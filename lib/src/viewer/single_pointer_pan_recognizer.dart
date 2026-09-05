import 'package:flutter/gestures.dart';

/// A pan recognizer that yields as soon as a second finger joins.
///
/// Drawing needs one finger; zooming needs two. `InteractiveViewer` has
/// no way to restrict its own panning to two fingers -- `panEnabled`
/// uses single-finger drag, which is exactly the finger the drawing
/// layer wants (flutter/flutter#94541, #140058). A plain
/// `GestureDetector` over an `InteractiveViewer` therefore swallows the
/// pinch: it wins the arena on the first pointer and never lets go.
///
/// This recognizer flips its own arena disposition from `accepted` to
/// `rejected` the moment it is tracking more than one pointer, so the
/// gesture bubbles up to `InteractiveViewer` and becomes a scale. One
/// finger still draws, two fingers still zoom, and the user never has to
/// think about a mode.
class SinglePointerPanGestureRecognizer extends PanGestureRecognizer {
  SinglePointerPanGestureRecognizer({super.debugOwner});

  final Set<int> _pointers = <int>{};

  /// Once accepted for a genuine one-finger drag, stay accepted: a
  /// second finger landing mid-stroke should not abort the stroke
  /// already in progress, which would leave a half-drawn annotation.
  bool _acceptedSinglePointerDrag = false;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    _pointers.add(event.pointer);
    super.addAllowedPointer(event);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerUpEvent || event is PointerCancelEvent) {
      _pointers.remove(event.pointer);
    }
    super.handleEvent(event);
  }

  @override
  void resolve(GestureDisposition disposition) {
    if (disposition == GestureDisposition.accepted &&
        !_acceptedSinglePointerDrag &&
        _pointers.length > 1) {
      // Two fingers down before this drag was claimed: this is a pinch,
      // not a stroke. Step out of the arena and let the viewer have it.
      super.resolve(GestureDisposition.rejected);
      return;
    }
    if (disposition == GestureDisposition.accepted) {
      _acceptedSinglePointerDrag = true;
    }
    super.resolve(disposition);
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    _pointers.clear();
    _acceptedSinglePointerDrag = false;
    super.didStopTrackingLastPointer(pointer);
  }

  @override
  String get debugDescription => 'single-pointer pan';
}
