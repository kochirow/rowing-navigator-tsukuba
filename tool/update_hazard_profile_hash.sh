#!/usr/bin/env bash
# 危険区域プリセット(assets/data/sakuragawa_obstacles.json)を編集したあと、
# lib/config/hazard_profile_config.dart の SHA-256 を実ファイルに合わせる。
#
# 使い方:
#   tool/update_hazard_profile_hash.sh          # 差分があれば書き換える
#   tool/update_hazard_profile_hash.sh --check  # 書き換えず、一致するかだけ確認(CI用)
#
# checksum が合わなくても航行機能は停止しない(同梱形状をそのまま使う)。
# ただし「検証済み」表示が外れ、診断ログに hazard_profile_unverified が残るため、
# データを更新したら必ずこのスクリプトを実行すること。
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
profile="$repo_root/assets/data/sakuragawa_obstacles.json"
config="$repo_root/lib/config/hazard_profile_config.dart"

check_only=0
if [[ "${1:-}" == "--check" ]]; then
  check_only=1
fi

for path in "$profile" "$config"; do
  if [[ ! -f "$path" ]]; then
    echo "error: not found: $path" >&2
    exit 1
  fi
done

actual="$(shasum -a 256 "$profile" | awk '{print $1}')"
expected="$(grep -oE "'[0-9a-f]{64}'" "$config" | head -1 | tr -d "'")"

if [[ -z "$expected" ]]; then
  echo "error: could not find a sha256 literal in $config" >&2
  exit 1
fi

if [[ "$actual" == "$expected" ]]; then
  echo "hazard profile hash is up to date ($actual)"
  exit 0
fi

if [[ "$check_only" -eq 1 ]]; then
  cat >&2 <<EOF
error: hazard profile hash is stale.
  expected (hazard_profile_config.dart): $expected
  actual   (sakuragawa_obstacles.json):  $actual
Run: tool/update_hazard_profile_hash.sh
EOF
  exit 1
fi

# BSD sed (macOS) と GNU sed の両方で動くよう -i の引数を分ける。
if sed --version >/dev/null 2>&1; then
  sed -i "s/$expected/$actual/" "$config"
else
  sed -i '' "s/$expected/$actual/" "$config"
fi

echo "updated hazard profile hash:"
echo "  from $expected"
echo "  to   $actual"
echo "Remember to bump currentHazardProfileDataVersion when hazard geometry"
echo "changes meaning, because coordinate calibrations are dropped on a"
echo "version mismatch (see HazardProfileIntegrity)."
