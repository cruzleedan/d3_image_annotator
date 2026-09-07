import 'dart:convert';
import 'dart:typed_data';

import 'package:d3_image_annotator/d3_image_annotator.dart';
import 'package:flutter/material.dart';

import '../test_image.dart';

/// The package's usual entry point: `D3AnnotatorScreen` over a real
/// photo, with every drawing tool available -- rectangle, circle,
/// arrow, freehand, and text.
///
/// This is the "just give me the whole editor" path: the screen owns
/// its own toolbars, history controls and close affordance, so this
/// demo only supplies the image and decides what to do with the result.
class FullEditorDemo extends StatefulWidget {
  const FullEditorDemo({super.key});

  @override
  State<FullEditorDemo> createState() => _FullEditorDemoState();
}

class _FullEditorDemoState extends State<FullEditorDemo> {
  final _controller = AnnotationController();
  Uint8List? _bytes;

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

  /// Two outputs, and the difference is the point of the design.
  ///
  /// The annotations are saved as JSON -- editable forever, re-openable
  /// against the same photo months later. The flattened PNG is produced
  /// only now, for something that cannot carry data: a report, an
  /// attachment. The original is untouched either way.
  Future<void> _save(Uint8List source) async {
    final document = AnnotationDocument(
      annotations: _controller.annotations,
      sourceImageSize: testImageSize,
    );
    final json = jsonEncode(document.toJson());

    final rendered = await renderAnnotatedImage(
      imageBytes: source,
      annotations: _controller.annotations,
      transform: _controller.transform,
    );

    if (!mounted) return;
    Navigator.of(context).pop();
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

    return D3AnnotatorScreen(
      background: AnnotationBackground.image(MemoryImage(bytes)),
      canvasSize: testImageSize,
      controller: _controller,
      onClose: () => Navigator.of(context).pop(),
      onDone: () => _save(bytes),
    );
  }
}
