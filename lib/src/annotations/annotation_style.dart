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
    this.borderWidth = 0.0,
    this.borderRadius = 0.0,
  }) : assert(strokeWidth > 0, 'strokeWidth must be positive'),
       assert(fontSize > 0, 'fontSize must be positive'),
       assert(borderWidth >= 0, 'borderWidth must not be negative'),
       assert(borderRadius >= 0, 'borderRadius must not be negative');

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

  /// A rounded-rect outline drawn around the text's own box, in [color]
  /// -- zero (the default) means no border, rather than a separate
  /// boolean flag, the same "zero-is-off" convention every other
  /// optional numeric style already uses in this package.
  ///
  /// Normalized to the image's shorter side, like [strokeWidth] and for
  /// the same reason. Found necessary on-device: bare floating text
  /// gave no visual cue that it was an editable field one could tap
  /// away from to finish, the way a bordered textbox does.
  ///
  /// Ignored by every type except `TextAnnotation`.
  final double borderWidth;

  /// Corner radius of [borderWidth]'s outline, as a fraction of the
  /// image's shorter side -- the same normalization, for the same
  /// reason. Meaningless while [borderWidth] is zero.
  ///
  /// Ignored by every type except `TextAnnotation`.
  final double borderRadius;

  /// Resolves [strokeWidth] to real pixels for a canvas whose shorter
  /// side is [shorterSidePixels].
  double resolveStrokeWidth(double shorterSidePixels) =>
      strokeWidth * shorterSidePixels;

  /// Resolves [fontSize] to real pixels for a canvas whose shorter side
  /// is [shorterSidePixels]. See [resolveStrokeWidth] -- same
  /// normalization, same reason.
  double resolveFontSize(double shorterSidePixels) =>
      fontSize * shorterSidePixels;

  /// Resolves [borderWidth] to real pixels. See [resolveStrokeWidth].
  double resolveBorderWidth(double shorterSidePixels) =>
      borderWidth * shorterSidePixels;

  /// Resolves [borderRadius] to real pixels. See [resolveStrokeWidth].
  double resolveBorderRadius(double shorterSidePixels) =>
      borderRadius * shorterSidePixels;

  AnnotationStyle copyWith({
    Color? color,
    double? strokeWidth,
    bool? filled,
    double? fontSize,
    Color? backgroundColor,
    bool clearBackgroundColor = false,
    double? borderWidth,
    double? borderRadius,
  }) {
    return AnnotationStyle(
      color: color ?? this.color,
      strokeWidth: strokeWidth ?? this.strokeWidth,
      filled: filled ?? this.filled,
      fontSize: fontSize ?? this.fontSize,
      backgroundColor: clearBackgroundColor
          ? null
          : (backgroundColor ?? this.backgroundColor),
      borderWidth: borderWidth ?? this.borderWidth,
      borderRadius: borderRadius ?? this.borderRadius,
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
          backgroundColor == other.backgroundColor &&
          borderWidth == other.borderWidth &&
          borderRadius == other.borderRadius;

  @override
  int get hashCode => Object.hash(
    color,
    strokeWidth,
    filled,
    fontSize,
    backgroundColor,
    borderWidth,
    borderRadius,
  );

  @override
  String toString() =>
      'AnnotationStyle(color: $color, strokeWidth: $strokeWidth, '
      'filled: $filled, fontSize: $fontSize, '
      'backgroundColor: $backgroundColor, borderWidth: $borderWidth, '
      'borderRadius: $borderRadius)';
}
