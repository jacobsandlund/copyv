# PLAN: Fix reindentation corruption + heavily unit test the indentation code

## Background: the two incidents (fully diagnosed, byte-identical repro)

Both incidents from `investigations/llvm-token-kinds-reindent/` were reproduced
offline, byte-for-byte, with a Python replica of `getIndent` + `matchIndent` +
`git merge-file` (using the inputs still present in `../src-8/.copyv-cache`).
The merge itself is innocent in both cases: `current == base_indented`, so the
merge trivially emits `theirs` — the corruption happens entirely inside
`matchIndent` on the *new* chunk.

### Incident 1: `llvm_clang.def` (13 continuation comments, 25→79 / 30→93 / 32→104 spaces)

Causal chain:

1. **Bogus width from the destination file.** `TokenKinds.def` content has no
   real block indentation — every line is at column 0 except 13
   comment-continuation lines aligned at columns 26/31/33 and one wrapped macro
   argument (`TYPE_TRAIT_1(__has_unique_object_representations,` /
   `             HasUniqueObjectRepresentations, ...` — a +13/−13 shift pair
   aligned under the open paren). Width detection ends with
   `indent_counts = {4: 1 (file-type prior), 13: 1}` — a tie — and the
   tie-breaker consults `deindent_counts`, where 13 is the *only* entry. A
   single wrapped argument line beats the prior: **detected width = 13**.
2. **Base chunk detects 13 too** (same text) → fast path → `base_indented` is
   the identity, equal to the local chunk.
3. **New chunk detects 4.** Upstream's removals deleted the one
   `TYPE_TRAIT_1(...)` wrapped-argument pair, so the new revision has *zero*
   countable shifts; the file-type prior (`.def` → 4) wins. **width = 4**.
4. **`matchIndent` "converts" width 4 → width 13.** The complex path decomposes
   each line's leading whitespace as
   `over_indents = over / current_width; over_spaces = over % current_width`
   and rebuilds it as `over_indents * desired_width + over_spaces`. Alignment
   whitespace gets treated as nesting: 25 = 6×4+1 → 6×13+1 = **79**;
   30 = 7×4+2 → 7×13+2 = **93**; 32 = 8×4+0 → 8×13+0 = **104**. Exactly the
   observed corruption; all 13 space-indented lines in the chunk are hit.

### Incident 2: `css.h` (4 continuation lines, column 28 → column 54)

Here the width conversion is *intended* (local file is 4-space, upstream is
2-space; dest detects 4 via threshold, chunk detects 2 via threshold), but the
same "alignment as nesting levels" decomposition destroys continuation lines:
upstream `static_cast<...>` is aligned under `UNSAFE_BUFFERS(` at 27 spaces =
2 + 25 over = 12 levels + 1 → 4 + 12×4 + 1 = **53 spaces**. The block lines
(2→4, 4→8) convert correctly; only the alignment explodes.

### Three distinct defects

- **(A) Alignment treated as indentation.** `matchIndent` rescales *all*
  whitespace beyond `current_start` by `desired_width / current_width`.
  Continuation/alignment columns (under an open paren, or a comment column)
  are not multiples of nesting depth and must not be rescaled.
- **(B) Width detection is winnable by a single line pair.** The file-type
  prior only seeds one count, and the deindent tie-breaker lets exactly one
  ±N shift pair override it. On alignment-heavy/flat files this produces
  garbage widths (13).
