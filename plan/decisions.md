# mdview.nvim — Decision Log

Why the design looks the way it does. Two of these decisions were **wrong** and
were corrected; they are kept because the corrections are the useful part, and
because without them someone will re-derive the same mistake.

The current state is described in [design.md](design.md) — where this log and
that document disagree, that document wins.

---

## 1. Architecture — command-driven, tree-sitter, decorated text

Chosen at the start and unchanged.

- **On demand, not always-on.** `:MdView` renders the buffer at that moment.
  Re-render is bound to `BufWritePost`, not `TextChanged`, so there is no
  debouncing and no cost while typing.
- **Neovim's bundled tree-sitter grammars**, not a hand-written parser. Accurate
  for far less code, and `markdown_inline` comes free as an injection.
- **A scratch buffer with extmarks**, not conceal on the source buffer. Because
  the preview is generated text we fully control, markdown markers are simply
  dropped at render time — no conceal gymnastics, and the source buffer is never
  touched.
- **Sessions keyed by source buffer**, so several markdown buffers can each have
  a preview, with one idempotent teardown path shared by every autocmd.
- **A pure `renderer.lua`.** It holds the most logic and the most edge cases, and
  purity is what makes it testable with plain tables.

## 2. Encoding heading depth — three attempts

A terminal cannot vary font size, so `h1 > h2 > h3` needs a different scale.

**Attempt 1: graduated line backgrounds.** Each level got a full-width
background blended at a decreasing alpha (18%, 13%, 9%…). *Failed:* a few
percent of alpha is invisible. The levels were indistinguishable.

**Attempt 2: partial-block bars of decreasing thickness** (`██ ▉▉ ▊▊ ▋▋ ▌▌ ▏▏`).
*Failed:* consecutive eighth-blocks differ by 1/8 of a cell — roughly one pixel
at 13pt. H1 and H2 looked identical.

**Attempt 3 (current): bar length in whole cells.** One `█` per `#` in the
source, left-aligned in a fixed gutter. Whole-cell differences are unmistakable,
and the length maps 1:1 to what was typed.

**Rule extracted:** encode magnitude as length in whole cells. Never as sub-cell
glyph geometry, never as small differences in colour.

## 3. Box drawing — removed, then restored (a wrong diagnosis)

**What happened.** Heading underlines and table borders appeared broken into
dashes with gaps. Parsing Monaco's `cmap` showed it lacks `▉ ▊ ▋ ▌ ▏ ● ◦ ▪ ☐ ☑`,
and the conclusion drawn was that the font could not tile box drawing either. All
box-drawing characters were removed and every marker was redrawn as
background-coloured spaces.

**Why it was wrong.** Ghostty renders box drawing (U+2500–257F) and block
elements (U+2580–259F) with its own built-in sprite renderer, not from the font.
Monaco's coverage is irrelevant for those two ranges — they tile perfectly. The
symptom being chased had a different cause entirely: the 1/8-cell problem in
decision 2 above.

**Correction.** Box drawing is restored for table grids. The `cmap` findings
still govern everything *outside* those two ranges, so `● ◦ ▪ ☐ ☑` remain
banned and checkboxes stay ASCII.

**What survived.** The background-space technique became `marker_style =
"block"`, a genuine fallback for terminals without native sprite drawing.

**Rule extracted:** a font's `cmap` does not determine what a terminal draws.
Check the terminal's own glyph handling before blaming the font.

## 4. Tables — borders, then shading, then borders again

Followed decision 3. Currently a full box-drawing grid with a bold shaded header.

Zebra striping was introduced while borders were gone, and defaults to off now
that every row is ruled — `tables.zebra = true` restores it.

## 5. Wrapping — the window cannot do it

The request was for tables to scroll horizontally rather than wrap. `wrap` is a
**window-local** option, so a single window cannot reflow prose while leaving
tables unwrapped.

The only way to get both is to make the preview window `nowrap` and move the
wrapping into the renderer. That made paragraph re-wrapping mandatory, which had
been explicitly declined earlier — the constraint changed the answer.

Consequences that had to be handled: inline spans crossing a break must be split
per line; CJK has no spaces so breaking is by display cell with minimal kinsoku;
and the wrap width depends on the window, so `WinResized` re-renders (skipping
when the width is unchanged).

## 6. Measuring width — `strdisplaywidth`, and its limits

`ambiwidth = "double"` makes `█ │ ─ • ·` two cells while `‣` stays one. Layout
padded by character count drifted the heading text column from 9 to 14 across
H1–H6, and staggered list text. Everything is measured now, with regression tests
under both settings.

Separately, `strdisplaywidth` turned out **not to be additive** — on a run of 47
`─` it reported two cells more than the sum of the parts, which briefly looked
like a table misalignment that did not exist. `strwidth` is the reliable measure
when auditing alignment.

**Rule extracted:** measure, never count. And when a measurement says the layout
is broken, confirm with a second measure before changing the layout.
