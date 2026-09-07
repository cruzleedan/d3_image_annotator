# d3_image_annotator — Project Guide

A Flutter package: annotate images with shapes, arrows, freehand marks,
and text. Public API, versioning, and status live in `README.md` and
`CHANGELOG.md` — read those for what this package actually does. This
file is about how work on the package itself is tracked.

Standalone public package repo (`github.com/cruzleedan/d3_image_annotator`),
not part of the shared cross-project `context/` workspace at
`/home/dan/projects/context/` — its `context/` folder below is a local
adoption of that same convention, not a subtree of it.

## Where decisions live

Design decisions, API changes, and anything with real trade-offs live in
`context/work/` — copy `0000-template.md`, follow the lifecycle in each
item's own frontmatter (`proposed` → `accepted`/`building` → `shipped`).
**Do not implement a work item whose status is still `proposed`** —
surface it for review first. See `context/RELEASING.md` for commit/branch
conventions once an item reaches `building`.

Log friction with this project's own `context/work/` *process* (not the
package's API — that belongs in a work item, e.g. WORK-0001) in
`context/friction.md`. Most sessions should add nothing there.

## Verification

Before reporting any change done:

```
flutter analyze
flutter test
cd example && flutter analyze . && flutter test
```

All four must be clean. The example app is a full showcase of every
public feature (see its own `lib/home_screen.dart`) — treat a change
that breaks the example as a change that breaks a real consumer, since
that's exactly what it's standing in for.

## Consumers

`site_inspector` (`/home/dan/projects/site_inspector`) is this package's
first real dependent app — see its `context/work/0029-checklist-photo-
annotation.md`. API friction found integrating there gets tracked in
this project's own `context/work/` (e.g. WORK-0001), not silently patched
around in the consumer.
