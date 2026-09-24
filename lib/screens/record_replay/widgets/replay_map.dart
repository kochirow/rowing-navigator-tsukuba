import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../../config/record_replay_config.dart';
import '../../../services/record/replay_track.dart';
import '../../../theme/record_palette.dart';
import '../replay_analysis.dart';
import '../replay_controller.dart';

/// 記録画面の地図（アプリと同じ Google Maps）。表示専用。
///
/// 航跡はペースで色分けし（本・区間の中だけ）、選択区間は太く・他は薄く描く。
/// 艇アイコンは再生位置で、向きの矢印つき。地図をタップするとその地点へ再生位置が飛ぶ。
class ReplayMap extends StatefulWidget {
  final ReplayController controller;

  /// 地図の上に重ねる見出し（日時・艇種）。
  final Widget? overlay;

  const ReplayMap({super.key, required this.controller, this.overlay});

  @override
  State<ReplayMap> createState() => _ReplayMapState();
}

class _ReplayMapState extends State<ReplayMap> {
  GoogleMapController? _map;
  BitmapDescriptor? _boatIcon;
  BitmapDescriptor? _startIcon;
  BitmapDescriptor? _endIcon;
  Set<Polyline> _base = const {};
  Set<Polyline> _selected = const {};
  String _selectedKey = '';
  int _fitSeen = 0;
  bool _satellite = false;
  Brightness? _builtFor;

  ReplayController get c => widget.controller;
  ReplayAnalysis get a => c.analysis;

  @override
  void initState() {
    super.initState();
    _fitSeen = c.mapFitRequest;
    _buildIcons();
  }

  Future<void> _buildIcons() async {
    final dpr =
        WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio;
    final boat = await _drawIcon(30, dpr, (canvas, s) {
      final center = Offset(s / 2, s / 2);
      final fill = Paint()..color = const Color(0xFFFF6B4A);
      final path = Path()
        ..moveTo(s / 2, 1)
        ..lineTo(s / 2 + 6, s / 2 - 3)
        ..lineTo(s / 2 - 6, s / 2 - 3)
        ..close();
      canvas.drawPath(path, fill);
      canvas.drawCircle(center, 7, fill);
      canvas.drawCircle(
          center,
          7,
          Paint()
            ..color = Colors.white
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.5);
    });
    Future<BitmapDescriptor> ring(bool filled) =>
        _drawIcon(16, dpr, (canvas, s) {
          final center = Offset(s / 2, s / 2);
          canvas.drawCircle(center, 5.5,
              Paint()..color = filled ? Colors.white : const Color(0xFF07090C));
          canvas.drawCircle(
              center,
              5.5,
              Paint()
                ..color = Colors.white
                ..style = PaintingStyle.stroke
                ..strokeWidth = 3);
        });
    final start = await ring(false), end = await ring(true);
    if (!mounted) return;
    setState(() {
      _boatIcon = boat;
      _startIcon = start;
      _endIcon = end;
    });
  }

