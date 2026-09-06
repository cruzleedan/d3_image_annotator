import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../coordinates/coordinate_space.dart';
import '../coordinates/normalized_point.dart';
import '../coordinates/normalized_rect.dart';
import '../geometry/image_fit.dart';
import '../geometry/image_transform.dart';
import '../geometry/content_rect.dart';
import '../ui/tool_button.dart';
import 'annotation.dart';
import 'annotation_controller.dart';
import 'annotation_handles.dart';
import 'annotation_painter.dart';
import 'annotation_style.dart';
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

  /// Set when a drag grabbed a resize handle rather than the shape body.
  AnnotationGrip? _grip;

  /// The text-entry overlay's state, or null when it is closed. A third
  /// interaction lifecycle alongside "grows as you drag" and "select and
  /// move" (WORK-0034) -- text has no drag phase at all, so it does not
  /// reuse `_draft`/`_dragStart`.
  _TextEditSession? _textEdit;

  int _idCounter = 0;


  String _nextId() {
    final generator = widget.idGenerator;
    if (generator != null) return generator();
    return 'a${DateTime.now().microsecondsSinceEpoch}_${_idCounter++}';
  }

  /// Where the *transformed* image sits inside this widget.
  ///
  /// Sized against the transform result size, not the raw imageSize: a quarter
  /// turn swaps the image pixel dimensions, so a portrait photo laid
  /// out under `contain` in a portrait viewport shrinks noticeably when
  /// rotated. The image itself is laid out that way by BoxFit, so an
  /// overlay measuring the untransformed size would draw annotations
  /// against a box larger than the picture -- marks would rotate
  /// correctly but come out oversized. A crop shrinks the result the
  /// same way.
  Rect _contentRect(Size widgetSize) => computeImageContentRect(
    widgetSize: widgetSize,
    contentSize: widget.imageTransform.resultSize(widget.imageSize),
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

    // Selection wins the tap, regardless of which tool is active
    // (WORK-0032). A shape under the finger is always selected/grabbed
    // first; only a gesture that starts on empty space falls through to
    // the active tool's draw behaviour below. This is what lets a user
    // delete, move, or restyle an existing mark without switching tools
    // first -- there is no dedicated select mode to switch into.

    // Handles first. A handle sits on the shape's edge, so without this
    // priority every corner drag would hit the shape and move it
    // instead of resizing.
    final selected = widget.controller.selected;
    if (selected != null) {
      final grip = gripAt(
        selected,
        _toImageSpace(localRaw),
        contentRect,
        widget.imageTransform,
      );
      if (grip != null) {
        _grip = grip;
        _movingId = selected.id;
        _movingOriginal = selected;
        return;
      }
    }

    final hit = hitTestAnnotations(
      widget.controller.annotations,
      point,
      contentRect,
      pixelPosition: _toImageSpace(localRaw),
      transform: widget.imageTransform,
    );
    if (hit != null) {
      // Tapping an already-selected TextAnnotation again re-opens the
      // text field pre-filled with its current content (WORK-0034),
      // rather than starting a move drag the way every other type's
      // second tap does -- decided explicitly so a typo can be
      // corrected in place instead of delete-and-replace being the
      // only option.
      if (hit is TextAnnotation && widget.controller.selectedId == hit.id) {
        setState(() => _textEdit = _TextEditSession(existing: hit));
        return;
      }

      widget.controller.select(hit.id);
      _movingId = hit.id;
      _movingOriginal = hit;
      _moveAnchor = point;
      return;
    }

    // Nothing under the finger: clear any existing selection.
    widget.controller.select(null);

    // Text has no drag phase (WORK-0034): a tap on empty space opens
    // the overlay text field directly, rather than starting a growing
    // draft the way every drag-based tool does below.
    if (widget.tool == AnnotationTool.text) {
      setState(() => _textEdit = _TextEditSession(position: point));
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
        AnnotationTool.text => throw StateError(
          'unreachable -- text is handled above, before any draft is '
          'created',
        ),
      };
    });
  }

  void _onPanUpdate(Offset localRaw, Rect contentRect) {
    final point = _toOriginalImagePoint(localRaw, contentRect);

    // A move/resize in progress takes priority over drawing, mirroring
    // _onPanStart's priority: if this gesture grabbed a shape or a
    // handle, it continues doing that regardless of the active tool.
    if (_movingId != null) {
      _dragSelection(point, _toImageSpace(localRaw), contentRect);
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
        // Unreachable: _draft is never a TextAnnotation -- text has no
        // drag phase at all (WORK-0034), so _onPanStart never assigns
        // one to _draft in the first place.
        TextAnnotation() => draft,
        // Unreachable for the same reason: this package provides no
        // drawing tool that creates an ImageAnnotation (WORK-0037
        // deliberately ships no image-picker UI) -- a consumer app
        // places one directly via `AnnotationController.add`, never
        // through this drag-draft lifecycle.
        ImageAnnotation() => draft,
      };
    });
  }

  void _dragSelection(
    NormalizedPoint point,
    Offset pixelPosition,
    Rect contentRect,
  ) {
    final id = _movingId;
    final original = _movingOriginal;
    if (id == null || original == null) return;

    final grip = _grip;
    if (grip != null) {
      // Resizing works from the *current* geometry, not the drag
      // origin: each update sets the grabbed corner to where the finger
      // is, so the shape tracks it exactly rather than accumulating.
      final current = widget.controller.selected ?? original;

      if (grip == AnnotationGrip.rotate) {
        final rotated = rotateAnnotation(
          current,
          pixelPosition,
          contentRect,
          widget.imageTransform,
        );
        if (rotated != null) widget.controller.update(id, rotated);
        return;
      }

      // Corner-drag resizes along the shape's own tilted axes, keeping
      // the *opposite* corner anchored on screen (WORK-0035, fixed for
      // rotated shapes as a follow-up) -- see
      // resizeRotatedAnnotation's own doc comment for why this needs a
      // dedicated rotation-aware function rather than routing a
      // computed point through the plain resizeAnnotation.
      final resized = resizeRotatedAnnotation(
        current,
        grip,
        pixelPosition,
        contentRect,
        widget.imageTransform,
      );
      if (resized != null) widget.controller.update(id, resized);
      return;
    }

    final anchor = _moveAnchor;
    if (anchor == null) return;

    final dx = point.x - anchor.x;
    final dy = point.y - anchor.y;
    final moved = translateAnnotation(original, dx, dy);
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
    if (_movingId != null) {
      _movingId = null;
      _movingOriginal = null;
      _moveAnchor = null;
      _grip = null;
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

  void _deleteSelected() {
    final id = widget.controller.selectedId;
    if (id != null) widget.controller.remove(id);
  }

  void _duplicateSelected() {
    if (widget.controller.selectedId != null) {
      widget.controller.duplicateSelected(_nextId());
    }
  }

  /// Commits [text] from the open text-entry session, or discards it if
  /// empty (WORK-0034) -- an empty submit must not create or leave
  /// behind an invisible annotation with nothing to show or hit-test.
  void _commitTextEdit(String text) {
    final session = _textEdit;
    if (session == null) return;
    setState(() => _textEdit = null);

    final trimmed = text.trim();
    if (trimmed.isEmpty) return;

    final existing = session.existing;
    if (existing != null) {
      // Editing: preserve position/style/rotation, replace only the
      // text, as one undo step via the existing controller.update --
      // the same mechanism every other restyle already uses.
      widget.controller.update(existing.id, existing.copyWith(text: trimmed));
      return;
    }

    final position = session.position;
    if (position == null) return;
    final annotation = TextAnnotation(
      id: _nextId(),
      style: widget.controller.style,
      position: position,
      text: trimmed,
    );
    widget.controller.add(annotation);
    widget.controller.select(annotation.id);
  }

  void _cancelTextEdit() {
    setState(() => _textEdit = null);
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
            final textEdit = _textEdit;
            final selected = draft == null && textEdit == null
                ? widget.controller.selected
                : null;

            return Stack(
              fit: StackFit.expand,
              children: [
                GestureDetector(
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
                      // A pinch may begin as one finger; drop any stroke
                      // it started before the second landed.
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
                        annotations: [
                          // The text annotation currently open for
                          // re-editing is hidden here -- its live
                          // TextField overlay is the visible
                          // representation while editing, so painting
                          // both would show the old text doubled under
                          // the field editing it.
                          for (final a in widget.controller.annotations)
                            if (a.id != textEdit?.existing?.id) a,
                          ?draft,
                        ],
                        contentRect: contentRect,
                        selectedId: widget.controller.selectedId,
                        transform: widget.imageTransform,
                        imageCache: widget.controller.imageCache,
                      ),
                    ),
                  ),
                ),
                // Deliberately a sibling of the GestureDetector above,
                // not a descendant of it (WORK-0035): an InkWell nested
                // inside the pan/scale GestureDetector would have to win
                // a gesture-arena contest against onScaleStart on every
                // tap, the exact kind of arena contention this file's
                // other comments document as unwinnable reliably. As a
                // sibling painted after it, its own hit-tests happen
                // first and never enter that arena at all.
                if (selected != null)
                  _MaybeTransformed(
                    transform: widget.transform,
                    child: _FloatingShapeControls(
                      annotation: selected,
                      contentRect: contentRect,
                      transform: widget.imageTransform,
                      onDelete: _deleteSelected,
                      onDuplicate: _duplicateSelected,
                    ),
                  ),
                // The text-entry overlay is the last (topmost) child for
                // the same reason the floating controls are: it is a
                // sibling of the drawing GestureDetector, not nested
                // inside it, so the TextField's own taps/keyboard focus
                // never enter that pan/scale gesture arena at all.
                if (textEdit != null)
                  _MaybeTransformed(
                    transform: widget.transform,
                    child: _TextEntryOverlay(
                      session: textEdit,
                      contentRect: contentRect,
                      transform: widget.imageTransform,
                      style: widget.controller.style,
                      onCommit: _commitTextEdit,
                      onCancel: _cancelTextEdit,
                    ),
                  ),
              ],
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
    // Text never reaches this function -- it has no drag-draft phase
    // (see _commitTextEdit's own empty-string check instead), but the
    // case is needed to keep this switch exhaustive.
    TextAnnotation() => false,
    // Same reasoning: this package has no drag-draft gesture that
    // produces an ImageAnnotation (WORK-0037).
    ImageAnnotation() => false,
  };
}

