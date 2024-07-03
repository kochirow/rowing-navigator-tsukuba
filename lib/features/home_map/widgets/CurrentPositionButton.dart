import 'dart:math';
import 'package:flutter/material.dart';

import 'package:rowing_navigator/widgets/RoundedIconButton.dart';

class CurrentPositionButton extends StatelessWidget {
  final VoidCallback onPressed;

  const CurrentPositionButton({super.key, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return RoundedIconButton(
      icon: Transform.rotate(
          angle: 45 * (pi / 180),
          child: Transform.translate(
              offset: const Offset(0, -2),
              child: const Icon(
                Icons.navigation_rounded,
                color: Colors.white,
              ))),
      onPressed: onPressed,
    );
  }
}
