# Render benchmarks

Measurements, not assertions. These files record *how* the numbers in
WORK-0027, WORK-0030 and WORK-0031 were obtained, so a later change can
re-run them rather than trusting a figure in a document. They mostly
print rather than assert — a benchmark that fails CI on a slower machine
would be noise.

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

## Baseline, Pixel 10 (Android 17), 12MP source

| stage | full resolution | bounded default |
|---|---|---|
| decode source | 81 ms | 79 ms |
| record canvas | 2 ms | — |
| rasterize | 24 ms | 6 ms |
| encode PNG | 541 ms | 160 ms |
| peak decoded RGBA | 91.6 MB | 57.2 MB |

Worst frame during a full-resolution render: **682 ms** blocking,
**134 ms** with encoding moved to an isolate. The ~100 ms floor is
`toByteData(rawRgba)`, which is root-isolate only.

## Note on the `image` dependency

`image` is a dev-dependency of the *example* only, for these benchmarks.
Whether the package itself takes that dependency is WORK-0030's decision
to make, and should not be pre-empted by a measurement.
