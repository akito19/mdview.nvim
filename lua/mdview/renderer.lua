--- IR -> { lines, decorations }. Pure function: no buffer or window access.
---
--- v4 targets GitHub's rendered Markdown as closely as a terminal allows.
--- A terminal cannot vary font size, so heading depth is encoded as the
--- LENGTH of a left bar: `level` cells, matching the number of `#` in the
--- source, LEFT-aligned in a fixed gutter so the staircase grows from the left
--- edge while the heading text starts at the same display column at every level.
---
--- Every non-ASCII character this module emits comes from a verified-safe set:
---
---   █ U+2588 FULL BLOCK        heading bars, blockquote bars
---   • U+2022 BULLET            list bullet, depth 1
---   ‣ U+2023 TRIANGULAR BULLET list bullet, depth 2
---   · U+00B7 MIDDLE DOT        list bullet, depth 3
---   ┌┬┐├┼┤└┴┘─│               table grid borders (U+2500..U+257F)
---
--- Box drawing (U+2500..U+257F) and block elements (U+2580..U+259F) are safe
--- because the terminal (Ghostty) draws them with its own built-in sprite
--- renderer instead of taking them from the configured font, so they tile
--- perfectly whatever the font covers. Everything *outside* those two ranges is
--- still judged against Monaco's `cmap`: `● ◦ ▪ ■ ☐ ☑` are absent from it, get
--- substituted from a fallback face with mismatched metrics, and are therefore
--- never used -- checkboxes stay ASCII `[ ]` / `[x]`.
---
--- `marker_style = "block"` keeps the v3 fallback for terminals that draw
--- neither range natively: identical layout, but every marker cell holds an
--- ordinary SPACE carrying a background highlight and tables lose their grid.
--- A space has no glyph outline, so a run of them is a solid rectangle in every
--- font. Under that style the emitted text is pure ASCII plus the document's
--- own characters.
---
--- Body text (paragraphs, list items, blockquote content, headings) is
--- hard-wrapped here, because the preview window is always 'nowrap': tables and
--- code blocks must be able to run off the right edge and scroll. The target
--- width arrives via `opts.width`; this module never touches a window.
---
--- Decoration kinds (columns/lengths are in bytes, multibyte-safe):
---   { kind = "hl", line, col_start, col_end, group, priority }
---   { kind = "line_hl", line, group, priority }        -- whole-line background
---   { kind = "virt_text", line, text, group, pos }     -- virtual text
---   { kind = "code", lang, row, col_offset, lines }    -- fenced code region for
---                                                      -- per-language highlighting
--- All line numbers are 0-based.
local M = {}

-- Also pure: plain Lua in, `{ lines, decorations }` out, no buffer or window.
-- Diagram layout is a large, self-contained problem, so it lives in its own
-- module rather than swelling the one that already holds the most logic.
local mermaid = require("mdview.mermaid")

local style_hl = {
  bold = "MdviewBold",
  italic = "MdviewItalic",
  bold_italic = "MdviewBoldItalic",
  code = "MdviewCode",
  link = "MdviewLink",
  strikethrough = "MdviewStrikethrough",
}

-- Extmark priorities (higher wins).
local PRI_BG = 90 -- line backgrounds (code block band, zebra rows, underline)
local PRI_QUOTE = 95 -- dimmed blockquote body text
local PRI_STRUCT = 100 -- bars, bullets, heading text
local PRI_INLINE = 110 -- inline emphasis/code/link spans

local displaywidth = vim.fn.strdisplaywidth

--- Number of distinct bullet colours (`MdviewBullet1..3` / `MdviewBulletBar1..3`).
local BULLET_LEVELS = 3

--- Narrowest column body text is wrapped into, in cells. Below this the block
--- is emitted long instead: 8 cells is four CJK characters, and anything less
--- reads as a vertical trickle of syllables rather than a paragraph.
local MIN_WRAP_WIDTH = 8

-- `strdisplaywidth` is a Lua->vimscript bridge crossing, and `characters()`
-- needs one per character of every wrapped block -- so a render costs O(document
-- characters) crossings for an answer that depends on nothing but the character
-- and 'ambiwidth'. A document holds far fewer DISTINCT characters than
-- characters, so per-character memoisation removes almost all of it.
--
-- Only single characters are cached. Whole-string measurements (prefixes,
-- markers, table cells) keep calling `displaywidth` directly: their cardinality
-- grows with the document rather than with its alphabet, so caching them would
-- trade a bounded table for an unbounded one.
--
-- The cache is keyed on the 'ambiwidth' that filled it, because that option is
-- exactly what makes `•` one cell or two -- and the regression tests flip it
-- inside a single process. `M.render` re-checks it once per render rather than
-- once per character, since reading `vim.o` is itself a bridge crossing and
-- would undo the saving. This is the module's one global dependency, and not a
-- new one: `displaywidth` already read the same option on every call.
local width_cache = {}
local width_cache_ambi = nil

