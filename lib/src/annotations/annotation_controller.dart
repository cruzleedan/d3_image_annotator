import 'package:flutter/foundation.dart';

import '../coordinates/normalized_rect.dart';
import '../geometry/image_transform.dart';
import 'annotation.dart';
import 'annotation_style.dart';
import 'image_annotation_cache.dart';

/// Owns the list of annotations on one image, with undo/redo.
///
/// A `ChangeNotifier`, matching `CustomCameraController`'s shape so a
/// consumer drives both the same way.
///
/// **Undo is snapshot-based, not command-based.** Each mutation pushes
/// the previous list onto an undo stack. Annotations are immutable and
/// the lists are small (tens of marks), so a snapshot costs a list copy
/// of references; the alternative -- paired do/undo commands -- requires
/// every operation to have a correct inverse, and a single wrong inverse
/// corrupts state silently in a way that is very hard to trace back.
class AnnotationController extends ChangeNotifier {
  AnnotationController({
    List<Annotation>? initial,
    this.maxUndoSteps = 50,
    AnnotationStyle initialStyle = const AnnotationStyle(),
    ImageTransform initialTransform = ImageTransform.identity,
    this.imageCache,
  }) : assert(maxUndoSteps > 0, 'maxUndoSteps must be positive'),
       _annotations = List.of(initial ?? const []),
       _style = initialStyle,
       _transform = initialTransform {
    for (final a in _annotations) {
      if (a case ImageAnnotation(:final reference)) {
        imageCache?.request(reference);
      }
    }
  }

  /// Decodes and caches the images this controller's `ImageAnnotation`s
  /// reference (WORK-0037). Null means no image annotations are in use
  /// -- a controller with only the original four/five geometry types
  /// never needs one. Owned by whoever constructs this controller, not
  /// by the controller itself: its lifecycle (in particular, the
  /// consumer-supplied resolver it wraps) is the consumer app's
  /// concern, the same way the resolver function itself is.
  final ImageAnnotationCache? imageCache;

  /// Cap on undo depth. Bounded so a long editing session cannot grow
  /// memory without limit; the oldest step is dropped past this.
  final int maxUndoSteps;

  List<Annotation> _annotations;
  ImageTransform _transform;

  // Snapshots capture annotations *and* transform together. Keeping
  // separate stacks would let undo restore a rotation without the marks
  // that were drawn under it, or vice versa.
  final List<_Snapshot> _undoStack = [];
  final List<_Snapshot> _redoStack = [];
  AnnotationStyle _style;
  String? _selectedId;

  /// Current annotations, in paint order (last is on top).
  List<Annotation> get annotations => List.unmodifiable(_annotations);

  /// Style applied to newly created annotations.
  AnnotationStyle get style => _style;

  set style(AnnotationStyle value) {
    if (_style == value) return;
    _style = value;
    notifyListeners();
  }

  /// Id of the selected annotation, or null. Selection is deliberately
  /// *not* part of the undo history -- undoing a drawing action should
  /// not also restore what happened to be selected at the time.
  String? get selectedId => _selectedId;

  Annotation? get selected {
    final id = _selectedId;
    if (id == null) return null;
    for (final a in _annotations) {
      if (a.id == id) return a;
    }
    return null;
  }

  /// Non-destructive rotate / mirror / crop applied to the image.
  ///
  /// Annotation geometry is never rewritten to match: marks stay in the
  /// original image's space and this composes at paint time, so a crop
  /// stays reversible and repeated rotations accumulate no float error.
  ImageTransform get transform => _transform;

  /// Rotates 90 degrees clockwise, as one undoable step.
  void rotateClockwise() {
    _pushUndo();
    _transform = _transform.rotatedClockwise();
    notifyListeners();
  }

  void rotateCounterClockwise() {
    _pushUndo();
    _transform = _transform.rotatedCounterClockwise();
    notifyListeners();
  }

  void toggleMirror() {
    _pushUndo();
    _transform = _transform.withMirrored(!_transform.mirrored);
    notifyListeners();
  }

  /// Sets the visible region, or clears it with null.
  ///
  /// Annotations outside the crop are neither hidden nor deleted --
  /// they clip at the boundary, and widening the crop brings them back
  /// intact, because their stored geometry was never touched.
  void crop(NormalizedRect? rect) {
    if (_transform.cropRect == rect) return;
    _pushUndo();
    _transform = _transform.withCrop(rect);
    notifyListeners();
  }

  void resetTransform() {
    if (_transform.isIdentity) return;
    _pushUndo();
    _transform = ImageTransform.identity;
    notifyListeners();
  }

  bool get canUndo => _undoStack.isNotEmpty;
  bool get canRedo => _redoStack.isNotEmpty;
  bool get isEmpty => _annotations.isEmpty;

  void select(String? id) {
    if (_selectedId == id) return;
    _selectedId = id;
    notifyListeners();
  }

  void add(Annotation annotation) {
    _pushUndo();
    _annotations.add(annotation);
    if (annotation case ImageAnnotation(:final reference)) {
      imageCache?.request(reference);
    }
    notifyListeners();
  }

