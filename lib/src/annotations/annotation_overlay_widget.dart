import 'package:flutter/material.dart';

import '../coordinates/coordinate_space.dart';
import '../coordinates/normalized_point.dart';
import '../coordinates/normalized_rect.dart';
import '../geometry/image_fit.dart';
import '../geometry/content_rect.dart';
import 'annotation.dart';
import 'annotation_controller.dart';
import 'annotation_painter.dart';
import 'annotation_tool.dart';
import '../viewer/single_pointer_pan_recognizer.dart';
import 'hit_testing.dart';

/// Draws [controller]'s annotations and creates new ones by gesture.
///
/// Sizes itself to fill its parent and computes the image's content rect
/// with the same `computeImageContentRect` the preview uses, so a mark
/// lands on the same part of the image the user was looking at. Every
/// pointer position is converted to normalized `[0,1]` image space
/// before an annotation is built -- the widget never stores a pixel.
///
/// [imageSize] is the annotated image's own pixel dimensions, needed to
/// work out where it sits inside this widget under [fit]. For a captured
/// photo that is `Size(capture.width, capture.height)`.
class AnnotationOverlay extends StatefulWidget {
  const AnnotationOverlay({
    super.key,
    required this.controller,
    required this.imageSize,
    this.tool = AnnotationTool.rectangle,
    this.fit = ImageFit.contain,
    this.idGenerator,
  });

  final AnnotationController controller;

  /// The annotated image's pixel dimensions.
  final Size imageSize;

  final AnnotationTool tool;

  /// How the image is laid out inside this widget. Must match how the
  /// image itself is displayed, or marks will land off-target --
  /// `contain` is the default because it is the only fit that shows the
  /// whole image, and annotating content you cannot see is a trap.
  final ImageFit fit;

  /// Supplies ids for new annotations. Injectable so tests get stable
  /// ids; defaults to a timestamp-plus-counter, which is unique within
  /// a session without pulling in a uuid dependency.
  final String Function()? idGenerator;

  @override
  State<AnnotationOverlay> createState() => _AnnotationOverlayState();
}

class _AnnotationOverlayState extends State<AnnotationOverlay> {
  /// The annotation being drawn right now. Held outside the controller
  /// so an in-progress drag does not push undo entries on every pointer
  /// move -- it is committed once, on drag end.
  Annotation? _draft;

  /// Drag origin, in normalized space, for the two-point tools.
  NormalizedPoint? _dragStart;

  /// For select-mode drags: what is being moved and from where.
  String? _movingId;
  Annotation? _movingOriginal;
  NormalizedPoint? _moveAnchor;

  int _idCounter = 0;

  String _nextId() {
    final generator = widget.idGenerator;
    if (generator != null) return generator();
    return 'a${DateTime.now().microsecondsSinceEpoch}_${_idCounter++}';
  }

  Rect _contentRect(Size widgetSize) => computeImageContentRect(
    widgetSize: widgetSize,
    contentSize: widget.imageSize,
    fit: widget.fit,
  );

  void _onPanStart(Offset local, Rect contentRect) {
    final point = toNormalized(local, contentRect);

    if (widget.tool == AnnotationTool.select) {
      final hit = hitTestAnnotations(
        widget.controller.annotations,
        point,
        contentRect,
      );
      widget.controller.select(hit?.id);
      if (hit != null) {
        _movingId = hit.id;
        _movingOriginal = hit;
        _moveAnchor = point;
      }
      return;
    }

    _dragStart = point;
    setState(() {
      _draft = switch (widget.tool) {
        AnnotationTool.rectangle => RectangleAnnotation(
          id: 'draft',
          style: widget.controller.style,
          rect: NormalizedRect.fromCorners(point, point),
        ),
        AnnotationTool.circle => CircleAnnotation(
          id: 'draft',
          style: widget.controller.style,
          rect: NormalizedRect.fromCorners(point, point),
        ),
        AnnotationTool.arrow => ArrowAnnotation(
          id: 'draft',
          style: widget.controller.style,
          start: point,
          end: point,
        ),
        AnnotationTool.freehand => FreehandAnnotation(
          id: 'draft',
          style: widget.controller.style,
          points: [point],
        ),
        AnnotationTool.select => throw StateError('handled above'),
      };
    });
  }

  void _onPanUpdate(Offset local, Rect contentRect) {
    final point = toNormalized(local, contentRect);

    if (widget.tool == AnnotationTool.select) {
      _dragSelection(point);
      return;
    }

    final start = _dragStart;
    final draft = _draft;
    if (start == null || draft == null) return;

    setState(() {
      _draft = switch (draft) {
        RectangleAnnotation() =>
          draft.copyWith(rect: NormalizedRect.fromCorners(start, point)),
        CircleAnnotation() =>
          draft.copyWith(rect: NormalizedRect.fromCorners(start, point)),
        ArrowAnnotation() => draft.copyWith(end: point),
        // Freehand accumulates; skip points too close to the last one to
        // avoid piling up duplicates when the finger is nearly still.
        FreehandAnnotation(:final points) => _isFarEnough(points.last, point)
            ? draft.copyWith(points: [...points, point])
            : draft,
      };
    });
  }

