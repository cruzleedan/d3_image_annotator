import 'package:d3_image_annotator/d3_image_annotator.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // `enabled` is separate from `onPressed` because the helper's own
  // `onPressed ?? () {}` default would otherwise make it impossible to
  // pump a genuinely disabled button -- which is exactly what the
  // disabled-semantics test needs.
  Future<void> pumpButton(
    WidgetTester tester, {
    String label = 'Crop',
    VoidCallback? onPressed,
    bool selected = false,
    bool enabled = true,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: D3ToolButton(
              icon: Icons.crop,
              label: label,
              selected: selected,
              onPressed: enabled ? (onPressed ?? () {}) : null,
            ),
          ),
        ),
      ),
    );
  }

  group('touch target', () {
    testWidgets('is at least 48dp square', (tester) async {
      // 48dp is the floor set by Material 3 and WCAG 2.5.8 (Level AA).
      // Not a style preference: a smaller control is measurably harder
      // to hit, disproportionately so for anyone with a motor
      // impairment. This test exists so a tidier-looking icon size
      // cannot quietly break it.
      await pumpButton(tester);

      final size = tester.getSize(find.byType(D3ToolButton));
      expect(size.width, greaterThanOrEqualTo(kMinimumTouchTarget));
      expect(size.height, greaterThanOrEqualTo(kMinimumTouchTarget));
    });

    testWidgets('holds even with a one-character label', (tester) async {
      // The shortest label is where a content-sized control would
      // collapse below the minimum.
      await pumpButton(tester, label: 'X');

      final size = tester.getSize(find.byType(D3ToolButton));
      expect(size.width, greaterThanOrEqualTo(kMinimumTouchTarget));
      expect(size.height, greaterThanOrEqualTo(kMinimumTouchTarget));
    });

    testWidgets('holds when disabled', (tester) async {
      // A disabled control still occupies space, and its neighbours are
      // positioned relative to it -- shrinking it would shift them.
      await pumpButton(tester, enabled: false);

      final size = tester.getSize(find.byType(D3ToolButton));
      expect(size.height, greaterThanOrEqualTo(kMinimumTouchTarget));
    });

    testWidgets('every tool in a bar meets the minimum', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: D3ToolBar(
              children: [
                for (final label in ['Select', 'Box', 'Arrow', 'Draw'])
                  D3ToolButton(
                    icon: Icons.crop,
                    label: label,
                    onPressed: () {},
                  ),
              ],
            ),
          ),
        ),
      );

      for (final element in find.byType(D3ToolButton).evaluate()) {
        final size = element.size!;
        expect(size.height, greaterThanOrEqualTo(kMinimumTouchTarget));
        expect(size.width, greaterThanOrEqualTo(kMinimumTouchTarget));
      }
    });
  });

  group('labels', () {
    testWidgets('the caption is shown, not just the icon', (tester) async {
      // Crop, straighten, mirror and perspective icons are not
      // self-evident; the caption is what makes the bar usable without
      // having memorised them.
      await pumpButton(tester, label: 'Straighten');

      expect(find.text('Straighten'), findsOneWidget);
    });

    testWidgets('a long label is ellipsised rather than overflowing', (
      tester,
    ) async {
      // A caption that pushed its neighbours off-screen would be worse
      // than no caption.
      await pumpButton(tester, label: 'An extremely long tool name');
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });
  });

  group('semantics', () {
    testWidgets('exposes label, button role and selected state', (
      tester,
    ) async {
      // A screen reader needs the caption as the control's name, not as
      // a stray text node beside it.
      await pumpButton(tester, label: 'Rotate', selected: true);

      // Asserting the specific properties rather than matchesSemantics,
      // which is exhaustive over every flag and would make this test
      // about InkWell's focus behaviour as much as about the button's
      // own contract.
      final node = tester.getSemantics(find.byType(D3ToolButton));
      expect(node.label, 'Rotate');
      // isEnabled is a tristate (unset / true / false) whose type is
      // not public, so compare its name; the others are plain bools.
      expect(node.flagsCollection.isButton, isTrue);
      expect(node.flagsCollection.isSelected.name, 'isTrue');
      expect(node.flagsCollection.isEnabled.name, 'isTrue');
    });

    testWidgets('a disabled tool reports as disabled', (tester) async {
      await pumpButton(tester, enabled: false);

      final node = tester.getSemantics(find.byType(D3ToolButton));
      expect(node.flagsCollection.isEnabled.name, 'isFalse',
          reason: 'a disabled tool must not announce itself as tappable');
    });
  });

  group('tool groups', () {
    testWidgets('tapping a group reports it', (tester) async {
      var chosen = 'Draw';
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: D3ToolGroupBar<String>(
              groups: const {'Draw': 'Draw', 'Adjust': 'Adjust'},
              selected: chosen,
              onSelected: (g) => chosen = g,
            ),
          ),
        ),
      );

      await tester.tap(find.text('Adjust'));
      expect(chosen, 'Adjust');
    });

    testWidgets('group chips also meet the touch minimum', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: D3ToolGroupBar<String>(
              groups: const {'A': 'A', 'B': 'B'},
              selected: 'A',
              onSelected: (_) {},
            ),
          ),
        ),
      );

      for (final element in find.byType(InkWell).evaluate()) {
        expect(element.size!.height, greaterThanOrEqualTo(kMinimumTouchTarget));
      }
    });
  });
}
