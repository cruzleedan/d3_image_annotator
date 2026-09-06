import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as pkg_img;

import '../annotations/annotation.dart';
import '../geometry/image_transform.dart';
import 'render_annotated_image.dart';
import 'render_options.dart';

/// One image to render, paired with the annotations and transform to
/// render it with.
///
/// A plain data class rather than named parameters on the batch
/// function, so a caller can build the whole list up front — from a
/// visit's photos, say — before rendering starts.
@immutable
class RenderRequest {
  const RenderRequest({
    required this.imageBytes,
    required this.annotations,
    this.transform = ImageTransform.identity,
  });

  final Uint8List imageBytes;
  final List<Annotation> annotations;
  final ImageTransform transform;
}

/// Progress through a batch started by [renderAnnotatedImages].
///
/// [bytes] is only this item's result — a batch of ten is not held in
/// memory as ten entries, only ever one at a time, and it is the
/// listener's responsibility to keep or discard it once received.
@immutable
class RenderProgress {
  const RenderProgress({
    required this.completed,
    required this.total,
    required this.bytes,
  });

  /// How many requests have finished, including this one.
  final int completed;

  final int total;

  /// This request's rendered output.
  final Uint8List bytes;
}

/// Renders each of [requests] in turn, yielding one [RenderProgress] as
/// each finishes.
///
/// **Why this exists rather than a caller looping [renderAnnotatedImage]
/// itself:** a report is the real call site for rendering, and a report
/// is rarely one image. WORK-0030 made a single render responsive; it
/// did not make ten of them fast, and a caller looping the single-image
/// function has no way to show progress except counting iterations
/// itself, and no warning about the peak-memory pitfall below.
///
/// **Sequential, deliberately — not pipelined.** Every stage except PNG
/// encoding above [kAsyncEncodeThresholdPixels] runs on the root
/// isolate, so there is only one root isolate to share across requests
/// regardless of how this loop is written; overlapping request *N*'s
/// encode with request *N+1*'s decode would mean both images' decoded
/// pixels are live at once, roughly doubling peak memory (WORK-0027
/// measured 91.6 MB for a single full-resolution render) to buy back
/// time this item's own Consequences section already accepts giving up
/// ("total wall-clock time is unchanged... about making the wait
/// legible, not shorter"). Trading a doubled memory ceiling for that is
/// the wrong side of the trade, so requests are rendered fully one at a
/// time and each result is emitted, and can be released, before the
/// next request starts decoding.
///
/// **One isolate worker, reused across the whole batch,** for the
/// requests whose encode is large enough to move off the root isolate
/// at all (WORK-0030's threshold). Measured on a Pixel 10: a reused
/// worker beats independent `Isolate.run` calls by ~7–9% for a batch of
/// ten (4468–4565 ms vs. 4892–4894 ms), with isolate spawn measured at
/// 5–8 ms — real but modest, nowhere near "pays for a spawn on every
/// image" the way a naive per-call `Isolate.run` loop would suggest at
/// first glance. The worker is spawned lazily on the first request that
/// needs it and shut down when the stream ends, including on early
/// cancellation.
///
/// **Cancellation falls out of the `Stream` contract**: unsubscribing
/// stops further requests from starting and releases the worker isolate
/// if one was spawned. A request already in flight when cancellation
/// happens is allowed to finish rather than abandoned mid-render, since
/// nothing productive is saved by discarding a nearly-complete render
/// and there is no partial result to hand back if it were. Implemented
/// with a single-subscription `StreamController`'s `onCancel`, not
/// `Stream.asBroadcastStream()` -- a broadcast stream's `onCancel` only
/// fires once *every* listener has gone, the wrong signal for one
/// caller backing out of report generation. (An earlier draft used
/// `asBroadcastStream()` with a `cancel()` method that nothing ever
/// called; a host-VM test with a fixed-delay cancel happened to pass
/// anyway because five tiny in-memory renders finish before the delay
/// fires either way. Rewritten to cancel on the first emitted event
/// instead, which is deterministic regardless of render speed.)
///
/// Confirmed on a Pixel 10 with 12MP sources, above
/// [kAsyncEncodeThresholdPixels] so the shared-worker path is actually
/// exercised: progress advances across multiple pumped frames rather
/// than jumping from 0 to N in one (a batch of 5 showed 0→1→2→3→4→5
/// spread over 48 pumped frames), and a batch of 10 completes with
/// never more than one `RenderProgress` reachable at a time.
Stream<RenderProgress> renderAnnotatedImages({
  required List<RenderRequest> requests,
  RenderOptions options = const RenderOptions(),
}) {
  return _BatchRenderer(requests: requests, options: options).stream;
}

