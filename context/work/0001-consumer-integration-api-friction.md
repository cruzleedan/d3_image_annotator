---
id: 0001
title: "Resolve API friction found integrating into site_inspector before that integration starts"
status: proposed
kind: feature
opened: 2026-09-07
decided: ~
branch: ~
supersedes: ~
superseded-by: ~
---

# WORK-0001 — Resolve API friction found integrating into site_inspector before that integration starts

| | |
|---|---|
| **Opened** | 2026-09-07 |
| **Status** | proposed |
| **Kind** | feature |
| **Supersedes** | — |
| **Superseded by** | — |

## Problem

`d3_image_annotator` has never been wired into a real consumer app —
every feature so far has only been exercised by its own example app,
which proves each widget/function works in isolation but not that the
public API is pleasant (or sufficient) to integrate against a real app's
existing screens, persistence, and state management.

`site_inspector` (`context/work/0029-checklist-photo-annotation.md` in
that project) is the first real consumer: annotate a checklist photo,
store the annotations as editable JSON on the photo's own database row,
and flatten to pixels only on demand (PDF report embed, a standalone
"download annotated image" action) — never speculatively, never cached.
Working through that design against this package's *current* public API
surfaced four concrete points of friction before a single line of
`site_inspector` integration code was written:

1. **No single "resume an existing annotation session" entry point.**
   Re-opening a previously-annotated photo requires the consumer to
   separately: decode `AnnotationDocument.fromJson`, extract
   `.annotations`, decode the image a second time via
   `instantiateImageCodec` purely to learn its pixel `Size` (required by
   `canvasSize`, which nothing else in this package can derive), build
   an `AnnotationController(initial: ...)`, and only then construct the
   screen. Four separate steps, done by every consumer, every time a
   session reopens — not just once at first annotation.
2. **`ImageAnnotation.reference` resolution is entirely the consumer's
   problem, with no guidance for the common "resume a saved session"
   case.** If a saved `AnnotationDocument` contains an `ImageAnnotation`,
   resuming it requires a live `ImageAnnotationCache` whose resolver can
   turn the saved `reference` string back into bytes — but there is
   nothing in this package's docs or example app showing what a
   *persisted* reference should look like, only that it's an opaque
   string the consumer defines. A consumer with no other reference
   registry (like `site_inspector`, whose photos are flat files with no
   stamp/asset system) has no guidance for whether to even support this
   case.
3. **`RenderOptions`'s 2000px default cap is easy to hit unknowingly on
   an explicit "download my full-size annotated photo" action.** The
   default is correct and well-reasoned for embedding into a PDF (this
   doc comment already cites `site_inspector`'s own SPIKE-0005 memory
   findings) but a *user-initiated* "give me my photo" export is a
   different intent than "make me a lightweight report thumbnail," and
   nothing about the API signals that distinction back to the caller —
   `maxDimension: null` exists but a consumer has to already know to
   reach for it.
