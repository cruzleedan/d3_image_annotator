# Releasing — d3_image_annotator

Thin, deliberately — mirrors the workspace-root convention at
`/home/dan/projects/context/RELEASING.md`. Governs how work ships once a
`context/work/` item reaches `building`; does not introduce versioning
policy beyond what `CHANGELOG.md`/`pubspec.yaml` already track for a
published Dart package.

## Commit format

Conventional Commits:

```
<type>(<scope>): <summary>
```

`type` is one of `feat | fix | refactor | chore | docs | test`. `scope` is
usually the affected module (e.g. `text-annotation`, `render`, `restyle-bar`).

Commits made before this file existed used a plain sentence-style subject
line, not this prefix — that history is not being retroactively rewritten;
this convention applies going forward.

## Branch naming

```
<kind>/<work-id>-<slug>
```

`kind` matches the work item's `kind` field. `work-id` is the 4-digit
zero-padded ID. Example: `feat/0001-restrict-annotator-toolset`.

Branches created before this file existed (e.g. `fix/text-annotation-
drag-to-move`) predate work-item tracking and have no ID prefix — that is
expected for that history, not a deviation to fix retroactively.

## Definition of done

Pulled from the work item itself — every box in its **Definition of done**
checklist must be checked before status moves to `shipped`.

## Before marking a context/work/ item "shipped"

- [ ] All Definition of done boxes checked
- [ ] `flutter analyze` clean, `flutter test` passing (package and
      `example/`)
- [ ] Log entry added: `- YYYY-MM-DD shipped — <one line>`

## After shipping

Status moves to `operating` once the change has shipped in a published
version (or, for an unpublished package still under active local
development, once it has been merged to `main` without issue for a
reasonable period) — a separate step from `shipped` so "just merged" and
"proven stable" aren't conflated. There's no fixed waiting period; use
judgment.
