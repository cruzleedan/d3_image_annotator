import 'package:flutter/foundation.dart';

import 'annotation.dart';
import 'annotation_style.dart';

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
  }) : assert(maxUndoSteps > 0, 'maxUndoSteps must be positive'),
       _annotations = List.of(initial ?? const []),
       _style = initialStyle;

  /// Cap on undo depth. Bounded so a long editing session cannot grow
  /// memory without limit; the oldest step is dropped past this.
  final int maxUndoSteps;

  List<Annotation> _annotations;
  final List<List<Annotation>> _undoStack = [];
  final List<List<Annotation>> _redoStack = [];
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
    notifyListeners();
  }

  /// Replaces the annotation with [id]. No-op if it is not present, so a
  /// stale reference cannot silently append a duplicate.
  void update(String id, Annotation replacement) {
    final index = _annotations.indexWhere((a) => a.id == id);
    if (index < 0) return;
    _pushUndo();
    _annotations[index] = replacement;
    notifyListeners();
  }

  void remove(String id) {
    final index = _annotations.indexWhere((a) => a.id == id);
    if (index < 0) return;
    _pushUndo();
    _annotations.removeAt(index);
    if (_selectedId == id) _selectedId = null;
    notifyListeners();
  }

  void clear() {
    if (_annotations.isEmpty) return;
    _pushUndo();
    _annotations = [];
    _selectedId = null;
    notifyListeners();
  }

  void undo() {
    if (_undoStack.isEmpty) return;
    _redoStack.add(List.of(_annotations));
    _annotations = _undoStack.removeLast();
    _dropSelectionIfGone();
    notifyListeners();
  }

  void redo() {
    if (_redoStack.isEmpty) return;
    _undoStack.add(List.of(_annotations));
    _annotations = _redoStack.removeLast();
    _dropSelectionIfGone();
    notifyListeners();
  }

  void _pushUndo() {
    _undoStack.add(List.of(_annotations));
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
