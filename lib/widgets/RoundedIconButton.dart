import 'package:flutter/material.dart';

class RoundedIconButton extends StatelessWidget {
  final Widget icon;
  final double? iconSize;
  final VoidCallback onPressed;

  const RoundedIconButton(
      {super.key,
      required this.icon,
      this.iconSize = 48,
      required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return IconButton.filled(
      icon: icon,
      iconSize: iconSize,
      onPressed: onPressed,
    );
  }
}