/// Gives a freshly-drawn draft its final id, preserving every other
/// field including `rotation` where it exists.
///
/// A draft is always constructed with `rotation: 0.0` by `_onPanStart`'s
/// switch -- there is no drawing gesture that produces a rotated shape
/// -- so this only ever runs on an unrotated shape today. It still
/// preserves rotation explicitly rather than dropping it, so it cannot
/// become a silent bug if that ever changes.
Annotation _withId(Annotation annotation, String id) {
  return switch (annotation) {
    RectangleAnnotation(:final style, :final rect, :final rotation) =>
      RectangleAnnotation(id: id, style: style, rect: rect, rotation: rotation),
    CircleAnnotation(:final style, :final rect, :final rotation) =>
      CircleAnnotation(id: id, style: style, rect: rect, rotation: rotation),
    ArrowAnnotation(:final style, :final start, :final end) =>
      ArrowAnnotation(id: id, style: style, start: start, end: end),
    FreehandAnnotation(:final style, :final points) =>
      FreehandAnnotation(id: id, style: style, points: points),
    // Text never reaches this function -- _commitTextEdit builds a
    // TextAnnotation with its final id directly, since it has no
    // drag-draft phase that would need a placeholder id replaced later.
    TextAnnotation(:final style, :final position, :final text, :final rotation) =>
      TextAnnotation(
        id: id,
        style: style,
        position: position,
        text: text,
        rotation: rotation,
      ),
    // Same reasoning: an ImageAnnotation never reaches this function
    // either, since this package places one only via
    // `AnnotationController.add` with its final id already supplied.
    ImageAnnotation(
      :final style,
      :final reference,
      :final rect,
      :final rotation,
      :final imageTransform,
    ) =>
      ImageAnnotation(
        id: id,
        style: style,
        reference: reference,
        rect: rect,
        rotation: rotation,
        imageTransform: imageTransform,
      ),
  };
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

/// Floating delete (×) and duplicate (+1) controls anchored to the
/// selected shape (WORK-0035).
///
/// A non-interactive [IgnorePointer]-free `Stack` positioned by
/// [floatingControlAnchors] -- the only two hit-testable widgets here
/// are the two [D3FloatingButton]s themselves, so the rest of this
/// widget's bounds (it fills the whole overlay, like its sibling
/// `CustomPaint`) let taps fall through to the `GestureDetector`
/// beneath whenever neither button is under the finger.
class _FloatingShapeControls extends StatelessWidget {
  const _FloatingShapeControls({
    required this.annotation,
    required this.contentRect,
    required this.transform,
    required this.onDelete,
    required this.onDuplicate,
  });

  final Annotation annotation;
  final Rect contentRect;
  final ImageTransform transform;
  final VoidCallback onDelete;
  final VoidCallback onDuplicate;

  @override
  Widget build(BuildContext context) {
    final anchors = floatingControlAnchors(annotation, contentRect, transform);
    final deleteAnchor = anchors[0];
    final duplicateAnchor = anchors[1];

    // Transparency: this widget supplies its own Material so a host
    // embedding a bare AnnotationOverlay (as the widget tests do) is
    // not required to wrap it in one just for these two InkWells --
    // D3AnnotatorScreen already provides one for its own bars, but
    // AnnotationOverlay is documented as composable on its own.
    return Material(
      type: MaterialType.transparency,
      child: Stack(
        children: [
          Positioned(
            left: deleteAnchor.dx - kMinimumTouchTarget / 2,
            top: deleteAnchor.dy - kMinimumTouchTarget / 2,
            child: D3FloatingButton(
              icon: Icons.close,
              tooltip: 'Delete',
              color: Colors.redAccent,
              onPressed: onDelete,
            ),
          ),
          Positioned(
            left: duplicateAnchor.dx - kMinimumTouchTarget / 2,
            top: duplicateAnchor.dy - kMinimumTouchTarget / 2,
            child: D3FloatingButton(
              icon: Icons.add_box_outlined,
              tooltip: 'Duplicate',
              color: Colors.white,
              onPressed: onDuplicate,
            ),
          ),
        ],
      ),
    );
  }
}

/// What the text-entry overlay is doing: placing a brand-new
/// [TextAnnotation] at [position], or re-editing [existing]'s content in
/// place (WORK-0034). Exactly one of the two is set.
@immutable
class _TextEditSession {
  const _TextEditSession({this.position, this.existing})
    : assert(
        (position == null) != (existing == null),
        'exactly one of position or existing must be given',
      );

  final NormalizedPoint? position;
  final TextAnnotation? existing;
}

/// A single-line [TextField] positioned at a [_TextEditSession]'s
/// anchor point, for placing or re-editing a [TextAnnotation]
/// (WORK-0034).
///
/// Positioned in pixel space like the floating shape controls -- a
/// sibling of the drawing `GestureDetector`, not nested inside it, so
/// this field's own taps and the system keyboard's focus never enter
/// that pan/scale gesture arena.
class _TextEntryOverlay extends StatefulWidget {
  const _TextEntryOverlay({
    required this.session,
    required this.contentRect,
    required this.transform,
    required this.style,
    required this.onCommit,
    required this.onCancel,
  });

  final _TextEditSession session;
  final Rect contentRect;
  final ImageTransform transform;

  /// The style a *new* placement would use -- irrelevant when
  /// [_TextEditSession.existing] is set, since editing keeps that
  /// annotation's own style untouched.
  final AnnotationStyle style;

  final ValueChanged<String> onCommit;
  final VoidCallback onCancel;

  @override
  State<_TextEntryOverlay> createState() => _TextEntryOverlayState();
}

class _TextEntryOverlayState extends State<_TextEntryOverlay> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.session.existing?.text ?? '',
  );
  late final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    // Opens already focused -- the whole point of tap-to-place is typing
    // immediately, not a second tap to reach the keyboard.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final existing = widget.session.existing;
    final style = existing?.style ?? widget.style;
    final fontSizePixels = style.resolveFontSize(
      shorterSidePixels(widget.contentRect, widget.transform),
    );

    final anchor = existing != null
        ? textBoundsInPixels(existing, widget.contentRect, widget.transform)
              .topLeft
        : mapPointToPixels(
            widget.session.position!,
            widget.contentRect,
            widget.transform,
          );

    // Own Stack, the same pattern _FloatingShapeControls uses: a bare
    // Positioned needs a Stack as its direct ancestor, and this widget
    // sits under _MaybeTransformed's Transform, not a Stack, in the
    // overlay's own tree.
    return Stack(
      children: [
        Positioned(
          left: anchor.dx,
          top: anchor.dy,
          child: Material(
            type: MaterialType.transparency,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minWidth: math.max(fontSizePixels * 4, 80),
              ),
              child: IntrinsicWidth(
                child: TextField(
                  controller: _controller,
                  focusNode: _focusNode,
                  autofocus: true,
                  maxLines: 1,
                  // Single-line for v1 (WORK-0034): a hardware/software
                  // return key commits rather than inserting a newline
                  // the rest of this package's rendering has no
                  // support for.
                  textInputAction: TextInputAction.done,
                  onSubmitted: widget.onCommit,
                  style: TextStyle(
                    color: style.color,
                    fontSize: fontSizePixels,
                  ),
                  decoration: InputDecoration(
                    isDense: true,
                    filled: style.backgroundColor != null,
                    fillColor: style.backgroundColor,
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.zero,
                  ),
                  onTapOutside: (_) => widget.onCommit(_controller.text),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
