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

  @override
  Widget build(BuildContext context) {
    final content = Stack(
      fit: StackFit.expand,
      children: [
        Image(image: widget.image, fit: _boxFitFor(widget.fit)),
        AnnotationOverlay(
          controller: widget.controller,
          imageSize: widget.imageSize,
          tool: widget.tool,
          fit: widget.fit,
        ),
      ],
    );

    return ColoredBox(
      color: widget.backgroundColor,
      child: widget.enableZoom
          ? InteractiveViewer(
              transformationController: _transform,
              minScale: widget.minScale,
              maxScale: widget.maxScale,
              // panEnabled MUST be false. It governs *single-finger*
              // dragging, and InteractiveViewer wins the arena for
              // those -- with it on, one-finger strokes are eaten as
              // pans and nothing is ever drawn. Verified on-device:
              // leaving it true produced no annotations at all.
              //
              // Two-finger panning is unaffected: scaleEnabled handles
              // the scale gesture, which carries translation with it,
              // so pinch-zoom and two-finger drag both still work.
              panEnabled: false,
              scaleEnabled: true,
              child: content,
            )
          : content,
    );
  }

  static BoxFit _boxFitFor(ImageFit fit) => switch (fit) {
    ImageFit.contain => BoxFit.contain,
    ImageFit.cover => BoxFit.cover,
  };
}
