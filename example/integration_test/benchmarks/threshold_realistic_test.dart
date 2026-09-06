import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';

/// Same question as threshold_test.dart, but on busier pixels.
///
/// threshold_test.dart used a flat gradient and found the engine
/// consistently at or ahead of the isolate up to ~9MP -- a different
/// result from isolate_encode_test.dart's 12MP-only measurement, which
/// used circles-over-bands and found the isolate winning. Deflate's
/// cost depends on pixel entropy, not just pixel count, so the two
/// benchmarks may simply disagree because their images do. This settles
/// it by sweeping sizes on the busier content, which is closer to what
/// this package actually renders -- shapes and arrows over a photo.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<ui.Image> busySurfaceOf(int width, int height) async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    final bandHeight = height / 60;
    for (var i = 0; i < 60; i++) {
      canvas.drawRect(
        Rect.fromLTWH(0, i * bandHeight, width.toDouble(), bandHeight),
        Paint()..color = Color(0xFF000000 | (i * 0x040A0F)),
      );
    }
    final circleCount = (200 * (width * height) / (4000 * 3000)).round();
    for (var i = 0; i < circleCount; i++) {
      canvas.drawCircle(
        Offset(
          ((i * 197) % width).toDouble(),
          ((i * 313) % height).toDouble(),
        ),
        40 * (width / 4000),
        Paint()..color = Color(0x80000000 | (i * 0x00FF37)),
      );
    }
    return recorder.endRecording().toImage(width, height);
  }

  Future<void> measureAt(int width, int height, String label) async {
    final image = await busySurfaceOf(width, height);

    final engineWatch = Stopwatch()..start();
    final enginePng = await image.toByteData(format: ui.ImageByteFormat.png);
    engineWatch.stop();

    final raw = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    image.dispose();
    final pixels = raw!.buffer.asUint8List();

    final transferable = TransferableTypedData.fromList([pixels]);
    final isolateWatch = Stopwatch()..start();
    final isolatePng = await Isolate.run(() {
      final bytes = transferable.materialize().asUint8List();
      final decoded = img.Image.fromBytes(
        width: width,
        height: height,
        bytes: bytes.buffer,
        numChannels: 4,
      );
      return img.encodePng(decoded);
    });
    isolateWatch.stop();

    // ignore: avoid_print
    print('THRESHOLD_BUSY label=$label size=${width}x$height '
        'megapixels=${(width * height / 1000000).toStringAsFixed(1)} '
        'engine_ms=${engineWatch.elapsedMilliseconds} '
        'isolate_ms=${isolateWatch.elapsedMilliseconds} '
        'engine_bytes=${enginePng!.lengthInBytes} '
        'isolate_bytes=${isolatePng.length}');
  }

  testWidgets('encode cost across sizes, busy content', (tester) async {
    await measureAt(800, 600, 'small (screenshot-ish)');
    await measureAt(1200, 900, 'below default');
    await measureAt(2000, 1500, 'bounded default');
    await measureAt(2800, 2100, 'above default');
    await measureAt(3400, 2550, 'near full 12MP');
    await measureAt(4000, 3000, 'full 12MP');
  });
}
