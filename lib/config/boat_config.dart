import 'package:rowing_navigator/services/ship_domain_service.dart';
import 'package:rowing_navigator/types/boat_type.dart';

class BoatConfigs {
  final BoatConfig r_1x;
  final BoatConfig r_2x;

  // BoatTypeに従ってBoatConfigを取得
  BoatConfig byBoatType(BoatType type) {
    switch (type) {
      case BoatType.r_1x:
        return r_1x;
      case BoatType.r_2x:
        return r_2x;
      default:
        return r_1x;
    }
  }

  BoatConfigs({
    required this.r_1x,
    required this.r_2x,
  });
}

class BoatConfig {
  final BoatType type;
  final ShipDomainParams shipDomainParams;
  final double Function(double speed) stoppingDistanceFormula;
  final List<int> seatPosList;

  BoatConfig(
      {required this.type,
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

// ============================
// Boat Config
// ============================
BoatConfigs boatConfigs = BoatConfigs(
  r_1x: BoatConfig(
    type: BoatType.r_1x,
    shipDomainParams: ShipDomainParams(
      shipBodyParam: ShipDomainParam(h: 10, w: 6, s: 6),
      exclusiveParam: ShipDomainParam(h: 20, w: 10, s: 14),
      attentionParam: ShipDomainParam(h: 40, w: 14, s: 22),
    ),
    stoppingDistanceFormula: (speed) {
      return 10.0;
    },
    seatPosList: [1],
  ),
  r_2x: BoatConfig(
    type: BoatType.r_2x,
    shipDomainParams: ShipDomainParams(
      shipBodyParam: ShipDomainParam(h: 10, w: 6, s: 6),
      exclusiveParam: ShipDomainParam(h: 20, w: 10, s: 14),
      attentionParam: ShipDomainParam(h: 40, w: 14, s: 22),
    ),
    stoppingDistanceFormula: (speed) {
      return 10.0;
    },
    seatPosList: [1, 2],
  ),
);
