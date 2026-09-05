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
/// - `D3ImageAnnotator` — a ready-made viewer: any `ImageProvider`,
///   pinch-zoom and pan, one finger draws.
/// - `AnnotationOverlay` plus `AnnotationController` and the shape
///   model — compose your own.
library;

// Model and controller
export 'src/annotations/annotation.dart';
export 'src/annotations/annotation_binding.dart';
export 'src/annotations/annotation_codec.dart';
export 'src/annotations/annotation_controller.dart';
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

// Viewer
export 'src/viewer/image_annotator.dart';