local function sync_width_cache()
  local ambi = vim.o.ambiwidth
  if ambi ~= width_cache_ambi then
    width_cache = {}
    width_cache_ambi = ambi
  end
end

local function cellwidth(ch)
  local w = width_cache[ch]
  if not w then
    w = displaywidth(ch)
    width_cache[ch] = w
  end
  return w
end

------------------------------------------------------------------------------
-- Wrapping
--
-- The preview window is 'nowrap', so body text is broken here. Everything is
-- measured with `strdisplaywidth`: a byte or character count would be wrong for
-- Japanese, where every kana/kanji occupies two cells.
------------------------------------------------------------------------------

--- Minimal kinsoku shori. These may not *start* a line, ...
local NO_BREAK_BEFORE = {}
for _, c in ipairs({ "。", "、", "」", "』", "）", "］", "｝", "〕", "・", "？", "！" }) do
  NO_BREAK_BEFORE[c] = true
end

--- ... and these may not *end* one.
local NO_BREAK_AFTER = {}
for _, c in ipairs({ "「", "『", "（", "［", "｛", "〔" }) do
  NO_BREAK_AFTER[c] = true
end

--- Split `text` into characters with their byte offset (0-based) and cell width.
local function characters(text)
  local pos = vim.str_utf_pos(text)
  local out = {}
  for i = 1, #pos do
    local ch = text:sub(pos[i], (pos[i + 1] or (#text + 1)) - 1)
    out[i] = { byte = pos[i] - 1, str = ch, width = cellwidth(ch) }
  end
  return out
end

--- May a line break between `cs[k - 1]` and `cs[k]`?
---
--- Space-separated text breaks after a space. CJK has no spaces at all, so a
--- break is allowed between any two characters as soon as one side is
--- full-width -- which is exactly what every kana, kanji and Japanese
--- punctuation mark is. The two kinsoku sets then veto the breaks that would
--- leave a closing mark at the head of a line or an opening one at its tail.
local function break_allowed(cs, k)
  local prev, next_ = cs[k - 1], cs[k]
  if not prev or not next_ then
    return false
  end
  if next_.str == " " then
    return false -- a line never starts with a space
  end
  if NO_BREAK_BEFORE[next_.str] or NO_BREAK_AFTER[prev.str] then
    return false
  end
  if prev.str == " " then
    return true
  end
  return prev.width >= 2 or next_.width >= 2
end

--- Greedily break `text` into byte ranges no wider than the available cells.
---@param text string
---@param avail_first integer cells available on the first emitted line
---@param avail_cont integer cells available on every continuation line
---@return table[] list of { start = 0-based inclusive, stop = 0-based exclusive }
local function wrap_ranges(text, avail_first, avail_cont)
  local cs = characters(text)
  local n = #cs
  local ranges = {}
  local i = 1
  while i <= n do
    local avail = math.max(1, (#ranges == 0) and avail_first or avail_cont)
    -- `best` is the last break that still fits; `first` is the earliest break
    -- of any kind, used when a single word is wider than the whole target
    -- width -- it is emitted long rather than looping forever.
    local best, first, w = nil, nil, 0
    for j = i, n do
      w = w + cs[j].width
      local k = j + 1
      if k > n or break_allowed(cs, k) then
        first = first or k
        if w <= avail then
          best = k
        end
      end
      if w > avail and (best or first) then
        break
      end
    end
    local k = best or first or (n + 1)
    local start = cs[i].byte
    local stop = cs[k] and cs[k].byte or #text
    -- Never leave a trailing space on an emitted line.
    while stop > start and text:sub(stop, stop) == " " do
      stop = stop - 1
    end
    ranges[#ranges + 1] = { start = start, stop = stop }
    i = k
  end
  return ranges
end

--- Wrap one run of inline text into rendered pieces.
---
--- Spans carry byte offsets into `text`; when a break falls inside one it is
--- split into a piece per emitted line, each with columns relative to that
--- line's own text (the caller then shifts them past its prefix).
---@param text string joined inline text, without any prefix
---@param spans table[] { start_col, end_col, style, url } byte offsets into `text`
---@param first_prefix string prefix of the first emitted line
---@param cont_prefix string prefix of every continuation line (hanging indent)
---@param width integer|nil target width in cells; nil disables wrapping
---@return table[] list of { prefix = string, text = string, spans = table[] }
local function wrap_inline(text, spans, first_prefix, cont_prefix, width)
  if not width or text == "" or displaywidth(first_prefix .. text) <= width then
    return { { prefix = first_prefix, text = text, spans = spans } }
  end
  -- Below the floor, stop wrapping and let the block run off the right edge
  -- into the horizontal scroll -- the same treatment tables and code blocks
  -- already get. A heading's prefix is 8 cells, and 14 under 'ambiwidth'
  -- "double", so an ordinary narrow split can leave 4 cells: two CJK
  -- characters per line, which is far less readable than one long line the
  -- reader can scroll. `math.max(1, ...)` in `wrap_ranges` would otherwise
  -- take this all the way down to a single cell.
  local avail = math.min(width - displaywidth(first_prefix), width - displaywidth(cont_prefix))
  if avail < MIN_WRAP_WIDTH then
    return { { prefix = first_prefix, text = text, spans = spans } }
  end
  local ranges = wrap_ranges(text, width - displaywidth(first_prefix), width - displaywidth(cont_prefix))
  local pieces = {}
  for idx, r in ipairs(ranges) do
    local piece_spans = {}
    for _, span in ipairs(spans) do
      local s = math.max(span.start_col, r.start)
      local e = math.min(span.end_col, r.stop)
      if e > s then
        piece_spans[#piece_spans + 1] =
          { start_col = s - r.start, end_col = e - r.start, style = span.style, url = span.url }
      end
    end
    pieces[idx] = {
      prefix = (idx == 1) and first_prefix or cont_prefix,
      text = text:sub(r.start + 1, r.stop),
      spans = piece_spans,
    }
  end
  return pieces
end

--- Resolve the width body text is wrapped to.
---
--- `wrap = false` disables wrapping entirely. Otherwise the live window width
--- (`opts.width`) is used, capped by `text_width` when that is set. With no
--- window width available -- direct calls from tests, say -- `text_width` alone
--- decides, and without it nothing is wrapped.
---@return integer|nil
local function target_width(config, opts)
  if config.wrap == false then
    return nil
  end
  local cap = tonumber(config.text_width)
  local avail = tonumber(opts and opts.width)
  if avail and avail > 0 then
    return (cap and cap > 0) and math.min(cap, avail) or math.floor(avail)
  end
  if cap and cap > 0 then
    return math.floor(cap)
  end
  return nil
end

--- Concatenate segments into one line; return text and byte-offset spans.
local function seg_line(segments)
  local parts, spans = {}, {}
  local col = 0
  for _, seg in ipairs(segments or {}) do
    parts[#parts + 1] = seg.text
    if seg.style then
      spans[#spans + 1] = { start_col = col, end_col = col + #seg.text, style = seg.style, url = seg.url }
    end
    col = col + #seg.text
  end
  return table.concat(parts), spans
end

--- Heading gutter width in cells. Always at least 1 so a bar is never
--- zero-width, i.e. never invisible.
local function heading_gutter(heading_cfg)
  local n = tonumber(heading_cfg.gutter)
  if not n then
    n = 6
  end
  return math.max(1, math.floor(n))
end

--- Render IR blocks into lines and decorations.
---@param blocks table IR block list from mdview.parser
---@param config table active config (mdview.config.get())
---@param opts table|nil { width = integer } live preview window width in cells
---@return table { lines = string[], decorations = table[] }
function M.render(blocks, config, opts)
  sync_width_cache()
  local width = target_width(config, opts)
  local icons = config.icons or {}
  local elements = config.elements or {}
  local heading_cfg = config.heading or {}
  local code_cfg = config.code or {}
  local table_cfg = config.tables or {}
  local mermaid_cfg = config.mermaid or {}
  -- Only an explicit "block" selects the v3 background-space markers.
  local block_style = config.marker_style == "block"

  -- The one glyph used for every solid bar. Under the block style each bar
  -- cell is a space instead, painted by the same highlight group.
  local bar_char = block_style and " " or (heading_cfg.bar or "█")

  local lines, decorations = {}, {}
  local line_bg = {} -- line -> true once a background has been claimed

  local function add_line(text)
    lines[#lines + 1] = text
    return #lines - 1 -- 0-based
  end

  --- Append a blank line unless the buffer already ends with one.
  ---@return integer index of the trailing blank line (0-based)
  local function ensure_blank()
    if #lines == 0 or lines[#lines] ~= "" then
      add_line("")
    end
    return #lines - 1
  end

  local function add_hl(line, col_start, col_end, group, priority)
    if group and col_end > col_start then
      decorations[#decorations + 1] = {
        kind = "hl",
        line = line,
        col_start = col_start,
        col_end = col_end,
        group = group,
        priority = priority or PRI_STRUCT,
      }
    end
  end

  --- Claim the whole-line background of `line`. First claim wins, so an
  --- enclosing context (blockquote, code band) is never overwritten by a
  --- later, weaker one.
  local function set_line_bg(line, group)
    if not group or line_bg[line] then
      return
    end
    line_bg[line] = true
    decorations[#decorations + 1] = { kind = "line_hl", line = line, group = group, priority = PRI_BG }
  end

  local function add_dec(dec)
    decorations[#decorations + 1] = dec
  end

  local function add_spans(line, spans, offset)
    for _, span in ipairs(spans) do
      local style = span.style
      local enabled = true
      if not elements.emphasis
        and (style == "bold" or style == "italic" or style == "bold_italic" or style == "strikethrough")
      then
        enabled = false
      end
      if not elements.links and style == "link" then
        enabled = false
      end
      if enabled then
        -- Inline code is GitHub's shaded chip: a background *and* a
        -- foreground. They are two groups because `MdviewCode` is a
        -- `default = true` link (so colorschemes can retarget it) and Neovim
        -- cannot attach extra attributes to a link.
        if style == "code" then
          add_hl(line, span.start_col + offset, span.end_col + offset, "MdviewCodeBg", PRI_INLINE - 1)
        end
        add_hl(line, span.start_col + offset, span.end_col + offset, style_hl[style], PRI_INLINE)
      end
    end
  end

  ------------------------------------------------------------------------
  -- Blockquotes: GitHub's left border, one `█` per nesting level, then a
  -- single separator space. Under the block style each bar cell is a space.
  ------------------------------------------------------------------------

  local function quote_prefix(block)
    local depth = block.quote or 0
    if depth == 0 then
      return ""
    end
    if not elements.blockquotes then
      return string.rep("> ", depth)
    end
    return string.rep(bar_char, depth) .. " "
  end

  --- Highlight the accumulated quote bars (not the text after them).
  local function quote_bar_hl(line, block)
    local depth = block.quote or 0
    if depth == 0 or not elements.blockquotes then
      return
    end
    add_hl(line, 0, depth * #bar_char, "MdviewQuoteBar", PRI_STRUCT)
  end

  --- Quote bars plus the quote line background.
  local function quote_deco(line, block)
    quote_bar_hl(line, block)
    if (block.quote or 0) > 0 and elements.blockquotes then
      set_line_bg(line, "MdviewQuoteBg")
    end
  end

  --- Dim the quoted body text itself (GitHub greys blockquote content).
  --- Lower priority than every structural and inline group, so it never
  --- steals a heading's or a span's colour.
  local function quote_text_hl(line, block, col_start)
    if (block.quote or 0) > 0 and elements.blockquotes then
      add_hl(line, col_start, #lines[line + 1], "MdviewQuote", PRI_QUOTE)
    end
  end

  --- The line between two blocks. Blank at the top level -- but *inside* a
  --- blockquote it carries the bars, because the bar has to run down the whole
  --- quote. An unprefixed gap splits a multi-paragraph quote into what reads
  --- as two separate quotes.
  ---
  --- The depth is the shallower of the two neighbours: a quote that deepens or
  --- ends between blocks only shares the bars both sides actually have.
  local function separator(prev, next_)
    local depth = math.min((prev and prev.quote) or 0, (next_ and next_.quote) or 0)
    if depth == 0 or not elements.blockquotes then
      return ensure_blank()
    end
    local ghost = { quote = depth }
    -- Bars only, no trailing separator space: nothing follows them on this
    -- line, and the background is a line highlight that fills the width anyway.
    local text = string.rep(bar_char, depth)
    if lines[#lines] == text then
      return #lines - 1 -- already separated
    end
    local l = add_line(text)
    quote_deco(l, ghost)
    return l
  end

  ------------------------------------------------------------------------
  -- Per-block renderers
  ------------------------------------------------------------------------

  --- `<bar><pad>  <text>`: the bar is `level` cells long -- matching the number
  --- of `#` in the source -- and LEFT-aligned in the gutter, so the six levels
  --- form a staircase growing from the left edge while the text column never
  --- moves.
  --- H1/H2 additionally get GitHub's `border-bottom`: a blank line carrying a
  --- dim full-width background.
  --- Continuation lines are indented to the text column -- past the gutter --
  --- and never repeat the bar.
  local function render_heading(b)
    local text, spans = seg_line(b.inline)
    local qp = quote_prefix(b)
    if not elements.headings then
      for _, piece in ipairs(wrap_inline(text, spans, qp, qp, width)) do
        local l = add_line(piece.prefix .. piece.text)
        quote_deco(l, b)
        add_spans(l, piece.spans, #piece.prefix)
      end
      return
    end

    local level = math.max(1, math.min(b.level or 1, 6))
    local group = "MdviewH" .. level

    local gutter = heading_gutter(heading_cfg)
    local bar_len = math.max(1, math.min(gutter, level))
    local bar = string.rep(bar_char, bar_len)
    -- The gutter holds `gutter` bar slots, so its width in cells depends on how
    -- wide the bar glyph actually is. `█` is East Asian Ambiguous: one cell
    -- under 'ambiwidth' "single" but two under "double", and padding by slot
    -- count alone would drift the text column by one slot per level.
    local slot_w = math.max(1, displaywidth(bar_char))
    local prefix = qp .. bar .. string.rep(" ", (gutter - bar_len) * slot_w) .. "  "
    -- Measured, not assumed: the continuation indent has to reach the text
    -- column even when the bar glyph is not exactly one cell wide.
    local cont = qp .. string.rep(" ", math.max(0, displaywidth(prefix) - displaywidth(qp)))

    for i, piece in ipairs(wrap_inline(text, spans, prefix, cont, width)) do
      local l = add_line(piece.prefix .. piece.text)
      quote_deco(l, b)
      if i == 1 then
        add_hl(l, #qp, #qp + #bar, group .. "Bar", PRI_STRUCT)
      end
      add_hl(l, #piece.prefix, #lines[l + 1], group, PRI_STRUCT)
      if heading_cfg.bold ~= false then
        add_hl(l, #piece.prefix, #lines[l + 1], "MdviewHeadingBold", PRI_STRUCT)
      end
      add_spans(l, piece.spans, #piece.prefix)
    end

    local underline_levels = tonumber(heading_cfg.underline_levels) or 0
    if level <= underline_levels then
      set_line_bg(add_line(""), "MdviewHeadingUnderline")
      add_line("") -- breathing room below the band
    end
  end

  --- Continuation lines repeat the quote prefix (so the `█` bar runs down the
  --- whole quote) and the indent, but nothing else.
  local function render_paragraph(b)
    local text, spans = seg_line(b.inline)
    local qp = quote_prefix(b)
    local ind = string.rep("  ", b.indent or 0)
    for _, piece in ipairs(wrap_inline(text, spans, qp .. ind, qp .. ind, width)) do
      local l = add_line(piece.prefix .. piece.text)
      quote_deco(l, b)
      quote_text_hl(l, b, #qp)
      add_spans(l, piece.spans, #piece.prefix)
    end
  end

  --- GitHub's grey box: a full-width background band with the content
  --- indented 2 cells, preceded by a dim language label inside the same band.
  --- No left bar (v3 had one); the band alone delimits the block.
  local function render_code_block(b)
    local qp = quote_prefix(b)
    local ind = string.rep("  ", b.indent or 0)
    if not elements.code_blocks then
      for _, cl in ipairs(b.lines) do
        local l = add_line(qp .. ind .. cl)
        quote_deco(l, b)
      end
      return
    end

    local base = qp .. ind
    local body = #b.lines > 0 and b.lines or { "" }
    local has_lang = b.lang ~= nil and b.lang ~= ""

    -- A ```mermaid fence becomes a drawn diagram when it falls inside the
    -- supported subset. `render` returns nil for everything else -- an
    -- unsupported construct, a cycle, the block marker style -- and the fence
    -- then renders as the ordinary code block below, exactly as before.
    --
    -- The dispatch lives here rather than in `parser.lua` on purpose: keeping
    -- it a `code_block` in the IR is what makes the fallback a no-op instead of
    -- a decision the parser would have to make before it could know.
    if has_lang and b.lang:lower() == "mermaid" and elements.mermaid ~= false then
      local diagram = mermaid.render(b.lines, {
        prefix = base .. "  ",
        marker_style = config.marker_style,
        max_nodes = mermaid_cfg.max_nodes,
        max_edges = mermaid_cfg.max_edges,
      })
      if diagram then
        if mermaid_cfg.language_label ~= false then
          local l = add_line(base .. "  " .. b.lang)
          quote_bar_hl(l, b)
          add_hl(l, #base + 2, #lines[l + 1], "MdviewCodeHeader", PRI_STRUCT)
        end
        local first = #lines
        for _, dl in ipairs(diagram.lines) do
          local l = add_line(dl)
          quote_deco(l, b)
        end
        for _, dec in ipairs(diagram.decorations) do
          dec.line = dec.line + first
          add_dec(dec)
        end
        return
      end
    end

    local function band(l)
      quote_bar_hl(l, b)
      set_line_bg(l, "MdviewCodeBlock")
    end

    if has_lang and code_cfg.language_label ~= false then
      local l = add_line(base .. "  " .. b.lang)
      band(l)
      add_hl(l, #base + 2, #lines[l + 1], "MdviewCodeHeader", PRI_STRUCT)
    end

    -- Gutter: either a fixed 2-space indent or right-aligned line numbers.
    local numbered = code_cfg.line_numbers == true
    local numw = numbered and #tostring(#body) or 0
    local gutter_len = numbered and (numw + 1) or 2

    local first
    for i, cl in ipairs(body) do
      local gutter = numbered and string.format("%" .. numw .. "d ", i) or "  "
      local l = add_line(base .. gutter .. cl)
      first = first or l
      band(l)
      if numbered then
        add_hl(l, #base, #base + numw, "MdviewCodeLineNr", PRI_STRUCT)
      end
    end

    if has_lang and #b.lines > 0 then
      add_dec({
        kind = "code",
        lang = b.lang,
        row = first,
        col_offset = #base + gutter_len,
        lines = b.lines,
      })
    end
  end

  --- The marker as it would be drawn with no padding at all, plus the group
  --- that colours it. Padding is decided separately, once the widest marker in
  --- the same list is known.
  local function marker_core(b)
    if not elements.lists then
      return (b.ordered and (b.marker or "1.") or (b.marker or "-")), nil
    end
    if b.checkbox then
      return ((icons.checkbox or {})[b.checkbox] or "?"), "MdviewCheckbox"
    end
    if b.ordered then
      return (b.marker or "1."), "MdviewBullet"
    end
    local bullets = icons.bullets or {}
    local idx = ((b.depth or 0) % math.max(#bullets, 1)) + 1
    local shade = math.min(idx, BULLET_LEVELS)
    if block_style then
      return " ", "MdviewBulletBar" .. shade -- one coloured cell
    end
    return (bullets[idx] or "-"), "MdviewBullet" .. shade
  end

  -- The bullet shapes are not all the same width under 'ambiwidth' "double"
  -- (`•` and `·` are ambiguous, `‣` is not), so every marker slot is at least
  -- as wide as the widest shape and the text column holds across depths. The
  -- block style draws no glyphs, so it does not pay for this.
  local bullet_floor = 1
  if not block_style then
    for _, shape in ipairs(icons.bullets or {}) do
      bullet_floor = math.max(bullet_floor, displaywidth(shape))
    end
  end

  --- Marker slot width per block. Every run of consecutive list items shares
  --- one slot, so the text column holds even when the markers differ in width:
  --- `9.` beside `10.`, or a `[ ]` checkbox beside a `•`. Measured once here
  --- rather than per item, which also keeps the widest-shape scan out of the
  --- render loop.
  ---
  --- The slot is keyed by depth AND orderedness. Depth because each level has
  --- its own column anyway; orderedness because a change of marker type starts
  --- a new list in CommonMark, and the IR has no list node to say so -- without
  --- it, a bullet list that merely happens to sit next to a numbered one would
  --- be padded out to fit the numbers.
  local function slot_key(b)
    return ((b.depth or 0) * 2) + (b.ordered and 1 or 0)
  end

  local marker_slot = {}
  do
    local blist = blocks or {}
    local i = 1
    while i <= #blist do
      if blist[i].type ~= "list_item" then
        i = i + 1
      else
        local j = i
        while j <= #blist and blist[j].type == "list_item" do
          j = j + 1
        end
        local widest = {}
        for k = i, j - 1 do
          local key = slot_key(blist[k])
          widest[key] = math.max(widest[key] or bullet_floor, displaywidth((marker_core(blist[k]))))
        end
        for k = i, j - 1 do
          marker_slot[blist[k]] = widest[slot_key(blist[k])]
        end
        i = j
      end
    end
  end

  --- Real bullets, one shape per depth, cycling beyond depth 3. GitHub
  --- indents lists from the body margin, so the base indent is 2 cells plus 2
  --- per nesting depth. Ordered numbers and checkboxes stay ASCII.
  local function render_list_item(b)
    local qp = quote_prefix(b)
    local depth = b.depth or 0
    -- Decorated lists get GitHub's 2-cell base indent; undecorated ones stay
    -- flush so they read as raw markdown.
    local ind = string.rep("  ", depth + (elements.lists and 1 or 0))
    local core, group = marker_core(b)
    -- `lead` is padding before the marker; the highlight has to skip it.
    local marker, lead = core .. " ", ""
    if elements.lists then
      local slot = marker_slot[b] or math.max(bullet_floor, displaywidth(core))
      local pad = string.rep(" ", math.max(0, slot - displaywidth(core)))
      if b.ordered then
        -- Numbers are right-aligned in the slot: `9.` and `10.` then end at
        -- the same column, so their text starts at the same one.
        lead = pad
        marker = lead .. core .. " "
      else
        marker = core .. pad .. " "
      end
    end
    local text, spans = seg_line(b.inline)
    -- Hanging indent: continuation text aligns under the item's text, not
    -- under its marker.
    local prefix = qp .. ind .. marker
    local cont = qp .. ind .. string.rep(" ", displaywidth(marker))
    for i, piece in ipairs(wrap_inline(text, spans, prefix, cont, width)) do
      local l = add_line(piece.prefix .. piece.text)
      quote_deco(l, b)
      quote_text_hl(l, b, #qp)
      if elements.lists and i == 1 then
        local at = #qp + #ind + #lead
        add_hl(l, at, at + #core, group, PRI_STRUCT)
      end
      add_spans(l, piece.spans, #piece.prefix)
    end
  end

  --- A blank line whose background is tinted across the full window width.
  local function render_rule(b)
    if not elements.horizontal_rules then
      add_line("---")
      return
    end
    local qp = quote_prefix(b)
    local l = add_line(qp)
    quote_bar_hl(l, b)
    set_line_bg(l, "MdviewRuleBg")
    add_line("") -- breathing room below the band
  end

  --- A full box-drawing grid: a rule above the header, below the header,
  --- between every body row and below the last one, with `│` between columns.
  --- Safe because the terminal draws U+2500..U+257F itself.
  ---
  --- Tables are NEVER wrapped -- they are exactly the content the preview's
  --- horizontal scrolling exists for.
  local function render_table(b)
    local qp = quote_prefix(b)
    local ncols = #b.header
    for _, row in ipairs(b.rows) do
      ncols = math.max(ncols, #row)
    end
    if ncols == 0 then
      return
    end

    -- The grid is inherently O(rows x columns): every intersection needs a
    -- padded cell, a junction and a rule segment whether or not a cell exists
    -- there. `ncols` comes from the WIDEST row, so a single 800-cell row makes
    -- every other row 800 columns wide too -- 14 KB of markdown then costs
    -- hundreds of megabytes, on every save. Past the cap the table is emitted
    -- as plain text instead, which costs only the cells that are really there.
    --
    -- 32 is far past anything a reader would write: at the minimum one cell per
    -- column a 32-column grid is already ~130 cells wide, wider than a
    -- full-screen preview, so no realistic table is affected by the bound.
    local max_cols = tonumber(table_cfg.max_columns) or 32

    -- Tables switched off, or wider than the cap: the source rows as text.
    -- Nothing is padded out to `ncols` here -- a row contributes exactly the
    -- cells it has, so the pathological table costs its real cell count rather
    -- than rows x columns.
    if not elements.tables or ncols > max_cols then
      local function plain(cells)
        local texts = {}
        for i, segments in ipairs(cells) do
          texts[i] = (seg_line(segments))
        end
        add_line(qp .. table.concat(texts, " | "))
      end
      plain(b.header)
      for _, row in ipairs(b.rows) do
        plain(row)
      end
      return
    end

    -- A cell that its row does not have renders as empty padding, so it needs
    -- no `seg_line` (two tables and a concat) and no measurement -- one shared
    -- immutable stand-in covers every absent cell in the table. Nothing below
    -- writes through a resolved cell, so sharing is safe.
    local EMPTY = { text = "", spans = {}, width = 0 }

    --- Resolve every cell to { text, spans, width }. The width is measured here
    --- once and read back by both the column-width pass and `content_line`;
    --- measuring is a Lua->vimscript crossing, so doing it twice per cell was
    --- half the cost of a wide table.
    local function resolve(cells)
      local out = {}
      for i = 1, ncols do
        local segments = cells[i]
        if segments == nil then
          out[i] = EMPTY
        else
          local text, spans = seg_line(segments)
          out[i] = { text = text, spans = spans, width = displaywidth(text) }
        end
      end
      return out
    end
    local header = resolve(b.header)
    local rows = {}
    for i, row in ipairs(b.rows) do
      rows[i] = resolve(row)
    end

    local widths = {}
    for i = 1, ncols do
      widths[i] = math.max(1, header[i].width)
    end
    for _, row in ipairs(rows) do
      for i = 1, ncols do
        if row[i].width > widths[i] then
          widths[i] = row[i].width
        end
      end
    end

    local lead = "  "
    -- The full grid needs horizontal tiling, which only holds when the
    -- terminal draws box drawing itself. The block style is the fallback for
    -- when it does not, so there it degrades to padding-separated columns.
    local borders = table_cfg.borders ~= false and not block_style
    local vert = block_style and "" or "│"
    -- Padded cell -> ` cell `, joined by `│` under the grid and by a bare
    -- separator (or plain padding) without it.
    local pad_cell = borders and 1 or 0
    local sep = borders and (" " .. vert .. " ") or (block_style and "   " or (" " .. vert .. " "))
    local border_group = borders and "MdviewTableBorder" or "MdviewTableSep"

    -- Box drawing is East Asian *Ambiguous*, so 'ambiwidth' = "double" makes
    -- every one of these characters two cells rather than one. The rules are
    -- runs of `─` while the cells they have to span are padded with 1-cell
    -- spaces, so a column has to be widened until a whole number of `─` covers
    -- it exactly -- otherwise the rules come out twice the width of the rows.
    local rule_w = math.max(1, displaywidth("─"))
    if borders and rule_w > 1 then
      for i = 1, ncols do
        widths[i] = widths[i] + (rule_w - (widths[i] + 2 * pad_cell) % rule_w) % rule_w
      end
    end

    --- One horizontal rule; `left`/`mid`/`right` are its junction characters.
    local function border_line(left, mid, right)
      local parts = {}
      for i = 1, ncols do
        parts[i] = string.rep("─", (widths[i] + 2 * pad_cell) / rule_w)
      end
      local l = add_line(qp .. lead .. left .. table.concat(parts, mid) .. right)
      quote_bar_hl(l, b)
      add_hl(l, #qp + #lead, #lines[l + 1], "MdviewTableBorder", PRI_STRUCT)
    end

    local function content_line(cells, bg, head)
      local parts = {}
      local col = #qp + #lead
      local infos, seps = {}, {}
      if borders then
        seps[#seps + 1] = { start = col, len = #vert }
        col = col + #vert + pad_cell
      end
      for i = 1, ncols do
        local cell = cells[i]
        local text = cell.text
        local pad = widths[i] - cell.width
        local align = b.align and b.align[i] or "none"
        local left_pad, right_pad
        if align == "right" then
          left_pad, right_pad = pad, 0
        elseif align == "center" then
          left_pad = math.floor(pad / 2)
          right_pad = pad - left_pad
        else
          left_pad, right_pad = 0, pad
        end
        parts[#parts + 1] = string.rep(" ", left_pad) .. text .. string.rep(" ", right_pad)
        infos[i] = { start = col + left_pad, len = #text }
        col = col + left_pad + #text + right_pad
        if i < ncols then
          -- The separator sits one space into the joiner.
          seps[#seps + 1] = { start = col + 1, len = #vert }
          col = col + #sep
        end
      end
      local body = table.concat(parts, sep)
      local text_line
      if borders then
        text_line = qp .. lead .. vert .. " " .. body .. " " .. vert
        seps[#seps + 1] = { start = col + pad_cell, len = #vert }
      else
        text_line = qp .. lead .. body
      end
      local l = add_line(text_line)
      quote_bar_hl(l, b)
      set_line_bg(l, bg)
      for _, s in ipairs(seps) do
        add_hl(l, s.start, s.start + s.len, border_group, PRI_STRUCT)
      end
      for i, info in ipairs(infos) do
        if head then
          add_hl(l, info.start, info.start + info.len, "MdviewTableHead", PRI_STRUCT)
        end
        add_spans(l, cells[i].spans, info.start)
      end
    end

    if borders then
      border_line("┌", "┬", "┐")
    end
    content_line(header, "MdviewTableHeadBg", true)
    for i, row in ipairs(rows) do
      if borders then
        border_line("├", "┼", "┤")
      end
      -- Zebra striping is redundant once every row is ruled, so it defaults
      -- off; an explicit `zebra = true` still gets it.
      local zebra = table_cfg.zebra == true and i % 2 == 0 and "MdviewTableZebra" or nil
      content_line(row, zebra, false)
    end
    if borders then
      border_line("└", "┴", "┘")
    end
  end

  local function render_raw(b)
    local qp = quote_prefix(b)
    for _, rl in ipairs(b.lines or {}) do
      local l = add_line(qp .. rl)
      quote_deco(l, b)
      quote_text_hl(l, b, #qp)
    end
  end

  local renderers = {
    heading = render_heading,
    paragraph = render_paragraph,
    code_block = render_code_block,
    list_item = render_list_item,
    rule = render_rule,
    table = render_table,
    raw = render_raw,
  }

  ------------------------------------------------------------------------
  -- Main loop: one blank separator line between blocks, except between
  -- consecutive list items. Blocks that already end on a blank line (rules,
  -- underlined headings) do not get a second one.
  ------------------------------------------------------------------------
  local last_type, last_block
  for _, block in ipairs(blocks or {}) do
    local renderer = renderers[block.type]
    if renderer then
      if #lines > 0 and not (block.type == "list_item" and last_type == "list_item") then
        separator(last_block, block)
      end
      renderer(block)
      last_type = block.type
      last_block = block
    end
  end

  return { lines = lines, decorations = decorations }
end

return M
