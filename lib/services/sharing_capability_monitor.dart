/// 位置共有の「能力」を監視する純Dart部品。
///
/// ## なぜ隻数ではなく能力を見るのか
///
/// 2026-08-06 の実機ログで、1台が **2セッション118分**にわたり
/// `positionSharingState = unavailable` のまま走り、他艇を1隻も
/// 受信しなかった。にもかかわらず `dynamic_obstacle_stream_error` は
/// **0件**で、乗員には何も表示されなかった。
/// その端末では他艇警告が原理的に発生し得ないのに、画面上は正常に見えていた。
///
/// 当初は「受信0隻を fault にする」と考えたが、それは誤りである。
/// **0隻は正常状態でもあり得る**(最初に出艇した艇、他艇が全部上がった後)。
/// 「他艇がいない」と「他艇を受信できる状態を確認できない」は別物であり、
/// 後者だけを fault にしなければならない(原則6)。
///
/// そこで隻数ではなく、共有が成立するための**能力**を分解して持つ。
///
/// ## 音は足さない
///
/// この fault は**表示のみ**である。漕ぎながら対処できない情報を
/// 読み上げると、本当に鳴るべき衝突警告を覆い隠す(原則4)。
library;

/// RTDB の認可状態。
enum SharingAuthorization {
  /// 認可されている(書き込み・購読が通っている)。
  granted,

  /// `permission-denied`。Rules かチーム所属の問題。再試行では直らない。
  denied,

  /// まだ判定できていない。
  unknown,
}

/// 位置共有の能力スナップショット。
class SharingCapability {
  /// 送信の初期設定(clear + onDisconnect 登録)が完了したか。
  final bool publishSetupComplete;

  /// 最後に送信が ACK されてからの経過。null は一度も ACK されていない。
  final Duration? sinceLastPublishAck;

  /// 他艇ストリームの購読が接続できているか。
  final bool subscriptionConnected;

  final SharingAuthorization authorization;

  /// サーバ時刻オフセットの鮮度。null は未取得。
  final Duration? serverTimeOffsetAge;

  /// 最後に他艇の更新を受け取ってからの経過。null は一度も受け取っていない。
  final Duration? sinceLastRemoteUpdate;

  /// チーム名簿を取得できているか。
  final bool rosterAvailable;

  const SharingCapability({
    this.publishSetupComplete = false,
    this.sinceLastPublishAck,
    this.subscriptionConnected = false,
    this.authorization = SharingAuthorization.unknown,
    this.serverTimeOffsetAge,
    this.sinceLastRemoteUpdate,
    this.rosterAvailable = false,
  });

  /// 他艇を受信できる状態だと確認できているか。
  ///
  /// **「他艇が0隻かどうか」は見ない。** 隻数は正常でも0になり得る。
  bool get isReceiveCapabilityConfirmed =>
      subscriptionConnected && authorization != SharingAuthorization.denied;

  /// 自艇の位置を他艇へ届けられる状態だと確認できているか。
  bool get isPublishCapabilityConfirmed =>
      publishSetupComplete && authorization != SharingAuthorization.denied;

  Map<String, Object?> toDiagnosticDetails() => {
        'publishSetupComplete': publishSetupComplete,
        'sinceLastPublishAckMs': sinceLastPublishAck?.inMilliseconds,
        'subscriptionConnected': subscriptionConnected,
        'authorization': authorization.name,
        'serverTimeOffsetAgeMs': serverTimeOffsetAge?.inMilliseconds,
        'sinceLastRemoteUpdateMs': sinceLastRemoteUpdate?.inMilliseconds,
        'rosterAvailable': rosterAvailable,
        'receiveCapabilityConfirmed': isReceiveCapabilityConfirmed,
        'publishCapabilityConfirmed': isPublishCapabilityConfirmed,
      };
}

/// 能力が確認できない状態が続いたら fault を立てる。
///
/// 起動直後は確立に数秒かかるのが正常なので、
/// [confirmDuration] のあいだは待つ。回復したら即座に解除する(非対称)。
class SharingCapabilityMonitor {
  SharingCapabilityMonitor({
    this.confirmDuration = const Duration(seconds: 60),
  });

