import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Where the ~640 ms actually goes, stage by stage.
///
/// WORK-0030 flagged this as the open question that decides the fix: if
/// PNG encoding dominates, it is portable off the root isolate and worth
/// moving; if compositing dominates, it is not, and the answer has to be
/// UI-level. Reasoning about it would be guessing, so this measures it.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<Uint8List> source12mp() async {
    const width = 4000;
    const height = 3000;
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
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

  testWidgets('stage breakdown at full resolution', (tester) async {
    final bytes = await source12mp();

    // 1. Decode the source PNG to a ui.Image.
    final decodeWatch = Stopwatch()..start();
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final src = frame.image;
    decodeWatch.stop();
    codec.dispose();

    // 2. Record the canvas ops. Should be trivial -- recording builds a
    //    display list, it does not rasterize.
    final recordWatch = Stopwatch()..start();
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawImageRect(
      src,
      Rect.fromLTWH(0, 0, src.width.toDouble(), src.height.toDouble()),
      const Rect.fromLTWH(0, 0, 4000, 3000),
      Paint()..filterQuality = FilterQuality.high,
    );
    final picture = recorder.endRecording();
    recordWatch.stop();

    // 3. Rasterize the display list into a ui.Image.
    final rasterWatch = Stopwatch()..start();
    final rendered = await picture.toImage(4000, 3000);
    rasterWatch.stop();
    picture.dispose();

    // 4. Encode to PNG.
    final encodeWatch = Stopwatch()..start();
    final png = await rendered.toByteData(format: ui.ImageByteFormat.png);
    encodeWatch.stop();

    // 5. For comparison: raw RGBA extraction, no compression. Isolates
    //    how much of the encode cost is PNG's deflate specifically.
    final rawWatch = Stopwatch()..start();
    final raw = await rendered.toByteData(format: ui.ImageByteFormat.rawRgba);
    rawWatch.stop();

    // ignore: avoid_print
    print('BREAKDOWN '
        'decode_ms=${decodeWatch.elapsedMilliseconds} '
        'record_ms=${recordWatch.elapsedMilliseconds} '
        'raster_ms=${rasterWatch.elapsedMilliseconds} '
        'encode_png_ms=${encodeWatch.elapsedMilliseconds} '
        'extract_raw_ms=${rawWatch.elapsedMilliseconds} '
        'png_bytes=${png!.lengthInBytes} raw_bytes=${raw!.lengthInBytes}');

    src.dispose();
    rendered.dispose();
  });

  testWidgets('stage breakdown at the bounded default', (tester) async {
    final bytes = await source12mp();

    final decodeWatch = Stopwatch()..start();
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final src = frame.image;
    decodeWatch.stop();
    codec.dispose();

    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawImageRect(
      src,
      Rect.fromLTWH(0, 0, src.width.toDouble(), src.height.toDouble()),
      const Rect.fromLTWH(0, 0, 2000, 1500),
      Paint()..filterQuality = FilterQuality.high,
    );
    final picture = recorder.endRecording();

    final rasterWatch = Stopwatch()..start();
    final rendered = await picture.toImage(2000, 1500);
    rasterWatch.stop();
    picture.dispose();

    final encodeWatch = Stopwatch()..start();
    final png = await rendered.toByteData(format: ui.ImageByteFormat.png);
    encodeWatch.stop();

    // ignore: avoid_print
    print('BREAKDOWN_BOUNDED '
        'decode_ms=${decodeWatch.elapsedMilliseconds} '
        'raster_ms=${rasterWatch.elapsedMilliseconds} '
        'encode_png_ms=${encodeWatch.elapsedMilliseconds} '
        'png_bytes=${png!.lengthInBytes}');

    src.dispose();
    rendered.dispose();
  });

  testWidgets('does targetWidth on the codec cut decode cost?', (tester) async {
    // instantiateImageCodec can downscale during decode. If the caller
    // only wants 2000px out, decoding straight to 2000px would avoid
    // ever materializing the 48 MB full-size surface -- which would cut
    // both time and peak memory, not just one.
    final bytes = await source12mp();

    final fullWatch = Stopwatch()..start();
    final fullCodec = await ui.instantiateImageCodec(bytes);
    final full = (await fullCodec.getNextFrame()).image;
    fullWatch.stop();
    fullCodec.dispose();

    final scaledWatch = Stopwatch()..start();
    final scaledCodec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: 2000,
      targetHeight: 1500,
    );
    final scaled = (await scaledCodec.getNextFrame()).image;
    scaledWatch.stop();
    scaledCodec.dispose();

    // ignore: avoid_print
    print('DECODE_SCALING '
        'full_ms=${fullWatch.elapsedMilliseconds} '
        'full=${full.width}x${full.height} '
        'scaled_ms=${scaledWatch.elapsedMilliseconds} '
        'scaled=${scaled.width}x${scaled.height}');

    full.dispose();
    scaled.dispose();
  });
}
