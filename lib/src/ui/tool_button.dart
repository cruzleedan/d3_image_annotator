import 'package:flutter/material.dart';

import '../annotations/annotation.dart';
import '../annotations/annotation_controller.dart';
import '../annotations/annotation_style.dart';
import '../geometry/image_transform.dart';

/// Minimum touch target, in logical pixels.
///
/// 48dp is the floor set by both Material 3 and WCAG 2.5.8 Target Size
/// (Level AA). It is a hard requirement rather than a style choice: a
/// smaller control is measurably harder to hit, and disproportionately
/// so for anyone with a motor impairment or simply larger fingers.
///
/// The *visual* icon stays smaller; only the tappable area is padded out
/// to this. Guaranteeing it here means a consumer cannot accidentally
/// ship an untappable toolbar by choosing a tidy-looking icon size.
const double kMinimumTouchTarget = 48;

/// An icon button with a caption, sized to a guaranteed touch target.
///
/// The label is not decoration. Icons for crop, straighten, mirror and
/// perspective are not self-evident, and a caption is what makes a
/// toolbar usable by someone who has not memorised them — which is the
/// pattern Google Photos and the Pixel camera both follow.
class D3ToolButton extends StatelessWidget {
  const D3ToolButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.selected = false,
    this.destructive = false,
  });

  final IconData icon;

  /// Shown beneath the icon. Keep it to one or two words — this sits in
  /// a scrolling row, and a long caption pushes neighbours off-screen.
  final String label;

  final VoidCallback? onPressed;
  final bool selected;

  /// Tints the control to signal an irreversible-feeling action, such as
  /// deleting the current selection.
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    final color = !enabled
        ? Colors.white24
        : destructive
        ? Colors.redAccent
        : selected
        ? Colors.amber
        : Colors.white70;

    return Semantics(
      button: true,
      enabled: enabled,
      selected: selected,
      label: label,
      // The caption is already the control's semantic name, so exclude
      // the Text beneath -- otherwise a screen reader announces it
      // twice ("Rotate, Rotate").
      excludeSemantics: true,
      // ExcludeSemantics covers the InkWell too, not just the caption:
      // InkWell publishes its own enabled/tappable node, which would
      // otherwise win over the Semantics above and leave a disabled
      // button announcing itself as tappable to a screen reader.
      child: ExcludeSemantics(
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(12),
          child: ConstrainedBox(
            // The whole control, caption included, is the touch target --
            // so the label adds to the tappable area rather than sitting
            // outside it as dead space.
            constraints: const BoxConstraints(
              minWidth: kMinimumTouchTarget,
              minHeight: kMinimumTouchTarget,
            ),
            child: Padding(
              // Generous horizontal padding so even a short caption
              // ("Crop", "Reset") clears 48dp of width. The
              // ConstrainedBox sets the floor, but content narrower than
              // it only just reaches it -- measured 46dp on a real
              // device before this was widened.
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, color: color, size: 22),
                  const SizedBox(height: 4),
                  Text(
                    label,
                    style: TextStyle(color: color, fontSize: 11),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A horizontally scrolling row of [D3ToolButton]s.
///
/// Scrolls rather than wraps or shrinks: shrinking would break the
/// touch-target guarantee, and wrapping makes the toolbar's height jump
/// as tools are added or filtered.
class D3ToolBar extends StatelessWidget {
  const D3ToolBar({super.key, required this.children, this.padding});

  final List<Widget> children;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding:
          padding ?? const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final child in children)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: child,
            ),
        ],
      ),
    );
  }
}

/// A segmented control that chooses which group of tools is shown.
///
/// Grouping keeps the tool row short enough to read at a glance instead
/// of forcing the user to scroll a long undifferentiated list — the
/// Pixel camera's Auto / Crop / Adjust arrangement.
class D3ToolGroupBar<T> extends StatelessWidget {
  const D3ToolGroupBar({
    super.key,
    required this.groups,
    required this.selected,
    required this.onSelected,
  });

