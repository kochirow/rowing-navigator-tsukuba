#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
git_sha="$(git -C "$repo_root" rev-parse --verify HEAD)"
build_timestamp_utc="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
build_flavor="default"

arguments=("$@")
for ((index = 1; index <= ${#arguments}; index++)); do
  argument="${arguments[$index]}"
  if [[ "$argument" == "--flavor" && $index -lt ${#arguments} ]]; then
    build_flavor="${arguments[$((index + 1))]}"
  elif [[ "$argument" == --flavor=* ]]; then
    build_flavor="${argument#--flavor=}"
  fi
done

exec flutter "$@" \
  "--dart-define=GIT_COMMIT_SHA=$git_sha" \
  "--dart-define=BUILD_TIMESTAMP_UTC=$build_timestamp_utc" \
  "--dart-define=BUILD_FLAVOR=$build_flavor"
