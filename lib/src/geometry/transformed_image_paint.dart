import 'dart:math' as math;
import 'dart:ui' as ui;

import 'image_transform.dart';

/// Draws [transform]'s cropped, mirrored, rotated view of [source] into
/// [target].
///
/// Built from canvas transforms rather than by producing intermediate
/// images: each intermediate would be another full-size allocation,
/// working against the whole reason a bounded render output exists (see
/// `render_annotated_image.dart`'s own docs on peak memory).
///
/// Shared by the document-level background render path
/// (`render_annotated_image.dart`) and, since WORK-0037, each
/// `ImageAnnotation`'s own independent [ImageTransform] in
/// `annotation_painter.dart` -- the same allocation-free canvas-rotate
/// approach applies to both, and duplicating it a second time would risk
/// the two drifting apart the way this whole package's "one painter,
/// one render path" design (WORK-0027) exists to prevent for
/// annotations generally.
void drawTransformedImage(
  ui.Canvas canvas,
  ui.Image source,
  ImageTransform transform,
  ui.Rect target,
) {
  final crop = transform.effectiveCrop;
  // Source rect in the original image's pixels.
  final src = ui.Rect.fromLTRB(
    crop.left * source.width,
    crop.top * source.height,
    crop.right * source.width,
    crop.bottom * source.height,
  );

  canvas.save();
  // Rotate and mirror about the target's centre, then draw the cropped
  // region into the *unrotated* rect -- for an odd quarter turn that
  // rect is the target with its axes swapped, since the rotation is
  // what makes it fit.
  canvas.translate(target.center.dx, target.center.dy);
  if (transform.quarterTurns != 0) {
    canvas.rotate(transform.quarterTurns * math.pi / 2);
  }
  if (transform.mirrored) canvas.scale(-1, 1);

  final drawSize = transform.swapsAxes
      ? ui.Size(target.height, target.width)
      : target.size;
  final dst = ui.Rect.fromCenter(
    center: ui.Offset.zero,
    width: drawSize.width,
    height: drawSize.height,
  );

  canvas.drawImageRect(
    source,
    src,
    dst,
    ui.Paint()..filterQuality = ui.FilterQuality.high,
  );
  canvas.restore();
}