  /// Replaces the annotation with [id]. No-op if it is not present, so a
  /// stale reference cannot silently append a duplicate.
  void update(String id, Annotation replacement) {
    final index = _annotations.indexWhere((a) => a.id == id);
    if (index < 0) return;
    _pushUndo();
    _annotations[index] = replacement;
    if (replacement case ImageAnnotation(:final reference)) {
      // Covers a restyle/reference change on an existing image
      // annotation -- request() is itself a no-op if this reference is
      // already cached, so this is safe to call unconditionally rather
      // than diffing the old and new reference first.
      imageCache?.request(reference);
    }
    notifyListeners();
  }

  void remove(String id) {
    final index = _annotations.indexWhere((a) => a.id == id);
    if (index < 0) return;
    _pushUndo();
    final removed = _annotations.removeAt(index);
    if (removed case ImageAnnotation(:final reference)) {
      _releaseIfUnused(reference);
    }
    if (_selectedId == id) _selectedId = null;
    notifyListeners();
  }

  /// Releases [reference] from [imageCache] unless another surviving
  /// `ImageAnnotation` still uses it -- two placements of the same
  /// image share one decoded copy, so removing one must not evict the
  /// other's still-in-use entry.
  void _releaseIfUnused(String reference) {
    final stillUsed = _annotations.any(
      (a) => a is ImageAnnotation && a.reference == reference,
    );
    if (!stillUsed) imageCache?.release(reference);
  }

  /// Adds a copy of the selected annotation with id [newId], selecting
  /// the copy rather than the original (WORK-0035).
  ///
  /// [newId] is a parameter, not generated here: every annotation's id
  /// is supplied externally at construction (`add` never invents one),
  /// so this stays a single source of id generation with the overlay
  /// widget's own injectable id generator, rather than becoming a
  /// second, inconsistent one. No-op if nothing is selected.
  void duplicateSelected(String newId) {
    final original = selected;
    if (original == null) return;
    final copy = duplicateAnnotation(original, newId);
    _pushUndo();
    _annotations.add(copy);
    if (copy case ImageAnnotation(:final reference)) {
      // Already cached -- duplicating shares the original's decoded
      // image, and request() is a no-op for a reference already
      // present, so this only registers the new instance's use of it
      // for _releaseIfUnused's reference counting.
      imageCache?.request(reference);
    }
    _selectedId = newId;
    notifyListeners();
  }

  void clear() {
    if (_annotations.isEmpty) return;
    _pushUndo();
    for (final a in _annotations) {
      if (a case ImageAnnotation(:final reference)) {
        imageCache?.release(reference);
      }
    }
    _annotations = [];
    _selectedId = null;
    notifyListeners();
  }

  void undo() {
    if (_undoStack.isEmpty) return;
    _redoStack.add(_snapshot());
    _restore(_undoStack.removeLast());
    notifyListeners();
  }

  void redo() {
    if (_redoStack.isEmpty) return;
    _undoStack.add(_snapshot());
    _restore(_redoStack.removeLast());
    notifyListeners();
  }

  _Snapshot _snapshot() => _Snapshot(List.of(_annotations), _transform);

  void _restore(_Snapshot snapshot) {
    final before = _annotations;
    _annotations = snapshot.annotations;
    _transform = snapshot.transform;
    _dropSelectionIfGone();
    _reconcileImageCache(before, _annotations);
  }

  /// Requests every `ImageAnnotation` reference newly present after an
  /// undo/redo jump, and releases every one that is no longer used by
  /// anything in the restored list -- undo/redo replaces the whole
  /// annotation list at once, so a single add/remove's request/release
  /// calls do not cover the jump; this reconciles the cache against
  /// wherever history landed instead.
  void _reconcileImageCache(List<Annotation> before, List<Annotation> after) {
    if (imageCache == null) return;

    final beforeRefs = {
      for (final a in before)
        if (a is ImageAnnotation) a.reference,
    };
    final afterRefs = {
      for (final a in after)
        if (a is ImageAnnotation) a.reference,
    };

    for (final ref in afterRefs.difference(beforeRefs)) {
      imageCache!.request(ref);
    }
    for (final ref in beforeRefs.difference(afterRefs)) {
      imageCache!.release(ref);
    }
  }

  void _pushUndo() {
    _undoStack.add(_snapshot());
    if (_undoStack.length > maxUndoSteps) _undoStack.removeAt(0);
    // Any new edit invalidates the redo branch -- standard editor
    // behaviour, and keeping it would let redo resurrect annotations
    // from a history that no longer leads here.
    _redoStack.clear();
  }

  void _dropSelectionIfGone() {
    final id = _selectedId;
    if (id == null) return;
    if (!_annotations.any((a) => a.id == id)) _selectedId = null;
  }
}

/// One point in the edit history: the annotations *and* the transform
/// as they were together.
class _Snapshot {
  _Snapshot(this.annotations, this.transform);

  final List<Annotation> annotations;
  final ImageTransform transform;
}
