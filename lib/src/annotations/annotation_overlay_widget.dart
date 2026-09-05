import 'package:flutter/material.dart';

import '../coordinates/coordinate_space.dart';
import '../coordinates/normalized_point.dart';
import '../coordinates/normalized_rect.dart';
import '../geometry/image_fit.dart';
import '../geometry/image_transform.dart';
import '../geometry/content_rect.dart';
import 'annotation.dart';
import 'annotation_controller.dart';
import 'annotation_painter.dart';
import 'annotation_tool.dart';
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
    this.transform,
    this.onScaleStart,
    this.onScaleUpdate,
    this.onScaleEnd,
    this.imageTransform = ImageTransform.identity,
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

  /// Zoom/pan currently applied to the image beneath this overlay.
  ///
  /// Null means "no transform" -- the overlay is a direct sibling of an
  /// untransformed image, or is itself inside the transformed subtree.
  /// When the overlay sits *outside* an `InteractiveViewer` (which it
  /// must, so the viewer's scale recognizer does not swallow one-finger
  /// strokes), pass the viewer's matrix here: the overlay then paints
  /// through it and inverts it to turn pointer positions back into
  /// image coordinates.
  final Matrix4? transform;

  /// Multi-finger gestures, forwarded so a host can drive zoom/pan.
  ///
  /// The overlay owns *all* pointers -- see build() for why two
  /// competing recognizers cannot share them -- so a zooming host
  /// cannot use its own gesture detector and must be fed from here.
  final void Function(ScaleStartDetails)? onScaleStart;
  final void Function(ScaleUpdateDetails)? onScaleUpdate;
  final void Function(ScaleEndDetails)? onScaleEnd;

  /// Rotate / mirror / crop applied to the image beneath.
  ///
  /// Marks are drawn on the *transformed* view but stored against the
  /// *original* image, so every pointer position is unmapped through
  /// this before an annotation is built.
  final ImageTransform imageTransform;


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

  /// Undoes the zoom/pan so a screen position becomes a position in the
  /// untransformed image box. Must happen *before* clamping to the
  /// content rect: under zoom the visible area is a subset of the
  /// image, and clamping first would pin strokes to the viewport edge
  /// instead of the image edge.
  Offset _toImageSpace(Offset local) {
    final matrix = widget.transform;
    if (matrix == null) return local;
    final inverted = Matrix4.tryInvert(matrix);
    if (inverted == null) return local;
    return MatrixUtils.transformPoint(inverted, local);
  }

  /// Screen position to a point in the *original* image's space.
  ///
  /// Two steps, and the order matters: undo the zoom/pan first (that is
  /// widget-space), then undo the image transform (that is image-space).
  NormalizedPoint _toOriginalImagePoint(Offset localRaw, Rect contentRect) {
    final local = _toImageSpace(localRaw);
    final inView = toNormalized(local, contentRect);
    if (widget.imageTransform.isIdentity) return inView;
    return widget.imageTransform.unmapPoint(inView.x, inView.y);
  }

  void _onPanStart(Offset localRaw, Rect contentRect) {
    final point = _toOriginalImagePoint(localRaw, contentRect);

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

  void _onPanUpdate(Offset localRaw, Rect contentRect) {
    final point = _toOriginalImagePoint(localRaw, contentRect);

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

  /// Drops an in-progress stroke without committing it.
  void _abandonDraft() {
    if (_draft == null && _dragStart == null) return;
    setState(() {
      _draft = null;
      _dragStart = null;
    });
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

            // ONE gesture detector owns both drawing and zoom.
            //
            // Two competing recognizers cannot share these pointers:
            // ScaleGestureRecognizer accepts single-pointer gestures, so
            // an InteractiveViewer beneath wins every one-finger drag,
            // and a drawing recognizer that merely declines still
            // starves the viewer's arena. Whichever way they are nested,
            // one always wins -- confirmed by probe and on-device.
            //
            // onScale* reports pointerCount, so a single detector can
            // route one finger to drawing and two to zoom without any
            // arena contention at all.
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onScaleStart: (d) {
                if (d.pointerCount > 1) {
                  _abandonDraft();
                  widget.onScaleStart?.call(d);
                } else {
                  _onPanStart(d.localFocalPoint, contentRect);
                }
              },
              onScaleUpdate: (d) {
                if (d.pointerCount > 1) {
                  // A pinch may begin as one finger; drop any stroke it
                  // started before the second landed.
                  _abandonDraft();
                  widget.onScaleUpdate?.call(d);
                } else if (_draft != null || _movingId != null) {
                  _onPanUpdate(d.localFocalPoint, contentRect);
                }
              },
              onScaleEnd: (d) {
                widget.onScaleEnd?.call(d);
                _onPanEnd();
              },
              child: _MaybeTransformed(
                transform: widget.transform,
                child: CustomPaint(
                  size: widgetSize,
                  painter: AnnotationPainter(
                    annotations: [...widget.controller.annotations, ?draft],
                    contentRect: contentRect,
                    selectedId: widget.controller.selectedId,
                    transform: widget.imageTransform,
                  ),
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

/// Applies [transform] when there is one, and gets out of the way when
/// there is not -- an identity `Transform` would still force a layer.
class _MaybeTransformed extends StatelessWidget {
  const _MaybeTransformed({required this.transform, required this.child});

  final Matrix4? transform;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final matrix = transform;
    if (matrix == null) return child;
    return Transform(transform: matrix, child: child);
  }
}
