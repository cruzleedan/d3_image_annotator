import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';

/// Can PNG encoding actually leave the root isolate?
///
/// The breakdown showed encoding is 83% of the render cost, and that
/// most of it is deflate rather than pixel extraction. Deflate is plain
/// CPU work on a byte buffer with no engine dependency, so in principle
/// it is portable in a way `PictureRecorder` is not. This proves it on
/// the device rather than assuming it.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('encoding RGBA to PNG in a background isolate', (tester) async {
    // Build a 12MP surface and extract raw pixels on the root isolate --
    // that part is unavoidable, and cheap (~57 ms).
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    for (var i = 0; i < 60; i++) {
      canvas.drawRect(
        Rect.fromLTWH(0, i * 50, 4000, 50),
        Paint()..color = Color(0xFF000000 | (i * 0x040A0F)),
      );
    }
    for (var i = 0; i < 200; i++) {
      canvas.drawCircle(
        Offset(((i * 197) % 4000).toDouble(), ((i * 313) % 3000).toDouble()),
        40,
        Paint()..color = Color(0x80000000 | (i * 0x00FF37)),
      );
    }
    final image = await recorder.endRecording().toImage(4000, 3000);

    final extractWatch = Stopwatch()..start();
    final raw = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    extractWatch.stop();

    // Baseline: encode on the root isolate, the current behaviour.
    final rootWatch = Stopwatch()..start();
    final rootPng = await image.toByteData(format: ui.ImageByteFormat.png);
    rootWatch.stop();
    image.dispose();

    // The candidate: hand the raw bytes to a background isolate and
    // encode there. `compute` copies the buffer; a TransferableTypedData
    // would move it instead, which matters at 48 MB.
    final pixels = raw!.buffer.asUint8List();
    final isolateWatch = Stopwatch()..start();
    final isolatePng = await Isolate.run(() {
      final decoded = img.Image.fromBytes(
        width: 4000,
        height: 3000,
        bytes: pixels.buffer,
        numChannels: 4,
      );
      return img.encodePng(decoded);
    });
    isolateWatch.stop();

    // ignore: avoid_print
    print('ISOLATE_ENCODE '
        'extract_raw_ms=${extractWatch.elapsedMilliseconds} '
        'root_encode_ms=${rootWatch.elapsedMilliseconds} '
        'isolate_encode_ms=${isolateWatch.elapsedMilliseconds} '
        'root_bytes=${rootPng!.lengthInBytes} '
        'isolate_bytes=${isolatePng.length}');

    expect(isolatePng.length, greaterThan(0));
  });

  testWidgets('is the UI responsive while the isolate encodes?', (
    tester,
  ) async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    for (var i = 0; i < 60; i++) {
      canvas.drawRect(
        Rect.fromLTWH(0, i * 50, 4000, 50),
        Paint()..color = Color(0xFF000000 | (i * 0x040A0F)),
      );
    }
    final image = await recorder.endRecording().toImage(4000, 3000);
    final raw = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    image.dispose();
    final pixels = raw!.buffer.asUint8List();

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.black,
          body: Center(child: CircularProgressIndicator()),
        ),
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

    // Kick off the encode, then keep pumping frames while it runs.
    final future = Isolate.run(() {
      final decoded = img.Image.fromBytes(
        width: 4000,
        height: 3000,
        bytes: pixels.buffer,
        numChannels: 4,
      );
      return img.encodePng(decoded);
    });

    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    await future;

    int worst(List<int> xs) =>
        xs.isEmpty ? 0 : xs.reduce((a, b) => a > b ? a : b);

    // ignore: avoid_print
    print('ISOLATE_JANK worst_frame_us=${worst(gaps)} frames=${gaps.length}');
  });
}
