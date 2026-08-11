# mdview.nvim — Mermaid flowchart rendering

The supported `flowchart` / `graph` subset and how it is drawn. Read
[design.md](design.md) first; this document only describes what mermaid adds.
For *why* the design looks like this — including the two calls that were wrong
and were corrected — see decisions 7 and 9 in [decisions.md](decisions.md).
`sequenceDiagram` is a separate type with its own document,
[mermaid-sequence.md](mermaid-sequence.md).

## Goal

A ` ```mermaid ` fence whose contents fall inside the supported subset renders
as a box-and-line diagram. Anything else falls back to today's behaviour —
a labeled code block — with no error and no partial diagram.

**Never render a wrong diagram.** Every unsupported construct is a hard bail to
the code-block path. That rule is what makes an incremental subset safe: the
failure mode is "you get the source text", which is exactly what happened before
the feature existed. It also decides the close calls — a label that cannot be
attributed to its edge, or a box whose border is overwritten, is a *wrong*
diagram rather than a cosmetic slip, and is treated as one.

## Supported subset

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

`flowchart XY` (an unknown direction), a non-flowchart keyword and an empty body
all return `not_flowchart`. An unclosed frontmatter block returns `unparsed`.

### Nodes

| Form | Support |
|---|---|
| `A` (bare id) | yes — label is the id |
| `A[text]` | yes |
| `A(text)` `A((text))` `A(((text)))` `A{text}` `A{{text}}` `A([text])` `A[[text]]` `A[(text)]` `A>text]` `A[/text/]` `A[\text\]` `A[/text\]` `A[\text/]` | parsed, **drawn as a rectangle** |
| `A["quoted text"]` | yes |
| `text<br/>text` in a label | yes — a two-line box |
| `A:::someClass` (inline class suffix) | yes — suffix stripped, class ignored |
| `A@{ shape: … }`, `@{ icon: … }`, `@{ img: … }` | bail (`unsupported_node`) |
| markdown-string labels ``A["`**x**`"]`` | bail (`unsupported_node`) |
| `#35;` / `#9829;` numeric entity codes | **not decoded** — rendered literally |

Those are the fifteen classic bracket-delimiter forms; the v11.3+ `@{ shape: … }`
syntax bails generically on the `@{` rather than by enumerating ~30 shape names.

**Node ids are restricted to `[A-Za-z0-9_]`**; anything else bails. The docs give
no formal id grammar, only negative examples, so a conservative class is the only
defensible choice. It also sidesteps the documented `---o` / `---x` ambiguity,
where an id beginning with `o` or `x` is lexed as an edge end marker.

**A repeated id is last-write-wins** for its label, per the docs.

**A label line may be empty**: `A[a<br/>]` yields `{ "a", "" }` and `A[]` yields
`{ "" }`. Box sizing must not assume non-empty label lines.

Entity codes are left literal deliberately: decoding `#9829;` would have the
*renderer* synthesise `♥` — a glyph outside the safe set — from pure-ASCII
source. Document text passes through untouched everywhere else in this plugin,
and this keeps that true.

Shape differentiation is deliberately not implemented: rounded corners would need
`╭ ╮ ╰ ╯`, and there is no box-drawing diamond or circle at all, so the glyph set
can only ever solve a third of the problem. Every shape is a rectangle, and the
README says so.

### Edges

| Form | End marker | Style |
|---|---|---|
| `---` `----` `-----` | none | solid |
| `-->` `--->` `---->` | `v` `^` `<` `>` | solid |
| `-.-` `-..-` `-...-` | none | dim |
| `-.->` `-..->` `-...->` | arrowhead | dim |
| `===` `====` | none | strong |
| `==>` `===>` | arrowhead | strong |
| `--o` `---o` `==o` `-.-o` | `o` | per family |
| `--x` `---x` `==x` `-.-x` | `x` | per family |
| `~~~` | none | invisible |

Extra dashes only lengthen the edge in mermaid's rank model; **length is
ignored** here. Note the dotted family lengthens by adding `.`, not `-`.

Line style is carried into a **highlight group**, not a glyph — decoration is
what this plugin does, and the glyph set has one line weight. Circle and cross
end markers, on the other hand, are drawn as literal ASCII `o` and `x` in the
arrowhead's cell: the character is already the marker, so nothing is lost.

**Double-ended forms `<-->` `o--o` `x--x` bail.** A source-end marker would have
to land on the box border cell already occupied by the `┬` junction, and drawing
them one-directional instead would be a semantically *wrong* diagram.

