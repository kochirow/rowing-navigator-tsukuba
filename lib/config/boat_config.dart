import 'package:rowing_navigator/services/ship_domain_service.dart';
import 'package:rowing_navigator/types/boat_type.dart';

class BoatConfigs {
  final BoatConfig single;
  final BoatConfig double;

  // BoatTypeに従ってBoatConfigを取得
  BoatConfig byBoatType(BoatType type) {
    switch (type) {
      case BoatType.single:
        return single;
      case BoatType.double:
        return double;
      default:
        return single;
    }
  }

  BoatConfigs({
    required this.single,
    required this.double,
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
  single: BoatConfig(
    type: BoatType.single,
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
  double: BoatConfig(
    type: BoatType.double,
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
