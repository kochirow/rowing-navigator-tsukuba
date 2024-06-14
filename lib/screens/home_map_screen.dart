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
  late GoogleMapController _mapController;
  late StreamSubscription<Position> positionStream;
  late Timer _timer;
  late Position _currentPosition;
  Set<Marker> markers = {};

  static const LOCATION_ACCURACY = LocationAccuracy.high;
  static const POSITION_UPDATE_INTERVAL = 2;

  final CameraPosition initialCameraPosition = const CameraPosition(
    target: LatLng(35.681236, 139.767125), // 東京駅
    zoom: 16.0,
  );
  // 現在地通知の設定
  final LocationSettings locationSettings = const LocationSettings(
    accuracy: LocationAccuracy.bestForNavigation,
    distanceFilter: 0,
  );

  // =============================================
  // 位置情報取得の許可
  // =============================================
  Future<void> _requestPermission() async {
    // 位置情報の許可を求める
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      await Geolocator.requestPermission();
    }
  }

  // =============================================
  // 現在地を取得してマーカーとカメラを移動
  // =============================================
  Future<void> _moveToCurrentLocation() async {
    // 位置情報の許可を求める
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.always ||
        permission == LocationPermission.whileInUse) {
      // 現在地を取得
      final Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LOCATION_ACCURACY,
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
      await _mapController.animateCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(
            target: LatLng(position.latitude, position.longitude),
            zoom: await _mapController.getZoomLevel(),
          ),
        ),
      );
    }
  }

  // =============================================
  // 現在地を取得
  // =============================================
  Future<Position> _getCurrentPosition() async {
    // 現在地を取得
    final Position position = await Geolocator.getCurrentPosition(
      desiredAccuracy: LOCATION_ACCURACY,
    );
    return position;
  }

  // =============================================
  // マーカーを更新
  // =============================================
  void _updateMarkers() {
    markers.add(
      Marker(
        markerId: const MarkerId("current_location"),
        position: LatLng(
          _currentPosition.latitude,
          _currentPosition.longitude,
        ),
      ),
    );
  }

  // =============================================
  // 現在地にカメラを移動
  // =============================================
  void _focusCurrentPosition() async {
    await _mapController.animateCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(
          target: LatLng(_currentPosition.latitude, _currentPosition.longitude),
          zoom: await _mapController.getZoomLevel(),
        ),
      ),
    );
  }

  // =============================================
  // 現在地を更新
  // =============================================
  void _updateCurrentPosition() async {
    final Position position = await _getCurrentPosition();
    setState(() {
      _currentPosition = position;
      _updateMarkers();
      _focusCurrentPosition();
    });
  }

  // =============================================
  // 位置情報の定期更新を開始
  // =============================================
  void _startPeriodicPositionUpdate() {
    _timer = Timer.periodic(const Duration(seconds: POSITION_UPDATE_INTERVAL),
        (timer) {
      _updateCurrentPosition();
    });
  }

  // =============================================
  // LifeCycles
  // =============================================
  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    _mapController.dispose();
    positionStream.cancel();
    _timer.cancel();
    super.dispose();
  }

  // =============================================
  // build
  // =============================================
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
            _mapController = controller;
            await _requestPermission(); // 位置情報の許可を求める
            _updateCurrentPosition(); // 現在地を取得
            _startPeriodicPositionUpdate(); // 位置情報の定期更新を開始
          },
          markers: markers,
        ),
        floatingActionButton: FloatingActionButton(
          onPressed: () {
            _focusCurrentPosition(); // 現在地にカメラを移動
          },
          child: const Icon(Icons.my_location),
        ));
  }
}
