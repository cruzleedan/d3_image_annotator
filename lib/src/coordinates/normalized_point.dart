import 'package:meta/meta.dart';

/// A single point in normalized `[0,1] x [0,1]` space, relative to the
/// preview's own content rect (not the widget's full bounds -- see
/// `preview_transform.dart` for the cover/contain distinction once that
/// lands). Used for tap-to-focus and tap-to-expose so the platform layer
/// never needs to know the preview surface's actual pixel resolution.
///
/// This is the point-shaped sibling of `NormalizedRect`; both exist
/// because focus/exposure targets are single points, while annotation
/// geometry (added in a later phase) is generally a rect or a polyline.
@immutable
class NormalizedPoint {
  const NormalizedPoint(this.x, this.y)
    : assert(x >= 0 && x <= 1, 'x must be in [0, 1], got $x'),
      assert(y >= 0 && y <= 1, 'y must be in [0, 1], got $y');

  final double x;
  final double y;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NormalizedPoint &&
          runtimeType == other.runtimeType &&
          x == other.x &&
          y == other.y;

  @override
  int get hashCode => Object.hash(x, y);

  @override
  String toString() => 'NormalizedPoint($x, $y)';
}
