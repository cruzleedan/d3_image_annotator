import 'package:flutter/material.dart';

import '../annotations/annotation_controller.dart';
import '../annotations/annotation_tool.dart';
import '../coordinates/normalized_rect.dart';
import '../geometry/image_fit.dart';
import '../viewer/image_annotator.dart';
import 'tool_button.dart';

/// Which set of tools the bar is showing.
enum AnnotatorToolGroup {
  /// Shape tools and select.
  draw,

  /// Crop, rotate, mirror, reset.
  adjust,
}

/// A complete annotation screen: image, tools, history, and a way out.
///
/// This owns the chrome rather than leaving each consumer to assemble
/// it. The individual pieces ([D3ToolButton], [D3HistoryBar],
/// [D3CloseButton]) stay exported for anyone building something
/// different, but an app that just wants "let the user mark up this
/// photo" should not have to rediscover which controls belong where,
/// nor re-derive that undo has to sit outside the tool groups.
///
/// It still owns no `Scaffold`, `AppBar` or title — the bars here are
/// plain rows, so a host can place this inside its own page, a dialog,
/// or a sheet without inheriting a page structure it did not ask for.
class D3AnnotatorScreen extends StatefulWidget {
  const D3AnnotatorScreen({
    super.key,
    required this.image,
    required this.imageSize,
    required this.controller,
    this.onClose,
    this.onDone,
    this.doneLabel = 'Done',
    this.fit = ImageFit.contain,
    this.backgroundColor = Colors.black,
    this.initialTool = AnnotationTool.rectangle,
  });

  final ImageProvider image;
  final Size imageSize;
  final AnnotationController controller;

  /// Called when the user taps the close button.
  ///
  /// When null the screen pops its own route, so the common case needs
  /// no wiring. An editing surface needs a visible exit: the system
  /// back gesture is invisible, and on a screen that has just taught
  /// the user to drag things, a swipe is an ambiguous way to say "I am
  /// finished".
  final VoidCallback? onClose;

  /// Called when the user confirms. Omit to hide the action entirely —
  /// annotations live on the controller either way, so a host that
  /// watches it directly needs no button.
  final VoidCallback? onDone;

  final String doneLabel;
  final ImageFit fit;
  final Color backgroundColor;
  final AnnotationTool initialTool;

  @override
  State<D3AnnotatorScreen> createState() => _D3AnnotatorScreenState();
}

class _D3AnnotatorScreenState extends State<D3AnnotatorScreen> {
  late AnnotationTool _tool = widget.initialTool;
  late final TransformationController _zoom = TransformationController();

  AnnotatorToolGroup _group = AnnotatorToolGroup.draw;
  bool _cropping = false;
  NormalizedRect? _pendingCrop;

  @override
  void dispose() {
    _zoom.dispose();
    super.dispose();
  }

  void _close() {
    final onClose = widget.onClose;
    if (onClose != null) {
      onClose();
      return;
    }
    Navigator.maybePop(context);
  }

  @override
  Widget build(BuildContext context) {
    // Material, not ColoredBox: the controls use InkWell, which
    // requires a Material ancestor. Since this screen deliberately owns
    // no Scaffold, a host dropping it into a bare page would otherwise
    // hit "No Material widget found" -- so the widget provides its own
    // rather than making that the consumer's problem.
    return Material(
      color: widget.backgroundColor,
      child: SafeArea(
        child: Column(
          children: [
            _TopBar(
              controller: widget.controller,
              zoom: _zoom,
              onClose: _close,
              onDone: widget.onDone,
              doneLabel: widget.doneLabel,
            ),
            Expanded(
              child: D3ImageAnnotator(
                image: widget.image,
                imageSize: widget.imageSize,
                controller: widget.controller,
                tool: _tool,
                fit: widget.fit,
                backgroundColor: widget.backgroundColor,
                transformationController: _zoom,
                cropping: _cropping,
                onCropChanged: (rect) => _pendingCrop = rect,
              ),
            ),
            if (_cropping)
              _CropBar(
                onCancel: () => setState(() {
                  _cropping = false;
                  _pendingCrop = null;
                }),
                onApply: () => setState(() {
                  final rect = _pendingCrop;
                  if (rect != null) widget.controller.crop(rect);
                  _cropping = false;
                  _pendingCrop = null;
                }),
              )
            else
              _BottomBars(
                controller: widget.controller,
                tool: _tool,
                group: _group,
                onToolChanged: (t) => setState(() => _tool = t),
                onGroupChanged: (g) => setState(() => _group = g),
                onStartCrop: () => setState(() {
                  _cropping = true;
                  _pendingCrop = widget.controller.transform.effectiveCrop;
                }),
              ),
          ],
        ),
      ),
    );
  }
}

