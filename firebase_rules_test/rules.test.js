const fs = require("node:fs");
const path = require("node:path");
const {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} = require("@firebase/rules-unit-testing");
const {
  GeoPoint,
  Timestamp,
  collection,
  deleteDoc,
  doc,
  getDoc,
  getDocs,
  limit,
  orderBy,
  query,
  serverTimestamp,
  setDoc,
  where,
  updateDoc,
  writeBatch,
} = require("firebase/firestore");
const {
  get,
  ref,
  set,
  update,
} = require("firebase/database");

const projectRoot = path.resolve(__dirname, "..");
const projectId = "demo-rowing-team-rules";
const teamA = "team-a";
const teamB = "team-b";
const inviteA = "23456789ABCDEFGHJKMN";
const inviteB = "98765432NMPKJHGFEDCB";
const rotatedInviteA = "CDEFGHJKMNPQ";
const termsVersion = "2026-08-03";

function termsAcceptance() {
  return {
    termsVersion,
    termsAcceptedAt: serverTimestamp(),
  };
}

function livePosition({sequence = 1, updatedAt = Date.now(), session = "s-a"} = {}) {
  return {
    s: session,
    q: sequence,
    u: updatedAt,
    o: updatedAt,
    x: 36.07,
    y: 140.20,
    z: 3.5,
    c: 180,
    v: 4.2,
  };
}

function strokeTrace({updatedAt = Date.now(), startedAt = null} = {}) {
  return {
    o: startedAt === null ? updatedAt - 2400 : startedAt,
    d: 2400,
    b: 420,
    // 48点のint8波形をbase64にすると64文字。
    w: "A".repeat(64),
    r: 250,
    c: 81,
    l: 1010,
    k: 42,
    g: -13,
    h: 76,
    p: 380,
    u: updatedAt,
  };
}

function temporaryHazard(uid) {
  const points = Array.from(
    {length: 24},
    (_, index) => new GeoPoint(36.07 + index * 0.000001, 140.20),
  );
  return {
    name: "臨時危険区域",
    shape: "circle",
    kind: "generic",
    center: new GeoPoint(36.07, 140.20),
    radiusMeters: 5,
    points,
    createdBy: uid,
    source: "user_confirmed",
    createdAt: serverTimestamp(),
    confirmedAt: serverTimestamp(),
    updatedAt: serverTimestamp(),
    updatedBy: uid,
  };
}

// `assets/data/sakuragawa_obstacles.json` の SHA-256。
// `lib/config/hazard_profile_config.dart` の currentHazardProfileSha256 と
// `firestore.rules` の baseProfileSha256 に一致させること。
// ずれると共有校正の書き込みが全て拒否され、このテストも通らない。
const hazardProfileSha256 =
  "962ed029ec2ba091e7d5cfd1fbc6cf98d5fe1dad7787dff11a7f68bfb978f3e5";
const legacyHazardProfileSha256 =
  "aaafbf67b64c5b50aa401c77d849f52b1db4fe2a5bc122e5b09bc989d3572b33";

function dangerZoneOffsets() {
  return Object.fromEntries(
    ["shore", "bridge", "island", "driftwood", "testZone"].map((kind) => [
      kind,
      {
        waterSideMeters: 5,
        landSideMeters: kind === "shore" ? 15 : 5,
      },
    ]),
  );
}

function sharedSafetyCalibration({
  uid,
  revision = 1,
  calibrations = fixedCalibrations({
    bridge_suigo: {northMeters: 1.5, eastMeters: -2},
    pile_3eacc519: {northMeters: 0.5, eastMeters: -0.5},
  }),
  scaledOffsets,
  scaledVertexOffsets = {},
  disabledWarningSourceIds = ["island_upstream"],
  previousState,
  baseProfileVersion = 10,
  baseProfileSha256 = hazardProfileSha256,
} = {}) {
  return {
    kind: "fixed_obstacle_calibrations",
    baseProfileVersion,
    baseProfileSha256,
    scaledOffsets: scaledOffsets ?? fixedCalibrationOffsets(calibrations),
    scaledVertexOffsets,
    dangerZoneOffsets: dangerZoneOffsets(),
    disabledWarningSourceIds,
    primaryWarningLeadSeconds: 9,
    advanceWarningLeadSeconds: 12,
    revision,
    updatedAt: serverTimestamp(),
    updatedBy: uid,
    ...(previousState ? {previousState} : {}),
  };
}

const fixedCalibrationSourceIds = [
  "curve_1", "curve_2", "curve_3", "curve_4", "curve_5", "curve_6",
  "curve_7", "reverse_main_channel", "driftwood_estuary",
  "island_sakuragawa_bridge", "island_upstream", "bridge_suigo",
  "bridge_railway", "bridge_sakuragawa", "bridge_nioi", "bridge_zenigame",
  "bridge_tsuchiura", "bridge_gakuen", "shore_north", "shore_south",
  "test_zone_land", "shore_bd39c863", "pile_3eacc519", "pile_e14ff5c6",
  "pile_71ec1621",
];

function fixedCalibrations(overrides = {}) {
  return Object.fromEntries(
    fixedCalibrationSourceIds.map((sourceId) => [
      sourceId,
      overrides[sourceId] ?? {northMeters: 0, eastMeters: 0},
    ]),
  );
}

