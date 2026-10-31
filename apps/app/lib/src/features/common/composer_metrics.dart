import 'package:flutter/material.dart';
import 'package:syntila_design/syntila_design.dart';

/// Input-area icon buttons are square 32px buttons holding 20px icons.
/// Toggle/chip buttons share [composerButtonSize] as their height only.
const double composerButtonSize = 32;
const double composerIconSize = 20;
const double composerButtonRadius = SyntilaRadius.sm;

const BoxConstraints composerButtonConstraints = BoxConstraints.tightFor(
    width: composerButtonSize, height: composerButtonSize);

/// Flat rounded-square style shared by the composer rails and bottom row.
ButtonStyle composerIconButtonStyle() => IconButton.styleFrom(
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      shape: SyntilaRadius.buttonShape,
      backgroundColor: Colors.transparent,
      disabledBackgroundColor: Colors.transparent,
    );
