import 'dart:typed_data';
import 'dart:ui' as ui show instantiateImageCodec;
import 'dart:ui' show Size;

import 'annotation.dart';
import 'annotation_binding.dart';
import 'annotation_codec.dart';
import 'annotation_controller.dart';
import 'annotation_style.dart';
import 'image_annotation_cache.dart';

/// Everything a consumer needs to resume editing a previously-saved
/// [AnnotationDocument] against its image, bundled into one call
/// (WORK-0038).
///
/// Resuming a saved session otherwise means four separate steps done by
/// hand, every time: decode the JSON, decode the image a second time
/// purely to learn its pixel [Size] (`D3ImageAnnotator`/
/// `D3AnnotatorScreen`'s `canvasSize` has no other way to obtain it — see
/// their own doc comments on why layout must happen before decode),
/// build an [AnnotationController] from the decoded annotations, and
/// only then construct the screen. This bundles the first three into
/// one awaited call, leaving only "pass `canvasSize` and `controller`
/// into the widget" for the caller.
///
/// **Starting a *fresh* (non-resumed) session is unaffected** — this
/// type exists purely to remove the resume-path's repeated boilerplate;
/// constructing an [AnnotationController] directly for a brand-new
/// annotation remains exactly as simple as it always was.
///
/// **Does not touch [ImageAnnotationCache].** If the document being
/// resumed contains an [ImageAnnotation] (its own
/// [ImageAnnotation.reference] pointing at another image), resolving
/// that reference back to bytes is still entirely the caller's
/// responsibility, the same as it always has been — this type only
/// decodes the document's own background image bytes, not anything
/// referenced from within it. A consumer with no reference-resolution
/// story of its own can simply not expose the image-annotation tool;
/// see [ImageAnnotation.reference] and [ImageReferenceResolver] for what
/// a reference intended to survive a save/reload cycle needs to be
/// resolvable against.
class AnnotationEditingSession {
  const AnnotationEditingSession({
    required this.canvasSize,
    required this.controller,
    required this.binding,
  });

  /// Decodes [imageBytes] once to learn its pixel dimensions, then
  /// builds a ready-to-use [controller] from [document]'s stored
  /// annotations.
  ///
  /// [binding] is [classifyBinding]'s own result for [document] against
  /// the *decoded* size — computed here because decoding already
  /// happened; a caller that also wants this classification would
  /// otherwise have to decode the image a third time itself. Advisory,
  /// same as [classifyBinding] always is: this constructor does not
  /// refuse to build a session for a [AnnotationBinding.sizeMismatch] or
  /// [AnnotationBinding.missingImage] result — decoding [imageBytes]
  /// failing entirely is the only case that throws, propagated from
  /// `dart:ui`'s own decode failure. A caller decides what a mismatch
  /// means for its own UI; see [AnnotationBinding]'s own doc comment for
  /// why this package does not decide that for you.
  ///
  /// [initialStyle], [maxUndoSteps], and [imageCache] are forwarded
  /// straight to the constructed [AnnotationController] — see its own
  /// constructor for what each does.
  static Future<AnnotationEditingSession> fromDocument(
    AnnotationDocument document,
    Uint8List imageBytes, {
    AnnotationStyle initialStyle = const AnnotationStyle(),
    int maxUndoSteps = 50,
    ImageAnnotationCache? imageCache,
  }) async {
    final codec = await ui.instantiateImageCodec(imageBytes);
    final Size canvasSize;
    try {
      final frame = await codec.getNextFrame();
      // Only the dimensions are needed here -- the decoded pixels
      // themselves are not retained. The image itself is what
      // `AnnotationBackground.image` will separately hand to Flutter's
      // own image pipeline to actually paint.
      canvasSize = Size(
        frame.image.width.toDouble(),
        frame.image.height.toDouble(),
      );
      frame.image.dispose();
    } finally {
      codec.dispose();
    }

    return AnnotationEditingSession(
      canvasSize: canvasSize,
      controller: AnnotationController(
        initial: document.annotations,
        initialStyle: initialStyle,
        maxUndoSteps: maxUndoSteps,
        imageCache: imageCache,
      ),
      binding: classifyBinding(document, canvasSize),
    );
  }

  /// The decoded image's pixel dimensions -- pass straight through to
  /// `D3ImageAnnotator`/`D3AnnotatorScreen`'s own `canvasSize`.
  final Size canvasSize;

  /// Pre-populated from the saved document's annotations -- pass
  /// straight through to `D3ImageAnnotator`/`D3AnnotatorScreen`'s own
  /// `controller`.
  ///
  /// Owned by the caller from this point on, the same as any other
  /// [AnnotationController] -- dispose it when the editing screen is
  /// done with it.
  final AnnotationController controller;

  /// [classifyBinding]'s result for the document against the image just
  /// decoded -- see this constructor's own doc comment for what it does
  /// and does not mean.
  final AnnotationBinding binding;
}
