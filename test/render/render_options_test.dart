import 'package:d3_image_annotator/d3_image_annotator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RenderOptions.original (WORK-0038)', () {
    test('is equivalent to RenderOptions(maxDimension: null)', () {
      expect(
        RenderOptions.original,
        const RenderOptions(maxDimension: null),
      );
    });

    test('has an unbounded maxDimension', () {
      expect(RenderOptions.original.maxDimension, isNull);
    });

    test('keeps the default format', () {
      expect(RenderOptions.original.format, RenderFormat.png);
    });
  });
}
