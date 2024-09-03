import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/boat_config.dart';
import '../types/boat_type.dart';

final boatTypeProvider = StateProvider<BoatType>((ref) {
  return BoatType.r_1x;
});

final seatPositionProvider = StateProvider<SeatPosition>((ref) {
  return boatConfigs.r_1x.seatPosList[0];
});
