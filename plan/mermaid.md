# mdview.nvim — Mermaid flowchart rendering

Plan for [issue #1](https://github.com/akito19/mdview.nvim/issues/1). Read
[design.md](design.md) first; this document only describes what is added.

The chosen direction is option 2 from the issue, scoped tight: a **narrow
subgraph of mermaid `flowchart`**, laid out and drawn in pure Lua with the
existing closed glyph set. Options 1 and 3 were rejected — option 3 contradicts
the goal statement (`design.md`, "No browser, no external process, no runtime
plugin dependency") and cannot be covered by the headless test suite; option 1
gives up a feature that turns out to fit the constraints.

## Goal

A ` ```mermaid ` fence whose contents fall inside the supported subset renders
as a box-and-line diagram. Anything else falls back to today's behaviour —
a labeled code block — with no error and no partial diagram.

**Never render a wrong diagram.** Every unsupported construct is a hard bail to
the code-block path. That rule is what makes an incremental subset safe to ship:
the failure mode is "you get the source text", which is exactly what happens
today.

## Supported subset (v1)

### Header

| Form | Support |
|---|---|
| `flowchart <DIR>` / `graph <DIR>` | yes, interchangeable (`graph` is the legacy spelling) |
| `<DIR>` ∈ `TB` `TD` `BT` `LR` `RL` | yes; `TD` is a synonym of `TB` |
| direction omitted | yes, defaults to `TB` |

`BT` is `TB` with the layer order reversed; `RL` is `LR` reversed. One layout
engine, four entry points.

Keyword and direction are matched **case-insensitively**. The docs never state
whether mermaid itself is case-sensitive here, and being permissive cannot
produce a wrong diagram — at worst it renders something mermaid would reject.

### Nodes

| Form | Support |
|---|---|
| `A` (bare id) | yes — label is the id |
| `A[text]` | yes |
| `A(text)` `A((text))` `A(((text)))` `A{text}` `A{{text}}` `A([text])` `A[[text]]` `A[(text)]` `A>text]` `A[/text/]` `A[\text\]` `A[/text\]` `A[\text/]` | parsed, **drawn as a rectangle** |
| `A["quoted text"]` | yes |
| `text<br/>text` in a label | yes — a two-line box |
| `A:::someClass` (inline class suffix) | yes — suffix stripped, class ignored |
| `A@{ shape: … }`, `@{ icon: … }`, `@{ img: … }` | bail |
| markdown-string labels ``A["`**x**`"]`` | bail |
| `#35;` / `#9829;` numeric entity codes | **not decoded** — rendered literally |

Those are the fifteen classic bracket-delimiter forms; the v11.3+ `@{ shape: … }`
syntax bails generically on the `@{` rather than by enumerating ~30 shape names.

**Node ids are restricted to `[A-Za-z0-9_]`**; anything else bails. The docs give
no formal id grammar, only negative examples, so a conservative class is the only
defensible choice. It also sidesteps the documented `---o` / `---x` ambiguity,
where an id beginning with `o` or `x` is lexed as an edge end marker.

**A repeated id is last-write-wins** for its label, per the docs.

Entity codes are left literal deliberately: decoding `#9829;` would have the
*renderer* synthesise `♥` — a glyph outside the safe set — from pure-ASCII
source. Document text passes through untouched everywhere else in this plugin,
and this keeps that true.

Shape differentiation is deliberately **not** implemented in v1: it would need
`╭ ╮ ╰ ╯` (rounded) and there is no box-drawing diamond or circle at all. Those
four are inside U+2500–257F and so would be safe, but adding to a closed set
that a test enforces is a decision of its own, and diamonds/circles have no
answer regardless. Every shape is a rectangle, and the doc says so.

### Edges

| Form | End marker | Style |
|---|---|---|
| `---` `----` `-----` | none | solid |
| `-->` `--->` `---->` | `v` `^` `<` `>` | solid |
| `-.-` `-..-` `-...-` | none | dim |
| `-.->` `-..->` `-...->` | arrowhead | dim |
| `===` `====` | none | strong |
| `==>` `===>` | arrowhead | strong |
| `--o` `---o` | `o` | solid |
| `--x` `---x` | `x` | solid |
| `~~~` | none | invisible |

Extra dashes only lengthen the edge in mermaid's rank model; **length is
ignored** here. Note the dotted family lengthens by adding `.`, not `-`.

Line style is carried into a **highlight group**, not a glyph — decoration is
what this plugin does, and the glyph set has one line weight. Circle and cross
end markers, on the other hand, are drawn as literal ASCII `o` and `x` in the
arrowhead's cell: the character is already the marker, so nothing is lost.

**Double-ended forms `<-->` `o--o` `x--x` bail.** A source-end marker would have
to land on the box border cell already occupied by the `┬` junction, and drawing
them one-directional instead would be a semantically *wrong* diagram — the one
outcome this design refuses.

| Form | Support |
|---|---|
| `A -->\|text\| B`, `A -- text --> B` | yes, equivalent; also `-. text .->` and `== text ==>` |
| `A --> B --> C` (chaining) | yes |
| `A & B --> C & D` | yes, cross product |
| `a --> b & c --> d` (mixed) | yes |
| `A e1@--> B` (edge id) | bail |

Chaining and `&` are one rule, not two special cases: a statement parses as a
sequence of node-groups separated by connectors, and each adjacent pair of groups
becomes the cross product of its members. That covers all three rows uniformly
and avoids guessing at the precedence the docs never state.

`~~~` **still participates in layering** — it is invisible, not absent, and
mermaid's own docs say it affects layout. It contributes a layer constraint and a
dummy-node chain, then draws nothing.

### Statements recognised and skipped

Parsed far enough to be ignored without derailing the parse: `classDef`, `class`,
`style`, `linkStyle`, `click`, blank lines, YAML frontmatter (`---` … `---`, only
at the very top, opening fence alone on its line), and directives
(`%%{init: …}%%`).

Two of these need care rather than a line-prefix match:

- **`%%` comments must start the line.** The docs are explicit that a comment
  occupies its own line, so `%%` is only a comment when it is the first
  non-whitespace on the line. Stripping `%%`-to-end-of-line anywhere would
  corrupt a label that legitimately contains it.
- **`:::` is an inline suffix, not a statement.** `A:::className --> B` is an
  ordinary edge; the class suffix is stripped by the *node* parser, not skipped
  by the line dispatcher.

**`;` separates statements**, so a line is split on `;` before dispatch and each
piece parsed independently.

### Hard bails (→ code block)

- `subgraph` … `end` — containers change layout materially. A bare `end` line, or
  the lowercase word `end` used as a node id, bails for the same reason (mermaid
  itself misparses the latter, per its docs)
- **cycles** — the layout is layered and DAG-only in v1
- a node id outside `[A-Za-z0-9_]`
- `@{ … }` node metadata, edge ids, markdown-string labels, double-ended arrows
- any line, or `;`-separated piece of a line, the parser does not recognise
- more than `max_nodes` nodes (default 60) or `max_edges` (default 120)

`parse` returns `nil, reason` with a short machine-checkable reason string
(`"subgraph"`, `"cycle"`, `"bad_id"`, `"unparsed"`, `"too_big"`, …) so tests can
assert *why* a fence bailed rather than only that it did.

## Architecture

One new module, `lua/mdview/mermaid.lua`, pure in exactly the sense
`renderer.lua` is pure: no buffer, window or API access. It may call
`vim.fn.strdisplaywidth` and read `vim.o.ambiwidth`, because the renderer
already does.

```
mermaid.parse(lines)          -> graph | nil, reason
mermaid.draw(graph, opts)     -> { lines, decorations }   -- 0-based, byte cols
mermaid.render(lines, opts)   -> { lines, decorations } | nil
```

`render` is the only thing `renderer.lua` calls, and `nil` means "fall back".

### Integration point

`render_code_block` (`lua/mdview/renderer.lua:531`) gains one branch at the top
of its decorated path: if `b.lang` is `mermaid`, `elements.mermaid` is on, and
`mermaid.render` returns a result, emit those lines and decorations (offset by
the block's quote prefix and indent) instead of the code body. Otherwise fall
through unchanged.

`parser.lua` does **not** change — a mermaid fence stays a `code_block` in the
IR. Making it its own block type would force the parser to decide supportability
at parse time, which is exactly the wrong place.

`window.lua` does **not** change. The diagram needs only `hl` decorations, which
already exist. No new decoration kind, no new extmark namespace.

### Not wrapped, not width-dependent

Diagrams join tables, code blocks and rules in the never-wrapped set
(`design.md`, "Wrapping and Scrolling"). A diagram is sized by its content and
left-aligned at the same 2-cell indent as code-block content; `opts.width` is
not consulted at all. That removes an entire class of resize bugs — a resize
cannot change a diagram, so it cannot invalidate a golden test.

## The canvas

Diagram drawing is a grid problem, and the whole `ambiwidth` hazard lives here.

**Every canvas column is exactly `rule_w` display cells wide**, where
`rule_w = strdisplaywidth("─")` — 1 normally, 2 under `ambiwidth = "double"`.

- A box-drawing glyph occupies exactly one canvas column, and fills it.
- Text (a node label, an arrowhead) is placed as a span across
  `ceil(displaywidth(text) / rule_w)` columns and padded with spaces to fill
  them exactly.

That is the same widen-to-a-whole-number-of-`─` trick `render_table` uses
(`renderer.lua:782-787`), generalised: instead of correcting per column at the
end, the unit of layout *is* the rule width from the start. Alignment is then
structural rather than something to be checked.

Consequence: under `ambiwidth = "double"` a diagram is twice as wide. That is
inherent — the glyphs really are two cells — and it is why diagrams scroll
rather than wrap.

Consequence: an end marker (`v` `^` `<` `>` `o` `x`, one cell each — verified:
`strdisplaywidth` returns 1 for these under both settings, while `─` and `│`
return 1 and 2) sits in the left half of its two-cell column under
`ambiwidth = "double"`, a half-cell off the line it terminates. A one-cell glyph
cannot be centred in a two-cell column, and the alternatives are worse. Same call
as ASCII checkboxes.

### Line merging by bitmask

The canvas holds, per cell, a 4-bit mask of which directions a line leaves it
(`U=1 D=2 L=4 R=8`). Edges are drawn by OR-ing bits along their path; the glyph
is chosen once at the end.

| Mask | Glyph | | Mask | Glyph |
|---|---|---|---|---|
| `U\|D` | `│` | | `U\|D\|R` | `├` |
| `L\|R` | `─` | | `U\|D\|L` | `┤` |
| `D\|R` | `┌` | | `D\|L\|R` | `┬` |
| `D\|L` | `┐` | | `U\|L\|R` | `┴` |
| `U\|R` | `└` | | `U\|D\|L\|R` | `┼` |
| `U\|L` | `┘` | | single bit | `│` or `─` |

The 16 masks map onto exactly the 11 box-drawing characters already in the safe
set. **v1 adds no new glyphs**, so `tests/test_renderer.lua`'s `SAFE` table is
untouched.

Crossings, T-junctions where two edges meet, and the `┬`/`┴` where an edge meets
a box border all fall out of the OR rather than being special-cased.

## Layout pipeline

Sugiyama, minus the expensive parts.

1. **Cycle check** — DFS. A cycle bails (see above), so everything downstream
   may assume a DAG.
2. **Layer assignment** — longest-path: `layer(v) = 0` with no incoming edge,
   otherwise `max(layer(u)) + 1`.
3. **Dummy nodes** — an edge spanning `k > 1` layers gets `k-1` one-column
   dummies chained through the intermediate layers, so long edges route through
   channels instead of crossing boxes.
4. **Ordering within a layer** — **source order** (first appearance in the
   text). Not barycenter. Deterministic ordering is worth more here than
   minimal crossings: it is what makes a golden test a golden test, and it
   matches what the author wrote.
5. **Sizing** — box inner width is the widest label line in canvas columns, plus
   one column of padding each side; box width is that plus two border columns.
   Box height is the label line count plus two.
6. **X placement** — left to right within a layer with a 2-column gap, then each
   layer centred over the widest layer. For a simple chain this puts every box
   centre on the same column, so the connectors come out straight.
7. **Channel routing** — the rows between two layers. An edge whose exit and
   entry columns match needs one row (the end marker). An edge needing a
   horizontal jog takes a routing row: down, corner, across, corner, then the
   marker row. Routing rows are shared greedily by edges whose horizontal spans
   do not overlap; a new row is added when they do. An invisible (`~~~`) edge
   reserves nothing and draws nothing, having already done its work in steps 2–3.
8. **Edge labels** — placed on the edge's first vertical run, one column to the
   right of it, in the channel. An edge label that would collide with a box
   forces an extra channel row.
9. **Emit** — walk the canvas row by row, building each line's bytes and
   recording `hl` decorations as byte ranges while the string is built. Byte
   offsets are never recomputed from display columns.

For `LR`/`RL` the same pipeline runs with rows and columns transposed: layers
become columns, boxes stack vertically, channels are vertical bands.

## Highlight groups

New `Mdview*` groups in `highlights.lua`, following the existing pattern of
`default = true` foreground groups linked to sensible candidates:

| Group | Role | Links to |
|---|---|---|
| `MdviewMermaidBox` | node borders | `MdviewTableBorder` candidates |
| `MdviewMermaidLabel` | node label text | `Normal` |
| `MdviewMermaidEdge` | edge lines and arrowheads | `MdviewTableBorder` candidates |
| `MdviewMermaidEdgeDim` | `-.->` edges | `Comment`, `NonText` |
| `MdviewMermaidEdgeStrong` | `==>` edges | `MdviewMermaidEdge` + `bold` |
| `MdviewMermaidEdgeLabel` | edge label text | `MdviewCodeHeader` candidates |

No background groups, so no blend maths and nothing to degrade without
`termguicolors`.

## Config

```lua
elements = {
  mermaid = true,      -- alongside code_blocks, tables, ...
},
mermaid = {
  language_label = true, -- keep the dim `mermaid` header line above the diagram
  max_nodes = 60,        -- above this, fall back to the code block
  max_edges = 120,
},
```

Mirrors `elements.tables` + `tables = {…}`. `setup()` stays optional; the
defaults stand alone. The `mermaid` label line is kept by default so a reader
can tell a rendered diagram from hand-drawn ASCII art in the source.

`marker_style = "block"` has no box drawing to fall back to, so under it a
mermaid fence renders as a plain code block — same as `tables.borders = false`
degrading the grid.

## Testing

New `tests/test_mermaid.lua`:

- **Parser** — one case per supported form (every bracket shape, every edge
  family and length variant, both edge-label forms, chaining, `&` cross product,
  mixed chains, `:::` suffix, `;` splitting, repeated-id last-write-wins,
  comments, frontmatter, directives, skipped statements); one per bail reason,
  asserting both `nil` and the reason string.
- **Layout goldens** — a chain, a fan-out, a diamond (two paths rejoining), a
  long edge spanning three layers, a jog, an edge label, a `<br/>` label, and
  each of `TB` / `BT` / `LR` / `RL`. Each golden runs under **both** `ambiwidth`
  settings.
- **Alignment invariant** — for every golden, every line of a diagram measures
  the same display width. This is the property the canvas exists to guarantee,
  so it is asserted directly rather than inferred from the golden text. Measured
  with `strwidth`, per `design.md` ("`strdisplaywidth` is not additive").
- **Glyph set** — the mermaid path emits nothing outside `SAFE`.
- **Fallback** — an unsupported fence produces byte-identical output to the same
  fence with a different language tag.

Extended existing tests:

- `test_renderer.lua` — a mermaid block added to `kitchen_sink()`, so the
  existing character-set tests cover the new path for free.
- `test_config.lua` — defaults and validation for the new options.
- `test_highlights.lua` — the new groups are defined.

## Documentation

- `README.md` — a feature entry, the supported-subset table, and the fallback
  rule.
- `doc/mdview.txt` — the same, plus the new config options; `doc/tags` regenerated.
- `plan/design.md` — mermaid added to the element table and to the never-wrapped
  list; `subgraph` and cycles added to Out of Scope.
- `plan/decisions.md` — a new entry recording why option 2 over 1 and 3, why the
  canvas column is `rule_w` cells, why shapes are all rectangles, and why
  ordering is source order rather than barycenter.

## Amendments from stage 1 (the parser, as built)

Things the plan above got wrong or left open, resolved during implementation.
Where this section and the sections above disagree, this section wins.

1. **`;` splitting must be quote-, bracket- and `|`-aware.** "Split the line on
   `;` before dispatch" collides with "entity codes stay literal": `A["#35;"]`
   contains a `;`. Side effect: an odd number of `|` on a line suppresses `;`
   splitting for the rest of that line, which can only turn a diagram into a
   bail, never into a wrong diagram.

2. **A skip keyword is only a keyword in keyword position.** `style` and `class`
   are legal node ids, so blindly skipping a line by its first word would
   silently drop `style --> B` — a wrong diagram. A `SKIPPED` word counts only
   when followed by whitespace or end-of-statement *and* the remainder does not
   begin with `- = ~ < &`. So `class A,B warn` skips, while `style --> B`,
   `class-->B` and `class[Foo] --> B` parse as ordinary nodes and edges.

3. **`bad_id` vs `unparsed`**: `bad_id` when an illegal id character appears
   where a node was expected (`a.b`, `#hash`, `A:B`); `unparsed` when the text
   there starts with a connector character or the statement ran out (`A -->`).
   Both bail; only the reason differs.

4. **`flowchart XY` and a non-flowchart keyword both return `not_flowchart`**,
   as does an empty body. An unclosed frontmatter block returns `unparsed`.

5. **`==o` `==x` `-.-o` `-.-x` are accepted.** The edge table above lists circle
   and cross markers only under the solid family, but these are real mermaid
   spellings with unambiguous semantics.

6. **An edge label containing `<br/>` bails** (`unsupported_edge`). Stage 1
   returned it literally, which would draw the characters `<br/>` inside the
   diagram — wrong text, and so a wrong diagram by this design's own rule.
   Multi-row edge labels would complicate channel routing for a rare construct,
   so v1 refuses them instead. Node labels are unaffected: they split as planned.

7. **A label line may be empty.** `A[a<br/>]` yields `{ "a", "" }` and `A[]`
   yields `{ "" }`. Box sizing must not assume non-empty label lines.

8. **Guarantees the drawing stage may rely on**: `nodes` is in first-appearance
   order; `index` is total over those ids; every `from`/`to` is a valid index;
   invisible edges are present; the graph is acyclic, self-loops included;
   `#nodes <= max_nodes` and `#edges <= max_edges`; the `&` cross product is
   left-major, so `A & B --> C & D` is A→C, A→D, B→C, B→D.

## Amendments from stages 2 and 3 (layout, drawing, integration)

1. **Rows are padded, not right-trimmed.** The plan's alignment invariant
   ("every line of a diagram measures the same display width") is false against
   trimmed output — box widths differ, so trimmed rows legitimately differ.
   Padding every row to the canvas width makes the invariant exact and directly
   assertable. Goldens are still written trimmed, so an editor that strips
   trailing whitespace cannot corrupt them.

2. **Ports are aligned, not layers.** Step 6 said "each layer centred over the
   widest one". A port sits at `floor(w/2)`, so `Parse` (9 columns) and `Layout`
   (10) end up one column apart and a straight chain jogs at every step. Each
   item now aims its port at the mean port of its predecessors, then the layer
   is shifted to sit under the group. Chains come out straight; fan-outs stay
   centred.

3. **Horizontal layouts give every box in a layer the widest width.** LR edges
   leave the right border and enter the left one, so uniform widths align both
   ports at once; otherwise every narrower box needs a jog. Labels are
   re-centred in the widened box.

4. **Edge labels are placed differently per direction.** Vertical: beside the
   line, since a run of `│` has no room for text. Horizontal: *on* the run
   (`──ok──>`), which is the conventional look and always fits. A horizontal
   channel is at least 3 columns wide so adjacent boxes do not collapse to
   `├>┤`.

5. **A colliding edge label interrupts the line rather than bailing.** The right
   of the vertical is preferred, the left is the fallback, and if a port column
   blocks both the label is drawn on the right anyway. Text over a line is
   cosmetic; dropping the label or bailing the whole diagram would cost real
   information.

6. **`renderer.lua` gained a dependency on `mermaid.lua`.** Both are pure, so
   the invariant holds, but the module table in `CLAUDE.md` and `design.md`
   needed a new row. `parser.lua` and `window.lua` were untouched exactly as
   planned — the diagram needs only `hl` decorations, which already existed.

7. **Runs sharing a port may share a slot.** Found by eye, not by a test: a
   fan-out came out as a staircase (`┌───┤` on one row, `│   └────┐` on the
   next) instead of the symmetric `┌───┴────┐`. The greedy slot allocator was
   comparing column spans only, so the left branch `[3,7]` and the right branch
   `[7,11]` counted as colliding — but the column they share is the source
   port, where they are *supposed* to meet.

   Two runs may now touch at a single coordinate when it is the same kind of
   port for both: a shared source (fan-out) or a shared target (fan-in). The
   test is deliberately narrow, because one segment's source coinciding with
   another's target is a coincidence of layout, and merging there would draw a
   connection that does not exist.

   Every affected diagram also lost a row. This is the one defect the golden
   tests could not have caught on their own — they encoded the wrong output
   faithfully.

8. **`M.draw` takes `opts.prefix`.** The renderer passes the quote prefix and
   indent straight in rather than shifting byte columns afterwards, so
   decoration offsets are computed once, where the string is built.

## Deliberately deferred

Follow-up issues, not silent gaps: `subgraph` containers, cycles / back edges,
node shape differentiation, crossing minimisation, `classDef`-driven colours,
double-ended arrows, entity-code decoding, markdown-string labels, and
multi-row edge labels.
