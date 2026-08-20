import 'package:rowing_navigator/services/ship_domain_service.dart';
import 'package:rowing_navigator/types/boat_type.dart';

class BoatConfigs {
  final BoatConfig r_1x_;
  final BoatConfig r_2x_;
  final BoatConfig r_4x_;
  final BoatConfig r_8p_;

  BoatConfig get r_1x => r_1x_;
  BoatConfig get r_2x => r_2x_;
  BoatConfig get r_4x => r_4x_;
  BoatConfig get r_8p => r_8p_;

  List<BoatConfig> get allConfigs => [r_1x_, r_2x_, r_4x_, r_8p_];

  // BoatTypeに従ってBoatConfigを取得
  BoatConfig byBoatType(BoatType type) {
    switch (type) {
      case BoatType.r_1x:
        return r_1x_;
      case BoatType.r_2x:
        return r_2x_;
      case BoatType.r_4x:
        return r_4x_;
      case BoatType.r_8p:
        return r_8p_;
    }
  }

  BoatConfigs({
    required this.r_1x_,
    required this.r_2x_,
    required this.r_4x_,
    required this.r_8p_,
  });
}

class BoatConfig {
  final BoatType type;
  final String label;
  final ShipDomainParams shipDomainParams;

  /// 地図の矢羽だけに使う実艇の船体幅。
  ///
  /// [ShipDomainParams.shipBodyParam] の幅はオーまで含む衝突判定用で、
  /// マーカーに使うと危険ポリゴンと同じ太さに見える。
  final double displayHullWidthMeters;
  final double Function(double speed) stoppingDistanceFormula;
  final List<SeatPosition> seatPosList;

  BoatConfig(
      {required this.type,
      required this.label,
      required this.shipDomainParams,
      required this.displayHullWidthMeters,
      required this.stoppingDistanceFormula,
      required this.seatPosList});
}

class ShipDomainParams {
  final ShipDomainParam shipBodyParam;
  final ShipDomainParam exclusiveParam;

  ShipDomainParams({
    required this.shipBodyParam,
    required this.exclusiveParam,
  });
}

class SeatPosition {
  final String label;
  final int position; // 船首側からの座席位置

  SeatPosition({
    required this.label,
    required this.position,
  });
}

// ============================
// Boat Config
// ============================
// 安全定数の来歴:
// - 認知・判断・反応時間と停止係数は 2024-11-30 の 809ad831 で導入。
// - 船体・排他領域寸法は 2024-12-03 の 9fc93930 で導入。
// - 元の実測記録・文献出典はリポジトリに残っていない。
//
// したがって現時点では「現場実測済みの物理モデル」ではなく、既存運用を
// 維持するlegacy engineering assumptionとして扱う。値を変えるときは、
// 艇種・速度・停止操作・水流を記録した実測か引用可能な文献を根拠台帳へ追記し、
// 停止距離・領域不変条件・実データ回帰を同時に更新すること。
// 詳細: docs/design_notes/2026-08-20_艇種別安全定数の根拠台帳.md
const tp = 0.5; // 認知時間 [s]（出典未記録の継承値）
const td = 2.0; // 判断時間 [s]（出典未記録の継承値）
const tr = 1.0; // 反応時間 [s]（出典未記録の継承値）
BoatConfigs boatConfigs = BoatConfigs(
  r_1x_: BoatConfig(
    type: BoatType.r_1x,
    label: '1x',
    shipDomainParams: ShipDomainParams(
      shipBodyParam: ShipDomainParam(h: 8.2, w: 6, s: 4),
      exclusiveParam: ShipDomainParam(h: 11.2, w: 9, s: 5.8),
    ),
    displayHullWidthMeters: 0.55,
    stoppingDistanceFormula: (speed) {
      // 反応まで3.5秒 + 艇種別の減速相当3.45秒 = 6.95秒分。
      return (tp + td + tr) * speed + 3.45 * speed;
    },
    seatPosList: [
      SeatPosition(label: '1', position: 1),
    ],
  ),
  r_2x_: BoatConfig(
    type: BoatType.r_2x,
    label: '2x',
    shipDomainParams: ShipDomainParams(
      shipBodyParam: ShipDomainParam(h: 10.4, w: 6, s: 5),
      exclusiveParam: ShipDomainParam(h: 13.4, w: 9, s: 5.6),
    ),
    displayHullWidthMeters: 0.6,
    stoppingDistanceFormula: (speed) {
      // 反応まで3.5秒 + 艇種別の減速相当3.10秒 = 6.60秒分。
      return (tp + td + tr) * speed + 3.10 * speed;
    },
    seatPosList: [
      SeatPosition(label: 'stroke', position: 2),
      SeatPosition(label: 'bow', position: 1),
    ],
  ),
  r_4x_: BoatConfig(
    type: BoatType.r_4x,
    label: '4x',
    shipDomainParams: ShipDomainParams(
      shipBodyParam: ShipDomainParam(h: 13.4, w: 6, s: 8.5),
      exclusiveParam: ShipDomainParam(h: 16.4, w: 9, s: 9.6),
    ),
    displayHullWidthMeters: 0.65,
    stoppingDistanceFormula: (speed) {
      // 反応まで3.5秒 + 艇種別の減速相当3.18秒 = 6.68秒分。
      return (tp + td + tr) * speed + 3.18 * speed;
    },
    seatPosList: [
      SeatPosition(label: 'stroke', position: 4),
      SeatPosition(label: '3', position: 3),
      SeatPosition(label: '2', position: 2),
      SeatPosition(label: 'bow', position: 1),
    ],
  ),
  r_8p_: BoatConfig(
    type: BoatType.r_8p,
    label: '8+',
    shipDomainParams: ShipDomainParams(
      shipBodyParam: ShipDomainParam(h: 19.9, w: 7.5, s: 16),
      exclusiveParam: ShipDomainParam(h: 22.9, w: 10.5, s: 18.88),
    ),
    displayHullWidthMeters: 0.7,
    stoppingDistanceFormula: (speed) {
      // 反応まで3.5秒 + 艇種別の減速相当4.65秒 = 8.15秒分。
      return (tp + td + tr) * speed + 4.65 * speed;
    },
    seatPosList: [
      SeatPosition(label: 'cox', position: 9),
      SeatPosition(label: 'stroke', position: 8),
      SeatPosition(label: '7', position: 7),
      SeatPosition(label: '6', position: 6),
      SeatPosition(label: '5', position: 5),
      SeatPosition(label: '4', position: 4),
      SeatPosition(label: '3', position: 3),
      SeatPosition(label: '2', position: 2),
      SeatPosition(label: 'bow', position: 1),
    ],
  ),
);

const seatSpan = 1.4; // 座席間距離
