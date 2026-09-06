import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:d3_image_annotator/d3_image_annotator.dart';
import 'package:flutter/material.dart';

void main() {
  runApp(const AnnotatorExampleApp());
}

/// Demonstrates annotating an image that already exists — no camera
/// involved, which is the point of this package standing alone.
///
/// The test image is generated at runtime rather than bundled: a
/// labelled grid makes it obvious whether a mark landed where it was
/// drawn, and stays obvious when you zoom in.
class AnnotatorExampleApp extends StatelessWidget {
  const AnnotatorExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData.dark(),
      home: const _AnnotatorDemo(),
    );
  }
}

/// A 1200x1600 grid (3:4, like a phone photo) with labelled cells, so
/// "the mark is in cell C2" is checkable by eye at any zoom.
Future<Uint8List> _buildTestImage() async {
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

class _AnnotatorDemo extends StatefulWidget {
  const _AnnotatorDemo();

  @override
  State<_AnnotatorDemo> createState() => _AnnotatorDemoState();
}

class _AnnotatorDemoState extends State<_AnnotatorDemo> {
  static const _imageSize = Size(1200, 1600);

  final _controller = AnnotationController();
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _buildTestImage().then((b) {
      if (mounted) setState(() => _bytes = b);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Two outputs, and the difference is the point of the design.
  ///
  /// The annotations are saved as JSON -- editable forever, re-openable
  /// against the same photo months later. The flattened PNG is produced
  /// only now, for something that cannot carry data: a report, an
  /// attachment. The original is untouched either way.
  Future<void> _save(Uint8List source) async {
    final document = AnnotationDocument(
      annotations: _controller.annotations,
      sourceImageSize: _imageSize,
    );
    final json = jsonEncode(document.toJson());

    final rendered = await renderAnnotatedImage(
      imageBytes: source,
      annotations: _controller.annotations,
      transform: _controller.transform,
    );

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '${document.annotations.length} annotation(s): '
          '${json.length} bytes of JSON, '
          '${(rendered.length / 1024).round()} KB rendered PNG',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    if (bytes == null) {
      return const ColoredBox(
        color: Colors.black,
        child: Center(child: CircularProgressIndicator()),
      );
    }

    // The whole editor, chrome included. The package owns the toolbars,
    // history controls and close affordance, so a consuming app supplies
    // the background and decides what to do with the result -- rather
    // than reassembling a toolbar and re-deriving which controls belong
    // where.
    return D3AnnotatorScreen(
      background: AnnotationBackground.image(MemoryImage(bytes)),
      canvasSize: _imageSize,
      controller: _controller,
      onClose: () => ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Closed without saving')),
      ),
      onDone: () => _save(bytes),
    );
  }
}
