import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show ChangeNotifier;

/// How one `ImageAnnotation`'s reference currently stands, from the
/// cache's point of view.
enum ImageAnnotationLoadState {
  /// Resolve/decode is in flight. Paint a placeholder.
  loading,

  /// Decoded and ready to paint.
  ready,

  /// The resolver or the decoder failed. Paint an error placeholder --
  /// never silently treated the same as [loading], since a failure will
  /// not resolve itself by waiting.
  failed,
}

/// One cache entry: where a reference currently stands, and its decoded
/// image once [ImageAnnotationLoadState.ready].
class ImageAnnotationEntry {
  const ImageAnnotationEntry._(this.state, this.image, this.error);

  const ImageAnnotationEntry.loading()
    : this._(ImageAnnotationLoadState.loading, null, null);

  const ImageAnnotationEntry.ready(ui.Image image)
    : this._(ImageAnnotationLoadState.ready, image, null);

  const ImageAnnotationEntry.failed(Object error)
    : this._(ImageAnnotationLoadState.failed, null, error);

  final ImageAnnotationLoadState state;

  /// Non-null only when [state] is [ImageAnnotationLoadState.ready].
  final ui.Image? image;

  /// Non-null only when [state] is [ImageAnnotationLoadState.failed].
  final Object? error;
}

/// Resolves an `ImageAnnotation.reference` to encoded image bytes.
///
/// This package never interprets the reference itself (WORK-0037) --
/// resolving it to bytes, by whatever storage strategy the consumer app
/// uses (filesystem, database blob, content-provider URI, asset bundle),
/// is entirely this function's job.
///
/// **A reference meant to survive a save/reload cycle must be
/// resolvable by the app's own persisted lookup, not a transient
/// in-memory one** (WORK-0038). Concretely: a reference that only makes
/// sense against, say, a `Map` built fresh each app launch will resolve
/// fine while annotating, then fail every time afterward, once the
/// saved `AnnotationDocument` is reloaded in a later session and handed
/// to a *new* resolver instance that never populated that map. The
/// reference has to be something the app can look up again on its own
/// terms later -- a stored file path, a database row id, a
/// content-provider URI -- exactly the kind of value `ImageAnnotation
/// .reference`'s own doc comment already describes as the intended
/// shape.
///
/// **A consumer app with no such persisted-reference story of its own
/// does not need to support this at all.** Nothing requires exposing
/// the image-annotation tool; an app whose annotated images are, say,
/// flat photo files with no separate asset/stamp registry can simply
/// not offer it (see `D3AnnotatorScreen.visibleTools`) rather than
/// wiring up a resolver for a capability it has no persisted backing
/// for.
typedef ImageReferenceResolver =
    Future<Uint8List> Function(String reference);

/// Decodes and caches the images `ImageAnnotation`s reference, off the
/// synchronous paint path (WORK-0037).
///
/// **Why this is a sibling object `AnnotationController` owns, not a
/// set of fields folded directly into the controller:** document/undo
/// state (what the controller already manages) and async image-decode
/// lifecycle are different kinds of responsibility with different
/// failure modes -- a mutation cannot fail or take time, a decode can
/// do both. Keeping them separate means neither has to understand the
/// other's concerns.
///
/// **`paintAnnotations` only ever reads from this cache; it never
/// triggers a resolve.** `CustomPainter.paint` cannot `await`, so
/// resolving has to happen here, asynchronously, driven by whoever
/// places or loads an `ImageAnnotation` calling [request]. While an
/// entry is [ImageAnnotationLoadState.loading] or
/// [ImageAnnotationLoadState.failed], the painter draws a placeholder
/// instead of the real image -- never skips the annotation entirely,
/// so it stays visible (and, since hit-testing works from the
/// placement rect regardless of decode state, selectable and movable)
/// throughout.
class ImageAnnotationCache extends ChangeNotifier {
  ImageAnnotationCache({required this.resolver});

  final ImageReferenceResolver resolver;

  final Map<String, ImageAnnotationEntry> _entries = {};
  bool _disposed = false;

  /// The current entry for [reference], or null if [request] has never
  /// been called for it.
  ImageAnnotationEntry? entryFor(String reference) => _entries[reference];

  /// Starts resolving and decoding [reference] if it is not already
  /// loading, ready, or failed. A no-op on a reference already present
  /// in the cache -- callers that want to retry a failure call [retry]
  /// instead, so a transient decode failure is never silently retried
  /// forever on every rebuild.
  void request(String reference) {
    if (_entries.containsKey(reference)) return;
    _load(reference);
  }

  /// Re-attempts a failed reference. A no-op for a reference that is
  /// not currently [ImageAnnotationLoadState.failed] -- retrying a
  /// reference already loading or ready would be redundant work.
  void retry(String reference) {
    final entry = _entries[reference];
    if (entry != null && entry.state != ImageAnnotationLoadState.failed) {
      return;
    }
    _load(reference);
  }

  Future<void> _load(String reference) async {
    _entries[reference] = const ImageAnnotationEntry.loading();
    notifyListeners();

    ui.Image? decoded;
    Object? failure;
    try {
      final bytes = await resolver(reference);
      final codec = await ui.instantiateImageCodec(bytes);
      try {
        final frame = await codec.getNextFrame();
        decoded = frame.image;
      } finally {
        codec.dispose();
      }
    } on Object catch (error) {
      failure = error;
    }

    // The cache (or the whole controller it belongs to) may have been
    // disposed while the resolve/decode above was in flight -- a real
    // possibility, not a hypothetical, since navigating away is exactly
    // as likely to happen mid-decode as any other time. Disposing a
    // ui.Image nobody will ever read, rather than storing it and
    // calling notifyListeners on a dead ChangeNotifier, is the correct
    // response: this cache has no more listeners to tell, and no
    // caller will ever call entryFor on it again.
    if (_disposed) {
      decoded?.dispose();
      return;
    }

    _entries[reference] = decoded != null
        ? ImageAnnotationEntry.ready(decoded)
        : ImageAnnotationEntry.failed(failure!);
    notifyListeners();
  }

  /// Drops [reference]'s cache entry, disposing its decoded image if it
  /// had one. Called when an `ImageAnnotation` using it is removed, so
  /// a deleted annotation's decoded image does not sit in memory
  /// indefinitely.
  void release(String reference) {
    final entry = _entries.remove(reference);
    entry?.image?.dispose();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final entry in _entries.values) {
      entry.image?.dispose();
    }
    _entries.clear();
    super.dispose();
  }
}
