#!/usr/bin/env bash
# 総合レビューの棚卸し。規模・テスト有無・前回レビュー以降の変更を出す。
#
# 使い方(リポジトリ直下で):
#   bash tool/review/inventory.sh            # 規模とテスト有無だけ
#   bash tool/review/inventory.sh 44a762a    # 指定コミットからの変更も出す
#   bash tool/review/inventory.sh 2026-07-27 # 日付でも可
#
# 読み取りのみ。ファイルを書き換えない。

set -uo pipefail

SINCE="${1:-}"

if [ ! -d lib ] || [ ! -f pubspec.yaml ]; then
  echo "リポジトリ直下で実行してください(lib/ と pubspec.yaml が見つかりません)。" >&2
  exit 1
fi

echo "==== 1. 規模 ===="
lib_lines=$(find lib -name '*.dart' -exec cat {} + | wc -l | tr -d ' ')
test_lines=$(find test -name '*.dart' -exec cat {} + | wc -l | tr -d ' ')
echo "lib : $(find lib -name '*.dart' | wc -l | tr -d ' ') ファイル / ${lib_lines} 行"
echo "test: $(find test -name '*.dart' | wc -l | tr -d ' ') ファイル / ${test_lines} 行"
echo
echo "-- ディレクトリ別 --"
find lib -type d | sort | while read -r d; do
  n=$(find "$d" -maxdepth 1 -name '*.dart' | wc -l | tr -d ' ')
  [ "$n" -eq 0 ] && continue
  l=$(find "$d" -maxdepth 1 -name '*.dart' -exec cat {} + | wc -l | tr -d ' ')
  printf '%-40s %3s files %6s lines\n' "$d" "$n" "$l"
done

echo
echo "==== 2. 大きいファイル(上位25・1パスの分割判断に使う) ===="
find lib -name '*.dart' -exec wc -l {} + | sort -rn | grep -v ' total$' | head -25

echo
echo "==== 3. 同名のテストが無い lib ファイル(行数の多い順) ===="
echo "ファイル名での照合にすぎない。「候補」欄に近い名前のテストが出たら、それが実際に"
echo "その責務を検査しているかを読んで確かめること。無条件に「テストが無い」と書かない。"
find lib -name '*.dart' ! -name '*.g.dart' | while read -r f; do
  base=$(basename "$f" .dart)
  # 厳密一致: <base>_test.dart
  if find test -name "${base}_test.dart" | grep -q .; then
    continue
  fi
  # 近い名前: 先頭2トークン(例 ship_domain_service → ship_domain*)
  stem=$(echo "$base" | awk -F_ '{ if (NF >= 2) printf "%s_%s", $1, $2; else printf "%s", $1 }')
  cand=$(find test -name "${stem}*_test.dart" | head -2 | tr '\n' ' ')
  lines=$(wc -l < "$f" | tr -d ' ')
  printf '%6s  %-58s 候補: %s\n' "$lines" "$f" "${cand:-なし}"
done | sort -rn

echo
echo "==== 4. 設定値ファイル(P00 の設定値表の対象) ===="
for f in lib/config/*.dart; do
  total=$(wc -l < "$f" | tr -d ' ')
  # 定数宣言の数と、直前行がコメントでない(=根拠が書かれていない疑い)ものの数
  consts=$(grep -cE '^[[:space:]]*(static )?const ' "$f" || true)
  bare=$(awk '
    /^[[:space:]]*(static )?const /{ if (prev !~ /^[[:space:]]*\/\// && prev !~ /^[[:space:]]*\*/) n++ }
    { prev = $0 }
    END { print n + 0 }' "$f")
  printf '%-46s %4s行  const %3s  直前にコメント無し %3s\n' "$f" "$total" "$consts" "$bare"
done

echo
echo "==== 5. CI が担保している範囲(.github/workflows/ci.yml) ===="
grep -E '^\s+- (name|run):' .github/workflows/ci.yml | sed 's/^ *//'

if [ -n "$SINCE" ]; then
  echo
  echo "==== 6. ${SINCE} 以降に変更された lib/test ファイル ===="
  if git rev-parse --verify "$SINCE" >/dev/null 2>&1; then
    range="$SINCE..HEAD"
    git diff --stat "$range" -- lib test | tail -40
  else
    echo "(コミットとして解決できないため日付として扱います)"
    git log --since="$SINCE" --name-only --pretty=format: -- lib test |
      grep -v '^$' | sort | uniq -c | sort -rn | head -40
  fi
  echo
  echo "-- 上記のうち、前回レビュー時点より 30% 以上増えたファイルは、"
  echo "   前回の到達度をそのまま信用しないこと(use_navigator は 3,189 → 5,330 行に増えた) --"
fi

echo
echo "==== 7. 既存のレビュー記録 ===="
ls -1 docs/review 2>/dev/null | sed 's/^/  docs\/review\//'
ls -1 docs/reviews 2>/dev/null | sed 's/^/  docs\/reviews\//'
ls -1 safety_reviews 2>/dev/null | sed 's/^/  safety_reviews\//'
