import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:d3_image_annotator/d3_image_annotator.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// On-device measurements for WORK-0027.
///
/// These deliberately do not run in the host VM. A widget test there has
/// no real GPU, no device memory limit, and no frame pipeline to jank,
/// so a "pass" would measure nothing about the phone. The DoD asks what
/// happens on the hardware, so this runs on the hardware.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  /// A source at real camera resolution: 12MP, the size the Pixel
  /// actually produces and the case the bounded default exists for.
  Future<Uint8List> twelveMegapixelSource() async {
    const width = 4000;
    const height = 3000;
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);

    // Not a flat fill: a solid colour compresses to almost nothing and
    // would understate both the encode cost and the output size. Bands
    // plus shapes give the encoder something real to chew on.
    for (var i = 0; i < 60; i++) {
      canvas.drawRect(
        Rect.fromLTWH(0, i * (height / 60), width.toDouble(), height / 60),
        Paint()..color = Color(0xFF000000 | (i * 0x040A0F)),
      );
    }
    for (var i = 0; i < 200; i++) {
      canvas.drawCircle(
        Offset(((i * 197) % width).toDouble(), ((i * 313) % height).toDouble()),
        40,
        Paint()..color = Color(0x80000000 | (i * 0x00FF37)),
      );
    }

    final image = await recorder.endRecording().toImage(width, height);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return data!.buffer.asUint8List();
  }

  List<Annotation> markup() => [
    RectangleAnnotation(
      id: 'r',
      style: const AnnotationStyle(color: Color(0xFFFF3B30)),
      rect: NormalizedRect(left: 0.1, top: 0.1, right: 0.5, bottom: 0.4),
    ),
    const ArrowAnnotation(
      id: 'a',
      style: AnnotationStyle(color: Color(0xFF34C759)),
      start: NormalizedPoint(0.6, 0.2),
      end: NormalizedPoint(0.85, 0.55),
    ),
    CircleAnnotation(
      id: 'c',
      style: const AnnotationStyle(color: Color(0xFF007AFF)),
      rect: NormalizedRect(left: 0.3, top: 0.6, right: 0.7, bottom: 0.9),
    ),
  ];

  testWidgets('full-resolution render: memory ceiling and timing', (
    tester,
  ) async {
    final source = await twelveMegapixelSource();

    // Deliberately the unbounded path. The bounded default is the
    // safe one; what needs measuring is the ceiling a caller hits when
    // they explicitly ask for the original.
    final watch = Stopwatch()..start();
    final rendered = await renderAnnotatedImage(
      imageBytes: source,
      annotations: markup(),
      options: const RenderOptions(maxDimension: null),
    );
    watch.stop();

    final decoded = await ui.instantiateImageCodec(rendered);
    final frame = await decoded.getNextFrame();
    addTearDown(frame.image.dispose);

    binding.reportData = <String, dynamic>{
      ...?binding.reportData,
      // Also printed below: reportData is only collected by
      // `flutter drive`, and these numbers are the whole point of the run.
      'full_resolution': <String, dynamic>{
        'source_png_bytes': source.length,
        'output_png_bytes': rendered.length,
        'output_width': frame.image.width,
        'output_height': frame.image.height,
        'elapsed_ms': watch.elapsedMilliseconds,
        // Peak live bytes for the decoded surfaces: source and output
        // are both held as RGBA at once during compositing. This is the
        // number the bounded default exists to cap.
        'decoded_rgba_bytes': 4000 * 3000 * 4 + frame.image.width * frame.image.height * 4,
      },
    };

    // ignore: avoid_print
    print('MEASURE full_resolution '
        'source_png=${source.length} output_png=${rendered.length} '
        'out=${frame.image.width}x${frame.image.height} '
        'elapsed_ms=${watch.elapsedMilliseconds} '
        'peak_rgba_mb=${((4000 * 3000 * 4 + frame.image.width * frame.image.height * 4) / 1048576).toStringAsFixed(1)}');

    expect(frame.image.width, 4000, reason: 'full resolution preserved');
    expect(frame.image.height, 3000);
  });

  testWidgets('bounded default: memory and timing for the same source', (
    tester,
  ) async {
    final source = await twelveMegapixelSource();

    final watch = Stopwatch()..start();
    final rendered = await renderAnnotatedImage(
      imageBytes: source,
      annotations: markup(),
    );
    watch.stop();

    final decoded = await ui.instantiateImageCodec(rendered);
    final frame = await decoded.getNextFrame();
    addTearDown(frame.image.dispose);

    binding.reportData = <String, dynamic>{
      ...?binding.reportData,
      // Also printed below: reportData is only collected by
      // `flutter drive`, and these numbers are the whole point of the run.
      'bounded_default': <String, dynamic>{
        'output_png_bytes': rendered.length,
        'output_width': frame.image.width,
        'output_height': frame.image.height,
        'elapsed_ms': watch.elapsedMilliseconds,
        'decoded_rgba_bytes':
            4000 * 3000 * 4 + frame.image.width * frame.image.height * 4,
      },
    };

    // ignore: avoid_print
    print('MEASURE bounded_default '
        'output_png=${rendered.length} '
        'out=${frame.image.width}x${frame.image.height} '
        'elapsed_ms=${watch.elapsedMilliseconds} '
        'peak_rgba_mb=${((4000 * 3000 * 4 + frame.image.width * frame.image.height * 4) / 1048576).toStringAsFixed(1)}');

    expect(frame.image.width, 2000, reason: 'capped by the default');
  });

  testWidgets('a render while the UI animates does not drop frames', (
    tester,
  ) async {
    // The honest version of "does not jank". Compositing must run on the
    // root isolate (flutter/flutter#92575), so the only meaningful
    // question is what that does to frames actually being produced.
    // A spinner animates throughout; frame timings are recorded around
    // a full-resolution render.
    final source = await twelveMegapixelSource();

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.black,
          body: Center(child: CircularProgressIndicator()),
        ),
      ),
    );

    // Measured from the binding's own frame callbacks rather than
    // `traceAction`: that needs a VM Service connection which
    // `flutter test` does not expose to the app (it is a `flutter drive`
    // facility). Wall-clock gaps between real rasterized frames answer
    // the same question without the extra harness.
    final gaps = <int>[];
    var last = Stopwatch()..start();
    void onFrame(Duration _) {
      gaps.add(last.elapsedMicroseconds);
      last = Stopwatch()..start();
      binding.addPostFrameCallback(onFrame);
    }

    binding.addPostFrameCallback(onFrame);

    // Baseline: the spinner alone, no render competing with it.
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    final baseline = List<int>.from(gaps);
    gaps.clear();

    // Pump *while* the render is in flight, not after it has already
    // finished. Awaiting the render first and only then pumping records
    // nothing about the render itself -- it measures whatever the first
    // catch-up pump after a long await looks like, which is a property
    // of `tester.pump`, not of this function. (An earlier version of
    // this test made exactly that mistake, and it produced a "regression"
    // that was actually a measurement artifact -- see WORK-0030's log.)
    final watch = Stopwatch()..start();
    var done = false;
    final renderFuture = renderAnnotatedImage(
      imageBytes: source,
      annotations: markup(),
      options: const RenderOptions(maxDimension: null),
    );
    // ignore: unawaited_futures
    renderFuture.whenComplete(() => done = true);
    var pumped = 0;
    while (!done && pumped < 200) {
      await tester.pump(const Duration(milliseconds: 16));
      pumped++;
    }
    await renderFuture;
    watch.stop();

    int worst(List<int> xs) => xs.isEmpty ? 0 : xs.reduce((a, b) => a > b ? a : b);

    binding.reportData = <String, dynamic>{
      ...?binding.reportData,
      // Also printed below: reportData is only collected by
      // `flutter drive`, and these numbers are the whole point of the run.
      'jank': <String, dynamic>{
        'render_blocked_ms': watch.elapsedMilliseconds,
        'baseline_worst_frame_us': worst(baseline),
        'during_worst_frame_us': worst(gaps),
        'baseline_frames': baseline.length,
        'during_frames': gaps.length,
      },
    };

    // ignore: avoid_print
    print('MEASURE jank '
        'render_blocked_ms=${watch.elapsedMilliseconds} '
        'baseline_worst_us=${worst(baseline)} '
        'during_worst_us=${worst(gaps)} '
        'baseline_frames=${baseline.length} during_frames=${gaps.length}');
  });
}
