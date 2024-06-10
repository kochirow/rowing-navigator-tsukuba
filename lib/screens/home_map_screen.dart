import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
/* spellchecker: disable */
import 'package:geolocator/geolocator.dart';

class HomeMapScreen extends StatefulWidget {
  const HomeMapScreen({super.key});

  @override
  State<HomeMapScreen> createState() => _HomeMapScreenState();
}

class _HomeMapScreenState extends State<HomeMapScreen> {
  late GoogleMapController mapController;
  late StreamSubscription<Position> positionStream;
  Set<Marker> markers = {};
  bool _trackCurrentLocation = true;
  bool _isProgrammaticMove = false;

  final CameraPosition initialCameraPosition = const CameraPosition(
    target: LatLng(35.681236, 139.767125), // 東京駅
    zoom: 16.0,
  );
  // 現在地通知の設定
  final LocationSettings locationSettings = const LocationSettings(
    accuracy: LocationAccuracy.bestForNavigation,
    distanceFilter: 0,
  );

  Future<void> _requestPermission() async {
    // 位置情報の許可を求める
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      await Geolocator.requestPermission();
    }
  }

  Future<void> _moveToCurrentLocation() async {
    // 位置情報の許可を求める
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.always ||
        permission == LocationPermission.whileInUse) {
      // 現在地を取得
      final Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      setState(() {
        markers.add(
          Marker(
            markerId: const MarkerId("current_location"),
            position: LatLng(
              position.latitude,
              position.longitude,
            ),
          ),
        );
      });

      // 現在地にカメラを移動
      await mapController.animateCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(
            target: LatLng(position.latitude, position.longitude),
            zoom: await mapController.getZoomLevel(),
          ),
        ),
      );
    }
  }

  void _watchCurrentLocation() {
    // 現在地を監視
    positionStream =
        Geolocator.getPositionStream(locationSettings: locationSettings)
            .listen((position) async {
      // マーカーの位置を更新
      setState(() {
        markers.removeWhere(
            (marker) => marker.markerId == const MarkerId('current_location'));
        markers.add(Marker(
          markerId: const MarkerId('current_location'),
          position: LatLng(
            position.latitude,
            position.longitude,
          ),
        ));
      });
      if (_trackCurrentLocation) {
        setProgrammaticMove(true);
        // 現在地にカメラを移動
        await mapController.animateCamera(
          CameraUpdate.newCameraPosition(
            CameraPosition(
              target: LatLng(position.latitude, position.longitude),
              zoom: await mapController.getZoomLevel(),
            ),
          ),
        );
      }
    });
  }

  void setTrackCurrentLocation(bool value) {
    setState(() {
      _trackCurrentLocation = value;
    });
  }

  void setProgrammaticMove(bool value) {
    setState(() {
      _isProgrammaticMove = value;
    });
  }

  @override
  void initState() {
    // some code
    super.initState();
  }

  @override
  void dispose() {
    mapController.dispose();
    positionStream.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
        appBar: AppBar(
          backgroundColor: Theme.of(context).colorScheme.inversePrimary,
          title: null,
        ),
        body: GoogleMap(
          myLocationEnabled: false,
          myLocationButtonEnabled: false,
          initialCameraPosition: initialCameraPosition,
          onMapCreated: (GoogleMapController controller) async {
            mapController = controller;
            await _requestPermission();
            await _moveToCurrentLocation();
            _watchCurrentLocation();
          },
          markers: markers,
          onCameraMoveStarted: () {
            if (!_isProgrammaticMove) {
              setTrackCurrentLocation(false);
            }
          },
          onCameraIdle: () {
            if (_isProgrammaticMove) {
              setProgrammaticMove(false);
            }
          },
        ),
        floatingActionButton: FloatingActionButton(
          onPressed: () {
            setTrackCurrentLocation(true);
            _moveToCurrentLocation();
          },
          child: const Icon(Icons.my_location),
        ));
  }
}
