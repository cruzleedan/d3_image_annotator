import 'dart:ui' show Size;

import 'annotation_codec.dart';

/// How a stored [AnnotationDocument] relates to the image it is about to
/// be shown or rendered against.
///
/// Annotations are stored as data rather than burned into pixels, which
/// keeps them editable — but it also means the data and the image are
/// two separate things an app has to keep together. This type names the
/// ways they can come apart, so a caller handles them deliberately
/// instead of discovering the consequences in a finished report.
enum AnnotationBinding {
  /// The image is present and its dimensions match the recorded hint,
  /// or no hint was recorded. Safe to render.
  ok,

  /// The image is present but its dimensions differ from the ones the
  /// annotations were drawn against.
  ///
  /// Rendering will place every mark somewhere, but not necessarily
  /// where it was drawn: the file may have been replaced or re-cropped
  /// outside this package. It can also be entirely intentional — an app
  /// deliberately re-associating annotations with a new image — which is
  /// why this is reported rather than enforced.
  sizeMismatch,

  /// There is no image.
  ///
  /// The annotations survived but the file did not: deleted, moved, or
  /// unreachable. There is nothing to draw against and no correct
  /// render — an empty canvas would be a lie, since the marks describe
  /// content that is simply gone. A caller should surface this rather
  /// than produce an image.
  missingImage,
}

/// Classifies how [document] relates to an image of [imageSize].
///
/// Pass null for [imageSize] when the image could not be loaded.
///
/// Advisory by design: nothing in this package acts on the result. Only
/// the app knows whether a mismatch is corruption or intent, and whether
/// a missing file should block a report or be skipped with a note.
AnnotationBinding classifyBinding(
  AnnotationDocument document,
  Size? imageSize,
) {
  if (imageSize == null) return AnnotationBinding.missingImage;
  return document.matchesImageSize(imageSize)
      ? AnnotationBinding.ok
      : AnnotationBinding.sizeMismatch;
}
