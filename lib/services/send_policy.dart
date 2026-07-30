import 'package:rowing_navigator/config/navigator_config.dart';

/// 適応送信: 状況に応じた位置送信間隔 [秒] を返す。
///
/// - リスクレベルがlv1以上: 2秒(端末内判定は1秒のまま)
/// - 他艇情報を受信できない: 2秒(下記)
/// - 他艇が近いがリスクなし: 2秒(推測航法で毎秒補間)
/// - 停止中かつ他艇なし: 10秒
/// - 周囲300m以内に他艇なし: 5秒
/// - それ以外(他艇が近い): 2秒
///
/// 自艇のリスク評価は送信間隔と無関係に毎秒行われるため、
/// 静的危険区域への警告はこの設定の影響を受けない。
///
/// [receiveUnavailable] は「他艇の受信経路が落ちている」ことを表す。
/// [otherBoatNearby] は自艇が受信できた他艇からしか作れないため、受信だけが
/// 落ちた艇は常に「周囲に他艇なし」と判断して10秒送信を続ける。10秒は
/// 受信側の予測TTL(`boatPredictionTimeoutSeconds` = 6秒)を超えるので、
/// その艇は10秒周期のうち4秒間、他艇の衝突評価から消える。
/// 「他艇が見えない艇ほど、他艇からも見えなくなる」相関故障になるため、
/// 受信が落ちている間は近傍時と同じ間隔で送り続ける。
int sendIntervalSecondsFor({
  required double speed,
  required bool otherBoatNearby,
  required bool elevatedRisk,
  bool receiveUnavailable = false,
}) {
  if (elevatedRisk) return sendIntervalElevatedRiskSec;
  if (receiveUnavailable) return sendIntervalNearOthersSec;
  if (otherBoatNearby) return sendIntervalNearOthersSec;
  if (speed < stoppedSpeedThreshold) return sendIntervalStoppedSec;
  return sendIntervalNoOthersNearbySec;
}
