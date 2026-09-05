import 'package:flutter/material.dart';

import '../annotations/annotation_controller.dart';
import '../annotations/annotation_overlay_widget.dart';
import '../annotations/annotation_painter.dart';
import '../coordinates/normalized_rect.dart';
import '../geometry/content_rect.dart';
import '../annotations/annotation_style.dart';
import '../annotations/annotation_tool.dart';
import '../geometry/image_fit.dart';
import '../geometry/image_transform.dart';
import 'crop_overlay.dart';

/// A zoomable, annotatable image.
///
/// Works on any [ImageProvider] -- a file from disk, a freshly captured
/// photo, an asset, a network image. Nothing here knows or cares what
/// produced the image.
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
    required this.image,
    required this.imageSize,
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
  });

  final ImageProvider image;

  /// The image's pixel dimensions. Required rather than resolved from
  /// [image] because layout has to happen before the image decodes, and
  /// a box that resizes on decode would move annotations under the
  /// user. Callers generally know this already (a capture result, EXIF,
  /// or a database row).
  final Size imageSize;

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

  @override
  State<D3ImageAnnotator> createState() => _D3ImageAnnotatorState();
}

class _D3ImageAnnotatorState extends State<D3ImageAnnotator> {
  TransformationController? _ownedController;

  TransformationController get _transform =>
      widget.transformationController ??
      (_ownedController ??= TransformationController());

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
              Transform(
                transform: _transform.value,
                child: _TransformedImage(
                  image: widget.image,
                  fit: _boxFitFor(widget.fit),
                  imageTransform: widget.controller.transform,
                ),
              ),
              if (!widget.cropping)
                AnnotationOverlay(
                  controller: widget.controller,
                  imageSize: widget.imageSize,
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
                    final contentRect = computeImageContentRect(
                      widgetSize: Size(
                        constraints.maxWidth,
                        constraints.maxHeight,
                      ),
                      contentSize: widget.controller.transform.resultSize(
                        widget.imageSize,
                      ),
                      fit: widget.fit,
                    );
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
                          // An inset frame when nothing is cropped yet.
                          // Opening at the full frame is technically
                          // correct but reads as broken: there is no
                          // dimmed surround to see, and the corner
                          // handles sit right on the image edge where
                          // they are awkward to grab. Pixel and iOS both
                          // open inset for the same reason.
                          initialCrop:
                              widget.controller.transform.cropRect ??
                              _defaultCropFrame,
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

  static BoxFit _boxFitFor(ImageFit fit) => switch (fit) {
    ImageFit.contain => BoxFit.contain,
    ImageFit.cover => BoxFit.cover,
  };
}

/// Draws the image with the rotate / mirror / crop applied.
///
/// Crop is done with alignment and a fitted box rather than by cutting
/// pixels: nothing is destroyed, so clearing the crop restores the
/// original view immediately.
class _TransformedImage extends StatelessWidget {
  const _TransformedImage({
    required this.image,
    required this.fit,
    required this.imageTransform,
  });

  final ImageProvider image;
  final BoxFit fit;
  final ImageTransform imageTransform;

  @override
  Widget build(BuildContext context) {
    Widget child = Image(image: image, fit: fit);

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

/// Where the crop frame starts when the image has never been cropped.
///
/// Inset rather than full-frame so the handles are visible and clear of
/// the image edge from the moment crop mode opens.
final NormalizedRect _defaultCropFrame = NormalizedRect(
  left: 0.1,
  top: 0.1,
  right: 0.9,
  bottom: 0.9,
);
