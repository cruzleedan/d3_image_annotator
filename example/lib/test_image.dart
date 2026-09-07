import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// The demo image's real pixel size -- every screen that annotates it
/// passes this same value as `canvasSize`, matching how a real caller
/// always knows the source's dimensions upfront.
const testImageSize = Size(1200, 1600);

/// A 1200x1600 grid (3:4, like a phone photo) with labelled cells, so
/// "the mark is in cell C2" is checkable by eye at any zoom.
///
/// Generated at runtime rather than bundled, so every demo screen stays
/// a single file with no asset wiring -- and a labelled grid makes it
/// obvious whether a mark landed where it was drawn, which stays
/// obvious when you zoom in.
Future<Uint8List> buildTestImage() async {
  const width = 1200.0;
  const height = 1600.0;
  const cols = 4;
  const rows = 5;

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);

  canvas.drawRect(
    const Rect.fromLTWH(0, 0, width, height),
    Paint()..color = const Color(0xFFF5F1E8),
  );

  final cellW = width / cols;
  final cellH = height / rows;
  final line = Paint()
    ..color = const Color(0xFF9AA5B1)
    ..strokeWidth = 3
    ..style = PaintingStyle.stroke;

  for (var c = 0; c <= cols; c++) {
    canvas.drawLine(Offset(c * cellW, 0), Offset(c * cellW, height), line);
  }
  for (var r = 0; r <= rows; r++) {
    canvas.drawLine(Offset(0, r * cellH), Offset(width, r * cellH), line);
  }

  for (var r = 0; r < rows; r++) {
    for (var c = 0; c < cols; c++) {
      final label = '${String.fromCharCode(65 + c)}${r + 1}';
      final painter = TextPainter(
        text: TextSpan(
          text: label,
          style: const TextStyle(
            color: Color(0xFF334155),
            fontSize: 44,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      painter.paint(
        canvas,
        Offset(
          c * cellW + (cellW - painter.width) / 2,
          r * cellH + (cellH - painter.height) / 2,
        ),
      );

      // Fine print, only legible zoomed in -- the reason pinch-zoom
      // exists here at all.
      final fine = TextPainter(
        text: TextSpan(
          text: 'zoom to read $label',
          style: const TextStyle(color: Color(0xFF64748B), fontSize: 11),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      fine.paint(
        canvas,
        Offset(
          c * cellW + (cellW - fine.width) / 2,
          r * cellH + (cellH - fine.height) / 2 + 40,
        ),
      );
    }
  }

  final picture = recorder.endRecording();
  final image = await picture.toImage(width.toInt(), height.toInt());
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  return bytes!.buffer.asUint8List();
}

/// A small square swatch, used as the "photo" an [ImageAnnotation]
/// places onto another canvas (see the image-annotation demo) -- a
/// second, visually distinct image so it is obvious at a glance which
/// pixels came from the nested annotation versus the page behind it.
Future<Uint8List> buildStampImage() async {
  const size = 300.0;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);

  canvas.drawRect(
    const Rect.fromLTWH(0, 0, size, size),
    Paint()..color = const Color(0xFFEA580C),
  );
  canvas.drawCircle(
    const Offset(size / 2, size / 2),
    size * 0.32,
    Paint()..color = const Color(0xFFFFF7ED),
  );
  final painter = TextPainter(
    text: const TextSpan(
      text: 'STAMP',
      style: TextStyle(
        color: Color(0xFF7C2D12),
        fontSize: 34,
        fontWeight: FontWeight.bold,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  painter.paint(
    canvas,
    Offset((size - painter.width) / 2, (size - painter.height) / 2),
  );

  final picture = recorder.endRecording();
  final image = await picture.toImage(size.toInt(), size.toInt());
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  return bytes!.buffer.asUint8List();
}