  /// Group value to its caption, in display order.
  final Map<T, String> groups;
  final T selected;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final entry in groups.entries)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Semantics(
                button: true,
                selected: entry.key == selected,
                child: InkWell(
                  onTap: () => onSelected(entry.key),
                  borderRadius: BorderRadius.circular(20),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      minHeight: kMinimumTouchTarget,
                      minWidth: 64,
                    ),
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: entry.key == selected
                                ? Colors.white70
                                : Colors.transparent,
                          ),
                        ),
                        child: Text(
                          entry.value,
                          style: TextStyle(
                            color: entry.key == selected
                                ? Colors.white
                                : Colors.white54,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A close affordance for the annotator, sized like every other control
/// here.
///
/// An editing surface needs a visible way out. Relying on the system
/// back gesture alone is a poor default: it is invisible, it is not
/// available on every platform this package's Dart API is meant to
/// reach, and on a screen that has just taught the user to drag things
/// around, a swipe is an ambiguous way to say "I am finished".
class D3CloseButton extends StatelessWidget {
  const D3CloseButton({
    super.key,
    required this.onPressed,
    this.tooltip = 'Close',
  });

  final VoidCallback? onPressed;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return D3FloatingButton(
      icon: Icons.close,
      tooltip: tooltip,
      color: Colors.white,
      onPressed: onPressed,
    );
  }
}

/// Undo / redo / clear, sized for a top bar.
///
/// These live apart from the tool groups on purpose. Undo is a safety
/// control, not a tool: if reaching it means switching groups first, a
/// mistake stays on screen while the user hunts for the fix. Tools are
/// things you choose between; history is something you always want at
/// hand. The Pixel camera keeps them separate for the same reason.
///
/// Targets meet [kMinimumTouchTarget] like every other control here.
class D3HistoryBar extends StatelessWidget {
  const D3HistoryBar({
    super.key,
    required this.controller,
    this.foregroundColor = Colors.white70,
  });

  final AnnotationController controller;
  final Color foregroundColor;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        // The floating × (WORK-0035) now owns "delete the selected
        // shape" -- one control per action, not two doing the same
        // thing in two places. This button keeps only its "clear
        // everything, nothing selected" half, and disables rather than
        // relabels itself while something is selected, since deleting
        // that selection is no longer a thing this button does at all.
        final hasSelection = controller.selectedId != null;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            D3FloatingButton(
              icon: Icons.undo,
              tooltip: 'Undo',
              color: foregroundColor,
              onPressed: controller.canUndo ? controller.undo : null,
            ),
            D3FloatingButton(
              icon: Icons.redo,
              tooltip: 'Redo',
              color: foregroundColor,
              onPressed: controller.canRedo ? controller.redo : null,
            ),
            D3FloatingButton(
              icon: Icons.delete_outline,
              tooltip: 'Clear all',
              color: foregroundColor,
              onPressed: controller.isEmpty || hasSelection
                  ? null
                  : controller.clear,
            ),
          ],
        );
      },
    );
  }
}

