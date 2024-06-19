import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
/* spellchecker: disable */
import 'package:geolocator/geolocator.dart';

import '../services/auth_service.dart';
import '../utils/image2icon.dart';
import '../utils/heading.dart';

class HomeMapScreen extends StatefulWidget {
  const HomeMapScreen({super.key});

  @override
  State<HomeMapScreen> createState() => _HomeMapScreenState();
}

class _HomeMapScreenState extends State<HomeMapScreen> {
  late GoogleMapController _mapController;
  late Position _currentPosition;
  double _currentHeading = 0;
  Set<Marker> markers = {};
  late Timer _timer;
  DateTime _preProcessTime = DateTime.now();
  DateTime _postProcessTime = DateTime.now();
  AuthService _auth = AuthService();

  var LOCATION_ACCURACY = LocationAccuracy.bestForNavigation;
  var POSITION_UPDATE_INTERVAL = 1;

  final CameraPosition initialCameraPosition = const CameraPosition(
    target: LatLng(35.681236, 139.767125), // 東京駅
    zoom: 16.0,
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
  void _updateMarkers() async {
    final zoomLevel = await _mapController.getZoomLevel();
    final iconSize = (zoomLevel * 4).toInt(); // ZoomLevelに応じてiconSizeを変更
    final icon = await getBitmapDescriptorFromAssetBytes(
        'assets/icons/ship.png', iconSize);
    markers.add(
      Marker(
        markerId: const MarkerId("current_location"),
        // markerId: MarkerId(DateTime.now().toString()),
        position: LatLng(
          _currentPosition.latitude,
          _currentPosition.longitude,
        ),
        icon: icon,
        infoWindow: const InfoWindow(title: "タイトル", snippet: "詳細情報"),
        anchor: const Offset(0.5, 0.5), // 回転軸をアイコンの中央に設定
        // MEMO: 向き情報の取得方法は要検討
        rotation: _currentHeading, // 向きを設定
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
    final preProcessTime = DateTime.now();
    final prePosition = _currentPosition;
    final Position position = await _getCurrentPosition();
    setState(() {
      _currentPosition = position;
      _currentHeading = getHeading(
        prePosition,
        position,
      );
      _updateMarkers();
      _focusCurrentPosition();
      _preProcessTime = preProcessTime;
      _postProcessTime = DateTime.now();
    });
  }

  // =============================================
  // 位置情報の定期更新を開始
  // =============================================
  void _startPeriodicPositionUpdate() {
    _timer =
        Timer.periodic(Duration(seconds: POSITION_UPDATE_INTERVAL), (timer) {
      _updateCurrentPosition();
    });
  }

  // =============================================
  // LifeCycles
  // =============================================
  @override
  void initState() {
    super.initState();
    _currentPosition = Position(
      latitude: 35.681236,
      longitude: 139.767125,
      accuracy: 0,
      altitude: 0,
      altitudeAccuracy: 0,
      speed: 0,
      speedAccuracy: 0,
      heading: 0,
      headingAccuracy: 0,
      timestamp: DateTime.now(),
    );
    Future(() async {
      if (!_auth.isSignedIn) {
        await _auth.signInAnonymously();
        print("Signed in with temporary account.");
        print("UID: ${_auth.currentUser?.uid}");
      } else {
        print("Already signed in.");
        print("UID: ${_auth.currentUser?.uid}");
      }
    });
  }

  @override
  void dispose() {
    _mapController.dispose();
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
        body: Stack(alignment: Alignment.topCenter, children: <Widget>[
          GoogleMap(
            myLocationEnabled: false,
            myLocationButtonEnabled: false,
            initialCameraPosition: initialCameraPosition,
            onMapCreated: (GoogleMapController controller) async {
              await Future.delayed(
                  const Duration(microseconds: 1)); // 中心座標がずれるバグを防ぐため1ms待機
              _mapController = controller;
              await _requestPermission(); // 位置情報の許可を求める
              _updateCurrentPosition(); // 現在地を取得
              _startPeriodicPositionUpdate(); // 位置情報の定期更新を開始
            },
            markers: markers,
          ),
          // 画面上部に現在位置と時刻を表示
          SizedBox(
              width: double.infinity,
              child: Card(
                margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
                color: Colors.white.withOpacity(0.9),
                elevation: 0,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    "緯度: ${_currentPosition.latitude.toStringAsFixed(6)}\n"
                    "経度: ${_currentPosition.longitude.toStringAsFixed(6)}\n"
                    "精度: ${LOCATION_ACCURACY.name.toString()} ${_currentPosition.accuracy.toString()}m\n"
                    "開始時刻: ${_preProcessTime.toLocal().toString()}\n"
                    "確定時刻: ${_currentPosition.timestamp.toLocal().toString()}\n"
                    "終了時刻: ${_postProcessTime.toLocal().toString()}\n"
                    "表示時刻: ${DateTime.now().toLocal().toString()}\n"
                    "確定-開始: ${(_currentPosition.timestamp.difference(_preProcessTime)).toString()}秒\n"
                    "方位角: ${_currentHeading.toStringAsFixed(1)}",
                    style: const TextStyle(fontSize: 16),
                  ),
                ),
              )),
        ]),
        floatingActionButton: FloatingActionButton(
          onPressed: () {
            _focusCurrentPosition(); // 現在地にカメラを移動
          },
          child: const Icon(Icons.my_location),
        ));
  }
}
