import '../models/alert_candidate.dart';
import '../models/safety_snapshot.dart';

/// 位置共有に載せる、記録専用の提示状態を符号化する。
///
/// このクラスは SafetySnapshot だけを読み、受信値を安全判定や地図表示へ
/// 戻す経路を持たない。protocolVersionを上げずに後方互換で追加するため、
/// 警告が無いときの `w` は null (省略) にする。
class PresentationStateCodec {
  static const _categoryCodes = <String, String>{
    'other_boat': 'o',
    'bridge': 'b',
    'bridgePier': 'p',
    'shore': 's',
    'island': 'i',
    'driftwood': 'd',
    'curve': 'c',
    'reverse': 'r',
  };

  static String? warningFor(SafetySnapshot? snapshot) {
    if (snapshot == null) return null;
    final selected = _selectedAlert(snapshot);
    if (selected == null) return null;
    return '${_bandCode(snapshot, selected)}${_categoryCode(selected)}';
  }

  static String? runModeFor(SafetySnapshot? snapshot) =>
      switch (snapshot?.runMode) {
        SafetyRunMode.runningFull => 'f',
        SafetyRunMode.runningDegraded => 'd',
        SafetyRunMode.unavailable => 'u',
        _ => null,
      };

  static ActiveAlert? _selectedAlert(SafetySnapshot snapshot) {
    final audioId = snapshot.audioDirective?.alertId;
    if (audioId != null) {
      for (final alert in snapshot.activeAlerts) {
        if (alert.candidate.alertId == audioId) return alert;
      }
    }
    final primaryId = snapshot.primaryAlertId;
    if (primaryId != null) {
      for (final alert in snapshot.activeAlerts) {
        if (alert.candidate.alertId == primaryId) return alert;
      }
    }
    return null;
  }

  /// 記録するのは「実際にどう鳴っていたか」であって、警告の種類ではない。
  ///
  /// `AlertBehavior` から作ると、衝突警告に負けて無音になった
  /// カーブ・逆走を「鳴った」として残す嘘が入る。
  ///
  /// 音声チャンネルは1本しかないので、`audioDirective` の対象と鳴らし方が
  /// そのまま「聞こえていたはずの音」である(原則5: まずさと切迫度を混ぜない)。
  static String _bandCode(SafetySnapshot snapshot, ActiveAlert alert) {
    final directive = snapshot.audioDirective;
    if (directive == null || directive.alertId != alert.candidate.alertId) {
      return '0'; // 表示のみ
    }
    return switch (directive.mode) {
      AudioDirectiveMode.loop => '2', // 連続音
      AudioDirectiveMode.playOnce => '1',
    };
  }

  /// system fault は種類が増えるため、カテゴリ名の部分一致で拾わない。
  /// `pipeline_unresponsive` のように 'fault' も 'unavailable' も
  /// 含まない名前があり、取りこぼすと fault が generic に混ざる。
  static String _categoryCode(ActiveAlert alert) =>
      alert.candidate.behavior == AlertBehavior.persistentSystemFault
          ? 'f'
          : _categoryCodes[alert.candidate.category] ?? 'g';
}