/// A circular icon-only button, sized to a guaranteed touch target, with
/// no caption.
///
/// The undo/redo/clear/close icons here are self-evident (a familiar
/// system glyph, or one used only once so there is nothing to confuse
/// it with) in a way crop/straighten/mirror are not — that is what
/// [D3ToolButton]'s caption exists for, and why this stays uncaptioned
/// rather than duplicating that pattern.
///
/// Also used for floating shape controls (WORK-0035): a delete/duplicate
/// icon sitting directly on a small selected shape has no room for a
/// label either, and the same "obvious from the icon alone" reasoning
/// applies to a × or a +1.
///
/// The icon sits on a translucent dark disc, not directly on whatever is
/// behind it -- found necessary on-device: a white icon (the default
/// duplicate color) drawn straight onto a light or white photo was all
/// but invisible with no backdrop of its own.
class D3FloatingButton extends StatelessWidget {
  const D3FloatingButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.color,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final Color color;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: onPressed != null,
      label: tooltip,
      excludeSemantics: true,
      child: Tooltip(
        message: tooltip,
        child: InkWell(
          onTap: onPressed,
          customBorder: const CircleBorder(),
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minWidth: kMinimumTouchTarget,
              minHeight: kMinimumTouchTarget,
            ),
            child: Center(
              child: SizedBox(
                width: kMinimumTouchTarget * 0.6,
                height: kMinimumTouchTarget * 0.6,
                child: DecoratedBox(
                  decoration: const BoxDecoration(
                    color: Color(0x99000000),
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: Icon(
                      icon,
                      color: onPressed == null ? Colors.white24 : color,
                      size: 22,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The colour swatches [D3RestyleBar] offers.
///
/// A fixed, small palette rather than a full colour picker: annotations
/// are marks meant to stand out against a photo, and a handful of
/// distinct, high-contrast colours serves that better than the paradox
/// of choice a full wheel would add to what is meant to be a quick,
/// glanceable bar.
const List<Color> kRestyleColors = [
  Color(0xFFFF3B30), // red -- AnnotationStyle's own default
  Color(0xFFFFCC00), // yellow
  Color(0xFF34C759), // green
  Color(0xFF007AFF), // blue
  Color(0xFFFFFFFF), // white
];

/// Stroke widths [D3RestyleBar] offers, as fractions of the image's
/// shorter side -- see [AnnotationStyle.strokeWidth].
const List<double> kRestyleStrokeWidths = [0.0025, 0.005, 0.01];

/// Font sizes [D3RestyleBar] offers for [TextAnnotation]s, as fractions
/// of the image's shorter side -- see [AnnotationStyle.fontSize]
/// (WORK-0034).
const List<double> kRestyleFontSizes = [0.02, 0.03, 0.05];

/// Background-colour choices [D3RestyleBar] offers for [TextAnnotation]s
/// -- the first entry (null) is "no background", matching
/// [AnnotationStyle.backgroundColor]'s own default.
const List<Color?> kRestyleTextBackgrounds = [
  null,
  Color(0x99000000),
  Color(0x99FFFFFF),
];

/// Border widths [D3RestyleBar] offers for [TextAnnotation]s, as
/// fractions of the image's shorter side -- see
/// [AnnotationStyle.borderWidth]. The first entry (0) is "no border",
/// [AnnotationStyle]'s own default -- the same "zero is off" convention
/// [AnnotationStyle.borderWidth] itself uses, rather than a separate
/// visibility toggle.
const List<double> kRestyleBorderWidths = [0.0, 0.0025, 0.005, 0.01];

/// Border-radius choices [D3RestyleBar] offers for [TextAnnotation]s, as
/// fractions of the image's shorter side -- see
/// [AnnotationStyle.borderRadius]. The first entry (0) is a square
/// corner.
const List<double> kRestyleBorderRadii = [0.0, 0.008, 0.02];

/// Colour, stroke-width, and fill controls for the selected annotation
/// (WORK-0035).
///
/// A bar, not floating controls: a colour/stroke/fill palette needs real
/// space that floating icons near a small shape cannot give without
/// covering it, unlike the single-icon ×/+1 controls -- decided in
/// WORK-0035's Decision section, not an oversight that the two controls
/// live in different places.
///
/// Shown only while something is selected; the caller (typically
/// `D3AnnotatorScreen`) is responsible for that condition, the same way
/// it already gates the crop bar.
class D3RestyleBar extends StatelessWidget {
  const D3RestyleBar({
    super.key,
    required this.controller,
    required this.selected,
  });

  final AnnotationController controller;

  /// The annotation this bar edits. Passed explicitly rather than read
  /// from `controller.selected` internally so a caller that has already
  /// fetched it (to decide whether to show this bar at all) does not
  /// have to fetch it twice, and so this widget has no way to render
  /// with a stale idea of which annotation it is editing.
  final Annotation selected;

  /// Fill has no meaning for a shape with no interior -- honouring it
  /// would either do nothing (arrows are always stroked, per
  /// `annotation_painter.dart`) or silently vanish a freehand stroke
  /// behind a fill that was never drawn. Text's analogous concept is
  /// its own `backgroundColor` control below, not this one.
  bool get _supportsFill =>
      selected is RectangleAnnotation || selected is CircleAnnotation;

  /// Stroke width means nothing for text -- it has no stroke, only a
  /// font size (WORK-0034).
  bool get _isText => selected is TextAnnotation;

  void _apply(AnnotationStyle style) {
    controller.update(selected.id, selected.copyWithStyle(style));
  }

  void _applyImageTransform(ImageTransform transform) {
    final image = selected;
    if (image is ImageAnnotation) {
      controller.update(image.id, image.copyWith(imageTransform: transform));
    }
  }

  @override
  Widget build(BuildContext context) {
    final style = selected.style;
    final image = selected;
    // Scrolls rather than wraps or shrinks, same reasoning as
    // D3ToolBar: a text annotation's row (colour + font size +
    // background swatches) is long enough on a narrow phone to overflow
    // a fixed-width row, and shrinking the swatches would break their
    // touch-target guarantee.
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SizedBox(
        height: kMinimumTouchTarget,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: image is ImageAnnotation
              ? _imageControls(image)
              : [
                  for (final color in kRestyleColors)
                    _ColorSwatch(
                      color: color,
                      selected: style.color.toARGB32() == color.toARGB32(),
                      onTap: () => _apply(style.copyWith(color: color)),
                    ),
                  if (_isText) ...[
                    const _GroupDivider(),
                    for (final fontSize in kRestyleFontSizes)
                      _FontSizeSwatch(
                        fontSize: fontSize,
                        selected: style.fontSize == fontSize,
                        onTap: () =>
                            _apply(style.copyWith(fontSize: fontSize)),
                      ),
                    const _GroupDivider(),
                    for (final background in kRestyleTextBackgrounds)
                      _TextBackgroundSwatch(
                        color: background,
                        selected:
                            style.backgroundColor?.toARGB32() ==
                            background?.toARGB32(),
                        onTap: () => _apply(
                          background == null
                              ? style.copyWith(clearBackgroundColor: true)
                              : style.copyWith(backgroundColor: background),
                        ),
                      ),
                    const _GroupDivider(),
                    for (final borderWidth in kRestyleBorderWidths)
                      _BorderWidthSwatch(
                        borderWidth: borderWidth,
                        selected: style.borderWidth == borderWidth,
                        onTap: () =>
                            _apply(style.copyWith(borderWidth: borderWidth)),
                      ),
                    // Meaningless while there is no border to round --
                    // shown only once one is chosen, the same
                    // conditional-on-a-prerequisite pattern _supportsFill
                    // already uses for its own group below.
                    if (style.borderWidth > 0) ...[
                      const _GroupDivider(),
                      for (final borderRadius in kRestyleBorderRadii)
                        _BorderRadiusSwatch(
                          borderRadius: borderRadius,
                          selected: style.borderRadius == borderRadius,
                          onTap: () => _apply(
                            style.copyWith(borderRadius: borderRadius),
                          ),
                        ),
                    ],
                  ] else ...[
                    const _GroupDivider(),
                    for (final width in kRestyleStrokeWidths)
                      _StrokeWidthSwatch(
                        strokeWidth: width,
                        selected: style.strokeWidth == width,
                        onTap: () =>
                            _apply(style.copyWith(strokeWidth: width)),
                      ),
                    if (_supportsFill) ...[
                      const _GroupDivider(),
                      _FillToggle(
                        filled: style.filled,
                        onTap: () =>
                            _apply(style.copyWith(filled: !style.filled)),
                      ),
                    ],
                  ],
                ],
        ),
      ),
    );
  }

  /// Controls for an [ImageAnnotation]'s own crop/mirror -- deliberately
  /// distinct from the document-level Adjust toolbar (WORK-0026) both
  /// visually (this row, not that toolbar) and functionally (mutates
  /// only this annotation's `imageTransform`, never
  /// `AnnotationController.transform`), so the user cannot mistake
  /// "crop this picture" for "crop the whole canvas" (WORK-0037's
  /// decision). No colour/stroke/fill controls apply to an image the
  /// way they do to a drawn shape.
  List<Widget> _imageControls(ImageAnnotation image) {
    final transform = image.imageTransform;
    return [
      _ImageAdjustButton(
        icon: Icons.rotate_90_degrees_cw,
        tooltip: 'Rotate image',
        onTap: () =>
            _applyImageTransform(transform.rotatedClockwise()),
      ),
      _ImageAdjustButton(
        icon: Icons.flip,
        tooltip: 'Mirror image',
        selected: transform.mirrored,
        onTap: () =>
            _applyImageTransform(transform.withMirrored(!transform.mirrored)),
      ),
      _ImageAdjustButton(
        icon: Icons.crop_free,
        tooltip: 'Reset image adjustments',
        onTap: transform.isIdentity
            ? null
            : () => _applyImageTransform(ImageTransform.identity),
      ),
    ];
  }
}

class _ColorSwatch extends StatelessWidget {
  const _ColorSwatch({
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: 'Color',
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minWidth: kMinimumTouchTarget,
            minHeight: kMinimumTouchTarget,
          ),
          child: Center(
            child: Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected ? Colors.white : Colors.white38,
                  width: selected ? 2.5 : 1,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A thin vertical rule separating one control group from the next (e.g.
/// colour from stroke width, stroke width from fill) -- found necessary
/// on-device (bug report during WORK-0037 functional testing): an
/// undifferentiated row of same-sized dots gave a first-time user no way
/// to tell "these five are colours" from "these three are something
/// else" without trial and error. Purely visual, so it carries no
/// semantics of its own.
class _GroupDivider extends StatelessWidget {
  const _GroupDivider();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 4, vertical: 12),
      child: VerticalDivider(width: 1, color: Colors.white24),
    );
  }
}

/// Shared look for a selectable icon-based swatch: an outlined circle
/// that fills solid and gains an amber ring when selected, framing
/// [child] (a weight-scaled line, an "A" glyph, or the like). Replaces
/// the earlier bare, uniformly-coloured dot -- amber/white70 read as an
/// arbitrary colour choice unrelated to the actual colour swatches
/// above them, not as "selected" (found on-device, same report as
/// [_GroupDivider]'s).
class _IconSwatch extends StatelessWidget {
  const _IconSwatch({
    required this.selected,
    required this.onTap,
    required this.label,
    required this.child,
  });

  final bool selected;
  final VoidCallback onTap;
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      excludeSemantics: true,
      child: Tooltip(
        message: label,
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minWidth: kMinimumTouchTarget,
              minHeight: kMinimumTouchTarget,
            ),
            child: Center(
              child: SizedBox(
                width: 32,
                height: 32,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: selected
                        ? Colors.amber.withValues(alpha: 0.25)
                        : Colors.transparent,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: selected ? Colors.amber : Colors.white38,
                      width: selected ? 2 : 1,
                    ),
                  ),
                  child: Center(child: child),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One stroke-width choice: a horizontal line drawn at its actual
/// relative weight, so the effect is legible at a glance rather than an
/// abstract dot size the user must learn to compare -- self-evident the
/// way a word processor's line-weight picker is, addressing the same
/// on-device report as [_GroupDivider]'s ("not user friendly especially
/// [for] those using the app the first time").
class _StrokeWidthSwatch extends StatelessWidget {
  const _StrokeWidthSwatch({
    required this.strokeWidth,
    required this.selected,
    required this.onTap,
  });

  final double strokeWidth;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _IconSwatch(
      selected: selected,
      onTap: onTap,
      label: 'Stroke width',
      child: Container(
        width: 18,
        height: (strokeWidth * 800).clamp(2.0, 10.0),
        decoration: BoxDecoration(
          color: selected ? Colors.amber : Colors.white70,
          borderRadius: BorderRadius.circular(4),
        ),
      ),
    );
  }
}

/// One font-size choice: a capital "A" drawn at a size proportional to
/// the actual choice, the same "show, don't make the user compare
/// numbers" reasoning as [_StrokeWidthSwatch].
class _FontSizeSwatch extends StatelessWidget {
  const _FontSizeSwatch({
    required this.fontSize,
    required this.selected,
    required this.onTap,
  });

  final double fontSize;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _IconSwatch(
      selected: selected,
      onTap: onTap,
      label: 'Font size',
      child: Text(
        'A',
        style: TextStyle(
          fontSize: 10 + fontSize * 250,
          height: 1,
          fontWeight: FontWeight.w600,
          color: selected ? Colors.amber : Colors.white70,
        ),
      ),
    );
  }
}

/// One border-width choice for a [TextAnnotation]'s box (see
/// `AnnotationStyle.borderWidth`'s own doc comment for why this exists):
/// a square outline drawn at its actual relative weight, or a slashed
/// square for zero -- "no border" reads as a deliberate option, not a
/// missing one, the same convention [_TextBackgroundSwatch] already
/// uses for "no background".
class _BorderWidthSwatch extends StatelessWidget {
  const _BorderWidthSwatch({
    required this.borderWidth,
    required this.selected,
    required this.onTap,
  });

  final double borderWidth;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? Colors.amber : Colors.white70;
    return _IconSwatch(
      selected: selected,
      onTap: onTap,
      label: 'Border width',
      child: borderWidth <= 0
          ? Icon(Icons.block, color: color, size: 16)
          : Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                border: Border.all(
                  color: color,
                  width: (borderWidth * 800).clamp(1.0, 6.0),
                ),
              ),
            ),
    );
  }
}

/// One border-radius choice for a [TextAnnotation]'s box: a square
/// drawn with its actual corner rounding, the same "show, don't make
/// the user compare numbers" reasoning as [_StrokeWidthSwatch].
class _BorderRadiusSwatch extends StatelessWidget {
  const _BorderRadiusSwatch({
    required this.borderRadius,
    required this.selected,
    required this.onTap,
  });

  final double borderRadius;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? Colors.amber : Colors.white70;
    return _IconSwatch(
      selected: selected,
      onTap: onTap,
      label: 'Border radius',
      child: Container(
        width: 20,
        height: 20,
        decoration: BoxDecoration(
          border: Border.all(color: color, width: 2),
          borderRadius: BorderRadius.circular((borderRadius * 500).clamp(0.0, 10.0)),
        ),
      ),
    );
  }
}

class _FillToggle extends StatelessWidget {
  const _FillToggle({required this.filled, required this.onTap});

