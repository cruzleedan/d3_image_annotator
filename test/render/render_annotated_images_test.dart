import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:d3_image_annotator/d3_image_annotator.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

/// A solid image of one colour, so which request produced which output
/// is unambiguous by inspection.
Future<Uint8List> _solidImage(int width, int height, Color color) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = color,
  );
  final image = await recorder.endRecording().toImage(width, height);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

Future<ui.Image> _decode(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  return frame.image;
}

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('renderAnnotatedImages', () {
    test('emits one RenderProgress per request, in order, fully counted',
        () async {
      final requests = [
        RenderRequest(
          imageBytes: await _solidImage(50, 50, const Color(0xFFFF0000)),
          annotations: const [],
        ),
        RenderRequest(
          imageBytes: await _solidImage(50, 50, const Color(0xFF00FF00)),
          annotations: const [],
        ),
        RenderRequest(
          imageBytes: await _solidImage(50, 50, const Color(0xFF0000FF)),
          annotations: const [],
        ),
      ];

      final progress = await renderAnnotatedImages(requests: requests).toList();

      expect(progress, hasLength(3));
      expect(progress.map((p) => p.completed), [1, 2, 3]);
      expect(progress.every((p) => p.total == 3), isTrue);
    });

    test('each result belongs to its own request, not a mixed-up one',
        () async {
      // The real risk in a loop that reuses state (a worker isolate,
      // shared buffers) between iterations: request 2's output
      // accidentally contains request 1's pixels. Distinct solid colours
      // make that unmissable.
      final requests = [
        RenderRequest(
          imageBytes: await _solidImage(40, 40, const Color(0xFFFF0000)),
          annotations: const [],
        ),
        RenderRequest(
          imageBytes: await _solidImage(40, 40, const Color(0xFF00FF00)),
          annotations: const [],
        ),
      ];

      final progress = await renderAnnotatedImages(requests: requests).toList();

      final first = await _decode(progress[0].bytes);
      final second = await _decode(progress[1].bytes);
      addTearDown(first.dispose);
      addTearDown(second.dispose);

      expect(await _pixelAt(first, 0.5, 0.5), const Color(0xFFFF0000));
      expect(await _pixelAt(second, 0.5, 0.5), const Color(0xFF00FF00));
    });

    test('annotations land correctly on each image in the batch', () async {
      RectangleAnnotation markAt(double left) => RectangleAnnotation(
        id: 'r',
        style: const AnnotationStyle(
          color: Color(0xFF000000),
          filled: true,
        ),
        rect: NormalizedRect(left: left, top: 0, right: left + 0.2, bottom: 0.2),
      );

      final requests = [
        RenderRequest(
          imageBytes: await _solidImage(100, 100, const Color(0xFFFFFFFF)),
          annotations: [markAt(0)],
        ),
        RenderRequest(
          imageBytes: await _solidImage(100, 100, const Color(0xFFFFFFFF)),
          annotations: [markAt(0.7)],
        ),
      ];

      final progress = await renderAnnotatedImages(requests: requests).toList();
      final first = await _decode(progress[0].bytes);
      final second = await _decode(progress[1].bytes);
      addTearDown(first.dispose);
      addTearDown(second.dispose);

      expect(await _pixelAt(first, 0.1, 0.1), const Color(0xFF000000));
      expect(await _pixelAt(second, 0.8, 0.1), const Color(0xFF000000));
    });

    test('an empty batch completes with no progress events', () async {
      final progress = await renderAnnotatedImages(requests: const []).toList();
      expect(progress, isEmpty);
    });

    test('a request that fails to decode surfaces as a stream error',
        () async {
      final requests = [
        RenderRequest(
          imageBytes: Uint8List.fromList(const [1, 2, 3]),
          annotations: const [],
        ),
      ];

      await expectLater(
        renderAnnotatedImages(requests: requests),
        emitsError(isA<RenderException>()),
      );
    });

    test('cancelling stops further requests from starting', () async {
      // Cancelling after a fixed delay is flaky by construction: a batch
      // of tiny in-memory renders can finish well inside a millisecond
      // on a fast host VM, so any wall-clock delay either always beats
      // the batch or never does, depending on the machine. Cancelling
      // deterministically on the *first* event removes that guesswork:
      // it proves the mechanism regardless of how fast rendering is.
      var emitted = 0;
      final requests = <RenderRequest>[
        for (var i = 0; i < 5; i++)
          RenderRequest(
            imageBytes: await _solidImage(30, 30, const Color(0xFF808080)),
            annotations: const [],
          ),
      ];

      late StreamSubscription<RenderProgress> subscription;
      final firstEvent = Completer<void>();
      subscription = renderAnnotatedImages(requests: requests).listen((_) {
        emitted++;
        if (!firstEvent.isCompleted) firstEvent.complete();
      });

      await firstEvent.future;
      await subscription.cancel();

      final afterCancel = emitted;
      // Give any wrongly-continued renders a real chance to land.
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(emitted, afterCancel,
          reason: 'no further progress after the subscription was cancelled');
      expect(emitted, lessThan(requests.length),
          reason: 'cancellation actually stopped the batch, rather than '
              'racing it to completion');
    });

    test('encoding above the async threshold still round-trips correctly',
        () async {
      // Exercises the shared-worker path (WORK-0031), not just the
      // small-image root-isolate path the other tests here use.
      const size = kAsyncEncodeThresholdPixels;
      final requests = [
        RenderRequest(
          imageBytes: await _solidImage(size, size, const Color(0xFFFF00FF)),
          annotations: const [],
        ),
        RenderRequest(
          imageBytes: await _solidImage(size, size, const Color(0xFF00FFFF)),
          annotations: const [],
        ),
      ];

      final progress = await renderAnnotatedImages(requests: requests).toList();
      final first = await _decode(progress[0].bytes);
      final second = await _decode(progress[1].bytes);
      addTearDown(first.dispose);
      addTearDown(second.dispose);

      expect(first.width, size);
      expect(await _pixelAt(first, 0.5, 0.5), const Color(0xFFFF00FF));
      expect(await _pixelAt(second, 0.5, 0.5), const Color(0xFF00FFFF));
    });
  });
}