  static Future<BitmapDescriptor> _drawIcon(double logicalSize, double dpr,
      void Function(Canvas, double) paint) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)..scale(dpr);
    paint(canvas, logicalSize);
    final size = (logicalSize * dpr).ceil();
    final image = await recorder.endRecording().toImage(size, size);
    try {
      final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!
          .buffer
          .asUint8List();
      return BitmapDescriptor.bytes(bytes, imagePixelRatio: dpr);
    } finally {
      image.dispose();
    }
  }

  /// 同じ色の連続を1本の線にまとめる（線の本数を抑える）。
  List<(Color, List<LatLng>)> _runs(int from, int to, RecordPalette p) {
    final tr = a.track;
    final out = <(Color, List<LatLng>)>[];
    String? key;
    for (var i = math.max(1, from); i <= math.min(tr.length - 1, to); i++) {
      final v = tr.speed[i];
      final rest = v < replayWorkSpeedMps || !a.inBout[i];
      final q = rest ? -1 : (a.paceRatio(500 / v) * 6).round().clamp(0, 6);
      final k = '$q';
      if (k != key) {
        key = k;
        out.add((
          rest ? p.restTrack : RecordPalette.paceRamp(q / 6),
          [LatLng(tr.lat[i - 1], tr.lng[i - 1])],
        ));
      }
      out.last.$2.add(LatLng(tr.lat[i], tr.lng[i]));
    }
    return out;
  }

  void _rebuildLines(RecordPalette p) {
    final tr = a.track;
    if (_builtFor != p.brightness) {
      _builtFor = p.brightness;
      _selectedKey = '';
      var n = 0;
      _base = {
        for (final (color, pts) in _runs(0, tr.length - 1, p))
          Polyline(
            polylineId: PolylineId('b${n++}'),
            points: pts,
            color: color.withValues(alpha: 0.28),
            width: 3,
            zIndex: 1,
            consumeTapEvents: false,
          ),
      };
    }
    final sel = c.selection;
    final key = '${sel.start.toStringAsFixed(1)}_${sel.end.toStringAsFixed(1)}';
    if (key == _selectedKey) return;
    _selectedKey = key;
    final runs = _runs(tr.indexAt(sel.start), tr.indexAt(sel.end) + 1, p);
    var n = 0;
    _selected = {
      for (final (_, pts) in runs)
        Polyline(
          polylineId: PolylineId('c${n++}'),
          points: pts,
          color:
              (p.isDark ? Colors.black : Colors.white).withValues(alpha: 0.55),
          width: 9,
          zIndex: 2,
          startCap: Cap.roundCap,
          endCap: Cap.roundCap,
        ),
      for (final (color, pts) in runs)
        Polyline(
          polylineId: PolylineId('s${n++}'),
          points: pts,
          color: color,
          width: 5,
          zIndex: 3,
          startCap: Cap.roundCap,
          endCap: Cap.roundCap,
          jointType: JointType.round,
        ),
    };
  }

  LatLngBounds? _bounds(ReplayRange r) {
    final tr = a.track;
    if (tr.isEmpty) return null;
    var minLat = 90.0, maxLat = -90.0, minLng = 180.0, maxLng = -180.0;
    for (var i = tr.indexAt(r.start); i <= tr.indexAt(r.end); i++) {
      minLat = math.min(minLat, tr.lat[i]);
      maxLat = math.max(maxLat, tr.lat[i]);
      minLng = math.min(minLng, tr.lng[i]);
      maxLng = math.max(maxLng, tr.lng[i]);
    }
    if (maxLat - minLat < 1e-5) {
      minLat -= 0.001;
      maxLat += 0.001;
    }
    if (maxLng - minLng < 1e-5) {
      minLng -= 0.001;
      maxLng += 0.001;
    }
    return LatLngBounds(
        southwest: LatLng(minLat, minLng), northeast: LatLng(maxLat, maxLng));
  }

  Future<void> _fit(ReplayRange r) async {
    final b = _bounds(r);
    if (b == null || _map == null) return;
    try {
      await _map!.animateCamera(CameraUpdate.newLatLngBounds(b, 48));
    } catch (_) {
      // 地図がまだ配置されていないときは寄せない（表示だけの機能なので黙って続ける）。
    }
  }

  void _onTap(LatLng at) {
    c.pause();
    final tr = a.track;
    var best = -1;
    var bestD = double.infinity;
    final near = <int>[];
    for (var i = 0; i < tr.length; i++) {
      final dy = (tr.lat[i] - at.latitude) * 111320;
      final dx = (tr.lng[i] - at.longitude) *
          111320 *
          math.cos(at.latitude * math.pi / 180);
      final d = math.sqrt(dx * dx + dy * dy);
      if (d < 30) near.add(i);
      if (d < bestD) {
        bestD = d;
        best = i;
      }
    }
    if (bestD > 80 || best < 0) return;
    // 往復で同じ場所を2回通るので、近い点が複数あれば今の再生位置に時刻が近いほう
    final pick = near.isEmpty
        ? best
        : near.reduce((x, y) =>
            (tr.t[x] - c.cursor).abs() <= (tr.t[y] - c.cursor).abs() ? x : y);
    c.seek(tr.t[pick]);
  }

  @override
  Widget build(BuildContext context) {
    final p = RecordPalette.of(context);
    _rebuildLines(p);
    if (c.mapFitRequest != _fitSeen) {
      _fitSeen = c.mapFitRequest;
      WidgetsBinding.instance.addPostFrameCallback((_) => _fit(c.selection));
    }
    final tr = a.track;
    final pos = tr.isEmpty ? null : tr.positionAt(c.cursor);
    final sa = tr.isEmpty ? null : tr.positionAt(c.selection.start);
    final sb = tr.isEmpty ? null : tr.positionAt(c.selection.end);
    final markers = <Marker>{
      if (sa != null && _startIcon != null)
        Marker(
          markerId: const MarkerId('a'),
          position: LatLng(sa.lat, sa.lng),
          icon: _startIcon!,
          anchor: const Offset(0.5, 0.5),
          zIndexInt: 4,
          consumeTapEvents: true,
        ),
      if (sb != null && _endIcon != null)
        Marker(
          markerId: const MarkerId('b'),
          position: LatLng(sb.lat, sb.lng),
          icon: _endIcon!,
          anchor: const Offset(0.5, 0.5),
          zIndexInt: 4,
          consumeTapEvents: true,
        ),
      if (pos != null && _boatIcon != null)
        Marker(
          markerId: const MarkerId('boat'),
          position: LatLng(pos.lat, pos.lng),
          icon: _boatIcon!,
          rotation: pos.heading,
          flat: true,
          anchor: const Offset(0.5, 0.5),
          zIndexInt: 5,
          consumeTapEvents: true,
        ),
    };
    final initial = tr.isEmpty
        ? const LatLng(36.08, 140.21)
        : LatLng(tr.lat[tr.length ~/ 2], tr.lng[tr.length ~/ 2]);
    return Stack(children: [
      Positioned.fill(
        child: GoogleMap(
          initialCameraPosition: CameraPosition(target: initial, zoom: 14),
          mapType: _satellite ? MapType.hybrid : MapType.normal,
          style: p.isDark && !_satellite ? _darkMapStyle : null,
          polylines: {..._base, ..._selected},
          markers: markers,
          myLocationButtonEnabled: false,
          zoomControlsEnabled: false,
          mapToolbarEnabled: false,
          compassEnabled: false,
          onTap: _onTap,
          onMapCreated: (m) {
            _map = m;
            WidgetsBinding.instance
                .addPostFrameCallback((_) => _fit(ReplayRange(0, tr.duration)));
          },
        ),
      ),
      if (widget.overlay != null)
        Positioned(left: 0, right: 0, top: 0, child: widget.overlay!),
      Positioned(
        left: 12,
        bottom: 12,
        child: _Legend(palette: p),
      ),
      Positioned(
        right: 12,
        bottom: 12,
        child: Row(children: [
          _MapButton(
            label: '写真',
            palette: p,
            on: _satellite,
            onTap: () => setState(() => _satellite = !_satellite),
          ),
          const SizedBox(width: 6),
          _MapButton(
            label: '全体',
            palette: p,
            onTap: () => _fit(ReplayRange(0, tr.duration)),
          ),
        ]),
      ),
    ]);
  }
}

