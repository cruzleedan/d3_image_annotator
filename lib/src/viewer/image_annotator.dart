import 'package:flutter/material.dart';

import '../annotations/annotation_binding.dart';
import '../annotations/annotation_codec.dart' show AnnotationDocument;
import '../annotations/annotation_controller.dart';
import '../annotations/annotation_overlay_widget.dart';
import '../annotations/annotation_painter.dart';
import '../coordinates/normalized_rect.dart';
import '../geometry/content_rect.dart';
import '../annotations/annotation_style.dart';
import '../annotations/annotation_tool.dart';
import '../geometry/image_fit.dart';
import '../geometry/image_transform.dart';
import 'annotation_background.dart';
import 'crop_overlay.dart';

/// A zoomable, annotatable canvas.
///
/// Works on any [AnnotationBackground] -- a real image (a file from
/// disk, a freshly captured photo, an asset, a network image) or a
/// plain colour fill (WORK-0036), swappable at runtime. Nothing here
/// knows or cares what produced an image background; a colour
/// background needs no background at all beyond a fill colour.
///
/// **Gestures.** One finger draws with the active [tool]; two fingers
/// pinch to zoom and pan. There is no mode to toggle, matching Apple
/// Photos markup and most drawing apps. See
/// `SinglePointerPanGestureRecognizer` for how the two are kept from
/// fighting over the same pointers.
///
/// **Annotations scale with the image, not the screen.** A circle drawn
/// around a hairline crack keeps its size *relative to the crack* at
/// every zoom level, because [AnnotationStyle.strokeWidth] is a fraction
/// of the image's shorter side rather than a pixel count. The
/// alternative -- constant on-screen stroke width, as CAD "flat to
/// screen" annotations use -- would make a mark's apparent thickness
/// change as you zoom, and would not survive export at all.
///
/// The overlay is placed *inside* the transformed child, so its local
/// coordinates are already untransformed image-box coordinates. That is
/// what keeps the coordinate maths identical at every zoom level: there
/// is no inverse matrix to get wrong, because the framework has already
/// applied it.
class D3ImageAnnotator extends StatefulWidget {
  const D3ImageAnnotator({
    super.key,
    required this.background,
    required this.canvasSize,
    required this.controller,
    this.tool = AnnotationTool.rectangle,
    this.fit = ImageFit.contain,
    this.minScale = 1.0,
    this.maxScale = 8.0,
    this.enableZoom = true,
    this.transformationController,
    this.backgroundColor = Colors.black,
    this.cropping = false,
    this.onCropChanged,
    this.cropInset = 28,
    this.sourceImageSize,
    this.onBindingChanged,
  });

  /// What sits behind the annotations: a real image, or a plain colour
  /// fill (WORK-0036). Swappable at runtime -- the consumer app rebuilds
  /// this widget with a new value (image to colour, colour to image, or
  /// image to a different image) without losing existing annotations,
  /// which live independently of any particular background.
  final AnnotationBackground background;

  /// The canvas's pixel dimensions -- the annotation coordinate space's
  /// size, regardless of what [background] is.
  ///
  /// Always explicit, never resolved from a decoded image or from this
  /// widget's own layout constraints, and required unconditionally
  /// rather than only for a colour background: layout has to happen
  /// before an image decodes (a box that resized on decode would move
  /// annotations under the user), and deriving it from the viewport
  /// would tie the coordinate space to whatever screen happened to be
  /// open, complicating export and reopening the same document later at
  /// a different size. Callers generally know this already (a capture
  /// result, EXIF, a database row, or a deliberately chosen canvas size
  /// for a blank document).
  final Size canvasSize;

  final AnnotationController controller;
  final AnnotationTool tool;

  /// How the image sits in the viewport before any zoom.
  /// [ImageFit.contain] by default -- annotating content you cannot see
  /// is a trap.
  final ImageFit fit;

