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
    this.rotation = 0.0,
  });

  final NormalizedRect rect;

  /// Radians, clockwise-positive, relative to the image's own upright
  /// orientation -- not the screen, and not
  /// `ImageTransform.quarterTurns`/mirroring, which are applied to the
  /// painted result separately (WORK-0033). Matches `Canvas.rotate()`'s
  /// own convention, so no unit conversion is needed at paint time.
  final double rotation;

  @override
  NormalizedRect get bounds => rect;

  @override
  RectangleAnnotation copyWithStyle(AnnotationStyle style) =>
      RectangleAnnotation(id: id, style: style, rect: rect, rotation: rotation);

  RectangleAnnotation copyWith({NormalizedRect? rect, double? rotation}) =>
      RectangleAnnotation(
        id: id,
        style: style,
        rect: rect ?? this.rect,
        rotation: rotation ?? this.rotation,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RectangleAnnotation &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          style == other.style &&
          rect == other.rect &&
          rotation == other.rotation;

  @override
  int get hashCode => Object.hash(id, style, rect, rotation);

  @override
  String toString() => 'RectangleAnnotation($id, $rect, rotation: $rotation)';
}

/// An ellipse inscribed in [rect]. Named "circle" for the user-facing
/// concept; it is an ellipse whenever the drag was not square, matching
/// how every drawing tool behaves.
final class CircleAnnotation extends Annotation {
  const CircleAnnotation({
    required super.id,
    required super.style,
    required this.rect,
    this.rotation = 0.0,
  });

  final NormalizedRect rect;

  /// See [RectangleAnnotation.rotation] -- same convention.
  final double rotation;

  @override
  NormalizedRect get bounds => rect;

  @override
  CircleAnnotation copyWithStyle(AnnotationStyle style) =>
      CircleAnnotation(id: id, style: style, rect: rect, rotation: rotation);

