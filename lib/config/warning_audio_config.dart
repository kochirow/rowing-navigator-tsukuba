import 'package:audioplayers/audioplayers.dart';

import '../models/static_obstacle_model.dart';

// =====================================================
// 警告対象ごとの音声アセット
// -----------------------------------------------------
// **すべて「何に当たりそうか」を言葉で告げる読み上げ音声**である
// (VOICEVOX / ずんだもん、2026-07-27)。単なるアラート音では、
// 鳴っていることは分かっても何を避ければいいのか分からない。
//
// 危険区域JSONの warningAudio で区域ごとに上書きできるため、
// 同じ種類でも個別音声へ差し替え可能。
//
// ## アセットを追加・差し替えるときの手順
//
// 1. WAV マスターを `tool/audio_src/` へ置く(assets/ を直接編集しない)
// 2. `./tool/normalize_warning_audio.sh` で `assets/audio/` を生成する
// 3. `./tool/check_warning_audio.sh` で音圧が揃っていることを確認する
//
// **音圧を揃えるのは音質の問題ではなく安全の問題である。**
// 端末のボリュームは1つしかないので、ファイル間で音圧が違うと
// 「読み上げが聞こえる音量にするとアラート音が耳をつんざく」状態になり、
// どちらかが必ず犠牲になる。聞こえない警告は警告漏れと同じ。
//
// ## 音声の長さとループ
//
// 各ファイルは語句を1回読み上げるだけの 0.5〜1.4 秒。衝突警告は鳴っている間
// 繰り返し(ループ)、カーブ・逆走は区域内で間をあけて読み直す。切迫度は鳴り方では
// なく**鳴り始めの早さ**で表す(2026-10-23 に警告音を1種類にした。CLAUDE.md「提示ポリシー」)。
// 同じ音声を使い回すので、緊急版のような別録りは持たない。
// 末尾の 0.15 秒の無音がループ時の語句どうしの間隔になる。

/// プラットフォーム音声呼び出し1回の上限。
///
/// 実機ログ(2026-07-28)では stop → setSource の間で無限待ちが発生した。
/// 読み上げは1秒前後なので、3秒を超える応答は異常である。タイムアウトは
/// 再生経路だけを縮退させ、警告候補・表示・runModeを止める理由にしない。
const alertPlatformCallTimeout = Duration(seconds: 3);

/// この回数だけ連続でプラットフォーム呼び出しがタイムアウトしたら、
/// その [AudioPlayer] を捨てて作り直す。
///
/// timeout後も古いネイティブ呼び出し自体は裏で残る可能性があるため、
/// 同じインスタンスを使い続けない。値は実機ログの再現性を確認しながら
/// 調整する設定値である。
const alertPlayerRecreateFailureThreshold = 2;

/// 他艇接近の読み上げ。「他艇に注意」
const otherBoatWarningAudioAsset = 'audio/other_boat_warning.mp3';

/// 種類の分からない危険区域の読み上げ。「危険区域に注意」
const genericWarningAudioAsset = 'audio/generic_warning.mp3';

/// 監視者向けの異常通知音。
///
/// 航行中のsystem faultには使わない。GPS・通信・評価停止は
/// すべて画面表示だけとし、物理的な衝突警告の聞き取りを妨げない。
const systemFaultWarningAudioAsset = 'audio/system_fault_warning.mp3';

/// 監視(コーチ)機能の異常通知音。既定では鳴らない
/// (`coachAudibleAnomalyKindNames` が空のため)。
///
/// **[genericWarningAudioAsset] を流用しないこと。** かつては両方とも
/// 意味を持たないアラート音だったので流用できたが、いまは
/// 「危険区域に注意」という自艇の衝突警告の読み上げである。
/// 岸で画面を見ている監視者に、自分が危険区域へ近づいていると
/// 告げることになり、意味が食い違う。
///
/// 監視の異常(沈・電池切れ・更新途絶)は自艇の衝突とは別系統なので、
/// 意味を持たない通知音を使う。監視者は画面を見られる状況にいるため、
/// 「アプリを見ろ」と伝われば足りる。
///
/// TODO(audio): 読み上げにするなら「艇に異常」など監視専用の文言を
/// 別アセットとして用意する。衝突警告の文言は流用しない。
const coachAnomalyAlertAudioAsset = systemFaultWarningAudioAsset;