  final double minScale;
  final double maxScale;

  /// Turns pinch-zoom off, leaving a plain annotatable image.
  final bool enableZoom;

  /// Supply one to observe or drive the zoom from outside -- a
  /// "reset zoom" button, or persisting the viewport. When null the
  /// widget owns its own.
  final TransformationController? transformationController;

  final Color backgroundColor;

  /// Shows the interactive crop frame, suspending drawing and zoom.
  ///
  /// Crop is a mode rather than a tool: while it is on, every drag
  /// adjusts the frame. That keeps it clear of the gesture contention
  /// that drawing and zoom already have to share, and matches how the
  /// Pixel and iOS editors behave.
  ///
  /// Nothing is applied while cropping -- the host decides when to
  /// commit the frame via `controller.crop`, so cancelling is free.
  final bool cropping;

  /// Reports the frame as it is dragged, so a host can enable a confirm
  /// button or show live dimensions.
  final ValueChanged<NormalizedRect>? onCropChanged;

  /// Margin left around the image while [cropping], in logical pixels.
  ///
  /// Without it the crop frame's corners sit against the screen edges,
  /// where Android's back-gesture zone lives -- dragging the left-hand
  /// corners triggers a navigate-back instead of a resize, which makes
  /// them effectively ungrabbable on a gesture-nav device. Google Photos
  /// insets the image during crop for the same reason.
  ///
  /// Applies only in crop mode: shrinking the image the rest of the time
  /// would waste space for no benefit.
  final double cropInset;

  /// The pixel dimensions the current annotations were originally drawn
  /// against, when known -- an `AnnotationDocument.sourceImageSize`
  /// hint, passed through so this widget can classify a background
  /// switch the same way `classifyBinding` already classifies a
  /// document reload (WORK-0036). Null skips the check ([onBindingChanged]
  /// is never called), matching `classifyBinding`'s own "no hint
  /// recorded" behaviour.
  final Size? sourceImageSize;

  /// Reports how [canvasSize] relates to [sourceImageSize] whenever
  /// either changes -- the same `classifyBinding` question
  /// `annotation_binding.dart` already answers for a document reload
  /// (WORK-0029), asked here at the moment of a live background switch
  /// instead. Advisory, like `classifyBinding` itself: this widget never
  /// acts on the result (rescaling annotations or refusing to switch),
  /// it only reports it for the consumer app to decide what a mismatch
  /// means.
  final ValueChanged<AnnotationBinding>? onBindingChanged;

  @override
  State<D3ImageAnnotator> createState() => _D3ImageAnnotatorState();
}

class _D3ImageAnnotatorState extends State<D3ImageAnnotator> {
  TransformationController? _ownedController;

  TransformationController get _transform =>
      widget.transformationController ??
      (_ownedController ??= TransformationController());

  @override
  void initState() {
    super.initState();
    _reportBindingIfChanged(previousCanvasSize: null);
  }

  @override
  void didUpdateWidget(D3ImageAnnotator oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Fires on a canvas-size change *or* a background swap -- a switch
    // from an image to a colour (or to a different image) is exactly
    // the moment WORK-0036 wires this classifier to, alongside the
    // existing "size actually changed" case.
    if (widget.canvasSize != oldWidget.canvasSize ||
        widget.background != oldWidget.background ||
        widget.sourceImageSize != oldWidget.sourceImageSize) {
      _reportBindingIfChanged(previousCanvasSize: oldWidget.canvasSize);
    }
  }

  /// Classifies `widget.canvasSize` against `widget.sourceImageSize` and
  /// reports it via `widget.onBindingChanged` -- the same
  /// `classifyBinding` question `annotation_binding.dart` already
  /// answers for a document reload (WORK-0029), asked here at the
  /// moment of a live background/size switch. `previousCanvasSize` is
  /// unused beyond documenting *why* this runs; the classification
  /// itself only ever depends on the current values.
  void _reportBindingIfChanged({required Size? previousCanvasSize}) {
    final hint = widget.sourceImageSize;
    if (hint == null) return;
    final binding = classifyBinding(
      AnnotationDocument(annotations: const [], sourceImageSize: hint),
      widget.canvasSize,
    );
    widget.onBindingChanged?.call(binding);
  }

