#!/usr/bin/env bash
#
# 同梱する警告音アセットの音圧が揃っているかを検証する。
#
# ## 何を守っているか
#
# **ファイル間の音圧差**である。絶対値ではない。
# 端末のボリュームは利用者が1つのつまみで決めるので、
# ファイルごとに音圧が違うと「読み上げが聞こえる音量にすると
# アラート音が耳をつんざく」状態になり、どちらかが必ず犠牲になる。
# 実測(2026-07-27)では最大 23.3 LU(体感でおよそ5倍)の差があった。
#
# **聞こえない警告は警告漏れと同じ**(CLAUDE.md 安全方針)なので、
# これは音質の問題ではなく安全の問題として扱う。
#
# ## 使い方
#
#   ./tool/check_warning_audio.sh
#
# assets/audio/ の mp3 を直接編集したり、正規化を通さないファイルを
# 足したりすると、ここで落ちる。直し方は normalize_warning_audio.sh を
# 実行すること(マスターは tool/audio_src/*.wav)。

set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly AUDIO_DIR="${REPO_ROOT}/assets/audio"
readonly SRC_DIR="${REPO_ROOT}/tool/audio_src"

# ファイル間で許容する最大の音圧差 [LU]。
#
# 1 LU は実用上ほぼ知覚できない。2 LU はわずかに分かる程度で、
# 「片方が聞こえない」には至らない。ここを超えたら揃え直す。
readonly MAX_SPREAD_LU=2.5

# 絶対値の許容範囲 [LUFS]。正気度チェック。
# 屋外で聞かせるので配信規格(-14〜-16)より大きく、
# 音声が潰れない上限(-8 付近)より小さいこと。
readonly MIN_LUFS=-13.0
readonly MAX_LUFS=-8.0

for cmd in ffmpeg python3; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "エラー: ${cmd} が見つかりません。" >&2
    exit 1
  fi
done

measure_lufs() {
  ffmpeg -hide_banner -nostats -i "$1" -filter_complex ebur128 -f null - 2>&1 |
    grep -A2 'Integrated loudness' | grep 'I:' | tail -1 |
    sed -E 's/.*I: *(-?[0-9.]+).*/\1/'
}

status=0

# --- 1. マスターの欠落を検出する ---------------------------------
# assets 側にしか無いファイルは、正規化を通っていないか、
# マスターを消してしまったかのどちらか。次に走らせたとき消える。
while IFS= read -r -d '' mp3; do
  name="$(basename "${mp3}" .mp3)"
  if [[ ! -f "${SRC_DIR}/${name}.wav" ]]; then
    echo "エラー: マスターがありません: tool/audio_src/${name}.wav" >&2
    echo "  assets/audio/${name}.mp3 は正規化を通っていない可能性があります。" >&2
    status=1
  fi
done < <(find "${AUDIO_DIR}" -maxdepth 1 -name '*.mp3' -print0)

# --- 2. 音圧を測る -----------------------------------------------
printf '%-30s %12s\n' 'ファイル' 'LUFS'
printf '%s\n' '-------------------------------------------'

values=()
while IFS= read -r -d '' mp3; do
  name="$(basename "${mp3}")"
  lufs="$(measure_lufs "${mp3}")"
  if [[ -z "${lufs}" ]]; then
    echo "エラー: ${name} のラウドネスを測れません(無音の可能性)。" >&2
    status=1
    continue
  fi
  printf '%-30s %12s\n' "${name}" "${lufs}"
  values+=("${lufs}")

  if ! python3 -c "import sys; sys.exit(0 if ${MIN_LUFS} <= ${lufs} <= ${MAX_LUFS} else 1)"; then
    echo "エラー: ${name} が許容範囲外です (${MIN_LUFS} 〜 ${MAX_LUFS} LUFS)" >&2
    status=1
  fi
done < <(find "${AUDIO_DIR}" -maxdepth 1 -name '*.mp3' -print0 | sort -z)

if [[ ${#values[@]} -eq 0 ]]; then
  echo "エラー: assets/audio/ に mp3 がありません。" >&2
  exit 1
fi

# --- 3. ファイル間の差を検証する(本命) --------------------------
spread="$(python3 -c "
vals = [float(v) for v in '''${values[*]}'''.split()]
print(round(max(vals) - min(vals), 2))
")"

printf '\nファイル間の差: %s LU (上限 %s LU)\n' "${spread}" "${MAX_SPREAD_LU}"

if ! python3 -c "import sys; sys.exit(0 if ${spread} <= ${MAX_SPREAD_LU} else 1)"; then
  echo "エラー: 音圧が揃っていません。" >&2
  echo "  ./tool/normalize_warning_audio.sh を実行してください。" >&2
  status=1
fi

if [[ ${status} -eq 0 ]]; then
  echo "OK: 警告音の音圧は揃っています。"
fi
exit "${status}"