| Form | Support |
|---|---|
| `A -->\|text\| B`, `A -- text --> B` | yes, equivalent; also `-. text .->` and `== text ==>` |
| `A --> B --> C` (chaining) | yes |
| `A & B --> C & D` | yes, cross product |
| `a --> b & c --> d` (mixed) | yes |
| `A e1@--> B` (edge id) | bail |
| `<br/>` inside an *edge* label | bail (`unsupported_edge`) |

Chaining and `&` are one rule, not two special cases: a statement parses as a
sequence of node-groups separated by connectors, and each adjacent pair of groups
becomes the cross product of its members. That covers all three rows uniformly
and avoids guessing at the precedence the docs never state.

A `<br/>` in an edge label is refused rather than passed through: rendering it
literally would draw the characters `<br/>` inside the diagram, and multi-row
edge labels would complicate channel routing for a rare construct. Node labels
are unaffected — they split into lines as documented above.

`~~~` **still participates in layering** — it is invisible, not absent, and
mermaid's own docs say it affects layout. It contributes a layer constraint and a
dummy-node chain, then draws nothing.

### Statements recognised and skipped

Parsed far enough to be ignored without derailing the parse: `classDef`, `class`,
`style`, `linkStyle`, `click`, blank lines, YAML frontmatter (`---` … `---`, only
at the very top, opening fence alone on its line), and directives
(`%%{init: …}%%`).

Three of these need care rather than a line-prefix match:

- **`%%` comments must start the line.** The docs are explicit that a comment
  occupies its own line, so `%%` is only a comment when it is the first
  non-whitespace on the line. Stripping `%%`-to-end-of-line anywhere would
  corrupt a label that legitimately contains it.
- **`:::` is an inline suffix, not a statement.** `A:::className --> B` is an
  ordinary edge; the class suffix is stripped by the *node* parser, not skipped
  by the line dispatcher.
- **A skip keyword is only a keyword in keyword position.** `style` and `class`
  are legal node ids, so skipping a line by its first word would silently drop
  `style --> B` — a wrong diagram. A skip word counts only when followed by
  whitespace or end-of-statement *and* the remainder does not begin with
  `- = ~ < &`. So `class A,B warn` skips, while `style --> B`, `class-->B` and
  `class[Foo] --> B` parse as ordinary nodes and edges.

**`;` separates statements**, so a line is split on `;` before dispatch and each
piece parsed independently. The split is **quote-, bracket- and `|`-aware**,
because entity codes stay literal and `A["#35;"]` contains a `;`. Side effect: an
odd number of `|` on a line suppresses `;` splitting for the rest of that line,
which can only turn a diagram into a bail, never into a wrong diagram.

### Hard bails (→ code block)

- `subgraph` … `end` — containers change layout materially. A bare `end` line, or
  the lowercase word `end` used as a node id, bails for the same reason (mermaid
  itself misparses the latter, per its docs)
- **cycles** — the layout is layered and DAG-only
- a node id outside `[A-Za-z0-9_]`
- `@{ … }` node metadata, edge ids, markdown-string labels, double-ended arrows,
  `<br/>` in an edge label
- any line, or `;`-separated piece of a line, the parser does not recognise
- more than `max_nodes` nodes (default 60) or `max_edges` (default 120)
- an edge label with both ends shared (decided during layout — see below)

`parse` returns `nil, reason` with a short machine-checkable reason string so
tests can assert *why* a fence bailed rather than only that it did:
`not_flowchart`, `subgraph`, `cycle`, `bad_id`, `unsupported_node`,
`unsupported_edge`, `unparsed`, `too_big`.

`bad_id` and `unparsed` divide as follows: `bad_id` when an illegal id character
appears where a node was expected (`a.b`, `#hash`, `A:B`); `unparsed` when the
text there starts with a connector character or the statement ran out (`A -->`).

### Guarantees the drawing stage may rely on

`nodes` is in first-appearance order; `index` is total over those ids; every
`from`/`to` is a valid index; invisible edges are present; the graph is acyclic,
self-loops included; `#nodes <= max_nodes` and `#edges <= max_edges`; the `&`
cross product is left-major, so `A & B --> C & D` is A→C, A→D, B→C, B→D.

## Architecture

`lua/mdview/mermaid/` is pure in exactly the sense `renderer.lua` is pure: no
buffer, window or API access. It may call `vim.fn.strdisplaywidth` and read
`vim.o.ambiwidth`, because the renderer already does.

