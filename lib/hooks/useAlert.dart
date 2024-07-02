import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_hooks/flutter_hooks.dart';

import '../types/alert_type.dart';

UseAlert useAlert() {
  final player = useState(AudioPlayer());
  final state = useState<PlayerState>(PlayerState.stopped);

  useEffect(() {
    Future(() async {
      player.value.setPlayerMode(PlayerMode.lowLatency);
      AudioCache.instance.loadAll([
        'audio/alert_lv1.mp3',
        'audio/alert_lv2.mp3',
        'audio/alert_lv3.mp3',
      ]);
    });
    return () async {
      await player.value.stop();
      await player.value.dispose();
    };
  }, []);

  Future<void> play(AlertType type) async {
    AssetSource source;
    switch (type) {
      case AlertType.caution:
        source = AssetSource('audio/alert_lv1.mp3');
        break;
      case AlertType.warning:
        source = AssetSource('audio/alert_lv2.mp3');
        break;
      case AlertType.critical:
        source = AssetSource('audio/alert_lv3.mp3');
        break;
      case AlertType.emergency:
        source = AssetSource('audio/alert_lv4.mp3');
        break;
    }
    await player.value.setVolume(0.5); // for dev
    await player.value.setSource(source);
    await player.value.setReleaseMode(ReleaseMode.loop);
    await player.value.resume();
    state.value = PlayerState.playing;
  }

  Future<void> stop() async {
    await player.value.stop();
    state.value = PlayerState.stopped;
  }

  Future<void> dispose() async {
    await player.value.dispose();
    state.value = PlayerState.stopped;
  }

  return UseAlert(
    isPlaying: state.value == PlayerState.playing,
    play: play,
    stop: stop,
    dispose: dispose,
  );
}

class UseAlert {
  final bool isPlaying;
  final Future<void> Function(AlertType type) play;
  final Future<void> Function() stop;
  final Future<void> Function() dispose;

  UseAlert({
    required this.isPlaying,
    required this.play,
    required this.stop,
    required this.dispose,
  });
}
