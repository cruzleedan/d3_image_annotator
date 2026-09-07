import 'dart:ui' show Offset;

import 'package:meta/meta.dart';

import '../coordinates/normalized_point.dart';
import 'annotation.dart';
import 'annotation_handles.dart';

/// What is currently happening to a single annotation on the canvas --
/// the vocabulary `AnnotationOverlay` itself uses internally, named so
/// comments, tests, and any future UI reacting to the current
/// interaction can all say the same six words rather than reinventing
/// ad hoc phrasing per call site.
///
/// A sealed hierarchy, not an enum with nullable payload fields: each
/// state needs different data (a grip, a drag anchor, the text session
/// being edited), and a sealed class makes "which fields are valid
/// together" a type-level fact rather than a convention every reader
/// has to remember -- the same reasoning [Annotation] itself already
/// applies to the five shape types.
///
/// - [AnnotationUnselected]: nothing selected. No outline, no handles,
///   no floating controls.
/// - [AnnotationSelected]: selected and idle -- the dashed selection
///   outline, corner/rotate handles, and floating delete/duplicate
///   controls are all showing, but no gesture is in progress.
/// - [AnnotationMoving]: a body drag is repositioning the annotation.
/// - [AnnotationResizing]: a corner handle (or, for an arrow, an
///   endpoint) is being dragged.
/// - [AnnotationRotating]: the rotate handle is being dragged.
/// - [AnnotationEditing]: a [TextAnnotation]'s live text field is open
///   for typing -- the only state specific to one annotation type,
///   since text is the only type with an in-place edit affordance.
@immutable
sealed class AnnotationInteractionState {
  const AnnotationInteractionState();
}

/// No annotation is selected.
final class AnnotationUnselected extends AnnotationInteractionState {
  const AnnotationUnselected();
}

/// [annotation] is selected and idle: outline, handles, and floating
/// controls are showing, but no drag is in progress.
final class AnnotationSelected extends AnnotationInteractionState {
  const AnnotationSelected(this.annotation);

  final Annotation annotation;
}

/// [id] is being moved by a body drag, from [original]'s geometry and
/// [anchor] (the drag's starting point, in normalized space).
///
/// [textDragStartPixel] is non-null only while [original] is a
/// [TextAnnotation]: unlike every other type (where a stationary "drag"
/// is simply a no-op translate), a tap on a text annotation must be
/// able to resolve to either a move or a re-opened edit session once
/// the gesture ends, so this state doubles as "maybe moving, maybe
/// about to edit" for text specifically until `AnnotationOverlay`
/// decides which one the finger actually did (see its own gesture
/// handling for the `kTouchSlop` comparison that makes that call).
final class AnnotationMoving extends AnnotationInteractionState {
  const AnnotationMoving({
    required this.id,
    required this.original,
    required this.anchor,
    this.textDragStartPixel,
    this.textDragLastPixel,
  });

  final String id;
  final Annotation original;
  final NormalizedPoint anchor;
  final Offset? textDragStartPixel;
  final Offset? textDragLastPixel;

  AnnotationMoving copyWith({Offset? textDragLastPixel}) => AnnotationMoving(
    id: id,
    original: original,
    anchor: anchor,
    textDragStartPixel: textDragStartPixel,
    textDragLastPixel: textDragLastPixel ?? this.textDragLastPixel,
  );
}

/// [id] is being resized by a drag on [grip] -- a corner, or (for an
/// arrow) an endpoint. Never [AnnotationGrip.rotate]; that is
/// [AnnotationRotating] instead, a separate state rather than a case
/// this one also has to handle, since resizing and rotating change
/// different fields of an annotation and should read as different
/// things wherever this state is consumed.
final class AnnotationResizing extends AnnotationInteractionState {
  const AnnotationResizing({
    required this.id,
    required this.original,
    required this.grip,
  }) : assert(
         grip != AnnotationGrip.rotate,
         'rotate is AnnotationRotating, not AnnotationResizing',
       );

  final String id;
  final Annotation original;
  final AnnotationGrip grip;
}

/// [id] is being rotated by a drag on its rotate handle.
final class AnnotationRotating extends AnnotationInteractionState {
  const AnnotationRotating({required this.id, required this.original});

  final String id;
  final Annotation original;
}

/// A [TextAnnotation]'s live text field is open: either placing a
/// brand-new one at [position], or re-editing [existing]'s content in
/// place. Exactly one of the two is set, mirroring the two ways
/// `AnnotationOverlay` can enter this state (WORK-0034).
final class AnnotationEditing extends AnnotationInteractionState {
  const AnnotationEditing({this.position, this.existing})
    : assert(
        (position == null) != (existing == null),
        'exactly one of position or existing must be given',
      );

  final NormalizedPoint? position;
  final TextAnnotation? existing;
}
