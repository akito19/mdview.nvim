# mdview.nvim — Mermaid sequence diagram rendering

Plan for [issue #3](https://github.com/akito19/mdview.nvim/issues/3). Read
[design.md](design.md) and [mermaid.md](mermaid.md) first: the subset/bail
discipline, the canvas model and the highlight groups all come from there and
are not restated.

Two deliverables, in this order and on separate branches:

1. `refactor/mermaid-module-split` — split `lua/mdview/mermaid.lua` into a
   package. Behaviour-preserving; the existing suite passing unchanged is the
   proof.
2. `feat/mermaid-sequence-diagram` — `sequenceDiagram` support on top.

## Stage 1 — the split

`lua/mdview/mermaid.lua` (1551 lines) is one file structured for one diagram
type. A second type wants it split first.

```
lua/mdview/mermaid/init.lua        dispatch on the header keyword
lua/mdview/mermaid/text.lua        shared: trim, statement lines, labels
lua/mdview/mermaid/canvas.lua      shared: column grid, bitmask glyphs, emit, draw_box
lua/mdview/mermaid/flowchart.lua   what #1 built
lua/mdview/mermaid/sequence.lua    stage 2
```

`require("mdview.mermaid")` keeps resolving — Lua finds `mermaid/init.lua` — so
`renderer.lua` is untouched and `M.parse` / `M.draw` / `M.render` keep their
signatures.

**`text.lua` is a fifth module the issue did not list.** The issue's four-file
sketch has no home for `trim`, `skip_ws`, `unquote`, `split_label` and
`strip_frontmatter`: they are parsing, not drawing, so `canvas.lua` is the wrong
place, and putting them in `flowchart.lua` for `sequence.lua` to reach into
would couple the two diagram types the split exists to separate. Putting them in
`init.lua` would make `flowchart.lua` require its own parent — a cycle.

### What goes where

| Module | Contents |
|---|---|
| `text.lua` | `trim`, `skip_ws`, `unquote`, `split_label`, `strip_frontmatter`, `lines_of` (frontmatter- and comment-stripped source lines) |
| `canvas.lua` | `BIT_*`, `GLYPH`, `MARKER_CHAR`, the `GROUP_*`/`EDGE_GROUP` names, `new_canvas`, `bits`, `span`, `emit`, `text_cols`, `draw_box`, `draw_path`, `rule_width()` |
| `flowchart.lua` | everything else currently in the file: `;` splitting, node/connector/statement parsing, cycle check, layering, both layout engines, `greedy_slot` |
| `init.lua` | `parse`, `draw`, `render`, and the keyword → module table |

`greedy_slot` / `slot_count` stay in `flowchart.lua`: channel routing is exactly
what a sequence diagram does not have.

### `;` splitting is flowchart-only

`split_line` stays in `flowchart.lua`. `text.lua` supplies only the shared
prelude — frontmatter dropped, `%%` comment lines dropped, blanks dropped — and
each diagram type decides how a line becomes statements. Sequence diagrams are
one statement per line (see stage 2).

### Dispatch

```lua
local KINDS = { flowchart = flowchart, graph = flowchart }  -- + sequencediagram in stage 2
```

`init.parse` takes the first statement's first word, lowercased, and looks it up.
No match, or no first statement at all, is the existing `not_flowchart` bail.

**`not_flowchart` is kept as the name of that bail**, even once it also covers
"the header names no diagram type we support". Renaming it would churn tests
that assert bail reasons for no behavioural gain, and the reason string is read
only by tests — the renderer's fallback keys on `nil`.

### Acceptance for stage 1

- `make test` passes with **no test file edited**. Any change to a golden or an
  assertion means the refactor was not behaviour-preserving.
- `CLAUDE.md`'s layout table and `plan/design.md`'s tree gain the new files.
- No change to `renderer.lua`, `config.lua`, `highlights.lua`, `parser.lua` or
  `window.lua`.

## Stage 2 — the subset

Same discipline as #1: **a wrong diagram is worse than no diagram.** Everything
outside the table below is a hard bail, and the fence renders as the labelled
code block it is today.

### Header

| Form | Support |
|---|---|
| `sequenceDiagram` | yes, matched case-insensitively |
| anything after the keyword on that line | bail (`unparsed`) |

### Participants

| Form | Support |
|---|---|
| `participant A` | yes — label is the id |
| `participant A as Alice Smith` | yes — label is the alias, free text to end of line |
| `participant A as "Alice"` | yes — one layer of quotes stripped |
| alias containing `<br/>` | yes — a multi-line box, as node labels are |
| implicit: an id first seen in a message | yes, registered in source order |
| `actor A` | bail (`unsupported_statement`) |

Ids are `[A-Za-z0-9_]`, same class and same reasoning as flowchart node ids
(`bad_id` otherwise). Column order is **source order**: `participant` statements
first in the order written, then implicit participants at first mention. A
repeated `participant` is last-write-wins for its label, as a repeated node id
is.

`actor` bails rather than drawing a box: the stick figure is the whole
difference between the two keywords, and drawing an actor as a participant is a
diagram that says something the source did not.

### Messages

`A <arrow> B: text`, one per line. The arrow decides two independent things —
line style (carried by highlight group) and end marker (carried by an ASCII
character in the cell before the target lifeline).

| Form | Style | Marker |
|---|---|---|
| `->` | solid | none |
| `-->` | dashed | none |
| `->>` | solid | `>` / `<` |
| `-->>` | dashed | `>` / `<` |
| `-x` | solid | `x` |
| `--x` | dashed | `x` |
| `-)` | solid | `)` / `(` |
| `--)` | dashed | `)` / `(` |

One dash is solid, two are dashed; the terminator is one of `>>`, `>`, `x`, `)`.
**Dashed differs from solid by highlight group alone** (`MdviewMermaidEdgeDim`
vs `MdviewMermaidEdge`) — the glyph set has one line weight, exactly as `-.->`
does in a flowchart.

The async marker keeps its own character (`)` right, `(` left) rather than
collapsing onto `>`: both are ASCII, so nothing is risked, and an open arrowhead
is a semantic distinction mermaid draws.

The `: text` part is optional — `A->>B:` and `A->>B` both parse, with no label.
Text runs to end of line, is trimmed and unquoted. **`<br/>` in message text
bails** (`unsupported_message`), for the reason edge labels do: the text is
drawn on one row, so keeping it literal would print `<br/>` inside the diagram.

### Bails

| Construct | Reason |
|---|---|
| `alt` / `else` / `opt` / `loop` / `par` / `and` / `critical` / `option` / `break` / `rect` / `end` | `unsupported_block` |
| `Note left of` / `right of` / `over` | `unsupported_note` |
| `activate` / `deactivate`, and `+` / `-` on an arrow (`A->>+B`) | `unsupported_activation` |
| `A ->> A` (self-message) | `self_message` |
| `<<->>`, `<<-->>` (bidirectional) | `unsupported_message` |
| `autonumber`, `box`, `create`, `destroy`, `links`, `link`, `actor` | `unsupported_statement` |
| an id outside `[A-Za-z0-9_]` | `bad_id` |
| anything else | `unparsed` |
| more than `mermaid.max_nodes` participants or `mermaid.max_edges` messages | `too_big` |

Frames (`alt` / `loop` / …) are this diagram's `subgraph`: they nest *and* span
lifelines, so they change the layout materially rather than adding to it. They
are deferred for the same reason, not forgotten.

The two existing config guards are reused rather than joined by new ones:
participants count against `max_nodes`, messages against `max_edges`. New keys
for the same job would be config surface with no user-visible benefit.

### `;` is not a separator here

A sequence statement ends at the end of its line. Message text is free text and
routinely contains `;`; mermaid's own grammar takes the newline as the
terminator. Not splitting cannot produce a wrong diagram — at worst a line
mermaid would accept bails.

## Layout

No search, no ranks, no channels. Participants are columns in source order,
messages are rows in time order. The canvas from #1 is used unchanged, so every
column is `strdisplaywidth("─")` cells wide and alignment stays structural.

```
┌───────┐    ┌─────┐
│ Alice │    │ Bob │
└───┬───┘    └──┬──┘
    │           │
    ├──hello───>┤
    │           │
    ├<──reply───┤
    │           │
```

1. **Box sizing** — as flowchart nodes: widest label line in canvas columns,
   plus one column of padding each side and two border columns. Height is the
   label line count plus two. All boxes share the header band's height (the
   tallest box), so every lifeline starts on the same row.
