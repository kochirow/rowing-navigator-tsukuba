import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../services/record/range_analyzer.dart';
import '../../services/record/record_chart_model.dart';
import '../../services/record/replay_track.dart';
import '../../services/record/training_set_detector.dart';
import 'replay_analysis.dart';

/// 記録画面の状態の持ち主（設計書 芯1「時刻は1つ、区間は1つ」）。
///
/// 地図・時間軸・数値・グラフは、ここの [cursor] と [selection] を描くだけにする。
/// 部品どうしが直接やり取りしないので、「地図では3分、グラフでは4分」のような
/// 食い違いが原理的に起きない。
class ReplayController extends ChangeNotifier {
  final ReplayAnalysis analysis;

  ReplayController(this.analysis)
      : _selection = ReplayRange(0, analysis.track.duration),
        _timelineView = ReplayRange(0, analysis.track.duration);

  static const playbackSpeeds = [10, 30, 60, 100, 200];

  double _cursor = 0;
  ReplayRange _selection;
  ReplayRange _timelineView;
  ChartMetric _metric = ChartMetric.pace;
  ChartXAxis _axis = ChartXAxis.time;
  ChartZoom _zoom = ChartZoom.none;
  int _speed = 30;
  Timer? _timer;
  DateTime? _lastTick;

  /// 地図を選択区間へ寄せる要求の番号（増えたら地図が寄せる）。
  int _mapFitRequest = 0;
  bool _disposed = false;

  ReplayTrack get track => analysis.track;
  double get duration => track.duration;
  double get cursor => _cursor;
  ReplayRange get selection => _selection;
  ReplayRange get timelineView => _timelineView;
  ChartMetric get metric => _metric;
  ChartXAxis get axis => _axis;
  ChartZoom get zoom => _zoom;
  int get speed => _speed;
  bool get isPlaying => _timer != null;
  int get mapFitRequest => _mapFitRequest;
  bool get isTimelineZoomed =>
      _timelineView.start > 0.5 || _timelineView.end < duration - 0.5;

  bool get isAll => _selection.start <= 0.5 && _selection.end >= duration - 0.5;

  static bool _same(ReplayRange a, ReplayRange b) =>
      (a.start - b.start).abs() < 0.5 && (a.end - b.end).abs() < 0.5;

  /// 選択区間がセットと一致していれば、そのセット。
  TrainingSet? get selectedSet {
    for (final s in analysis.sets) {
      if (_same(s.range, _selection)) return s;
    }
    return null;
  }

  /// 選択区間が本・区間と一致していれば、その本（セットと一致するときは null）。
  TrainingBout? get selectedBout {
    if (selectedSet != null) return null;
    for (final s in analysis.sets) {
      for (final b in s.bouts) {
        if (_same(b.range, _selection)) return b;
      }
    }
    return null;
  }

  /// 選択区間の統計。セットなら本・区間の中だけで出す。
  RangeStats get selectionStats {
    final set = selectedSet;
    if (set != null) return set.stats;
    return analysis.analyzer.stats(_selection);
  }

