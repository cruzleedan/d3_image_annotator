import 'package:meta/meta.dart';

/// Output encoding for a rendered image.
///
/// PNG only, for now. Flutter's `ui.Image.toByteData` offers no JPEG
/// encoder — its `ImageByteFormat` is PNG or raw pixels — so a `jpeg`
/// value here would either need an image-codec dependency or would
/// quietly return PNG bytes under a JPEG name. Neither is worth doing
/// silently; the enum exists so adding JPEG later is not a breaking
/// change.
enum RenderFormat {
  /// Lossless, with alpha. Larger than a JPEG for a photograph.
  png,
}

/// How an annotated image is rendered.
@immutable
class RenderOptions {
  const RenderOptions({
    this.maxDimension = 2000,
    this.format = RenderFormat.png,
  }) : assert(
         maxDimension == null || maxDimension > 0,
         'maxDimension must be positive, or null for full resolution',
       );

  /// Longest side of the output, in pixels. Null renders at full
  /// resolution.
  ///
  /// **Bounded by default, deliberately.** Site Inspector hit real
  /// memory trouble producing unbounded full-resolution copies
  /// (SPIKE-0005 §12/§14), and a report attachment almost never needs
  /// 12 megapixels. A caller that genuinely wants the original must ask
  /// for it, so the expensive path is chosen rather than stumbled into.
  final int? maxDimension;

  final RenderFormat format;

  RenderOptions copyWith({
    int? maxDimension,
    bool clearMaxDimension = false,
    RenderFormat? format,
  }) {
    return RenderOptions(
      maxDimension: clearMaxDimension
          ? null
          : (maxDimension ?? this.maxDimension),
      format: format ?? this.format,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RenderOptions &&
          runtimeType == other.runtimeType &&
          maxDimension == other.maxDimension &&
          format == other.format;

  @override
  int get hashCode => Object.hash(maxDimension, format);

  @override
  String toString() =>
      'RenderOptions(maxDimension: $maxDimension, format: $format)';
}

/// Thrown when a render cannot be produced.
@immutable
class RenderException implements Exception {
  const RenderException(this.message);

  final String message;

  @override
  String toString() => 'RenderException: $message';
}
