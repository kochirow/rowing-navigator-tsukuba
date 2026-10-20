# Xcode の "Run Script"(xcode_backend.sh build)から `.` で読み込む。
#
# Xcode の Archive / Run は `flutter build` を経由しないため、
# `tool/flutter_with_provenance.sh` を使わないと Git SHA が `unknown` の
# まま配布される(2026-09-26 の実機ログで実際に起きた)。ここで
# DART_DEFINES へ足しておけば、どの経路でビルドしても診断ZIPから
# 「どのコードの挙動か」を確定できる。
#
# DART_DEFINES は `KEY=VALUE` を base64 にしてカンマで繋いだ文字列。
# すでに同じキーがある(flutter_with_provenance.sh 経由)なら上書きしない。
# git が無い・リポジトリ外でも失敗させない(ビルドを止めない)。

_rn_has_define() {
  _rn_key="$1"
  _rn_old_ifs="$IFS"
  IFS=','
  for _rn_encoded in ${DART_DEFINES:-}; do
    _rn_decoded="$(printf '%s' "$_rn_encoded" | base64 --decode 2>/dev/null || true)"
    case "$_rn_decoded" in
      "$_rn_key="*)
        IFS="$_rn_old_ifs"
        return 0
        ;;
    esac
  done
  IFS="$_rn_old_ifs"
  return 1
}

_rn_append_define() {
  _rn_encoded="$(printf '%s=%s' "$1" "$2" | base64 | tr -d '\n')"
  if [ -n "${DART_DEFINES:-}" ]; then
    DART_DEFINES="${DART_DEFINES},${_rn_encoded}"
  else
    DART_DEFINES="${_rn_encoded}"
  fi
}

_rn_repo_root="${SRCROOT:-.}/.."
if ! _rn_has_define GIT_COMMIT_SHA; then
  _rn_sha="$(git -C "$_rn_repo_root" rev-parse --verify HEAD 2>/dev/null || true)"
  if [ -n "$_rn_sha" ]; then
    _rn_append_define GIT_COMMIT_SHA "$_rn_sha"
  else
    echo "warning: Git SHA を取得できませんでした。診断ログの gitCommitSha は unknown になります。"
  fi
fi
if ! _rn_has_define BUILD_TIMESTAMP_UTC; then
  _rn_append_define BUILD_TIMESTAMP_UTC "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
fi
if ! _rn_has_define BUILD_FLAVOR; then
  _rn_append_define BUILD_FLAVOR "xcode-${CONFIGURATION:-unknown}"
fi
export DART_DEFINES
