import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:rowing_navigator/models/boat_model.dart';

class BoatStatusCard extends HookConsumerWidget {
  final Boat? myBoat;
  final LocationAccuracy accuracy;
  final DateTime preProcessTime;
  final DateTime postProcessTime;

  const BoatStatusCard(
      {super.key,
      required this.myBoat,
      required this.accuracy,
      required this.preProcessTime,
      required this.postProcessTime});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
      color: Colors.white.withOpacity(0.9),
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Text(
          "ボートID: ${myBoat?.boatId}\n"
          "緯度: ${myBoat?.lat.toStringAsFixed(14)}\n"
          "経度: ${myBoat?.lng.toStringAsFixed(14)}\n"
          "精度: ${accuracy.name.toString()}\n"
          "開始時刻: ${preProcessTime.toLocal().toString()}\n"
          "確定時刻: ${myBoat?.timestamp.toLocal().toString()}\n"
          "終了時刻: ${postProcessTime.toLocal().toString()}\n"
          "表示時刻: ${DateTime.now().toLocal().toString()}\n"
          "確定-開始: ${(myBoat?.timestamp.difference(preProcessTime)).toString()}秒\n"
          "方位角: ${myBoat?.heading.toStringAsFixed(1)}",
          style: const TextStyle(fontSize: 16),
        ),
      ),
    );
  }
}
