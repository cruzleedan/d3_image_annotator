# d3_image_annotator

Annotate images with shapes, arrows, and freehand marks. Pinch to zoom,
one finger to draw.

Works on **any image** — a file from disk, a photo just taken, an asset,
a network image. It has no camera dependency; it started inside
[d3_camera](https://github.com/cruzleedan/d3_camera) and was split out
because annotating an image has nothing to do with how the image was
produced.

## The guarantee

**Geometry is stored in normalized `[0,1]` image space, never widget
pixels.** That is the one form invariant under everything that differs
between drawing a mark and exporting it: widget size, zoom level, fit
mode, image resolution, rotation, and mirroring.

Concretely: a mark drawn on a 400px-wide preview lands on the same
feature of a 4000px-wide export, and zooming in to draw a fine detail
stores the same coordinate as drawing it zoomed out.

Annotations also **scale with the image, not the screen** — a circle
around a hairline crack keeps its weight relative to the crack at every
zoom, because stroke width is a fraction of the image's shorter side
rather than a pixel count.

## Getting started

```dart
final controller = AnnotationController();

D3ImageAnnotator(
  image: FileImage(File(path)),
  imageSize: const Size(3000, 4000),  // the image's real pixels
  controller: controller,
  tool: AnnotationTool.rectangle,
)
```

`controller.annotations` is the result — an immutable list of
normalized-geometry shapes you can persist however you like.

### Gestures

| Input | Action |
|---|---|
| One finger | Draw with the active tool |
| Two fingers | Pinch to zoom, drag to pan |

No mode to toggle, matching Apple Photos markup and most drawing apps.
This needs a custom gesture recognizer, because `InteractiveViewer` has
no built-in way to restrict panning to two fingers — its `panEnabled`
uses single-finger drag, which is the finger drawing wants
([flutter/flutter#94541](https://github.com/flutter/flutter/issues/94541),
[#140058](https://github.com/flutter/flutter/issues/140058)). See
`SinglePointerPanGestureRecognizer`.

### Tools

`select` (tap to select, drag to move), `rectangle`, `circle`, `arrow`,
`freehand`. Undo/redo is on the controller (`canUndo`, `undo()`,
`canRedo`, `redo()`), bounded and snapshot-based.

## Composing your own UI

`D3ImageAnnotator` is a convenience. The overlay works standalone over
anything you draw yourself:

```dart
Stack(
  fit: StackFit.expand,
  children: [
    MyOwnImageWidget(),
    AnnotationOverlay(
      controller: controller,
      imageSize: imageSize,
      tool: tool,
    ),
  ],
)
```

`paintAnnotations(canvas, contentRect, annotations)` is a plain function,
not tied to a widget — the same call renders the live overlay and, later,
the burned-in export. One rendering path means the two cannot drift.

## Status

Model, controller, painter, hit-testing, overlay, and the zoomable viewer
are implemented, with 49 tests. Export (burning annotations into a JPEG)
is not built yet.

Text and highlight annotations are deliberately deferred — text drags in
IME and font-metrics work that is its own problem.
