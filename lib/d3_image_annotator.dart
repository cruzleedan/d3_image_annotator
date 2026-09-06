/// Annotate images with shapes, arrows, and freehand marks.
///
/// **Geometry is stored in normalized `[0,1]` image space, never widget
/// pixels.** That is the one form invariant under everything that
/// differs between drawing a mark and exporting it: widget size, zoom
/// level, fit mode, image resolution, rotation, and mirroring. It is
/// what makes a mark drawn on a 400px preview land on the same feature
/// of a 4000px export.
///
/// Two layers:
///
/// - `D3ImageAnnotator` — a ready-made viewer: any `AnnotationBackground`
///   (a real image, or a plain colour fill for a blank canvas),
///   pinch-zoom and pan, one finger draws.
/// - `AnnotationOverlay` plus `AnnotationController` and the shape
///   model — compose your own.
library;

// Model and controller
export 'src/annotations/annotation.dart';
export 'src/annotations/annotation_binding.dart';
export 'src/annotations/annotation_codec.dart';
export 'src/annotations/annotation_controller.dart';
export 'src/annotations/annotation_handles.dart';
export 'src/annotations/annotation_overlay_widget.dart';
export 'src/annotations/annotation_painter.dart';
export 'src/annotations/annotation_style.dart';
export 'src/annotations/annotation_tool.dart';
export 'src/annotations/hit_testing.dart';

// Coordinates -- the normalized [0,1] lingua franca
export 'src/coordinates/coordinate_space.dart';
export 'src/coordinates/normalized_point.dart';
export 'src/coordinates/normalized_rect.dart';

// Geometry shared by the viewer and the overlay
export 'src/geometry/content_rect.dart';
export 'src/geometry/image_fit.dart';
export 'src/geometry/image_transform.dart';

// Reusable toolbar controls with guaranteed touch targets
export 'src/ui/annotator_screen.dart';
export 'src/ui/tool_button.dart';

// Rendering: flatten annotations into image bytes for output
//
// renderCompositedImage, PixelEncoder, and decodeSourceImage are hidden
// -- they exist only so renderAnnotatedImages (below) can share a
// worker isolate across a batch. A caller of this package should never
// need them, and their contract is free to change without notice.
export 'src/render/render_annotated_image.dart'
    hide renderCompositedImage, PixelEncoder, decodeSourceImage;
export 'src/render/render_annotated_images.dart';
export 'src/render/render_options.dart';

// Viewer
export 'src/viewer/annotation_background.dart';
export 'src/viewer/crop_overlay.dart';
export 'src/viewer/image_annotator.dart';
