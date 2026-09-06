import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';

/// Where the residual 175 ms goes after moving encoding off the isolate.
///
/// Two candidates, and they have different fixes: copying 48 MB into the
/// isolate (fixable with TransferableTypedData, which moves the buffer
/// instead of copying it), or `toByteData(rawRgba)` itself, which cannot
/// leave the root isolate at all.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<ui.Image> surface() async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    for (var i = 0; i < 60; i++) {
      canvas.drawRect(
        Rect.fromLTWH(0, i * 50, 4000, 50),
        Paint()..color = Color(0xFF000000 | (i * 0x040A0F)),
      );
    }
    return recorder.endRecording().toImage(4000, 3000);
  }

  testWidgets('cost of moving 48MB: copy vs transfer', (tester) async {
    final image = await surface();
    final raw = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    image.dispose();
    final pixels = raw!.buffer.asUint8List();

    // Copying: the closure captures `pixels`, so Isolate.run copies all
    // 48 MB across.
    final copyWatch = Stopwatch()..start();
    final copiedLength = await Isolate.run(() => pixels.length);
    copyWatch.stop();

    // Transferring: TransferableTypedData moves the underlying buffer
    // without copying it. The sender loses access, which is fine here --
    // the bytes are consumed by the encode.
    final transferable = TransferableTypedData.fromList([pixels]);
    final transferWatch = Stopwatch()..start();
    final transferredLength = await Isolate.run(
      () => transferable.materialize().lengthInBytes,
    );
    transferWatch.stop();

    // ignore: avoid_print
    print('TRANSFER '
        'copy_ms=${copyWatch.elapsedMilliseconds} '
        'transfer_ms=${transferWatch.elapsedMilliseconds} '
        'copied=$copiedLength transferred=$transferredLength');
  });

  testWidgets('frame cost of toByteData(rawRgba) alone', (tester) async {
    // This is the part that provably cannot move. If it dominates the
    // residual jank, then ~50-60 ms is the floor for a 12MP render
    // however the rest is arranged.
    final image = await surface();

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Center(child: CircularProgressIndicator())),
      ),
    );

    final gaps = <int>[];
    var last = Stopwatch()..start();
    void onFrame(Duration _) {
      gaps.add(last.elapsedMicroseconds);
      last = Stopwatch()..start();
      WidgetsBinding.instance.addPostFrameCallback(onFrame);
    }

    WidgetsBinding.instance.addPostFrameCallback(onFrame);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    final baseline = gaps.reduce((a, b) => a > b ? a : b);
    gaps.clear();

    final extractWatch = Stopwatch()..start();
    final raw = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    extractWatch.stop();

    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    final during = gaps.reduce((a, b) => a > b ? a : b);
    image.dispose();

    // ignore: avoid_print
    print('EXTRACT_ONLY '
        'extract_ms=${extractWatch.elapsedMilliseconds} '
        'baseline_worst_us=$baseline during_worst_us=$during '
        'bytes=${raw!.lengthInBytes}');
  });

  testWidgets('end to end: transfer + isolate encode, frames measured', (
    tester,
  ) async {
    final image = await surface();

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Center(child: CircularProgressIndicator())),
      ),
    );

    final gaps = <int>[];
    var last = Stopwatch()..start();
    void onFrame(Duration _) {
      gaps.add(last.elapsedMicroseconds);
      last = Stopwatch()..start();
      WidgetsBinding.instance.addPostFrameCallback(onFrame);
    }

    WidgetsBinding.instance.addPostFrameCallback(onFrame);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    gaps.clear();

    final total = Stopwatch()..start();
    final raw = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    image.dispose();
    final transferable = TransferableTypedData.fromList([
      raw!.buffer.asUint8List(),
    ]);

    final future = Isolate.run(() {
      final bytes = transferable.materialize().asUint8List();
      final decoded = img.Image.fromBytes(
        width: 4000,
        height: 3000,
        bytes: bytes.buffer,
        numChannels: 4,
      );
      return img.encodePng(decoded);
    });

    // Pump *while* the encode runs -- that is the whole point, since
    // frames produced during the work are what reveal jank -- but stop
    // as soon as it completes, so `total_ms` reports the render rather
    // than the length of a fixed loop.
    var done = false;
    // ignore: unawaited_futures
    future.whenComplete(() => done = true);
    var pumped = 0;
    while (!done && pumped < 200) {
      await tester.pump(const Duration(milliseconds: 16));
      pumped++;
    }
    final png = await future;
    total.stop();

    final worst = gaps.reduce((a, b) => a > b ? a : b);

    // ignore: avoid_print
    print('END_TO_END '
        'total_ms=${total.elapsedMilliseconds} '
        'worst_frame_us=$worst png_bytes=${png.length}');
  });
}
