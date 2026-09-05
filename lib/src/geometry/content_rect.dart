import 'dart:ui' show Rect, Size;

import 'image_fit.dart';

/// Computes the rect, within a widget of [widgetSize], that the preview's
/// actual content occupies once [contentSize] (the image's own
/// aspect ratio) is laid out under [fit].
///
/// Pure function, no Flutter widget dependency beyond `Rect`/`Size` --
/// deliberately kept this way so it stays exhaustively unit-testable and
/// is safe to reuse, unchanged, for annotation coordinate mapping once
/// that lands: the overlay and the preview must agree on exactly where
/// the image content is, and sharing this one function is what
/// guarantees that rather than hoping two separate implementations never
/// drift apart.
///
/// - [ImageFit.cover]: the returned rect is scaled up to fully cover
///   [widgetSize], centered, extending beyond the widget's bounds on one
///   axis (the caller clips to the widget's bounds when painting).
/// - [ImageFit.contain]: the returned rect fits entirely within
///   [widgetSize], centered, with letterboxing (empty space) on one axis.
Rect computeImageContentRect({
  required Size widgetSize,
  required Size contentSize,
  required ImageFit fit,
}) {
  if (widgetSize.isEmpty || contentSize.isEmpty) {
    return Rect.fromLTWH(0, 0, widgetSize.width, widgetSize.height);
  }

  final widgetAspect = widgetSize.width / widgetSize.height;
  final contentAspect = contentSize.width / contentSize.height;

  final contentIsRelativelyWider = contentAspect > widgetAspect;

  // cover: when content is relatively wider than the widget, scale to
  // match the widget's height (so width overflows); contain does the
  // opposite -- scale to match the widget's width (so height fits).
  final matchHeight = fit == ImageFit.cover
      ? contentIsRelativelyWider
      : !contentIsRelativelyWider;

  late double scaledWidth;
  late double scaledHeight;
  if (matchHeight) {
    scaledHeight = widgetSize.height;
    scaledWidth = scaledHeight * contentAspect;
  } else {
    scaledWidth = widgetSize.width;
    scaledHeight = scaledWidth / contentAspect;
  }

  final left = (widgetSize.width - scaledWidth) / 2;
  final top = (widgetSize.height - scaledHeight) / 2;

  return Rect.fromLTWH(left, top, scaledWidth, scaledHeight);
}
