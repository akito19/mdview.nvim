# mdview.nvim

A terminal-only markdown viewer for Neovim. Running `:MdView` parses the
current markdown buffer with Neovim's built-in tree-sitter parsers and renders
it as decorated text in a split window. Saving the source buffer re-renders the
preview automatically.

No browser, no external processes, no runtime plugin dependencies.

## What it looks like

The target is GitHub's rendered Markdown, as closely as a terminal allows.
Terminals cannot vary font size, so heading level is encoded as the **length of
a bar**: one `█` glyph per `#` in the source, left-aligned in a fixed gutter,
so the staircase grows from the left edge while the heading text stays at one
constant column.

```
█       Heading One      H1 — 1 cell, then a dim underline band
██      Heading Two      H2 — 2 cells, then a dim underline band
███     Heading Three    H3 — 3 cells
████    Heading Four     H4 — 4 cells
█████   Heading Five     H5 — 5 cells
██████  Heading Six      H6 — 6 cells

  • top level            real bullets, one shape per depth
    ‣ second level
      · third level
  1. ordered item
  [ ] task
  [x] done task

█ quoted paragraph       blockquote: one █ per nesting depth
██ nested quote

  lua                    code block: a full-width grey band with a
  local x = 1            dim language label, content indented 2 cells
  print(x)

  ┌──────────────┬──────────────┐   tables: a full box-drawing grid,
  │ Command      │ Description  │   ruled between every row, with a
  ├──────────────┼──────────────┤   shaded bold header
  │ :MdView      │ Open preview │
  ├──────────────┼──────────────┤
  │ :MdViewClose │ Close it     │
  └──────────────┴──────────────┘
```

Horizontal rules are a full-width tinted band, not repeated characters. Inline
code is a shaded chip, like GitHub's.

### Text reflows, tables scroll

The preview window is always `'nowrap'`, because `'wrap'` is window-local and
could not reflow prose while leaving a wide table intact. **mdview wraps the
body text itself**, to the preview window's live width: paragraphs, list items,
blockquote content and headings are hard-wrapped, while tables, code blocks and
horizontal rules keep their full width and scroll sideways (`zl` / `zh`, or the
mouse) — exactly like GitHub's overflowing table container.

Continuation lines keep a hanging indent, so wrapped text lines up under the
first line's text rather than under its marker:

```
  • a list item whose text is long enough to need
    a second line
█ a blockquote that also runs past the available
█ width
```

Consecutive list items share one marker slot per depth, sized to the widest
marker among them, so the text column holds where the markers do not — numbers
are right-aligned in it, and a checkbox beside a bullet pads the bullet rather
than shifting its neighbour's text:

```
   9. nine            •   a plain item
  10. ten             [ ] a task
```

Inside a blockquote the line between two blocks is not blank: it carries the
bars both blocks have in common, so the `█` runs down the whole quote instead
of breaking at every paragraph.

Wrapping is measured in **display cells**, not bytes or characters, so CJK is
handled correctly. Japanese has no spaces, so a break is allowed between any
two full-width characters, with minimal kinsoku: `。、」』）］｝〕・？！` never
start a line and `「『（［｛〔` never end one.

Wrapping stops below a floor of 8 cells. A heading's gutter is 8 cells wide (14
under `ambiwidth = "double"`), so in a narrow split there can be less room left
than a couple of CJK characters — at which point the block is emitted long and
scrolls sideways like a table, rather than trickling down the window two
syllables at a time.

Resizing the preview reflows it. The width is compared against the one used for
the last render, so resizing an unrelated window costs nothing.

### Which characters are safe?

Two different questions decide this, and they have different answers.

**Box drawing (U+2500–257F) and block elements (U+2580–259F) are safe**, because
the terminal draws them itself. Ghostty renders those two ranges with a built-in
sprite renderer rather than pulling glyphs from the configured font, so they
tile perfectly — horizontally *and* vertically — whatever the font covers. That
is why tables get a real grid.

