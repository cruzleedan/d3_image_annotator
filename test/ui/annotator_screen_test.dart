import 'dart:typed_data';

import 'package:d3_image_annotator/d3_image_annotator.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final _png = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

void main() {
  Future<AnnotationController> pumpScreen(
    WidgetTester tester, {
    VoidCallback? onClose,
    VoidCallback? onDone,
  }) async {
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final controller = AnnotationController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: D3AnnotatorScreen(
          image: MemoryImage(_png),
          imageSize: const Size(600, 800),
          controller: controller,
          onClose: onClose,
          onDone: onDone,
        ),
      ),
    );
    await tester.pump();
    return controller;
  }

  group('the screen owns its chrome', () {
    testWidgets('shows close, history and tools without host wiring', (
      tester,
    ) async {
      // The point of this widget: a consuming app supplies an image and
      // gets a working editor, rather than reassembling a toolbar and
      // re-deriving which controls belong where.
      await pumpScreen(tester);

      expect(find.byIcon(Icons.close), findsOneWidget);
      expect(find.byIcon(Icons.undo), findsOneWidget);
      expect(find.byIcon(Icons.redo), findsOneWidget);
      // No 'Select' tool (WORK-0032): tapping any existing annotation
      // selects it regardless of which drawing tool is active, so there
      // is no dedicated mode to switch into.
      expect(find.text('Select'), findsNothing);
      expect(find.text('Draw'), findsWidgets);
      expect(find.text('Adjust'), findsOneWidget);
    });

    testWidgets('owns no Scaffold or AppBar, so a host keeps its own', (
      tester,
    ) async {
      // Chrome the package should not impose: an annotator embedded in a
      // host app has to fit that app's page structure, dialog or sheet.
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => D3AnnotatorScreen(
              image: MemoryImage(_png),
              imageSize: const Size(600, 800),
              controller: AnnotationController(),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(AppBar), findsNothing);
    });
  });

  group('actions', () {
    testWidgets('close reports to the host', (tester) async {
      var closed = false;
      await pumpScreen(tester, onClose: () => closed = true);

      await tester.tap(find.byIcon(Icons.close));
      await tester.pump();

      expect(closed, isTrue);
    });

    testWidgets('the done action is hidden unless a handler is given', (
      tester,
    ) async {
      // Annotations live on the controller either way, so a host that
      // watches it directly needs no button.
      await pumpScreen(tester);
      expect(find.text('Done'), findsNothing);

      await pumpScreen(tester, onDone: () {});
      expect(find.text('Done'), findsOneWidget);
    });

    testWidgets('undo in the top bar reaches the controller', (tester) async {
      final controller = await pumpScreen(tester);

      controller.add(
        RectangleAnnotation(
          id: 'a',
          style: const AnnotationStyle(),
          rect: NormalizedRect(left: 0.2, top: 0.2, right: 0.6, bottom: 0.6),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.undo));
      await tester.pumpAndSettle();

      expect(controller.annotations, isEmpty);
    });
  });

  group('tool groups', () {
    testWidgets('switching to Adjust swaps the tool row', (tester) async {
      await pumpScreen(tester);

      expect(find.text('Circle'), findsOneWidget);
      expect(find.text('Rotate'), findsNothing);

      await tester.tap(find.text('Adjust'));
      await tester.pumpAndSettle();

      expect(find.text('Rotate'), findsOneWidget);
      expect(find.text('Circle'), findsNothing);
    });

    testWidgets('history stays reachable in every group', (tester) async {
      // The reason undo is not itself a group: a mistake must be
      // fixable without first navigating somewhere else.
      await pumpScreen(tester);

      await tester.tap(find.text('Adjust'));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.undo), findsOneWidget);
      expect(find.byIcon(Icons.close), findsOneWidget);
    });
  });

  group('crop mode', () {
    testWidgets('entering crop swaps the bars for confirm/cancel', (
      tester,
    ) async {
      await pumpScreen(tester);
      await tester.tap(find.text('Adjust'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Crop'));
      await tester.pumpAndSettle();

      expect(find.text('Apply crop'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
      expect(find.text('Select'), findsNothing);
    });

    testWidgets('cancelling a crop applies nothing', (tester) async {
      final controller = await pumpScreen(tester);
      await tester.tap(find.text('Adjust'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Crop'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(controller.transform.cropRect, isNull);
      // Back to the tool row -- and to the group the user was in when
      // they entered crop, not reset to Draw.
      expect(find.text('Rotate'), findsOneWidget);
      expect(find.text('Apply crop'), findsNothing);
    });
  });

  group('controls stay legible over the image', () {
    testWidgets('the image is clipped so it cannot paint over the bars', (
      tester,
    ) async {
      // Zooming scales the image past its box. Without a clip it paints
      // over the bars above and below, and white controls vanish against
      // a zoomed white photo -- reported on-device.
      await pumpScreen(tester);

      final clip = find.ancestor(
        of: find.byType(D3ImageAnnotator),
        matching: find.byType(ClipRect),
      );
      expect(clip, findsWidgets);
    });

    testWidgets('the bars carry their own opaque background', (tester) async {
      // Clipping alone is not enough: backgroundColor is a consumer
      // setting that could be light, so contrast has to be a property
      // of the controls rather than of whatever is behind them.
      await pumpScreen(tester);

      final surfaces = tester
          .widgetList<ColoredBox>(
            find.ancestor(
              of: find.byIcon(Icons.close),
              matching: find.byType(ColoredBox),
            ),
          )
          .toList();

      expect(surfaces, isNotEmpty,
          reason: 'the top bar needs a surface of its own');
      expect(
        surfaces.any((box) => box.color.a > 0.8),
        isTrue,
        reason: 'that surface must be near-opaque to guarantee contrast',
      );
    });

    testWidgets('the tool bar carries one too', (tester) async {
      await pumpScreen(tester);

      // 'Box' (rectangle) anchors the search -- any tool label works
      // equally, since D3ToolBar wraps every button in one shared Row,
      // but 'Select' no longer exists as a tool (WORK-0032).
      final surfaces = tester
          .widgetList<ColoredBox>(
            find.ancestor(
              of: find.text('Box'),
              matching: find.byType(ColoredBox),
            ),
          )
          .toList();

      expect(surfaces.any((box) => box.color.a > 0.8), isTrue);
    });
  });
}
