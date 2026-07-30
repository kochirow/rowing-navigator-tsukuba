import 'package:shared_preferences/shared_preferences.dart';

import '../models/danger_zone_settings.dart';

/// 端末内の危険区域幅が、コード既定値ではなく利用者が保存した値かを表す。
///
/// 共有安全設定が無い端末では、この区別を診断ログと航行計器に出す。既定値を
/// 「この端末だけの設定」と誤表示すると、複数艇で設定が揃っていない理由を
/// 次回のログから特定できなくなる。
class LocalDangerZoneSettingsLoad {
  const LocalDangerZoneSettingsLoad({
    required this.settings,
    required this.hasStoredValues,
  });

  final DangerZoneSettings settings;
  final bool hasStoredValues;
}

class DangerZoneSettingsService {
  static const _prefix = 'danger_zone_offset_v1';

  Future<DangerZoneSettings> load() async {
    return (await loadWithSource()).settings;
  }

  /// 値と、SharedPreferencesに実値があるかを同時に返す。
  ///
  /// 保存値が壊れている場合も [load] と同じく既定値へ縮退するが、保存値が
  /// 存在した事実自体は残す。これにより「共有設定なし・端末設定あり」と
  /// 「共有設定なし・コード既定値」を区別できる。
  Future<LocalDangerZoneSettingsLoad> loadWithSource() async {
    final prefs = await SharedPreferences.getInstance();
    var settings = DangerZoneSettings.defaults();
    var hasStoredValues = false;
    for (final kind in DangerZoneKind.values) {
      final defaults = settings[kind];
      final waterKey = _key(kind, 'water');
      final landKey = _key(kind, 'land');
      hasStoredValues = hasStoredValues ||
          prefs.containsKey(waterKey) ||
          prefs.containsKey(landKey);
      settings = settings.withOffsets(
        kind,
        DangerZoneOffsets(
          waterSideMeters: _validOrDefault(
            prefs.getDouble(waterKey),
            defaults.waterSideMeters,
          ),
          landSideMeters: _validOrDefault(
            prefs.getDouble(landKey),
            defaults.landSideMeters,
          ),
        ),
      );
    }
    return LocalDangerZoneSettingsLoad(
      settings: settings,
      hasStoredValues: hasStoredValues,
    );
  }

  Future<void> save(DangerZoneSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    final defaults = DangerZoneSettings.defaults();
    for (final kind in DangerZoneKind.values) {
      final offsets = settings[kind];
      await prefs.setDouble(
        _key(kind, 'water'),
        _validOrDefault(
          offsets.waterSideMeters,
          defaults[kind].waterSideMeters,
        ),
      );
      await prefs.setDouble(
        _key(kind, 'land'),
        _validOrDefault(
          offsets.landSideMeters,
          defaults[kind].landSideMeters,
        ),
      );
    }
  }

  String _key(DangerZoneKind kind, String side) =>
      '${_prefix}_${kind.name}_$side';

  double _validOrDefault(double? value, double fallback) {
    if (value == null || !value.isFinite || value < minDangerZoneOffsetMeters) {
      return fallback;
    }
    final clamped = value
        .clamp(minDangerZoneOffsetMeters, maxDangerZoneOffsetMeters)
        .toDouble();
    return (clamped / dangerZoneOffsetStepMeters).round() *
        dangerZoneOffsetStepMeters;
  }
}