2. **X placement**, a single left-to-right sweep. `x[1] = 0`; for each later
   participant `j`,

   ```
   x[j] = max( x[j-1] + w[j-1] + GAP,
               max over messages (i, j) or (j, i) of  needed(i, j) )
   ```

   where `needed` is the smallest `x[j]` that leaves the run between the two
   lifelines wide enough: `label_cols + 1` marker column, and at least one run
   column even for an unlabelled message. Because a constraint always runs from
   a lower index to a higher one, one sweep is a longest-path solve — there is
   no iteration to converge and no ordering choice to make.
3. **Lifeline column** is `x + floor(w / 2)`, the same port rule flowchart boxes
   use.
4. **Rows** — the header band, then one lifeline row, then per message a message
   row followed by a lifeline row. The trailing lifeline row is what stops the
   diagram ending on an arrow.
5. **Drawing** — the box bottom border cell at the port column gains `BIT_D`, so
   it becomes `┬` for free. The lifeline is `BIT_U|BIT_D` down every row below
   it. A message adds the horizontal bit to each of its two lifeline cells (`├`
   at the source, `┤` at the target) and `BIT_L|BIT_R` to the cells between, and
   the end marker is a one-column span over the run cell adjacent to the target.
   Crossings and junctions are the bitmask's job, as before.
