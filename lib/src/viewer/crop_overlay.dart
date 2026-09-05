import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../coordinates/normalized_rect.dart';

/// Which part of the crop frame a drag is manipulating.
enum _CropGrip { topLeft, topRight, bottomLeft, bottomRight, body, none }

/// An interactive crop frame: four corner handles, a draggable interior,
/// and a dimmed surround, in the style of the Pixel and iOS photo
/// editors.
///
/// Crop is a **mode**, not a tool. While this is up the user is
/// adjusting the frame rather than drawing, so it takes every pointer
/// and the annotation layer is suspended beneath it. That is also what
/// keeps it clear of the gesture-arena problem that drawing and zoom
/// ran into: there is only ever one interpretation of a drag here.
///
/// The frame is reported in normalized coordinates and nothing is
/// applied until the caller commits it, so cancelling costs nothing and
/// the underlying image is never touched.
class CropOverlay extends StatefulWidget {
  const CropOverlay({
    super.key,
    required this.contentRect,
    required this.initialCrop,
    required this.onChanged,
    this.handleSize = 28,
    this.minimumSize = 0.08,
  });

  /// Where the image sits inside this widget.
  final Rect contentRect;

  /// Starting frame, in normalized image coordinates.
  final NormalizedRect initialCrop;

  /// Called as the frame changes, so a host can show live dimensions or
  /// enable a confirm button.
  final ValueChanged<NormalizedRect> onChanged;

  /// Touch target for a corner, in logical pixels.
  ///
  /// A pixel size rather than a normalized one: a finger is the same
  /// size regardless of how large the image is, which is the same reason
  /// hit-test slop is expressed in pixels. Note this is the opposite
  /// rule from annotation stroke width, which scales with the image
  /// because it is part of the picture rather than part of the UI.
  final double handleSize;

  /// Smallest allowed crop, as a fraction of each axis. Stops a frame
  /// being dragged down to nothing, which would leave no image and no
  /// handles big enough to grab.
  final double minimumSize;

  @override
  State<CropOverlay> createState() => _CropOverlayState();
}

class _CropOverlayState extends State<CropOverlay> {
  late NormalizedRect _crop = widget.initialCrop;
  _CropGrip _grip = _CropGrip.none;
  Offset _lastPosition = Offset.zero;

  @override
  void didUpdateWidget(CropOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Only adopt an externally-changed crop between gestures; doing it
    // mid-drag would fight the finger.
    if (_grip == _CropGrip.none && widget.initialCrop != oldWidget.initialCrop) {
      _crop = widget.initialCrop;
    }
  }

  Rect get _frame => _crop.toRect(widget.contentRect);

  _CropGrip _gripAt(Offset position) {
    final frame = _frame;
    final slop = widget.handleSize;

    bool near(Offset corner) =>
        (position - corner).distance <= slop;

    if (near(frame.topLeft)) return _CropGrip.topLeft;
    if (near(frame.topRight)) return _CropGrip.topRight;
    if (near(frame.bottomLeft)) return _CropGrip.bottomLeft;
    if (near(frame.bottomRight)) return _CropGrip.bottomRight;
    if (frame.contains(position)) return _CropGrip.body;
    return _CropGrip.none;
  }

  void _onPanStart(DragStartDetails details) {
    _grip = _gripAt(details.localPosition);
    _lastPosition = details.localPosition;
  }

  void _onPanUpdate(DragUpdateDetails details) {
    if (_grip == _CropGrip.none) return;

    final rect = widget.contentRect;
    if (rect.width <= 0 || rect.height <= 0) return;

    // Work in normalized deltas so the frame is stored in the same space
    // it will be applied in.
    final dx = (details.localPosition.dx - _lastPosition.dx) / rect.width;
    final dy = (details.localPosition.dy - _lastPosition.dy) / rect.height;
    _lastPosition = details.localPosition;

    setState(() => _crop = _apply(dx, dy));
    widget.onChanged(_crop);
  }

