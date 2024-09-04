import 'package:flutter/material.dart';
/* spellchecker: disable */
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:rowing_navigator/config/boat_config.dart';
import 'package:rowing_navigator/features/home_map/widgets/RoundedButton.dart';

import '../../../providers/nav_config_providers.dart';
import '../../../types/boat_type.dart';

class NavSettingModal extends HookConsumerWidget {
  final void Function() onPressStartNav;

  const NavSettingModal({
    super.key,
    required this.onPressStartNav,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final boatType = ref.watch(boatTypeProvider);
    final seatPosision = ref.watch(seatPositionProvider);

    setBoatType(BoatType type) {
      ref.read(boatTypeProvider.notifier).state = type;
    }

    setSeatPosition(SeatPosition pos) {
      ref.read(seatPositionProvider.notifier).state = pos;
    }

    return Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.only(
            topLeft: Radius.circular(20),
            topRight: Radius.circular(20),
          ),
        ),
        child: Container(
          alignment: Alignment.topLeft,
          margin: const EdgeInsets.symmetric(vertical: 42, horizontal: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                margin: const EdgeInsets.only(bottom: 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      "Boat type",
                      style:
                          TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                    ),
                    const Text(
                      "Select your boat type.",
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.grey,
                        fontWeight: FontWeight.normal,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: boatConfigs.allConfigs.map((config) {
                        final type = config.type;
                        final label = config.label;
                        return RawChip(
                          label: Text(label),
                          selected: type == boatType,
                          showCheckmark: false,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                          visualDensity: const VisualDensity(
                              horizontal: -4.0, vertical: 0),
                          backgroundColor: Colors.white,
                          selectedColor: Theme.of(context).primaryColor,
                          shape: RoundedRectangleBorder(
                            side: const BorderSide(
                              color: Colors.black12,
                              width: 1,
                            ),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          labelStyle: TextStyle(
                            color:
                                type == boatType ? Colors.white : Colors.black,
                          ),
                          onPressed: () {
                            setBoatType(type);
                            setSeatPosition(
                                boatConfigs.byBoatType(type).seatPosList.first);
                          },
                        );
                      }).toList(),
                    ),
                  ],
                ),
              ),
              Container(
                margin: const EdgeInsets.only(bottom: 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      "Seat position",
                      style:
                          TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                    ),
                    const Text(
                      "Select your seat position.",
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.grey,
                        fontWeight: FontWeight.normal,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: boatConfigs
                          .byBoatType(boatType)
                          .seatPosList
                          .map((seatPos) {
                        return RawChip(
                          label: Text(seatPos.label),
                          selected: seatPos == seatPosision,
                          showCheckmark: false,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                          visualDensity: const VisualDensity(
                              horizontal: -4.0, vertical: 0),
                          backgroundColor: Colors.white,
                          selectedColor: Theme.of(context).primaryColor,
                          shape: RoundedRectangleBorder(
                            side: const BorderSide(
                              color: Colors.black12,
                              width: 1,
                            ),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          labelStyle: TextStyle(
                            color: seatPos == seatPosision
                                ? Colors.white
                                : Colors.black,
                          ),
                          onPressed: () {
                            setSeatPosition(seatPos);
                          },
                        );
                      }).toList(),
                    )
                  ],
                ),
              ),
              // シート下部中心に配置
              Expanded(child: Container()),
              Container(
                alignment: Alignment.center,
                child: RoundedButton(
                  label: "Start Nav",
                  onPressed: onPressStartNav,
                ),
              ),
            ],
          ),
        ));
  }
}
