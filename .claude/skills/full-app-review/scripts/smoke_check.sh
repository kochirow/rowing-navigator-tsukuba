#!/usr/bin/env bash
# 「動くか」を機械的に確かめる smoke check。軽量版レビュー(動作確認レビュー)の起点。
#
# 使い方(リポジトリ直下で):
#   bash .claude/skills/full-app-review/scripts/smoke_check.sh            # 既定。静的チェックのみ(実測0.4秒)
#   bash .claude/skills/full-app-review/scripts/smoke_check.sh --analyze  # + dart analyze(実測7秒)
#   bash .claude/skills/full-app-review/scripts/smoke_check.sh --full     # + flutter test 全実行(実測101秒)
#
# **アプリのビルドは一切しない。** flutter build / flutter run / Xcode / Gradle は
# このスクリプトも skill も実行しない。実機ビルドと配布は利用者の作業(AGENTS.md)。
#
# 既定でテストを流さないのは、`flutter analyze` / `flutter test` を PR で必ず通すのが
# CI の役割だからである(.github/workflows/ci.yml)。CI が担保している層をローカルで
# 繰り返さず、CI が見られない層に時間を使う、というのがこの skill の方針。
# ローカルで走らせるときは、レビュー中の範囲のテストファイルだけを指定するほうが速い。
#
# 読み取りのみ。ファイルを書き換えない。
# ここが全部通っても「動く」証明にはならない。実機・本番Rules・水上は別の証拠(AGENTS.md)。

set -uo pipefail

# 0=静的のみ / 1=解析まで / 2=テストまで
LEVEL=0
case "${1:-}" in
  --analyze) LEVEL=1 ;;
  --full) LEVEL=2 ;;
  --fast | "") LEVEL=0 ;;  # --fast は既定と同じ(旧引数の互換)
  *) echo "不明な引数: $1(--analyze / --full のみ)" >&2; exit 1 ;;
esac

if [ ! -f pubspec.yaml ]; then
  echo "リポジトリ直下で実行してください。" >&2
  exit 1
fi

fail=0
note() { printf '\n==== %s ====\n' "$1"; }
ng() { printf '  [NG] %s\n' "$1"; fail=1; }
ok() { printf '  [OK] %s\n' "$1"; }

# ---------------------------------------------------------------- 1. 解析とテスト
note "1-2. 解析とテスト"
if [ "$LEVEL" -ge 1 ]; then
  # flutter analyze は日本語パスで必ずクラッシュするため使わない(CLAUDE.md)。
  if dart analyze lib test tool; then ok "解析エラーなし"; else ng "解析エラーあり"; fi
else
  echo "  (既定ではスキップ。--analyze で約7秒)"
fi
if [ "$LEVEL" -ge 2 ]; then
  if flutter test; then ok "テスト全緑"; else ng "テスト失敗あり"; fi
else
  echo "  (テスト全実行は既定ではスキップ。--full で約101秒、PRでは CI が必ず実行する)"
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
if [ "$LEVEL" -ge 1 ]; then
  # テスト1本だけ(実測6秒)。全実行はしない。
  if flutter test test/config/diagnostic_event_catalog_test.dart >/dev/null 2>&1; then
    ok "発報される診断イベントはすべてカタログに載っている"
  else
    ng "カタログとコードが乖離している(記録されない失敗が生まれる)"
  fi
else
  echo "  (既定ではスキップ。--analyze で約6秒)"
fi

# ------------------------------------------------------------- 7. 生成物の整合
note "7. 危険区域データと生成物の整合(CIと同じ検査・実測1.4秒)"
bash tool/update_hazard_profile_hash.sh --check >/dev/null 2>&1 &&
  ok "hazard profile のハッシュ一致" || ng "ハッシュ不一致(検証済み状態が外れる)"
dart run tool/generate_hazard_constants.dart --check >/dev/null 2>&1 &&
  ok "生成 allowlist 一致" || ng "生成 allowlist が古い"

note "結果"
if [ "$fail" -eq 0 ]; then
  echo "  機械的な検査は通った。ここから先は人が読む工程(軽量版_動作確認レビュー.md の F1〜F6)。"
else
  echo "  NG がある。まずそこを潰してからレビューを進めること。"
fi
exit 0