  NormalizedRect _apply(double dx, double dy) {
    var left = _crop.left;
    var top = _crop.top;
    var right = _crop.right;
    var bottom = _crop.bottom;
    final min = widget.minimumSize;

    switch (_grip) {
      case _CropGrip.topLeft:
        left = (left + dx).clamp(0.0, right - min);
        top = (top + dy).clamp(0.0, bottom - min);
      case _CropGrip.topRight:
        right = (right + dx).clamp(left + min, 1.0);
        top = (top + dy).clamp(0.0, bottom - min);
      case _CropGrip.bottomLeft:
        left = (left + dx).clamp(0.0, right - min);
        bottom = (bottom + dy).clamp(top + min, 1.0);
      case _CropGrip.bottomRight:
        right = (right + dx).clamp(left + min, 1.0);
        bottom = (bottom + dy).clamp(top + min, 1.0);
      case _CropGrip.body:
        // Move the whole frame, clamped so it stays wholly on the image
        // and keeps its size -- clamping each edge independently would
        // squash it against the boundary instead.
        final width = right - left;
        final height = bottom - top;
        left = (left + dx).clamp(0.0, 1.0 - width);
        top = (top + dy).clamp(0.0, 1.0 - height);
        right = left + width;
        bottom = top + height;
      case _CropGrip.none:
        break;
    }

    return NormalizedRect(
      left: left,
      top: top,
      right: right,
      bottom: bottom,
    );
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: _onPanStart,
      onPanUpdate: _onPanUpdate,
      onPanEnd: (_) => _grip = _CropGrip.none,
      child: CustomPaint(
        painter: _CropPainter(
          frame: _frame,
          contentRect: widget.contentRect,
          handleSize: widget.handleSize,
        ),
        child: const SizedBox.expand(),
      ),
    );
  }
}

/// Weight shared by the frame border and the corner arms, so the two
/// read as one control rather than a hairline with decorations.
const double _borderWidth = 4;

class _CropPainter extends CustomPainter {
  const _CropPainter({
    required this.frame,
    required this.contentRect,
    required this.handleSize,
  });

  final Rect frame;
  final Rect contentRect;
  final double handleSize;

  @override
  void paint(Canvas canvas, Size size) {
    // Dim everything outside the frame, so what will be kept reads at a
    // glance. Drawn as a single even-odd path rather than four rects to
    // avoid seams where they would meet.
    final scrim = Path()
      ..addRect(contentRect)
      ..addRect(frame)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(scrim, Paint()..color = Colors.black54);

    // Black edges at the same weight as the corner arms, so the corners
    // read as the grabbable part while the frame still has a continuous
    // outline. This is what lets the frame open at the full image
    // without an inset: the white corners stay visible against any
    // photo because they sit on top of a black border rather than
    // needing empty space around them.
    canvas.drawRect(
      frame,
      Paint()
        ..color = Colors.black87
        ..strokeWidth = _borderWidth
        ..style = PaintingStyle.stroke,
    );

    // Rule-of-thirds guides, the convention in every photo cropper.
    final guide = Paint()
      ..color = Colors.white38
      ..strokeWidth = 1;
    for (var i = 1; i < 3; i++) {
      final x = frame.left + frame.width * i / 3;
      final y = frame.top + frame.height * i / 3;
      canvas.drawLine(Offset(x, frame.top), Offset(x, frame.bottom), guide);
      canvas.drawLine(Offset(frame.left, y), Offset(frame.right, y), guide);
    }

    _paintCorners(canvas);
  }

  void _paintCorners(Canvas canvas) {
    final paint = Paint()
      ..color = Colors.white
      ..strokeWidth = _borderWidth
      ..strokeCap = StrokeCap.square
      ..style = PaintingStyle.stroke;

    // Arm length shrinks with the frame so the corners never overlap on
    // a small crop -- at which point they would be unusable.
    final arm = math.min(
      handleSize,
      math.min(frame.width, frame.height) / 3,
    );

    // Inset by half the stroke so an arm at the image edge is drawn
    // wholly inside the frame rather than half-clipped -- which is what
    // would happen now the frame can sit flush against the boundary.
    const inset = _borderWidth / 2;

    void corner(Offset at, double dx, double dy) {
      final origin = at.translate(dx * inset, dy * inset);
      canvas.drawLine(origin, origin.translate(dx * arm, 0), paint);
      canvas.drawLine(origin, origin.translate(0, dy * arm), paint);
    }

    corner(frame.topLeft, 1, 1);
    corner(frame.topRight, -1, 1);
    corner(frame.bottomLeft, 1, -1);
    corner(frame.bottomRight, -1, -1);
  }

  @override
  bool shouldRepaint(_CropPainter oldDelegate) =>
      oldDelegate.frame != frame ||
      oldDelegate.contentRect != contentRect ||
      oldDelegate.handleSize != handleSize;
}
