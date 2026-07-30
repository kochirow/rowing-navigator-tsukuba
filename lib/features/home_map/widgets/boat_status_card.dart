import 'package:flutter/material.dart';

import 'package:rowing_navigator/models/boat_model.dart';
import 'package:rowing_navigator/models/nav_config_model.dart';

/// 開発・検証用の詳細情報カード(緯度経度・処理時刻など)。
class BoatStatusCard extends StatelessWidget {
  final Boat? myBoat;
  final NavConfig? config;
  final DateTime preProcessTime;
  final DateTime postProcessTime;

  const BoatStatusCard(
      {super.key,
      required this.myBoat,
      required this.config,
      required this.preProcessTime,
      required this.postProcessTime});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '詳細情報(開発用)',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: Colors.black54,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            "ボートID: ${myBoat?.boatId}\n"
            "緯度: ${myBoat?.lat.toStringAsFixed(14)}\n"
            "経度: ${myBoat?.lng.toStringAsFixed(14)}\n"
            "精度: ${config?.accuracy.name.toString()}\n"
            "開始時刻: ${preProcessTime.toLocal().toString()}\n"
            "確定時刻: ${myBoat?.timestamp.toLocal().toString()}\n"
            "終了時刻: ${postProcessTime.toLocal().toString()}\n"
            "表示時刻: ${DateTime.now().toLocal().toString()}\n"
            "確定-開始: ${(myBoat?.timestamp.difference(preProcessTime)).toString()}秒\n"
            "方位角: ${myBoat?.heading.toStringAsFixed(1)}",
            style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
          ),
        ],
      ),
    );
  }
}
