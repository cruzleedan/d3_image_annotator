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
  final _transform = TransformationController();
  AnnotationTool _tool = AnnotationTool.rectangle;
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
    _transform.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('d3_image_annotator'),
        actions: [
          IconButton(
            tooltip: 'Reset zoom',
            onPressed: () => _transform.value = Matrix4.identity(),
            icon: const Icon(Icons.zoom_out_map),
          ),
        ],
      ),
      body: bytes == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Expanded(
                  child: D3ImageAnnotator(
                    image: MemoryImage(bytes),
                    imageSize: _imageSize,
                    controller: _controller,
                    tool: _tool,
                    transformationController: _transform,
                  ),
                ),
                _Toolbar(
                  tool: _tool,
                  controller: _controller,
                  onToolChanged: (t) => setState(() => _tool = t),
                ),
              ],
            ),
    );
  }
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.tool,
    required this.controller,
    required this.onToolChanged,
  });

  final AnnotationTool tool;
  final AnnotationController controller;
  final ValueChanged<AnnotationTool> onToolChanged;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 4),
                child: Text(
                  'One finger draws · two fingers pinch to zoom',
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  for (final t in AnnotationTool.values)
                    IconButton(
                      onPressed: () => onToolChanged(t),
                      color: t == tool ? Colors.amber : Colors.white70,
                      icon: Icon(switch (t) {
                        AnnotationTool.select => Icons.touch_app,
                        AnnotationTool.rectangle => Icons.crop_square,
                        AnnotationTool.circle => Icons.circle_outlined,
                        AnnotationTool.arrow => Icons.arrow_outward,
                        AnnotationTool.freehand => Icons.gesture,
                      }),
                    ),
                  IconButton(
                    onPressed: controller.canUndo ? controller.undo : null,
                    color: Colors.white70,
                    disabledColor: Colors.white24,
                    icon: const Icon(Icons.undo),
                  ),
                  IconButton(
                    onPressed: controller.canRedo ? controller.redo : null,
                    color: Colors.white70,
                    disabledColor: Colors.white24,
                    icon: const Icon(Icons.redo),
                  ),
                  IconButton(
                    onPressed: controller.isEmpty ? null : controller.clear,
                    color: Colors.white70,
                    disabledColor: Colors.white24,
                    icon: const Icon(Icons.delete_outline),
                  ),
                ],
              ),
              // Transforms: non-destructive, so annotations follow the
              // image and a crop can be undone.
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  IconButton(
                    tooltip: 'Rotate',
                    onPressed: controller.rotateClockwise,
                    color: Colors.white70,
                    icon: const Icon(Icons.rotate_90_degrees_cw),
                  ),
                  IconButton(
                    tooltip: 'Mirror',
                    onPressed: controller.toggleMirror,
                    color: controller.transform.mirrored
                        ? Colors.amber
                        : Colors.white70,
                    icon: const Icon(Icons.flip),
                  ),
                  IconButton(
                    tooltip: 'Crop to centre',
                    onPressed: () => controller.crop(
                      NormalizedRect(
                        left: 0.2,
                        top: 0.2,
                        right: 0.8,
                        bottom: 0.8,
                      ),
                    ),
                    color: controller.transform.cropRect != null
                        ? Colors.amber
                        : Colors.white70,
                    icon: const Icon(Icons.crop),
                  ),
                  IconButton(
                    tooltip: 'Reset transform',
                    onPressed: controller.transform.isIdentity
                        ? null
                        : controller.resetTransform,
                    color: Colors.white70,
                    disabledColor: Colors.white24,
                    icon: const Icon(Icons.crop_free),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}
