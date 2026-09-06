# Device benchmarks

Measurements, not assertions. These files record *how* the numbers in
WORK-0023, WORK-0027, WORK-0030 and WORK-0031 were obtained, so a later
change can re-run them rather than trusting a figure in a document. They
mostly print rather than assert — a benchmark that fails CI on a slower
machine would be noise.

Most of this directory is about the render pipeline (WORK-0027/0030/
0031, below). `freehand_worst_case_test.dart` is a separate question —
annotation paint/hit-test/serialisation cost — that happens to live
alongside the render benchmarks rather than in its own directory,
grouped here because it shares the "measure on device, don't guess"
convention rather than any code with the rest of this folder.

Run one against a connected device:

```
flutter test integration_test/benchmarks/render_breakdown_test.dart -d <device-id>
```

They must run on hardware. A host-VM widget test has no real GPU, no
device memory limit, and no frame pipeline to jank, so it would measure
nothing about a phone.

## What each answers

| File | Question | Answer |
|---|---|---|
| `render_breakdown_test.dart` | Which stage costs the 648 ms? | PNG encoding, 541 ms. Compositing is 26 ms |
| `isolate_encode_test.dart` | Can encoding leave the root isolate? | Yes. Worst frame 682 → 175 ms |
| `transfer_cost_test.dart` | What is the residual, and can it go? | `toByteData(rawRgba)`, ~60 ms, cannot move. Transfer beats copy 18 vs 33 ms |
| `codec_options_test.dart` | Would JPEG or a lower PNG level be better? | No to both. JPEG is 2× slower in pure Dart; level 3 is 24% larger |
| `threshold_test.dart` | Where does the isolate stop paying for itself, on plain content? | Engine leads up to ~9MP on a flat gradient |
| `threshold_realistic_test.dart` | Same question, on content shaped like what this package actually renders | Engine leads up to ~9MP here too; isolate only wins at full 12MP. Threshold set at 2000px — see below |
| `reused_worker_test.dart` | Does a reused isolate worker beat `Isolate.run` per image, for a batch? | Yes, ~7–9% for a batch of ten. Modest, not dramatic — spawn cost measured at only 5–8 ms |
| `freehand_worst_case_test.dart` | Does dense freehand markup cost anything worth simplifying for? | No. 1.3–3.5 ms paint and 190–930 µs hit-test from 8,000 to 40,000 points, both negligible against a frame budget — see below |

`../batch_render_test.dart` (one level up, not in this directory since
it exercises the public batch API rather than an internal choice)
confirms two WORK-0031 device claims: progress genuinely advances across
pumped frames rather than jumping straight to the end, and a batch of
ten never holds more than one result at a time.

## Baseline, Pixel 10 (Android 17), 12MP source

| stage | full resolution | bounded default |
|---|---|---|
| decode source | 81 ms | 79 ms |
| record canvas | 2 ms | — |
| rasterize | 24 ms | 6 ms |
| encode PNG | 541 ms | 160 ms |
| peak decoded RGBA | 91.6 MB | 57.2 MB |

Worst frame during a full-resolution render: **682 ms** blocking,
**134 ms** with encoding moved to an isolate (initial prototype). After
shipping the split in `render_annotated_image.dart` and re-measuring
against the real code path: **57–68 ms**, at or below the 39–73 ms
baseline of an idle spinner. The ~100 ms floor from the prototype
measurement did not fully materialize in the shipped version — encoding
moving off-isolate removed essentially all of the jank, not just most
of it. The residual `toByteData(rawRgba)` cost is real but apparently
small enough on this device not to dominate a frame.

## Threshold: why 2000px, not somewhere between the measured points

`threshold_test.dart` (flat gradient) and `threshold_realistic_test.dart`
(bands + circles, scaled to size — closer to a real annotated photo) both
swept six sizes from 800×600 to 4000×3000, comparing root-isolate
encoding against the background-isolate path. Both found the same
shape: the background isolate has a fixed cost (~50 ms, visible clearly
at small sizes) that a wall-clock comparison shows losing to plain
root-isolate encoding at every size up to ~9MP, and only winning once
the encode itself is large enough to outweigh that fixed cost — reached
in this sweep only at full 12MP. Reproduced twice on the realistic
content.

