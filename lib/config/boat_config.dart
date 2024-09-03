import 'package:rowing_navigator/models/boat_model.dart';
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
      default:
        return r_1x_;
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
  final double Function(double speed) stoppingDistanceFormula;
  final List<SeatPosition> seatPosList;

  BoatConfig(
      {required this.type,
      required this.label,
      required this.shipDomainParams,
      required this.stoppingDistanceFormula,
      required this.seatPosList});
}

class ShipDomainParams {
  final ShipDomainParam shipBodyParam;
  final ShipDomainParam exclusiveParam;
  final ShipDomainParam attentionParam;

  ShipDomainParams({
    required this.shipBodyParam,
    required this.exclusiveParam,
    required this.attentionParam,
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
BoatConfigs boatConfigs = BoatConfigs(
  r_1x_: BoatConfig(
    type: BoatType.r_1x,
    label: '1x',
    shipDomainParams: ShipDomainParams(
      shipBodyParam: ShipDomainParam(h: 10, w: 6, s: 6),
      exclusiveParam: ShipDomainParam(h: 20, w: 10, s: 14),
      attentionParam: ShipDomainParam(h: 40, w: 14, s: 22),
    ),
    stoppingDistanceFormula: (speed) {
      return 5.0;
    },
    seatPosList: [
      SeatPosition(label: '1', position: 1),
    ],
  ),
  r_2x_: BoatConfig(
    type: BoatType.r_2x,
    label: '2x',
    shipDomainParams: ShipDomainParams(
      shipBodyParam: ShipDomainParam(h: 10, w: 6, s: 6),
      exclusiveParam: ShipDomainParam(h: 20, w: 10, s: 14),
      attentionParam: ShipDomainParam(h: 40, w: 14, s: 22),
    ),
    stoppingDistanceFormula: (speed) {
      return 10.0;
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
      shipBodyParam: ShipDomainParam(h: 10, w: 6, s: 6),
      exclusiveParam: ShipDomainParam(h: 20, w: 10, s: 14),
      attentionParam: ShipDomainParam(h: 40, w: 14, s: 22),
    ),
    stoppingDistanceFormula: (speed) {
      return 20.0;
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
      shipBodyParam: ShipDomainParam(h: 10, w: 6, s: 6),
      exclusiveParam: ShipDomainParam(h: 20, w: 10, s: 14),
      attentionParam: ShipDomainParam(h: 40, w: 14, s: 22),
    ),
    stoppingDistanceFormula: (speed) {
      return 30.0;
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

const seatSpan = 0.9; // 座席間距離