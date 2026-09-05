import 'package:flutter/material.dart';

import '../annotations/annotation_controller.dart';
import '../annotations/annotation_overlay_widget.dart';
import '../annotations/annotation_style.dart';
import '../annotations/annotation_tool.dart';
import '../geometry/image_fit.dart';

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
        animation: _transform,
        builder: (context, _) {
          return Stack(
            fit: StackFit.expand,
            children: [
              Transform(
                transform: _transform.value,
                child: Image(
                  image: widget.image,
                  fit: _boxFitFor(widget.fit),
                ),
              ),
              AnnotationOverlay(
                controller: widget.controller,
                imageSize: widget.imageSize,
                tool: widget.tool,
                fit: widget.fit,
                transform: _transform.value,
                onScaleStart: _onScaleStart,
                onScaleUpdate: _onScaleUpdate,
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
