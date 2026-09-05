import 'dart:ui' show Offset, Rect;

import 'package:meta/meta.dart';

import 'normalized_point.dart';

/// An axis-aligned rectangle in normalized `[0,1] x [0,1]` image space.
///
/// The persisted form for every bounded annotation (rectangles,
/// ellipses). Like [NormalizedPoint], it is invariant under widget size,
/// fit mode, and image resolution -- see `coordinate_space.dart` for why
/// that matters.
///
/// Always stored normalized in the sense of `left <= right` and
/// `top <= bottom`: a rect dragged up-and-left is stored the same way as
/// the identical rect dragged down-and-right, so downstream code never
/// has to handle negative extents.
@immutable
class NormalizedRect {
  NormalizedRect({
    required double left,
    required double top,
    required double right,
    required double bottom,
  }) : left = left <= right ? left : right,
       top = top <= bottom ? top : bottom,
       right = left <= right ? right : left,
       bottom = top <= bottom ? bottom : top {
    assert(
      this.left >= 0 && this.right <= 1,
      'horizontal extent must be in [0, 1]',
    );
    assert(
      this.top >= 0 && this.bottom <= 1,
      'vertical extent must be in [0, 1]',
    );
  }

  /// Builds the rect spanning two corners in any order -- the natural
  /// constructor for a drag gesture, where neither corner is known to be
  /// the top-left until the drag ends.
  factory NormalizedRect.fromCorners(NormalizedPoint a, NormalizedPoint b) {
    return NormalizedRect(
      left: a.x,
      top: a.y,
      right: b.x,
      bottom: b.y,
    );
  }

  final double left;
  final double top;
  final double right;
  final double bottom;

  double get width => right - left;
  double get height => bottom - top;

  NormalizedPoint get center =>
      NormalizedPoint((left + right) / 2, (top + bottom) / 2);

  /// Projects this rect into widget coordinates against [contentRect].
  Rect toRect(Rect contentRect) {
    return Rect.fromLTRB(
      contentRect.left + left * contentRect.width,
      contentRect.top + top * contentRect.height,
      contentRect.left + right * contentRect.width,
      contentRect.top + bottom * contentRect.height,
    );
  }

  bool contains(NormalizedPoint point) {
    return point.x >= left &&
        point.x <= right &&
        point.y >= top &&
        point.y <= bottom;
  }

  /// Whether [point] is within [toleranceX]/[toleranceY] of this rect,
  /// used for hit-testing with a finger-sized slop rather than requiring
  /// a pixel-exact hit.
  bool containsWithTolerance(
    NormalizedPoint point,
    double toleranceX,
    double toleranceY,
  ) {
    return point.x >= left - toleranceX &&
        point.x <= right + toleranceX &&
        point.y >= top - toleranceY &&
        point.y <= bottom + toleranceY;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NormalizedRect &&
          runtimeType == other.runtimeType &&
          left == other.left &&
          top == other.top &&
          right == other.right &&
          bottom == other.bottom;

  @override
  int get hashCode => Object.hash(left, top, right, bottom);

  @override
  String toString() =>
      'NormalizedRect($left, $top, $right, $bottom)';
}

/// Convenience for the common "where is this normalized point on screen"
/// question, mirroring [NormalizedRect.toRect].
extension NormalizedPointProjection on NormalizedPoint {
  Offset toOffset(Rect contentRect) => Offset(
    contentRect.left + x * contentRect.width,
    contentRect.top + y * contentRect.height,
  );
}
