import 'dart:typed_data';

import 'package:d3_image_annotator/d3_image_annotator.dart';
import 'package:flutter/material.dart';

import '../test_image.dart';

/// `D3ImageAnnotator` is the bare viewer with none of `D3AnnotatorScreen`'s
/// chrome -- this demo builds its own `Scaffold`, `AppBar`, and tool
/// row from the individually-exported controls
/// (`D3ToolButton`/`D3ToolBar`/`D3HistoryBar`/`D3CloseButton`), showing
/// what a host app reaches for when it wants the editor to look like
/// its own app rather than the package's.
class BareViewerDemo extends StatefulWidget {
  const BareViewerDemo({super.key});

  @override
  State<BareViewerDemo> createState() => _BareViewerDemoState();
}

class _BareViewerDemoState extends State<BareViewerDemo> {
  final _controller = AnnotationController();
  Uint8List? _bytes;
  var _tool = AnnotationTool.rectangle;

  @override
  void initState() {
    super.initState();
    buildTestImage().then((b) {
      if (mounted) setState(() => _bytes = b);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Custom toolbar, bare viewer'),
        actions: [D3HistoryBar(controller: _controller)],
      ),
      // A plain page background, not the package's own -- the whole
      // point of composing at this level is that the surrounding chrome
      // is ordinary app UI, indistinguishable from any other screen.
      body: bytes == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Expanded(
                  child: ClipRect(
                    child: D3ImageAnnotator(
                      background: AnnotationBackground.image(
                        MemoryImage(bytes),
                      ),
                      canvasSize: testImageSize,
                      controller: _controller,
                      tool: _tool,
                    ),
                  ),
                ),
                SafeArea(
                  top: false,
                  child: D3ToolBar(
                    children: [
                      for (final entry in const {
                        AnnotationTool.rectangle: ('Box', Icons.crop_square),
                        AnnotationTool.circle: ('Circle', Icons.circle_outlined),
                        AnnotationTool.arrow: ('Arrow', Icons.north_east),
                        AnnotationTool.freehand: ('Draw', Icons.edit),
                        AnnotationTool.text: ('Text', Icons.text_fields),
                      }.entries)
                        D3ToolButton(
                          icon: entry.value.$2,
                          label: entry.value.$1,
                          selected: _tool == entry.key,
                          onPressed: () => setState(() => _tool = entry.key),
                        ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}
