import 'dart:ui' show Size;

import 'package:meta/meta.dart';

import '../coordinates/normalized_point.dart';
import '../coordinates/normalized_rect.dart';

/// A non-destructive rotate / mirror / crop applied to an image.
///
/// **Nothing here modifies pixels.** The transform is data, stored
/// alongside the annotations and applied when rendering — so a crop
/// stays reversible for as long as the app keeps the original file, and
/// a rotation can be undone months later.
///
/// Annotation geometry is **never rewritten** when a transform changes.
/// Marks stay in the original image's coordinate space and the transform
/// is composed at paint time. Rewriting coordinates on every rotate
/// would accumulate float error across repeated operations, and would
/// make a crop destructive: marks outside it could not be recovered by
/// widening the crop again.
@immutable
class ImageTransform {
  const ImageTransform({
    this.quarterTurns = 0,
    this.mirrored = false,
    this.cropRect,
  }) : assert(
         quarterTurns >= 0 && quarterTurns < 4,
         'quarterTurns must be 0-3; use the normalising constructor for '
         'arbitrary values',
       );

  /// Normalises [quarterTurns] into 0-3, so callers can add or subtract
  /// freely without doing modular arithmetic at each site.
  factory ImageTransform.normalized({
    int quarterTurns = 0,
    bool mirrored = false,
    NormalizedRect? cropRect,
  }) {
    return ImageTransform(
      quarterTurns: quarterTurns % 4 < 0
          ? quarterTurns % 4 + 4
          : quarterTurns % 4,
      mirrored: mirrored,
      cropRect: cropRect,
    );
  }

  static const ImageTransform identity = ImageTransform();

  /// Clockwise quarter-turns, 0-3.
  ///
  /// Only 90-degree steps. Arbitrary-angle straightening needs
  /// interpolation, a larger output canvas, and its own quality
  /// decisions — a separate concern if it turns out to be wanted.
  final int quarterTurns;

  /// Horizontal flip, applied after rotation.
  final bool mirrored;

  /// Visible region, in the *original* image's normalized space.
  ///
  /// Null means the full frame. Stored as a rect rather than by
  /// rescaling annotations into the cropped frame, which is what keeps
  /// a crop reversible: widen it again and clipped marks reappear
  /// intact.
  final NormalizedRect? cropRect;

  bool get isIdentity =>
      quarterTurns == 0 && !mirrored && cropRect == null;

  /// Whether the transform swaps the image's width and height.
  bool get swapsAxes => quarterTurns.isOdd;

  /// The visible region, defaulting to the whole image.
  NormalizedRect get effectiveCrop =>
      cropRect ?? NormalizedRect(left: 0, top: 0, right: 1, bottom: 1);

  /// Size of the transformed result, given the original's [size].
  Size resultSize(Size size) {
    final crop = effectiveCrop;
    final cropped = Size(size.width * crop.width, size.height * crop.height);
    return swapsAxes
        ? Size(cropped.height, cropped.width)
        : cropped;
  }

  ImageTransform rotatedClockwise() => ImageTransform.normalized(
    quarterTurns: quarterTurns + 1,
    mirrored: mirrored,
    cropRect: cropRect,
  );

  ImageTransform rotatedCounterClockwise() => ImageTransform.normalized(
    quarterTurns: quarterTurns - 1,
    mirrored: mirrored,
    cropRect: cropRect,
  );

  ImageTransform withMirrored(bool value) => ImageTransform(
    quarterTurns: quarterTurns,
    mirrored: value,
    cropRect: cropRect,
  );

  ImageTransform withCrop(NormalizedRect? rect) => ImageTransform(
    quarterTurns: quarterTurns,
    mirrored: mirrored,
    cropRect: rect,
  );

  /// Maps a point from the original image's space into the transformed
  /// result's space.
  ///
  /// Order matters and mirrors how the result is built: crop first
  /// (which redefines what `[0,1]` spans), then mirror, then rotate.
  ///
  /// The returned point can fall outside `[0,1]` when the input lies
  /// outside the crop — that is the whole point of clipping rather than
  /// hiding. It is returned as a raw pair rather than a
  /// [NormalizedPoint], whose invariant forbids out-of-range values.
  ({double x, double y}) mapPoint(NormalizedPoint point) {
    final crop = effectiveCrop;

    // Crop: re-express the point relative to the visible region.
    var x = crop.width == 0 ? 0.0 : (point.x - crop.left) / crop.width;
    var y = crop.height == 0 ? 0.0 : (point.y - crop.top) / crop.height;

    if (mirrored) x = 1 - x;

    return switch (quarterTurns) {
      1 => (x: 1 - y, y: x),
      2 => (x: 1 - x, y: 1 - y),
      3 => (x: y, y: 1 - x),
      _ => (x: x, y: y),
    };
  }

  /// The inverse of [mapPoint] — from the transformed result's space
  /// back to the original image's.
  ///
  /// Needed for input: a user drawing on a rotated, cropped view is
  /// pointing at the *result*, but the mark must be stored against the
  /// original.
  NormalizedPoint unmapPoint(double x, double y) {
    final (:double ux, :double uy) = switch (quarterTurns) {
      1 => (ux: y, uy: 1 - x),
      2 => (ux: 1 - x, uy: 1 - y),
      3 => (ux: 1 - y, uy: x),
      _ => (ux: x, uy: y),
    };

    final mx = mirrored ? 1 - ux : ux;
    final crop = effectiveCrop;

    return NormalizedPoint(
      (crop.left + mx * crop.width).clamp(0.0, 1.0),
      (crop.top + uy * crop.height).clamp(0.0, 1.0),
    );
  }

  Map<String, Object?> toJson() => {
    'quarterTurns': quarterTurns,
    'mirrored': mirrored,
    if (cropRect case final rect?) 'crop': {
      'left': rect.left,
      'top': rect.top,
      'right': rect.right,
      'bottom': rect.bottom,
    },
  };

  factory ImageTransform.fromJson(Map<String, Object?> json) {
    final turns = json['quarterTurns'];
    final crop = json['crop'];
    return ImageTransform.normalized(
      quarterTurns: turns is int ? turns : 0,
      mirrored: json['mirrored'] == true,
      cropRect: crop is Map
          ? NormalizedRect(
              left: (crop['left'] as num).toDouble(),
              top: (crop['top'] as num).toDouble(),
              right: (crop['right'] as num).toDouble(),
              bottom: (crop['bottom'] as num).toDouble(),
            )
          : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ImageTransform &&
          runtimeType == other.runtimeType &&
          quarterTurns == other.quarterTurns &&
          mirrored == other.mirrored &&
          cropRect == other.cropRect;

  @override
  int get hashCode => Object.hash(quarterTurns, mirrored, cropRect);

  @override
  String toString() =>
      'ImageTransform(quarterTurns: $quarterTurns, mirrored: $mirrored, '
      'cropRect: $cropRect)';
}
