import 'dart:typed_data';

import 'package:d3_image_annotator/d3_image_annotator.dart';
import 'package:flutter/material.dart';

import '../test_image.dart';

/// `ImageAnnotation` (WORK-0037): a second image placed *as an
/// annotation* on top of the canvas -- movable, resizable by corner
/// drag, with its own independent crop/mirror, distinct from the
/// document-level Adjust toolbar.
///
/// The package never interprets `ImageAnnotation.reference` itself --
/// resolving a reference to bytes is entirely the host app's job, via
/// an `ImageReferenceResolver`. This demo's "storage" is a single
/// in-memory map, standing in for whatever a real app would use
/// (filesystem, database blob, asset bundle, network).
class ImageAnnotationDemo extends StatefulWidget {
  const ImageAnnotationDemo({super.key});

  @override
  State<ImageAnnotationDemo> createState() => _ImageAnnotationDemoState();
}

class _ImageAnnotationDemoState extends State<ImageAnnotationDemo> {
  static const _stampReference = 'demo-stamp';

  late final ImageAnnotationCache _imageCache;
  late final AnnotationController _controller;
  Uint8List? _pageBytes;
  var _stampCount = 0;

  @override
  void initState() {
    super.initState();

    // Stands in for a real resolver -- reading a file, querying a
    // database, fetching a network image. The cache decodes off the
    // synchronous paint path and notifies the painter when done, so the
    // annotation appears the moment decoding finishes rather than
    // blocking the gesture that placed it.
    final stampBytesFuture = buildStampImage();
    _imageCache = ImageAnnotationCache(
      resolver: (reference) => stampBytesFuture,
    );
    _controller = AnnotationController(imageCache: _imageCache);

    buildTestImage().then((b) {
      if (mounted) setState(() => _pageBytes = b);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _imageCache.dispose();
    super.dispose();
  }

  void _placeStamp() {
    _stampCount++;
    final id = 'stamp_$_stampCount';
    // Each stamp gets its own id but the same reference -- the cache
    // decodes the underlying bytes once and every annotation sharing
    // that reference reuses the same decoded ui.Image.
    _controller.add(
      ImageAnnotation(
        id: id,
        style: const AnnotationStyle(),
        reference: _stampReference,
        rect: NormalizedRect(
          left: 0.3,
          top: 0.3 + (_stampCount - 1) * 0.05,
          right: 0.55,
          bottom: 0.45 + (_stampCount - 1) * 0.05,
        ),
      ),
    );
    _controller.select(id);
  }

  @override
  Widget build(BuildContext context) {
    final pageBytes = _pageBytes;
    if (pageBytes == null) {
      return const ColoredBox(
        color: Colors.black,
        child: Center(child: CircularProgressIndicator()),
      );
    }

    return Stack(
      children: [
        D3AnnotatorScreen(
          background: AnnotationBackground.image(MemoryImage(pageBytes)),
          canvasSize: testImageSize,
          controller: _controller,
          onClose: () => Navigator.of(context).pop(),
        ),
        // Positioned below D3AnnotatorScreen's own top bar rather than
        // using a Scaffold FAB slot -- the screen deliberately owns no
        // Scaffold, and the bottom of the layout is already the
        // package's own toolbar/restyle-bar rows, which a bottom-corner
        // FAB would sit awkwardly on top of.
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.only(top: 72, right: 16),
            child: Align(
              alignment: Alignment.topRight,
              child: FloatingActionButton.extended(
                onPressed: _placeStamp,
                icon: const Icon(Icons.add_photo_alternate),
                label: const Text('Place stamp'),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
