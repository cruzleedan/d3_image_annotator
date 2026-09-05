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

  /// Crop is a mode: while it is on, drags adjust the frame instead of
  /// drawing, and nothing is applied until it is confirmed.
  bool _cropping = false;
  NormalizedRect? _pendingCrop;

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
                    cropping: _cropping,
                    onCropChanged: (rect) => _pendingCrop = rect,
                  ),
                ),
                if (_cropping)
                  _CropBar(
                    onCancel: () => setState(() {
                      _cropping = false;
                      _pendingCrop = null;
                    }),
                    onConfirm: () => setState(() {
                      final rect = _pendingCrop;
                      if (rect != null) _controller.crop(rect);
                      _cropping = false;
                      _pendingCrop = null;
                    }),
                  )
                else
                  _Toolbar(
                    tool: _tool,
                    controller: _controller,
                    onToolChanged: (t) => setState(() => _tool = t),
                    onStartCrop: () => setState(() {
                      _cropping = true;
                      _pendingCrop = _controller.transform.effectiveCrop;
                    }),
                  ),
              ],
            ),
    );
  }
}

/// Which set of tools the bar is showing.
///
/// Grouping keeps the row short enough to read at a glance rather than
/// making the user scan a long undifferentiated list of icons -- the
/// arrangement the Pixel camera uses.
enum _ToolGroup { draw, transform, history }

class _Toolbar extends StatefulWidget {
  const _Toolbar({
    required this.tool,
    required this.controller,
    required this.onToolChanged,
    required this.onStartCrop,
  });

  final AnnotationTool tool;
  final AnnotationController controller;
  final ValueChanged<AnnotationTool> onToolChanged;
  final VoidCallback onStartCrop;

  @override
  State<_Toolbar> createState() => _ToolbarState();
}

class _ToolbarState extends State<_Toolbar> {
  _ToolGroup _group = _ToolGroup.draw;

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              D3ToolBar(children: _toolsFor(_group)),
              D3ToolGroupBar<_ToolGroup>(
                groups: const {
                  _ToolGroup.draw: 'Draw',
                  _ToolGroup.transform: 'Adjust',
                  _ToolGroup.history: 'Edit',
                },
                selected: _group,
                onSelected: (g) => setState(() => _group = g),
              ),
            ],
          ),
        );
      },
    );
  }

  List<Widget> _toolsFor(_ToolGroup group) {
    final controller = widget.controller;
    return switch (group) {
      _ToolGroup.draw => [
        for (final t in AnnotationTool.values)
          D3ToolButton(
            icon: switch (t) {
              AnnotationTool.select => Icons.touch_app,
              AnnotationTool.rectangle => Icons.crop_square,
              AnnotationTool.circle => Icons.circle_outlined,
              AnnotationTool.arrow => Icons.arrow_outward,
              AnnotationTool.freehand => Icons.gesture,
            },
            label: switch (t) {
              AnnotationTool.select => 'Select',
              AnnotationTool.rectangle => 'Box',
              AnnotationTool.circle => 'Circle',
              AnnotationTool.arrow => 'Arrow',
              AnnotationTool.freehand => 'Draw',
            },
            selected: t == widget.tool,
            onPressed: () => widget.onToolChanged(t),
          ),
      ],
      _ToolGroup.transform => [
        D3ToolButton(
          icon: Icons.crop,
          label: 'Crop',
          selected: controller.transform.cropRect != null,
          onPressed: widget.onStartCrop,
        ),
        D3ToolButton(
          icon: Icons.rotate_90_degrees_cw,
          label: 'Rotate',
          onPressed: controller.rotateClockwise,
        ),
        D3ToolButton(
          icon: Icons.flip,
          label: 'Mirror',
          selected: controller.transform.mirrored,
          onPressed: controller.toggleMirror,
        ),
        D3ToolButton(
          icon: Icons.crop_free,
          label: 'Reset',
          onPressed: controller.transform.isIdentity
              ? null
              : controller.resetTransform,
        ),
      ],
      _ToolGroup.history => [
        D3ToolButton(
          icon: Icons.undo,
          label: 'Undo',
          onPressed: controller.canUndo ? controller.undo : null,
        ),
        D3ToolButton(
          icon: Icons.redo,
          label: 'Redo',
          onPressed: controller.canRedo ? controller.redo : null,
        ),
        // One control for both: deletes the selection when there is one,
        // otherwise clears everything, and says which by its label.
        D3ToolButton(
          icon: controller.selectedId != null
              ? Icons.delete
              : Icons.delete_outline,
          label: controller.selectedId != null ? 'Delete' : 'Clear',
          destructive: controller.selectedId != null,
          onPressed: controller.isEmpty
              ? null
              : () {
                  final id = controller.selectedId;
                  if (id != null) {
                    controller.remove(id);
                  } else {
                    controller.clear();
                  }
                },
        ),
      ],
    };
  }
}

/// Confirm / cancel for crop mode. Nothing is applied until confirmed,
/// so backing out leaves the image exactly as it was.
class _CropBar extends StatelessWidget {
  const _CropBar({required this.onCancel, required this.onConfirm});

  final VoidCallback onCancel;
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Drag the corners or the frame',
              style: TextStyle(color: Colors.white54, fontSize: 12),
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                TextButton.icon(
                  onPressed: onCancel,
                  icon: const Icon(Icons.close),
                  label: const Text('Cancel'),
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.white70,
                  ),
                ),
                TextButton.icon(
                  onPressed: onConfirm,
                  icon: const Icon(Icons.check),
                  label: const Text('Apply crop'),
                  style: TextButton.styleFrom(foregroundColor: Colors.amber),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
