#!/usr/bin/env bash
#
# 警告音アセットのラウドネスを揃えて assets/audio/ を生成する。
#
# ## なぜ必要か
#
# 生成元がバラバラだと音圧が揃わない。実測(2026-07-27)では、
# 録音アラート音が -2.4 LUFS、macOS say の読み上げが -25.7 LUFS で、
# その差 23.3 LU(体感でおよそ5倍)。読み上げが聞こえる音量まで上げると
# アラート音が耳をつんざき、アラート音に合わせると読み上げが聞こえない。
# **聞こえない警告は警告漏れと同じ**である(CLAUDE.md 安全方針)。
#
# ## 入力と出力
#
#   tool/audio_src/*.wav  (マスター。非可逆圧縮を経ていない原本)
#     → assets/audio/*.mp3 (アプリが同梱する成果物)
#
# **assets/audio/ の mp3 を直接編集しないこと。** ここを入力にすると
# 実行のたびに mp3 の世代劣化が重なる。新しい音を足すときは、
# WAV をマスターとして tool/audio_src/ へ置いてから実行する。
#
# ## 処理内容
#
# 1. 前後の無音を落とし、末尾に一定長の無音を付け直す
#    → ループ再生(imminent の連続音)の間隔をファイル間で揃えるため。
#      VOICEVOX は前後に 0.07〜0.15 秒の無音を付けるので、そのままだと
#      ファイルごとにループの間隔がばらつく。
# 2. 140Hz 以下を落とす
#    → スマホスピーカーが再生できない帯域。残すとリミッタの余裕を食うだけ。
# 3. 2.8kHz を持ち上げる
#    → 明瞭度と小型スピーカーの効率がいちばん高い帯域。
# 4. 圧縮してから、目標ラウドネスへ合わせてリミッタを通す
#    → 音声は波高率が高く、単純なゲインでは目標へ届かない。
#
# ## 使い方
#
#   ./tool/normalize_warning_audio.sh          # 全ファイル
#   ./tool/normalize_warning_audio.sh curve_warning shore_warning
#
# 実行後は必ず ./tool/check_warning_audio.sh で検証する。

set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly SRC_DIR="${REPO_ROOT}/tool/audio_src"
readonly OUT_DIR="${REPO_ROOT}/assets/audio"

# 目標統合ラウドネス [LUFS]。
#
# 配信規格(-14〜-16)より意図的に大きい。屋外・風・水音の下で聞かせる
# 用途だからである。一方これ以上(-8 以上)を狙うと、音声はリミッタで
# 潰れて逆に聞き取りにくくなる。実測で音声が破綻せず届く上限がここ。
readonly TARGET_LUFS=-10

# トゥルーピークの上限。mp3 のデコード時に発生するオーバーシュートぶんの
# 余裕を残す。0dBFS まで詰めると端末側で歪む。
readonly LIMITER_CEILING=0.89

# 末尾に付け直す無音の長さ [秒]。
#
# ループ再生時の語句どうしの間隔になる。0 にすると語尾と語頭が
# つながって聞き取れない。長くすると連続音の切迫感が落ちる。
readonly TAIL_SILENCE_SEC=0.15

# 無音とみなすしきい値。これより小さい音を前後から削る。
# 語頭の子音を削らないよう、低めに取る。
readonly SILENCE_THRESHOLD_DB=-50

readonly SAMPLE_RATE=44100
readonly BITRATE=128k

# 目標ラウドネスへ寄せる反復回数。
#
# リミッタはラウドネスを下げるため、ゲインを1回当てるだけでは届かない。
# 6回でほぼ収束する。**音声は目標へ完全には届かない**(実測 -11 前後)。
# 波高率が高く、これ以上ゲインを足してもリミッタが削るだけだからである。
# 揃えたいのは絶対値ではなくファイル間の差なので、これで足りる。
# 実効レンジの検証は check_warning_audio.sh が行う。
readonly GAIN_ITERATIONS=6

for cmd in ffmpeg ffprobe python3; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "エラー: ${cmd} が見つかりません。" >&2
    echo "  brew install ffmpeg" >&2
    exit 1
  fi
done

if [[ ! -d "${SRC_DIR}" ]]; then
  echo "エラー: マスター置き場がありません: ${SRC_DIR}" >&2
  exit 1
