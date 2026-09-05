## 0.1.0

Initial release. Split out of `d3_camera`, where the annotation system
was originally built — annotating an image has nothing to do with how
the image was produced.

* `D3ImageAnnotator` — a zoomable, annotatable view over any
  `ImageProvider`. One finger draws, two fingers pinch to zoom and pan.
* Rectangle, circle, arrow, and freehand annotations, plus a select tool
  for moving existing marks.
* `AnnotationController` with bounded, snapshot-based undo/redo.
* Geometry stored in normalized `[0,1]` image space, so a mark lands on
  the same feature at any zoom, widget size, or export resolution.
* `AnnotationOverlay` and `paintAnnotations` are usable standalone for
  fully custom UI.

Not yet implemented: export (burning annotations into an image file),
and text/highlight annotations.
