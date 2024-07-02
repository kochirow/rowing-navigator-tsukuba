class NavConfig {
  String _boatId;
  int _boatType;
  int _seatPos; // 要enum定義
  static final init = NavConfig(
    boatId: 'init',
    boatType: 0,
    seatPos: 0,
  );

  String get boatId => _boatId;
  int get boatType => _boatType;
  int get seatPos => _seatPos;

  NavConfig({
    required String boatId,
    required int boatType,
    required int seatPos,
  })  : _boatId = boatId,
        _boatType = boatType,
        _seatPos = seatPos;
}