/// Close, history, and the optional confirm action.
///
/// History sits here rather than in a tool group because undo is a
/// safety control: needing to switch groups to reach it leaves the
/// mistake on screen while the user hunts for the fix.
class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.controller,
    required this.zoom,
    required this.onClose,
    required this.onDone,
    required this.doneLabel,
  });

  final AnnotationController controller;
  final TransformationController zoom;
  final VoidCallback onClose;
  final VoidCallback? onDone;
  final String doneLabel;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        D3CloseButton(onPressed: onClose),
        const Spacer(),
        D3HistoryBar(controller: controller),
        // Disabled at 1x, so it reads as "nothing to reset" rather than
        // as a control that does nothing.
        ValueListenableBuilder<Matrix4>(
          valueListenable: zoom,
          builder: (context, matrix, _) {
            final zoomed = matrix.getMaxScaleOnAxis() > 1.001;
            return IconButton(
              tooltip: 'Reset zoom',
              onPressed: zoomed ? () => zoom.value = Matrix4.identity() : null,
              color: Colors.white70,
              disabledColor: Colors.white24,
              icon: const Icon(Icons.zoom_out_map),
            );
          },
        ),
        if (onDone case final done?)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: TextButton(
              onPressed: done,
              style: TextButton.styleFrom(
                foregroundColor: Colors.amber,
                minimumSize: const Size(kMinimumTouchTarget, kMinimumTouchTarget),
              ),
              child: Text(doneLabel),
            ),
          ),
      ],
    );
  }
}

class _BottomBars extends StatelessWidget {
  const _BottomBars({
    required this.controller,
    required this.tool,
    required this.group,
    required this.onToolChanged,
    required this.onGroupChanged,
    required this.onStartCrop,
  });

  final AnnotationController controller;
  final AnnotationTool tool;
  final AnnotatorToolGroup group;
  final ValueChanged<AnnotationTool> onToolChanged;
  final ValueChanged<AnnotatorToolGroup> onGroupChanged;
  final VoidCallback onStartCrop;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            D3ToolBar(children: _tools()),
            D3ToolGroupBar<AnnotatorToolGroup>(
              groups: const {
                AnnotatorToolGroup.draw: 'Draw',
                AnnotatorToolGroup.adjust: 'Adjust',
              },
              selected: group,
              onSelected: onGroupChanged,
            ),
          ],
        );
      },
    );
  }

  List<Widget> _tools() => switch (group) {
    AnnotatorToolGroup.draw => [
      for (final t in AnnotationTool.values)
        D3ToolButton(
          icon: switch (t) {
            AnnotationTool.select => Icons.touch_app,
            AnnotationTool.rectangle => Icons.crop_square,
            AnnotationTool.circle => Icons.circle_outlined,
            AnnotationTool.arrow => Icons.arrow_outward,
            AnnotationTool.freehand => Icons.gesture,
          },
          label: switch (t) {
            AnnotationTool.select => 'Select',
            AnnotationTool.rectangle => 'Box',
            AnnotationTool.circle => 'Circle',
            AnnotationTool.arrow => 'Arrow',
            AnnotationTool.freehand => 'Draw',
          },
          selected: t == tool,
          onPressed: () => onToolChanged(t),
        ),
    ],
    AnnotatorToolGroup.adjust => [
      D3ToolButton(
        icon: Icons.crop,
        label: 'Crop',
        selected: controller.transform.cropRect != null,
        onPressed: onStartCrop,
      ),
      D3ToolButton(
        icon: Icons.rotate_90_degrees_cw,
        label: 'Rotate',
        onPressed: controller.rotateClockwise,
      ),
      D3ToolButton(
        icon: Icons.flip,
        label: 'Mirror',
        selected: controller.transform.mirrored,
        onPressed: controller.toggleMirror,
      ),
      D3ToolButton(
        icon: Icons.crop_free,
        label: 'Reset',
        onPressed: controller.transform.isIdentity
            ? null
            : controller.resetTransform,
      ),
    ],
  };
}

/// Confirm / cancel while cropping. Nothing is applied until confirmed,
/// so backing out leaves the image exactly as it was.
class _CropBar extends StatelessWidget {
  const _CropBar({required this.onCancel, required this.onApply});

  final VoidCallback onCancel;
  final VoidCallback onApply;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Drag the corners or the frame',
            style: TextStyle(color: Colors.white54, fontSize: 12),
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              TextButton.icon(
                onPressed: onCancel,
                icon: const Icon(Icons.close),
                label: const Text('Cancel'),
                style: TextButton.styleFrom(
                  foregroundColor: Colors.white70,
                  minimumSize: const Size(
                    kMinimumTouchTarget,
                    kMinimumTouchTarget,
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: onApply,
                icon: const Icon(Icons.check),
                label: const Text('Apply crop'),
                style: TextButton.styleFrom(
                  foregroundColor: Colors.amber,
                  minimumSize: const Size(
                    kMinimumTouchTarget,
                    kMinimumTouchTarget,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