function fixedCalibrationOffsets(calibrations) {
  return Object.fromEntries(
    fixedCalibrationSourceIds.flatMap((sourceId) => {
      const northMeters = calibrations[sourceId]?.northMeters ?? 0;
      const eastMeters = calibrations[sourceId]?.eastMeters ?? 0;
      // アプリはゼロ補正をFirestoreへ保存しない。全source IDをゼロ値で
      // 埋めると実payloadと異なり、Rulesの式数上限だけを消費する。
      return northMeters === 0 && eastMeters === 0
        ? []
        : [[sourceId, new GeoPoint(northMeters * 3, eastMeters * 6)]];
    }),
  );
}

function previousSafetyState(
  calibrations,
  revision,
  scaledVertexOffsets = {},
  disabledWarningSourceIds = ["island_upstream"],
) {
  return {
    scaledOffsets: fixedCalibrationOffsets(calibrations),
    scaledVertexOffsets,
    dangerZoneOffsets: dangerZoneOffsets(),
    disabledWarningSourceIds,
    primaryWarningLeadSeconds: 9,
    advanceWarningLeadSeconds: 12,
    revision,
  };
}

async function seed(testEnv) {
  await testEnv.withSecurityRulesDisabled(async (context) => {
    const firestore = context.firestore();
    const database = context.database();
    const now = Timestamp.now();
    for (const [teamId, invite, owner] of [
      [teamA, inviteA, "u1"],
      [teamB, inviteB, "b1"],
    ]) {
      await setDoc(doc(firestore, "teams", teamId), {
        name: teamId,
        inviteCode: invite,
        createdBy: owner,
        adminUid: owner,
        createdAt: now,
      });
      await setDoc(doc(firestore, "invite_codes", invite), {
        teamId,
        createdBy: owner,
        createdAt: now,
      });
    }
    for (const [uid, teamId, invite] of [
      ["u1", teamA, inviteA],
      ["u2", teamA, inviteA],
      ["b1", teamB, inviteB],
    ]) {
      await setDoc(doc(firestore, "users", uid), {
        teamId,
        joinedAt: now,
        termsVersion,
        termsAcceptedAt: now,
      });
      await setDoc(doc(firestore, "teams", teamId, "members", uid), {
        inviteCode: invite,
        joinedAt: now,
        termsVersion,
        termsAcceptedAt: now,
      });
      await set(ref(database, `team_users/${uid}`), {teamId, inviteCode: invite});
      await set(ref(database, `team_members/${teamId}/${uid}`), {
        joinedAt: Date.now(),
      });
    }
    await set(ref(database, `team_invites/${inviteA}`), {
      teamId: teamA,
      ownerUid: "u1",
      createdAt: Date.now(),
    });
    await set(ref(database, `team_invites/${inviteB}`), {
      teamId: teamB,
      ownerUid: "b1",
      createdAt: Date.now(),
    });
    await set(ref(database, `team_meta/${teamA}`), {
      inviteCode: inviteA,
      ownerUid: "u1",
      createdAt: Date.now(),
    });
    await set(ref(database, `team_meta/${teamB}`), {
      inviteCode: inviteB,
      ownerUid: "b1",
      createdAt: Date.now(),
    });
    await set(
      ref(database, `teams/${teamA}/live_positions/u1`),
      livePosition({updatedAt: Date.now() - 1000, sequence: 10}),
    );
    await setDoc(doc(firestore, "teams", teamA, "temporary_obstacles", "seed"), {
      ...temporaryHazard("u1"),
      createdAt: now,
      confirmedAt: now,
      updatedAt: now,
      // 旧アプリが保存した期限切れデータも、今回の仕様では残し、
      // チームメンバーが編集・削除できる。
      expiresAt: Timestamp.fromMillis(Date.now() - 24 * 60 * 60 * 1000),
    });
  });
}

