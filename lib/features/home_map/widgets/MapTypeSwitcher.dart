import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

class MapTypeSwitcher extends StatelessWidget {
  final MapType mapType;
  final VoidCallback onTap;
  const MapTypeSwitcher(
      {super.key, required this.mapType, required this.onTap});
  static const NORMAL_MAP_IMG_PATH = 'assets/images/normal_map.png';
  static const SATELLITE_MAP_IMG_PATH = 'assets/images/satellite_map.png';
  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8.0),
        side: const BorderSide(color: Colors.white, width: 3),
      ),
      child: Ink.image(
        image: mapType == MapType.normal
            ? const AssetImage(SATELLITE_MAP_IMG_PATH)
            : const AssetImage(NORMAL_MAP_IMG_PATH),
        fit: BoxFit.cover,
        width: 68,
        height: 68,
        child: InkWell(
          onTap: onTap,
        ),
      ),
    );
  }
}
