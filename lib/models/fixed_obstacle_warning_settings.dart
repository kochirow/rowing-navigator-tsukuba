import 'shared_safety_calibration.dart';

/// 端末ごとの固定対象物に対する警告の有効・無効状態。
///
/// 地図表示・座標校正・チーム共有の形状は変えず、衝突判定と警告だけを
/// 対象外にする。存在しないことが現地で確認された対象を一時的に外す用途を
/// 想定し、共有校正とは別の端末設定として扱う。
class FixedObstacleWarningSettings {
  /// 現地確認により、初回は島2（上流）を警告対象から外す。
  static const defaultDisabledSourceIds =
      SharedSafetyCalibrationState.defaultDisabledWarningSourceIds;

  final Set<String> disabledSourceIds;

  FixedObstacleWarningSettings({
    Set<String> disabledSourceIds = defaultDisabledSourceIds,
  }) : disabledSourceIds = Set.unmodifiable(disabledSourceIds);

  bool isEnabled(String sourceId) => !disabledSourceIds.contains(sourceId);

  FixedObstacleWarningSettings withEnabled(String sourceId, bool enabled) {
    if (!SharedSafetyCalibrationState.allowedSourceIds.contains(sourceId)) {
      throw ArgumentError.value(sourceId, 'sourceId', 'Unknown source ID');
    }
    final next = Set<String>.from(disabledSourceIds);
    if (enabled) {
      next.remove(sourceId);
    } else {
      next.add(sourceId);
    }
    return FixedObstacleWarningSettings(disabledSourceIds: next);
  }
}
