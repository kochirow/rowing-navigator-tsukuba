/**
 * Firebaseとの境界。既存アカウントでの認証と読み取りだけを提供する。
 * Firestoreの書き込みAPIは、このファイルを含めツールに導入しない。
 */
import { getApp, getApps, initializeApp, type FirebaseApp } from 'firebase/app';
import { getAuth, signInAnonymously, type User } from 'firebase/auth';
import { collection, doc, getDoc, getDocs, getFirestore, limit, query, serverTimestamp, writeBatch, type DocumentData, type Firestore, type GeoPoint } from 'firebase/firestore';
import type { Coordinate } from '../model/types';

export type FirestoreImport = {
  teamId: string;
  calibration: DocumentData | null;
  managedDriftwood: DocumentData | null;
  temporaryObstacles: Array<DocumentData & { id: string }>;
};

let firebaseApp: FirebaseApp | undefined;
async function app(): Promise<FirebaseApp> {
  if (firebaseApp) return firebaseApp;
  const config = await fetch('/api/firebase-config').then(async (response) => {
    if (!response.ok) throw new Error((await response.json()).message ?? 'Firebase設定を取得できません。');
    return response.json() as Promise<Record<string, string>>;
  });
  firebaseApp = getApps().length ? getApp() : initializeApp(config);
  return firebaseApp;
}
async function database(): Promise<Firestore> { return getFirestore(await app()); }

/// ツール専用の匿名IDを作る。危険区域データの更新・削除には使わない。
async function ensureUser(): Promise<User> {
  const auth = getAuth(await app());
  return auth.currentUser ?? (await signInAnonymously(auth)).user;
}

async function memberTeamId(user: User): Promise<string | null> {
  const snapshot = await getDoc(doc(await database(), 'users', user.uid));
  const teamId = snapshot.data()?.teamId;
  return typeof teamId === 'string' && teamId.length > 0 ? teamId : null;
}

/// 招待コードを明示入力した時だけ、ツール用匿名IDをチームへ参加させる。
/// 危険区域や共有校正には一切書き込まない。
async function joinTeamForRead(user: User, inviteCode: string): Promise<string> {
  const normalized = inviteCode.toUpperCase().replace(/[\s-]/g, '');
  if (!/^[23456789ABCDEFGHJKMNPQRSTVWXYZ]{12}$|^[23456789ABCDEFGHJKMNPQRSTVWXYZ]{20}$/.test(normalized)) {
    throw new Error('招待コードの形式が正しくありません。');
  }
  const db = await database();
  const invite = await getDoc(doc(db, 'invite_codes', normalized));
  const teamId = invite.data()?.teamId;
  if (!invite.exists() || typeof teamId !== 'string' || !teamId) throw new Error('招待コードが見つかりません。');
  const batch = writeBatch(db);
  batch.set(doc(db, 'teams', teamId, 'members', user.uid), { inviteCode: normalized, joinedAt: serverTimestamp() });
  batch.set(doc(db, 'users', user.uid), { teamId, joinedAt: serverTimestamp() });
  await batch.commit();
  return teamId;
}

/// 既存所属を使うか、利用者が入力した招待コードで読み取り専用所属を作る。
export async function prepareTemporaryObstacleImport(inviteCode: string): Promise<{ user: User; teamId: string }> {
  const user = await ensureUser();
  const existingTeamId = await memberTeamId(user);
  if (existingTeamId) return { user, teamId: existingTeamId };
  if (!inviteCode.trim()) throw new Error('初回のみ、このチームの招待コードを入力してください。');
  return { user, teamId: await joinTeamForRead(user, inviteCode) };
}

export function asCoordinate(value: GeoPoint): Coordinate { return { lat: value.latitude, lng: value.longitude }; }

export async function readTeamSafety(teamId: string): Promise<FirestoreImport> {
  const db = await database();
  const root = `teams/${teamId}`;
  // 最新v10を優先し、存在しない間だけ旧文書を読む。いずれにも書き込まない。
  const v10 = await getDoc(doc(db, `${root}/managed_hazards/fixed_obstacle_calibrations_v10`));
  const v9 = v10.exists() ? null : await getDoc(doc(db, `${root}/managed_hazards/fixed_obstacle_calibrations_v9`));
  const v8 = v10.exists() || v9?.exists() ? null : await getDoc(doc(db, `${root}/managed_hazards/fixed_obstacle_calibrations_v8`));
  const v7 = v10.exists() || v9?.exists() || v8?.exists() ? null : await getDoc(doc(db, `${root}/managed_hazards/fixed_obstacle_calibrations_v7`));
  const v6 = v10.exists() || v9?.exists() || v8?.exists() || v7?.exists() ? null : await getDoc(doc(db, `${root}/managed_hazards/fixed_obstacle_calibrations_v6`));
  const v5 = v10.exists() || v9?.exists() || v8?.exists() || v7?.exists() || v6?.exists() ? null : await getDoc(doc(db, `${root}/managed_hazards/fixed_obstacle_calibrations_v5`));
  const v4 = v10.exists() || v9?.exists() || v8?.exists() || v7?.exists() || v6?.exists() || v5?.exists() ? null : await getDoc(doc(db, `${root}/managed_hazards/fixed_obstacle_calibrations_v4`));
  const v3 = v10.exists() || v9?.exists() || v8?.exists() || v7?.exists() || v6?.exists() || v5?.exists() || v4?.exists() ? null : await getDoc(doc(db, `${root}/managed_hazards/fixed_obstacle_calibrations_v3`));
  const v2 = v10.exists() || v9?.exists() || v8?.exists() || v7?.exists() || v6?.exists() || v5?.exists() || v4?.exists() || v3?.exists() ? null : await getDoc(doc(db, `${root}/managed_hazards/fixed_obstacle_calibrations_v2`));
  const driftwood = await getDoc(doc(db, `${root}/managed_hazards/fixed_driftwood_01`));
  const temporary = await getDocs(query(collection(db, `${root}/temporary_obstacles`), limit(100)));
  return {
    teamId,
    calibration: v10.exists() ? v10.data() : v9?.exists() ? v9.data() : v8?.exists() ? v8.data() : v7?.exists() ? v7.data() : v6?.exists() ? v6.data() : v5?.exists() ? v5.data() : v4?.exists() ? v4.data() : v3?.exists() ? v3.data() : v2?.exists() ? v2.data() : null,
    managedDriftwood: driftwood.exists() ? driftwood.data() : null,
    temporaryObstacles: temporary.docs.map((snapshot) => ({ id: snapshot.id, ...snapshot.data() })),
  };
}
