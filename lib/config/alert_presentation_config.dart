import 'boat_config.dart';
import '../types/boat_type.dart';

/// 警告判定そのものを変えず、画面表示と音声の段階だけを決める設定。
///
/// **設計の要点: 2つの軸を分離する。**
///
/// - 内部レベル(lv0〜3)は「どれだけまずいか」= 停止距離内か・確度。
///   表示色・優先順位・ログにだけ使い、音の鳴り方には使わない。
/// - 音は「どれだけ切迫しているか」= 到達までの時間と、当たり判定の確度で
///   **鳴り始め**を決める。鳴り方は1種類(読み上げの繰り返し)。
///
/// 以前は lv2 が必ず単発音1回、lv3 でも到達3秒超なら単発音という具合に
/// 2軸が混線しており、「レベル」と「音」の対応が直感と合わなかった。
///
/// **衝突警告の鳴り方は1種類である(2026-10-23 利用者決定)。**
/// 以前は10秒以内=連続音、10〜13秒=3秒間隔の断続音の2段階だった。
/// 漕手は「鳴っている/鳴っていない」しか聞き分けない(両手がオールで
/// 塞がり、段階が変わってもすること=振り返って確認する、は同じ)うえ、
/// 断続音の帯は3秒しかなく実質1回しか鳴らなかった。確度の違いは
/// 鳴り方ではなく鳴り始めの早さで表す。経緯は DESIGN_PRINCIPLES 3.3.1。
class AlertPresentationConfig {
  /// 確実な当たり予測が、この時間以内に到達するなら鳴らす。
  ///
  /// 予測地平(`advanceWarningLeadSeconds` = 13秒)と一致させ、
  /// 「予測が届かない先では音が鳴らない」という不変条件にする。
  /// 設定画面・共有設定では `advanceWarningLeadSeconds` の名前で保存される。
  final Duration audioStartDeadline;

  /// 確度の低い当たり予測は、この時間以内に到達するときだけ鳴らす。
  ///
  /// 該当するのは、固定の危険区域に自艇のGPS誤差を足して初めて当たる候補と、
  /// 回頭中の方位のブレで広げた領域で初めて当たる候補。鳴り方は確実な
  /// 候補と同じで、鳴り始めだけを遅らせる。確度の低い警報が長く鳴ると
  /// 警報全体が無視されるようになる(原則4)ため。
  ///
  /// 8+の停止時間(約8.15秒)より余裕を取り、既定は10秒にする。
  /// 確度が低くても、止まりきれる時点では必ず鳴らす。
  /// 停止距離式(`boat_config.dart`)は `(0.5+2.0+1.0)·v + k·v` で速度に線形
  /// なので、停止に必要な**時間**は速度によらず一定になる。
  /// 設定画面・共有設定では `primaryWarningLeadSeconds` の名前で保存される。
  final Duration lowConfidenceAudioStartDeadline;

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
  /// 1回だけでは聞き逃す。一方で3秒間隔で鳴らし続けると、
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
    this.audioStartDeadline = const Duration(seconds: 13),
    this.lowConfidenceAudioStartDeadline = const Duration(seconds: 10),
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
        // 「確度の低い候補の鳴り始め <= 確実な候補の鳴り始め」は不変条件だが、
        // Duration は const 式で比較できないため assert にできない。
        // `test/services/alert_presentation_config_test.dart` で担保する。
        assert(guidanceRepeatMaxCount == null || guidanceRepeatMaxCount > 0);
}

const defaultAlertPresentationConfig = AlertPresentationConfig();

/// 衝突警告の鳴らし方。到達までの時間と確度で決まる。
enum AlertUrgency {
  /// 表示のみ。
  monitoring,

  /// 1回だけ読み上げる。静的区域と重なっているが距離が縮まっていない
  /// (岸との並走・桟橋への係留)ときの猶予中だけに使う。
  approaching,

  /// 繰り返し読み上げる。衝突警告の鳴り方はこれ1種類。
  imminent;

