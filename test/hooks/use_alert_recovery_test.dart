// 偽の音声プラットフォームを差し込むため、audioplayers の内部 API を使う。
// ignore_for_file: depend_on_referenced_packages, implementation_imports
import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:audioplayers_platform_interface/audioplayers_platform_interface.dart';
import 'package:audioplayers_platform_interface/src/audioplayers_platform.dart';
import 'package:audioplayers_platform_interface/src/global_audioplayers_platform.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/hooks/use_alert.dart';

class _FakeCache extends AudioCache {
  @override
  Future<Uri> load(String file) async => Uri.parse('file:///test/$file');

  @override
  Future<String> loadPath(String file) async => '/test/$file';
}

class _FakeGlobal extends GlobalAudioplayersPlatform {
  @override
  Future<void> init() async {}

  @override
  Stream<GlobalAudioEvent> getGlobalEventStream() => const Stream.empty();

  @override
  Future<void> setGlobalAudioContext(AudioContext context) async {}
}

/// 再生位置が進まない(=鳴っていない)プレイヤー。復旧の初回だけ
/// pause の後の音声設定で一過性の失敗を返せる。
class _StalledPlatform extends AudioplayersPlatform {
  final events = <String, StreamController<AudioEvent>>{};
  int pauseCount = 0;
  int resumeCount = 0;
  bool failNextRecoveryContext = false;

  @override
  Future<void> create(String id) async {
    events[id] = StreamController.broadcast();
  }

  @override
  Stream<AudioEvent> getEventStream(String id) => events[id]!.stream;

  @override
  Future<void> dispose(String id) async {}

  @override
  Future<void> setAudioContext(String id, AudioContext context) async {
    if (failNextRecoveryContext && pauseCount > 0) {
      failNextRecoveryContext = false;
      throw PlatformException(code: 'transient_failure');
    }
  }

  @override
  Future<void> setPlayerMode(String id, PlayerMode mode) async {}

  @override
  Future<void> setReleaseMode(String id, ReleaseMode mode) async {}

  @override
  Future<void> setVolume(String id, double volume) async {}

  @override
  Future<void> stop(String id) async {}

  @override
  Future<void> release(String id) async {}

  @override
  Future<void> pause(String id) async => pauseCount++;

  @override
  Future<void> resume(String id) async => resumeCount++;

  @override
  Future<int?> getCurrentPosition(String id) async => 0;

  @override
  Future<int?> getDuration(String id) async => 1000;

  @override
  Future<void> setSourceUrl(
    String id,
    String url, {
    bool? isLocal,
    String? mimeType,
  }) async {
    events[id]!.add(const AudioEvent(
      eventType: AudioEventType.prepared,
      isPrepared: true,
    ));
  }

  @override
  Future<void> seek(String id, Duration position) async {
    events[id]!.add(const AudioEvent(eventType: AudioEventType.seekComplete));
  }
}

void main() {
  // 2026-10-29 監査 F06: 復旧が pause の後で1回失敗すると paused のまま残り、
  // 監視が「playingなのに進まない」にしか反応しないため二度と復旧されなかった。
  testWidgets('ループ警告の復旧が1回失敗しても再試行し、続けば故障を表示する',
      (tester) async {
    final platform = _StalledPlatform();
    AudioplayersPlatformInterface.instance = platform;
    GlobalAudioplayersPlatformInterface.instance = _FakeGlobal();
    AudioCache.instance = _FakeCache();
    late UseAlert api;
    final diagnostics = <String>[];
    await tester.pumpWidget(HookBuilder(builder: (_) {
      api = useAlert(onDiagnosticEvent: (type, _) => diagnostics.add(type));
      return const SizedBox();
    }));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 1));
    }
    var started = false;
    unawaited(api.play('audio/test.mp3').then((_) => started = true));
    for (var i = 0; i < 50 && !started; i++) {
      await tester.pump(const Duration(milliseconds: 1));
    }
    expect(started, isTrue);
    platform.failNextRecoveryContext = true;

    // 監視は DateTime.now を直接使うので、実時間も進める。
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(seconds: 1)));
      await tester.pump(const Duration(seconds: 1));
      for (var j = 0; j < 5; j++) {
        await tester.pump();
      }
    }

    final failures =
        diagnostics.where((type) => type == 'audio_recovery_failed').length;
    expect(failures, greaterThanOrEqualTo(3), reason: '1回の失敗で止まらない');
    expect(platform.resumeCount, greaterThan(2));
    expect(api.error.value, isNotNull, reason: '3回失敗したら故障を表示する');

    var stopped = false;
    unawaited(api.stop().then((_) => stopped = true));
    for (var i = 0; i < 50 && !stopped; i++) {
      await tester.pump(const Duration(milliseconds: 1));
    }
    await tester.pumpWidget(const SizedBox());
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 1));
    }
  });
}
