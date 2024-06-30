import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../types/marker_type.dart';
import '../utils/image2icon.dart';

UseNavMap useNavMap() {
  final mapController = useState<GoogleMapController?>(null);
  final markers = useState<Set<Marker>>({});
  final isReady = useState(false);
  const BLUE_BOAT_ICON_PATH = 'assets/icons/blue_boat.png';
  const RED_BOAT_ICON_PATH = 'assets/icons/red_boat.png';
  const initCamPos = CameraPosition(
    target: LatLng(35.681236, 139.767125), // 東京駅
    zoom: 16.0,
  );

  void setController(GoogleMapController controller) {
    mapController.value = controller;
    isReady.value = true;
  }

  void setMarkers(Set<Marker> newMarkers) {
    markers.value = {...newMarkers};
  }

  Future<Marker> createMarker(String markerId, MarkerType type, double lat,
      double lng, double heading, String title, String snippet) async {
    final zoomLevel = await mapController.value!.getZoomLevel();
    final iconSize = (zoomLevel * 4).toInt(); // ZoomLevelに応じてiconSizeを変更
    // TODO: MarkerType次第でアイコンの種類を変更
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
    );
  }

  Future<void> focus(double lat, double lng) async {
    final zoomLevel = await mapController.value!.getZoomLevel();
    await mapController.value!.animateCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(
          target: LatLng(lat, lng),
          zoom: zoomLevel,
        ),
      ),
    );
  }

  useEffect(() {
    return () {
      mapController.value?.dispose();
    };
  }, []);

  return UseNavMap(
      mapController: mapController.value,
      markers: markers.value,
      isReady: isReady.value,
      setController: setController,
      createMarker: createMarker,
      setMarkers: setMarkers,
      focus: focus,
      initCamPos: initCamPos);
}

class UseNavMap {
  final GoogleMapController? mapController;
  final Set<Marker> markers;
  final bool isReady;
  final Function setController;
  final Function createMarker;
  final Function setMarkers;
  final Function focus;
  final CameraPosition initCamPos;

  UseNavMap({
    required this.mapController,
    required this.markers,
    required this.isReady,
    required this.setController,
    required this.createMarker,
    required this.setMarkers,
    required this.focus,
    required this.initCamPos,
  });
}