  CircleAnnotation copyWith({NormalizedRect? rect, double? rotation}) =>
      CircleAnnotation(
        id: id,
        style: style,
        rect: rect ?? this.rect,
        rotation: rotation ?? this.rotation,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CircleAnnotation &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          style == other.style &&
          rect == other.rect &&
          rotation == other.rotation;

  @override
  int get hashCode => Object.hash(id, style, rect, rotation);

  @override
  String toString() => 'CircleAnnotation($id, $rect, rotation: $rotation)';
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

/// A single line of text anchored at [position] (WORK-0034).
///
/// Single-line only for v1 -- [text] must not contain `\n`; the overlay
/// text-entry surface enforces this at input time rather than leaving it
/// as an undocumented assumption an unvalidated string could violate.
final class TextAnnotation extends Annotation {
  const TextAnnotation({
    required super.id,
    required super.style,
    required this.position,
    required this.text,
    this.rotation = 0.0,
  });

  /// Top-left anchor, matching every other bounded type's corner
  /// convention rather than a centre-anchored exception for this one
  /// type.
  final NormalizedPoint position;

  final String text;

  /// See [RectangleAnnotation.rotation] -- same convention, included
  /// from v1 rather than deferred, so text is not a known inconsistency
  /// against the four already-rotatable types (WORK-0034's decision).
  final double rotation;

  /// A coarse, approximate rect anchored at [position] -- **not** the
  /// real on-screen box a rendered line of this length and [style]
  /// .fontSize actually occupies.
  ///
  /// Every other type's `bounds` is knowable from stored geometry alone;
  /// text's true rendered width needs a `TextPainter` layout pass
  /// against a resolved pixel font size, which this zero-argument
  /// getter has no way to obtain (it would need the image's shorter-side
  /// pixel size, exactly what `contentRect`/`transform` supply at every
  /// real call site). Rather than widen `Annotation.bounds`'s signature
  /// for every type to accommodate this one, callers that need the
  /// *exact* on-screen box (painting, precise hit-testing, handles,
  /// floating controls) use `textBoundsInPixels` in
  /// `annotation_handles.dart` instead. This getter exists only so
  /// `TextAnnotation` satisfies the sealed base's contract uniformly --
  /// callers that only need "roughly where is this, in normalized
  /// space" (nothing in this package today) can use it directly.
  ///
  /// The estimate: `fontSize` tall, and `fontSize * 0.6 * text.length`
  /// wide -- a rough average glyph aspect ratio, not a substitute for
  /// real layout.
  @override
  NormalizedRect get bounds {
    final width = (style.fontSize * 0.6 * text.length).clamp(0.0, 1.0 - position.x);
    final height = style.fontSize.clamp(0.0, 1.0 - position.y);
    return NormalizedRect(
      left: position.x,
      top: position.y,
      right: position.x + width,
      bottom: position.y + height,
    );
  }

  @override
  TextAnnotation copyWithStyle(AnnotationStyle style) => TextAnnotation(
    id: id,
    style: style,
    position: position,
    text: text,
    rotation: rotation,
  );

  TextAnnotation copyWith({
    NormalizedPoint? position,
    String? text,
    double? rotation,
  }) => TextAnnotation(
    id: id,
    style: style,
    position: position ?? this.position,
    text: text ?? this.text,
    rotation: rotation ?? this.rotation,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TextAnnotation &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          style == other.style &&
          position == other.position &&
          text == other.text &&
          rotation == other.rotation;

  @override
  int get hashCode => Object.hash(id, style, position, text, rotation);

  @override
  String toString() => 'TextAnnotation($id, "$text" @ $position, '
      'rotation: $rotation)';
}

/// [annotation]'s rotation (WORK-0033), or `0.0` for a type that has
/// none.
///
/// `RectangleAnnotation`/`CircleAnnotation`/`TextAnnotation` carry a
/// `rotation` field; consolidated here rather than repeating this same
/// `switch` at every site that needs to know whether a shape is rotated
/// (the painter, hit-testing, and floating shape controls all do).
double rotationOf(Annotation annotation) => switch (annotation) {
  RectangleAnnotation(:final rotation) => rotation,
  CircleAnnotation(:final rotation) => rotation,
  TextAnnotation(:final rotation) => rotation,
  ArrowAnnotation() || FreehandAnnotation() => 0.0,
};

/// Translates [annotation] by a normalized delta, or returns null if the
/// move would push any part of it outside the image.
///
/// Refusing the move rather than clamping is deliberate: clamping each
/// coordinate independently would squash a shape against the edge,
/// silently changing its size as well as its position. `copyWith`'s
/// unrelated fields (including `rotation`, where it exists) are left
/// untouched, since only `rect`/`points`/endpoints are passed here.
Annotation? translateAnnotation(Annotation annotation, double dx, double dy) {
  bool inRange(double v) => v >= 0 && v <= 1;

  switch (annotation) {
    case RectangleAnnotation(:final rect):
      if (!inRange(rect.left + dx) ||
          !inRange(rect.right + dx) ||
          !inRange(rect.top + dy) ||
          !inRange(rect.bottom + dy)) {
        return null;
      }
      return annotation.copyWith(
        rect: NormalizedRect(
          left: rect.left + dx,
          top: rect.top + dy,
          right: rect.right + dx,
          bottom: rect.bottom + dy,
        ),
      );

    case CircleAnnotation(:final rect):
      if (!inRange(rect.left + dx) ||
          !inRange(rect.right + dx) ||
          !inRange(rect.top + dy) ||
          !inRange(rect.bottom + dy)) {
        return null;
      }
      return annotation.copyWith(
        rect: NormalizedRect(
          left: rect.left + dx,
          top: rect.top + dy,
          right: rect.right + dx,
          bottom: rect.bottom + dy,
        ),
      );

    case ArrowAnnotation(:final start, :final end):
      if (!inRange(start.x + dx) ||
          !inRange(end.x + dx) ||
          !inRange(start.y + dy) ||
          !inRange(end.y + dy)) {
        return null;
      }
      return annotation.copyWith(
        start: NormalizedPoint(start.x + dx, start.y + dy),
        end: NormalizedPoint(end.x + dx, end.y + dy),
      );

    case FreehandAnnotation(:final points):
      for (final p in points) {
        if (!inRange(p.x + dx) || !inRange(p.y + dy)) return null;
      }
      return annotation.copyWith(
        points: [
          for (final p in points) NormalizedPoint(p.x + dx, p.y + dy),
        ],
      );

    case TextAnnotation(:final position):
      if (!inRange(position.x + dx) || !inRange(position.y + dy)) {
        return null;
      }
      return annotation.copyWith(
        position: NormalizedPoint(position.x + dx, position.y + dy),
      );
  }
}

/// The normalized offset [duplicateAnnotation] nudges a copy by, so it
/// does not render exactly under the original and immediately get
/// selected instead of it (WORK-0035).
const double kDuplicateOffset = 0.02;

/// Returns a copy of [annotation] with a fresh [newId], nudged by
/// [kDuplicateOffset] so it is not rendered exactly under the original.
///
/// If the nudge would push the copy outside the image (the original was
/// near an edge), the copy is placed at the original's exact position
/// instead of being refused outright -- unlike a user's own drag
/// ([translateAnnotation] returning null there), duplicating is not a
/// gesture the user can retry with a smaller distance, so silently
/// failing to duplicate at all would be a worse outcome than two
/// exactly-overlapping copies the user can immediately drag apart.
Annotation duplicateAnnotation(Annotation annotation, String newId) {
  final withId = switch (annotation) {
    RectangleAnnotation(:final style, :final rect, :final rotation) =>
      RectangleAnnotation(id: newId, style: style, rect: rect, rotation: rotation),
    CircleAnnotation(:final style, :final rect, :final rotation) =>
      CircleAnnotation(id: newId, style: style, rect: rect, rotation: rotation),
    ArrowAnnotation(:final style, :final start, :final end) =>
      ArrowAnnotation(id: newId, style: style, start: start, end: end),
    FreehandAnnotation(:final style, :final points) =>
      FreehandAnnotation(id: newId, style: style, points: points),
    TextAnnotation(:final style, :final position, :final text, :final rotation) =>
      TextAnnotation(
        id: newId,
        style: style,
        position: position,
        text: text,
        rotation: rotation,
      ),
  };
  return translateAnnotation(withId, kDuplicateOffset, kDuplicateOffset) ??
      withId;
}
