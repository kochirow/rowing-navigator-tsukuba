import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../types/marker_type.dart';
import '../utils/image2icon.dart';

UseNavMap useNavMap() {
  final mapController = useState<GoogleMapController?>(null);
  final markers = useState<Set<Marker>>({});
  final polylines = useState<Set<Polyline>>({});
  final polygons = useState<Set<Polygon>>({});
  final isReady = useState(false);
  const BLUE_BOAT_ICON_PATH = 'assets/icons/blue_boat.png';
  const RED_BOAT_ICON_PATH = 'assets/icons/red_boat.png';
  const initCamPos = CameraPosition(
    target: LatLng(35.681236, 139.767125), // 東京駅
    zoom: 18.0,
  );

  void setController(GoogleMapController controller) {
    mapController.value = controller;
    isReady.value = true;
  }

  Future<double> getZoomLevel() {
    return mapController.value!.getZoomLevel();
  }

  void setMarkers(Set<Marker> newMarkers) {
    markers.value = newMarkers;
  }

  void setPolylines(Set<Polyline> newPolylines) {
    polylines.value = newPolylines;
  }

  void setPolygons(Set<Polygon> newPolygons) {
    polygons.value = newPolygons;
  }

  Future<Marker> createMarker(String markerId, MarkerType type, double lat,
      double lng, double heading, String title, String snippet) async {
    final zoomLevel = await mapController.value!.getZoomLevel();
    final iconSize = (zoomLevel * 4).toInt(); // ZoomLevelに応じてiconSizeを変更
    BitmapDescriptor icon;
    switch (type) {
      case MarkerType.myBoat:
        icon = await getBitmapDescriptorFromAssetBytes(
            RED_BOAT_ICON_PATH, iconSize);
        break;
      case MarkerType.otherBoat:
        icon = await getBitmapDescriptorFromAssetBytes(
            BLUE_BOAT_ICON_PATH, iconSize);
        break;
    }
    return Marker(
      markerId: MarkerId(markerId),
      position: LatLng(lat, lng),
      icon: icon,
      infoWindow: InfoWindow(title: title, snippet: snippet),
      anchor: const Offset(0.5, 0.5),
      rotation: heading,
      flat: true,
    );
  }

  Marker createHiddenMarker(
    String markerId,
    LatLng position,
    void Function()? onTap,
  ) {
    return Marker(
      markerId: MarkerId(markerId),
      position: position,
      infoWindow: InfoWindow(title: "削除", onTap: onTap),
      anchor: const Offset(0.5, 0), // 表示位置を調整
      alpha: 0, // Markerを非表示
    );
  }

  Polygon createPolygon(
      String polygonId, List<LatLng> points, void Function()? onTap) {
    return Polygon(
      polygonId: PolygonId(polygonId),
      points: points,
      strokeWidth: 2,
      strokeColor: Colors.red,
      fillColor: Colors.red.withOpacity(0.4),
      consumeTapEvents: true, // タップイベントを受け取る
      onTap: onTap,
    );
  }

  Polyline createPolyline(List<LatLng> points) {
    return Polyline(
      polylineId: const PolylineId("drawing_line"),
      points: points,
      width: 2,
      color: Colors.red,
    );
  }

  Future<void> focus(
      double lat, double lng, double heading, double zoomLevel) async {
    CameraPosition camPos;
    camPos = CameraPosition(
      target: LatLng(lat, lng),
      bearing: heading,
      zoom: zoomLevel,
    );
    await mapController.value!.animateCamera(
      CameraUpdate.newCameraPosition(camPos),
    );
  }

  useEffect(() {
    return () {
      mapController.value?.dispose();
    };
  }, []);

  return UseNavMap(
      mapController: mapController.value,
      getZoomLevel: getZoomLevel,
      markers: markers.value,
      polylines: polylines.value,
      polygons: polygons.value,
      isReady: isReady.value,
      setController: setController,
      createMarker: createMarker,
      createHiddenMarker: createHiddenMarker,
      createPolyline: createPolyline,
      createPolygon: createPolygon,
      setMarkers: setMarkers,
      setPolylines: setPolylines,
      setPolygons: setPolygons,
      focus: focus,
      initCamPos: initCamPos);
}

class UseNavMap {
  final GoogleMapController? mapController;
  final Future<double> Function() getZoomLevel;
  final Set<Marker> markers;
  final Set<Polyline> polylines;
  final Set<Polygon> polygons;
  final bool isReady;
  final void Function(GoogleMapController controller) setController;
  final Future<Marker> Function(String markerId, MarkerType type, double lat,
      double lng, double heading, String title, String snippet) createMarker;
  final Marker Function(
          String markerId, LatLng position, void Function()? onTap)
      createHiddenMarker;
  final Polygon Function(
          String polygonId, List<LatLng> points, void Function()? onTap)
      createPolygon;
  final Polyline Function(List<LatLng> points) createPolyline;
  final void Function(Set<Marker> newMarkers) setMarkers;
  final void Function(Set<Polyline> newPolylines) setPolylines;
  final void Function(Set<Polygon> newPolygons) setPolygons;
  final Future<void> Function(
      double lat, double lng, double heading, double zoomLevel) focus;
  final CameraPosition initCamPos;

  UseNavMap({
    required this.mapController,
    required this.getZoomLevel,
    required this.markers,
    required this.polylines,
    required this.polygons,
    required this.isReady,
    required this.setController,
    required this.createMarker,
    required this.createHiddenMarker,
    required this.createPolyline,
    required this.createPolygon,
    required this.setMarkers,
    required this.setPolylines,
    required this.setPolygons,
    required this.focus,
    required this.initCamPos,
  });
}