```
mermaid.parse(lines, opts)    -> graph | nil, reason
mermaid.draw(graph, opts)     -> { lines, decorations } | nil   -- 0-based, byte cols
mermaid.render(lines, opts)   -> { lines, decorations } | nil
```

`render` is the only thing `renderer.lua` calls, and `nil` means "fall back".

`M.draw` takes `opts.prefix` — the renderer passes the quote prefix and indent
straight in rather than shifting byte columns afterwards, so decoration offsets
are computed once, where the string is built.

**An empty canvas is a fallback, not a diagram.** `M.draw` returns `nil` when the
drawn result has no lines, so a *successful* parse with nothing in it falls back
like a bail does. A header alone (`flowchart TD`), or a header plus only
recognised-and-skipped statements, parses fine and lays out zero rows; a truthy
empty table would make the renderer emit the language label, loop over no lines
and drop the fence body, so the author's source would vanish from the preview the
moment they saved a diagram they had only started writing. The check sits at the
dispatch point rather than inside each kind's `draw` — it is a property of the
drawn result, not of any one diagram type — and the renderer keeps its own
`#diagram.lines > 0` guard as belt and braces.

### Integration point

`render_code_block` in `lua/mdview/renderer.lua` branches at the top of its
decorated path: if `b.lang` is `mermaid`, `elements.mermaid` is on, and
`mermaid.render` returns a result, emit those lines and decorations instead of
the code body. Otherwise fall through unchanged.

`parser.lua` does **not** change — a mermaid fence stays a `code_block` in the
IR. Making it its own block type would force the parser to decide supportability
at parse time, which is exactly the wrong place. `window.lua` does **not** change
either: the diagram needs only `hl` decorations, which already exist.

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
- **Every row is padded to the canvas width**, not right-trimmed. That makes
  "every line of a diagram measures the same display width" an exact, directly
  assertable property. Goldens are still written trimmed, so an editor that
  strips trailing whitespace cannot corrupt them.

That is the same widen-to-a-whole-number-of-`─` trick `render_table` uses,
generalised: instead of correcting per column at the end, the unit of layout *is*
the rule width from the start. Alignment is then structural rather than something
to be checked.

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
set. **Mermaid adds no new glyphs**, so `tests/test_renderer.lua`'s `SAFE` table
is untouched and the mermaid path is asserted to emit nothing outside it.

Crossings, T-junctions where two edges meet, and the `┬`/`┴` where an edge meets
a box border all fall out of the OR rather than being special-cased.

## Layout pipeline

Sugiyama, minus the expensive parts.

1. **Cycle check** — DFS. A cycle bails, so everything downstream may assume a
   DAG.
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
   Box height is the label line count plus two. In a **horizontal** layout every
   box in a layer takes the layer's widest width: LR edges leave the right border
   and enter the left one, so uniform widths align both ports at once and no
   narrower box needs a jog. Labels are re-centred in the widened box.
6. **Placement — ports are aligned, not layers.** A port sits at `floor(w/2)`, so
   centring each layer over the widest one puts `Parse` (9 columns) and `Layout`
   (10) one column apart and makes a straight chain jog at every step. Each item
   instead aims its port at the mean port of its predecessors, then the layer is
   shifted to sit under the group. Chains come out straight; fan-outs stay
   centred.
7. **Channel routing** — the rows (or columns) between two layers. An edge whose
   exit and entry coordinates match needs one row, for the end marker. An edge
   needing a jog takes a routing row: out, corner, across, corner, then the
   marker row. Routing rows are shared greedily by segments whose spans do not
   overlap. An invisible (`~~~`) edge reserves nothing and draws nothing, having
   already done its work in steps 2–3.

   **Two runs may touch at a single coordinate when it is the same kind of port
   for both** — a shared source (fan-out) or a shared target (fan-in). Comparing
   spans alone made a fan-out's left branch `[3,7]` and right branch `[7,11]`
   collide on the source port they are *supposed* to meet at, and drew a
   staircase (`┌───┤` then `│   └────┐`) instead of a symmetric `┌───┴────┐`. The
   test is deliberately narrow: one segment's source coinciding with another's
   target is a coincidence of layout, and merging there would draw a connection
   that does not exist.
8. **Edge labels** — see below.
9. **Emit** — walk the canvas row by row, building each line's bytes and
   recording `hl` decorations as byte ranges while the string is built. Byte
   offsets are never recomputed from display columns.

For `LR`/`RL` the same pipeline runs with rows and columns transposed: layers
become columns, boxes stack vertically, channels are vertical bands.

## Edge labels

