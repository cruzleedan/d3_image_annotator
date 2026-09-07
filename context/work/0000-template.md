---
id: NNNN
title: ""
status: proposed     # proposed | accepted | building | shipped | operating | superseded | rejected | abandoned
kind: feature         # feature | fix | migration | infra | spike
opened: YYYY-MM-DD
decided: ~            # date status moved to accepted — leave ~ until then
branch: ~             # <kind>/<id>-<slug> — filled in when building starts
supersedes: ~         # NNNN of work item this replaces, or ~
superseded-by: ~      # leave ~ unless this item is being retired
---

# WORK-NNNN — Title

<!-- Copy this file, fill in all fields, and name it NNNN-kebab-case-title.md -->

| | |
|---|---|
| **Opened** | YYYY-MM-DD |
| **Status** | proposed |
| **Kind** | feature |
| **Supersedes** | — |
| **Superseded by** | — |

## Problem

What problem or situation prompted this? Describe the forces at play —
technical, product, or operational. Be specific. Future agents need to
understand why this was worth a work item, not just a preference.

## Decision

What was decided (or is being proposed)? One or two sentences, active voice:
> "We will use X for Y because Z."

If status is still `proposed`, this section describes the proposed design in
enough detail that an agent could implement it from this document alone.

## Options considered

| Option | Pros | Cons | Chosen? |
|---|---|---|---|
| Option A | ... | ... | ✓ |
| Option B | ... | ... | ✗ |

## Consequences

**Positive:**
-

**Negative / Trade-offs accepted:**
-

**Risks / Open questions:**
-

## Definition of done

- [ ] Concrete, checkable outcome
- [ ] Concrete, checkable outcome

## Log

<!-- Append-only. One line per status change or notable event. This is the
     audit trail — do not rewrite past entries. -->
- YYYY-MM-DD proposed — initial draft

---

> **For AI agents:** Do NOT implement this work item unless status is
> `accepted` or `building`. If status is `proposed`, surface it to the user
> for a decision before writing any code. If status is `superseded`, follow
> the item in `superseded-by` instead — do NOT implement the pattern
> described here. If you are about to contradict an `accepted`, `building`,
> `shipped`, or `operating` item, stop and surface it to the user before
> proceeding.
