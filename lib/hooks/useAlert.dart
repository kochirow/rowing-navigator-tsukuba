import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_hooks/flutter_hooks.dart';

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

  Future<void> play() async {
    await player.value.setVolume(0.5);
    await player.value.setSource(AssetSource('audio/alert_lv1.mp3'));
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
  final Function play;
  final Function stop;
  final Function dispose;

  UseAlert({
    required this.isPlaying,
    required this.play,
    required this.stop,
    required this.dispose,
  });
}
