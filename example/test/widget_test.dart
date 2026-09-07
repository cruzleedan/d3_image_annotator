import 'package:example/home_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('the home menu lists every demo and builds without throwing', (
    tester,
  ) async {
    await tester.pumpWidget(const AnnotatorExampleApp());
    await tester.pump();

    // A smoke test only, plus a check that the menu itself renders. Each
    // demo's own image is rasterised via PictureRecorder.toImage, which
    // does not complete under the test binding, so this deliberately
    // does not navigate into a demo and assert on its toolbar -- the
    // package's own suite covers drawing, zoom and undo properly; this
    // exists to catch a build-time regression in the example shell.
    expect(find.byType(AnnotatorExampleApp), findsOneWidget);
    expect(find.byType(ListTile), findsNWidgets(5));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'each demo screen builds and tears down without throwing',
    (tester) async {
      await tester.pumpWidget(const AnnotatorExampleApp());
      await tester.pump();

      for (final title in [
        'Full editor on a photo',
        'Blank canvas',
        'Image-as-annotation',
        'Bare viewer, custom UI',
        'Save & restore',
      ]) {
        await tester.tap(find.text(title));
        await tester.pump();
        // Long enough to let the loading spinner appear, but not to
        // wait on the demo's own image decode -- PictureRecorder.toImage
        // does not complete under this binding, which is fine: this
        // test exists to catch a build-time regression in the demo's
        // widget tree, not to exercise the fully-decoded editor.
        await tester.pump(const Duration(milliseconds: 200));
        expect(tester.takeException(), isNull,
            reason: '$title threw while building');

        // Each demo pushes its own route rather than using an AppBar
        // back button (D3AnnotatorScreen supplies its own close
        // control instead), so popping directly through the Navigator
        // exercises every demo the same way regardless of what chrome
        // it happens to show.
        final navigator = tester.state<NavigatorState>(
          find.byType(Navigator),
        );
        navigator.pop();
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull,
            reason: '$title threw while disposing');
      }
    },
  );
}