/// 起動時に事前ロードし、`assets/audio/` の実在を検証する対象。
/// `use_alert` の初期化(`AudioCache.instance.loadAll`)と、
/// `use_navigator` の診断イベントが参照する。
const warningAudioAssets = <String>[
  otherBoatWarningAudioAsset,
  genericWarningAudioAsset,
  'audio/shore_warning.mp3',
  'audio/bridge_warning.mp3',
  'audio/bridge_pier_warning.mp3',
  'audio/island_warning.mp3',
  'audio/driftwood_warning.mp3',
  'audio/pile_warning.mp3',
  'audio/curve_warning.mp3',
  'audio/reverse_warning.mp3',
  'audio/test_warning.mp3',
];

// ## 同梱しているが、いまは鳴らさない音声
//
// `assets/audio/` の次の5本は、どのコードからも再生しない(上の一覧にも入れない)。
// 旧アプリから移植した音で、「将来使うので残す」という利用者の判断
// (2026-07-27 全体レビュー P07)で同梱したままにしている。
//
// - `add_warning.mp3`(以前は監視の異常で鳴らしていた。いまは監視は既定で無音)
// - `alert_beep.mp3` / `alert_high_tempo.mp3` / `alert_low_tempo.mp3`(読み上げ以前のビープ音)
// - `proximity_warning.mp3`(名前に反して、近接注意では鳴らない。近接注意は
//   kind ごとの読み上げ([defaultWarningAudioAssetFor])を使う)
//
// `tool/check_warning_audio.sh` は全 mp3 の音圧の揃いを検査するので、
// 使っていないこの5本も、鳴っている音の音圧の幅を縛っている。
// 使うと決めたら上の一覧へ足し、使わないと決めたら `tool/audio_src/` の原本ごと消す。

/// 航行警告の音声セッション設定。
///
/// iOS では [AudioContextConfigFocus.mixWithOthers] が `mixWithOthers` を
/// 有効にする。Buddycom などの通話音声を下げたり止めたりせず、その上から
/// 警告音を鳴らす。iOS のロック中再生は Info.plist の `audio` background
/// mode で許可し、Android でも他アプリの音声フォーカスを奪わない。
AudioContextConfig createWarningAudioContextConfig() {
  return AudioContextConfig(
    // 警告音はiPhoneのサイレントスイッチ中も必要である。
    respectSilence: false,
    // Androidでは、画面ロック中も再生を継続できるようにする。
    // iOSではInfo.plistのUIBackgroundModes/audioを併用する。
    stayAwake: true,
    // gain/duckOthers は通話音声を妨げうるため使用しない。
    focus: AudioContextConfigFocus.mixWithOthers,
  );
}

String defaultWarningAudioAssetFor(StaticObstacleKind? kind) {
  switch (kind) {
    case StaticObstacleKind.shore:
      return 'audio/shore_warning.mp3';
    case StaticObstacleKind.bridge:
      return 'audio/bridge_warning.mp3';
    case StaticObstacleKind.bridgePier:
      return 'audio/bridge_pier_warning.mp3';
    case StaticObstacleKind.island:
      return 'audio/island_warning.mp3';
    case StaticObstacleKind.driftwood:
      return 'audio/driftwood_warning.mp3';
    case StaticObstacleKind.pile:
      return 'audio/pile_warning.mp3';
    case StaticObstacleKind.curve:
      return 'audio/curve_warning.mp3';
    case StaticObstacleKind.reverse:
      return 'audio/reverse_warning.mp3';
    case StaticObstacleKind.testZone:
      return 'audio/test_warning.mp3';
    case StaticObstacleKind.generic:
    case null:
      return genericWarningAudioAsset;
  }
}