  @override
  void dispose() {
    _ownedController?.dispose();
    super.dispose();
  }

  double _scaleAtGestureStart = 1;
  Offset _focalAtGestureStart = Offset.zero;
  Offset _translationAtGestureStart = Offset.zero;

  double get _scale => _transform.value.getMaxScaleOnAxis();

  Offset get _translation {
    final t = _transform.value.getTranslation();
    return Offset(t.x, t.y);
  }

  void _onScaleStart(ScaleStartDetails d) {
    _scaleAtGestureStart = _scale;
    _focalAtGestureStart = d.localFocalPoint;
    _translationAtGestureStart = _translation;
  }

  /// Rebuilds the matrix from the gesture rather than accumulating
  /// deltas, so a pinch that returns to its starting spread returns to
  /// its starting zoom instead of drifting.
  void _onScaleUpdate(ScaleUpdateDetails d) {
    if (!widget.enableZoom) return;
    final scale = (_scaleAtGestureStart * d.scale)
        .clamp(widget.minScale, widget.maxScale);

    // Keep the point under the fingers pinned while scaling, then apply
    // the focal point's own movement as a pan.
    final ratio = scale / _scaleAtGestureStart;
    final origin = _focalAtGestureStart;
    final panned = d.localFocalPoint - _focalAtGestureStart;
    final translation =
        (_translationAtGestureStart - origin) * ratio + origin + panned;

    _transform.value = Matrix4.identity()
      ..translateByDouble(translation.dx, translation.dy, 0, 1)
      ..scaleByDouble(scale, scale, 1, 1);
  }

  /// Where the image sits, leaving room for crop handles when cropping.
  Rect _contentRectFor(BoxConstraints constraints) {
    final inset = widget.cropping ? widget.cropInset : 0.0;
    final available = Size(
      (constraints.maxWidth - inset * 2).clamp(1.0, double.infinity),
      (constraints.maxHeight - inset * 2).clamp(1.0, double.infinity),
    );
    final rect = computeImageContentRect(
      widgetSize: available,
      contentSize: widget.controller.transform.resultSize(widget.canvasSize),
      fit: widget.fit,
    );
    return rect.shift(Offset(inset, inset));
  }

