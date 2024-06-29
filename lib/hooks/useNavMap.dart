import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:rowing_navigator/models/message_model.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:rowing_navigator/types/marker_type.dart';

import '../models/boat_model.dart';
import '../services/env_service.dart';
import '../services/message_service.dart';
import '../utils/image2icon.dart';

Map<String, dynamic> useNavMap() {
  final mapController = useState<GoogleMapController?>(null);
  final markers = useState<Set<Marker>>({});
  const SHIP_ICON_PATH = 'assets/icons/ship.png';

  void setController(GoogleMapController controller) {
    mapController.value = controller;
  }

  void setMarker(Marker marker) async {
    markers.value.add(marker);
  }

  Future<Marker> createMarker(String markerId, MarkerType type, double lat,
      double lng, double heading, String title, String snippet) async {
    final zoomLevel = await mapController.value!.getZoomLevel();
    final iconSize = (zoomLevel * 4).toInt(); // ZoomLevelに応じてiconSizeを変更
    // TODO: MarkerType次第でアイコンの種類を変更
    final icon =
        await getBitmapDescriptorFromAssetBytes(SHIP_ICON_PATH, iconSize);
    return Marker(
      markerId: MarkerId(markerId),
      position: LatLng(lat, lng),
      icon: icon,
      infoWindow: InfoWindow(title: title, snippet: snippet),
      anchor: const Offset(0.5, 0.5),
    );
  }

  void focus(double lat, double lng) async {
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

  return {
    "setController": setController,
    "createMarker": createMarker,
    "setMarker": setMarker,
    "focus": focus,
  };
}
