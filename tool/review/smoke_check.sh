#!/usr/bin/env bash
# 動作確認・総合監査の共通チェック。差分レビューでは関連検証を直接選んでもよい。
# auto: 文書だけなら差分確認、限定コードは指定された関連テスト、その他の変更は全検証。
# --base REF: REF..HEAD と未コミット変更を分類（指定なしは未コミット変更のみ）。
# --targeted TEST...: 限定コードの関連Flutterテストを明示。安全・基盤変更は全検証を維持。
# --static / --analyze / --full: 共通静的 / 解析と診断カタログ / 全解析・全テスト。
# ビルド・署名・本番アクセスは行わない。CI・ローカル・実機の証拠を区別する。
set -uo pipefail

MODE=auto
BASE=""
TARGETS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --full) MODE=full; shift ;;
    --static|--fast) MODE=static; shift ;;
    --analyze) MODE=analyze; shift ;;
    --base)
      [ "$#" -ge 2 ] || { echo "--base に比較元が必要" >&2; exit 2; }
      BASE=$2; shift 2 ;;
    --targeted)
      shift
      while [ "$#" -gt 0 ] && [[ "$1" != --* ]]; do
        [ -f "$1" ] && [[ "$1" == test/*_test.dart ]] || {
          echo "対象テストが存在しないか test/*_test.dart 形式ではない: $1" >&2; exit 2;
        }
        TARGETS+=("$1"); shift
      done
      [ "${#TARGETS[@]}" -gt 0 ] || { echo "--targeted にテストが必要" >&2; exit 2; } ;;
    *) echo "不明な引数: $1" >&2; exit 2 ;;
  esac
done

[ -f pubspec.yaml ] || { echo "リポジトリ直下で実行してください。" >&2; exit 1; }
git rev-parse --verify HEAD >/dev/null 2>&1 || { echo "Git HEAD を確認できない" >&2; exit 1; }
if [ -n "$BASE" ]; then
  git rev-parse --verify "${BASE}^{commit}" >/dev/null 2>&1 || { echo "比較元を確認できない: $BASE" >&2; exit 2; }
fi
fail=0
note() { printf '\n==== %s ====\n' "$1"; }
ng() { printf '  [NG] %s\n' "$1"; fail=1; }
ok() { printf '  [OK] %s\n' "$1"; }
ci_verdict=unknown
ci_reason="CI結果は参照していない"
run_analyze=0
run_tests=0
run_targeted=0
changed=0
code_changed=0
broad_changed=0

# --no-renames で改名前後の双方を分類する。未追跡ファイルも含める。
while IFS= read -r -d '' file; do
  changed=1
  case "$file" in
    *.md) ;;
    lib/screens/*.dart|lib/features/*.dart|lib/widgets/*.dart|lib/theme/*.dart|test/*_test.dart)
      code_changed=1 ;;
    *) broad_changed=1 ;;
  esac
done < <(
  git diff --no-renames --name-only -z HEAD --
  if [ -n "$BASE" ]; then git diff --no-renames --name-only -z "$BASE" HEAD --; fi
  git ls-files --others --exclude-standard -z
)

case "$MODE" in
  full) run_analyze=1; run_tests=1; decision="--full の指定" ;;
  analyze) run_analyze=1; decision="--analyze の指定" ;;
  static) decision="--static の指定（共通静的チェックのみ）" ;;
  auto)
    if [ "$changed" -eq 1 ] && [ "$code_changed" -eq 0 ] && [ "$broad_changed" -eq 0 ]; then
      echo "文書のみの変更: 差分の空白エラーを確認。参照・内容はレビューで確認する。"
      git diff --check HEAD -- || exit 1
      if [ -n "$BASE" ]; then git diff --check "$BASE" HEAD -- || exit 1; fi
      echo "アプリの解析・テストは未実施。文書変更から実行時の安全性は認定しない。"
      exit 0
    elif [ "$broad_changed" -eq 1 ]; then
      run_analyze=1; run_tests=1; decision="安全・基盤または影響を限定できない変更"
    elif [ "$code_changed" -eq 1 ]; then
      run_analyze=1
      if [ "${#TARGETS[@]}" -gt 0 ]; then
        run_targeted=1; decision="限定コード変更: 指定された関連テスト"
      else
        run_tests=1; decision="コード変更の対象テスト未指定: 全検証"
      fi
    elif [ "${#TARGETS[@]}" -gt 0 ]; then
      run_analyze=1; run_targeted=1; decision="指定された関連検証"
    else
      head_sha=$(git rev-parse HEAD)
      run=""
      if command -v gh >/dev/null 2>&1; then
        run=$(gh run list --commit "$head_sha" --workflow ci.yml --limit 1 \
          --json status,conclusion --jq '.[0] | "\(.status)/\(.conclusion)"' 2>/dev/null) || run=""
      fi
      case "$run" in
        completed/success) ci_verdict=covered; ci_reason="HEAD(${head_sha:0:7})のCIがsuccess" ;;
        completed/failure|completed/timed_out|completed/action_required)
          run_analyze=1; run_tests=1; ci_reason="HEADのCIに未解決の失敗: $run" ;;
        *) ci_reason="HEADのCIが未確認または未完了。アプリ全体の検証済みとは扱わない" ;;
      esac
      decision="${ci_reason}（コミット済み変更の検証には --base、総合検証には --full）"
    fi ;;
esac

note "1-2. 解析とテスト"
echo "  判断: $decision"
if [ "$run_analyze" -eq 1 ]; then
  if dart analyze lib test tool; then ok "解析エラーなし"; else ng "解析エラーあり"; fi
else
  echo "  解析は今回未実施。"
fi
if [ "$run_tests" -eq 1 ]; then
  if flutter test; then ok "全テスト成功"; else ng "テスト失敗あり"; fi
elif [ "$run_targeted" -eq 1 ]; then
  if flutter test "${TARGETS[@]}"; then ok "対象テスト成功"; else ng "対象テスト失敗あり"; fi
elif [ "$ci_verdict" = covered ]; then
  ok "テストはCI結果を引用($ci_reason)"
else
  echo "  全テストは今回未実施。依頼・影響範囲に応じて関連検証を行う。"
fi

# ------------------------------------------------------- 3. 鮮度の階層(不変条件2)
note "3. 鮮度の階層(不変条件2)"
val() { grep -hoE "^const $1 = [0-9]+" lib/config/*.dart | grep -oE '[0-9]+$' | head -1; }
fresh=$(grep -oE 'freshUntil = Duration\(seconds: [0-9]+' lib/services/other_boat_track_store.dart | grep -oE '[0-9]+$' | head -1)
pred=$(val boatPredictionTimeoutSeconds)
stale=$(val boatStaleTimeoutSeconds)
stopped=$(val sendIntervalStoppedSec)
echo "  freshUntil=${fresh:-?}s / prediction=${pred:-?}s / stale=${stale:-?}s / sendStopped=${stopped:-?}s"
if [ -n "$fresh" ] && [ -n "$pred" ] && [ -n "$stale" ] && [ -n "$stopped" ]; then
  if [ "$fresh" -lt "$pred" ] && [ "$pred" -lt "$stale" ] && [ "$stopped" -lt "$stale" ]; then
    ok "freshUntil < prediction < stale、かつ sendStopped < stale"
  else
    ng "階層が崩れている。他艇が評価から消える窓が空く"
  fi
else
  ng "値を読み取れなかった(定数名が変わった可能性。手で確認すること)"
fi

# --------------------------------------------------- 4. 警告音アセットの実在
note "4. コードが参照する警告音アセットの実在"
# audioplayers は 'audio/xxx.mp3' を assets/audio/xxx.mp3 として解決する。
refs=$(grep -rhoE "'(assets/)?audio/[A-Za-z0-9_./-]+\.(mp3|wav|m4a)'" lib | tr -d "'" | sed 's|^assets/||' | sort -u)
missing=""
for a in $refs; do
  [ -f "assets/$a" ] || missing="${missing}  [NG] 実体が無い: assets/$a"$'\n'
done
if [ -n "$missing" ]; then printf '%s' "$missing"; fail=1; else
  ok "参照されている音声アセットはすべて存在する($(printf '%s\n' "$refs" | grep -c . ) 件)"
fi
# 逆向き: 置いてあるのに誰も参照していないファイル(死んだアセット)
for f in assets/audio/*.mp3; do
  b=$(basename "$f")
  printf '%s\n' "$refs" | grep -q "$b" || echo "  [参考] 参照されていないアセット: $f"
done

# -------------------------------------------- 5. 無言 catch(fail-silent 候補)
note "5. 無言 catch の候補(安全経路)"
echo "  catch の直後3行に log / diagnostic / rethrow / 状態更新が見当たらないもの。"
echo "  握りつぶしは「データ欠損を安全と読み替える」経路になりやすい(原則6・不変条件3)。"
silent=$(for f in lib/services/*.dart lib/hooks/*.dart; do
  awk -v file="$f" '
    /catch[[:space:]]*\(/ { pending = 3; line = NR; found = 0; next }
    pending > 0 {
      if ($0 ~ /log|Log|diagnostic|Diagnostic|debugPrint|rethrow|throw|onError|record|report|emit|state|value|notify|fault|=/) found = 1
      pending--
      if (pending == 0 && found == 0) printf "  %s:%d\n", file, line
    }
  ' "$f"
done)
if [ -z "$silent" ]; then
  ok "候補なし"
else
  echo "$silent"
  echo "  → 上記は候補にすぎない。1件ずつ読み、「失敗したのに脅威なし/正常として続く」かを判定する。"
fi

# ------------------------------------------------- 6. 診断イベントの記録経路
note "6. 診断イベントカタログ(失敗が記録に残るか)"
catalog_covered=0
for target in ${TARGETS[@]+"${TARGETS[@]}"}; do
  [ "$target" != test/config/diagnostic_event_catalog_test.dart ] || catalog_covered=1
done
if [ "$run_tests" -eq 1 ]; then
  echo "  全テストに含まれるため再実行しない。"
elif [ "$run_targeted" -eq 1 ] && [ "$catalog_covered" -eq 1 ]; then
  echo "  指定テストに含まれるため再実行しない。"
elif [ "$run_analyze" -eq 1 ]; then
  # 全テスト未実施時だけ単独で確認する。
  if flutter test test/config/diagnostic_event_catalog_test.dart >/dev/null 2>&1; then
    ok "発報される診断イベントはすべてカタログに載っている"
  else
    ng "カタログとコードが乖離している(記録されない失敗が生まれる)"
  fi
else
  echo "  (スキップ。--analyze で約6秒)"
fi

# ------------------------------------------------------------- 7. 生成物の整合
note "7. 危険区域データと生成物の整合(CIと同じ検査・実測1.4秒)"
bash tool/update_hazard_profile_hash.sh --check >/dev/null 2>&1 &&
  ok "hazard profile のハッシュ一致" || ng "ハッシュ不一致(検証済み状態が外れる)"
dart run tool/generate_hazard_constants.dart --check >/dev/null 2>&1 &&
  ok "生成 allowlist 一致" || ng "生成 allowlist が古い"

note "結果"
if [ "$fail" -eq 0 ]; then
  echo "  機械的な検査は通った。ここから先は人が読む工程(docs/review_guide/quick_review.md の F1〜F6)。"
else
  echo "  NG がある。所見を記録し、修正も許可されている場合だけ修正・再検証する。"
fi
exit "$fail"
