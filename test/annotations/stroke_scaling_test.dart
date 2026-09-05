import 'dart:ui' as ui;

import 'package:d3_image_annotator/d3_image_annotator.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records the stroke widths a painter actually uses, so the scaling
/// rule can be asserted on real output rather than on a proxy.
class _StrokeRecorder implements Canvas {
  final widths = <double>[];

  @override
  void drawRect(Rect rect, Paint paint) => widths.add(paint.strokeWidth);

  @override
  void noSuchMethod(Invocation invocation) {}
}

void main() {
  final annotation = RectangleAnnotation(
    id: 'r',
    style: const AnnotationStyle(strokeWidth: 0.01),
    rect: NormalizedRect(left: 0.3, top: 0.3, right: 0.7, bottom: 0.7),
  );

  double strokeFor(ImageTransform transform, Rect contentRect) {
    final canvas = _StrokeRecorder();
    paintAnnotations(
      canvas as ui.Canvas,
      contentRect,
      [annotation],
      transform: transform,
    );
    return canvas.widths.single;
  }

  test('cropping magnifies the stroke to match the magnified content', () {
    // A 500x1000 image in a 1000x1000 viewport occupies 500x1000. Crop
    // to the middle half and the 250x500 result is scaled back up to
    // 500x1000 by `contain` -- the visible rect is unchanged but the
    // content is 2x magnified.
    //
    // If stroke were measured against that rect it would stay the same
    // pixel width and the mark would look thinner against the feature
    // it marks. It has to track the magnification instead.
    const rect = Rect.fromLTWH(0, 0, 500, 1000);

    final uncropped = strokeFor(ImageTransform.identity, rect);
    final cropped = strokeFor(
      ImageTransform(
        cropRect: NormalizedRect(
          left: 0.25,
          top: 0.25,
          right: 0.75,
          bottom: 0.75,
        ),
      ),
      rect,
    );

    expect(cropped, closeTo(uncropped * 2, 1e-6),
        reason: 'a half-extent crop doubles the magnification');
  });

  test('an uncropped transform leaves the stroke alone', () {
    const rect = Rect.fromLTWH(0, 0, 500, 1000);

    expect(
      strokeFor(const ImageTransform(quarterTurns: 1), rect),
      closeTo(strokeFor(ImageTransform.identity, rect), 1e-9),
      reason: 'rotation does not magnify content',
    );
  });

  test('stroke still scales with the canvas, as it must for export', () {
    // The original guarantee: the same annotation rendered onto a
    // larger canvas gets a proportionally heavier stroke, so a preview
    // and a full-resolution export look the same.
    final small = strokeFor(
      ImageTransform.identity,
      const Rect.fromLTWH(0, 0, 500, 1000),
    );
    final large = strokeFor(
      ImageTransform.identity,
      const Rect.fromLTWH(0, 0, 2000, 4000),
    );

    expect(large, closeTo(small * 4, 1e-6));
  });
}