4. **No API-level support for "what does a size/binding mismatch mean
   for my UI."** `classifyBinding` returns `AnnotationBinding.ok /
   sizeMismatch / missingImage`, but every consumer has to invent its
   own handling for the non-`ok` cases from scratch — there is no
   default widget, guidance, or even a worked example of what a
   reasonable fallback looks like.

Additionally, `D3AnnotatorScreen`'s tool bar unconditionally renders
every `AnnotationTool` (`_tools()` iterates `AnnotationTool.values`
directly) — a consumer whose use case only ever needs one or two shape
types (e.g. "just circle the defect") has no way to trim the toolbar
without forking the widget.

## Decision

Address each point with the smallest change that removes the friction,
without inventing speculative generality for use cases nobody has hit
yet:

1. **Add `AnnotationEditingSession` (or similar), a single object that
   bundles what a consumer needs to resume editing.** Concretely, a
   static/named constructor such as
   `AnnotationEditingSession.fromDocument(document, imageBytes)` that:
   decodes `imageBytes` once via `instantiateImageCodec` to get
   `canvasSize`, builds the `AnnotationController` from
   `document.annotations`, and exposes both as plain fields
   (`canvasSize`, `controller`) ready to pass straight into
   `D3AnnotatorScreen`. Starting a *fresh* (non-resumed) session stays
   exactly as simple as it is today — this is additive, not a
   replacement for the existing direct-construction path.
2. **Document the `ImageAnnotation.reference` contract explicitly for
   the persist/resume case**, rather than changing the type: add a doc
   comment section (on `ImageAnnotation.reference` and
   `ImageReferenceResolver`) spelling out that a reference intended to
   survive a save/reload cycle must be resolvable by the consumer's
   *own* persisted-reference lookup (e.g. a stored file path, a content
   ID) — not a transient in-memory key — and that a consumer with no
   such registry can simply choose not to expose the image-annotation
   tool at all (see the toolbar-restriction change below, which makes
   that an explicit, supported choice rather than an accident).
3. **Add a named `RenderOptions.original` (or similar) constant/factory**
   equivalent to `RenderOptions(maxDimension: null)`, so "I want the
   real thing, not a report thumbnail" is a self-documenting call at
   the use site rather than a bespoke parameter a caller has to already
   know exists. No change to the default.
4. **Do not build a default mismatch-handling widget** — the range of
   reasonable UI responses (silently fall back to unannotated, show a
   warning banner, block entirely) is too consumer-specific to guess at
   from one integration. Instead, add a worked example to the package's
   own `example/` app (the save/restore demo already built this session
   is the natural home) demonstrating at least one handling of
   `AnnotationBinding.sizeMismatch`, so a future consumer has a concrete
   pattern to copy rather than reading `classifyBinding`'s doc comment
   cold.
5. **Add a `visibleTools: Set<AnnotationTool>?` parameter to
   `D3AnnotatorScreen`** (null/omitted means "all tools," matching
   today's behaviour exactly), threaded into `_tools()`'s existing
   `for (final t in AnnotationTool.values)` loop as a filter. `tool`/
   `initialTool` are unaffected; a consumer restricting tools is
   responsible for choosing an `initialTool` that's actually in the
   allowed set (documented, not enforced by an assert, since a mismatch
   just means the toolbar opens with nothing visually selected rather
   than crashing).

## Options considered

| Option | Pros | Cons | Chosen? |
|---|---|---|---|
| `AnnotationEditingSession.fromDocument` convenience constructor | Additive, doesn't change the direct-construction path anyone already using this package depends on; collapses four manual steps into one at the one call site that needs them | One more public type to document and keep in sync if `AnnotationDocument`/`AnnotationController`'s own shapes change | ✓ |
| Change `AnnotationBackground.image` to accept a `Future<Size>` or resolve size itself from the `ImageProvider` | Removes the `instantiateImageCodec` boilerplate at its actual source, benefiting every consumer including ones not resuming a saved session | A real breaking change to `canvasSize`'s always-synchronous, always-explicit contract (the package's own docs are emphatic that this is deliberate — layout must happen before decode) — bigger and riskier than the friction it fixes for what is, so far, a single consumer's report | ✗ (deferred — see Risks) |
| Make `ImageAnnotation.reference` a typed/structured value instead of an opaque `String` | Could self-document what "a reference that survives persistence" means | Every existing consumer (including this package's own example app) already treats it as an opaque string by design (`ImageAnnotation`'s own doc comment); changing the type is a breaking change to fix what is actually a documentation gap, not a type-safety gap | ✗ |
| Build a default `AnnotationBindingBanner`-style widget for mismatch handling | Saves every consumer from writing their own | Guessing at UI for a situation with only one real consumer risks building the wrong default and having to change it once a second consumer disagrees — a worked example achieves the same "don't start from zero" goal without locking in a widget's visual design prematurely | ✗ |
| `visibleTools` as a `Set<AnnotationTool>` parameter | Minimal, additive, mirrors `initialTool`'s existing shape | A consumer could pass an empty set or one that excludes `initialTool`, producing a toolbar with nothing selected — accepted as a documented caller responsibility rather than adding runtime validation for a self-inflicted misuse | ✓ |

## Consequences

**Positive:**
- Closes all four friction points found while designing `site_inspector`'s
  integration *before* that integration writes a line of code against
  the current API, rather than discovering them mid-implementation and
  needing a second consumer-side patch pass.
- `AnnotationEditingSession` and `visibleTools` are both purely additive
  — no existing call site anywhere (this package's own screens, tests,
  or `example/`) needs to change.
- The `RenderOptions.original` naming and the mismatch-handling example
  are both documentation/discoverability fixes, not new runtime
  behaviour — lowest possible risk of the four.

**Negative / Trade-offs accepted:**
- `AnnotationEditingSession` only handles the "decode bytes, build
  controller" half of resuming a session — it does not (and should not)
  know anything about `ImageAnnotationCache`/reference resolution, so a
  consumer using image-as-annotation still has to wire that separately.
  Documented as an explicit limitation of the new type, not silently
  glossed over.
- Deferring the `AnnotationBackground.image` size-resolution change
  (Option 2 above) means the `instantiateImageCodec` cost is only
  amortized for the *resume* path via the new convenience constructor,
  not eliminated for a fresh first-time annotation — a consumer
  annotating a photo for the first time still measures it manually
  today. Accepted since it's the smaller, non-breaking fix; revisit if
  a second consumer independently reports the same friction on the
  fresh-annotation path specifically.

**Risks / Open questions:**
- Whether `AnnotationBackground.image`'s synchronous-size contract is
  actually a real API limitation or a `site_inspector`-specific gap
  (this app happens to have never needed a photo's pixel dimensions
  before) is still open — decided here to treat it as consumer-specific
  for now, but if a second consumer hits the same "I don't know my
  image's size" problem, that's the signal to revisit Option 2 above
  rather than adding a second workaround.
- `visibleTools` interacting with `AnnotatorToolGroup`s (draw vs.
  adjust) beyond the `draw` group's tool list hasn't been checked
  against every group — needs a read of `_tools()`'s other `switch`
  arms before implementing, to confirm the filter only needs to apply
  to the `draw` case shown above and not silently break another group.

## Definition of done

- [ ] `AnnotationEditingSession.fromDocument(document, imageBytes)` added,
      exercised by a new test and wired into the package's own
      save/restore example demo
- [ ] `ImageAnnotation.reference`/`ImageReferenceResolver` doc comments
      updated to explicitly address the persist/resume contract
- [ ] `RenderOptions.original` (naming TBD at implementation time) added
      alongside the existing default, with a doc comment cross-linking
      the two so a reader lands on whichever one they didn't call
- [ ] Save/restore example demo extended with a worked
      `AnnotationBinding.sizeMismatch` handling example
- [ ] `D3AnnotatorScreen` gains `visibleTools: Set<AnnotationTool>?`,
      filtering the existing tool bar; `null` preserves today's
      show-everything behaviour exactly
- [ ] `flutter analyze` and `flutter test` clean on both the package and
      `example/`
- [ ] `site_inspector`'s WORK-0029 integration re-checked against the
      new API once this ships, confirming each of the four friction
      points is actually resolved in practice, not just in theory

## Log

- 2026-09-07 proposed — drafted from four concrete friction points found
  while designing `site_inspector`'s WORK-0029 checklist-photo-annotation
  integration against this package's current public API, before any
  `site_inspector` integration code was written. This is
  `d3_image_annotator`'s first `context/work/` item — `context/`,
  `context/RELEASING.md`, and this file's own template were bootstrapped
  alongside it, matching the workspace-wide convention used by every
  other project.

---

> **For AI agents:** Do NOT implement this work item unless status is
> `accepted` or `building`. If status is `proposed`, surface it to the user
> for a decision before writing any code. If status is `superseded`, follow
> the item in `superseded-by` instead — do NOT implement the pattern
> described here. If you are about to contradict an `accepted`, `building`,
> `shipped`, or `operating` item, stop and surface it to the user before
> proceeding.
