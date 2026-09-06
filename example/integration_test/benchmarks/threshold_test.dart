import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';

/// Where does the isolate stop paying for itself?
///
/// codec_options_test.dart found the isolate a toss-up at 2000px (engine
/// ~130 ms, isolate 129-199 ms across runs) and a clear win at 4000px
/// (engine 592 ms, isolate 509-530 ms). WORK-0030's DoD asks for a
/// threshold picked from measurement, not from splitting that
/// difference by feel -- so this fills in the sizes between and below.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<ui.Image> surfaceOf(int width, int height) async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    for (var y = 0; y < height; y += 4) {
      canvas.drawRect(
        Rect.fromLTWH(0, y.toDouble(), width.toDouble(), 4),
        Paint()
          ..color = Color.fromARGB(
            255,
            (y ~/ 12) % 256,
            (y ~/ 7) % 256,
            (y ~/ 5) % 256,
          ),
      );
    }
    return recorder.endRecording().toImage(width, height);
  }

  Future<void> measureAt(int width, int height, String label) async {
    final image = await surfaceOf(width, height);

    // Root-isolate encode, the current unconditional path.
    final engineWatch = Stopwatch()..start();
    final enginePng = await image.toByteData(format: ui.ImageByteFormat.png);
    engineWatch.stop();

    final raw = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    image.dispose();
    final pixels = raw!.buffer.asUint8List();

    // Background-isolate encode via TransferableTypedData, same as the
    // proposed implementation.
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
    print('THRESHOLD label=$label size=${width}x$height '
        'megapixels=${(width * height / 1000000).toStringAsFixed(1)} '
        'engine_ms=${engineWatch.elapsedMilliseconds} '
        'isolate_ms=${isolateWatch.elapsedMilliseconds} '
        'engine_bytes=${enginePng!.lengthInBytes} '
        'isolate_bytes=${isolatePng.length}');
  }

  testWidgets('encode cost across sizes, engine vs isolate', (tester) async {
    // Each in its own iteration rather than one long test, so a slow
    // run at one size cannot be mistaken for a slow run at another --
    // the print lines are independently greppable.
    await measureAt(800, 600, 'small (screenshot-ish)');
    await measureAt(1200, 900, 'below default');
    await measureAt(2000, 1500, 'bounded default');
    await measureAt(2800, 2100, 'above default');
    await measureAt(3400, 2550, 'near full 12MP');
    await measureAt(4000, 3000, 'full 12MP');
  });
}
