/// 警告判定そのものを変えず、画面表示と音声の段階だけを決める設定。
///
/// **設計の要点: 2つの軸を分離する。**
///
/// - 内部レベル(lv0〜3)は「どれだけまずいか」= 停止距離内か・確度。
///   表示色・優先順位・ログにだけ使い、音の鳴り方には使わない。
/// - 音の鳴り方は「どれだけ切迫しているか」= 到達までの時間だけで決める。
///
/// 以前は lv2 が必ず単発音1回、lv3 でも到達3秒超なら単発音という具合に
/// 2軸が混線しており、「レベル」と「音」の対応が直感と合わなかった。
class AlertPresentationConfig {
  /// この時間以内に到達する脅威は連続音にする。
  ///
  /// 8+の停止時間(約8.15秒)より余裕を取り、既定は10秒にする。
  /// 漕手は後ろ向きで前を見ていないため、停止判断へ移るための余裕を残す。
  /// 停止距離式(`boat_config.dart`)は `(0.5+2.0+1.0)·v + k·v` で速度に線形
  /// なので、停止に必要な**時間**は速度によらず一定になる。
  ///
  /// 予告は [intermittentAudioDeadline] まで残す。連続音の余裕と
  /// 段階的な予告を両立するため、予測地平を13秒へ伸ばしている。
  final Duration continuousAudioDeadline;

  /// この時間以内なら断続音で知らせる([continuousAudioDeadline]より先)。
  ///
  /// 予測地平(`advanceWarningLeadSeconds` = 13秒)と一致させ、
  /// 「予測が届かない先では音が鳴らない」という不変条件にする。
  final Duration intermittentAudioDeadline;

  /// 断続音を鳴らし直す間隔。
  ///
  /// 単発音1回では聞き逃す。連続音まで上げずに「継続して危ない」ことを
  /// 伝えるための中間段階。
  final Duration intermittentRepeatInterval;

  /// 近接注意で単発音を鳴らしたあと、再武装するのに必要な離脱距離 [m]。
  /// 同じ場所で接近判定が揺れて鳴り続けるのを防ぐ。
  final double proximityAudioRearmMeters;

  final double stableStopSpeedMetersPerSecond;

  /// 安定停止を「抜けた」と認める速度 [m/s]。
  ///
  /// [stableStopSpeedMetersPerSecond] より**大きく**すること。
  /// 係留中の艇は波と測位ノイズで 0.0〜0.6m/s を往復する。単一のしきい値だと
  /// 安定停止に入っては抜けるを繰り返し、そのたびに低速静音の確定待ちが
  /// 巻き戻って音声エピソードが作り直される(2026-08-05 実機ログ)。
  ///
  /// 止まったと判定するのは速く、動き出したと判定するのは慎重にする
  /// 非対称。0.8m/s は分速48mで、漕ぎ出しの最初の1ストロークでも超える。
  final double stableStopExitSpeedMetersPerSecond;

  final Duration stableStopConfirmationDuration;
  final double stableStopRealertApproachMeters;
  final double approachingObservationMeters;
  final Duration stableThreatEpisodeRetentionDuration;
  final Duration guidanceRearmDuration;

  /// 区域内にいる間、カーブ・逆走の読み上げを鳴らし直す間隔。
  ///
  /// 1回だけでは聞き逃す。一方で衝突警告と同じ3秒間隔にすると、
  /// 5m/sで20〜40秒かかるカーブ区域の通過中に7〜13回鳴り、
  /// 原則4(過剰警告は安全機能の破壊)へ直行する。
  /// 区域進入は「いま操作を変えろ」ではなく「この先の形に備えろ」なので、
  /// 衝突警告より薄い周期にする。
  ///
  /// 衝突警告との競合では鳴らない。カーブ・逆走は
  /// `AlertBehavior.entryEvent`(band 3)で、
  /// `continuousAction`(0)・`singleAction`(1)に必ず負ける。
  final Duration guidanceRepeatInterval;

  /// 同一区域に入っている間に読み上げる上限回数。null で無制限。
  ///
  /// **既定は null(無制限)である。上限で打ち切らない。**
  ///
  /// 一度 3 を既定にしたが撤回した。逆走は「入った」という一度きりの
  /// 事実ではなく、**是正されるまで続く状態**である。実機ログの逆走警告は
  /// 誤検知ではなく実際に逆走していた(利用者確認済み)。
  /// 正しく鳴っている警告を回数で打ち切ると、状態が続いているのに
  /// 黙ることになり、警告漏れと同じになる。
  ///
  /// うるささは**回数ではなく頻度**で解く([guidanceBurstCount])。
  /// 長いカーブ区域などで上限を入れたくなったときのために口は残す。
  final int? guidanceRepeatMaxCount;

  /// 1組の読み上げに含める回数。
  ///
  /// **「2回鳴らして、しばらく黙る」を1組とする。**
  ///
  /// 一定間隔で鳴らし続けると、聞き手はすぐに慣れて無視するようになる。
  /// 2回続けて鳴ると「いま起きている」ことが伝わり、そのあとの静寂が
  /// 「まだ続いている」を次の組で再認識させる。同じ総数でも、
  /// 均等に散らすより組にしたほうが体感のうるささが下がる。
  final int guidanceBurstCount;

  /// 組と組のあいだの静寂。滞在が続くと [guidanceBurstMaxIdleInterval] まで伸びる。
  ///
  /// 進入直後は短い間隔で確実に気づかせ、状態が続くにつれて落ち着かせる。
  /// 人のコーチが同じ状況で取る振る舞いに近い。
  final Duration guidanceBurstIdleInterval;