class _Legend extends StatelessWidget {
  final RecordPalette palette;
  const _Legend({required this.palette});

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final style =
        TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: p.textSub);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: p.surface.withValues(alpha: 0.82),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: p.line),
      ),
      child: Row(children: [
        Text('遅い', style: style),
        const SizedBox(width: 7),
        Container(
          width: 70,
          height: 6,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(3),
            gradient: LinearGradient(colors: [
              for (var k = 0; k <= 4; k++) RecordPalette.paceRamp(k / 4),
            ]),
          ),
        ),
        const SizedBox(width: 7),
        Text('速い', style: style),
      ]),
    );
  }
}

class _MapButton extends StatelessWidget {
  final String label;
  final RecordPalette palette;
  final bool on;
  final VoidCallback onTap;
  const _MapButton(
      {required this.label,
      required this.palette,
      required this.onTap,
      this.on = false});

  @override
  Widget build(BuildContext context) {
    final p = palette;
    return Material(
      color: on ? p.accent : p.surface.withValues(alpha: 0.82),
      shape: StadiumBorder(side: BorderSide(color: on ? p.accent : p.line)),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 36, minWidth: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Center(
              child: Text(label,
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: on ? p.onAccent : p.text)),
            ),
          ),
        ),
      ),
    );
  }
}

/// 暗いテーマ用の地図スタイル（道路・地名を控えめにし、航跡を主役にする）。
const _darkMapStyle = '''
[
  {"elementType":"geometry","stylers":[{"color":"#1d2127"}]},
  {"elementType":"labels.text.fill","stylers":[{"color":"#8a93a0"}]},
  {"elementType":"labels.text.stroke","stylers":[{"color":"#101318"}]},
  {"featureType":"poi","stylers":[{"visibility":"off"}]},
  {"featureType":"road","elementType":"geometry","stylers":[{"color":"#2a3039"}]},
  {"featureType":"road","elementType":"labels","stylers":[{"visibility":"off"}]},
  {"featureType":"transit","stylers":[{"visibility":"off"}]},
  {"featureType":"water","elementType":"geometry","stylers":[{"color":"#0b0e12"}]},
  {"featureType":"water","elementType":"labels.text.fill","stylers":[{"color":"#56606d"}]}
]
''';