/// 端末の出力音量がこれを下回ったら「小さい」とみなす [0.0〜1.0]。
///
/// 2026-08-06 実機ログ: 8+ に載せた1台が全期間 0.30 固定だった
/// (他3台は 1.00)。読み上げが実際に聞こえたかはログからは判定できないが、
/// `audio_route_snapshot.outputVolume` は毎回取れている。
///
/// **画面へ出すだけにする。** 音量が小さいことを音で知らせるのは矛盾している。
/// 閾値は暫定で、実機で聞こえ方を確認できたら調整する。
const audioLowOutputVolumeThreshold = 0.5;

/// アプリ内の警告音量 [0.0〜1.0]。実際の音量は「端末の音量 × これ」になる。
///
/// ## 何のためか
///
/// トランシーバー(Buddycom など)と同じ端末で使うとき、トランシーバーは
/// 大きく、このアプリは少し小さく聞きたいことがある(2026-10-24 利用者要望)。
/// 端末の音量は1つしかないので、アプリの側で絞れるようにする。
/// 音声セッションは `mixWithOthers` なので、ここを下げてもトランシーバーの
/// 音量は変わらない。
///
/// ## 上限は 100%(既定)
///
/// 100% を超えて大きくはできない。音源は歪まずに出せる上限
/// (-10 LUFS・ピーク 0.89)まで既に上げてあり(`tool/normalize_warning_audio.sh`)、
/// 再生側(iOS の AVPlayer・Android の MediaPlayer)の音量も 1.0 が上限である。
/// 音源を持ち上げてもリミッタで潰れて聞き取りにくくなるだけで、大きくはならない。
///
/// ## 下限は 30%(0 にはしない)
///
/// このスライダーは、トランシーバーなど他の音との**聞き分けの調整**である。警告を
/// 消したい人は端末の音量で消せる(警告を切って使うのも正当な使い方。DESIGN_PRINCIPLES 原則2)
/// ので、警告を止めさせないために下限を置いているのではない。下限は、聞き分けの調整の
/// つもりで下げた結果、屋外で聞こえない音量になってしまうことを避けるためにある。
/// 30% は 2026-08-06 の実機で端末音量 0.30 のまま運用されていた例と同じ水準で、
/// 屋外で聞こえるかどうかの境目として選んだ暫定値。実機で聞こえ方を確かめて調整する。
/// 全ファイルに同じ倍率がかかるので、ファイル間の音圧の揃い(2.5 LU 以内)は崩れない。
///
/// 端末ごとの設定で、艇どうしで共有しない(端末の置き場所も、トランシーバーとの
/// 兼ね合いも端末ごとに違う)。
const warningAudioAppVolumeMin = 0.3;
const warningAudioAppVolumeMax = 1.0;
const warningAudioAppVolumeDefault = 1.0;

/// 音量の刻み。スライダーの目盛と保存値の丸めに使う。
const warningAudioAppVolumeStep = 0.1;

/// 保存値・入力値を設定範囲と刻みへ収める。
///
/// 範囲外は端へ寄せ、壊れた値(null・NaN)は既定(100%)へ戻す。
/// 壊れた値を下限へ倒さないのは、聞こえない警告は警告漏れと同じだから。
double normalizeWarningAudioAppVolume(double? value) {
  if (value == null || !value.isFinite) return warningAudioAppVolumeDefault;
  final clamped = value
      .clamp(warningAudioAppVolumeMin, warningAudioAppVolumeMax)
      .toDouble();
  final steps = (clamped / warningAudioAppVolumeStep).round();
  // 0.1 刻みの浮動小数誤差(0.30000000000000004 など)を保存値に残さない。
  return double.parse((steps * warningAudioAppVolumeStep).toStringAsFixed(2));
}