- **(C) Inconsistent detection domains.** `desired` is detected over the whole
  destination file; `current` over just the fetched chunk — and separately for
  the base and new revisions of the *same* source file. Nearly identical text
  yielded 13 vs 13 vs 4, triggering a phantom conversion between two files
  that had identical indentation styles. (Related hazard: the destination file
  now also embeds a `Traits.td` chunk, so "desired" detection runs over a
  foreign file's style.)

Also worth noting: the corruption was **silent** — no conflict, no warning.
(The `Merging file: llvm_clang.def[838]` log line came from a *subsequent* run
over the already-corrupted file, which the merge then preserved as "ours".)

## Proposal

### Phase 1 — Extract the indentation code into a testable module

Move the indentation logic out of `src/main.zig` (2400 lines, everything
coupled to `FileContext`/network) into `src/indent.zig`:

- `getIndentStart`, `getIndent` (char/width/start detection),
  `getChunkIndent`, `matchIndent`, `getWhitespace`, `getMixedWhitespace`,
  the `Indent` struct and detection constants.
- Break the `FileContext` dependency: these functions only need
  `(bytes, FileTypeIndentDefault, DebugIndent, name/line for logging)`. Pass a
  small `IndentContext` struct instead of `*FileContext`.
- `main.zig` imports it; add `test { _ = @import("indent.zig"); }` so
  `zig build test` (already wired in build.zig) picks everything up.

No behavior change in this phase — verify with `zig build run` over
`examples/` producing an empty diff.

### Phase 2 — Unit tests (the bulk of the work)

All pure-function tests on string fixtures; big fixtures via `@embedFile`
from a new `src/testdata/`.

**Detection: char** (`getIndent`)
- threshold path (≥10 space-led / tab-led lines), majority path, file-type
  default fallback, `max_lines_to_check` cap, blank-line handling.

**Detection: width**
- threshold path (≥6 equal shifts); max-count path; tie-breaker path.
- shifts after `*` / `-` / `/*` lines ignored (block-comment heuristics).
- shifts ≥ `max_indent_width` ignored.
- tabs → file-type default.
- **Regression (B):** a TokenKinds-style flat file — hundreds of column-0
  lines, comment continuations at ~25–32, one wrapped-argument ±13 pair —
  must detect the file-type default (4), not 13.
- **Stability property:** deleting unrelated lines from a fixture must not
  change the detected width (the base-vs-new divergence that triggered
  incident 1).

**Detection: start_width** — first non-blank line, tab+space mixes,
whitespace-only files.

**`matchIndent` mechanics**
- fast path (identity when char/width/start all equal) — byte-identical.
- simple path: prefix add / remove, spaces and tabs, whitespace-only lines,
  empty lines, `current_start == 0` first-line behavior.
- complex path: 2↔4 spaces, spaces↔tabs, tab+space remainders, start-offset
  changes, lines shallower than `current_start`.

**Alignment regressions (golden tests from the real incidents)**
- LLVM: new-chunk text through `matchIndent` with the *fixed* pipeline must be
  byte-identical to upstream (trimmed fixture: the two excerpt regions plus
  enough context, or the full cached revisions committed under
  `src/testdata/`).
- CSS: base/new chunk (2-space) reindented to 4-space must convert block
  indentation (2→4, 4→8, 6→12) while *preserving* continuation alignment
  relative to its anchor line (27 → 31, i.e. anchor delta +4), not 53.
- The README's suggested scenario: a large deletion before an unchanged
  continuation region; unchanged lines must survive byte-identical.

**Merge-path composition** — factor the "compute `base_indented`,
`new_indented`, run `git merge-file`" block of `updateChunk` into a function
taking `(current_chunk, base_bytes, new_bytes, indents)` so the incident can
be replayed end-to-end in a test (subprocess + cache-dir writes stay behind
the seam; the pure reindent parts test without Io).

### Phase 3 — Fixes, each landed test-first

**Fix B — require real evidence before overriding the prior.**
Only accept a detected width from max-count/tie-breaker if its count meets a
minimum (e.g. ≥3 observed shifts); otherwise fall back to the file-type
default. A lone wrapped-argument pair (count 1) can no longer win. This alone
makes incident 1 vanish: dest, base, and new all detect 4 → fast path →
byte-identical output.

**Fix A — preserve alignment instead of rescaling it.**
In the complex path, track the previous non-blank line's original and output
indent. Classify each line's over-indent:
- `over_start % current_width != 0` (has a remainder) → **alignment**: emit
  `prev_output_indent + (line_indent − prev_orig_indent)` — i.e. keep the
  column offset relative to the anchor line, shifted by the anchor's delta.
- exact multiple of `current_width` → treat as nesting and rescale (current
  behavior).

This fixes incident 2 (27 → 31 alongside anchor 4 → 8) and is the safety net
for any future bogus-width case: alignment can drift by the anchor delta but
can never be multiplied. Decide during implementation whether jumps of
`> 1 × width` with zero remainder should also be treated as alignment
(ambiguous; default to rescaling, revisit with fixtures).

**Fix C — one detection per source file.**
Detect `current` once (on the base chunk when tracking; new chunk for plain
gets) and reuse it for both `base_indented` and `new_indented`. Revisions of
the same file days apart almost never change indent style, and detection
differences between them are exactly the phantom-conversion trigger. If we
want to allow upstream restyles, detect both and, when they disagree, prefer
the base detection and log a notice — never silently reindent the two sides
with different assumptions.

**Fix D — observability.**
- Log detected `(char, width, start)` for dest/base/new at `--verbose`
  whenever the fast path is *not* taken (a reindent is happening).
- Warn when a reindent changes any single line's indent by more than
  `desired_width × 2` beyond the chunk-level start delta — that's almost
  certainly alignment being mangled. Incident 1 would have printed 13 warnings
  instead of corrupting silently.

**Follow-up (separate, lower priority):** scope `desired`-width detection to
the destination file *excluding* other copyv chunks' bodies, so a foreign
embedded file (the `Traits.td` chunk now in `llvm_clang.def`) can't set the
style for this one.

### Phase 4 — Validation

- `zig build test` green; `zig build run` over `examples/` yields no diff.
- Replay both incidents through the real binary using the cached upstream
  files (`.copyv-cache` in a temp repo fixture) — output must be
  byte-identical to upstream text.
- Keep `investigations/llvm-token-kinds-reindent/` as the incident record;
  the distilled fixtures live in `src/testdata/`.

## Suggested order

1. Phase 1 (extraction) — small, mechanical, unblocks everything.
2. Phase 2 detection + matchIndent mechanics tests (locks in current behavior).
3. Fix B + its regression tests (kills incident 1's class).
4. Fix A + alignment golden tests (kills incident 2's class).
5. Fix C, Fix D, then Phase 4 validation.