async function run() {
  const testEnv = await initializeTestEnvironment({
    projectId,
    firestore: {
      rules: fs.readFileSync(path.join(projectRoot, "firestore.rules"), "utf8"),
    },
    database: {
      rules: fs.readFileSync(path.join(projectRoot, "database.rules.json"), "utf8"),
    },
  });
  let checks = 0;
  const check = async (name, action) => {
    await action();
    checks += 1;
    process.stdout.write(`ok ${checks} - ${name}\n`);
  };

  try {
    await seed(testEnv);
    const anonymous = testEnv.unauthenticatedContext();
    const u1 = testEnv.authenticatedContext("u1");
    const u2 = testEnv.authenticatedContext("u2");
    const b1 = testEnv.authenticatedContext("b1");
    const u3 = testEnv.authenticatedContext("u3");

    await check("unauthenticated shared data is denied", async () => {
      await assertFails(get(ref(anonymous.database(), `teams/${teamA}/live_positions`)));
      await assertFails(getDoc(doc(anonymous.firestore(), "teams", teamA)));
    });

    await check("same-team members can read positions and hazards", async () => {
      await assertSucceeds(get(ref(u2.database(), `teams/${teamA}/live_positions`)));
      await assertSucceeds(
        getDoc(doc(u2.firestore(), "teams", teamA, "temporary_obstacles", "seed")),
      );
      const hazards = collection(
        u2.firestore(),
        "teams",
        teamA,
        "temporary_obstacles",
      );
      await assertFails(getDocs(hazards));
      await assertSucceeds(
        getDocs(
          query(
            hazards,
            limit(100),
          ),
        ),
      );
      await assertSucceeds(
        updateDoc(doc(u2.firestore(), "teams", teamA, "temporary_obstacles", "seed"), {
          confirmedAt: serverTimestamp(),
          updatedAt: serverTimestamp(),
          updatedBy: "u2",
        }),
      );
    });

    await check("another team is completely denied", async () => {
      await assertFails(get(ref(b1.database(), `teams/${teamA}/live_positions`)));
      await assertFails(
        getDoc(doc(b1.firestore(), "teams", teamA, "temporary_obstacles", "seed")),
      );
    });

    await check("unused Firestore position fallback is denied", async () => {
      const message = doc(u1.firestore(), "teams", teamA, "messages", "u1");
      await assertFails(getDoc(message));
      await assertFails(setDoc(message, {boatId: "u1"}));
    });

    await check("a member atomically writes only their own profile and position", async () => {
      const updatedAt = Date.now();
      await assertSucceeds(
        update(ref(u2.database()), {
          [`teams/${teamA}/boat_profiles/u2`]: {
            displayName: "u2",
            boatType: "r_1x",
            protocolVersion: 1,
            appVersion: "1.0.0",
            profileVersion: "sakuragawa-v3",
            updatedAt,
          },
          [`teams/${teamA}/live_positions/u2`]: livePosition({updatedAt}),
        }),
      );
      await assertFails(
        set(
          ref(u2.database(), `teams/${teamA}/live_positions/u1`),
          livePosition({updatedAt: Date.now(), sequence: 11}),
        ),
      );
    });

    // Build 8から位置payloadへ追加された表示状態。Rules側が1項目でも
    // 未対応だと、Firebaseは部分的に保存せず位置書き込み全体を拒否する。
    await check("presentation state fields do not block position sharing", async () => {
      // Codecが生成する全カテゴリ。特に p=橋脚 / k=杭が
      // 欠けると、その警告中だけ他艇から自艇が消える。
      for (const category of ["o", "b", "p", "s", "i", "d", "k", "c", "r", "f", "g"]) {
        const positionRef = ref(
          u2.database(),
          `teams/${teamA}/live_positions/u2`,
        );
        // 直前の別テストが残した位置とのレート制限は、
        // ここで検証する提示コードと無関係なので先に削除する。
        await assertSucceeds(set(positionRef, null));
        await assertSucceeds(
          set(positionRef, {
            ...livePosition({
              updatedAt: Date.now(),
              sequence: 30,
              session: `presentation-${category}`,
            }),
            w: `2${category}`,
            m: "f",
            a: 1,
          }),
        );
      }

      // 値域は開放せず、壊れた表示状態は拒否する。
      for (const invalidState of [
        {w: "system-warning"},
        {m: "fast"},
        {a: 0},
      ]) {
        await assertFails(
          set(
            ref(u2.database(), `teams/${teamA}/live_positions/u2`),
            {
              ...livePosition({
                updatedAt: Date.now(),
                sequence: 31,
                session: "presentation",
              }),
              w: "0s",
              m: "f",
              a: 1,
              ...invalidState,
            },
          ),
        );
      }
    });

    // 送信レート制限(`database.rules.json` の "u")。
    // クライアントは `intervalSec * 1000 - 100` で発火するため2秒間隔では
    // 1900ms で撃ち、`u` はサーバー到着時刻なのでジッタぶん更に縮む。
    // 下限が 1900ms だと余裕がゼロで、書き込み全体が拒否されていた
    // (2026-07-27 レビュー S2-H)。下限 1700ms の実効を固定する。
    await check("the position rate limit leaves room for network jitter", async () => {
      const base = Date.now();
      await testEnv.withSecurityRulesDisabled(async (context) => {
        await set(
          ref(context.database(), `teams/${teamA}/live_positions/u2`),
          livePosition({updatedAt: base, sequence: 100, session: "jitter"}),
        );
      });
      // 1900ms 目標が 100ms のジッタで縮んだ状態。旧下限では拒否されていた。
      await assertSucceeds(
        set(
          ref(u2.database(), `teams/${teamA}/live_positions/u2`),
          livePosition({
            updatedAt: base + 1800,
            sequence: 101,
            session: "jitter",
          }),
        ),
      );
      // 下限そのものは有効なまま。
      await assertFails(
        set(
          ref(u2.database(), `teams/${teamA}/live_positions/u2`),
          livePosition({
            updatedAt: base + 1800 + 1699,
            sequence: 102,
            session: "jitter",
          }),
        ),
      );
    });

    // 1ストロークの艇速波形。**位置とは別ノード**にしてあるのが要点で、
    // 位置payloadへ混ぜると12x12のfan-outで転送量が跳ね上がる。
    await check("a member publishes only their own stroke trace", async () => {
      const updatedAt = Date.now();
      await assertSucceeds(
        set(
          ref(u2.database(), `teams/${teamA}/stroke_traces/u2`),
          strokeTrace({updatedAt}),
        ),
      );
      // 他人の波形は書けない。
      await assertFails(
        set(
          ref(u2.database(), `teams/${teamA}/stroke_traces/u1`),
          strokeTrace({updatedAt: Date.now()}),
        ),
      );
    });

    // 監視者はどの艇を選ぶか事前に決められないため、ノード全体を読める。
    // 実際の購読は選んだ1艇ぶんだけ。
    await check("team members can watch any boat's stroke trace", async () => {
      await assertSucceeds(get(ref(u1.database(), `teams/${teamA}/stroke_traces`)));
      await assertSucceeds(
        get(ref(u1.database(), `teams/${teamA}/stroke_traces/u2`)),
      );
      await assertFails(
        get(ref(anonymous.database(), `teams/${teamA}/stroke_traces`)),
      );
    });

    // 壊れた波形で監視表示を止めないよう、値域はRules側でも閉じておく。
    await check("malformed stroke traces are rejected", async () => {
      const invalid = [
        {d: 120}, // 65spmより速い = ストロークではない
        {d: 9000}, // 12spmより遅い
        {b: -1}, // 負の艇速
        {b: 5000}, // 30m/sを超える艇速
        {w: ""}, // 波形なし
        {w: "A".repeat(200)}, // 想定外の巨大payload
        {w: 42}, // 非文字列
      ];
      for (const broken of invalid) {
        await assertFails(
          set(
            ref(u2.database(), `teams/${teamA}/stroke_traces/u2`),
            {...strokeTrace({updatedAt: Date.now()}), ...broken},
          ),
        );
      }
    });

    // 位置と同じレート制限。1ストローク(約2.4秒)に1回を超えて送らせない。
    await check("the stroke trace rate limit matches the position rule", async () => {
      const base = Date.now();
      await testEnv.withSecurityRulesDisabled(async (context) => {
        await set(
          ref(context.database(), `teams/${teamA}/stroke_traces/u2`),
          strokeTrace({updatedAt: base}),
        );
      });
      await assertSucceeds(
        set(
          ref(u2.database(), `teams/${teamA}/stroke_traces/u2`),
          strokeTrace({updatedAt: base + 1800}),
        ),
      );
      await assertFails(
        set(
          ref(u2.database(), `teams/${teamA}/stroke_traces/u2`),
          strokeTrace({updatedAt: base + 1800 + 1699}),
        ),
      );
      // 自分の波形はいつでも消せる(onDisconnect・共有停止)。
      await assertSucceeds(
        set(ref(u2.database(), `teams/${teamA}/stroke_traces/u2`), null),
      );
    });

    // 版番号や将来の艇種名だけで位置共有を拒否しない。
    await check("future versions can still publish profiles and positions", async () => {
      const updatedAt = Date.now();
      // 直前のレート制限テストは意図的に未来時刻を使う。テスト間で
      // その状態を持ち越すと、現在時刻の正常な送信までreplay扱いになる。
      await testEnv.withSecurityRulesDisabled(async (context) => {
        await set(
          ref(context.database(), `teams/${teamA}/live_positions/u2`),
          livePosition({
            updatedAt: updatedAt - 2000,
            sequence: 19,
            session: "future",
          }),
        );
      });
      await assertSucceeds(
        set(ref(u2.database(), `teams/${teamA}/boat_profiles/u2`), {
          displayName: "u2",
          boatType: "future_boat",
          protocolVersion: 2,
          appVersion: "1.0.1",
          profileVersion: "sakuragawa-v99",
          futureScalar: "ignored-by-older-clients",
          updatedAt,
        }),
      );
      await assertSucceeds(
        set(
          ref(u2.database(), `teams/${teamA}/live_positions/u2`),
          {...livePosition({updatedAt, sequence: 20, session: "future"}), futureFlag: true},
        ),
      );
      // 文字列としての妥当性は残す(空文字・65文字以上・非文字列は拒否)。
      for (const appVersion of ["", "x".repeat(65), 101]) {
        await assertFails(
          set(ref(u2.database(), `teams/${teamA}/boat_profiles/u2`), {
            displayName: "u2",
            boatType: "r_1x",
            protocolVersion: 1,
            appVersion,
            profileVersion: "sakuragawa-v3",
            updatedAt: Date.now(),
          }),
        );
      }
      // 値は固定しないが、不正な版番号は拒否する。
      await assertFails(
        set(ref(u2.database(), `teams/${teamA}/boat_profiles/u2`), {
          displayName: "u2",
          boatType: "r_1x",
          protocolVersion: 0,
          appVersion: "1.0.0",
          profileVersion: "sakuragawa-v3",
          updatedAt: Date.now(),
        }),
      );
    });

    await check("all team members can create, update, and delete a hazard", async () => {
      const hazard = doc(u1.firestore(), "teams", teamA, "temporary_obstacles", "shared");
      await assertSucceeds(setDoc(hazard, temporaryHazard("u1")));
      await assertSucceeds(
        updateDoc(doc(u2.firestore(), "teams", teamA, "temporary_obstacles", "shared"), {
          center: new GeoPoint(36.071, 140.20),
          points: Array.from(
            {length: 24},
            (_, index) => new GeoPoint(36.071 + index * 0.000001, 140.20),
          ),
          confirmedAt: serverTimestamp(),
          updatedAt: serverTimestamp(),
          updatedBy: "u2",
        }),
      );
      await assertSucceeds(
        deleteDoc(doc(u1.firestore(), "teams", teamA, "temporary_obstacles", "shared")),
      );
    });

    await check("invite codes cannot be listed but exact-code join is atomic", async () => {
      await assertFails(getDocs(collection(u3.firestore(), "invite_codes")));
      await assertSucceeds(getDoc(doc(u3.firestore(), "invite_codes", inviteA)));
      await assertFails(get(ref(u3.database(), "team_invites")));
      await assertSucceeds(get(ref(u3.database(), `team_invites/${inviteA}`)));
      const withoutTerms = writeBatch(u3.firestore());
      withoutTerms.set(doc(u3.firestore(), "users", "terms-missing"), {
        teamId: teamA,
        joinedAt: serverTimestamp(),
      });
      withoutTerms.set(
        doc(u3.firestore(), "teams", teamA, "members", "terms-missing"),
        {inviteCode: inviteA, joinedAt: serverTimestamp()},
      );
      await assertFails(withoutTerms.commit());
      const db = u3.firestore();
      const batch = writeBatch(db);
      batch.set(doc(db, "users", "u3"), {
        teamId: teamA,
        joinedAt: serverTimestamp(),
        ...termsAcceptance(),
      });
      batch.set(doc(db, "teams", teamA, "members", "u3"), {
        inviteCode: inviteA,
        joinedAt: serverTimestamp(),
        ...termsAcceptance(),
      });
      await assertSucceeds(batch.commit());
    });

    await check("only the administrator can list member IDs", async () => {
      await assertSucceeds(
        getDocs(collection(u1.firestore(), "teams", teamA, "members")),
      );
      await assertSucceeds(
        getDoc(doc(u1.firestore(), "teams", teamA, "members", "u1")),
      );
      await assertSucceeds(
        getDoc(doc(u1.firestore(), "teams", teamA, "members", "u2")),
      );
      await assertFails(getDocs(collection(u2.firestore(), "teams", teamA, "members")));
      await assertFails(getDoc(doc(u2.firestore(), "teams", teamA, "members", "u1")));
      await assertFails(get(ref(u1.database(), `team_members/${teamA}`)));
      await assertSucceeds(get(ref(u1.database(), `team_members/${teamA}/u1`)));
      await assertFails(get(ref(u1.database(), `team_members/${teamA}/u2`)));
    });

    await check("first team creation, first join, and restart restoration succeed", async () => {
      const creatorId = "creator";
      const joinerId = "joiner";
      const newTeamId = "new-random-team-id";
      // 新規発行は12文字。seed済みの20文字コードも他テストで継続利用する。
      const newInvite = "BCDEFGHJKMNP";
      const creator = testEnv.authenticatedContext(creatorId);
      const joiner = testEnv.authenticatedContext(joinerId);

      // TeamService.createTeam: create-only meta, collision-safe invite,
      // Firestore atomic membership, then the minimal RTDB bridge.
      await assertSucceeds(
        set(ref(creator.database(), `team_meta/${newTeamId}`), {
          inviteCode: newInvite,
          ownerUid: creatorId,
          createdAt: Date.now(),
        }),
      );
      await assertSucceeds(
        set(ref(creator.database(), `team_invites/${newInvite}`), {
          teamId: newTeamId,
          ownerUid: creatorId,
          createdAt: Date.now(),
        }),
      );
      const creatorDb = creator.firestore();
      const createBatch = writeBatch(creatorDb);
      createBatch.set(doc(creatorDb, "teams", newTeamId), {
        name: "new team",
        inviteCode: newInvite,
        createdBy: creatorId,
        adminUid: creatorId,
        createdAt: serverTimestamp(),
      });
      createBatch.set(doc(creatorDb, "invite_codes", newInvite), {
        teamId: newTeamId,
        createdBy: creatorId,
        createdAt: serverTimestamp(),
      });
      createBatch.set(doc(creatorDb, "users", creatorId), {
        teamId: newTeamId,
        joinedAt: serverTimestamp(),
        ...termsAcceptance(),
      });
      createBatch.set(doc(creatorDb, "teams", newTeamId, "members", creatorId), {
        inviteCode: newInvite,
        joinedAt: serverTimestamp(),
        ...termsAcceptance(),
      });
      await assertSucceeds(createBatch.commit());
      await assertSucceeds(
        set(ref(creator.database(), `team_users/${creatorId}`), {
          teamId: newTeamId,
          inviteCode: newInvite,
        }),
      );
      const creatorMember = ref(
        creator.database(),
        `team_members/${newTeamId}/${creatorId}`,
      );
      await assertSucceeds(get(creatorMember));
      await assertSucceeds(set(creatorMember, {joinedAt: Date.now()}));
      // restoreMembership reads the existing bridge and deliberately skips set.
      const restoredCreatorMember = await assertSucceeds(get(creatorMember));
      if (!restoredCreatorMember.exists()) throw new Error("creator restore failed");

      // TeamService.joinTeam: exact invite, atomic Firestore membership, bridge.
      const joinDb = joiner.firestore();
      const joinBatch = writeBatch(joinDb);
      joinBatch.set(doc(joinDb, "users", joinerId), {
        teamId: newTeamId,
        joinedAt: serverTimestamp(),
        ...termsAcceptance(),
      });
      joinBatch.set(doc(joinDb, "teams", newTeamId, "members", joinerId), {
        inviteCode: newInvite,
        joinedAt: serverTimestamp(),
        ...termsAcceptance(),
      });
      await assertSucceeds(joinBatch.commit());
      await assertSucceeds(
        set(ref(joiner.database(), `team_users/${joinerId}`), {
          teamId: newTeamId,
          inviteCode: newInvite,
        }),
      );
      const joinerMember = ref(
        joiner.database(),
        `team_members/${newTeamId}/${joinerId}`,
      );
      await assertSucceeds(get(joinerMember));
      await assertSucceeds(set(joinerMember, {joinedAt: Date.now()}));
      const restoredJoinerMember = await assertSucceeds(get(joinerMember));
      if (!restoredJoinerMember.exists()) throw new Error("joiner restore failed");
    });

    await check("an attacker cannot bind a new invite to an existing team", async () => {
      const attackerCode = "ABCDEFGHJKMNPQRSTVW2";
      await assertFails(
        set(ref(b1.database(), `team_invites/${attackerCode}`), {
          teamId: teamA,
          ownerUid: "b1",
          createdAt: Date.now(),
        }),
      );
      await assertFails(
        set(ref(b1.database(), `team_meta/${teamA}`), {
          inviteCode: attackerCode,
          ownerUid: "b1",
          createdAt: Date.now(),
        }),
      );
    });

    await check("an unused invite reservation can be cleaned but a live team cannot", async () => {
      const ownerId = "cleanup-owner";
      const orphanTeam = "abandoned-random-team-id";
      const orphanInvite = "CDEFGHJKMNPQRSTVW234";
      const owner = testEnv.authenticatedContext(ownerId);
      await assertSucceeds(
        set(ref(owner.database(), `team_meta/${orphanTeam}`), {
          inviteCode: orphanInvite,
          ownerUid: ownerId,
          createdAt: Date.now(),
        }),
      );
      await assertSucceeds(
        set(ref(owner.database(), `team_invites/${orphanInvite}`), {
          teamId: orphanTeam,
          ownerUid: ownerId,
          createdAt: Date.now(),
        }),
      );
      await assertSucceeds(
        update(ref(owner.database()), {
          [`team_meta/${orphanTeam}`]: null,
          [`team_invites/${orphanInvite}`]: null,
        }),
      );
      const collisionOwnerId = "collision-owner";
      const collisionTeam = "collision-random-team-id";
      const collisionOwner = testEnv.authenticatedContext(collisionOwnerId);
      await assertSucceeds(
        set(ref(collisionOwner.database(), `team_meta/${collisionTeam}`), {
          inviteCode: inviteA,
          ownerUid: collisionOwnerId,
          createdAt: Date.now(),
        }),
      );
      await assertFails(
        set(ref(collisionOwner.database(), `team_invites/${inviteA}`), {
          teamId: collisionTeam,
          ownerUid: collisionOwnerId,
          createdAt: Date.now(),
        }),
      );
      await assertSucceeds(
        update(ref(collisionOwner.database()), {
          [`team_meta/${collisionTeam}`]: null,
        }),
      );
      await assertFails(
        update(ref(u1.database()), {
          [`team_meta/${teamA}`]: null,
          [`team_invites/${inviteA}`]: null,
        }),
      );
    });

    await check("an authenticated user without membership cannot access team data", async () => {
      const u4 = testEnv.authenticatedContext("u4");
      await assertFails(get(ref(u4.database(), `teams/${teamA}/live_positions`)));
      await assertFails(
        set(
          ref(u4.database(), `teams/${teamA}/live_positions/u4`),
          livePosition(),
        ),
      );
      await assertFails(
        setDoc(
          doc(u4.firestore(), "teams", teamA, "temporary_obstacles", "blocked"),
          temporaryHazard("u4"),
        ),
      );
    });

    await check("position replay, sequence reversal, and over-frequency writes are denied", async () => {
      const base = Date.now();
      await testEnv.withSecurityRulesDisabled(async (context) => {
        await set(
          ref(context.database(), `teams/${teamA}/live_positions/u1`),
          livePosition({updatedAt: base - 2000, sequence: 10, session: "stable"}),
        );
      });
      await assertFails(
        set(
          ref(u1.database(), `teams/${teamA}/live_positions/u1`),
          livePosition({updatedAt: base, sequence: 9, session: "stable"}),
        ),
      );
      await assertSucceeds(
        set(
          ref(u1.database(), `teams/${teamA}/live_positions/u1`),
          livePosition({updatedAt: base, sequence: 11, session: "stable"}),
        ),
      );
      await assertFails(
        set(
          ref(u1.database(), `teams/${teamA}/live_positions/u1`),
          livePosition({updatedAt: base + 100, sequence: 12, session: "stable"}),
        ),
      );
    });

    await check("all team members publish one shared safety document", async () => {
      const legacyDoc = doc(
        u1.firestore(),
        "teams",
        teamA,
        "managed_hazards",
        "fixed_obstacle_calibrations_v9",
      );
      await testEnv.withSecurityRulesDisabled(async (context) => {
        await setDoc(
          doc(
            context.firestore(),
            "teams",
            teamA,
            "managed_hazards",
            "fixed_obstacle_calibrations_v9",
          ),
          sharedSafetyCalibration({
            uid: "u1",
            baseProfileVersion: 9,
            baseProfileSha256: legacyHazardProfileSha256,
          }),
        );
      });
      await assertSucceeds(getDoc(legacyDoc));
      await assertFails(
        setDoc(
          legacyDoc,
          sharedSafetyCalibration({
            uid: "u1",
            baseProfileVersion: 9,
            baseProfileSha256: legacyHazardProfileSha256,
          }),
        ),
      );

      const ownerDoc = doc(
        u1.firestore(),
        "teams",
        teamA,
        "managed_hazards",
        "fixed_obstacle_calibrations_v10",
      );
      await assertSucceeds(
        setDoc(ownerDoc, sharedSafetyCalibration({uid: "u1"})),
      );
      await assertSucceeds(
        getDoc(
          doc(
            u2.firestore(),
            "teams",
            teamA,
            "managed_hazards",
            "fixed_obstacle_calibrations_v10",
          ),
        ),
      );
      await assertFails(
        getDoc(
          doc(
            b1.firestore(),
            "teams",
            teamA,
            "managed_hazards",
            "fixed_obstacle_calibrations_v10",
          ),
        ),
      );
      await assertSucceeds(
        setDoc(
          doc(
            u2.firestore(),
            "teams",
            teamA,
            "managed_hazards",
            "fixed_obstacle_calibrations_v10",
          ),
          sharedSafetyCalibration({
            uid: "u2",
            revision: 2,
            previousState: previousSafetyState(
              fixedCalibrations({
                bridge_suigo: {northMeters: 1.5, eastMeters: -2},
                pile_3eacc519: {northMeters: 0.5, eastMeters: -0.5},
              }),
              1,
            ),
          }),
        ),
      );
    });

    await check("shared safety publish requires revision + 1 and exact previous state", async () => {
      const ownerDoc = doc(
        u1.firestore(),
        "teams",
        teamA,
        "managed_hazards",
        "fixed_obstacle_calibrations_v10",
      );
      const previousState = previousSafetyState(
        fixedCalibrations({
          bridge_suigo: {northMeters: 1.5, eastMeters: -2},
          pile_3eacc519: {northMeters: 0.5, eastMeters: -0.5},
        }),
        2,
      );
      await assertSucceeds(
        setDoc(
          ownerDoc,
          sharedSafetyCalibration({
            uid: "u1",
            revision: 3,
            calibrations: fixedCalibrations({
              bridge_suigo: {northMeters: 2, eastMeters: -2},
            }),
            previousState,
          }),
        ),
      );
      await assertFails(
        setDoc(
          ownerDoc,
          sharedSafetyCalibration({
            uid: "u1",
            revision: 5,
            previousState: previousSafetyState(
              fixedCalibrations({
                bridge_suigo: {northMeters: 2, eastMeters: -2},
              }),
              3,
            ),
          }),
        ),
      );
      await assertFails(
        setDoc(
          ownerDoc,
          sharedSafetyCalibration({
            uid: "u1",
            revision: 4,
            previousState: {
              ...previousState,
              revision: 3,
            },
          }),
        ),
      );
    });

    await check("shared safety schema rejects unknown IDs, ranges, and profiles", async () => {
      const teamBDoc = doc(
        b1.firestore(),
        "teams",
        teamB,
        "managed_hazards",
        "fixed_obstacle_calibrations_v10",
      );
      await assertFails(
        setDoc(
          teamBDoc,
          sharedSafetyCalibration({
            uid: "b1",
            scaledOffsets: {
              ...fixedCalibrationOffsets(fixedCalibrations()),
              unknown_obstacle: new GeoPoint(0, 0),
            },
          }),
        ),
      );
      await assertFails(
        setDoc(teamBDoc, {
          ...sharedSafetyCalibration({uid: "b1"}),
          baseProfileSha256: "wrong-profile",
        }),
      );
      await assertFails(
        setDoc(
          teamBDoc,
          sharedSafetyCalibration({
            uid: "b1",
            disabledWarningSourceIds: ["unknown_obstacle"],
          }),
        ),
      );
      // 頂点単位の校正は、同梱プロファイルの頂点数と厳密に一致すること。
      // 数が合わない配列を受け入れると、別形状へ座標差分を当てることになる。
      await assertFails(
        setDoc(
          teamBDoc,
          sharedSafetyCalibration({
            uid: "b1",
            scaledVertexOffsets: {
              shore_north: Array.from({length: 153}, () => new GeoPoint(0, 0)),
            },
          }),
        ),
      );
      await assertSucceeds(
        setDoc(
          teamBDoc,
          sharedSafetyCalibration({
            uid: "b1",
            scaledVertexOffsets: {
              shore_north: Array.from(
                {length: 154},
                (_, index) => new GeoPoint(index === 7 ? 3 : 0, 0),
              ),
            },
          }),
        ),
      );
    });

    await check("an administrator revokes a member and rotates the invite across Firebase", async () => {
      const firestore = u1.firestore();
      const revoke = writeBatch(firestore);
      revoke.update(doc(firestore, "teams", teamA), {
        inviteCode: rotatedInviteA,
        adminUid: "u1",
      });
      revoke.set(doc(firestore, "invite_codes", rotatedInviteA), {
        teamId: teamA,
        createdBy: "u1",
        createdAt: serverTimestamp(),
      });
      revoke.delete(doc(firestore, "invite_codes", inviteA));
      revoke.delete(doc(firestore, "teams", teamA, "members", "u2"));
      revoke.delete(doc(firestore, "users", "u2"));
      await assertSucceeds(revoke.commit());

      await assertFails(getDoc(doc(u2.firestore(), "teams", teamA)));
      await assertFails(
        setDoc(
          doc(u2.firestore(), "teams", teamA, "temporary_obstacles", "after-revoke"),
          temporaryHazard("u2"),
        ),
      );
      const oldCodeRejoin = writeBatch(u2.firestore());
      oldCodeRejoin.set(doc(u2.firestore(), "users", "u2"), {
        teamId: teamA,
        joinedAt: serverTimestamp(),
        ...termsAcceptance(),
      });
      oldCodeRejoin.set(doc(u2.firestore(), "teams", teamA, "members", "u2"), {
        inviteCode: inviteA,
        joinedAt: serverTimestamp(),
        ...termsAcceptance(),
      });
      await assertFails(oldCodeRejoin.commit());
      await assertFails(
        updateDoc(doc(u3.firestore(), "teams", teamA), {
          inviteCode: "DEFGHJKMNPQR",
        }),
      );

      await assertSucceeds(
        update(ref(u1.database()), {
          [`team_meta/${teamA}/inviteCode`]: rotatedInviteA,
          [`team_invites/${inviteA}`]: null,
          [`team_invites/${rotatedInviteA}`]: {
            teamId: teamA,
            ownerUid: "u1",
            createdAt: Date.now(),
          },
          [`teams/${teamA}/live_positions/u2`]: null,
          [`teams/${teamA}/boat_profiles/u2`]: null,
          "team_users/u2": null,
          [`team_members/${teamA}/u2`]: null,
        }),
      );
      await assertFails(get(ref(u2.database(), `teams/${teamA}/live_positions`)));
      await assertFails(
        set(
          ref(u2.database(), `teams/${teamA}/live_positions/u2`),
          livePosition({updatedAt: Date.now(), sequence: 50, session: "revoked"}),
        ),
      );
      await assertFails(
        set(ref(u2.database(), "team_users/u2"), {
          teamId: teamA,
          inviteCode: inviteA,
        }),
      );
    });

    await check("account deletion atomically clears bridges and anonymizes ownership", async () => {
      await assertSucceeds(
        set(ref(u1.database(), `teams/${teamA}/boat_profiles/u1`), {
          displayName: "owner",
          boatType: "r_1x",
          protocolVersion: 1,
          appVersion: "1.0.0",
          profileVersion: "sakuragawa-v3",
          updatedAt: Date.now(),
        }),
      );
      const cleanup = {
        [`teams/${teamA}/live_positions/u1`]: null,
        [`teams/${teamA}/boat_profiles/u1`]: null,
        "team_users/u1": null,
        [`team_members/${teamA}/u1`]: null,
        [`team_meta/${teamA}/ownerUid`]: "deleted-account",
        [`team_invites/${rotatedInviteA}/ownerUid`]: "deleted-account",
      };
      await assertSucceeds(update(ref(u1.database()), cleanup));
      // Unknown commit result can be retried without recreating partial state.
      await assertSucceeds(update(ref(u1.database()), cleanup));

      const db = u1.firestore();
      const batch = writeBatch(db);
      batch.update(doc(db, "teams", teamA), {createdBy: "deleted-account"});
      batch.update(doc(db, "invite_codes", rotatedInviteA), {
        createdBy: "deleted-account",
      });
      batch.delete(doc(db, "teams", teamA, "members", "u1"));
      batch.delete(doc(db, "users", "u1"));
      await assertSucceeds(batch.commit());

      await testEnv.withSecurityRulesDisabled(async (context) => {
        const rtdb = context.database();
        const firestore = context.firestore();
        const values = await Promise.all([
          get(ref(rtdb, `teams/${teamA}/live_positions/u1`)),
          get(ref(rtdb, `teams/${teamA}/boat_profiles/u1`)),
          get(ref(rtdb, "team_users/u1")),
          get(ref(rtdb, `team_members/${teamA}/u1`)),
          get(ref(rtdb, `team_meta/${teamA}/ownerUid`)),
          get(ref(rtdb, `team_invites/${rotatedInviteA}/ownerUid`)),
        ]);
        for (const value of values.slice(0, 4)) {
          if (value.exists()) throw new Error("RTDB cleanup was partial");
        }
        if (values[4].val() !== "deleted-account" ||
            values[5].val() !== "deleted-account") {
          throw new Error("RTDB owner was not anonymized");
        }
        const team = await getDoc(doc(firestore, "teams", teamA));
        const invite = await getDoc(doc(firestore, "invite_codes", rotatedInviteA));
        if (team.data().createdBy !== "deleted-account" ||
            invite.data().createdBy !== "deleted-account") {
          throw new Error("Firestore owner was not anonymized");
        }
      });
    });

    process.stdout.write(`1..${checks}\n`);
  } finally {
    await testEnv.cleanup();
  }
}

run().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
