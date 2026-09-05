import 'package:meta/meta.dart';

import '../coordinates/normalized_point.dart';
import '../coordinates/normalized_rect.dart';
import 'annotation_style.dart';

/// A single mark drawn on an image.
///
/// Sealed, so exhaustive `switch` covers every variant and adding a new
/// shape is a compile error at each site that must handle it -- the
/// painter and hit-tester both rely on that rather than a default case
/// that would silently skip an unhandled kind.
///
/// **All geometry is normalized `[0,1]` image space.** Never widget
/// pixels, never sensor pixels. This is what makes an annotation land in
/// the same place on a 400px preview and a 4000px export; see
/// `coordinates/coordinate_space.dart`.
@immutable
sealed class Annotation {
  const Annotation({required this.id, required this.style});

  /// Stable identity across edits -- an annotation that is moved or
  /// restyled keeps its id, which is what lets undo/redo and selection
  /// track the same mark through a change.
  final String id;

  final AnnotationStyle style;

  /// The smallest normalized rect containing this annotation, ignoring
  /// stroke width. Used for coarse hit-testing and, later, for export
  /// bounds.
  NormalizedRect get bounds;

  Annotation copyWithStyle(AnnotationStyle style);
}

/// A rectangle, stored by its bounds.
final class RectangleAnnotation extends Annotation {
  const RectangleAnnotation({
    required super.id,
    required super.style,
    required this.rect,
  });

  final NormalizedRect rect;

  @override
  NormalizedRect get bounds => rect;

  @override
  RectangleAnnotation copyWithStyle(AnnotationStyle style) =>
      RectangleAnnotation(id: id, style: style, rect: rect);

  RectangleAnnotation copyWith({NormalizedRect? rect}) =>
      RectangleAnnotation(id: id, style: style, rect: rect ?? this.rect);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RectangleAnnotation &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          style == other.style &&
          rect == other.rect;

  @override
  int get hashCode => Object.hash(id, style, rect);

  @override
  String toString() => 'RectangleAnnotation($id, $rect)';
}

/// An ellipse inscribed in [rect]. Named "circle" for the user-facing
/// concept; it is an ellipse whenever the drag was not square, matching
/// how every drawing tool behaves.
final class CircleAnnotation extends Annotation {
  const CircleAnnotation({
    required super.id,
    required super.style,
    required this.rect,
  });

  final NormalizedRect rect;

  @override
  NormalizedRect get bounds => rect;

  @override
  CircleAnnotation copyWithStyle(AnnotationStyle style) =>
      CircleAnnotation(id: id, style: style, rect: rect);

  CircleAnnotation copyWith({NormalizedRect? rect}) =>
      CircleAnnotation(id: id, style: style, rect: rect ?? this.rect);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CircleAnnotation &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          style == other.style &&
          rect == other.rect;

  @override
  int get hashCode => Object.hash(id, style, rect);

  @override
  String toString() => 'CircleAnnotation($id, $rect)';
}

/// A directional arrow from [start] to [end]. Direction is part of the
/// meaning, so the two points are stored rather than a bounds rect --
/// a rect could not distinguish an arrow from its reverse.
final class ArrowAnnotation extends Annotation {
  const ArrowAnnotation({
    required super.id,
    required super.style,
    required this.start,
    required this.end,
  });

  final NormalizedPoint start;
  final NormalizedPoint end;

  @override
  NormalizedRect get bounds => NormalizedRect.fromCorners(start, end);

  @override
  ArrowAnnotation copyWithStyle(AnnotationStyle style) =>
      ArrowAnnotation(id: id, style: style, start: start, end: end);

  ArrowAnnotation copyWith({NormalizedPoint? start, NormalizedPoint? end}) =>
      ArrowAnnotation(
        id: id,
        style: style,
        start: start ?? this.start,
        end: end ?? this.end,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ArrowAnnotation &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          style == other.style &&
          start == other.start &&
          end == other.end;

  @override
  int get hashCode => Object.hash(id, style, start, end);

  @override
  String toString() => 'ArrowAnnotation($id, $start -> $end)';
}

/// A free-drawn path of sampled points.
final class FreehandAnnotation extends Annotation {
  FreehandAnnotation({
    required super.id,
    required super.style,
    required List<NormalizedPoint> points,
  }) : assert(points.isNotEmpty, 'a freehand stroke needs at least one point'),
       points = List.unmodifiable(points);

  /// In draw order. Unmodifiable: annotations are immutable, and a
  /// mutable list would let a caller change a stroke behind the
  /// controller's back, breaking undo.
  final List<NormalizedPoint> points;

  @override
  NormalizedRect get bounds {
    var minX = points.first.x;
    var maxX = points.first.x;
    var minY = points.first.y;
    var maxY = points.first.y;
    for (final p in points) {
      if (p.x < minX) minX = p.x;
      if (p.x > maxX) maxX = p.x;
      if (p.y < minY) minY = p.y;
      if (p.y > maxY) maxY = p.y;
    }
    return NormalizedRect(left: minX, top: minY, right: maxX, bottom: maxY);
  }

  @override
  FreehandAnnotation copyWithStyle(AnnotationStyle style) =>
      FreehandAnnotation(id: id, style: style, points: points);

  FreehandAnnotation copyWith({List<NormalizedPoint>? points}) =>
      FreehandAnnotation(id: id, style: style, points: points ?? this.points);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! FreehandAnnotation || runtimeType != other.runtimeType) {
      return false;
    }
    if (id != other.id || style != other.style) return false;
    if (points.length != other.points.length) return false;
    for (var i = 0; i < points.length; i++) {
      if (points[i] != other.points[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(id, style, Object.hashAll(points));

  @override
  String toString() => 'FreehandAnnotation($id, ${points.length} points)';
}
