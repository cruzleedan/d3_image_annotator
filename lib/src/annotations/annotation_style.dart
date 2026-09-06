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
    this.fontSize = 0.03,
    this.backgroundColor,
  }) : assert(strokeWidth > 0, 'strokeWidth must be positive'),
       assert(fontSize > 0, 'fontSize must be positive');

  final Color color;

  /// Fraction of the image's shorter side. The default (0.5%) is about
  /// 3px on a 600px preview and 20px on a 4000px export -- the same
  /// apparent weight on both.
  ///
  /// Ignored by `TextAnnotation`, which has no stroke -- see [fontSize]
  /// for its equivalent.
  final double strokeWidth;

  /// Fills the shape rather than only stroking its outline. Ignored by
  /// annotations that have no interior (arrows, freehand, text -- text's
  /// analogous concept is [backgroundColor], not this).
  final bool filled;

  /// Text size, as a fraction of the image's shorter side -- the same
  /// normalization [strokeWidth] uses, and for the same reason: a label
  /// must read at the same size relative to the picture whether shown on
  /// a small preview or a large export (WORK-0034).
  ///
  /// Ignored by every type except `TextAnnotation`.
  final double fontSize;

  /// A fill drawn behind the text, or null for no background -- a
  /// legibility aid over a busy photo, not the same concept as [filled]
  /// (which fills a shape's own interior, something text has none of).
  ///
  /// Ignored by every type except `TextAnnotation`.
  final Color? backgroundColor;

  /// Resolves [strokeWidth] to real pixels for a canvas whose shorter
  /// side is [shorterSidePixels].
  double resolveStrokeWidth(double shorterSidePixels) =>
      strokeWidth * shorterSidePixels;

  /// Resolves [fontSize] to real pixels for a canvas whose shorter side
  /// is [shorterSidePixels]. See [resolveStrokeWidth] -- same
  /// normalization, same reason.
  double resolveFontSize(double shorterSidePixels) =>
      fontSize * shorterSidePixels;

  AnnotationStyle copyWith({
    Color? color,
    double? strokeWidth,
    bool? filled,
    double? fontSize,
    Color? backgroundColor,
    bool clearBackgroundColor = false,
  }) {
    return AnnotationStyle(
      color: color ?? this.color,
      strokeWidth: strokeWidth ?? this.strokeWidth,
      filled: filled ?? this.filled,
      fontSize: fontSize ?? this.fontSize,
      backgroundColor: clearBackgroundColor
          ? null
          : (backgroundColor ?? this.backgroundColor),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AnnotationStyle &&
          runtimeType == other.runtimeType &&
          color == other.color &&
          strokeWidth == other.strokeWidth &&
          filled == other.filled &&
          fontSize == other.fontSize &&
          backgroundColor == other.backgroundColor;

  @override
  int get hashCode =>
      Object.hash(color, strokeWidth, filled, fontSize, backgroundColor);

  @override
  String toString() =>
      'AnnotationStyle(color: $color, strokeWidth: $strokeWidth, '
      'filled: $filled, fontSize: $fontSize, '
      'backgroundColor: $backgroundColor)';
}
