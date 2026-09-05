import 'package:example/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('the demo builds without throwing', (tester) async {
    await tester.pumpWidget(const AnnotatorExampleApp());
    await tester.pump();

    // A smoke test only. The demo's image is rasterised via
    // PictureRecorder.toImage, which does not complete under the test
    // binding, so the toolbar never renders here -- asserting on it
    // would be asserting on something this test cannot actually reach.
    // The package's own suite covers drawing, zoom and undo properly;
    // this exists to catch a build-time regression in the example.
    expect(find.byType(AnnotatorExampleApp), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
