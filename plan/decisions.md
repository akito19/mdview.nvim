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

## 7. Mermaid — drawn, not shelled out

[Issue #1](https://github.com/akito19/mdview.nvim/issues/1) asked for mermaid
rendering and, correctly, treated it as a design question rather than a feature
request. Three directions were on the table.

**Rejected: an external renderer** (`mmdc`, or a terminal image protocol). It is
the fastest route to real diagrams and it contradicts the goal statement
outright — no browser, no external process, no runtime dependency. It also could
not be covered by the headless test suite, which is the only thing standing
between this project and silent regressions.

**Rejected: documenting it as out of scope.** Defensible, and the issue said so —
but the constraint turned out not to bind. Box drawing was already in the safe
set, and a layered layout is a pure function, so the feature fits the
architecture as it stands.

**Chosen: draw a narrow subset in pure Lua.** `flowchart` only, rectangles only,
DAGs only; everything else falls back to the labelled code block that was already
there. The fallback is what makes an incremental subset safe — the failure mode
is exactly today's behaviour.

Four decisions inside that, each of which cost something:

**The canvas column is `strdisplaywidth("─")` cells.** Decision 6 says measure,
never count; this goes further and makes the *unit of layout* the thing that
moves under `ambiwidth`. A glyph fills one column by definition and text is
padded to a whole number of them, so alignment cannot drift — it is not a
property to be verified afterwards but one the representation cannot express the
violation of. Rows are padded rather than right-trimmed so "every row is the same
width" is an exact, directly assertable property.

**Lines merge by bitmask, not by case analysis.** Cells accumulate
up/down/left/right bits and the glyph is picked once at the end. Crossings,
T-junctions and box-border joins all fall out of the OR. The sixteen masks map
onto exactly the eleven box-drawing characters already permitted, so the feature
added **no new glyph** and decision 3's `cmap` finding still holds unchallenged.

**Ports are aligned, not boxes.** The first attempt centred each layer over the
widest one, following the obvious reading of "centre it". A box's port sits at
`floor(w/2)`, so two boxes whose widths differ in parity — `Parse` at 9 columns
and `Layout` at 10 — end up with ports one column apart, and a straight chain
jogged at *every* step. Each item now aims its port at the mean port of its
predecessors and the layer is shifted to follow. A chain comes out straight.

**Shapes are not differentiated.** `A(x)`, `A{x}` and `A((x))` all draw as
rectangles. Rounded corners would need `╭╮╰╯` — safe in principle, being inside
the terminal-drawn range — but box drawing has no diamond and no circle at all,
so the glyph set can only ever solve a third of the problem. Half-differentiated
shapes would be worse than none.

**Rule extracted:** when a constraint looks like it rules a feature out, check
whether it actually binds. And prefer a representation that cannot express the
bug over a check that catches it.

## 8. Mermaid sequence diagrams — a second type, and what it refused to reuse

[Issue #3](https://github.com/akito19/mdview.nvim/issues/3) added
`sequenceDiagram`. Details in [mermaid-sequence.md](mermaid-sequence.md).

**The split came first, as its own branch.** `mermaid.lua` was 1551 lines
structured around one diagram type. Splitting it into a package *while* adding
the second type would have made the diff unreviewable and, worse, untestable:
the refactor's only proof of correctness is the existing suite passing with no
test file edited, and that proof does not exist once the same commit changes
behaviour.

**What did not carry over is the interesting part.** A sequence diagram has no
ranks, no channels, no dummy nodes and no crossing question: participants are
columns in source order, messages are rows in time order. The X sweep is one
left-to-right pass, and it is exact rather than approximate because every
constraint runs from a lower column index to a higher one — a longest-path solve
with nothing to iterate. `greedy_slot`, the whole of flowchart channel routing,
stayed where it was. What *did* carry over is `canvas.lua`, and it carried the
`ambiwidth` answer with it for free.

**Frames are deferred, and they are this type's `subgraph`.** `alt` / `opt` /
`loop` / `par` / `critical` nest *and* span lifelines, so they change the layout
materially rather than adding to it. Same call as decision 7's containers, same
hard bail, and the fence stays the code block it already was.

**No bottom participant boxes.** Mermaid repeats the boxes at the foot of the
diagram. Three rows and a duplicate of every label to restate what the top of a
diagram that fits on one screen already says is not a trade worth making in a
terminal, where vertical space is the scarce axis.

**Dashed is a colour, not a glyph** — `-->>` differs from `->>` by highlight
group alone, exactly as `-.->` does in a flowchart. The glyph set has one line
weight and decision 3's `cmap` finding still governs what may be added to it, so
a second weight is not available at any price. The *markers* went the other way
and stayed literal characters: `>` `x` and the async `)` `(` are all ASCII, so
the distinction mermaid draws costs nothing to keep.

**Stage 2 added no highlight group and no config key.** A lifeline is part of its
participant's structure, like a box border, so it takes `MdviewMermaidBox` and
first-writer-wins then makes every `├` / `┤` / `┼` junction border-coloured. And
participants count against `max_nodes` while messages count against `max_edges`:
the two guards already there do the same job, and a second pair would have been
config surface with no user-visible difference.

**Message text is centred on the run, and the flowchart convention it first
borrowed was the wrong one.** The plan placed a message label the way a
horizontal flowchart edge label is placed — one column after the source — on the
grounds that both are text sitting on a horizontal run. It drew `├hello───>┤`,
the label welded to the source with every spare column heaped up in front of the
marker. The convention had transferred without its context: a flowchart's
horizontal channel is *sized from the labels in it*, so left-aligned and centred
are near enough the same picture there, whereas a sequence run is sized by the
participant boxes above it and routinely has slack to distribute. Centring is
what mermaid draws, and it makes a leftward message the exact mirror of a
rightward one rather than two shapes that merely share a row.

Its cost was accepted knowingly: the midpoint of a message is where an
intermediate participant tends to sit, so a labelled message that skips a column
now usually covers the `┼` it crosses. That is decision 7's colliding-label call
— text over a line is cosmetic and never invents a connection — promoted from
the rare case to the common one.

**Rule extracted:** a second instance of a thing is what tells you which parts of
the first were general. Split before extending, let the new type say what it does
not need — and check that anything it *does* inherit still has the conditions
that made it right.

## 9. Edge labels are anchored to the end that is not shared

[Issue #7](https://github.com/akito19/mdview.nvim/issues/7). An edge label was
positioned relative to its segment's **source** port. In a fan-out every segment
leaves the same port, so `A -->|yes| B` and `A -->|no| C` put both labels on the
shared trunk *before* the split — and horizontally next to each other on one run,
where `yes─no` reads as a single token.

**This was a wrong diagram, not a cosmetic defect**, and that distinction is the
decision. The labels were real and the boxes were right; what was lost was the
attachment between them, which is the entire content of an edge label. Decision 7
already says a diagram whose meaning is not recoverable from the output must not
be drawn at all, so "the label is a bit off" was never the correct reading of the
symptom. A labelled `yes` / `no` fan-out is also one of the most common
flowcharts there is, so it was not an exotic corner either.

**The fix is a second label band per channel.** The channel now runs `pre band |
jog band | post band | marker`. A segment sits on its source coordinate until its
jog and on its target coordinate afterwards, so the post band is the first place
in the channel where a fan-out's branches are already apart. A label goes in
whichever band belongs to it alone: pre when the source is unshared — today's
behaviour, so nothing without a fan-out moved — post when the source is shared
but the target is not.

**A fan-in therefore keeps the source anchor**, which is why the rule is a
comparison of both ends rather than "use the target". `B -->|yes| D` and
`C -->|no| D` meet at one box: the source side is where they are still
distinguishable, and anchoring at the target would have reproduced the same bug
mirrored.

**An edge with both ends shared bails the whole fence.** `A -->|x| B` alongside
`A -->|y| B`, or a labelled fan-out crossing a fan-in, owns no run in its
channel — the source-side run is shared with its siblings, the target-side run
with the edges arriving beside it. There is no placement to choose, so the fence
falls back to the code block. This is the first bail decided during *layout*
rather than during parsing: the source is well formed and only the channel plan
knows there is nowhere to put the label. It reaches the renderer as the same
`nil` an empty canvas does, which is why no new plumbing was needed.

**Rule extracted:** when a decoration names a relationship, its position is not
presentation — it is the relationship. Ask which end of an edge a label belongs
to before asking where on the line it looks best.
