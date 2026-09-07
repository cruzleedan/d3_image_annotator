import 'package:flutter/material.dart';

import 'home_screen.dart';

/// Showcases every way to use `d3_image_annotator`: the full-chrome
/// editor over a photo, a blank canvas, an image placed as its own
/// annotation, the bare viewer composed into a hand-rolled UI, and a
/// JSON save/restore round-trip. See `home_screen.dart` for the menu
/// and `demos/` for each screen.
void main() {
  runApp(const AnnotatorExampleApp());
}
