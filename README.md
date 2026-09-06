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

## Saving annotations

**Annotations are data, not pixels.** Nothing is burned into the image —
you store the geometry and keep it editable forever. A user can reopen a
photo months later and move a mark someone else placed. Flattening
happens only when producing something that cannot carry data, like a PDF
(coming in a later release).

```dart
// Persist however you like -- a database column, a sidecar file, a sync
// payload. This package writes nothing itself.
final document = AnnotationDocument(
  annotations: controller.annotations,
  sourceImageSize: const Size(3000, 4000),
);
final json = jsonEncode(document.toJson());

// Later, against the same image
final restored = AnnotationDocument.fromJson(jsonDecode(json));
final controller = AnnotationController(initial: restored.annotations);
```

Because geometry is normalized, a saved annotation stays valid if the
file is re-encoded or resized. It is *not* valid against a different
image — so the payload records the source's dimensions, and
`classifyBinding` tells you what you are dealing with:

```dart
switch (classifyBinding(document, imageSize)) {
  case AnnotationBinding.ok:            // render
  case AnnotationBinding.sizeMismatch:  // wrong image, or deliberate re-association
  case AnnotationBinding.missingImage:  // nothing to render against
}
```

That last case is the one worth handling explicitly: annotations can
outlive the file they describe, and an empty canvas would be a lie.

The check is **advisory** — the package never refuses to decode, because
only your app knows whether a mismatch is corruption or intent.

## The whole editor, in one widget

`D3AnnotatorScreen` is the usual entry point. It brings its own tools,
history controls and close affordance, so you supply an image and decide
what to do with the result:

```dart
D3AnnotatorScreen(
  image: FileImage(File(path)),
  imageSize: const Size(3000, 4000),
  controller: controller,
  onClose: () => Navigator.pop(context),
  onDone: () => save(controller.annotations),
)
```

Every control carries a caption — crop, straighten and mirror icons are
not self-evident — and meets a 48dp touch target (Material 3 and
WCAG 2.5.8 AA). Tools are grouped so the row stays short; undo, redo and
clear deliberately sit *outside* those groups, because undo is a safety
control and hunting for it behind a group switch leaves the mistake on
screen.

**It owns no `Scaffold`, `AppBar` or screen title.** An annotator
embedded in your app should look like your app, so the bars are plain
rows you can place in a page, a dialog or a sheet.

Building something different? `D3ImageAnnotator` is the bare viewer, and
`D3ToolButton`, `D3ToolBar`, `D3ToolGroupBar`, `D3HistoryBar` and
`D3CloseButton` are exported individually.

## Rendering for output

Annotations stay data until something needs pixels — a PDF, an
attachment, a share sheet. `renderAnnotatedImage` flattens them on
demand and returns bytes; it writes nothing and never touches the
source, so the marks remain editable afterwards.

```dart
final png = await renderAnnotatedImage(
  imageBytes: await File(path).readAsBytes(),
  annotations: controller.annotations,
  transform: controller.transform,
);
```

Compositing goes through the same `paintAnnotations` the live overlay
uses, so what you saw is what you get — including marks clipped at a
crop boundary.

Two things worth knowing:

- **Output is bounded by default** (2000px longest side). Unbounded
  full-resolution copies caused real memory trouble in practice, and a
  report attachment rarely needs 12 megapixels. Pass
  `RenderOptions(maxDimension: null)` to opt into the original.
- **It takes bytes, not an `ImageProvider`.** A provider resolves
  through Flutter's binding and only makes progress while frames are
  pumped, so awaiting one from a background task hangs. Bytes have no
  such dependency.

PNG only for now: Flutter's `toByteData` has no JPEG encoder, and
returning PNG bytes under a JPEG name would be worse than saying so.

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

Model, controller, painter, hit-testing, overlay, the zoomable viewer,
and JSON serialization are implemented, with 75 tests. Rendering an
annotated image to a file is not built yet, nor are crop/rotate/mirror.

Text and highlight annotations are deliberately deferred — text drags in
IME and font-metrics work that is its own problem.