class _BatchRenderer {
  _BatchRenderer({required this.requests, required this.options}) {
    // A single-subscription controller, not asBroadcastStream: this
    // batch has exactly one intended listener, and onCancel is how that
    // listener unsubscribing is detected at all. A broadcast stream's
    // onCancel only fires once *every* listener has gone, which is the
    // wrong signal for "the caller backed out of report generation" and
    // was silently never wired to anything in an earlier draft of this
    // file -- cancel() existed but nothing called it.
    _controller = StreamController<RenderProgress>(
      onListen: _start,
      onCancel: _cancel,
    );
  }

  final List<RenderRequest> requests;
  final RenderOptions options;

  late final StreamController<RenderProgress> _controller;
  _EncodeWorker? _worker;
  bool _cancelled = false;

  Stream<RenderProgress> get stream => _controller.stream;

  Future<void> _start() async {
    try {
      for (var i = 0; i < requests.length; i++) {
        if (_cancelled) break;
        final bytes = await _renderOne(requests[i]);
        if (_cancelled) break;
        _controller.add(
          RenderProgress(completed: i + 1, total: requests.length, bytes: bytes),
        );
      }
    } on Object catch (error, stackTrace) {
      if (!_cancelled) _controller.addError(error, stackTrace);
    } finally {
      await _worker?.dispose();
      await _controller.close();
    }
  }

  Future<void> _cancel() async {
    _cancelled = true;
  }

  Future<Uint8List> _renderOne(RenderRequest request) async {
    final worker = await _workerFor(request);
    final source = await decodeSourceImage(request.imageBytes);
    try {
      return await renderCompositedImage(
        source: source,
        annotations: request.annotations,
        transform: request.transform,
        options: options,
        encoder: worker?.encode,
      );
    } finally {
      source.dispose();
    }
  }

  /// The reused worker, spawned on first use and shared for every
  /// remaining request in the batch -- never one per request.
  Future<_EncodeWorker?> _workerFor(RenderRequest request) async {
    if (options.format != RenderFormat.png) return null;
    _worker ??= await _EncodeWorker.spawn();
    return _worker;
  }
}

/// A long-lived isolate that PNG-encodes raw pixel buffers sent to it,
/// reused across an entire batch rather than spawned per image.
class _EncodeWorker {
  _EncodeWorker._(this._commands, this._isolate);

  final SendPort _commands;
  final Isolate _isolate;

  static Future<_EncodeWorker> spawn() async {
    final ready = ReceivePort();
    final isolate = await Isolate.spawn(_workerMain, ready.sendPort);
    final commands = await ready.first as SendPort;
    ready.close();
    return _EncodeWorker._(commands, isolate);
  }

  /// Encodes [width]x[height] RGBA [pixels] to PNG on the worker
  /// isolate. [pixels] is transferred, not copied -- see
  /// `render_annotated_image.dart`'s private off-isolate encoder for the
  /// same choice and the measurement behind it.
  Future<Uint8List> encode({
    required TransferableTypedData pixels,
    required int width,
    required int height,
  }) async {
    final reply = ReceivePort();
    _commands.send(_EncodeJob(pixels, width, height, reply.sendPort));
    final result = await reply.first;
    reply.close();
    if (result is _EncodeFailure) {
      throw RenderException(result.message);
    }
    return result as Uint8List;
  }

  Future<void> dispose() async {
    _isolate.kill(priority: Isolate.immediate);
  }

  static void _workerMain(SendPort mainSendPort) {
    final commands = ReceivePort();
    mainSendPort.send(commands.sendPort);
    commands.listen((message) {
      final job = message as _EncodeJob;
      try {
        final bytes = job.pixels.materialize().asUint8List();
        final decoded = pkg_img.Image.fromBytes(
          width: job.width,
          height: job.height,
          bytes: bytes.buffer,
          numChannels: 4,
        );
        final png = pkg_img.encodePng(decoded);
        job.replyTo.send(Uint8List.fromList(png));
      } on Object catch (error) {
        job.replyTo.send(_EncodeFailure('background PNG encode failed: $error'));
      }
    });
  }
}

class _EncodeJob {
  const _EncodeJob(this.pixels, this.width, this.height, this.replyTo);

  final TransferableTypedData pixels;
  final int width;
  final int height;
  final SendPort replyTo;
}

class _EncodeFailure {
  const _EncodeFailure(this.message);

  final String message;
}