  /// 能力未確認を fault へ昇格させるまでの継続時間。
  ///
  /// 起動直後の `ack_timeout` は A・D でも起きていた(一時的)。
  /// 一方 B/E は118分ずっと復帰しなかった。
  /// 数秒の確立待ちで鳴らさず、恒常的な不成立だけを拾う長さにする。
  final Duration confirmDuration;

  DateTime? _degradedSince;
  bool _faulted = false;

  bool get isFaulted => _faulted;

  /// 現在の能力を反映し、fault とみなすべきかを返す。
  bool update(SharingCapability capability, {required DateTime at}) {
    // 認可が明確に拒否されているときは、待たずに即座に fault にする。
    // 再試行で直る種類の障害ではないため、待つ意味がない。
    if (capability.authorization == SharingAuthorization.denied) {
      _degradedSince = _degradedSince ?? at;
      _faulted = true;
      return _faulted;
    }
    final degraded = !capability.isReceiveCapabilityConfirmed ||
        !capability.isPublishCapabilityConfirmed;
    if (!degraded) {
      _degradedSince = null;
      _faulted = false;
      return _faulted;
    }
    final since = _degradedSince;
    if (since == null || at.isBefore(since)) {
      // 時刻が巻き戻ったら基点を引き直す。巻き戻りで即座に確定しない。
      _degradedSince = at;
      return _faulted;
    }
    if (at.difference(since) >= confirmDuration) {
      _faulted = true;
    }
    return _faulted;
  }

  void reset() {
    _degradedSince = null;
    _faulted = false;
  }
}

/// 送信失敗の原因分類と、再試行してよいか。
///
/// 2026-08-06 の実機ログでは、C が起動直後に `permission-denied` を3回、
/// A・D が `ack_timeout` を数回出していた。**起動直後の共有確立は
/// 全端末で不安定**である。ただし原因によって正しい対処が違う。
enum SharingFailureKind {
  /// 通信タイムアウト・圏外。時間で直る。
  transientTimeout,

  /// 一時的な切断。すぐ1回試して、それでも駄目ならバックオフ。
  transientDisconnect,

  /// `permission-denied`。Rules・チーム所属・認証の問題。
  /// **無限に再試行しない。** 何度試しても直らず、電池と転送量を捨てるだけ。
  permissionDenied,

  /// データ契約の不一致。アプリ側の互換性問題。再試行しない。
  invalidDataContract,
}

extension SharingFailureRetryPolicy on SharingFailureKind {
  /// 再試行してよいか。
  bool get isRetryable => switch (this) {
        SharingFailureKind.transientTimeout => true,
        SharingFailureKind.transientDisconnect => true,
        SharingFailureKind.permissionDenied => false,
        SharingFailureKind.invalidDataContract => false,
      };

  /// [attempt] 回目(1始まり)の再試行までの待ち時間。
  ///
  /// jitter は呼出側で足す。ここは純関数に保つ。
  Duration backoffFor(int attempt) {
    if (!isRetryable) return Duration.zero;
    if (this == SharingFailureKind.transientDisconnect && attempt <= 1) {
      // 一時切断は、まず即座に1回試す。
      return Duration.zero;
    }
    final exponent = (attempt - 1).clamp(0, 6);
    final seconds = (1 << exponent).clamp(1, 60);
    return Duration(seconds: seconds);
  }
}

/// Firebase の errorCode から原因を分類する。
SharingFailureKind classifySharingFailure({
  String? errorCode,
  String? errorType,
}) {
  final code = errorCode?.toLowerCase() ?? '';
  if (code.contains('permission-denied') || code.contains('unauthorized')) {
    return SharingFailureKind.permissionDenied;
  }
  if (code.contains('invalid') || code.contains('validation')) {
    return SharingFailureKind.invalidDataContract;
  }
  if (code.contains('disconnect') || code.contains('unavailable')) {
    return SharingFailureKind.transientDisconnect;
  }
  final type = errorType?.toLowerCase() ?? '';
  if (type.contains('timeout')) return SharingFailureKind.transientTimeout;
  return SharingFailureKind.transientTimeout;
}
