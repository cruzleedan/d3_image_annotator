import 'dart:convert';
import 'dart:typed_data';

import 'package:d3_image_annotator/d3_image_annotator.dart';
import 'package:flutter/material.dart';

import '../test_image.dart';

/// Annotations are data, not pixels -- this demo makes that concrete by
/// round-tripping them through JSON into a second, independent editor
/// instance, and by showing [classifyBinding] catch a saved document
/// reopened against an image of the wrong size.
///
/// Two `D3AnnotatorScreen`s never share a controller: "Save" serializes
/// the left one's `controller.annotations` to a JSON string (shown on
/// screen, exactly as a database column or sidecar file would hold it),
/// and "Restore" decodes that same string into a brand new
/// `AnnotationController` for the right one -- proving the marks came
/// from the string, not from any in-memory reference surviving between
/// the two.
class SaveRestoreDemo extends StatefulWidget {
  const SaveRestoreDemo({super.key});

  @override
  State<SaveRestoreDemo> createState() => _SaveRestoreDemoState();
}

class _SaveRestoreDemoState extends State<SaveRestoreDemo> {
  final _sourceController = AnnotationController();
  Uint8List? _bytes;
  String? _savedJson;
  AnnotationController? _restoredController;
  AnnotationBinding? _mismatchResult;

  @override
  void initState() {
    super.initState();
    buildTestImage().then((b) {
      if (mounted) setState(() => _bytes = b);
    });
  }

  @override
  void dispose() {
    _sourceController.dispose();
    _restoredController?.dispose();
    super.dispose();
  }

  void _save() {
    final document = AnnotationDocument(
      annotations: _sourceController.annotations,
      sourceImageSize: testImageSize,
    );
    setState(() {
      _savedJson = const JsonEncoder.withIndent('  ').convert(
        document.toJson(),
      );
      _restoredController?.dispose();
      _restoredController = null;
      _mismatchResult = null;
    });
  }

  Future<void> _restore() async {
    final saved = _savedJson;
    final bytes = _bytes;
    if (saved == null || bytes == null) return;
    final document = AnnotationDocument.fromJson(
      jsonDecode(saved) as Map<String, Object?>,
    );

    // AnnotationEditingSession.fromDocument (WORK-0038) collapses what
    // used to be here as three separate manual steps -- decode the
    // image a second time purely to learn canvasSize, build a fresh
    // AnnotationController from document.annotations, and separately
    // call classifyBinding against that same decoded size -- into one
    // awaited call. It happens to already know the binding result
    // (decoding the image is exactly what classifyBinding also needs),
    // so this demo's own mismatch check below reuses that instead of
    // decoding a third time.
    final session = await AnnotationEditingSession.fromDocument(
      document,
      bytes,
    );
    if (!mounted) return;

    setState(() {
      _restoredController?.dispose();
      _restoredController = session.controller;
      _mismatchResult = session.binding;
    });
  }

  void _classifyAgainstWrongSize() {
    final saved = _savedJson;
    if (saved == null) return;
    final document = AnnotationDocument.fromJson(
      jsonDecode(saved) as Map<String, Object?>,
    );
    // A deliberately wrong size, standing in for "this document was
    // saved against one photo and is now being opened against another"
    // -- the case `classifyBinding` exists to catch before rendering an
    // empty-looking canvas that quietly lies about where the marks are.
    const wrongSize = Size(800, 600);
    setState(() {
      _mismatchResult = classifyBinding(document, wrongSize);
    });
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    return Scaffold(
      appBar: AppBar(title: const Text('Save & restore')),
      body: bytes == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      Expanded(
                        child: _EditorPane(
                          title: 'Source',
                          controller: _sourceController,
                          bytes: bytes,
                        ),
                      ),
                      const VerticalDivider(width: 1),
                      Expanded(
                        child: _restoredController == null
                            ? const _EmptyPane(
                                message: 'Restore a saved document to '
                                    'see it appear here, in a brand new '
                                    'controller',
                              )
                            : Column(
                                children: [
                                  // A worked response to classifyBinding's
                                  // result (WORK-0038), not just the raw
                                  // enum value: a mismatch is advisory,
                                  // per AnnotationBinding's own doc
                                  // comment, so this warns rather than
                                  // blocking -- the marks still render
                                  // (wherever normalized coordinates land
                                  // on an image of a different size), and
                                  // the user decides whether that's
                                  // corruption or intentional
                                  // re-association.
                                  if (_mismatchResult ==
                                      AnnotationBinding.sizeMismatch)
                                    const _BindingWarningBanner(
                                      message:
                                          'These annotations were saved '
                                          'against a differently-sized '
                                          'image. Marks may not line up '
                                          'with what you see below.',
                                    ),
                                  Expanded(
                                    child: _EditorPane(
                                      title: 'Restored',
                                      controller: _restoredController!,
                                      bytes: bytes,
                                    ),
                                  ),
                                ],
                              ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      FilledButton.icon(
                        onPressed: _save,
                        icon: const Icon(Icons.save_outlined),
                        label: const Text('Save (source → JSON)'),
                      ),
                      FilledButton.icon(
                        onPressed: _savedJson == null ? null : _restore,
                        icon: const Icon(Icons.restore_page_outlined),
                        label: const Text('Restore (JSON → new editor)'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _savedJson == null
                            ? null
                            : _classifyAgainstWrongSize,
                        icon: const Icon(Icons.warning_amber_outlined),
                        label: const Text('Classify against wrong size'),
                      ),
                      if (_mismatchResult != null)
                        Chip(label: Text('binding: ${_mismatchResult!.name}')),
                    ],
                  ),
                ),
                if (_savedJson != null)
                  Container(
                    constraints: const BoxConstraints(maxHeight: 140),
                    width: double.infinity,
                    color: Colors.black,
                    padding: const EdgeInsets.all(8),
                    child: SingleChildScrollView(
                      child: SelectableText(
                        _savedJson!,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11,
                          color: Colors.greenAccent,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}

class _EditorPane extends StatelessWidget {
  const _EditorPane({
    required this.title,
    required this.controller,
    required this.bytes,
  });

  final String title;
  final AnnotationController controller;
  final Uint8List bytes;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Text(title, style: Theme.of(context).textTheme.titleSmall),
        ),
        Expanded(
          child: ClipRect(
            child: D3ImageAnnotator(
              background: AnnotationBackground.image(MemoryImage(bytes)),
              canvasSize: testImageSize,
              controller: controller,
            ),
          ),
        ),
      ],
    );
  }
}

class _EmptyPane extends StatelessWidget {
  const _EmptyPane({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ),
    );
  }
}

/// One worked response to [AnnotationBinding.sizeMismatch] (WORK-0038):
/// a warning banner, not a block. `classifyBinding` is advisory by
/// design -- nothing in `d3_image_annotator` itself decides whether a
/// mismatch is corruption or a deliberate re-association, so this demo
/// picks one reasonable answer (warn, then still render) rather than
/// leaving every consumer to invent a response from the enum alone.
class _BindingWarningBanner extends StatelessWidget {
  const _BindingWarningBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: Colors.amber.shade900,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          const Icon(Icons.warning_amber, size: 18, color: Colors.white),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(color: Colors.white, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}