  /// グラフに並べる区画（セットなら本ごと、それ以外は選択区間ひとつ）。
  List<ReplayRange> get chartRanges {
    final set = selectedSet;
    if (set != null && set.bouts.length > 1) {
      return [for (final b in set.bouts) b.range];
    }
    return [_selection];
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  void seek(double time) {
    _cursor = time.clamp(0.0, duration);
    _changed();
  }

  void select(ReplayRange range, {bool fitMap = true, double? cursorAt}) {
    var a = math.max(0.0, math.min(range.start, range.end));
    var b = math.min(duration, math.max(range.start, range.end));
    if (b - a < 2) b = math.min(duration, a + 2);
    if (b - a < 2) a = math.max(0, b - 2);
    _selection = ReplayRange(a, b);
    _zoom = ChartZoom.none;
    if (cursorAt != null) {
      _cursor = cursorAt.clamp(a, b);
    } else if (!_selection.contains(_cursor)) {
      _cursor = a;
    }
    if (_selection.start < _timelineView.start ||
        _selection.end > _timelineView.end) {
      _timelineView = ReplayRange(0, duration);
    }
    if (fitMap) _mapFitRequest++;
    _changed();
  }

  void selectAll() {
    _timelineView = ReplayRange(0, duration);
    select(ReplayRange(0, duration), cursorAt: 0);
  }

  void selectSet(TrainingSet set) => select(set.range);
  void selectBout(TrainingBout bout, {double? cursorAt}) =>
      select(bout.range, cursorAt: cursorAt);

  /// 時間軸をタップ: セットを選び、選ばれたセットの中をもう一度タップするとその本を選ぶ。
  void tapTimeline(double time) {
    final set = analysis.setAt(time);
    _cursor = time.clamp(0.0, duration);
    if (set == null) {
      _changed();
      return;
    }
    final bout = analysis.boutAt(time);
    if (selectedSet == set && bout != null && set.bouts.length > 1) {
      selectBout(bout, cursorAt: time);
    } else {
      select(set.range, cursorAt: time);
    }
  }

  /// 選択区間の端を [seconds] 秒動かす（区間の微調整）。
  void nudge({required bool start, required double seconds}) {
    final a = start
        ? (_selection.start + seconds).clamp(0.0, _selection.end - 2)
        : _selection.start;
    final b = start
        ? _selection.end
        : (_selection.end + seconds).clamp(_selection.start + 2, duration);
    select(ReplayRange(a, b), fitMap: false, cursorAt: start ? a : b);
  }

  void setStartAtCursor() {
    if (_cursor >= _selection.end - 1) return;
    select(ReplayRange(_cursor, _selection.end),
        fitMap: false, cursorAt: _cursor);
  }

  void setEndAtCursor() {
    if (_cursor <= _selection.start + 1) return;
    select(ReplayRange(_selection.start, _cursor),
        fitMap: false, cursorAt: _cursor);
  }

  void zoomTimelineToSelection() {
    final m = math.max(10.0, _selection.duration * 0.06);
    _timelineView = ReplayRange(math.max(0, _selection.start - m),
        math.min(duration, _selection.end + m));
    _changed();
  }

  void resetTimeline() {
    _timelineView = ReplayRange(0, duration);
    _changed();
  }

  void setMetric(ChartMetric m) {
    _metric = m;
    _changed();
  }

  void setAxis(ChartXAxis a) {
    _axis = a;
    _zoom = ChartZoom.none;
    _changed();
  }

  void setZoom(ChartZoom z) {
    _zoom = z;
    _changed();
  }

  void setSpeed(int s) {
    _speed = s;
    _changed();
  }

  void togglePlay() => isPlaying ? pause() : play();

  void play() {
    if (isPlaying || duration <= 0) return;
    final end = _selection.contains(_cursor) && _cursor < _selection.end - 0.5
        ? _selection.end
        : duration;
    if (_cursor >= end - 0.5) {
      _cursor = end == _selection.end ? _selection.start : 0;
    }
    _lastTick = DateTime.now();
    _timer = Timer.periodic(const Duration(milliseconds: 50), (_) => _tick());
    _changed();
  }

  void pause() {
    _timer?.cancel();
    _timer = null;
    _changed();
  }

  void _tick() {
    final now = DateTime.now();
    final dt = math.min(0.1, now.difference(_lastTick!).inMilliseconds / 1000);
    _lastTick = now;
    final inSelection =
        _cursor >= _selection.start && _cursor <= _selection.end + _speed * 0.1;
    final end = inSelection ? _selection.end : duration;
    _cursor += _speed * dt;
    if (_cursor >= end) {
      _cursor = end;
      pause();
      return;
    }
    if (_cursor > _timelineView.end || _cursor < _timelineView.start) {
      _timelineView = ReplayRange(0, duration);
    }
    _changed();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
