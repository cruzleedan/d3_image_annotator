import 'package:flutter/painting.dart' show ImageProvider;
import 'package:flutter/widgets.dart' show Color;
import 'package:meta/meta.dart';

/// What sits behind an annotated canvas: a real image, or a plain
/// colour fill (WORK-0036).
///
/// A sealed choice rather than a nullable `ImageProvider` +
/// `backgroundColor` pair: the render/paint path never inspects source
/// pixels for anything beyond "the thing under the annotations", so the
/// two kinds are already interchangeable everywhere that matters, and a
/// sealed type makes "handle both cases" a compile-time property of
/// every `switch` over it rather than a convention a nullable field
/// relies on call sites remembering.
///
/// **Not a build-time constant.** `D3AnnotatorScreen`/`D3ImageAnnotator`
/// take this as ordinary reactive widget state (a `StatefulWidget`
/// parameter the consumer rebuilds with a new value), because switching
/// backgrounds -- image to colour, colour to image, or image to a
/// different image -- must work while the annotator stays open, not
/// only as a one-time choice at construction.
@immutable
sealed class AnnotationBackground {
  const factory AnnotationBackground.image(ImageProvider image) =
      _ImageBackground;

  const factory AnnotationBackground.color(Color color) = _ColorBackground;
}

final class _ImageBackground implements AnnotationBackground {
  const _ImageBackground(this.image);

  final ImageProvider image;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _ImageBackground && image == other.image;

  @override
  int get hashCode => image.hashCode;

  @override
  String toString() => 'AnnotationBackground.image($image)';
}

final class _ColorBackground implements AnnotationBackground {
  const _ColorBackground(this.color);

  final Color color;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _ColorBackground && color == other.color;

  @override
  int get hashCode => color.hashCode;

  @override
  String toString() => 'AnnotationBackground.color($color)';
}

/// The [ImageProvider] behind [background], or null if it is a colour.
///
/// A free function rather than a getter on the sealed type: the two
/// private implementation classes are not exposed, so callers switch
/// via these accessors (or their own `switch` after an `is _Image...`
/// check would not compile outside this library) rather than pattern
/// -matching on private subtypes they cannot name.
ImageProvider? imageOf(AnnotationBackground background) => switch (background) {
  _ImageBackground(:final image) => image,
  _ColorBackground() => null,
};

/// The fill [Color] behind [background], or null if it is an image.
Color? colorOf(AnnotationBackground background) => switch (background) {
  _ImageBackground() => null,
  _ColorBackground(:final color) => color,
};