6. **Message text** is a span placed on the run, left-aligned one column after
   the source lifeline — the horizontal convention `plan/mermaid.md` already
   settled for LR edge labels. Step 2 guarantees it fits, so there is no
   collision case and nothing to displace.

**No bottom participant boxes.** Mermaid repeats them; this does not. They cost
three rows and a duplicate of every label to restate what the top of a diagram
that fits on one screen already says. Revisit if it ever reads as unfinished.

**Lifelines take `MdviewMermaidBox`**, not a new group: a lifeline is part of
its participant's structure, like a box border, and first-writer-wins then makes
the `├`/`┤` junctions border-coloured, matching what flowchart does where an
edge meets a box. **Stage 2 adds no highlight groups and no config keys.**

## Testing

New `tests/test_mermaid_sequence.lua`, structured like `tests/test_mermaid.lua`.

- **Parser** — one case per supported form: both participant spellings, quoted
  and `<br/>` aliases, implicit participants, source ordering, repeated
  participants, every arrow in the table, labelled and unlabelled messages,
  comments, frontmatter, directives. One case per bail reason, asserting the
  reason string and not merely `nil`.
- **Layout goldens** — two participants with one message; a three-participant
  conversation; a right-to-left message; a message spanning a non-adjacent pair;
  a label wider than the boxes it sits between; a multi-line alias; every arrow
  form on one diagram. Each golden runs under **both** `ambiwidth` settings.
- **Equal-width invariant** — asserted directly on every golden with `strwidth`,
  as in `tests/test_mermaid.lua`.
- **Glyph set** — the sequence path emits nothing outside `SAFE`. The added
  markers `x ) (` are ASCII and already permitted; nothing new is introduced.
- **Fallback** — a fence carrying an unsupported construct produces output
  byte-identical to the same fence tagged with another language.
- `tests/test_mermaid.lua`'s `"another diagram type is not_flowchart"` case now
  needs a body that is genuinely no diagram type, since `sequenceDiagram` has
  stopped being one.

## Documentation

- `README.md` — the sequence subset table and the deferred list, beside the
  flowchart one.
- `doc/mdview.txt` — the same, plus a note that `max_nodes` / `max_edges` count
  participants and messages; `doc/tags` regenerated.
- `plan/design.md` — the module tree gains `mermaid/`.
- `plan/decisions.md` — one entry: why the split preceded the feature, why
  frames are deferred, why there are no bottom boxes, and why dashed is a colour.
- `CLAUDE.md` — the layout table gains the package.

## Amendments from stage 2 (as built)

Things the plan above got wrong or left open, resolved during implementation.
Where this section and the sections above disagree, this section wins.

1. **Message text is centred on the run, not left-aligned against the source.**
   Layout step 6 specified the LR edge-label convention — text one column after
   the source lifeline — and what it drew was `├hello───>┤`, with the label
   hugging the source and all the slack piled up in front of the marker. Three
   variants were rendered and compared; centring won on every one of them.
   It is the conventional look, it is what mermaid itself draws, and it makes a
   leftward message the exact mirror of a rightward one instead of two shapes
   that happen to share a row.

   Two consequences the plan did not anticipate:

   - **A labelled message reserves three run columns beyond its text**, not one.
     One is still the marker's; the other two are the line either side of the
     centred label, without which `├text┤` would read as a caption rather than
     an arrow. An *unlabelled* message is unchanged — it keeps its single marker
     column, so `├──────┤` and `├─────>┤` are byte-identical to what stage 2
     first drew.
   - **The centring reserves the cell next to the target for a marker whether
     or not the arrow draws one.** `->` and `-->` therefore sit one column left
     of true centre. That asymmetry is the price of the mirror symmetry between
     directions, and a column of slack on a markerless arrow is not worth
     special-casing for.

2. **Centring makes a long label likely to cover a lifeline it passes.** The
   midpoint of a message is exactly where an intermediate participant tends to
   sit, so `Alice -->> Carol` across a `Bob` column draws `├──────direct──────>┤`
   where the left-anchored version left the crossing visible as
   `├direct───┼────────>┤`. Same call `flowchart.lua` already makes for a
   colliding edge label — text over a line is cosmetic, and it never draws a
   connection that is not in the source, whereas displacing the label would cost
   a column of layout or the label itself. What changed is the frequency: this
   was the rare case under step 6 and is the common one now, so it is stated in
   `sequence.lua`, in the goldens and in both user-facing documents rather than
   left to be rediscovered.

   The suite keeps an unlabelled crossing as its own golden, so the `┼` a
   message makes over a lifeline is still pinned by something.

## Deliberately deferred

Follow-up issues, not silent gaps: `alt` / `opt` / `loop` / `par` / `critical`
frames, activations, self-messages, notes, `autonumber`, `box`, `create` /
`destroy`, actors, and participant links.
