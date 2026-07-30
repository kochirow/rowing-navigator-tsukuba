import '../config/warning_audio_config.dart';
import '../models/alert_candidate.dart';
import '../models/navigation_warning.dart';
import '../models/static_obstacle_model.dart';
import '../types/collision_risk_level.dart';
import 'collision_risk_evaluator_service.dart';

class NavigationWarningService {
  /// system fault は画面表示だけにし、音声モードも明示的に none とする。
  /// 既定音へフォールバックするとオーケストレータで外した音が復活するため、
  /// 候補が持つ null をそのまま保つ。
  NavigationWarning? fromCandidate(AlertCandidate? candidate) {
    if (candidate == null) return null;
    final audioMode = switch (candidate.behavior) {
      AlertBehavior.continuousAction => WarningAudioMode.loop,
      AlertBehavior.singleAction => WarningAudioMode.once,
      AlertBehavior.entryEvent => WarningAudioMode.once,
      AlertBehavior.visualOnly => WarningAudioMode.none,
      AlertBehavior.persistentSystemFault => WarningAudioMode.none,
    };
    // 画面の切迫度は、音の鳴り方をそのまま写すだけにする。ここで別の
    // しきい値を持つと、鳴っている音と見えている段階がずれる。
    final urgency = _urgencyOf(candidate.behavior);

    if (candidate.category == 'other_boat') {
      return NavigationWarning(
        key: candidate.alertId,
        category: candidate.category,
        title: '他艇に接近',
        message: '',
        audioAsset: candidate.behavior == AlertBehavior.visualOnly
            ? null
            : candidate.audioAsset ?? otherBoatWarningAudioAsset,
        audioMode: audioMode,
        urgency: urgency,
        audioEventId: candidate.audioEventId,
        timeUntilDanger: _timeUntilDanger(candidate),
        relativeBearingDegrees: candidate.relativeBearingDegrees,
      );
    }
    if (candidate.category == 'gps_unavailable') {
      return NavigationWarning(
        key: candidate.alertId,
        category: candidate.category,
        title: 'GPSが途絶',
        message: '衝突予測を継続できません。周囲を目視確認してください',
        audioAsset: candidate.audioAsset,
        audioMode: audioMode,
        urgency: urgency,
      );
    }
    if (candidate.category == 'position_sharing_unavailable') {
      return NavigationWarning(
        key: candidate.alertId,
        category: candidate.category,
        title: '位置共有が停止',
        message: '他艇から自艇を検知できません。周囲を目視確認してください',
        audioAsset: candidate.audioAsset,
        audioMode: audioMode,
        urgency: urgency,
      );
    }
    if (candidate.category == 'other_boat_receive_unavailable') {
      return NavigationWarning(
        key: candidate.alertId,
        category: candidate.category,
        title: '他艇情報を受信できません',
        message: '他艇接近の検知能力が低下しています。周囲を目視確認してください',
        audioAsset: candidate.audioAsset,
        audioMode: audioMode,
        urgency: urgency,
      );
    }
    if (candidate.category == 'other_boat_track_lost') {
      return NavigationWarning(
        key: candidate.alertId,
        category: candidate.category,
        title: '警告中の他艇情報が途絶',
        message: '最後に接近していた他艇を目視確認してください',
        audioAsset: candidate.audioAsset,
        audioMode: audioMode,
        urgency: urgency,
      );
    }
    if (candidate.category == 'static_profile_unavailable') {
      return NavigationWarning(
        key: candidate.alertId,
        category: candidate.category,
        title: '危険区域データを読み込めません',
        message: '固定危険区域の警告能力が利用できません',
        audioAsset: candidate.audioAsset,
        audioMode: audioMode,
        urgency: urgency,
      );
    }
    if (candidate.category == 'outside_operational_coverage') {
      return NavigationWarning(
        key: candidate.alertId,
        category: candidate.category,
        title: '対応水域の範囲外です',
        message: 'この位置の固定危険区域は未検証です。通常の目視確認を継続してください',
        audioAsset: candidate.audioAsset,
        audioMode: audioMode,
        urgency: urgency,
      );
    }
    if (candidate.category == 'operational_coverage_unverified') {
      return NavigationWarning(
        key: candidate.alertId,
        category: candidate.category,
        title: '対応水域が未設定です',
        message: '固定危険区域の網羅範囲は未検証です。警告は継続します',
        audioAsset: candidate.audioAsset,
        audioMode: audioMode,
        urgency: urgency,
      );
    }
    if (candidate.category == 'audio_unavailable') {
      return NavigationWarning(
        key: candidate.alertId,
        category: candidate.category,
        title: '警告音を再生できません',
        message: '画面表示を確認し、音量・Bluetooth接続を点検してください',
        audioAsset: null,
        audioMode: audioMode,
        urgency: urgency,
      );
    }
    if (candidate.category == 'pipeline_unresponsive') {
      return NavigationWarning(
        key: candidate.alertId,
        category: candidate.category,
        title: '警告処理の停止を検出',
        message: '画面ロック中などに処理が途切れました。周囲を目視確認してください',
        audioAsset: candidate.audioAsset,
        audioMode: audioMode,
        urgency: urgency,
      );
    }

    StaticObstacleKind kind;
    try {
      kind = StaticObstacleKind.values.byName(candidate.category);
    } catch (_) {
      kind = StaticObstacleKind.generic;
    }
    return NavigationWarning(
      key: candidate.alertId,
      category: candidate.category,
      title: _titleFor(kind),
      message: '',
      audioAsset: candidate.behavior == AlertBehavior.visualOnly
          ? null
          : candidate.audioAsset ?? defaultWarningAudioAssetFor(kind),
      audioMode: audioMode,
      urgency: urgency,
      audioEventId: candidate.audioEventId,
      timeUntilDanger: _timeUntilDanger(candidate),
      relativeBearingDegrees: candidate.relativeBearingDegrees,
    );
  }

