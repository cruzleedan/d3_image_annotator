/// What a drag on the annotation overlay does.
///
/// Kept separate from `AnnotationController` because it is view state,
/// not document state: switching tools does not change the annotations
/// and must not land on the undo stack.
enum AnnotationTool {
  /// Drags select and move existing annotations rather than creating
  /// new ones.
  select,

  /// Drag corner-to-corner to create a rectangle.
  rectangle,

  /// Drag corner-to-corner to create an ellipse inscribed in the drag.
  circle,

  /// Drag from tail to head to create an arrow.
  arrow,

  /// Drag to draw a free path.
  freehand,
}
