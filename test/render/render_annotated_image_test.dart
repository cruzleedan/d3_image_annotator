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
}