fi

mkdir -p "${OUT_DIR}"

readonly WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

# 統合ラウドネスを測る。無音しか無い場合は空文字を返す。
measure_lufs() {
  ffmpeg -hide_banner -nostats -i "$1" -filter_complex ebur128 -f null - 2>&1 |
    grep -A2 'Integrated loudness' | grep 'I:' | tail -1 |
    sed -E 's/.*I: *(-?[0-9.]+).*/\1/'
}

# 前処理: 無音除去 → 高域通過 → プレゼンス補正 → 圧縮 → リサンプル。
# ここではまだ音量を合わせない(合わせるのは反復ゲイン側)。
readonly PREFILTER="\
silenceremove=start_periods=1:start_silence=0.02:start_threshold=${SILENCE_THRESHOLD_DB}dB,\
areverse,\
silenceremove=start_periods=1:start_silence=0.02:start_threshold=${SILENCE_THRESHOLD_DB}dB,\
areverse,\
highpass=f=140,\
equalizer=f=2800:t=q:w=1.2:g=4,\
acompressor=threshold=-20dB:ratio=3:attack=5:release=120:makeup=4,\
aresample=${SAMPLE_RATE}"

targets=()
if [[ $# -gt 0 ]]; then
  for name in "$@"; do
    src="${SRC_DIR}/${name%.wav}.wav"
    if [[ ! -f "${src}" ]]; then
      echo "エラー: マスターがありません: ${src}" >&2
      exit 1
    fi
    targets+=("${src}")
  done
else
  while IFS= read -r -d '' src; do
    targets+=("${src}")
  done < <(find "${SRC_DIR}" -maxdepth 1 -name '*.wav' -print0 | sort -z)
fi

if [[ ${#targets[@]} -eq 0 ]]; then
  echo "エラー: 処理対象の WAV がありません: ${SRC_DIR}" >&2
  exit 1
fi

printf '目標 %s LUFS / ピーク上限 %s / 末尾無音 %ss\n\n' \
  "${TARGET_LUFS}" "${LIMITER_CEILING}" "${TAIL_SILENCE_SEC}"
printf '%-28s %10s %10s %10s\n' 'ファイル' '処理前' 'ゲイン' '処理後'
printf '%s\n' '--------------------------------------------------------------'

failed=0
for src in "${targets[@]}"; do
  name="$(basename "${src}" .wav)"
  staged="${WORK_DIR}/${name}.stage.wav"
  probe="${WORK_DIR}/${name}.probe.wav"
  out="${OUT_DIR}/${name}.mp3"

  before="$(measure_lufs "${src}")"
  if [[ -z "${before}" ]]; then
    echo "警告: ${name} のラウドネスを測れません。無音の可能性があります。" >&2
    failed=1
    continue
  fi

  ffmpeg -y -hide_banner -loglevel error -i "${src}" \
    -af "${PREFILTER}" -ac 1 -ar "${SAMPLE_RATE}" "${staged}"

  # リミッタ込みで目標へ寄せる。1回では届かないので反復する。
  gain=0
  for _ in $(seq "${GAIN_ITERATIONS}"); do
    ffmpeg -y -hide_banner -loglevel error -i "${staged}" \
      -af "volume=${gain}dB,alimiter=limit=${LIMITER_CEILING}:level=disabled" \
      "${probe}"
    measured="$(measure_lufs "${probe}")"
    gain="$(python3 -c "print(round(${gain} + ${TARGET_LUFS} - (${measured}), 2))")"
  done

  # 確定したゲインで書き出し、末尾に一定長の無音を付ける。
  ffmpeg -y -hide_banner -loglevel error -i "${staged}" \
    -af "volume=${gain}dB,alimiter=limit=${LIMITER_CEILING}:level=disabled,apad=pad_dur=${TAIL_SILENCE_SEC}" \
    -ac 1 -ar "${SAMPLE_RATE}" -b:a "${BITRATE}" "${out}"

  after="$(measure_lufs "${out}")"
  printf '%-28s %10s %10s %10s\n' "${name}.mp3" "${before}" "${gain}" "${after}"
done

printf '\n出力先: %s\n' "${OUT_DIR}"
printf '検証: ./tool/check_warning_audio.sh\n'
exit "${failed}"
