#!/usr/bin/env bash
# 「動くか」を機械的に確かめる smoke check。軽量版レビュー(動作確認レビュー)の起点。
#
# 使い方(リポジトリ直下で):
#   bash tool/review/smoke_check.sh            # 既定。CIで担保済みかを見て自動判定
#   bash tool/review/smoke_check.sh --static   # 静的チェックだけ(実測1.3秒)
#   bash tool/review/smoke_check.sh --full     # 必ず解析+テスト全実行(実測108秒)
#
# **アプリのビルドは一切しない。** flutter build / flutter run / Xcode / Gradle は
# このスクリプトも skill も実行しない。実機ビルドと配布は利用者の作業(AGENTS.md)。
#
# ## 既定(auto)がすること
#
# レビュー対象は「現在のワーキングツリー」であって、CI が見たコミットとは限らない。
# そこで**いまの状態が CI に担保されているか**を判定し、担保されていなければ
# 解析(7秒)とテスト全実行(101秒)を走らせる。担保されていれば静的のみで済ませる。
#
#   未コミットの変更がある                       → 走らせる(CIは見ていない)
#   HEAD の CI が success                        → 静的のみ(CIの結果を引用する)
#   HEAD の CI が失敗・未実行・状態を取れない    → 走らせる(不明を担保の根拠にしない)
#
# 「テストが赤い」は、このアプリで最も直接的な「動かない」の証拠なので、
# 100秒はレビュー1回あたりのコストとして払う価値がある。逆に、CI が緑だと
# 分かっているコミットで同じ100秒を払っても新しい情報は増えない。
#
# 読み取りのみ。ファイルを書き換えない。
# ここが全部通っても「動く」証明にはならない。実機・本番Rules・水上は別の証拠(AGENTS.md)。

set -uo pipefail

# auto=CIの担保状況で決める / static=静的のみ / full=必ず解析+テスト
MODE=auto
case "${1:-}" in
  --full) MODE=full ;;
  --static | --fast) MODE=static ;;  # --fast は旧引数の互換
  --analyze) MODE=analyze ;;
  "") MODE=auto ;;
  *) echo "不明な引数: $1(--static / --analyze / --full のみ)" >&2; exit 1 ;;
esac

if [ ! -f pubspec.yaml ]; then
  echo "リポジトリ直下で実行してください。" >&2
  exit 1
fi

fail=0
note() { printf '\n==== %s ====\n' "$1"; }
ng() { printf '  [NG] %s\n' "$1"; fail=1; }
ok() { printf '  [OK] %s\n' "$1"; }

# ------------------------------------------------- 0. いまの状態はCIに担保されているか
ci_verdict=""   # covered / uncovered
ci_reason=""
if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
  ci_verdict=uncovered; ci_reason="未コミットの変更があり、この状態でCIは走っていない"
elif ! command -v gh >/dev/null 2>&1; then
  ci_verdict=uncovered; ci_reason="gh が無く、HEAD のCI結果を確認できない"
else
  # --commit は完全なSHAでないと一致しない(短縮SHAだと常に0件になる)。
  head_sha=$(git rev-parse HEAD 2>/dev/null)
  run=$(gh run list --commit "$head_sha" --workflow ci.yml --limit 1 \
    --json status,conclusion --jq '.[0] | "\(.status)/\(.conclusion)"' 2>/dev/null)
  case "$run" in
    completed/success) ci_verdict=covered; ci_reason="HEAD(${head_sha:0:7})のCIが success" ;;
    "") ci_verdict=uncovered; ci_reason="HEAD(${head_sha:0:7})でCIの実行が見つからない" ;;
    */"") ci_verdict=uncovered; ci_reason="HEAD(${head_sha:0:7})のCIが実行中(${run%/*})" ;;
    *) ci_verdict=uncovered; ci_reason="HEAD(${head_sha:0:7})のCIが ${run#*/}" ;;
  esac
fi

case "$MODE" in
  full) run_analyze=1; run_tests=1; decision="--full の指定" ;;
  analyze) run_analyze=1; run_tests=0; decision="--analyze の指定" ;;
  static) run_analyze=0; run_tests=0; decision="--static の指定" ;;
  *)
    if [ "$ci_verdict" = covered ]; then
      run_analyze=0; run_tests=0; decision="CIで担保済み($ci_reason)"
    else
      run_analyze=1; run_tests=1; decision="CI未担保($ci_reason)"
    fi ;;
esac

# ---------------------------------------------------------------- 1. 解析とテスト
note "1-2. 解析とテスト"
echo "  判断: $decision"
if [ "$run_analyze" -eq 1 ]; then
  # flutter analyze は日本語パスで必ずクラッシュするため使わない(CLAUDE.md)。
  if dart analyze lib test tool; then ok "解析エラーなし"; else ng "解析エラーあり"; fi
else
  echo "  (解析はスキップ。--analyze で約7秒)"
fi
if [ "$run_tests" -eq 1 ]; then
  echo "  flutter test を実行する(全149本・約101秒)..."
  if flutter test; then ok "テスト全緑"; else ng "テスト失敗あり"; fi
elif [ "$ci_verdict" = covered ]; then
  ok "テストはCIの結果を引用($ci_reason)"
else
  echo "  (テスト全実行はスキップ。--full で約101秒)"
  echo "  レビュー中の範囲だけなら: flutter test test/services/<対象>_test.dart"
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
if [ "$run_analyze" -eq 1 ]; then
  # テスト1本だけ(実測6秒)。
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
  echo "  NG がある。まずそこを潰してからレビューを進めること。"
fi
exit 0
