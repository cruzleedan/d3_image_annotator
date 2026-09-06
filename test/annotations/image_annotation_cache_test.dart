import 'dart:async';
import 'dart:typed_data';

import 'package:d3_image_annotator/d3_image_annotator.dart';
import 'package:flutter_test/flutter_test.dart';

/// A 1x1 transparent PNG, so tests never touch the filesystem or
/// network. Only the lifecycle matters here, not the pixels.
final _pngBytes = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ImageAnnotationCache', () {
    test('a reference starts with no entry until request() is called', () {
      final cache = ImageAnnotationCache(
        resolver: (ref) async => _pngBytes,
      );
      addTearDown(cache.dispose);

      expect(cache.entryFor('a'), isNull);
    });

    test('request() transitions loading -> ready and notifies both times', () async {
      final cache = ImageAnnotationCache(
        resolver: (ref) async => _pngBytes,
      );
      addTearDown(cache.dispose);

      final states = <ImageAnnotationLoadState>[];
      cache.addListener(() {
        final entry = cache.entryFor('a');
        if (entry != null) states.add(entry.state);
      });

      cache.request('a');
      expect(cache.entryFor('a')!.state, ImageAnnotationLoadState.loading);

      await pumpEventQueue();

      expect(cache.entryFor('a')!.state, ImageAnnotationLoadState.ready);
      expect(cache.entryFor('a')!.image, isNotNull);
      expect(states, [
        ImageAnnotationLoadState.loading,
        ImageAnnotationLoadState.ready,
      ]);
    });

    test('a resolver failure lands in the failed state, not loading forever',
        () async {
      final cache = ImageAnnotationCache(
        resolver: (ref) async => throw Exception('boom'),
      );
      addTearDown(cache.dispose);

      cache.request('a');
      await pumpEventQueue();

      expect(cache.entryFor('a')!.state, ImageAnnotationLoadState.failed);
      expect(cache.entryFor('a')!.error, isNotNull);
      expect(cache.entryFor('a')!.image, isNull);
    });

    test('undecodable bytes also land in the failed state', () async {
      final cache = ImageAnnotationCache(
        resolver: (ref) async => Uint8List.fromList([1, 2, 3]),
      );
      addTearDown(cache.dispose);

      cache.request('a');
      await pumpEventQueue();

      expect(cache.entryFor('a')!.state, ImageAnnotationLoadState.failed);
    });

    test('request() is a no-op once a reference is already cached', () async {
      var calls = 0;
      final cache = ImageAnnotationCache(
        resolver: (ref) async {
          calls++;
          return _pngBytes;
        },
      );
      addTearDown(cache.dispose);

      cache.request('a');
      await pumpEventQueue();
      cache.request('a');
      cache.request('a');
      await pumpEventQueue();

      expect(calls, 1, reason: 'a cached reference must not re-resolve');
    });

    test('retry() re-attempts a failed reference', () async {
      var attempt = 0;
      final cache = ImageAnnotationCache(
        resolver: (ref) async {
          attempt++;
          if (attempt == 1) throw Exception('first attempt fails');
          return _pngBytes;
        },
      );
      addTearDown(cache.dispose);

      cache.request('a');
      await pumpEventQueue();
      expect(cache.entryFor('a')!.state, ImageAnnotationLoadState.failed);

      cache.retry('a');
      await pumpEventQueue();

      expect(cache.entryFor('a')!.state, ImageAnnotationLoadState.ready);
      expect(attempt, 2);
    });

    test('retry() is a no-op for a reference that is loading or ready', () async {
      var calls = 0;
      final completer = Completer<Uint8List>();
      final cache = ImageAnnotationCache(
        resolver: (ref) async {
          calls++;
          return completer.future;
        },
      );
      addTearDown(cache.dispose);

      cache.request('a');
      cache.retry('a');
      expect(calls, 1, reason: 'retry must not re-resolve a loading entry');

      completer.complete(_pngBytes);
      await pumpEventQueue();

      cache.retry('a');
      expect(calls, 1, reason: 'retry must not re-resolve a ready entry');
    });

    test('release() disposes the decoded image and drops the entry', () async {
      final cache = ImageAnnotationCache(
        resolver: (ref) async => _pngBytes,
      );
      addTearDown(cache.dispose);

      cache.request('a');
      await pumpEventQueue();
      final image = cache.entryFor('a')!.image!;

      cache.release('a');

      expect(cache.entryFor('a'), isNull);
      // A disposed ui.Image throws on further use -- confirm dispose was
      // actually called, not just the map entry cleared.
      expect(() => image.toByteData(), throwsA(anything));
    });

    test('dispose() releases every held image', () async {
      final cache = ImageAnnotationCache(resolver: (ref) async => _pngBytes);
      cache.request('a');
      cache.request('b');
      await pumpEventQueue();

      final imageA = cache.entryFor('a')!.image!;
      cache.dispose();

      expect(() => imageA.toByteData(), throwsA(anything));
    });

    test(
      'disposing while a decode is in flight does not throw when it '
      'completes',
      () async {
        final completer = Completer<Uint8List>();
        final cache = ImageAnnotationCache(
          resolver: (ref) => completer.future,
        );

        cache.request('a');
        cache.dispose();

        // The in-flight decode completes after dispose -- this must not
        // throw ("used a ChangeNotifier after dispose") the way a naive
        // implementation calling notifyListeners unconditionally would.
        completer.complete(_pngBytes);
        await pumpEventQueue();
      },
    );

    test('resolving two different references decodes independently',
        () async {
      final cache = ImageAnnotationCache(resolver: (ref) async => _pngBytes);
      addTearDown(cache.dispose);

      cache.request('a');
      cache.request('b');
      await pumpEventQueue();

      expect(cache.entryFor('a')!.state, ImageAnnotationLoadState.ready);
      expect(cache.entryFor('b')!.state, ImageAnnotationLoadState.ready);
      expect(
        cache.entryFor('a')!.image,
        isNot(same(cache.entryFor('b')!.image)),
      );
    });
  });
}