  void _dragSelection(NormalizedPoint point) {
    final id = _movingId;
    final original = _movingOriginal;
    final anchor = _moveAnchor;
    if (id == null || original == null || anchor == null) return;

    final dx = point.x - anchor.x;
    final dy = point.y - anchor.y;
    final moved = _translate(original, dx, dy);
    if (moved != null) widget.controller.update(id, moved);
  }

  void _onPanEnd() {
    if (widget.tool == AnnotationTool.select) {
      _movingId = null;
      _movingOriginal = null;
      _moveAnchor = null;
      return;
    }

    final draft = _draft;
    setState(() {
      _draft = null;
      _dragStart = null;
    });
    if (draft == null) return;
    // A tap with no movement produces a zero-area shape; committing it
    // would leave an invisible annotation that still swallows hits.
    if (_isDegenerate(draft)) return;

    widget.controller.add(_withId(draft, _nextId()));
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final widgetSize = Size(constraints.maxWidth, constraints.maxHeight);
        final contentRect = _contentRect(widgetSize);

        return AnimatedBuilder(
          animation: widget.controller,
          builder: (context, _) {
            final draft = _draft;
            // RawGestureDetector with a single-pointer recognizer, not
            // a plain GestureDetector: inside an InteractiveViewer the
            // latter wins the arena on the first pointer and swallows
            // the pinch, so two-finger zoom would never reach the
            // viewer. See SinglePointerPanGestureRecognizer.
            //
            // Positions arrive in this widget's own local space. When
            // this sits inside an InteractiveViewer it *is* the
            // transformed child, so local coordinates are already
            // untransformed image-box coordinates -- no inverse matrix
            // is needed here, and applying one would double-correct.
            return RawGestureDetector(
              behavior: HitTestBehavior.opaque,
              gestures: <Type, GestureRecognizerFactory>{
                SinglePointerPanGestureRecognizer:
                    GestureRecognizerFactoryWithHandlers<
                      SinglePointerPanGestureRecognizer
                    >(
                      () => SinglePointerPanGestureRecognizer(
                        debugOwner: this,
                      ),
                      (recognizer) {
                        recognizer.onStart = (d) =>
                            _onPanStart(d.localPosition, contentRect);
                        recognizer.onUpdate = (d) =>
                            _onPanUpdate(d.localPosition, contentRect);
                        recognizer.onEnd = (_) => _onPanEnd();
                      },
                    ),
              },
              child: CustomPaint(
                size: widgetSize,
                painter: AnnotationPainter(
                  annotations: [
                    ...widget.controller.annotations,
                    ?draft,
                  ],
                  contentRect: contentRect,
                  selectedId: widget.controller.selectedId,
                ),
              ),
            );
          },
        );
      },
    );
  }
}

/// Skips freehand samples closer than this (in normalized units) to the
/// previous point. Keeps a stationary finger from appending thousands of
/// identical points without visibly changing the stroke.
const double _freehandMinStep = 0.002;

bool _isFarEnough(NormalizedPoint last, NormalizedPoint next) {
  final dx = next.x - last.x;
  final dy = next.y - last.y;
  return dx * dx + dy * dy >= _freehandMinStep * _freehandMinStep;
}

bool _isDegenerate(Annotation annotation) {
  const epsilon = 1e-4;
  return switch (annotation) {
    RectangleAnnotation(:final rect) =>
      rect.width < epsilon && rect.height < epsilon,
    CircleAnnotation(:final rect) =>
      rect.width < epsilon && rect.height < epsilon,
    ArrowAnnotation(:final start, :final end) =>
      (start.x - end.x).abs() < epsilon && (start.y - end.y).abs() < epsilon,
    // A single-point freehand is a deliberate dot, not a mis-drag.
    FreehandAnnotation() => false,
  };
}

Annotation _withId(Annotation annotation, String id) {
  return switch (annotation) {
    RectangleAnnotation(:final style, :final rect) =>
      RectangleAnnotation(id: id, style: style, rect: rect),
    CircleAnnotation(:final style, :final rect) =>
      CircleAnnotation(id: id, style: style, rect: rect),
    ArrowAnnotation(:final style, :final start, :final end) =>
      ArrowAnnotation(id: id, style: style, start: start, end: end),
    FreehandAnnotation(:final style, :final points) =>
      FreehandAnnotation(id: id, style: style, points: points),
  };
}

/// Translates an annotation by a normalized delta, or returns null if
/// the move would push it outside the image.
///
/// Refusing the move rather than clamping is deliberate: clamping each
/// coordinate independently would squash a shape against the edge,
/// silently changing its size as well as its position.
Annotation? _translate(Annotation annotation, double dx, double dy) {
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
  }
}
