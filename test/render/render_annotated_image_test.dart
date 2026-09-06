import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:d3_image_annotator/d3_image_annotator.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

/// Builds a solid-white source image, so a coloured annotation
/// is unambiguous against it.
Future<Uint8List> _whiteImage(int width, int height) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = const Color(0xFFFFFFFF),
  );
  final image = await recorder.endRecording().toImage(width, height);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

/// Decodes rendered bytes so pixels can be inspected.
Future<ui.Image> _decode(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  return frame.image;
}

/// The colour at a normalized position of [image].
Future<Color> _pixelAt(ui.Image image, double nx, double ny) async {
  final data = await image.toByteData();
  final x = (nx * (image.width - 1)).round();
  final y = (ny * (image.height - 1)).round();
  final offset = (y * image.width + x) * 4;
  final bytes = data!.buffer.asUint8List();
  return Color.fromARGB(
    bytes[offset + 3],
    bytes[offset],
    bytes[offset + 1],
    bytes[offset + 2],
  );
}

/// The PNG chunk types present in [bytes], in file order.
///
/// PNG is a sequence of length-prefixed chunks after an 8-byte signature;
/// each chunk is a 4-byte big-endian length, a 4-byte ASCII type, the
/// data, and a 4-byte CRC.
List<String> _pngChunkTypes(Uint8List bytes) {
  final types = <String>[];
  var i = 8;
  while (i + 8 <= bytes.length) {
    final length =
        (bytes[i] << 24) | (bytes[i + 1] << 16) | (bytes[i + 2] << 8) |
        bytes[i + 3];
    final type = String.fromCharCodes(bytes.sublist(i + 4, i + 8));
    types.add(type);
    if (type == 'IEND') break;
    i += 12 + length;
  }
  return types;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const red = Color(0xFFFF0000);

  RectangleAnnotation filledRect({
    required double left,
    required double top,
    required double right,
    required double bottom,
  }) => RectangleAnnotation(
    id: 'r',
    style: const AnnotationStyle(color: red, filled: true),
    rect: NormalizedRect(left: left, top: top, right: right, bottom: bottom),
  );

  group('rendering', () {
    test('marks land where the overlay would have shown them', () async {
      // The guarantee the whole design rests on. A filled rect covering
      // the top-left quadrant must colour that quadrant of the output
      // and leave the rest untouched -- so the mark is where it was
      // drawn, not merely somewhere.
      final source = await _whiteImage(400, 400);

      final bytes = await renderAnnotatedImage(
        imageBytes: source,
        annotations: [
          filledRect(left: 0, top: 0, right: 0.5, bottom: 0.5),
        ],
      );

      final rendered = await _decode(bytes);
      addTearDown(rendered.dispose);

      expect(await _pixelAt(rendered, 0.25, 0.25), red,
          reason: 'inside the annotation');
      expect(await _pixelAt(rendered, 0.75, 0.75), const Color(0xFFFFFFFF),
          reason: 'outside it, the source shows through');
    });

    test('an image with no annotations renders unchanged', () async {
      final source = await _whiteImage(200, 200);

      final bytes = await renderAnnotatedImage(
        imageBytes: source,
        annotations: const [],
      );

      final rendered = await _decode(bytes);
      addTearDown(rendered.dispose);
      expect(await _pixelAt(rendered, 0.5, 0.5), const Color(0xFFFFFFFF));
    });

    test('rendering twice from the same data is identical', () async {
      // Annotations are stored as data and rendered on demand, so a
      // report regenerated tomorrow must match the one sent today.
      final source = await _whiteImage(200, 200);
      final annotations = [
        filledRect(left: 0.2, top: 0.2, right: 0.6, bottom: 0.6),
      ];

      final first = await renderAnnotatedImage(
        imageBytes: source,
        annotations: annotations,
      );
      final second = await renderAnnotatedImage(
        imageBytes: source,
        annotations: annotations,
      );

      expect(first, second);
    });

    test('the source image is never modified', () async {
      // Rendering is a read: the whole point of storing annotations as
      // data is that the original stays editable.
      final source = await _whiteImage(200, 200);
      final before = Uint8List.fromList(source);

      await renderAnnotatedImage(
        imageBytes: source,
        annotations: [filledRect(left: 0, top: 0, right: 1, bottom: 1)],
      );

      expect(source, before);
    });
  });

  group('output size', () {
    test('is bounded by default', () async {
      // Site Inspector hit real memory trouble with unbounded
      // full-resolution copies; a report attachment rarely needs 12MP.
      final source = await _whiteImage(3000, 2000);

      final bytes = await renderAnnotatedImage(
        imageBytes: source,
        annotations: const [],
      );

      final rendered = await _decode(bytes);
      addTearDown(rendered.dispose);
      expect(rendered.width, 2000, reason: 'longest side capped');
      expect(rendered.height, lessThanOrEqualTo(2000));
    });

    test('keeps the aspect ratio when downscaling', () async {
      final source = await _whiteImage(3000, 1500);

      final bytes = await renderAnnotatedImage(
        imageBytes: source,
        annotations: const [],
        options: const RenderOptions(maxDimension: 600),
      );

      final rendered = await _decode(bytes);
      addTearDown(rendered.dispose);
      expect(rendered.width, 600);
      expect(rendered.height, 300);
    });

    test('full resolution is available but must be asked for', () async {
      final source = await _whiteImage(2400, 1200);

      final bytes = await renderAnnotatedImage(
        imageBytes: source,
        annotations: const [],
        options: const RenderOptions(maxDimension: null),
      );

      final rendered = await _decode(bytes);
      addTearDown(rendered.dispose);
      expect(rendered.width, 2400);
    });

    test('a small image is not upscaled', () async {
      final source = await _whiteImage(100, 50);

      final bytes = await renderAnnotatedImage(
        imageBytes: source,
        annotations: const [],
      );

      final rendered = await _decode(bytes);
      addTearDown(rendered.dispose);
      expect(rendered.width, 100);
    });
  });

  group('transforms', () {
    test('a quarter turn swaps the output dimensions', () async {
      final source = await _whiteImage(400, 200);

      final bytes = await renderAnnotatedImage(
        imageBytes: source,
        annotations: const [],
        transform: const ImageTransform(quarterTurns: 1),
      );

      final rendered = await _decode(bytes);
      addTearDown(rendered.dispose);
      expect(rendered.width, 200);
      expect(rendered.height, 400);
    });

    test('a crop shrinks the output to the visible region', () async {
      final source = await _whiteImage(400, 400);

      final bytes = await renderAnnotatedImage(
        imageBytes: source,
        annotations: const [],
        transform: ImageTransform(
          cropRect: NormalizedRect(
            left: 0.25,
            top: 0.25,
            right: 0.75,
            bottom: 0.75,
          ),
        ),
      );

      final rendered = await _decode(bytes);
      addTearDown(rendered.dispose);
      expect(rendered.width, 200);
      expect(rendered.height, 200);
    });

    test('a mark outside the crop is clipped away', () async {
      // The obligation carried over from WORK-0026: a mark clipped at
      // the crop boundary on screen must be clipped identically here,
      // or it would reappear whole in a report.
      final source = await _whiteImage(400, 400);

      final bytes = await renderAnnotatedImage(
        imageBytes: source,
        annotations: [
          // Entirely within the top-left corner, well outside the crop.
          filledRect(left: 0, top: 0, right: 0.15, bottom: 0.15),
        ],
        transform: ImageTransform(
          cropRect: NormalizedRect(
            left: 0.5,
            top: 0.5,
            right: 1,
            bottom: 1,
          ),
        ),
      );

      final rendered = await _decode(bytes);
      addTearDown(rendered.dispose);

      // Nothing red anywhere: the mark lies outside what was kept.
      for (final at in const [0.1, 0.5, 0.9]) {
        expect(await _pixelAt(rendered, at, at), const Color(0xFFFFFFFF));
      }
    });
  });

  group('rotation (WORK-0033)', () {
    RectangleAnnotation rotatedRect({
      required double left,
      required double top,
      required double right,
      required double bottom,
      required double rotation,
    }) => RectangleAnnotation(
      id: 'r',
      style: const AnnotationStyle(color: red, filled: true),
      rect: NormalizedRect(left: left, top: top, right: right, bottom: bottom),
      rotation: rotation,
    );

    test('a rotated rectangle paints outside its own unrotated corners',
        () async {
      // A wide, short rect rotated 90 degrees becomes a tall, narrow
      // one -- so a point in what *was* the unrotated rect's short
      // side should now be red, since the rotation swings the long
      // side through it.
      final source = await _whiteImage(400, 400);

      final bytes = await renderAnnotatedImage(
        imageBytes: source,
        annotations: [
          rotatedRect(
            left: 0.2,
            top: 0.47,
            right: 0.8,
            bottom: 0.53,
            rotation: math.pi / 2,
          ),
        ],
      );

      final rendered = await _decode(bytes);
      addTearDown(rendered.dispose);

      // Above the unrotated band's centre, along what becomes the long
      // axis after a 90 degree turn.
      expect(await _pixelAt(rendered, 0.5, 0.25), red,
          reason: 'the long side should now run vertically through here');
      // Where the unrotated band's long side used to reach -- now
      // outside the rotated (narrow) shape.
      expect(await _pixelAt(rendered, 0.25, 0.5), const Color(0xFFFFFFFF),
          reason: 'the old long side is gone once rotated 90 degrees');
    });

    test('rotation is not distorted by a non-square crop', () async {
      // The exact failure this item's log records, run through the
      // real render pipeline end to end rather than just the
      // supporting geometry: a 45 degree rotation must still measure
      // as 45 degrees on screen after an anisotropic crop, not the
      // 26.57 degrees an earlier, wrong version of this design
      // produced for the same inputs.
      //
      // An elongated rect (4:1, half-width 80px / half-height 20px in
      // the 400x200 cropped output) makes the two angles' vertical
      // reach at the shape's own centre-x differ measurably: 28px
      // (correct 45°) vs. 22px (the previously-measured 26.57°
      // distortion). Every test point below came from directly
      // simulating the painter's own rotation math in Python and
      // scanning for the true boundary, not from computing it by hand
      // a second, independent way -- an earlier draft of this test did
      // that and got the reach wrong by a factor of ~2.5, which would
      // have made the test assert something false rather than what it
      // meant to.
      final source = await _whiteImage(400, 400);

      final bytes = await renderAnnotatedImage(
        imageBytes: source,
        annotations: [
          rotatedRect(
            left: 0.3,
            top: 0.2,
            right: 0.7,
            bottom: 0.3,
            rotation: math.pi / 4,
          ),
        ],
        transform: ImageTransform(
          cropRect: NormalizedRect(left: 0, top: 0, right: 1, bottom: 0.5),
        ),
      );

      final rendered = await _decode(bytes);
      addTearDown(rendered.dispose);
      expect(rendered.width, 400);
      expect(rendered.height, 200);

      // The shape's own centre survives any rotation or crop
      // unchanged.
      expect(await _pixelAt(rendered, 0.5, 0.5), red,
          reason: "the rotated shape's centre must still be red after "
              'the crop');

      // Comfortably inside the diamond under *either* angle -- a
      // sanity check that the shape paints at all, so the
      // discriminating assertion below cannot pass vacuously by the
      // shape being empty or misplaced.
      expect(await _pixelAt(rendered, 0.5, 0.4150), red,
          reason: 'sanity check -- inside the rotated diamond under '
              'either the correct or the previously-buggy angle, so it '
              'must be red regardless');

      // Between the two angles' vertical reach at the shape's centre-x
      // (28px correct vs. 22px for the previously-measured distortion):
      // red only if the rotation is genuinely 45 degrees on screen.
      expect(
        await _pixelAt(rendered, 0.5, 0.3750),
        red,
        reason: 'outside the diamond the earlier, wrong design would '
            'have produced (reach ~22px) but inside the correct one '
            '(reach ~28px) -- red here is what tells correct and '
            'distorted apart',
      );

      // Outside the diamond under *either* angle -- confirms the shape
      // has a real edge, not that everything above centre reads red
      // for an unrelated reason.
      expect(await _pixelAt(rendered, 0.5, 0.3350), const Color(0xFFFFFFFF),
          reason: 'sanity check -- outside the diamond under either '
              'angle, so it must be white regardless');
    });

    test('a rotated mark is still clipped at the crop boundary', () async {
      final source = await _whiteImage(400, 400);

      final bytes = await renderAnnotatedImage(
        imageBytes: source,
        annotations: [
          rotatedRect(
            left: 0.05,
            top: 0.05,
            right: 0.2,
            bottom: 0.2,
            rotation: math.pi / 4,
          ),
        ],
        transform: ImageTransform(
          cropRect: NormalizedRect(left: 0.5, top: 0.5, right: 1, bottom: 1),
        ),
      );

      final rendered = await _decode(bytes);
      addTearDown(rendered.dispose);

      for (final at in const [0.1, 0.5, 0.9]) {
        expect(await _pixelAt(rendered, at, at), const Color(0xFFFFFFFF),
            reason: 'a rotated mark entirely outside the crop must be '
                'clipped away exactly like an unrotated one');
      }
    });
  });

  group('metadata', () {
    test('no metadata from the source survives into the render', () async {
      // A rendered image is a derived artefact meant to be attached to a
      // report or shared. It must not silently carry the original's GPS
      // fix, capture time, or device serial along with it -- a site
      // photo's coordinates leaving with a PDF is a disclosure, not a
      // feature. Rendering through decoded pixels drops all of it; this
      // test pins that as a guarantee rather than an accident of the
      // encoder, so a future switch to a metadata-preserving codec has
      // to confront the decision instead of quietly reversing it.
      final source = await _whiteImage(64, 64);

      final bytes = await renderAnnotatedImage(
        imageBytes: source,
        annotations: const [],
      );

      expect(_pngChunkTypes(bytes), isNot(contains('eXIf')));
      expect(_pngChunkTypes(bytes), isNot(contains('tEXt')));
      expect(_pngChunkTypes(bytes), isNot(contains('iTXt')));
    });
  });

  group('encode path split (WORK-0030)', () {
    // These run on the host VM, so they cannot measure jank -- that is
    // what example/integration_test/ is for. What belongs here is
    // correctness: whichever path ran, the output must decode and the
    // marks must still land where they were drawn. A host test can
    // exercise both sides of the threshold cheaply; it just cannot
    // watch a frame budget while doing so.
    test('below the threshold: still correct, still clipped', () async {
      const size = kAsyncEncodeThresholdPixels - 200;
      final source = await _whiteImage(size, size);

      final bytes = await renderAnnotatedImage(
        imageBytes: source,
        annotations: [filledRect(left: 0, top: 0, right: 0.5, bottom: 0.5)],
      );

      final rendered = await _decode(bytes);
      addTearDown(rendered.dispose);
      expect(rendered.width, size);
      expect(await _pixelAt(rendered, 0.25, 0.25), red);
      expect(await _pixelAt(rendered, 0.75, 0.75), const Color(0xFFFFFFFF));
    });

    test('at and above the threshold: still correct, still clipped', () async {
      // Large enough to route through the background-isolate encoder.
      // Kept as small as the threshold allows so the host-VM test suite
      // stays fast -- the actual jank claim is verified on-device.
      const size = kAsyncEncodeThresholdPixels;
      final source = await _whiteImage(size, size);

      final bytes = await renderAnnotatedImage(
        imageBytes: source,
        annotations: [filledRect(left: 0, top: 0, right: 0.5, bottom: 0.5)],
      );

      final rendered = await _decode(bytes);
      addTearDown(rendered.dispose);
      expect(rendered.width, size);
      expect(await _pixelAt(rendered, 0.25, 0.25), red);
      expect(await _pixelAt(rendered, 0.75, 0.75), const Color(0xFFFFFFFF));
    });

    test(
      'text survives the background-isolate encode path (WORK-0034) -- '
      'rasterized before compositing, so the encode worker never needs '
      'font access at all',
      () async {
        const size = kAsyncEncodeThresholdPixels;
        final source = await _whiteImage(size, size);

        final bytes = await renderAnnotatedImage(
          imageBytes: source,
          annotations: const [
            TextAnnotation(
              id: 't',
              style: AnnotationStyle(
                color: Color(0xFFFF0000),
                fontSize: 0.1,
              ),
              position: NormalizedPoint(0.1, 0.1),
              text: 'X',
            ),
          ],
        );

        final rendered = await _decode(bytes);
        addTearDown(rendered.dispose);
        expect(rendered.width, size);

        // Somewhere inside the glyph's rendered box, a red pixel must
        // exist -- if text were silently dropped or substituted by the
        // background-isolate encode path, every pixel in this region
        // would still be plain white.
        var foundRed = false;
        for (var dx = 0.0; dx <= 0.1; dx += 0.01) {
          for (var dy = 0.0; dy <= 0.1; dy += 0.01) {
            final color = await _pixelAt(rendered, 0.1 + dx, 0.1 + dy);
            if (color.r > 0.5 && color.g < 0.3 && color.b < 0.3) {
              foundRed = true;
              break;
            }
          }
          if (foundRed) break;
        }
        expect(foundRed, isTrue,
            reason: 'the text glyph must actually be painted, not '
                'silently dropped by the background-isolate encoder');
      },
    );

    test('the threshold is measured against the output, not the source',
        () async {
      // A large source cropped down to a small output should take the
      // cheap path -- the cost this threshold manages is encoding the
      // *output*, and a caller cropping a 12MP photo to a small detail
      // should not pay the isolate's fixed overhead for a small result.
      const size = kAsyncEncodeThresholdPixels * 2;
      final source = await _whiteImage(size, size);

      final bytes = await renderAnnotatedImage(
        imageBytes: source,
        annotations: const [],
        transform: ImageTransform(
          cropRect: NormalizedRect(left: 0, top: 0, right: 0.1, bottom: 0.1),
        ),
      );

      final rendered = await _decode(bytes);
      addTearDown(rendered.dispose);
      expect(rendered.width, lessThan(kAsyncEncodeThresholdPixels),
          reason: 'cropped output is small, regardless of source size');
    });

    test('output is deterministic on both sides of the threshold', () async {
      // WORK-0027's guarantee (rendering twice from the same data is
      // identical) must keep holding regardless of which encoder ran.
      for (final size in [
        kAsyncEncodeThresholdPixels - 100,
        kAsyncEncodeThresholdPixels + 100,
      ]) {
        final source = await _whiteImage(size, size);
        final annotations = [
          filledRect(left: 0.2, top: 0.2, right: 0.6, bottom: 0.6),
        ];

        final first = await renderAnnotatedImage(
          imageBytes: source,
          annotations: annotations,
        );
        final second = await renderAnnotatedImage(
          imageBytes: source,
          annotations: annotations,
        );

        expect(first, second, reason: 'size $size');
      }
    });
  });

  group('failure', () {
    test('a source that cannot be loaded raises a typed error', () async {
      // Rather than a bare exception from deep inside the image stack.
      await expectLater(
        renderAnnotatedImage(
          imageBytes: Uint8List.fromList(const [1, 2, 3]),
          annotations: const [],
        ),
        throwsA(isA<RenderException>()),
      );
    });
  });

  group('blank-canvas mode: renderAnnotatedCanvas (WORK-0036)', () {
    const blue = Color(0xFF0000FF);

    test('a colour background renders as a solid fill of that colour',
        () async {
      final bytes = await renderAnnotatedCanvas(
        color: blue,
        size: const Size(200, 200),
        annotations: const [],
      );

      final rendered = await _decode(bytes);
      addTearDown(rendered.dispose);
      expect(rendered.width, 200);
      expect(rendered.height, 200);
      expect(await _pixelAt(rendered, 0.1, 0.1), blue);
      expect(await _pixelAt(rendered, 0.9, 0.9), blue);
    });

    test('an annotation lands on a colour background the same way it '
        'would on an image', () async {
      final bytes = await renderAnnotatedCanvas(
        color: blue,
        size: const Size(400, 400),
        annotations: [
          filledRect(left: 0, top: 0, right: 0.5, bottom: 0.5),
        ],
      );

      final rendered = await _decode(bytes);
      addTearDown(rendered.dispose);
      expect(await _pixelAt(rendered, 0.25, 0.25), red,
          reason: 'inside the annotation');
      expect(await _pixelAt(rendered, 0.75, 0.75), blue,
          reason: 'outside it, the colour background shows through');
    });

    test('a mark outside a crop is clipped away against a colour '
        'background, the same as against an image', () async {
      // The obligation this item's DoD calls out explicitly: crop
      // clipping of annotations must carry over to a colour background
      // unchanged, verified here rather than assumed.
      final bytes = await renderAnnotatedCanvas(
        color: blue,
        size: const Size(400, 400),
        annotations: [
          filledRect(left: 0, top: 0, right: 0.15, bottom: 0.15),
        ],
        transform: ImageTransform(
          cropRect: NormalizedRect(left: 0.5, top: 0.5, right: 1, bottom: 1),
        ),
      );

      final rendered = await _decode(bytes);
      addTearDown(rendered.dispose);
      expect(rendered.width, 200);
      expect(rendered.height, 200);
      for (final at in const [0.1, 0.5, 0.9]) {
        expect(await _pixelAt(rendered, at, at), blue,
            reason: 'the mark lies outside what the crop kept');
      }
    });

    test('an image background still works through the same function',
        () async {
      final source = await _whiteImage(200, 200);

      final bytes = await renderAnnotatedCanvas(
        imageBytes: source,
        size: const Size(200, 200),
        annotations: [
          filledRect(left: 0, top: 0, right: 0.5, bottom: 0.5),
        ],
      );

      final rendered = await _decode(bytes);
      addTearDown(rendered.dispose);
      expect(await _pixelAt(rendered, 0.25, 0.25), red);
      expect(await _pixelAt(rendered, 0.75, 0.75), const Color(0xFFFFFFFF));
    });

    test('exactly one of imageBytes or color must be given', () {
      expect(
        () => renderAnnotatedCanvas(
          size: const Size(200, 200),
          annotations: const [],
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test('synthesizeSolidImage produces a real ui.Image of the given size',
        () async {
      final image = await synthesizeSolidImage(blue, const Size(50, 30));
      addTearDown(image.dispose);

      expect(image.width, 50);
      expect(image.height, 30);
    });

    for (final entry in <String, Annotation>{
      'rectangle': RectangleAnnotation(
        id: 'r',
        style: const AnnotationStyle(color: red, filled: true),
        rect: NormalizedRect(left: 0.2, top: 0.2, right: 0.6, bottom: 0.6),
      ),
      'circle': CircleAnnotation(
        id: 'c',
        style: const AnnotationStyle(color: red, filled: true),
        rect: NormalizedRect(left: 0.2, top: 0.2, right: 0.6, bottom: 0.6),
      ),
      'arrow': const ArrowAnnotation(
        id: 'a',
        style: AnnotationStyle(color: red, strokeWidth: 0.05),
        start: NormalizedPoint(0.2, 0.2),
        end: NormalizedPoint(0.6, 0.6),
      ),
      'freehand': FreehandAnnotation(
        id: 'f',
        style: const AnnotationStyle(color: red, strokeWidth: 0.05),
        points: const [NormalizedPoint(0.2, 0.2), NormalizedPoint(0.6, 0.6)],
      ),
    }.entries) {
      test(
        'a ${entry.key} paints visibly onto a colour background',
        () async {
          final bytes = await renderAnnotatedCanvas(
            color: blue,
            size: const Size(400, 400),
            annotations: [entry.value],
          );

          final rendered = await _decode(bytes);
          addTearDown(rendered.dispose);
          expect(await _pixelAt(rendered, 0.4, 0.4), red,
              reason: 'every annotation type crosses its own diagonal '
                  'midpoint');
          expect(await _pixelAt(rendered, 0.05, 0.95), blue,
              reason: 'a far corner stays the plain background colour');
        },
      );
    }
  });
}
