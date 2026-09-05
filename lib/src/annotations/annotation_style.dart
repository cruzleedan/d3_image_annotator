import 'dart:ui' show Color;

import 'package:meta/meta.dart';

/// Stroke appearance for an annotation.
///
/// [strokeWidth] is in *normalized* units relative to the image's
/// shorter side, not pixels: an annotation must render at the same
/// visual weight whether it is drawn on a 400px-wide preview or burned
/// into a 4000px-wide export. A pixel width would be four-tenths of a
/// percent of the image on one and four percent on the other.
@immutable
class AnnotationStyle {
  const AnnotationStyle({
    this.color = const Color(0xFFFF3B30),
    this.strokeWidth = 0.005,
    this.filled = false,
  }) : assert(strokeWidth > 0, 'strokeWidth must be positive');

  final Color color;

  /// Fraction of the image's shorter side. The default (0.5%) is about
  /// 3px on a 600px preview and 20px on a 4000px export -- the same
  /// apparent weight on both.
  final double strokeWidth;

  /// Fills the shape rather than only stroking its outline. Ignored by
  /// annotations that have no interior (arrows, freehand).
  final bool filled;

  /// Resolves [strokeWidth] to real pixels for a canvas whose shorter
  /// side is [shorterSidePixels].
  double resolveStrokeWidth(double shorterSidePixels) =>
      strokeWidth * shorterSidePixels;

  AnnotationStyle copyWith({Color? color, double? strokeWidth, bool? filled}) {
    return AnnotationStyle(
      color: color ?? this.color,
      strokeWidth: strokeWidth ?? this.strokeWidth,
      filled: filled ?? this.filled,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AnnotationStyle &&
          runtimeType == other.runtimeType &&
          color == other.color &&
          strokeWidth == other.strokeWidth &&
          filled == other.filled;

  @override
  int get hashCode => Object.hash(color, strokeWidth, filled);

  @override
  String toString() =>
      'AnnotationStyle(color: $color, strokeWidth: $strokeWidth, '
      'filled: $filled)';
}
