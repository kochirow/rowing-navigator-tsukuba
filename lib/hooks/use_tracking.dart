import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';

import '../types/tracking_mode.dart';

UseTracking useTracking() {
  final mode = useState(TrackingMode.track);
  final progFlag = useState(false);

  void setMode(TrackingMode newMode) {
    mode.value = newMode;
  }

  void setProgFlag(bool newFlag) {
    progFlag.value = newFlag;
  }

  return UseTracking(
    mode: mode,
    progFlag: progFlag,
    setMode: setMode,
    setProgFlag: setProgFlag,
  );
}

class UseTracking {
  final ValueNotifier<TrackingMode> mode;
  final ValueNotifier<bool> progFlag;
  final void Function(TrackingMode) setMode;
  final void Function(bool) setProgFlag;

  UseTracking({
    required this.mode,
    required this.progFlag,
    required this.setMode,
    required this.setProgFlag,
  });
}
