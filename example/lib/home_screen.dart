import 'package:flutter/material.dart';

import 'demos/bare_viewer_demo.dart';
import 'demos/blank_canvas_demo.dart';
import 'demos/full_editor_demo.dart';
import 'demos/image_annotation_demo.dart';
import 'demos/save_restore_demo.dart';

/// One entry per demo screen, each showing a single feature area of the
/// package in isolation -- rather than one screen trying to switch
/// between all of them, which would mean every demo-specific control
/// (a "restore from JSON" button, a background-mode toggle) permanently
/// competing for the same layout.
class _Demo {
  const _Demo(this.title, this.subtitle, this.icon, this.builder);

  final String title;
  final String subtitle;
  final IconData icon;
  final WidgetBuilder builder;
}

final _demos = [
  _Demo(
    'Full editor on a photo',
    'D3AnnotatorScreen with every tool: shapes, arrows, freehand, text',
    Icons.image_outlined,
    (_) => const FullEditorDemo(),
  ),
  _Demo(
    'Blank canvas',
    'AnnotationBackground.color -- no photo, sketch on a plain fill',
    Icons.crop_square,
    (_) => const BlankCanvasDemo(),
  ),
  _Demo(
    'Image-as-annotation',
    'Place a second image as a movable, resizable, cropped annotation',
    Icons.add_photo_alternate_outlined,
    (_) => const ImageAnnotationDemo(),
  ),
  _Demo(
    'Bare viewer, custom UI',
    'D3ImageAnnotator with a hand-rolled toolbar, no package chrome',
    Icons.widgets_outlined,
    (_) => const BareViewerDemo(),
  ),
  _Demo(
    'Save & restore',
    'Round-trip annotations through JSON, and classify a size mismatch',
    Icons.save_outlined,
    (_) => const SaveRestoreDemo(),
  ),
];

class AnnotatorExampleApp extends StatelessWidget {
  const AnnotatorExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData.dark(),
      home: const _HomeScreen(),
    );
  }
}

class _HomeScreen extends StatelessWidget {
  const _HomeScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('d3_image_annotator')),
      body: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: _demos.length,
        separatorBuilder: (_, _) => const SizedBox(height: 12),
        itemBuilder: (context, index) {
          final demo = _demos[index];
          return Card(
            child: ListTile(
              leading: Icon(demo.icon),
              title: Text(demo.title),
              subtitle: Text(demo.subtitle),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: demo.builder),
              ),
            ),
          );
        },
      ),
    );
  }
}
