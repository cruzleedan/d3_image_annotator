import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import '../annotations/annotation.dart';
import '../annotations/annotation_painter.dart';
import '../geometry/image_transform.dart';
import 'render_options.dart';

/// Renders [annotations] onto the image in [imageBytes] and returns
/// encoded bytes.
///
/// **Nothing is written and the source is never modified.** Annotations
/// are stored as data precisely so they stay editable; this is the step
/// that flattens them for something which cannot carry data — a PDF, an
/// email attachment, a share sheet. Where the bytes go afterwards is the
/// caller's business.
///
/// Compositing goes through [paintAnnotations], the same function the
/// live overlay uses. That is the design's central guarantee rather than
/// a convenience: SPIKE-0005 rejected a separate export renderer
/// outright as "exactly the 'looks right live, wrong on export' failure
/// mode". One function means the two cannot drift.
///
/// [transform] is applied the same way the viewer applies it, so a mark
/// clipped at a crop boundary on screen is clipped identically here.
///
/// Takes **encoded bytes**, not an `ImageProvider`. A provider resolves
/// through Flutter's image cache and binding, which only makes progress
/// while frames are being pumped — so awaiting one outside a widget
/// tree (in a background report-generation task, say) hangs forever.
/// Decoding the bytes directly has no such dependency. A caller holding
/// a provider can read the file itself, which is the honest cost of the
/// guarantee.
///
/// **Metadata is not preserved.** Rendering goes through decoded pixels,
/// so no EXIF from the source reaches the output — not orientation, not
/// capture time, and notably not the GPS fix. That is the intended
/// default rather than a limitation worked around: a render exists to be
/// attached to a report or shared, and a site photo's coordinates
/// travelling with it would be a disclosure the user never asked for. A
/// caller who needs provenance should carry it in the surrounding
/// document, where it can be shown and removed deliberately.
///
/// Source EXIF *orientation* is likewise not read here. Bytes that
/// require it must be decoded upright by the caller, or the rotation
/// expressed as an [ImageTransform] — which is the reversible
/// representation this package is built around anyway.
///
/// **Runs on the root isolate, and blocks it.** `PictureRecorder`
/// refuses to run anywhere else ("UI actions are only available on root
/// isolate", flutter/flutter#92575), so this cannot be moved to a
/// background isolate however much one might want to.
///
/// Measured on a Pixel 10 with a 12MP source (WORK-0027):
///
/// | | full resolution | bounded default |
/// |---|---|---|
/// | elapsed | ~695 ms | ~223 ms |
/// | peak decoded RGBA | 91.6 MB | 57.2 MB |
///
/// A full-resolution render therefore freezes the UI for roughly 640 ms
/// — about 40 dropped frames. **Show a progress indicator**, and prefer
/// the bounded default unless the original resolution is genuinely
/// needed. Rendering several images for one report multiplies this:
/// ten at full resolution is close to seven seconds.
///
/// Most of that is removable and is being removed. A stage breakdown
/// puts PNG encoding at 541 ms of the 648 ms total, against 26 ms for
/// compositing; encoding is mostly deflate and can run in a background
/// isolate, which takes the worst frame to ~134 ms at the same
/// wall-clock cost. WORK-0030 tracks that change and WORK-0031 the
/// multi-image case. Until then the numbers above are what to expect.
Future<Uint8List> renderAnnotatedImage({
  required Uint8List imageBytes,
  required List<Annotation> annotations,
  ImageTransform transform = ImageTransform.identity,
  RenderOptions options = const RenderOptions(),
}) async {
  final source = await _decodeSource(imageBytes);
  try {
    return await _render(
      source: source,
      annotations: annotations,
      transform: transform,
      options: options,
    );
  } finally {
    // Always dispose, including on failure: a leaked decoded image is
    // several megabytes that nothing else will reclaim.
    source.dispose();
  }
}

Future<Uint8List> _render({
  required ui.Image source,
  required List<Annotation> annotations,
  required ImageTransform transform,
  required RenderOptions options,
}) async {
  final sourceSize = Size(source.width.toDouble(), source.height.toDouble());

  // The transform's own output size, before any downscale: crop shrinks
  // it, a quarter turn swaps its axes.
  final transformed = transform.resultSize(sourceSize);
  final output = _scaleToFit(transformed, options.maxDimension);
  if (output.width < 1 || output.height < 1) {
    throw const RenderException('output size collapsed to nothing');
  }

  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  final target = Offset.zero & output;

  _drawTransformedSource(canvas, source, transform, target);

  // The same call the live overlay makes. A second rendering path is
  // what this design exists to prevent.
  paintAnnotations(canvas, target, annotations, transform: transform);

  final picture = recorder.endRecording();
  try {
    final rendered = await picture.toImage(
      output.width.round(),
      output.height.round(),
    );
    try {
      return await _encode(rendered, options);
    } finally {
      rendered.dispose();
    }
  } finally {
    picture.dispose();
  }
}

/// Draws the cropped, mirrored, rotated source into [target].
///
/// Built from canvas transforms rather than by producing intermediate
/// images: each intermediate would be another full-size allocation, and
/// the whole point of the bounded default is to keep peak memory down.
void _drawTransformedSource(
  ui.Canvas canvas,
  ui.Image source,
  ImageTransform transform,
  Rect target,
) {
  final crop = transform.effectiveCrop;
  // Source rect in the original image's pixels.
  final src = Rect.fromLTRB(
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
      ? Size(target.height, target.width)
      : target.size;
  final dst = Rect.fromCenter(
    center: Offset.zero,
    width: drawSize.width,
    height: drawSize.height,
  );

  canvas.drawImageRect(
    source,
    src,
    dst,
    Paint()..filterQuality = FilterQuality.high,
  );
  canvas.restore();
}

Size _scaleToFit(Size size, int? maxDimension) {
  if (maxDimension == null) return size;
  final longest = math.max(size.width, size.height);
  if (longest <= maxDimension) return size;
  final scale = maxDimension / longest;
  return Size(size.width * scale, size.height * scale);
}

Future<Uint8List> _encode(ui.Image image, RenderOptions options) async {
  final data = await image.toByteData(
    format: switch (options.format) {
      RenderFormat.png => ui.ImageByteFormat.png,
    },
  );
  if (data == null) {
    throw const RenderException('failed to encode the rendered image');
  }
  return data.buffer.asUint8List();
}

Future<ui.Image> _decodeSource(Uint8List bytes) async {
  try {
    final codec = await ui.instantiateImageCodec(bytes);
    try {
      final frame = await codec.getNextFrame();
      return frame.image;
    } finally {
      codec.dispose();
    }
  } on Object catch (error) {
    throw RenderException('could not decode the source image: $error');
  }
}