  /// 確度が低い候補を1段下げる。
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

/// 繰り返し音まで上げず、1回の読み上げに留めるカテゴリ。**現在は空。**
///
/// 以前は橋をここへ入れ、毎回くぐる橋で繰り返し音が鳴らないようにしていた。
/// 橋脚を別の区域(`bridgePier`)として描けるようになったので外した。
/// 橋の下での休憩は低速静音([lowSpeedAudioMuteSpeedMetersPerSecond])が受け持つ。
// 橋と橋脚は同じ物理警告ロジックで扱う。音声アセットと、
// 同時に重なった場合の橋脚優先だけを別扱いにする。
const bandCappedCategories = <String>{};

/// 自艇がこの速さ(1.67m/s、分速100m、500mを5分)より遅い間は、
/// **すべての警告の音を止める**(2026-11-07 利用者決定)。画面の表示・記録・位置共有は続ける。
///
/// 前提: これより遅いのは休憩・待機・艇の向きを変えるときで、漕手は周りを見て
/// 自分で避けられる。2026-11-07 の実機ログでは、漕いでいる間にこの速さを3秒以上
/// 下回ったのは約1.5分だった(2.0m/sにすると約8分。軽く漕ぐ練習まで音が止まるので、
/// 同日に2.0m/sから戻した)。
/// 休憩・橋の下での停止・止まって並ぶ・コーチの指示を聞く、はどれも正常な運用で、
/// そこで鳴る警告は原則4の過剰警告になる(2026-11-07 実機ログ: 止まって並んだ
/// 他艇に2分鳴り続け、漕手が端末の音量を0にして、以後92分の警告がすべて消えた)。
///
/// 他艇も止める。相手が速く近づくときは、相手の端末(相手はこの速さより速い)で鳴る。
/// 危険を作っている側に伝われば足りる。
///
/// 自艇の速度が取れないときは低速とみなさず、今までどおり鳴らす。
const lowSpeedAudioMuteSpeedMetersPerSecond = 100 / 60;

/// 低速が続いたと確定するまでの時間。速さがしきい値をまたいで揺れるたびに
/// 音が出たり止まったりしないようにする。
const lowSpeedAudioMuteConfirmation = Duration(seconds: 3);

// ## 港の中(発着場所から航路の入口まで)
//
// 港の中では、艇を桟橋から離し、向きを変え、防波堤に沿って出口へ向かう。
// 予測地平と一致させた13秒の鳴り始めは、巡航(3〜5m/s)で40〜65m先を見る値で、
// 港の中の速さ(中央値1.1m/s。2026-11-03 までの霞ヶ浦5練習)では壁まで十数mしか
// ない港のほぼ全体が予測に入り、向きを変えるたびに岸の警告が鳴っていた
// (港の中で49回 / 霞ヶ浦全体100回。漕手2人が別々に指摘)。
// 要件: docs/要件定義_2026-11-03_実機ログとレビューに基づく改善.md R4。

/// 港の中で岸の警告を鳴らし始める時刻の、停止時間に足す余裕 [秒]。
///
/// 停止距離の式(`boat_config.dart`)は速さに比例するので、止まりきるまでの
/// **時間**は速さによらず艇種ごとに一定(1x 6.95秒・8+ 8.15秒など)。
/// 「止まりきれる時点では必ず鳴る」を港の中でも保つため、停止時間を下回らない
/// 値にする。1秒は、鳴ってから漕手が振り返るまでの余裕として選ぶ。
const harborShoreLeadMarginSeconds = 1.0;

/// 港の中で「艇を出し入れしている」とみなす速さ [m/s]。
///
/// **低速の定義は1つ(1.67m/s)に揃える**(2026-11-07 利用者決定)ので、
/// [lowSpeedAudioMuteSpeedMetersPerSecond] をそのまま使う。自艇も相手もこれ未満なら、
/// 他艇の警告を1回だけにする。相手が速い、または速度が分からなければ今までどおり繰り返す。
/// 自艇の低速が3秒続けば低速静音がすべての音を止めるので、この規則が働くのは
/// 低速になった直後の3秒間である。
const harborManeuverSpeedMetersPerSecond =
    lowSpeedAudioMuteSpeedMetersPerSecond;

/// 艇種の停止時間 [秒]。停止距離の式に 1m/s を入れた値(式が速さに比例するため)。
double stoppingTimeSecondsFor(BoatType type) =>
    boatConfigs.byBoatType(type).stoppingDistanceFormula(1.0);

/// 港の中で岸の警告を鳴らし始める、到達までの時間の上限。
///
/// 艇種の停止時間 + [harborShoreLeadMarginSeconds]。
Duration harborShoreAudioStartDeadlineFor(BoatType type) => Duration(
      milliseconds:
          ((stoppingTimeSecondsFor(type) + harborShoreLeadMarginSeconds) * 1000)
              .round(),
    );

/// 艇種が分からないときの既定値。最も止まりにくい 8+ に合わせる(8.15 + 1 秒)。
const defaultHarborShoreAudioStartDeadline = Duration(milliseconds: 9150);

// ## 同じ向きに漕ぐ艇(並走・縦列。2026-11-09 利用者決定)
//
// 向きの差が [sameDirectionMaxHeadingDifferenceDegrees] 以内で漕いでいる他艇は、
// 並走でも縦列(追いかけ・追いつく・追いつかれる)でも、その相手への他艇の警告を
// 表示だけにする。同じ向きに進む艇どうしは、少なくとも片方が相手を見ている
// (コックスは前を、漕手は後ろを向いている。前の遅い艇の漕手には後ろから来る艇が
// 見える)。オールが当たる距離(4〜5m)でも鳴らさない。
//
// 経緯: 2026-11-07・08 は「10秒の距離の変化」で並走・追いつくを分けていた。
// 判定が固まる最初の10秒は必ず鳴り、GPSの誤差(σ1.5m)だけで距離が10秒に7m以上
// ぶれて外れるため、並走の再現で91秒中10〜37秒鳴った。向きだけで決めると0秒になる。
//
// 角度の根拠(2026-11-07 桜川の自艇の軌跡、2.5m/s以上): 同じ線を10〜42m後ろで漕ぐ艇
// との向きの差は 99%点で5.5〜15°、最大25°(進路を曲げた1か所)。霞ヶ浦(11/03)は
// 最大7°。30°と45°の間は斜めに横切ってくる艇で、こちらには今までどおり鳴らす。
//
// 相手が送ってきた速さは使わない(2026-11-07 実機で並走中に1.5〜2.0m/sと実際より
// 遅く届き、追いついていると予測して約88秒鳴った)。前後・横・近づく速さは、
// 受け取った位置と同じ測位時刻の自艇の位置から求める。

/// 同じ向きとみなす向きの差の上限 [度]。
const sameDirectionMaxHeadingDifferenceDegrees = 30.0;

/// 相手の測位時刻と、同じ時刻の自艇の位置とのずれの許容。
/// 自艇の位置の履歴にこれ以上近い点が無ければ、その受信は判定に使わない。
const sameDirectionMaxTimeOffset = Duration(milliseconds: 1500);

/// 同じ向きの艇がこの距離 [m] 以内にいる間は、逆走注意を読み上げない
/// (横に並ぶ・追い抜くと、片方は地図上の逆側を通る)。
const sameDirectionReverseMuteDistanceMeters = 30.0;

// ### 追いつく側の安全網
//
// 後ろの速い艇の漕手は前が見えない(コックスがいれば見える)。前の艇がよけないまま
// 進路上に残り、このままだと [overtakingSafetyNetDeadline] 以内に艇首が前の艇の
// 艇尾に当たるときだけ、後ろの艇で鳴らす。前の艇(追いつかれる側)には鳴らさない。
//
// 「進路上」は距離ではなく前後・横で見る。2026-11-07 07:02 の実機では、2艇が
// 3.3〜5.2mの距離のまま約17秒並んで漕いでいた(横に並んでいた)。一方、縦に並ぶ
// 2艇の端末どうしの距離は、当たる時点で艇の長さ(4+で約13m)ある。距離5m以内の
// ような条件では、並走で鳴り、縦の衝突には間に合わない。
//
// 横の距離では細かく絞れない(2026-11-09 練習日シミュレーション)。2台の端末の
// 測位の誤差は相対で約2.5m、数十秒ゆっくり変わり、6秒平均でも消えない。真後ろ
// (横0m)の艇が横6mと測れることがある。横2m以内に絞ると、同じレーンで後ろから
// 当たる場面の35〜60%で鳴らなかった(`SIM=conflict` の overtaking)。そこで横は
// 明らかに離れた艇(横8m超)を外すだけにし、代わりに艇首が前の艇の艇尾を過ぎて
// 横に並んだら終える。後ろから当たるのは艇首が艇尾に届く瞬間なので、そこを
// 過ぎて当たっていなければ横を抜けている。横の距離は、航路中心線があれば
// 中心線に沿って測る(自艇の向き基準だと、舵のぶれとカーブで数mずれる)。
// 結果: 当たる前に鳴らなかったのは各水域約63回中0〜4回、練習日の安全網の
// 時間は1艇1時間あたり約12秒(鬼ごっこで抜くときの数秒ずつ)。

/// 追いつく側の安全網の鳴り始め。前後の距離が縮む速さ(位置から求めた速度差)で、
/// 艇首が前の艇の艇尾に届くまでの時間がこれ以内なら鳴らす。
///
/// 停止時間(約6.6〜8.2秒)は「完全に止まるまで」の時間である。追いつく場面では、
/// 少し減速して速度差を消せば当たらないので、それより短くてよい(2026-11-08 利用者)。
const overtakingSafetyNetDeadline = Duration(seconds: 4);

/// 安全網で「相手が進路上にいる」とみなす横の距離 [m]。明らかに離れた艇
/// (別のレーン・広く空けて抜く艇)だけを外す。測位の誤差(相対で約2.5m、
/// ゆっくり変わる)があるので、船体の幅では絞らない。直近
/// [overtakingLateralAveragingWindow] の平均で見る。
const overtakingInPathLateralMeters = 8.0;

/// 横の距離を平均する時間。
const overtakingLateralAveragingWindow = Duration(seconds: 6);

/// 前後の距離が縮む速さを求める時間(この間の前後の距離の傾き)。
const overtakingClosingWindow = Duration(seconds: 10);

/// 近づく速さを求めるのに必要な最短の時間。これより短い間しか同じ向きの関係が
/// 続いていなければ、安全網は判定しない。
const overtakingClosingMinSpan = Duration(seconds: 5);

/// 安全網で、艇首が前の艇の艇尾に届くまでの距離を短めに見る量 [m]。
/// 2艇の測位の誤差(各σ1.5m)で前後の距離は約2mぶれる。誤差で長めに出たときに
/// 当たってから鳴る、を避ける(再現で、誤差なしなら当たる約3秒前に鳴る場面が、
/// 誤差ありで当たった後に鳴った)。
const overtakingPositionMarginMeters = 2.0;

/// 安全網が「追いついている」とみなす、前後の距離が縮む速さの下限 [m/s]。
/// 同じ速さで追いかけているとき(GPSの誤差だけ)に鳴らさないための下限。
const overtakingMinClosingSpeedMetersPerSecond = 0.5;