This means "faster" is not the right test for where to place the
threshold: below the crossover, the isolate is a throughput *loss*, not
just an unneeded precaution. The threshold used in
`render_annotated_image.dart` is `kAsyncEncodeThresholdPixels = 2000`
— `RenderOptions.maxDimension`'s own default — rather than a value
between the measured points, so the two most common outcomes stay easy
to reason about: the bounded default always encodes on the root
isolate (faster there anyway), and asking for more always moves to the
background isolate (faster there too, and where the jank was worst).

## Reused worker: modest, not dramatic

Four runs comparing `Isolate.run` per image against one worker sent N
jobs over a `SendPort`, batch of ten, 12MP-content encode jobs: reused
worker 4468–4565 ms, independent calls 4892–4894 ms (each series' first
run discarded as JIT/cache warm-up — consistently the outlier in both).
A ~7–9% win, not the "pays a spawn on every image" framing WORK-0031's
Decision section originally worried about before this was measured;
isolate spawn itself is only 5–8 ms here. Chosen anyway: never slower in
any run, and it removes the concern from the design rather than leaving
it as an accepted cost.

## Freehand markup: measured negligible, don't simplify (WORK-0023)

A worst-case page — 20 freehand strokes at 400 points each (8,000
total, already past the "several thousand" this item's problem
statement names) plus 15 other shapes — exercised the real
`paintAnnotations` and `hitTestAnnotations` functions, not a
reimplementation of their logic. Repeated at 5× the point count
(40,000) to check for a nonlinearity the primary scale wouldn't reveal:

| | 8,000 points | 40,000 points |
|---|---|---|
| paint (one full repaint) | 1.3–1.5 ms | 3.3–3.5 ms |
| hit-test (a miss, the real worst case) | 190–240 µs | 830–930 µs |

Roughly linear, and two orders of magnitude under a 16.7 ms frame
budget even at 5×. **Simplifying stroke points (e.g. Ramer–Douglas–
Peucker) would trade fidelity for a cost that isn't there.**

Two things worth separating from that headline result:

- **The problem statement's own premise was outdated.** It assumed raw
  120Hz pointer sampling; `annotation_overlay_widget.dart` has applied
  a minimum-step filter during drawing (`_freehandMinStep = 0.002`
  normalized units) since the annotator's first commit, predating this
  item. The real worst case is bounded by path length divided by that
  step, not by how long a finger stays down.
- **Serialisation is a different question with a different answer.**
  The 8,000-point page encodes to 371.5 KB — 47.5 bytes/point, because
  `annotation_codec.dart` encodes each point as `{"x":…,"y":…}` rather
  than a flat array. A flat encoding would cut that by an estimated
  ~42% with *zero* fidelity loss, unlike point simplification. Recorded
  as a separate follow-up rather than folded in here, since it needs a
  schema-version bump (WORK-0029) this item was never scoped to make.

A bug was also found and fixed in the benchmark itself before it ever
reached the device: the synthetic-stroke generator could clamp two
coordinates at a boundary simultaneously, producing zero forward
progress and hanging. Caught on the host VM; fixed with edge-reflection
instead of clamping, plus a hard iteration cap so any future stall in
the generator fails fast instead of hanging silently again.

## The `image` dependency

Adopted as the package's first third-party dependency in WORK-0030,
after these benchmarks established encoding — not compositing — as the
cost worth moving, and that pure-Dart PNG in an isolate is not worse
than the engine's own encoder at the size where it matters (12MP:
423–473 ms isolate vs. 569–572 ms engine). Used only inside
`render_annotated_image.dart`'s `_encodePngOffIsolate`; nothing else in
the package depends on it.
