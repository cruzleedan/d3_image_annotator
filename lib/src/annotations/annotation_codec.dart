import 'dart:ui' show Color, Size;

import 'package:meta/meta.dart';

import '../coordinates/normalized_point.dart';
import '../coordinates/normalized_rect.dart';
import 'annotation.dart';
import 'annotation_style.dart';

/// Schema version of the payload this build writes.
///
/// Present from the first release on purpose. Annotations are meant to
/// outlive the app version that wrote them, and retrofitting versioning
/// later means guessing at unversioned data already sitting in a
/// database somewhere.
///
/// Bumped to 2 for `TextAnnotation` (WORK-0034) -- a genuinely new
/// annotation `type` value a version-1 reader has never seen, unlike
/// WORK-0033's `rotation` field, which stayed backward-compatible as an
/// optional key on existing types without needing a version bump at
/// all. A document written by this build is refused by a build that
/// only understands version 1, loudly, rather than silently dropping
/// every text annotation it contains.
const int kAnnotationSchemaVersion = 2;

/// Thrown when a payload cannot be decoded.
///
/// Decoding fails loudly rather than skipping what it does not
/// understand: an annotation silently missing from an inspection report
/// is a defect that looks like nothing at all.
@immutable
class AnnotationDecodeException implements Exception {
  const AnnotationDecodeException(this.message);

  final String message;

  @override
  String toString() => 'AnnotationDecodeException: $message';
}

/// A complete, storable annotation payload.
///
/// This is what a consuming app persists — a database column, a sidecar
/// file, a sync body. The package itself writes nothing and holds no
/// storage state; where these bytes live is entirely the app's choice.
///
/// Annotations are stored as *data*, not burned into pixels, so they
/// stay editable indefinitely. Flattening happens only when producing
/// something that cannot carry data, like a PDF.
@immutable
class AnnotationDocument {
  const AnnotationDocument({
    required this.annotations,
    this.sourceImageSize,
    this.schemaVersion = kAnnotationSchemaVersion,
  });

  final List<Annotation> annotations;

  /// Pixel dimensions of the image these annotations were drawn
  /// against, when known.
  ///
  /// Advisory identity hint, never enforced. Normalized geometry is
  /// resolution-independent, so it survives the file being re-encoded
  /// or resized — but it is *not* meaningful against a different image,
  /// and a file that was replaced or re-cropped outside this package
  /// would silently place every mark wrong. Recording the dimensions
  /// lets a caller notice; see [matchesImageSize].
  ///
  /// Deliberately dimensions rather than a content hash: dimensions are
  /// free to obtain and catch the realistic failures, whereas hashing
  /// megabytes on every load to catch a re-encode that preserved the
  /// framing is not worth it.
  final Size? sourceImageSize;

  final int schemaVersion;

  bool get isEmpty => annotations.isEmpty;

