import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:d3_image_annotator/d3_image_annotator.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

/// A solid-colour PNG of the given size, so `canvasSize` has an
/// unambiguous, non-trivial value to assert against (a 1x1 fixture
/// would not catch a width/height swap).
Future<Uint8List> _solidImage(int width, int height) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = const Color(0xFFFFFFFF),
  );
  final image = await recorder.endRecording().toImage(width, height);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

void main() {
  group('AnnotationEditingSession.fromDocument', () {
    test('decodes canvasSize from the image bytes, not the document', () async {
      final bytes = await _solidImage(300, 200);
      const document = AnnotationDocument(annotations: []);

      final session = await AnnotationEditingSession.fromDocument(
        document,
        bytes,
      );
      addTearDown(session.controller.dispose);

      expect(session.canvasSize, const Size(300, 200));
    });

    test('pre-populates the controller from the document\'s annotations', () async {
      final bytes = await _solidImage(100, 100);
      final document = AnnotationDocument(
        annotations: [
          RectangleAnnotation(
            id: 'r1',
            style: const AnnotationStyle(),
            rect: NormalizedRect(left: 0.1, top: 0.1, right: 0.5, bottom: 0.5),
          ),
        ],
      );

      final session = await AnnotationEditingSession.fromDocument(
        document,
        bytes,
      );
      addTearDown(session.controller.dispose);

      expect(session.controller.annotations, hasLength(1));
      expect(session.controller.annotations.single.id, 'r1');
    });

    test('a fresh (empty) document produces a controller with nothing in it', () async {
      final bytes = await _solidImage(50, 50);
      const document = AnnotationDocument(annotations: []);

      final session = await AnnotationEditingSession.fromDocument(
        document,
        bytes,
      );
      addTearDown(session.controller.dispose);

      expect(session.controller.annotations, isEmpty);
    });

    test('binding is ok when the document has no recorded sourceImageSize', () async {
      final bytes = await _solidImage(80, 60);
      const document = AnnotationDocument(annotations: []);

      final session = await AnnotationEditingSession.fromDocument(
        document,
        bytes,
      );
      addTearDown(session.controller.dispose);

      expect(session.binding, AnnotationBinding.ok);
    });

    test('binding is ok when the decoded size matches the recorded hint', () async {
      final bytes = await _solidImage(80, 60);
      const document = AnnotationDocument(
        annotations: [],
        sourceImageSize: Size(80, 60),
      );

      final session = await AnnotationEditingSession.fromDocument(
        document,
        bytes,
      );
      addTearDown(session.controller.dispose);

      expect(session.binding, AnnotationBinding.ok);
    });

    test('binding is sizeMismatch when the decoded size differs from the '
        'recorded hint', () async {
      final bytes = await _solidImage(80, 60);
      const document = AnnotationDocument(
        annotations: [],
        sourceImageSize: Size(999, 999),
      );

      final session = await AnnotationEditingSession.fromDocument(
        document,
        bytes,
      );
      addTearDown(session.controller.dispose);

      expect(session.binding, AnnotationBinding.sizeMismatch);
    });

    test('forwards initialStyle, maxUndoSteps, and imageCache to the '
        'constructed controller', () async {
      final bytes = await _solidImage(40, 40);
      const document = AnnotationDocument(annotations: []);
      const style = AnnotationStyle(fontSize: 0.09);
      final cache = ImageAnnotationCache(resolver: (ref) async => bytes);
      addTearDown(cache.dispose);

      final session = await AnnotationEditingSession.fromDocument(
        document,
        bytes,
        initialStyle: style,
        maxUndoSteps: 7,
        imageCache: cache,
      );
      addTearDown(session.controller.dispose);

      expect(session.controller.style, style);
      expect(session.controller.imageCache, same(cache));
    });
  });
}