  @override
  Widget build(BuildContext context) {
    // No InteractiveViewer. Two gesture recognizers cannot share these
    // pointers -- ScaleGestureRecognizer accepts single-pointer
    // gestures, so a viewer beneath wins every one-finger drag, and a
    // drawing recognizer that declines still starves the viewer's
    // arena. Whichever way they nest, one always wins.
    //
    // So the overlay owns every pointer and reports pointerCount, and
    // the transform is driven from here: one finger draws, two fingers
    // zoom, with no arena contention to lose.
    return ColoredBox(
      color: widget.backgroundColor,
      child: AnimatedBuilder(
        // Both: zoom lives on _transform, rotate/mirror/crop on the
        // controller. A change to either has to repaint.
        animation: Listenable.merge([_transform, widget.controller]),
        builder: (context, _) {
          return Stack(
            fit: StackFit.expand,
            children: [
              // The image is placed in the *same* content rect the
              // overlay computes, not simply told to fill the viewport.
              // Cropping changes the aspect ratio, so a stretched-to-fit
              // image and an aspect-correct annotation layer end up
              // describing different rectangles -- marks then sit off
              // their content once a crop is applied.
              Transform(
                transform: _transform.value,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final contentRect = _contentRectFor(constraints);
                    return Stack(
                      children: [
                        Positioned.fromRect(
                          rect: contentRect,
                          child: _TransformedBackground(
                            background: widget.background,
                            imageTransform: widget.controller.transform,
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
              if (!widget.cropping)
                AnnotationOverlay(
                  controller: widget.controller,
                  imageSize: widget.canvasSize,
                  tool: widget.tool,
                  fit: widget.fit,
                  transform: _transform.value,
                  imageTransform: widget.controller.transform,
                  onScaleStart: _onScaleStart,
                  onScaleUpdate: _onScaleUpdate,
                )
              else
                // Annotations stay visible while cropping so the user can
                // see what the frame will keep -- but they are painted
                // without gestures, since the crop frame owns every
                // pointer in this mode.
                LayoutBuilder(
                  builder: (context, constraints) {
                    final contentRect = _contentRectFor(constraints);
                    return Stack(
                      fit: StackFit.expand,
                      children: [
                        IgnorePointer(
                          child: CustomPaint(
                            painter: AnnotationPainter(
                              annotations: widget.controller.annotations,
                              contentRect: contentRect,
                              transform: widget.controller.transform,
                            ),
                          ),
                        ),
                        CropOverlay(
                          contentRect: contentRect,
                          // Opens wrapping the whole image. The frame's
                          // black border plus white corner arms stay
                          // visible against any photo, so no inset is
                          // needed to make the handles findable.
                          initialCrop:
                              widget.controller.transform.effectiveCrop,
                          onChanged: (rect) =>
                              widget.onCropChanged?.call(rect),
                        ),
                      ],
                    );
                  },
                ),
            ],
          );
        },
      ),
    );
  }

}

/// Draws [background] with the rotate / mirror / crop applied.
///
/// Crop is done with alignment and a fitted box rather than by cutting
/// pixels: nothing is destroyed, so clearing the crop restores the
/// original view immediately.
///
/// A colour background skips all of that (WORK-0036): rotating, mirroring,
/// or windowing a plain fill onto itself is a visual no-op by
/// construction (a uniform colour looks identical from every angle and
/// through every crop window), so there is nothing for this widget to
/// apply -- only annotation clipping at the crop boundary needs to keep
/// working for a colour background, and that happens in
/// `annotation_painter.dart` against the annotations, not here against
/// the background's pixels.
class _TransformedBackground extends StatelessWidget {
  const _TransformedBackground({
    required this.background,
    required this.imageTransform,
  });

  final AnnotationBackground background;
  final ImageTransform imageTransform;

  @override
  Widget build(BuildContext context) {
    final color = colorOf(background);
    if (color != null) return ColoredBox(color: color);

    // BoxFit.fill, not contain: the caller has already sized this box to
    // the transformed image's exact aspect ratio, so filling it is
    // correct and letterboxing inside it would inset the picture away
    // from the annotations.
    Widget child = Image(image: imageOf(background)!, fit: BoxFit.fill);

    final crop = imageTransform.cropRect;
    if (crop != null) {
      // FractionallySizedBox with a negative-space alignment shows only
      // the cropped region, scaled to fill. The full image is still
      // there; this is a window onto it.
      child = ClipRect(
        child: FractionallySizedBox(
          widthFactor: crop.width == 0 ? 1 : 1 / crop.width,
          heightFactor: crop.height == 0 ? 1 : 1 / crop.height,
          alignment: Alignment(
            crop.width >= 1 ? 0 : (crop.left / (1 - crop.width)) * 2 - 1,
            crop.height >= 1 ? 0 : (crop.top / (1 - crop.height)) * 2 - 1,
          ),
          child: child,
        ),
      );
    }

    if (imageTransform.mirrored) {
      child = Transform.flip(flipX: true, child: child);
    }

    if (imageTransform.quarterTurns != 0) {
      child = RotatedBox(
        quarterTurns: imageTransform.quarterTurns,
        child: child,
      );
    }

    return child;
  }
}

