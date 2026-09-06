import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:image/image.dart' as pkg_img;

import '../annotations/annotation.dart';
import '../annotations/annotation_painter.dart';
import '../geometry/image_transform.dart';
import 'render_options.dart';

/// Longest-side threshold, in pixels, above which PNG encoding moves to
/// a background isolate.
///
/// **Not a knob** — deliberately not exposed on [RenderOptions]. It is
/// an implementation detail a caller should not need to reason about,
/// and the number is only meaningful paired with the specific costs it
/// was measured against.
///
/// Set from a six-point size sweep on a Pixel 10 (WORK-0030), not from
/// picking a round number: the background isolate has a fixed cost
/// (~50 ms) that a wall-clock comparison shows losing to plain
/// root-isolate encoding at every size up to ~9MP, and only winning
/// once the work itself is large enough — full 12MP in the
/// measurement — to outweigh that fixed cost. Below the threshold the
/// root-isolate path is both faster *and* short enough to read as a
/// stutter rather than a stall, so there is no reason to pay for the
/// isolate. [kAsyncEncodeThresholdPixels] is set to
/// [RenderOptions.maxDimension]'s own default (2000) rather than
/// somewhere between the measured points, so the two most common
/// outcomes are also the two simplest to reason about: the bounded
/// default always encodes on the root isolate, and asking for more
/// (`maxDimension: null`, or an explicit larger value) always moves to
/// the background.
const int kAsyncEncodeThresholdPixels = 2000;

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
/// **Compositing runs on the root isolate and blocks it.**
/// `PictureRecorder` refuses to run anywhere else ("UI actions are only
/// available on root isolate", flutter/flutter#92575) — there is no way
/// to move drawing off it. What *can* move, and does above
/// [kAsyncEncodeThresholdPixels], is PNG encoding: it is most of the
/// cost (WORK-0027 measured 541 ms of 648 at 12MP, against 26 ms for
/// compositing) and none of it depends on the engine, so it runs in a
/// background isolate once an output is large enough to be worth the
/// isolate's own fixed overhead (WORK-0030).
///
/// Measured on a Pixel 10 with a 12MP source:
///
/// | | full resolution (async encode) | bounded default (2000px, sync encode) |
/// |---|---|---|
/// | elapsed | ~700 ms | ~220 ms |
/// | **worst frame** | **~134 ms** | **~120 ms** |
/// | peak decoded RGBA | 91.6 MB | 57.2 MB |
///
/// Both numbers are well short of what an unconditional root-isolate
/// encode cost before this: full resolution alone was ~640 ms of worst
/// frame, about 40 dropped frames. The remaining ~100–130 ms at either
/// size is `toByteData(rawRgba)` plus compositing, and it is the floor:
/// unlike encoding, it cannot leave the root isolate.
///
/// Rendering several images for one report still adds up — WORK-0031
/// tracks a batch API with progress for that case, since this function
/// renders one image at a time and a caller looping it has no way to
/// report progress except by counting iterations itself.
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
  switch (options.format) {
    case RenderFormat.png:
      final longestSide = math.max(image.width, image.height);
      return longestSide >= kAsyncEncodeThresholdPixels
          ? await _encodePngOffIsolate(image)
          : await _encodePngOnRootIsolate(image);
  }
}

/// The original, unconditional path: extract and encode both on the
/// root isolate. Used below [kAsyncEncodeThresholdPixels], where it
/// measures faster than the isolate path as well as short enough not
/// to need it.
Future<Uint8List> _encodePngOnRootIsolate(ui.Image image) async {
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  if (data == null) {
    throw const RenderException('failed to encode the rendered image');
  }
  return data.buffer.asUint8List();
}

/// Extracts raw pixels on the root isolate (unavoidable --
/// `ui.Image.toByteData` cannot run anywhere else) and PNG-encodes them
/// in a background isolate.
///
/// The pixel buffer is moved via [TransferableTypedData] rather than
/// captured by the isolate closure, which would copy it: measured at
/// 18–20 ms to transfer against 33–36 ms to copy, for a 12MP source
/// (WORK-0030). Transferring also means the buffer is never held twice
/// at once.
Future<Uint8List> _encodePngOffIsolate(ui.Image image) async {
  final raw = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  if (raw == null) {
    throw const RenderException('failed to extract pixels for encoding');
  }
  final transferable = TransferableTypedData.fromList([
    raw.buffer.asUint8List(),
  ]);
  final width = image.width;
  final height = image.height;

  return Isolate.run(() {
    final pixels = transferable.materialize().asUint8List();
    final decoded = pkg_img.Image.fromBytes(
      width: width,
      height: height,
      bytes: pixels.buffer,
      numChannels: 4,
    );
    return pkg_img.encodePng(decoded);
  });
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