**Everything outside those ranges is only as good as the font's coverage.**
Parsing the `cmap` of Monaco — a common terminal font, used here as a
conservative proxy for "safe" — shows the obvious choices are simply **absent**:
`● ◦ ▪ ■ ☐ ☑` are not in the font at all, so macOS substitutes them from a
fallback face whose metrics do not match the cell. mdview never emits them, and
checkboxes stay ASCII `[ ]` / `[x]`.

The complete set of non-ASCII characters mdview's own decoration emits:

| Glyph | Codepoint | Safe because | Used for |
|---|---|---|---|
| `█` | U+2588 FULL BLOCK | terminal-drawn (and in Monaco) | heading bars, blockquote bars |
| `•` | U+2022 BULLET | in Monaco | list bullet, depth 1 (GitHub's own bullet) |
| `‣` | U+2023 TRIANGULAR BULLET | in Monaco | list bullet, depth 2 |
| `·` | U+00B7 MIDDLE DOT | in Monaco | list bullet, depth 3 |
| `┌┬┐├┼┤└┴┘─│` | U+2500–257F | terminal-drawn | table grid, mermaid diagrams |

(v2 dropped box drawing after blaming the font for gaps between `─` glyphs. The
diagnosis was wrong: the terminal never asked the font for them. The heading
bars that looked identical in v2 were a separate problem — `█` and `▉` differ by
one eighth of a cell, roughly a pixel — and bar *length* fixed that in v4.)

If your terminal does **not** draw those ranges natively, set
`marker_style = "block"`. The layout is identical, but every marker cell holds
an ordinary **space carrying a background highlight** instead of a glyph, and
tables fall back to padding-separated columns. A space has no outline, so a run
of them is a solid rectangle at exact cell metrics in *any* font, and the
rendered buffer becomes pure ASCII plus your own document text.

Background colors are *computed*, not hardcoded: the element's foreground color
is blended into `Normal`'s background at a chosen alpha, and recomputed on
`ColorScheme`. When `Normal.bg` cannot be resolved (transparent terminal, no
`'termguicolors'`), the tint backgrounds are skipped — but the marker groups
fall back to `reverse` so they stay visible, because an invisible marker would
silently erase the whole hierarchy.

Two elements have no marker to fall back on: a code block's fences are stripped
and a horizontal rule *is* a blank line, so their band is the whole of their
presentation. Rather than vanishing, `MdviewCodeBlock` links to `CursorLine`
and `MdviewRuleBg` to `Visual` — different groups, so a divider never reads as
a code block. The same applies under `highlights.blend = false`.

## Requirements

- Neovim **0.10+**
- The bundled `markdown` and `markdown_inline` tree-sitter parsers (shipped
  with Neovim; no nvim-treesitter installation required)

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "akito19/mdview.nvim",
  cmd = { "MdView", "MdViewClose", "MdViewToggle" },
  opts = {},
}
```

With [vim-plug](https://github.com/junegunn/vim-plug):

```vim
Plug 'akito19/mdview.nvim'
```

Calling `setup()` is optional — the plugin works out of the box.

## Usage

| Command | Description |
|---|---|
| `:MdView [vertical\|horizontal]` | Open (or re-render) the preview for the current markdown buffer. The optional argument overrides the configured split direction. |
| `:MdViewClose` | Close the preview (works from the source or the preview window). |
| `:MdViewToggle [vertical\|horizontal]` | Toggle the preview. |

While a preview is open, `:w` in the source buffer re-parses and re-renders it.
Closing the preview window with `:q`, or wiping the source buffer, cleans the
session up automatically. Each markdown buffer owns an independent preview, so
multiple previews can be open at once.

### Lua API

The whole supported surface — `mdview.window` and `mdview.highlights` are
internal and change shape without notice.

| Call | Returns |
|---|---|
| `require("mdview").setup(opts)` | the merged, validated config |
| `require("mdview").open(direction)` | `false` when the buffer is not markdown |
| `require("mdview").close()` | `false` when the buffer had no preview |
| `require("mdview").toggle(direction)` | whether a preview is open afterwards |
| `require("mdview").is_open(buf)` | whether `buf` (default: current) has one |

`is_open` and `close` accept either side of a session, so a preview buffer
answers as truthfully as its source does:

```lua
vim.keymap.set("n", "<leader>m", function()
  if require("mdview").is_open() then
    require("mdview").close()
  else
    require("mdview").open("horizontal")
  end
end)
```

## Configuration

Defaults shown; pass any subset to `require("mdview").setup()` (or `opts` with
lazy.nvim):

```lua
require("mdview").setup({
  split = "vertical",        -- "vertical" | "horizontal"
  width = 0.5,               -- preview width: <= 1 is a fraction of the screen,
                             -- above 1 an absolute column count (so 1 = full screen)
  height = 0.5,              -- preview height (horizontal split), same rule
  wrap = true,               -- hard-wrap body text (the window is always 'nowrap')
  text_width = nil,          -- nil = wrap to the preview's live width; a number caps it
  code_block_syntax = true,  -- tree-sitter highlighting inside fenced code blocks
  elements = {               -- per-element decoration toggles
    headings = true,
    emphasis = true,
    code_blocks = true,
    lists = true,
    blockquotes = true,
    links = true,
    tables = true,
    horizontal_rules = true,
    mermaid = true,          -- draw ```mermaid flowcharts (see below)
  },
  -- how every bar / bullet / border is drawn:
  --   "glyph" -- real characters, from the verified-safe set only
  --   "block" -- spaces carrying a background highlight (any font)
  marker_style = "glyph",
  heading = {
    gutter = 6,              -- bar gutter width in cells; the bar is
                             -- `level` cells, LEFT-aligned in it
    bar = "█",               -- U+2588; fills its cell, so it needs no backdrop
    bold = true,             -- heading text is bold
    underline_levels = 2,    -- levels 1..N get GitHub's border-bottom band
  },
  code = {
    language_label = true,   -- dim header line carrying the fence language
    line_numbers = false,    -- right-aligned line numbers in the gutter
  },
  tables = {
    borders = true,          -- full box-drawing grid; false = `│` columns only
    zebra = false,           -- redundant once every row is ruled
  },
  highlights = {
    blend = true,            -- compute background groups from Normal.bg
  },
  icons = {
    bullets = { "•", "‣", "·" },                        -- cycled by depth
    checkbox = { unchecked = "[ ]", checked = "[x]" },  -- ASCII: font-safe
  },
})
```

Setting an entry of `elements` to `false` renders that element as plain text
with no decoration at all. `highlights.blend = false` keeps the markers but
skips every computed tint background.

`wrap = false` turns hard-wrapping off entirely: every block becomes one long
logical line and the whole buffer scrolls horizontally. `text_width` only ever
*caps* the width — a value wider than the preview window is ignored, so text
never runs off the edge.

`tables.borders = false` drops the horizontal rules and separates columns with
`│` alone (the v4 look); `tables.zebra = true` brings the alternating row tint
back on top of either.

`heading.underline_levels = 0` disables the H1/H2 band entirely; a value of 6
gives every level one. A heading level deeper than `heading.gutter` still gets
a 1-cell bar — a zero-width marker would be invisible. Lists nested deeper than
`#icons.bullets` cycle back to the first bullet, and their colour cycles with
them.

Under `marker_style = "block"` the layout is unchanged, but `heading.bar`,
`icons.bullets` and `tables.borders` are ignored: bar and bullet cells become
background-coloured spaces and table columns are separated by padding alone.
`icons.checkbox` and every other key apply to both styles. An invalid
`marker_style` warns and falls back to `"glyph"`.

`setup()` validates what it is given rather than merging it blindly. An
unrecognised key is reported by its full path and dropped, so a typo such as
`marker_syle = "block"` or `elements.headins = false` is a warning instead of a
silent no-op; a value of the wrong type warns and keeps the default. List-valued
options — currently `icons.bullets` — **replace** the default rather than merging
into it, so `icons.bullets = { "•" }` really is a one-entry cycle and not
`{ "•", "‣", "·" }`. Nested tables such as `icons.checkbox` still merge key by
key, so setting only `checked` leaves `unchecked` at its default.

Removed in v5: `tables.separator`, replaced by the border set. Removed in v4:
`heading.bars`, `heading.background`, `heading.padding`, `icons.quote_bars` and
`code.bar`. The graduated heading backgrounds they supported differed by only a
few percent of alpha, which is invisible in practice; bar length carries the
hierarchy instead.

### Highlight groups

Foreground groups are defined with `default = true`, so you can override them
from your colorscheme or config:

`MdviewH1`..`MdviewH6`, `MdviewHeadingBold`, `MdviewBold`, `MdviewItalic`,
`MdviewBoldItalic`, `MdviewStrikethrough`, `MdviewCode`, `MdviewCodeHeader`,
`MdviewCodeLineNr`, `MdviewLink`, `MdviewQuote`, `MdviewBullet`,
`MdviewCheckbox`, `MdviewTableHead`, `MdviewTableBorder`, `MdviewTableSep`.

`MdviewTableBorder` (reinstated in v5) paints every `┌ ┬ ┐ ├ ┼ ┤ └ ┴ ┘ ─ │` of
the grid; `MdviewTableSep` is used instead when `tables.borders = false`.

`MdviewHeadingBold` is painted on top of `MdviewH1`..`MdviewH6` when
`heading.bold` is set. It is a separate group because Neovim cannot attach
extra attributes to a `default = true` link, and the level colour has to keep
coming from one.

Background groups are **computed** by blending into `Normal.bg`, not linked, so
the shading stays consistent regardless of the colorscheme:

`MdviewCodeBg` (the inline-code chip), `MdviewCodeBlock` (the fenced-block
band), `MdviewHeadingUnderline` (the H1/H2 band), `MdviewQuoteBg`,
`MdviewTableHeadBg`, `MdviewTableZebra`, `MdviewRuleBg`.

`MdviewBullet1`..`MdviewBullet3` are computed *foreground* colors, dimming with
nesting depth; when no color can be resolved they link back to `MdviewBullet`
so a bullet is never invisible.

Marker groups carry the same color as **both** foreground and background, so
one group serves both marker styles — `█` fills its cell under `"glyph"`, and
the same group paints a space under `"block"`:

`MdviewH1Bar`..`MdviewH6Bar` (that heading's foreground color), `MdviewQuoteBar`,
`MdviewBulletBar1`..`MdviewBulletBar3` (`"block"` style bullets).

Reinstated in v5: `MdviewTableBorder`, dropped in v2 with the grid itself.

Removed in v4: `MdviewH1Bg`..`MdviewH6Bg`, `MdviewQuoteBar1`..`MdviewQuoteBar3`,
`MdviewBulletBar4`, `MdviewCodeBar`, `MdviewCodeBarBlock`.

All of these are recomputed on `ColorScheme`; override them with `nvim_set_hl`
after that event. `highlights.blend = false` leaves the `*Bg` groups empty and
the `*Bar` groups on their `reverse` fallback — they are never cleared, since an
invisible marker would erase the hierarchy.

## Rendering

- Headings: `#` markers stripped, a `█` bar of `level` cells (one per `#`)
  left-aligned in the gutter, bold text at a constant column, and a dim
  full-width underline band below H1 and H2 (GitHub's `border-bottom`)
- Emphasis / strikethrough: markers stripped, highlighted
- Inline code: markers stripped, rendered as a shaded chip (background plus
  foreground)
- Fenced code blocks: fences stripped, a full-width background band containing
  a dim language label line and the content indented 2 cells, optional line
  numbers, per-language tree-sitter highlighting (graceful fallback when a
  language parser is unavailable)
- Links: `[text](url)` renders as `text` with `MdviewLink`
- Lists: real `•` / `‣` / `·` bullets cycling by depth and dimming with it, a
  2-cell base indent plus 2 per nesting depth, ordered numbers kept, ASCII task
  checkboxes `[ ]`/`[x]`
- Blockquotes: `>` replaced by one `█` per nesting depth in a dim color, plus a
  tinted line background and dimmed body text
- Tables: re-laid out with display-width-aware (CJK-safe) columns inside a full
  box-drawing grid — a rule above the header, below it, between every body row
  and below the last — with a tinted+bold header row and `:---:` alignment
  honored. Never wrapped: a wide table scrolls
- Horizontal rules: a blank line tinted across the full window width
- Mermaid flowcharts and sequence diagrams: a ` ```mermaid ` fence inside the
  [supported subset](#mermaid-diagrams) is laid out and drawn with the same
  box-drawing glyph set as tables. Never wrapped: a wide diagram scrolls
- Body text (paragraphs, list items, blockquote content, headings) is
  hard-wrapped to the preview's width, measured in display cells, with a hanging
  indent on continuation lines and inline highlight spans split across the
  break. Tables, code blocks and rules are never wrapped
- HTML blocks and unknown elements fall back to raw text

## Mermaid diagrams

A ` ```mermaid ` fence is drawn as a box-and-line diagram, in pure Lua, with no
external process and no new glyphs — the same `┌┬┐├┼┤└┴┘─│` the table grid
already uses, plus ASCII end markers.

```
flowchart TD                      ┌───────┐
A[Parse] --> B[Layout]            │ Parse │
B --> C[Draw]                     └───┬───┘
                                      v
                                 ┌────┴───┐
                                 │ Layout │
                                 └────┬───┘
                                      v
                                  ┌───┴──┐
                                  │ Draw │
                                  └──────┘
```

**Anything outside the supported subset falls back to an ordinary labelled code
block** — no error, no half-drawn diagram. A wrong diagram is worse than no
diagram, so every ambiguity resolves towards the fallback.

### `flowchart` / `graph`

| Supported | |
|---|---|
| Header | `flowchart` / `graph`, direction `TB` `TD` `BT` `LR` `RL` (default `TB`) |
| Nodes | all fifteen bracket shapes — but every one **draws as a rectangle** |
| Node labels | quoted text, `<br/>` line breaks, `:::class` suffix (ignored) |
| Edges | `-->` `---` `-.->` `==>` `--o` `--x` `~~~`, any length |
| Edge style | `-.->` and `==>` differ by **colour**, not by glyph |
| Edge labels | `A -->\|text\| B` and `A -- text --> B` |
| Chaining | `A --> B --> C`, `A & B --> C & D`, and mixed forms |
| Ignored | `%%` comments, `classDef` / `class` / `style` / `linkStyle` / `click`, frontmatter, `%%{init}%%` |

| Falls back to a code block | Why |
|---|---|
| `subgraph` … `end` | containers change the layout materially |
| Cycles | the layout is layered and DAG-only |
| `<-->` `o--o` `x--x` | a source-end marker collides with the box border, and drawing them one-directional would be wrong |
| `<br/>` in an *edge* label | edge labels occupy a single row |
| Node ids outside `[A-Za-z0-9_]` | mermaid documents no id grammar, so the conservative class is the only defensible one |
| `@{ shape: … }`, edge ids, markdown-string labels | not implemented |
| More than `max_nodes` / `max_edges` | a guard, so one pathological fence cannot stall a `:w` |
| `marker_style = "block"` | a diagram is nothing but box drawing |

Numeric entity codes (`#35;`, `#9829;`) are left literal rather than decoded:
decoding one would have the renderer synthesise a glyph outside the verified-safe
set from pure-ASCII source.

Node shapes are not differentiated because box drawing has no diamond and no
circle, and adding `╭╮╰╯` for rounded corners would only solve a third of the
problem. Layout is deliberately deterministic — items are ordered by first
appearance rather than by crossing minimisation — so the same source always
renders the same way.

### `sequenceDiagram`

Participants are columns in source order, messages are rows in time order.

```
sequenceDiagram             ┌───────┐  ┌─────┐  ┌───────┐
Alice->>Bob: ask            │ Alice │  │ Bob │  │ Carol │
Bob->>Carol: check          └───┬───┘  └──┬──┘  └───┬───┘
Carol-->>Alice: done            │         │         │
                                ├──ask───>┤         │
                                │         │         │
                                │         ├─check──>┤
                                │         │         │
                                ├<───────done───────┤
                                │         │         │
```

| Supported | |
|---|---|
| Header | `sequenceDiagram`, alone on its line |
| Participants | `participant A`, `participant A as Alice`, `participant A as "Alice"` |
| Participant labels | `<br/>` line breaks, making a taller box |
| Implicit participants | an id first seen in a message, in source order |
| Messages | `->` `-->` `->>` `-->>` `-x` `--x` `-)` `--)`, one per line |
| Message style | `--` is dashed and differs by **colour**, not by glyph |
| End markers | `>` `<` for `->>`, `x` for `-x`, `)` `(` for the async `-)` |
| Message text | `A->>B: text` — optional, quoted or bare, runs to end of line, centred on the run |
| Ignored | `%%` comments, frontmatter, `%%{init}%%` |

| Falls back to a code block | Why |
|---|---|
| `alt` `else` `opt` `loop` `par` `and` `critical` `option` `break` `rect` `end` | frames nest *and* span lifelines, so they change the layout materially — this diagram type's `subgraph` |
| `Note left of` / `right of` / `over` | not implemented |
| `activate` / `deactivate`, and `A->>+B` | an activation changes a lifeline's shape rather than decorating it |
| `A->>A` (a self-message) | it needs a loop back onto one lifeline, a row shape this layout has not got |
| `<<->>`, `<<-->>` | a source-end marker has nowhere to go but the lifeline junction |
| `<br/>` in *message* text | the text is drawn on the single row of its arrow |
| `autonumber`, `box`, `create`, `destroy`, `link`, `links` | not implemented |
| `actor` | the stick figure is the whole difference from `participant`, so drawing one as the other would say something the source did not |
| Ids outside `[A-Za-z0-9_]`, more than `max_nodes` participants or `max_edges` messages | as for a flowchart |

`;` does **not** separate statements here: message text is free text and
routinely contains one, and mermaid itself terminates on the newline.

Message text is centred between the two lifelines, as mermaid draws it, which
means a label on a message that skips a column usually covers the lifeline it
passes — `done` above hides Bob's. Text over a line is cosmetic and no
connection that is not in the source is ever drawn, so the label wins; an
unlabelled message leaves the crossing visible as `┼`.

There are no bottom participant boxes. Mermaid repeats them; three rows and a
duplicate of every label to restate what the top of the diagram already says is
not worth it in a terminal.

## Development

```sh
make test   # headless test suite (mini.test; clones mini.nvim into .deps/)
```

Manual check: `nvim -u tests/minit.lua README.md`, then `:MdView`.

## Future work

- Scroll sync between source and preview
- Live rendering on `TextChanged` (currently on `:w` only)
- Opening links with `gx` from the preview
- Footnotes
- Rendered HTML blocks (currently shown as raw text)
- Mermaid: `subgraph` containers, cycles, node shape differentiation, crossing
  minimisation, `classDef` colours, and diagram types other than `flowchart`

## License

MIT
