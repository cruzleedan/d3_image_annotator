import 'package:d3_image_annotator/d3_image_annotator.dart';
import 'package:flutter/material.dart';

/// `AnnotationBackground.color` (WORK-0036): no photo at all, just a
/// plain fill to sketch on -- a whiteboard rather than markup over a
/// picture. Everything else about the editor stays the same, because
/// annotations live in the same normalized `[0,1]` space regardless of
/// what sits behind them.
///
/// A colour swatch row lets you swap the fill at runtime, which is the
/// point this demo exists to show: existing marks are unaffected by a
/// background change, since neither depends on the other.
class BlankCanvasDemo extends StatefulWidget {
  const BlankCanvasDemo({super.key});

  @override
  State<BlankCanvasDemo> createState() => _BlankCanvasDemoState();
}

class _BlankCanvasDemoState extends State<BlankCanvasDemo> {
  static const _canvasSize = Size(1000, 1400);
  static const _fills = [
    Colors.white,
    Color(0xFFFFF9C4), // legal-pad yellow
    Color(0xFF0F172A), // near-black slate, for a chalkboard feel
  ];

  final _controller = AnnotationController();
  var _fillIndex = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        D3AnnotatorScreen(
          background: AnnotationBackground.color(_fills[_fillIndex]),
          canvasSize: _canvasSize,
          controller: _controller,
          backgroundColor: Colors.black,
          onClose: () => Navigator.of(context).pop(),
          onDone: () {
            Navigator.of(context).pop();
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  '${_controller.annotations.length} annotation(s) on a '
                  'blank canvas -- no image involved at all',
                ),
              ),
            );
          },
        ),
        // A host-supplied control, floating above the package's own
        // chrome -- D3AnnotatorScreen owns no Scaffold or AppBar, so it
        // composes freely with whatever a consumer app wants alongside
        // it. Swapping the fill here does not touch _controller at all,
        // demonstrating that existing marks are independent of the
        // background they sit on.
        //
        // Positioned *below* the screen's own top bar (close/undo/redo/
        // zoom-reset/done), not overlapping it -- top: 56 clears that
        // row's ~48dp touch targets with a little breathing room.
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.only(top: 56, right: 8),
            child: Align(
              alignment: Alignment.topRight,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < _fills.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: GestureDetector(
                        onTap: () => setState(() => _fillIndex = i),
                        child: Container(
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                            color: _fills[i],
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: i == _fillIndex
                                  ? Colors.amber
                                  : Colors.white38,
                              width: i == _fillIndex ? 2.5 : 1,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