  /// 音の鳴り方から画面の切迫度を導出する。判定は一切増やさない。
  static WarningDisplayUrgency _urgencyOf(AlertBehavior behavior) =>
      switch (behavior) {
        AlertBehavior.continuousAction => WarningDisplayUrgency.imminent,
        AlertBehavior.singleAction => WarningDisplayUrgency.action,
        AlertBehavior.entryEvent => WarningDisplayUrgency.action,
        AlertBehavior.visualOnly => WarningDisplayUrgency.monitoring,
        AlertBehavior.persistentSystemFault => WarningDisplayUrgency.action,
      };

  List<NavigationWarning> fromCandidates(
    Iterable<AlertCandidate> candidates,
  ) =>
      candidates.map(fromCandidate).whereType<NavigationWarning>().toList(
            growable: false,
          );

  NavigationWarning? fromAssessment(RiskAssessment assessment) {
    if (assessment.level == CollisionRiskLevel.lv0) return null;

    final threat = assessment.primaryThreat;
    if (threat == null) {
      return const NavigationWarning(
        key: 'generic',
        category: 'generic',
        title: '衝突のおそれ',
        message: '後方を振り向いて周囲を目視確認してください',
        audioAsset: genericWarningAudioAsset,
      );
    }

    if (threat.kind == ThreatKind.boat) {
      return NavigationWarning(
        key: 'boat:${threat.boatId ?? 'unknown'}',
        category: 'other_boat',
        title: '他艇に接近',
        message: '',
        audioAsset: otherBoatWarningAudioAsset,
        timeUntilDanger: _timeUntilDangerFromThreat(threat),
        relativeBearingDegrees: threat.relativeBearingDegrees,
      );
    }

    final kind = threat.obstacleKind ?? StaticObstacleKind.generic;
    final label = threat.obstacleName ?? kind.displayLabel;
    return NavigationWarning(
      key: 'obstacle:${threat.obstacleId ?? kind.name}',
      category: kind.name,
      title: kind == StaticObstacleKind.shore
          ? '岸に接近'
          : kind.isEntryGuidance
              ? _titleFor(kind)
              : '$labelに接近',
      message: '',
      audioAsset: threat.warningAudioAsset ?? defaultWarningAudioAssetFor(kind),
      timeUntilDanger: _timeUntilDangerFromThreat(threat),
      relativeBearingDegrees: threat.relativeBearingDegrees,
    );
  }

  static Duration? _timeUntilDanger(AlertCandidate candidate) =>
      candidate.isPredicted ? candidate.actionDeadline : null;

  static Duration? _timeUntilDangerFromThreat(ThreatInfo threat) {
    final intersection = threat.continuousIntersection;
    final seconds = intersection?.firstEntryTimeSeconds;
    if (intersection == null ||
        intersection.currentOverlap ||
        seconds == null ||
        !seconds.isFinite) {
      return null;
    }
    return Duration(milliseconds: (seconds.clamp(0, 3600) * 1000).round());
  }

  static String _titleFor(StaticObstacleKind kind) => switch (kind) {
        StaticObstacleKind.shore => '岸に接近',
        StaticObstacleKind.bridge => '橋に接近',
        StaticObstacleKind.bridgePier => '橋脚に接近',
        StaticObstacleKind.island => '中洲に接近',
        StaticObstacleKind.driftwood => '流木に接近',
        StaticObstacleKind.curve => 'カーブ注意',
        StaticObstacleKind.reverse => '逆走注意',
        StaticObstacleKind.testZone => 'テスト区域に接近',
        StaticObstacleKind.generic => '危険区域に接近',
      };
}
