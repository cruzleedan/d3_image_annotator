import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';

/// Comparing encoder options for WORK-0030.
///
/// Research pointed two ways worth measuring rather than assuming:
/// pure-Dart encoding is reportedly far slower than a native codec, and
/// JPEG may be the better format for a photo destined for a PDF. Both
/// claims are cheap to test here and expensive to get wrong.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<ui.Image> photo() async {
    // Photographic-ish content: gradients and overlapping shapes, which
    // is what a JPEG/PNG size comparison needs. Flat colour would flatter
    // PNG unfairly.
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    for (var y = 0; y < 3000; y += 4) {
      canvas.drawRect(
        Rect.fromLTWH(0, y.toDouble(), 4000, 4),
        Paint()
          ..color = Color.fromARGB(
            255,
            (y ~/ 12) % 256,
            (y ~/ 7) % 256,
            (y ~/ 5) % 256,
          ),
      );
    }
    for (var i = 0; i < 400; i++) {
      canvas.drawCircle(
        Offset(((i * 197) % 4000).toDouble(), ((i * 313) % 3000).toDouble()),
        60,
        Paint()..color = Color(0x60000000 | (i * 0x00FF37)),
      );
    }
    return recorder.endRecording().toImage(4000, 3000);
  }

  testWidgets('PNG vs JPEG in an isolate: time and size', (tester) async {
    final image = await photo();
    final raw = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    image.dispose();
    final pixels = raw!.buffer.asUint8List();

    final pngWatch = Stopwatch()..start();
    final png = await Isolate.run(() {
      final decoded = img.Image.fromBytes(
        width: 4000,
        height: 3000,
        bytes: pixels.buffer,
        numChannels: 4,
      );
      return img.encodePng(decoded);
    });
    pngWatch.stop();

    // Level 3 rather than the default 6: PNG's deflate level trades time
    // against size, and for a report attachment the trade may be worth
    // making.
    final pngFastWatch = Stopwatch()..start();
    final pngFast = await Isolate.run(() {
      final decoded = img.Image.fromBytes(
        width: 4000,
        height: 3000,
        bytes: pixels.buffer,
        numChannels: 4,
      );
      return img.encodePng(decoded, level: 3);
    });
    pngFastWatch.stop();

    final jpgWatch = Stopwatch()..start();
    final jpg = await Isolate.run(() {
      final decoded = img.Image.fromBytes(
        width: 4000,
        height: 3000,
        bytes: pixels.buffer,
        numChannels: 4,
      );
      return img.encodeJpg(decoded, quality: 90);
    });
    jpgWatch.stop();

    // ignore: avoid_print
    print('CODECS '
        'png_ms=${pngWatch.elapsedMilliseconds} png_kb=${png.length ~/ 1024} '
        'png_l3_ms=${pngFastWatch.elapsedMilliseconds} '
        'png_l3_kb=${pngFast.length ~/ 1024} '
        'jpg90_ms=${jpgWatch.elapsedMilliseconds} '
        'jpg90_kb=${jpg.length ~/ 1024}');
  });

  testWidgets('engine PNG vs pure-Dart PNG, same surface', (tester) async {
    // Is the engine's own encoder (root isolate, blocking) actually
    // faster than the pure-Dart one? If it is much faster, then a
    // "block briefly" option is worth keeping for small images.
    final image = await photo();

    final engineWatch = Stopwatch()..start();
    final enginePng = await image.toByteData(format: ui.ImageByteFormat.png);
    engineWatch.stop();

    final raw = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    image.dispose();
    final pixels = raw!.buffer.asUint8List();

    final dartWatch = Stopwatch()..start();
    final dartPng = await Isolate.run(() {
      final decoded = img.Image.fromBytes(
        width: 4000,
        height: 3000,
        bytes: pixels.buffer,
        numChannels: 4,
      );
      return img.encodePng(decoded);
    });
    dartWatch.stop();

    // ignore: avoid_print
    print('ENGINE_VS_DART '
        'engine_ms=${engineWatch.elapsedMilliseconds} '
        'engine_kb=${enginePng!.lengthInBytes ~/ 1024} '
        'dart_isolate_ms=${dartWatch.elapsedMilliseconds} '
        'dart_kb=${dartPng.length ~/ 1024}');
  });

  testWidgets('bounded default: does the isolate still pay off?', (
    tester,
  ) async {
    // At 2000px the engine encode was only ~160 ms. If the isolate's
    // fixed costs exceed the saving, the right default may be to block
    // for small outputs and only go async above a threshold.
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    for (var y = 0; y < 1500; y += 4) {
      canvas.drawRect(
        Rect.fromLTWH(0, y.toDouble(), 2000, 4),
        Paint()
          ..color = Color.fromARGB(255, (y ~/ 6) % 256, (y ~/ 4) % 256, 128),
      );
    }
    final image = await recorder.endRecording().toImage(2000, 1500);

    final engineWatch = Stopwatch()..start();
    await image.toByteData(format: ui.ImageByteFormat.png);
    engineWatch.stop();

    final raw = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    image.dispose();
    final pixels = raw!.buffer.asUint8List();

    final isolateWatch = Stopwatch()..start();
    final isolatePng = await Isolate.run(() {
      final decoded = img.Image.fromBytes(
        width: 2000,
        height: 1500,
        bytes: pixels.buffer,
        numChannels: 4,
      );
      return img.encodePng(decoded);
    });
    isolateWatch.stop();

    // ignore: avoid_print
    print('BOUNDED_COMPARE '
        'engine_ms=${engineWatch.elapsedMilliseconds} '
        'isolate_ms=${isolateWatch.elapsedMilliseconds} '
        'kb=${isolatePng.length ~/ 1024}');
  });
}