  /// Whether [imageSize] looks like the image these annotations belong
  /// to.
  ///
  /// `true` when no hint was recorded — absence of evidence is not a
  /// mismatch, and refusing to render in that case would break every
  /// payload written before a hint existed.
  ///
  /// The package never acts on this itself. An app may legitimately be
  /// re-associating annotations with a new image on purpose, and only
  /// the app knows whether a mismatch is a bug or intent.
  bool matchesImageSize(Size imageSize) {
    final recorded = sourceImageSize;
    if (recorded == null) return true;
    return recorded.width == imageSize.width &&
        recorded.height == imageSize.height;
  }

  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    if (sourceImageSize case final size?) ...{
      'sourceWidth': size.width,
      'sourceHeight': size.height,
    },
    'annotations': [for (final a in annotations) annotationToJson(a)],
  };

  factory AnnotationDocument.fromJson(Map<String, Object?> json) {
    final version = json['schemaVersion'];
    if (version is! int) {
      throw const AnnotationDecodeException(
        'missing or invalid schemaVersion; this does not look like an '
        'annotation payload',
      );
    }
    if (version > kAnnotationSchemaVersion) {
      throw AnnotationDecodeException(
        'payload schema version $version is newer than this build '
        'understands ($kAnnotationSchemaVersion) -- refusing rather than '
        'dropping annotations it cannot read',
      );
    }

    final raw = json['annotations'];
    if (raw is! List) {
      throw const AnnotationDecodeException(
        'annotations must be a list',
      );
    }

    final width = json['sourceWidth'];
    final height = json['sourceHeight'];
    final size = (width is num && height is num)
        ? Size(width.toDouble(), height.toDouble())
        : null;

    return AnnotationDocument(
      schemaVersion: version,
      sourceImageSize: size,
      annotations: [
        for (final entry in raw)
          annotationFromJson(_asMap(entry, 'annotation entry')),
      ],
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! AnnotationDocument) return false;
    if (schemaVersion != other.schemaVersion) return false;
    if (sourceImageSize != other.sourceImageSize) return false;
    if (annotations.length != other.annotations.length) return false;
    for (var i = 0; i < annotations.length; i++) {
      if (annotations[i] != other.annotations[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
    schemaVersion,
    sourceImageSize,
    Object.hashAll(annotations),
  );
}

/// Encodes one annotation. The `type` discriminator is what
/// [annotationFromJson] switches on.
Map<String, Object?> annotationToJson(Annotation annotation) {
  final base = <String, Object?>{
    'id': annotation.id,
    'style': _styleToJson(annotation.style),
  };
  return switch (annotation) {
    RectangleAnnotation(:final rect, :final rotation) => {
      ...base,
      'type': 'rectangle',
      'rect': _rectToJson(rect),
      // Omitted when zero rather than written as 0.0: keeps documents
      // written before rotation existed byte-for-byte comparable to
      // ones written since, for the overwhelmingly common unrotated
      // case, and costs nothing on decode -- a missing key already
      // means "no rotation" (WORK-0033).
      if (rotation != 0.0) 'rotation': rotation,
    },
    CircleAnnotation(:final rect, :final rotation) => {
      ...base,
      'type': 'circle',
      'rect': _rectToJson(rect),
      if (rotation != 0.0) 'rotation': rotation,
    },
    ArrowAnnotation(:final start, :final end) => {
      ...base,
      'type': 'arrow',
      'start': _pointToJson(start),
      'end': _pointToJson(end),
    },
    FreehandAnnotation(:final points) => {
      ...base,
      'type': 'freehand',
      'points': [for (final p in points) _pointToJson(p)],
    },
    TextAnnotation(:final position, :final text, :final rotation) => {
      ...base,
      'type': 'text',
      'position': _pointToJson(position),
      'text': text,
      if (rotation != 0.0) 'rotation': rotation,
    },
  };
}

/// Decodes one annotation.
///
/// An unrecognised `type` throws. A newer app writing a shape this build
/// does not know must be a loud failure, not a mark that quietly
/// vanishes from a report.
Annotation annotationFromJson(Map<String, Object?> json) {
  final type = json['type'];
  if (type is! String) {
    throw const AnnotationDecodeException('annotation is missing "type"');
  }
  final id = json['id'];
  if (id is! String) {
    throw const AnnotationDecodeException('annotation is missing "id"');
  }
  final style = _styleFromJson(_asMap(json['style'], 'style'));

  switch (type) {
    case 'rectangle':
      return RectangleAnnotation(
        id: id,
        style: style,
        rect: _rectFromJson(_asMap(json['rect'], 'rect')),
        rotation: _rotationFromJson(json['rotation']),
      );
    case 'circle':
      return CircleAnnotation(
        id: id,
        style: style,
        rect: _rectFromJson(_asMap(json['rect'], 'rect')),
        rotation: _rotationFromJson(json['rotation']),
      );
    case 'arrow':
      return ArrowAnnotation(
        id: id,
        style: style,
        start: _pointFromJson(_asMap(json['start'], 'start')),
        end: _pointFromJson(_asMap(json['end'], 'end')),
      );
    case 'freehand':
      final raw = json['points'];
      if (raw is! List || raw.isEmpty) {
        throw const AnnotationDecodeException(
          'freehand annotation needs a non-empty "points" list',
        );
      }
      return FreehandAnnotation(
        id: id,
        style: style,
        points: [
          for (final p in raw) _pointFromJson(_asMap(p, 'freehand point')),
        ],
      );
    case 'text':
      final text = json['text'];
      if (text is! String) {
        throw const AnnotationDecodeException(
          'text annotation needs a string "text"',
        );
      }
      return TextAnnotation(
        id: id,
        style: style,
        position: _pointFromJson(_asMap(json['position'], 'position')),
        text: text,
        rotation: _rotationFromJson(json['rotation']),
      );
    default:
      throw AnnotationDecodeException(
        'unknown annotation type "$type" -- written by a newer version? '
        'Refusing rather than dropping it',
      );
  }
}

Map<String, Object?> _styleToJson(AnnotationStyle style) => {
  // Stored as an ARGB int: compact, and stable across Color's own
  // representation changing (it moved to floating-point components).
  'color': style.color.toARGB32(),
  'strokeWidth': style.strokeWidth,
  'filled': style.filled,
  // Omitted at their defaults/absent, the same convention rotation
  // already established: a document written before text annotations
  // existed decodes identically to one that explicitly wrote the
  // default fontSize, and a missing backgroundColor key already means
  // "no background" without needing a sentinel value.
  if (style.fontSize != const AnnotationStyle().fontSize)
    'fontSize': style.fontSize,
  if (style.backgroundColor case final bg?)
    'backgroundColor': bg.toARGB32(),
};

AnnotationStyle _styleFromJson(Map<String, Object?> json) {
  final color = json['color'];
  final strokeWidth = json['strokeWidth'];
  if (color is! int || strokeWidth is! num) {
    throw const AnnotationDecodeException(
      'style needs an int "color" and numeric "strokeWidth"',
    );
  }
  final fontSize = json['fontSize'];
  if (fontSize != null && fontSize is! num) {
    throw const AnnotationDecodeException('"fontSize" must be a number');
  }
  final backgroundColor = json['backgroundColor'];
  if (backgroundColor != null && backgroundColor is! int) {
    throw const AnnotationDecodeException('"backgroundColor" must be an int');
  }
  return AnnotationStyle(
    color: Color(color),
    strokeWidth: strokeWidth.toDouble(),
    filled: json['filled'] == true,
    fontSize: (fontSize as num?)?.toDouble() ?? const AnnotationStyle().fontSize,
    backgroundColor: backgroundColor == null
        ? null
        : Color(backgroundColor as int),
  );
}

Map<String, Object?> _rectToJson(NormalizedRect rect) => {
  'left': rect.left,
  'top': rect.top,
  'right': rect.right,
  'bottom': rect.bottom,
};

NormalizedRect _rectFromJson(Map<String, Object?> json) {
  final left = json['left'];
  final top = json['top'];
  final right = json['right'];
  final bottom = json['bottom'];
  if (left is! num || top is! num || right is! num || bottom is! num) {
    throw const AnnotationDecodeException(
      'rect needs numeric left/top/right/bottom',
    );
  }
  return NormalizedRect(
    left: left.toDouble(),
    top: top.toDouble(),
    right: right.toDouble(),
    bottom: bottom.toDouble(),
  );
}

Map<String, Object?> _pointToJson(NormalizedPoint point) => {
  'x': point.x,
  'y': point.y,
};

NormalizedPoint _pointFromJson(Map<String, Object?> json) {
  final x = json['x'];
  final y = json['y'];
  if (x is! num || y is! num) {
    throw const AnnotationDecodeException('point needs numeric x and y');
  }
  return NormalizedPoint(x.toDouble(), y.toDouble());
}

Map<String, Object?> _asMap(Object? value, String what) {
  if (value is Map<String, Object?>) return value;
  if (value is Map) return value.cast<String, Object?>();
  throw AnnotationDecodeException('$what must be a JSON object');
}

/// Decodes an optional `rotation` field, defaulting to `0.0`.
///
/// A missing key -- a document written before WORK-0033, or the
/// deliberately-omitted zero case in `annotationToJson` -- means "no
/// rotation", not an error: this is what makes the field backward- and
/// forward-compatible without a schema-version bump. A present-but-
/// wrong-typed value is still a loud decode failure, matching how
/// every other field in this file behaves.
double _rotationFromJson(Object? value) {
  if (value == null) return 0.0;
  if (value is num) return value.toDouble();
  throw const AnnotationDecodeException('"rotation" must be a number');
}
