import 'dart:math';

import 'package:flutter/material.dart';

class RoundedIconButton extends StatelessWidget {
  final IconData icon;
  final double? iconSize;
  final double angle;
  final Offset offset;
  final VoidCallback onPressed;

  const RoundedIconButton(
      {super.key,
      required this.icon,
      this.iconSize = 32,
      this.angle = 0.0,
      this.offset = const Offset(0, 0),
      required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Material(
        color: Theme.of(context).primaryColor,
        elevation: 5.0,
        shape: const CircleBorder(),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(999),
          splashColor: Colors.white.withOpacity(0.3),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Transform.rotate(
                angle: angle * (pi / 180),
                child: Transform.translate(
                    offset: offset,
                    child: Icon(
                      icon,
                      color: Colors.white,
                      size: iconSize,
                    ))),
          ),
        ));
  }
}
