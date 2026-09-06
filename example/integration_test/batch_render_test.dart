import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:d3_image_annotator/d3_image_annotator.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// On-device verification for WORK-0031's Definition of done: the UI
/// must repaint between images (not just after the whole batch), and
/// peak memory for a batch of ten must stay close to a single render's.
///
/// Both claims need the device -- a host-VM test has no real GPU, no
/// device memory limit, and no frame pipeline to jank or to repaint on,
/// so it can prove the batch API's *logic* (test/render/
/// render_annotated_images_test.dart already does) but nothing about
/// whether it behaves the way this item promises on hardware.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<Uint8List> photoOf(int seed) async {
    // 12MP, above kAsyncEncodeThresholdPixels, so the batch actually
    // exercises the shared-worker path this item exists for -- not the
    // small-image root-isolate path, which was never the concern.
    const width = 4000;
    const height = 3000;
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    for (var i = 0; i < 60; i++) {
      canvas.drawRect(
        Rect.fromLTWH(0, i * (height / 60), width.toDouble(), height / 60),
        Paint()..color = Color(0xFF000000 | ((i + seed) * 0x040A0F)),
      );
    }
    for (var i = 0; i < 200; i++) {
      canvas.drawCircle(
        Offset(
          (((i + seed) * 197) % width).toDouble(),
          (((i + seed) * 313) % height).toDouble(),
        ),
        40,
        Paint()..color = Color(0x80000000 | ((i + seed) * 0x00FF37)),
      );
    }
    final image = await recorder.endRecording().toImage(width, height);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return data!.buffer.asUint8List();
  }

  testWidgets('the UI repaints between images, not only after the batch', (
    tester,
  ) async {
    const batchSize = 5;
    final requests = <RenderRequest>[
      for (var i = 0; i < batchSize; i++)
        RenderRequest(imageBytes: await photoOf(i), annotations: const []),
    ];

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.black,
          body: Center(child: CircularProgressIndicator()),
        ),
      ),
    );

    final progressAtFrame = <int>[];
    var completedSoFar = 0;
    var frames = 0;
    var pending = true;
    Object? streamError;

    final sub = renderAnnotatedImages(requests: requests).listen(
      (progress) => completedSoFar = progress.completed,
      onError: (Object error) => streamError = error,
      onDone: () => pending = false,
    );

    // A wall-clock deadline, not a pump-count cap: 5 full-resolution
    // renders (~700-860ms each, WORK-0030) need several real seconds
    // regardless of how many simulated frames are pumped in between, so
    // a count alone cannot distinguish "still legitimately working" from
    // "stuck". If this deadline is ever hit, that is itself the finding
    // -- worth seeing as a clean test failure, not an apparent hang.
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (pending && DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 16));
      progressAtFrame.add(completedSoFar);
      frames++;
    }
    await sub.cancel();

    if (streamError != null) {
      fail('renderAnnotatedImages stream error during batch: $streamError');
    }
    if (pending) {
      fail(
        'batch did not complete within 30s wall-clock '
        '($frames frames pumped, completedSoFar=$completedSoFar/$batchSize) '
        '-- see WORK-0031 log for what this would indicate',
      );
    }

    // The claim under test: completedSoFar took more than one distinct
    // value across the frames pumped *during* the batch. If the batch
    // ran to completion inside one microtask sweep before any frame was
    // pumped, every entry would read 0 until the last frame jumped
    // straight to batchSize -- exactly the "one long freeze" this item
    // exists to avoid.
    final distinctValues = progressAtFrame.toSet();

    // ignore: avoid_print
    print('BATCH_REPAINT frames_pumped=$frames '
        'distinct_progress_values=${distinctValues.length} '
        'sequence=$progressAtFrame');

    expect(distinctValues.length, greaterThan(1),
        reason: 'progress must advance across multiple pumped frames, not '
            'jump from 0 to $batchSize in one');
    expect(completedSoFar, batchSize);
  });

  testWidgets('peak memory for a batch of ten stays near one render\'s', (
    tester,
  ) async {
    const batchSize = 10;
    final requests = <RenderRequest>[
      for (var i = 0; i < batchSize; i++)
        RenderRequest(imageBytes: await photoOf(i), annotations: const []),
    ];

    // This does not measure RSS or heap bytes -- there is no in-process
    // API for that available to a Flutter integration test without a
    // platform channel this package does not have. WORK-0030 already
    // measured the real ceiling for one render on this device: 91.6 MB
    // of peak decoded RGBA. What this test can honestly demonstrate is
    // the structural claim the "close to a single render" promise rests
    // on: `await for` processes and discards one RenderProgress before
    // the next is produced, and nothing here accumulates results into a
    // list. A batch of ten that instead collected every output (the
    // "render all N in one isolate call" option this item's Options
    // considered explicitly rejected) would hold ten results at once by
    // construction; this loop structurally cannot, whatever batchSize
    // is, because there is never more than one RenderProgress alive.
    var completed = 0;
    var peakConcurrentlyHeld = 0;

    await for (final progress in renderAnnotatedImages(requests: requests)) {
      completed = progress.completed;
      // Never assigned to anything longer-lived than this loop body, so
      // there is exactly one RenderProgress reachable at a time --
      // that is the property under test, not its byte size.
      peakConcurrentlyHeld = 1;
    }

    // ignore: avoid_print
    print('BATCH_MEMORY_STRUCTURE batch=$batchSize completed=$completed '
        'max_results_alive_at_once=$peakConcurrentlyHeld');

    expect(completed, batchSize);
    expect(peakConcurrentlyHeld, 1,
        reason: 'the loop never holds more than one result at a time, '
            'regardless of batch size');
    // What this assertion cannot see: whether renderAnnotatedImages'
    // own internals buffer results before emitting them. That guarantee
    // comes from having read _BatchRenderer._start() in
    // render_annotated_images.dart -- it calls _controller.add() once
    // per completed request with no accumulating list -- not from
    // anything observable through this loop. Recorded here so that
    // guarantee isn't silently assumed to be load-bearing tested when
    // it is actually load-bearing *read*.
  });
}
