# mdview.nvim — Design

The authoritative description of how the plugin is built and why. For the
chronology of decisions that got here — including two that were wrong and had to
be corrected — see [decisions.md](decisions.md).

## Goal

Render the current markdown buffer as decorated text in a split window, on
demand, entirely inside the terminal. No browser, no external process, no
runtime plugin dependency. The visual target is GitHub's rendered Markdown, as
closely as a fixed-cell grid allows.

Requirements that shaped everything else:

- Command-driven, not always-on. `:MdView` parses and renders on demand.
- Vertical split by default; horizontal available per-call or by config.
- Saving the source buffer (`:w`) re-renders the open preview.
- Parsing uses Neovim's bundled tree-sitter `markdown` + `markdown_inline`
  grammars (Neovim 0.10+).

## Module Layout

```
plugin/mdview.lua        user commands only, so the Lua tree loads on first use
lua/mdview/
  init.lua               setup(), open(), close(), toggle()
  config.lua             defaults + deep merge; setup() is optional
  highlights.lua         Mdview* groups, including ones computed by blending
  parser.lua             tree-sitter walk -> flat IR
  renderer.lua           IR -> { lines, decorations }   PURE: no API access
  window.lua             scratch buffer, split, session lifecycle, extmarks
```

`renderer.lua` being pure is load-bearing: it is the piece with the most logic
(wrapping, table layout, span splitting) and it is unit-tested directly with
plain tables in and plain tables out. Anything needing a buffer, a window or a
colour lives in `window.lua` or `highlights.lua`.

### Parser

`vim.treesitter.get_parser(bufnr, "markdown")`, then `parser:parse(true)` so
injected regions are parsed too. The `markdown_inline` trees are indexed by
region start so a block node can find its inline tree.

The IR is deliberately flat: list items and blockquotes carry a `depth`/`quote`
number rather than nesting children, which suits a line-oriented renderer.
Inline runs become `{ text, style, url }` segments with styles accumulated down
the walk, so `**_x_**` yields one `bold_italic` segment.

### Renderer

Produces `{ lines, decorations }`. Decoration kinds: `hl` (a byte range),
`line_hl` (whole-line background), `virt_text`, and `code` (a fenced region for
per-language highlighting, applied later by `window.lua`).

All columns are byte offsets; all widths are measured with `strdisplaywidth`.
Never count characters — see [Environment gotchas](#environment-gotchas).

### Window

Sessions are keyed by **source** buffer, so several markdown buffers each own an
independent preview:

```lua
sessions[src_buf] = { preview_buf, preview_win, direction, width, augroup }
```

One augroup per session drives `BufWritePost` (re-render), `BufWipeout`/
`BufDelete` on the source (cleanup), `WinClosed` on the preview (cleanup, for a
manual `:q`), and `WinResized`/`VimResized` (re-render, but only when the
preview's width actually changed). Every path routes through one idempotent
teardown that removes the session first, so re-entrant callbacks no-op.

## Visual Design

### Headings — bar length is the only rule

A terminal cannot vary font size, so heading level is encoded as the length of a
`█` bar: **one cell per `#` in the source**, left-aligned in a fixed gutter so
the staircase grows from the left edge while body text stays at one constant
column.

```
█       Heading One
██      Heading Two
...
██████  Heading Six
```

H1 and H2 additionally get a dim full-width underline band, mirroring GitHub's
`border-bottom`. H3–H6 get none, exactly as on GitHub.

Two earlier encodings failed and must not be reintroduced: graduated line
backgrounds differing by a few percent of alpha (invisible), and partial-block
glyphs of varying thickness (`▉▊▋▌▏` differ by 1/8 of a cell — about one pixel).

### Everything else

| Element | Rendering |
|---|---|
| Lists | real bullets `• ‣ ·` by depth, 2-cell base indent plus 2 per depth |
| Blockquote | one `█` per nesting depth, dimmed body text |
| Inline code | GitHub's chip: a computed background plus a foreground |
| Code block | full-width grey band, dim language label line, content indented 2 |
| Table | full box-drawing grid, bold shaded header, alignment honored |
| Horizontal rule | a blank line with a tinted background |
| Checkbox | ASCII `[ ]` / `[x]` — no font can be assumed to have `☐`/`☑` |

### Glyph set

Only these non-ASCII characters are emitted as decoration:

- `█` U+2588, and box drawing `┌ ┬ ┐ ├ ┼ ┤ └ ┴ ┘ ─ │` — safe because Ghostty
  draws U+2500–257F and U+2580–259F with its own sprite renderer rather than
  from the font, so they tile in both directions whatever the font covers.
- `• ‣ ·` — verified present in Monaco's `cmap`.

Deliberately never used: `● ◦ ▪ ■ ░ ▓ ☐ ☑`, absent from Monaco and therefore
substituted from a fallback face with mismatched metrics.

`marker_style = "block"` is the fallback for terminals that draw neither range
natively: identical layout, but every marker cell is a space carrying a
background highlight and tables lose their grid. A space has no glyph outline,
so a run of them is a solid rectangle in any font.

## Wrapping and Scrolling

Neovim's `wrap` is window-local, so one window cannot reflow prose while leaving
tables unwrapped. To get GitHub's behaviour — text reflows, wide tables scroll
sideways — the preview window is **always `nowrap`** and the renderer wraps text
itself.

- Wrapped: paragraphs, list items, blockquote content, headings.
- Never wrapped: tables, code blocks, horizontal rules. These are what the
  horizontal scrolling exists for (`zl` / `zh`).
- Continuation lines keep a hanging indent, and blockquotes repeat their `█`
  prefix at the same depth.
- Breaking is measured in display cells. CJK has no spaces, so a break is
  allowed between any two characters, with minimal kinsoku: never start a line
  with `。、」』）］｝〕・？！`, never end one with `「『（［｛〔`.
- Inline spans crossing a break are **split** into one decoration per emitted
  line, with columns recomputed relative to each line including its prefix.

The target width comes from the live preview window via `opts.width`, capped by
`text_width` when set. `WinResized` re-renders so prose reflows on resize.

## Environment Gotchas

These have each caused a real bug. Read before touching layout code.

- **`ambiwidth = "double"`** (set in this user's config) makes every East Asian
  Ambiguous character two cells — including `█ │ ─ • ·` but *not* `‣`. Padding by
  character count instead of `strdisplaywidth` drifts by one cell per unit.
  Always measure; there are regression tests for both settings.
- **`strdisplaywidth` is not additive.** On a long run of `─` it can exceed the
  sum of the per-character widths. When auditing whether rendered lines line up,
  measure with `strwidth`; a mismatch seen only via `strdisplaywidth` is
  probably an artifact.
- **Table columns are widened** so a whole number of `─` spans each one exactly,
  otherwise the rules come out twice the width of the rows under `ambiwidth =
  "double"`.

## Testing

`make test` runs mini.test headlessly; mini.nvim is cloned into `.deps/`.

- `test_parser.lua` — markdown in, IR shape out (child Neovim)
- `test_renderer.lua` — the bulk: pure-function goldens, wrapping, tables,
  character-set guarantees, both `ambiwidth` settings
- `test_highlights.lua` — blend maths, degradation without `termguicolors`
- `test_commands.lua` — end-to-end window/session behaviour (child Neovim)

## Out of Scope

Scroll sync, live `TextChanged` rendering, `gx` link opening, footnotes, and
rendered HTML blocks (shown as raw text).
