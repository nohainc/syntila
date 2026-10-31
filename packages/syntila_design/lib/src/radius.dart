import 'package:flutter/material.dart';

/// Border radius constants for Syntila.
abstract final class SyntilaRadius {
  static const double xs = 4.0;
  static const double sm = 6.0;
  static const double md = 10.0;
  static const double lg = 14.0;
  static const double xl = 20.0;
  static const double pill = 999.0;

  static const radiusXs = BorderRadius.all(Radius.circular(xs));
  static const radiusSm = BorderRadius.all(Radius.circular(sm));
  static const radiusMd = BorderRadius.all(Radius.circular(md));
  static const radiusLg = BorderRadius.all(Radius.circular(lg));
  static const radiusXl = BorderRadius.all(Radius.circular(xl));
  static const radiusPill = BorderRadius.all(Radius.circular(pill));

  /// Shared outline for buttons and icon-button interaction states.
  static const buttonShape = RoundedRectangleBorder(borderRadius: radiusSm);
}