  /// 組と組の静寂の上限。長く居続けても、これ以上は間延びさせない。
  ///
  /// 逆走のように是正されるまで続く状態では、完全に黙ってはいけない。
  final Duration guidanceBurstMaxIdleInterval;

  /// 逆走注意の再武装間隔。
  ///
  /// カーブと違い、区域の境界付近を行き来しても鳴り直さないようにする。
  /// 実機ログでは77分で16回 `reverse_main_channel` を出入りしており、
  /// 5秒のままだと正常に漕いでいるだけで16回鳴る(原則4)。
  final Duration reverseGuidanceRearmDuration;

  /// 静的区域と重なっていても、この速度以上で距離が縮まっていなければ
  /// 連続音まで上げない [m/s]。
  ///
  /// 岸との並走・桟橋への係留は「まずい」が「切迫していない」(原則5)。
  /// `currentOverlap` は「どれだけまずいか」であって
  /// 「どれだけ切迫しているか」ではない。
  final double staticOverlapClosingRateMetersPerSecond;

  /// 縮まらないまま重なり続けた場合に、表示のみへ落とすまでの猶予。
  final Duration staticOverlapImminentGrace;

  /// 接近判定に使う観測窓。この時間ぶんの距離差から接近速度を求める。
  ///
  /// 1秒ごとの差分だけで見るとGPSの揺れで符号が反転するため、
  /// 数秒の窓でならしてから判定する。
  final Duration closingRateWindow;

  const AlertPresentationConfig({
    this.continuousAudioDeadline = const Duration(seconds: 10),
    this.intermittentAudioDeadline = const Duration(seconds: 13),
    this.intermittentRepeatInterval = const Duration(seconds: 3),
    this.proximityAudioRearmMeters = 3,
    this.stableStopSpeedMetersPerSecond = 0.4,
    this.stableStopExitSpeedMetersPerSecond = 0.8,
    this.stableStopConfirmationDuration = const Duration(seconds: 5),
    this.stableStopRealertApproachMeters = 2,
    this.approachingObservationMeters = 0.5,
    this.stableThreatEpisodeRetentionDuration = const Duration(seconds: 5),
    this.guidanceRearmDuration = const Duration(seconds: 5),
    this.guidanceRepeatInterval = const Duration(seconds: 5),
    this.guidanceRepeatMaxCount,
    this.guidanceBurstCount = 2,
    this.guidanceBurstIdleInterval = const Duration(seconds: 15),
    this.guidanceBurstMaxIdleInterval = const Duration(seconds: 60),
    this.reverseGuidanceRearmDuration = const Duration(seconds: 60),
    this.staticOverlapClosingRateMetersPerSecond = 0.3,
    this.staticOverlapImminentGrace = const Duration(seconds: 5),
    this.closingRateWindow = const Duration(seconds: 3),
  })  : assert(stableStopSpeedMetersPerSecond >= 0),
        assert(stableStopExitSpeedMetersPerSecond >=
            stableStopSpeedMetersPerSecond),
        assert(stableStopRealertApproachMeters > 0),
        assert(approachingObservationMeters >= 0),
        assert(proximityAudioRearmMeters > 0),
        assert(staticOverlapClosingRateMetersPerSecond > 0),
        // 「区域進入の周期 > 衝突警告の断続音の周期」は不変条件だが、
        // Duration は const 式で比較できないため assert にできない。
        // `test/services/alert_presentation_config_test.dart` で担保する。
        assert(guidanceRepeatMaxCount == null || guidanceRepeatMaxCount > 0);
}

const defaultAlertPresentationConfig = AlertPresentationConfig();

/// 音の緊急度バンド。到達までの時間だけで決まる。
enum AlertUrgency {
  /// 表示のみ。
  monitoring,

  /// 断続音。
  approaching,

  /// 連続音。
  imminent;

  /// 確度が低い候補を1段下げる。連続音の信頼性を守るため。
  AlertUrgency get oneStepDown => switch (this) {
        AlertUrgency.imminent => AlertUrgency.approaching,
        AlertUrgency.approaching => AlertUrgency.monitoring,
        AlertUrgency.monitoring => AlertUrgency.monitoring,
      };
}

/// 近接注意(到達予測なし)でも単発音を鳴らすカテゴリ。
///
/// 岸は川幅40mでは常に近く、鳴らすと確実に形骸化するため入れない。
/// 流木・中州・杭は水面下や視認しづらい位置にあり、帰結が最悪なので鳴らす。
const audibleProximityCategories = <String>{
  'driftwood',
  'island',
  'pile',
  'bridgePier'
};

/// 連続音まで上げないカテゴリ。
///
/// 橋は毎回くぐって通過する区域なので、接近するたびに連続音が鳴ると
/// 確実に形骸化する。単発音1回に留める(従来と同じ挙動)。
/// 橋脚そのものを別kindへ分離できたら、橋脚はこの対象から外す。
// 橋と橋脚は同じ物理警告ロジックで扱う。音声アセットと、
// 同時に重なった場合の橋脚優先だけを別扱いにする。
const bandCappedCategories = <String>{};

/// 分速100m未満が3秒続く間だけ、橋の下・岸際で正常に休憩している艇へ
/// 読み上げを重ねない。速度欠損は静音の根拠にしない。
const lowSpeedAudioMuteSpeedMetersPerSecond = 100 / 60;
const lowSpeedAudioMuteConfirmation = Duration(seconds: 3);
const lowSpeedMutedCategories = <String>{
  'bridgePier',
  'bridge',
  'shore',
  'reverse',
};
