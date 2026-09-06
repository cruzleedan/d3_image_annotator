import 'dart:convert';
import 'dart:ui' as ui;

import 'package:d3_image_annotator/d3_image_annotator.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Measures WORK-0023's three named costs -- paint, hit-test,
/// serialization -- for a realistic dense-markup worst case on device.
///
/// **A load-bearing correction to WORK-0023's own problem statement,
/// found while reading the code before writing this benchmark:** the
/// item assumes raw 120Hz pointer sampling ("~240 points" for a
/// two-second stroke) with no filtering, and its Options considered
/// explicitly rejects "throttle sampling during drawing" as an option.
/// But `annotation_overlay_widget.dart` already applies a minimum-step
/// filter during drawing (`_freehandMinStep = 0.002` normalized units,
/// present since the annotator's first commit, predating this item).
/// So today's actual worst case is bounded by that filter, not by
/// touch-sampling rate -- a stroke's point count is capped by how far
/// it travels in normalized space divided by 0.002, not by how long the
/// user's finger is down. This benchmark generates strokes the same way
/// the real filter would: points are kept only when they clear the
/// minimum step, exactly like a real drag would produce.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const minStep = 0.002; // Mirrors _freehandMinStep in the overlay widget.

  /// A winding stroke covering a lot of *path length* within normalized
  /// [0,1] space, respecting the same minimum-step filter the real
  /// overlay applies. This is what "the user scribbles back and forth
  /// for a while" produces -- not a straight line, which would hit the
  /// space's diagonal bound almost immediately.
  ///
  /// Direction reflects off the [0,1] boundary rather than clamping:
  /// clamping can pin a point at an edge with zero forward progress
  /// (an early version of this generator hung on exactly that -- two
  /// clamped coordinates producing the same point every iteration,
  /// never clearing the minimum-step distance check, forever). A
  /// reflected bounce guarantees every step moves.
  List<NormalizedPoint> windingStroke({
    required int targetPointCount,
    required int seed,
  }) {
    final step = minStep * 1.5; // Comfortably clears the filter each time.
    var x = 0.5, y = 0.5;
    // A slowly turning heading, not pure noise -- noise cancels out and
    // the stroke would barely travel; a gentle turn actually winds.
    var heading = seed * 0.7;
    final points = <NormalizedPoint>[NormalizedPoint(x, y)];
    var iterations = 0;
    // A hard safety cap, not a tuning knob: if the walk logic has a bug
    // that stalls progress, this turns a silent hang into a fast,
    // legible test failure instead. Ten iterations per point needed is
    // generous headroom above the expected one-iteration-per-point case.
    final iterationCap = targetPointCount * 10;

    while (points.length < targetPointCount) {
      iterations++;
      if (iterations > iterationCap) {
        throw StateError(
          'windingStroke stalled: only ${points.length}/$targetPointCount '
          'points after $iterations iterations -- generator bug, not a '
          'slow device',
        );
      }
      heading += 0.35;
      var dx = step * (heading % (2 * 3.14159) - 3.14159).clamp(-1.0, 1.0);
      var dy = step * ((heading * 1.3) % (2 * 3.14159) - 3.14159).clamp(-1.0, 1.0);

      var nx = x + dx;
      var ny = y + dy;
      // Reflect off each edge independently: still moves, never stalls.
      if (nx < 0.0) nx = -nx;
      if (nx > 1.0) nx = 2.0 - nx;
      if (ny < 0.0) ny = -ny;
      if (ny > 1.0) ny = 2.0 - ny;
      nx = nx.clamp(0.0, 1.0);
      ny = ny.clamp(0.0, 1.0);

      final dist2 = (nx - x) * (nx - x) + (ny - y) * (ny - y);
      if (dist2 < minStep * minStep) {
        // Reflection landed too close (can happen right at a corner) --
        // force a diagonal nudge toward centre, which always clears the
        // filter and always makes progress.
        nx = (x + (x < 0.5 ? step : -step)).clamp(0.0, 1.0);
        ny = (y + (y < 0.5 ? step : -step)).clamp(0.0, 1.0);
      }

      points.add(NormalizedPoint(nx, ny));
      x = nx;
      y = ny;
    }
    return points;
  }

  /// A dense markup page: several long freehand strokes plus a scatter
  /// of the other shape types, which is closer to what a real
  /// inspection photo's markup looks like than freehand alone.
  List<Annotation> denseMarkupPage({
    required int strokeCount,
    required int pointsPerStroke,
  }) {
    final annotations = <Annotation>[];
    for (var s = 0; s < strokeCount; s++) {
      annotations.add(
        FreehandAnnotation(
          id: 'stroke-$s',
          style: const AnnotationStyle(color: Color(0xFFFF3B30)),
          points: windingStroke(targetPointCount: pointsPerStroke, seed: s + 1),
        ),
      );
    }
    for (var i = 0; i < 15; i++) {
      annotations.add(
        RectangleAnnotation(
          id: 'rect-$i',
          style: const AnnotationStyle(color: Color(0xFF34C759)),
          rect: NormalizedRect(
            left: (i * 0.06) % 0.8,
            top: (i * 0.05) % 0.8,
            right: ((i * 0.06) % 0.8) + 0.1,
            bottom: ((i * 0.05) % 0.8) + 0.1,
          ),
        ),
      );
    }
    return annotations;
  }

  testWidgets('worst case: paint, hit-test, and serialization cost', (
    tester,
  ) async {
    // "A page of markup could reach several thousand [points]" -- the
    // problem statement's own figure. 20 strokes x 400 points is 8000,
    // comfortably past that, from a plausible number of strokes for one
    // annotated photo (20 is already a very heavily marked-up image).
    const strokeCount = 20;
    const pointsPerStroke = 400;
    final annotations = denseMarkupPage(
      strokeCount: strokeCount,
      pointsPerStroke: pointsPerStroke,
    );
    final totalPoints = annotations
        .whereType<FreehandAnnotation>()
        .fold<int>(0, (sum, a) => sum + a.points.length);

    // --- Paint cost: one full repaint, the cost paid every frame the
    // overlay is visible while annotations exist on screen. ---
    const contentRect = Rect.fromLTWH(0, 0, 1200, 1600);
    final paintWatch = Stopwatch()..start();
    const paintIterations = 30; // Approximates half a second at 60fps.
    for (var i = 0; i < paintIterations; i++) {
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      paintAnnotations(canvas, contentRect, annotations);
      recorder.endRecording().dispose();
    }
    paintWatch.stop();
    final avgPaintMs = paintWatch.elapsedMilliseconds / paintIterations;

    // --- Hit-test cost: one tap, the cost paid whenever the user taps
    // to select something on a heavily marked-up image. ---
    final hitTestWatch = Stopwatch()..start();
    const hitTestIterations = 100;
    for (var i = 0; i < hitTestIterations; i++) {
      hitTestAnnotations(
        annotations,
        const NormalizedPoint(0.9, 0.9), // A miss: the true worst case,
        // since a hit returns early but a miss walks every annotation.
        contentRect,
      );
    }
    hitTestWatch.stop();
    final avgHitTestUs =
        hitTestWatch.elapsedMicroseconds / hitTestIterations;

    // --- Serialized size: the cost WORK-0022 flagged as relevant once
    // annotations are persisted -- shipped since as WORK-0029. ---
    final document = AnnotationDocument(annotations: annotations);
    final jsonString = jsonEncode(document.toJson());
    final jsonBytes = utf8.encode(jsonString).length;

    // ignore: avoid_print
    print('FREEHAND_WORST_CASE '
        'strokes=$strokeCount points_per_stroke=$pointsPerStroke '
        'total_freehand_points=$totalPoints '
        'avg_paint_ms=${avgPaintMs.toStringAsFixed(2)} '
        'avg_hittest_us=${avgHitTestUs.toStringAsFixed(1)} '
        'json_bytes=$jsonBytes '
        'json_kb=${(jsonBytes / 1024).toStringAsFixed(1)}');

    expect(totalPoints, greaterThan(2000),
        reason: 'the benchmark itself must exceed the "several thousand" '
            'figure from the problem statement to be a genuine worst case');
  });

  testWidgets('an extreme case: 5x the worst-case point count', (
    tester,
  ) async {
    // Checks for a nonlinearity that would not show at the primary
    // worst case's scale -- if cost were, say, quadratic in point
    // count, 5x the points would cost 25x, not 5x.
    const strokeCount = 20;
    const pointsPerStroke = 2000;
    final annotations = denseMarkupPage(
      strokeCount: strokeCount,
      pointsPerStroke: pointsPerStroke,
    );
    final totalPoints = annotations
        .whereType<FreehandAnnotation>()
        .fold<int>(0, (sum, a) => sum + a.points.length);

    const contentRect = Rect.fromLTWH(0, 0, 1200, 1600);
    final paintWatch = Stopwatch()..start();
    const paintIterations = 30;
    for (var i = 0; i < paintIterations; i++) {
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      paintAnnotations(canvas, contentRect, annotations);
      recorder.endRecording().dispose();
    }
    paintWatch.stop();

    final hitTestWatch = Stopwatch()..start();
    const hitTestIterations = 100;
    for (var i = 0; i < hitTestIterations; i++) {
      hitTestAnnotations(
        annotations,
        const NormalizedPoint(0.9, 0.9),
        contentRect,
      );
    }
    hitTestWatch.stop();

    // ignore: avoid_print
    print('FREEHAND_5X total_freehand_points=$totalPoints '
        'avg_paint_ms=${(paintWatch.elapsedMilliseconds / paintIterations).toStringAsFixed(2)} '
        'avg_hittest_us=${(hitTestWatch.elapsedMicroseconds / hitTestIterations).toStringAsFixed(1)}');
  });

  testWidgets('control: frame cost with zero annotations', (tester) async {
    // Isolates tester.pump's own fixed overhead from the painter's
    // actual cost -- without this, a frame time above 16.7ms could be
    // wrongly blamed on paintAnnotations when it might just be the test
    // harness's baseline.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CustomPaint(
            size: const Size(1200, 1600),
            painter: const _AnnotationsPainter([]),
          ),
        ),
      ),
    );

    final gaps = <int>[];
    var last = Stopwatch()..start();
    void onFrame(Duration _) {
      gaps.add(last.elapsedMicroseconds);
      last = Stopwatch()..start();
      WidgetsBinding.instance.addPostFrameCallback(onFrame);
    }

    WidgetsBinding.instance.addPostFrameCallback(onFrame);
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    final avg = gaps.isEmpty ? 0 : gaps.reduce((a, b) => a + b) / gaps.length;
    int worst(List<int> xs) =>
        xs.isEmpty ? 0 : xs.reduce((a, b) => a > b ? a : b);

    // ignore: avoid_print
    print('FREEHAND_CONTROL_EMPTY worst_frame_us=${worst(gaps)} '
        'avg_frame_us=${avg.toStringAsFixed(0)} frames=${gaps.length}');
  });

  testWidgets('does paint cost stay smooth across repeated frames?', (
    tester,
  ) async {
    // The frame-timing version of the same question: does a dense page
    // of markup visibly jank a real widget tree repainting it, not just
    // cost time in an isolated loop.
    const strokeCount = 20;
    const pointsPerStroke = 400;
    final annotations = denseMarkupPage(
      strokeCount: strokeCount,
      pointsPerStroke: pointsPerStroke,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CustomPaint(
            size: const Size(1200, 1600),
            painter: _AnnotationsPainter(annotations),
          ),
        ),
      ),
    );

    final gaps = <int>[];
    var last = Stopwatch()..start();
    void onFrame(Duration _) {
      gaps.add(last.elapsedMicroseconds);
      last = Stopwatch()..start();
      WidgetsBinding.instance.addPostFrameCallback(onFrame);
    }

    WidgetsBinding.instance.addPostFrameCallback(onFrame);
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    int worst(List<int> xs) =>
        xs.isEmpty ? 0 : xs.reduce((a, b) => a > b ? a : b);
    final avg = gaps.isEmpty
        ? 0
        : gaps.reduce((a, b) => a + b) / gaps.length;

    // ignore: avoid_print
    print('FREEHAND_REPAINT_JANK worst_frame_us=${worst(gaps)} '
        'avg_frame_us=${avg.toStringAsFixed(0)} frames=${gaps.length}');
  });
}

class _AnnotationsPainter extends CustomPainter {
  const _AnnotationsPainter(this.annotations);

  final List<Annotation> annotations;

  @override
  void paint(Canvas canvas, Size size) {
    paintAnnotations(canvas, Offset.zero & size, annotations);
  }

  @override
  bool shouldRepaint(covariant _AnnotationsPainter oldDelegate) => true;
}
