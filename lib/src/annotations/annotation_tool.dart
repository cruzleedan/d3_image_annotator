/// What a drag on the annotation overlay does when it does not start on
/// an existing annotation.
///
/// Kept separate from `AnnotationController` because it is view state,
/// not document state: switching tools does not change the annotations
/// and must not land on the undo stack.
///
/// There is no `select` value (WORK-0032). Tapping or dragging from an
/// existing annotation always selects/moves it first, regardless of
/// which value is active here -- selection is not a mode the user
/// switches into, it is what a tap on a shape does everywhere. This
/// enum is only consulted when a gesture starts on empty space.
enum AnnotationTool {
  /// Drag corner-to-corner to create a rectangle.
  rectangle,

  /// Drag corner-to-corner to create an ellipse inscribed in the drag.
  circle,

  /// Drag from tail to head to create an arrow.
  arrow,

  /// Drag to draw a free path.
  freehand,
}
