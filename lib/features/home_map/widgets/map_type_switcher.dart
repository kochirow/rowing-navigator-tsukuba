import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../../theme/app_theme.dart';

/// 地図/航空写真の切替タイル。
/// タップ後に何になるかをラベルで明示する(現状表示ではなく切替先を示す)。
class MapTypeSwitcher extends StatelessWidget {
  final MapType mapType;
  final VoidCallback onTap;
  const MapTypeSwitcher(
      {super.key, required this.mapType, required this.onTap});
  static const normalMapImagePath = 'assets/images/normal_map.png';
  static const satelliteMapImagePath = 'assets/images/satellite_map.png';

  @override
  Widget build(BuildContext context) {
    final toSatellite = mapType == MapType.normal;
    final active = !toSatellite;
    final colors = context.colors;
    final dimens = context.dimens;
    final label = toSatellite ? '航空写真' : '地図';
    return Semantics(
      button: true,
      selected: active,
      label: '$labelへ切替',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Material(
            color: colors.card,
            clipBehavior: Clip.antiAlias,
            elevation: dimens.elevationMd,
            shape: RoundedRectangleBorder(
              borderRadius: dimens.borderMd,
              side: BorderSide(
                color: active ? colors.primary : colors.onDark,
                width: active ? 3 : 2,
              ),
            ),
            child: Ink.image(
              image: toSatellite
                  ? const AssetImage(satelliteMapImagePath)
                  : const AssetImage(normalMapImagePath),
              fit: BoxFit.cover,
              width: dimens.mapControlSize,
              height: dimens.mapControlSize,
              child: InkWell(
                onTap: onTap,
                child: active
                    ? Align(
                        alignment: Alignment.topRight,
                        child: Container(
                          margin: EdgeInsets.all(dimens.space1),
                          decoration: BoxDecoration(
                            color: colors.primary,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            Icons.check,
                            size: 16,
                            color: colors.onPrimary,
                          ),
                        ),
                      )
                    : null,
              ),
            ),
          ),
          SizedBox(height: dimens.space1),
          Container(
            padding: EdgeInsets.symmetric(
              horizontal: dimens.space2,
              vertical: dimens.space1 / 2,
            ),
            decoration: BoxDecoration(
              color: colors.labelScrim,
              borderRadius: dimens.borderSm,
            ),
            child: Text(
              label,
              style: TextStyle(
                color: colors.onDark,
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