**Placement differs by direction.** Vertical (`TB`/`BT`): *beside* the line, at
an absolute column, since a run of `│` has no room for text. Horizontal
(`LR`/`RL`): *on* the run (`──ok──>`), which is the conventional look and always
fits — a horizontal channel is at least 3 columns wide so adjacent boxes do not
collapse to `├>┤`.

**A channel has two label bands.** The row (or column) order is
`pre band | jog band | post band | marker`. A segment sits on its source
coordinate for the rows up to and including its jog, and on its target coordinate
after it — so a label in the **pre** band is on the source-side run, and a label
in the **post** band is on the target-side run, after every jog in the channel
and therefore after any split. The post band rests on one guarantee: targets
within a layer have distinct ports, so of the segments sharing a source port at
most one can run straight and the rest must jog.

**The anchor is whichever end of the segment is not shared.** Per channel, count
the non-invisible segments leaving each source *item* and arriving at each target
*item* — item identity, not coordinate, since two boxes can share a column by
coincidence of layout.

| source shared | target shared | anchor |
|---|---|---|
| no | either | **pre**, at `cx` / `cy` |
| yes | no | **post**, at `tx` / `ty` |
| yes | yes | **bail** |

A **fan-in keeps the source anchor**, which is why the rule is a table rather
than "anchor at the target". `B -->|yes| D` and `C -->|no| D` leave different
boxes and meet at one: the source side is the side on which they are still
distinguishable, and anchoring at the target would reintroduce the fan-out bug
mirrored.

**Both ends shared is a hard bail** — `M.draw` returns `nil` and the fence
renders as the labelled code block. `A -->|x| B` twice over, or a labelled
fan-out crossing a fan-in (`A -->|x| C` / `A --> D` / `B --> C`), leaves the edge
owning no run in its channel: not the source-side run, which its siblings share,
and not the target-side one, which the edges arriving alongside it share. There
is no placement a reader could attribute, and a label that cannot be attached to
an edge is a wrong diagram rather than a missing one. This bail is decided during
*layout*, not during `M.parse` — the source is well formed, and only the channel
plan knows there is nowhere to put the label.

**A horizontal label is anchored at the run-order-leading end of its slot, which
is not always the leftmost column.** `draw_segment_h` indexes the channel in run
order — `cols[i]` counts *leftwards* under `RL` — while a span always fills
`col .. col + cols - 1` rightwards. A leftward run therefore anchors at
`head + label_cols - 1` instead of `head`, so the label occupies exactly the
columns its slot reserved and stays flush against the box it leaves: `├<─ok┤`
mirroring `├ok─>┤`. Anchoring at `head` grew the label past the end of its run
and onto the glyph beyond — a box's left border, or the corner of a jog — which
drew unclosed boxes. `TB`/`BT` cannot have this bug: a vertical label is placed
beside the run at an absolute column, and `BT` reverses rows, not columns.

**A colliding vertical label interrupts the line rather than bailing.** The right
of the vertical is preferred, the left is the fallback, and if a port column
blocks both the label is drawn on the right anyway. An edge label that would
collide with a box forces an extra channel row. Text over a line is cosmetic —
it never invents a connection — whereas dropping the label or bailing the whole
diagram would cost real information.

**Both channel planners return a plan table**, `{ size, pre, jogs, post,
widest_pre, widest_post }`. Horizontally `pre` and `post` are widths in columns
— a horizontal band is as wide as the labels in it — and the channel is
`max(3, pre_w + nj + post_w + 1)` columns; vertically they are row counts and the
channel is `npre + nj + npost + 1` rows. The column chooser is passed the anchor
coordinate of the band and **only that band's occupied coordinates** — the `cx`
of every segment for the pre band, the `tx` of every segment for the post band —
so a label is never pushed aside for a run that is nowhere near it.

## Highlight groups

`Mdview*` groups in `highlights.lua`, following the existing pattern of
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

`max_nodes` / `max_edges` are guards against a pathological fence costing a
visible pause on every `:w`; a zero or negative value is rejected, since
disabling diagrams by way of a size check is a confusing way to spell
`elements.mermaid = false`.

`marker_style = "block"` has no box drawing to fall back to, so under it a
mermaid fence renders as a plain code block — same as `tables.borders = false`
degrading the grid.

## Deliberately deferred

Follow-up issues, not silent gaps: `subgraph` containers, cycles / back edges,
node shape differentiation, crossing minimisation, `classDef`-driven colours,
double-ended arrows, entity-code decoding, markdown-string labels, and
multi-row edge labels.
