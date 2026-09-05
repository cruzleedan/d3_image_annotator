import 'package:flutter/material.dart';

import '../annotations/annotation_controller.dart';

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
        final hasSelection = controller.selectedId != null;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _HistoryAction(
              icon: Icons.undo,
              tooltip: 'Undo',
              color: foregroundColor,
              onPressed: controller.canUndo ? controller.undo : null,
            ),
            _HistoryAction(
              icon: Icons.redo,
              tooltip: 'Redo',
              color: foregroundColor,
              onPressed: controller.canRedo ? controller.redo : null,
            ),
            // One control for both: removes the selection when there is
            // one, otherwise clears everything. The tooltip and tint say
            // which, so the difference is not hidden behind a guess.
            _HistoryAction(
              icon: hasSelection ? Icons.delete : Icons.delete_outline,
              tooltip: hasSelection ? 'Delete selected' : 'Clear all',
              color: hasSelection ? Colors.redAccent : foregroundColor,
              onPressed: controller.isEmpty
                  ? null
                  : () {
                      final id = controller.selectedId;
                      if (id != null) {
                        controller.remove(id);
                      } else {
                        controller.clear();
                      }
                    },
            ),
          ],
        );
      },
    );
  }
}

class _HistoryAction extends StatelessWidget {
  const _HistoryAction({
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
            child: Icon(
              icon,
              color: onPressed == null ? Colors.white24 : color,
              size: 22,
            ),
          ),
        ),
      ),
    );
  }
}
