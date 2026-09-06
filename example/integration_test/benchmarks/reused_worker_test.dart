import 'dart:async';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';

/// WORK-0031's gating question: does a reused isolate worker beat
/// `Isolate.run` per image for a batch?
///
/// WORK-0030's numbers already bundle per-call isolate spawn cost into
/// every measurement. A batch of ten pays that spawn ten times over if
/// each image calls `Isolate.run` independently. This measures the
/// alternative directly: one long-lived isolate, N encode jobs sent to
/// it over a `SendPort`, against N independent `Isolate.run` calls.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<ui.Image> surface(int seed) async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    for (var i = 0; i < 60; i++) {
      canvas.drawRect(
        Rect.fromLTWH(0, i * 50, 4000, 50),
        Paint()..color = Color(0xFF000000 | ((i + seed) * 0x040A0F)),
      );
    }
    final circleCount = 200;
    for (var i = 0; i < circleCount; i++) {
      canvas.drawCircle(
        Offset(
          (((i + seed) * 197) % 4000).toDouble(),
          (((i + seed) * 313) % 3000).toDouble(),
        ),
        40,
        Paint()..color = Color(0x80000000 | ((i + seed) * 0x00FF37)),
      );
    }
    return recorder.endRecording().toImage(4000, 3000);
  }

  const batchSize = 10;

  testWidgets('per-image Isolate.run for a batch', (tester) async {
    final buffers = <TransferableTypedData>[];
    for (var i = 0; i < batchSize; i++) {
      final image = await surface(i);
      final raw = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      buffers.add(TransferableTypedData.fromList([raw!.buffer.asUint8List()]));
    }

    final watch = Stopwatch()..start();
    for (final buffer in buffers) {
      await Isolate.run(() {
        final bytes = buffer.materialize().asUint8List();
        final decoded = img.Image.fromBytes(
          width: 4000,
          height: 3000,
          bytes: bytes.buffer,
          numChannels: 4,
        );
        return img.encodePng(decoded);
      });
    }
    watch.stop();

    // ignore: avoid_print
    print('PER_IMAGE_ISOLATE_RUN batch=$batchSize total_ms=${watch.elapsedMilliseconds} '
        'avg_ms=${(watch.elapsedMilliseconds / batchSize).toStringAsFixed(0)}');
  });

  testWidgets('reused worker isolate for a batch', (tester) async {
    final buffers = <TransferableTypedData>[];
    for (var i = 0; i < batchSize; i++) {
      final image = await surface(i);
      final raw = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      buffers.add(TransferableTypedData.fromList([raw!.buffer.asUint8List()]));
    }

    final watch = Stopwatch()..start();

    final spawnWatch = Stopwatch()..start();
    final ready = ReceivePort();
    await Isolate.spawn(_encodeWorker, ready.sendPort);
    final workerSendPort = await ready.first as SendPort;
    spawnWatch.stop();

    final results = ReceivePort();
    var received = 0;
    final done = Completer<void>();
    results.listen((message) {
      received++;
      if (received == buffers.length) done.complete();
    });

    for (final buffer in buffers) {
      workerSendPort.send([buffer, results.sendPort]);
    }
    await done.future;
    watch.stop();

    ready.close();
    results.close();

    // ignore: avoid_print
    print('REUSED_WORKER batch=$batchSize total_ms=${watch.elapsedMilliseconds} '
        'spawn_ms=${spawnWatch.elapsedMilliseconds} '
        'avg_ms=${(watch.elapsedMilliseconds / batchSize).toStringAsFixed(0)}');
  });
}

void _encodeWorker(SendPort mainSendPort) {
  final commands = ReceivePort();
  mainSendPort.send(commands.sendPort);
  commands.listen((message) {
    final args = message as List<dynamic>;
    final buffer = args[0] as TransferableTypedData;
    final replyTo = args[1] as SendPort;
    final bytes = buffer.materialize().asUint8List();
    final decoded = img.Image.fromBytes(
      width: 4000,
      height: 3000,
      bytes: bytes.buffer,
      numChannels: 4,
    );
    final png = img.encodePng(decoded);
    replyTo.send(png.length);
  });
}