  final bool filled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: filled,
      label: 'Fill',
      excludeSemantics: true,
      child: Tooltip(
        message: filled ? 'Filled' : 'Outline only',
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minWidth: kMinimumTouchTarget,
              minHeight: kMinimumTouchTarget,
            ),
            child: Icon(
              filled ? Icons.square : Icons.square_outlined,
              color: filled ? Colors.amber : Colors.white70,
              size: 22,
            ),
          ),
        ),
      ),
    );
  }
}

/// One control in an [ImageAnnotation]'s own crop/mirror row
/// (WORK-0037) -- rotate, mirror, or reset that annotation's
/// `imageTransform`, distinct from the document-level Adjust toolbar.
class _ImageAdjustButton extends StatelessWidget {
  const _ImageAdjustButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.selected = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Semantics(
      button: true,
      enabled: enabled,
      selected: selected,
      label: tooltip,
      excludeSemantics: true,
      child: Tooltip(
        message: tooltip,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minWidth: kMinimumTouchTarget,
              minHeight: kMinimumTouchTarget,
            ),
            child: Icon(
              icon,
              color: !enabled
                  ? Colors.white24
                  : selected
                  ? Colors.amber
                  : Colors.white70,
              size: 22,
            ),
          ),
        ),
      ),
    );
  }
}

/// One background-colour choice for a [TextAnnotation] (WORK-0034).
/// [color] null means "no background", drawn as a slashed circle rather
/// than an empty swatch so "this clears it" reads as a deliberate
/// option, not a missing one.
class _TextBackgroundSwatch extends StatelessWidget {
  const _TextBackgroundSwatch({
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final Color? color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: 'Text background',
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minWidth: kMinimumTouchTarget,
            minHeight: kMinimumTouchTarget,
          ),
          child: Center(
            child: Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color: color ?? Colors.transparent,
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected ? Colors.amber : Colors.white38,
                  width: selected ? 2.5 : 1,
                ),
              ),
              child: color == null
                  ? const Icon(Icons.block, color: Colors.white54, size: 16)
                  : null,
            ),
          ),
        ),
      ),
    );
  }
}
