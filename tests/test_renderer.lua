-- Tests for lua/mdview/renderer.lua: pure function, runs in this process.
local eq = MiniTest.expect.equality

local renderer = require("mdview.renderer")
local config = require("mdview.config")

-- Several cases below flip 'ambiwidth', which is process-global and reflows
-- every golden in this file. Restoring it per case is structural rather than a
-- convention each author has to remember: a case that fails *before* its own
-- restore still cannot leak the option into the next one.
local ambiwidth_saved

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      ambiwidth_saved = vim.o.ambiwidth
    end,
    post_case = function()
      vim.o.ambiwidth = ambiwidth_saved
    end,
  },
})

--- `opts.width` is the live preview window width; without it nothing wraps.
local function render(blocks, cfg, opts)
  return renderer.render(blocks, cfg or config.get(), opts)
end

--- A deep copy of the defaults that a test may mutate freely.
local function cfg_copy()
  return vim.deepcopy(config.defaults)
end

--- Defaults switched to the v3 background-space markers (the `marker_style`
--- fallback for fonts that do not even cover the verified-safe glyph set).
local function block_cfg()
  local cfg = cfg_copy()
  cfg.marker_style = "block"
  return cfg
end

--- Find the first "hl" decoration with the given group.
local function find_hl(decs, group)
  for _, d in ipairs(decs) do
    if d.kind == "hl" and d.group == group then
      return d
    end
  end
end

--- All "hl" decorations with the given group, as { line, col_start, col_end }.
local function hls_of(decs, group)
  local out = {}
  for _, d in ipairs(decs) do
    if d.kind == "hl" and d.group == group then
      out[#out + 1] = { d.line, d.col_start, d.col_end }
    end
  end
  return out
end

--- Find the first whole-line background decoration with the given group.
local function find_line_hl(decs, group)
  for _, d in ipairs(decs) do
    if d.kind == "line_hl" and d.group == group then
      return d
    end
  end
end

--- line index (0-based) -> line_hl group.
local function line_bgs(decs)
  local out = {}
  for _, d in ipairs(decs) do
    if d.kind == "line_hl" then
      out[d.line] = d.group
    end
  end
  return out
end

--- The only non-ASCII codepoints the renderer's own decoration may emit.
--- `█ • ‣ ·` are present in Monaco (a conservative proxy for "in the user's
--- font"); the box-drawing characters are safe because the terminal draws
--- U+2500..U+257F with its own sprite renderer instead of taking them from the
--- font, so they tile in both directions.
local SAFE = {
  [0x2588] = "█ FULL BLOCK",
  [0x2022] = "• BULLET",
  [0x2023] = "‣ TRIANGULAR BULLET",
  [0x00B7] = "· MIDDLE DOT",
  [0x2500] = "─ BOX DRAWINGS LIGHT HORIZONTAL",
  [0x2502] = "│ BOX DRAWINGS LIGHT VERTICAL",
  [0x250C] = "┌ DOWN AND RIGHT",
  [0x252C] = "┬ DOWN AND HORIZONTAL",
  [0x2510] = "┐ DOWN AND LEFT",
  [0x251C] = "├ VERTICAL AND RIGHT",
  [0x253C] = "┼ VERTICAL AND HORIZONTAL",
  [0x2524] = "┤ VERTICAL AND LEFT",
  [0x2514] = "└ UP AND RIGHT",
  [0x2534] = "┴ UP AND HORIZONTAL",
  [0x2518] = "┘ UP AND LEFT",
}

--- Absent from Monaco entirely: they would be substituted from a fallback face
--- whose metrics do not match the cell, so they must never be emitted.
local UNSAFE = {
  [0x25CF] = "●",
  [0x25E6] = "◦",
  [0x25AA] = "▪",
  [0x25A0] = "■",
  [0x2610] = "☐",
  [0x2611] = "☑",
}

--- Every codepoint of `line` above ASCII.
local function non_ascii(line)
  local out = {}
  for _, cp in ipairs(vim.fn.str2list(line)) do
    if cp > 0x7F then
      out[#out + 1] = cp
    end
  end
  return out
end

T["headings"] = MiniTest.new_set()

T["headings"]["bar is `level` cells, left-aligned"] = function()
  local expected = {
    "█       T", -- 1 cell, matching the single `#` in the source
    "██      T", -- 2
    "███     T", -- 3
    "████    T", -- 4
    "█████   T", -- 5
    "██████  T", -- 6
  }
  for level = 1, 6 do
    local res = render({ { type = "heading", level = level, inline = { { text = "T" } } } })
    eq({ level, res.lines[1] }, { level, expected[level] })

    local bar = hls_of(res.decorations, "MdviewH" .. level .. "Bar")
    eq(#bar, 1)
    -- left-aligned: the bar always starts at column 0 of the gutter
    eq({ bar[1][1], bar[1][2] }, { 0, 0 })
    -- "█" is 3 bytes; the run is `level` cells long
    eq(bar[1][3], 3 * level)
  end
end

T["headings"]["body text starts at the same display column at every level"] = function()
  local cols, byte_cols = {}, {}
  for level = 1, 6 do
    local res = render({ { type = "heading", level = level, inline = { { text = "Title" } } } })
    local text = hls_of(res.decorations, "MdviewH" .. level)
    eq(#text, 1)
    byte_cols[level] = text[1][2]
    -- byte columns differ (the bar is multibyte); the *display* column is what
    -- the reader sees, and it must not move
    cols[level] = vim.fn.strdisplaywidth(res.lines[1]:sub(1, text[1][2]))
  end
  eq(cols, { 8, 8, 8, 8, 8, 8 }) -- gutter (6) + 2-space separator
  -- and the text really is at that column in every rendered line
  for level = 1, 6 do
    local res = render({ { type = "heading", level = level, inline = { { text = "Title" } } } })
    eq({ level, res.lines[1]:sub(byte_cols[level] + 1) }, { level, "Title" })
  end
end

T["headings"]["the staircase grows: bar length matches the `#` count"] = function()
  local widths = {}
  for level = 1, 6 do
    local res = render({ { type = "heading", level = level, inline = { { text = "T" } } } })
    local bar = hls_of(res.decorations, "MdviewH" .. level .. "Bar")[1]
    widths[level] = vim.fn.strdisplaywidth(res.lines[1]:sub(bar[2] + 1, bar[3]))
  end
  eq(widths, { 1, 2, 3, 4, 5, 6 })
end

T["headings"]["H1 and H2 get an underline band, H3..H6 do not"] = function()
  for level = 1, 2 do
    local res = render({ { type = "heading", level = level, inline = { { text = "T" } } } })
    eq({ level, #res.lines }, { level, 3 }) -- heading, band, breathing room
    eq({ level, res.lines[2], res.lines[3] }, { level, "", "" })
    local band = find_line_hl(res.decorations, "MdviewHeadingUnderline")
    eq({ level, band and band.line }, { level, 1 })
  end
  for level = 3, 6 do
    local res = render({ { type = "heading", level = level, inline = { { text = "T" } } } })
    eq({ level, #res.lines }, { level, 1 })
    eq({ level, find_line_hl(res.decorations, "MdviewHeadingUnderline") }, { level, nil })
  end
end

T["headings"]["underline_levels is configurable and 0 disables the band"] = function()
  local cfg = cfg_copy()
  cfg.heading.underline_levels = 0
  local res = render({ { type = "heading", level = 1, inline = { { text = "T" } } } }, cfg)
  eq(res.lines, { "█       T" })
  eq(find_line_hl(res.decorations, "MdviewHeadingUnderline"), nil)

  cfg.heading.underline_levels = 6
  res = render({ { type = "heading", level = 6, inline = { { text = "T" } } } }, cfg)
  eq(find_line_hl(res.decorations, "MdviewHeadingUnderline").line, 1)
end

T["headings"]["no graduated line background is emitted"] = function()
  -- v3's `MdviewH1Bg`..`MdviewH6Bg` differed by a few percent of alpha, which
  -- is invisible in practice. Length alone carries the hierarchy now.
  for level = 1, 6 do
    local res = render({ { type = "heading", level = level, inline = { { text = "T" } } } })
    eq({ level, find_line_hl(res.decorations, "MdviewH" .. level .. "Bg") }, { level, nil })
  end
end

T["headings"]["heading text is bold, and heading.bold = false drops it"] = function()
  local res = render({ { type = "heading", level = 3, inline = { { text = "Three" } } } })
  -- 3 bars (9 bytes) + 3 pad + 2 separator = byte column 14 (display column 8)
  eq(hls_of(res.decorations, "MdviewHeadingBold"), { { 0, 14, 19 } })

  local cfg = cfg_copy()
  cfg.heading.bold = false
  res = render({ { type = "heading", level = 3, inline = { { text = "Three" } } } }, cfg)
  eq(find_hl(res.decorations, "MdviewHeadingBold"), nil)
  eq(find_hl(res.decorations, "MdviewH3") ~= nil, true)
end

T["headings"]["custom gutter changes bar length and text column"] = function()
  local cfg = cfg_copy()
  cfg.heading.gutter = 3
  local res = render({ { type = "heading", level = 1, inline = { { text = "T" } } } }, cfg)
  eq(res.lines[1], "█    T") -- 3-cell gutter + 2-space separator
  eq(hls_of(res.decorations, "MdviewH1Bar"), { { 0, 0, 3 } })
end

T["headings"]["a gutter shallower than the level clamps the bar to the gutter"] = function()
  local cfg = cfg_copy()
  cfg.heading.gutter = 2
  local res = render({ { type = "heading", level = 6, inline = { { text = "T" } } } }, cfg)
  -- the bar never overflows the gutter, and is never zero-width
  eq(res.lines[1], "██  T")
  eq(hls_of(res.decorations, "MdviewH6Bar"), { { 0, 0, 6 } })
end

T["headings"]["disabled headings render plain"] = function()
  local cfg = cfg_copy()
  cfg.elements.headings = false
  local res = render({ { type = "heading", level = 1, inline = { { text = "T" } } } }, cfg)
  eq(res.lines, { "T" })
  eq(find_hl(res.decorations, "MdviewH1"), nil)
  eq(find_hl(res.decorations, "MdviewH1Bar"), nil)
end

T["headings"]["consecutive headings are separated by one blank line"] = function()
  local res = render({
    { type = "heading", level = 3, inline = { { text = "A" } } },
    { type = "heading", level = 4, inline = { { text = "B" } } },
  })
  eq(res.lines, { "███     A", "", "████    B" })
  eq(hls_of(res.decorations, "MdviewH3Bar"), { { 0, 0, 9 } })
  eq(hls_of(res.decorations, "MdviewH4Bar"), { { 2, 0, 12 } })
end

T["headings"]["an underlined heading does not double its trailing blank"] = function()
  local res = render({
    { type = "heading", level = 1, inline = { { text = "A" } } },
    { type = "paragraph", inline = { { text = "p" } } },
  })
  eq(res.lines, { "█       A", "", "", "p" })
  eq(line_bgs(res.decorations)[1], "MdviewHeadingUnderline")
end

T["inline spans"] = MiniTest.new_set()

T["inline spans"]["byte-accurate highlight ranges"] = function()
  local res = render({
    { type = "paragraph", inline = { { text = "ab " }, { text = "cd", style = "bold" }, { text = " ef" } } },
  })
  eq(res.lines, { "ab cd ef" })
  local hl = find_hl(res.decorations, "MdviewBold")
  eq({ hl.col_start, hl.col_end }, { 3, 5 })
end

T["inline spans"]["multibyte text keeps byte columns"] = function()
  local res = render({
    { type = "paragraph", inline = { { text = "あ" }, { text = "太字", style = "bold" } } },
  })
  eq(res.lines, { "あ太字" })
  local hl = find_hl(res.decorations, "MdviewBold")
  -- "あ" is 3 bytes; bold span covers the next 6 bytes
  eq({ hl.col_start, hl.col_end }, { 3, 9 })
end

T["inline spans"]["link style maps to MdviewLink"] = function()
  local res = render({
    { type = "paragraph", inline = { { text = "x", style = "link", url = "https://e.com" } } },
  })
  eq(find_hl(res.decorations, "MdviewLink") ~= nil, true)
end

T["inline spans"]["inline code is a chip: background as well as foreground"] = function()
  local res = render({
    { type = "paragraph", inline = { { text = "run " }, { text = ":MdView", style = "code" } } },
  })
  eq(res.lines, { "run :MdView" })
  eq(hls_of(res.decorations, "MdviewCode"), { { 0, 4, 11 } })
  -- same span, painted with the computed chip background
  eq(hls_of(res.decorations, "MdviewCodeBg"), { { 0, 4, 11 } })
end

T["lists"] = MiniTest.new_set()

T["lists"]["real bullet glyphs, one shape per depth, cycling"] = function()
  local res = render({
    { type = "list_item", depth = 0, ordered = false, inline = { { text = "a" } } },
    { type = "list_item", depth = 1, ordered = false, inline = { { text = "b" } } },
    { type = "list_item", depth = 2, ordered = false, inline = { { text = "c" } } },
    { type = "list_item", depth = 3, ordered = false, inline = { { text = "d" } } },
    { type = "list_item", depth = 4, ordered = false, inline = { { text = "e" } } },
  })
  eq(res.lines, {
    "  • a",
    "    ‣ b",
    "      · c",
    "        • d", -- cycles back at depth 3
    "          ‣ e",
  })
end

T["lists"]["bullet colours follow the depth cycle"] = function()
  local res = render({
    { type = "list_item", depth = 0, inline = { { text = "a" } } },
    { type = "list_item", depth = 1, inline = { { text = "b" } } },
    { type = "list_item", depth = 2, inline = { { text = "c" } } },
    { type = "list_item", depth = 3, inline = { { text = "d" } } },
    { type = "list_item", depth = 4, inline = { { text = "e" } } },
  })
  -- "•" and "‣" are 3 bytes, "·" is 2
  eq(hls_of(res.decorations, "MdviewBullet1"), { { 0, 2, 5 }, { 3, 8, 11 } })
  eq(hls_of(res.decorations, "MdviewBullet2"), { { 1, 4, 7 }, { 4, 10, 13 } })
  eq(hls_of(res.decorations, "MdviewBullet3"), { { 2, 6, 8 } })
  eq(find_hl(res.decorations, "MdviewBulletBar1"), nil)
end

T["lists"]["custom bullets are honored"] = function()
  local cfg = cfg_copy()
  cfg.icons.bullets = { "-" }
  local res = render({
    { type = "list_item", depth = 0, inline = { { text = "a" } } },
    { type = "list_item", depth = 1, inline = { { text = "b" } } },
  }, cfg)
  eq(res.lines, { "  - a", "    - b" })
end

T["lists"]["ordered items keep their numbers"] = function()
  local res = render({
    { type = "list_item", depth = 0, ordered = true, marker = "1.", inline = { { text = "a" } } },
    { type = "list_item", depth = 0, ordered = true, marker = "10.", inline = { { text = "b" } } },
  })
  -- Right-aligned in a slot as wide as the widest number in the list, so both
  -- items' text starts in the same column instead of drifting at 10.
  eq(res.lines, { "   1. a", "  10. b" })
  -- the highlight follows the number past its leading pad
  eq(hls_of(res.decorations, "MdviewBullet"), { { 0, 3, 5 }, { 1, 2, 5 } })
end

T["lists"]["a mixed list keeps one text column"] = function()
  local res = render({
    { type = "list_item", depth = 0, inline = { { text = "bullet" } } },
    { type = "list_item", depth = 0, checkbox = "unchecked", inline = { { text = "task" } } },
  })
  -- `[ ]` is the widest marker here, so the bullet is padded out to match it
  eq(res.lines, { "  •   bullet", "  [ ] task" })
end

T["lists"]["separate lists size their slots independently"] = function()
  local res = render({
    { type = "list_item", depth = 0, ordered = true, marker = "100.", inline = { { text = "a" } } },
    { type = "paragraph", inline = { { text = "between" } } },
    { type = "list_item", depth = 0, ordered = true, marker = "1.", inline = { { text = "b" } } },
  })
  -- the second list is not indented to fit a number from the first
  eq(res.lines, { "  100. a", "", "between", "", "  1. b" })
end

T["lists"]["a bullet list is not padded to fit the numbers next to it"] = function()
  -- The IR has no list node, so two adjacent lists arrive as one run of
  -- list_item blocks. Marker slots are keyed by orderedness as well as depth,
  -- because a change of marker type starts a new list in CommonMark.
  local res = render({
    { type = "list_item", depth = 0, inline = { { text = "a" } } },
    { type = "list_item", depth = 0, inline = { { text = "b" } } },
    { type = "list_item", depth = 0, ordered = true, marker = "1.", inline = { { text = "c" } } },
  })
  eq(res.lines, { "  • a", "  • b", "  1. c" })
end

T["lists"]["a nested item does not break the slot around it"] = function()
  local res = render({
    { type = "list_item", depth = 0, ordered = true, marker = "9.", inline = { { text = "nine" } } },
    { type = "list_item", depth = 1, inline = { { text = "nested" } } },
    { type = "list_item", depth = 0, ordered = true, marker = "10.", inline = { { text = "ten" } } },
  })
  -- 9. and 10. still share their slot across the intervening depth-1 item
  eq(res.lines, { "   9. nine", "    ‣ nested", "  10. ten" })
end

T["lists"]["tasks get ASCII checkboxes"] = function()
  local res = render({
    { type = "list_item", depth = 0, checkbox = "unchecked", inline = { { text = "todo" } } },
    { type = "list_item", depth = 0, checkbox = "checked", inline = { { text = "done" } } },
  })
  eq(res.lines, { "  [ ] todo", "  [x] done" })
  eq(hls_of(res.decorations, "MdviewCheckbox"), { { 0, 2, 5 }, { 1, 2, 5 } })
end

T["lists"]["disabled lists render flush with their raw markers"] = function()
  local cfg = cfg_copy()
  cfg.elements.lists = false
  local res = render({
    { type = "list_item", depth = 0, marker = "-", inline = { { text = "a" } } },
    { type = "list_item", depth = 1, marker = "-", inline = { { text = "b" } } },
  }, cfg)
  eq(res.lines, { "- a", "  - b" })
  eq(find_hl(res.decorations, "MdviewBullet1"), nil)
end

T["lists"]["blank line separates lists from other blocks but not items"] = function()
  local res = render({
    { type = "paragraph", inline = { { text = "p" } } },
    { type = "list_item", depth = 0, inline = { { text = "a" } } },
    { type = "list_item", depth = 0, inline = { { text = "b" } } },
  })
  eq(res.lines, { "p", "", "  • a", "  • b" })
end

T["code blocks"] = MiniTest.new_set()

T["code blocks"]["full-width band, 2-cell indent, dim language label"] = function()
  local res = render({ { type = "code_block", lang = "lua", lines = { "local x = 1" } } })
  eq(res.lines, { "  lua", "  local x = 1" })

  local bg = line_bgs(res.decorations)
  eq({ bg[0], bg[1] }, { "MdviewCodeBlock", "MdviewCodeBlock" })

  -- v3's left bar is gone: the band alone delimits the block
  eq(find_hl(res.decorations, "MdviewCodeBar"), nil)
  eq(find_hl(res.decorations, "MdviewCodeBarBlock"), nil)

  local header = find_hl(res.decorations, "MdviewCodeHeader")
  eq({ header.line, header.col_start, header.col_end }, { 0, 2, 5 })

  local code
  for _, d in ipairs(res.decorations) do
    if d.kind == "code" then
      code = d
    end
  end
  eq(code.lang, "lua")
  eq(code.row, 1) -- body starts after the header line
  eq(code.col_offset, 2) -- the 2-cell content indent, no bar
  eq(code.lines, { "local x = 1" })
end

T["code blocks"]["no language means no header line and no code decoration"] = function()
  local res = render({ { type = "code_block", lines = { "plain" } } })
  eq(res.lines, { "  plain" })
  for _, d in ipairs(res.decorations) do
    eq(d.kind ~= "code" and d.kind ~= "virt_text", true)
  end
  eq(find_line_hl(res.decorations, "MdviewCodeBlock").line, 0)
end

T["code blocks"]["language_label = false omits the header line"] = function()
  local cfg = cfg_copy()
  cfg.code.language_label = false
  local res = render({ { type = "code_block", lang = "lua", lines = { "local x = 1" } } }, cfg)
  eq(res.lines, { "  local x = 1" })
  local code
  for _, d in ipairs(res.decorations) do
    if d.kind == "code" then
      code = d
    end
  end
  eq(code.row, 0)
  eq(code.col_offset, 2)
end

T["code blocks"]["line_numbers = true adds a fixed-width gutter"] = function()
  local cfg = cfg_copy()
  cfg.code.line_numbers = true
  local res = render({ { type = "code_block", lang = "lua", lines = { "a", "b" } } }, cfg)
  eq(res.lines, { "  lua", "1 a", "2 b" })
  local code
  for _, d in ipairs(res.decorations) do
    if d.kind == "code" then
      code = d
    end
  end
  eq(code.col_offset, 2) -- "1 "
  eq(find_hl(res.decorations, "MdviewCodeLineNr") ~= nil, true)
end

T["blockquotes"] = MiniTest.new_set()

T["blockquotes"]["one full-block bar per depth, accumulated"] = function()
  local res = render({
    { type = "paragraph", quote = 1, inline = { { text = "one" } } },
    { type = "paragraph", quote = 2, inline = { { text = "two" } } },
    { type = "paragraph", quote = 3, inline = { { text = "three" } } },
  })
  -- The separator lines are not blank: the bar runs down the whole quote, so
  -- each one carries the bars the two blocks it sits between have in common.
  eq(res.lines, { "█ one", "█", "██ two", "██", "███ three" })
end

T["blockquotes"]["the separator between two blocks carries bar and background"] = function()
  local res = render({
    { type = "paragraph", quote = 1, inline = { { text = "one" } } },
    { type = "paragraph", quote = 1, inline = { { text = "two" } } },
  })
  eq(res.lines, { "█ one", "█", "█ two" })
  -- all three lines, separator included, or the quote reads as two quotes
  eq(hls_of(res.decorations, "MdviewQuoteBar"), { { 0, 0, 3 }, { 1, 0, 3 }, { 2, 0, 3 } })
  local bgs = line_bgs(res.decorations)
  eq({ bgs[0], bgs[1], bgs[2] }, { "MdviewQuoteBg", "MdviewQuoteBg", "MdviewQuoteBg" })
end

T["blockquotes"]["the gap either side of a quote stays blank"] = function()
  local res = render({
    { type = "paragraph", inline = { { text = "before" } } },
    { type = "paragraph", quote = 1, inline = { { text = "quoted" } } },
    { type = "paragraph", inline = { { text = "after" } } },
  })
  eq(res.lines, { "before", "", "█ quoted", "", "after" })
end

T["blockquotes"]["bars share one dim group, the body text is dimmed"] = function()
  local res = render({ { type = "paragraph", quote = 2, inline = { { text = "q" } } } })
  -- "█" is 3 bytes, so two bars span [0, 6)
  eq(hls_of(res.decorations, "MdviewQuoteBar"), { { 0, 0, 6 } })
  -- the quoted text (after the bars and the separator space) is dimmed
  eq(hls_of(res.decorations, "MdviewQuote"), { { 0, 7, 8 } })
  eq(find_line_hl(res.decorations, "MdviewQuoteBg").line, 0)
end

T["blockquotes"]["quoted headings keep their own bar and colour"] = function()
  local res = render({ { type = "heading", level = 2, quote = 1, inline = { { text = "H" } } } })
  eq(res.lines[1], "█ ██      H")
  eq(hls_of(res.decorations, "MdviewQuoteBar"), { { 0, 0, 3 } })
  eq(hls_of(res.decorations, "MdviewH2Bar"), { { 0, 4, 10 } })
  -- the heading text is not dimmed by the blockquote
  eq(find_hl(res.decorations, "MdviewQuote"), nil)
end

T["blockquotes"]["disabled blockquotes fall back to > markers"] = function()
  local cfg = cfg_copy()
  cfg.elements.blockquotes = false
  local res = render({ { type = "paragraph", quote = 2, inline = { { text = "q" } } } }, cfg)
  eq(res.lines, { "> > q" })
  eq(find_line_hl(res.decorations, "MdviewQuoteBg"), nil)
end

T["rules"] = MiniTest.new_set()

T["rules"]["rule is a tinted blank band, not repeated characters"] = function()
  local res = render({ { type = "rule" } })
  eq(res.lines, { "", "" })
  eq(find_line_hl(res.decorations, "MdviewRuleBg").line, 0)
end

T["rules"]["disabled rules fall back to ---"] = function()
  local cfg = cfg_copy()
  cfg.elements.horizontal_rules = false
  local res = render({ { type = "rule" } }, cfg)
  eq(res.lines, { "---" })
end

T["tables"] = MiniTest.new_set()

--- A 2-column, 3-row table used for the grid golden lines.
local function grid_blocks()
  return {
    {
      type = "table",
      header = { { { text = "Element" } }, { { text = "Rendering" } } },
      align = { "none", "none" },
      rows = {
        { { { text = "Heading" } }, { { text = "bar" } } },
        { { { text = "Link" } }, { { text = "MdviewLink" } } },
        { { { text = "Rule" } }, { { text = "band" } } },
      },
    },
  }
end

T["tables"]["a full box-drawing grid, ruled between every body row"] = function()
  local res = render(grid_blocks())
  eq(res.lines, {
    "  ┌─────────┬────────────┐",
    "  │ Element │ Rendering  │",
    "  ├─────────┼────────────┤",
    "  │ Heading │ bar        │",
    "  ├─────────┼────────────┤",
    "  │ Link    │ MdviewLink │",
    "  ├─────────┼────────────┤",
    "  │ Rule    │ band       │",
    "  └─────────┴────────────┘",
  })
end

T["tables"]["every border character carries MdviewTableBorder"] = function()
  local res = render(grid_blocks())
  local border = {}
  for _, d in ipairs(res.decorations) do
    if d.kind == "hl" and d.group == "MdviewTableBorder" then
      border[d.line] = (border[d.line] or 0) + 1
    end
  end
  -- one whole-line decoration per rule (rows 0, 2, 4, 6, 8)
  for _, row in ipairs({ 0, 2, 4, 6, 8 }) do
    eq({ row, border[row] }, { row, 1 })
  end
  -- three verticals per content row (left, middle, right)
  for _, row in ipairs({ 1, 3, 5, 7 }) do
    eq({ row, border[row] }, { row, 3 })
  end
  -- the rule spans the whole line, past the 2-cell lead
  local rule = hls_of(res.decorations, "MdviewTableBorder")[1]
  eq({ rule[1], rule[2], rule[3] }, { 0, 2, #res.lines[1] })
end

T["tables"]["column widths stay CJK-aware inside the grid"] = function()
  local res = render({
    {
      type = "table",
      header = { { { text = "a" } }, { { text = "日本" } } },
      align = { "none", "none" },
      rows = { { { { text = "bb" } }, { { text = "x" } } } },
    },
  })
  eq(res.lines, {
    "  ┌────┬──────┐",
    "  │ a  │ 日本 │",
    "  ├────┼──────┤",
    "  │ bb │ x    │",
    "  └────┴──────┘",
  })
  -- every rendered row is exactly as wide as the rules above and below it
  for _, line in ipairs(res.lines) do
    eq(vim.fn.strdisplaywidth(line), vim.fn.strdisplaywidth(res.lines[1]))
  end
end

--- Run `fn` with 'ambiwidth' = "double". The suite's `post_case` hook owns the
--- restore, so this does not need its own pcall -- and a failure reports at the
--- assertion instead of being re-raised from a wrapper.
local function with_ambiwidth_double(fn)
  vim.o.ambiwidth = "double"
  fn()
end

T["headings"]["the text column holds under 'ambiwidth' = double"] = function()
  -- `█` is East Asian Ambiguous, so it is two cells under "double". Padding the
  -- gutter by slot *count* would drift the text column by one slot per level.
  with_ambiwidth_double(function()
    local cols = {}
    for level = 1, 6 do
      local res = render({ { type = "heading", level = level, inline = { { text = "Title" } } } })
      local line = res.lines[1]
      cols[level] = vim.fn.strdisplaywidth(line:sub(1, line:find("Title", 1, true) - 1))
    end
    -- gutter (6 slots x 2 cells) + the 2-space separator
    eq(cols, { 14, 14, 14, 14, 14, 14 })
  end)
end

T["lists"]["bullet shapes of unequal width keep the text column"] = function()
  -- `•` and `·` are ambiguous (two cells under "double") but `‣` is not, so the
  -- narrow shape has to be padded to the width of the widest of the set.
  with_ambiwidth_double(function()
    local cols = {}
    for depth = 0, 3 do
      local res = render({ { type = "list_item", depth = depth, inline = { { text = "Item" } } } })
      local line = res.lines[1]
      cols[depth + 1] = vim.fn.strdisplaywidth(line:sub(1, line:find("Item", 1, true) - 1))
    end
    -- one constant marker slot, plus GitHub's 2-cell indent per depth
    eq(cols, { 5, 7, 9, 11 })
  end)
end

T["tables"]["the grid lines up under 'ambiwidth' = double"] = function()
  -- Box drawing is East Asian *Ambiguous*: with 'ambiwidth' = "double" every
  -- one of these characters is two cells, so a naive `string.rep("─", w + 2)`
  -- rule comes out twice as wide as the row it is supposed to span.
  with_ambiwidth_double(function()
    local res = render({
      {
        type = "table",
        header = { { { text = "a" } }, { { text = "日本" } } },
        align = { "none", "none" },
        rows = { { { { text = "bb" } }, { { text = "x" } } } },
      },
    })
    local width = vim.fn.strdisplaywidth(res.lines[1])
    for _, line in ipairs(res.lines) do
      eq({ line, vim.fn.strdisplaywidth(line) }, { line, width })
    end
    -- and the junctions sit at the same display columns as the verticals
    local function columns(line, glyphs)
      local out, col = {}, 0
      for _, ch in ipairs(vim.split(line, "")) do
        if vim.tbl_contains(glyphs, ch) then
          out[#out + 1] = col
        end
        col = col + vim.fn.strdisplaywidth(ch)
      end
      return out
    end
    eq(columns(res.lines[1], { "┌", "┬", "┐" }), columns(res.lines[2], { "│" }))
    eq(columns(res.lines[3], { "├", "┼", "┤" }), columns(res.lines[4], { "│" }))
  end)
end

T["tables"]["alignment is honored"] = function()
  local res = render({
    {
      type = "table",
      header = { { { text = "head" } } },
      align = { "right" },
      rows = { { { { text = "x" } } } },
    },
  })
  eq(res.lines[4], "  │    x │")
end

T["tables"]["header cells get MdviewTableHead over exact byte range"] = function()
  local res = render({
    {
      type = "table",
      header = { { { text = "ab" } } },
      align = { "none" },
      rows = {},
    },
  })
  eq(res.lines, { "  ┌────┐", "  │ ab │", "  └────┘" })
  local hl = find_hl(res.decorations, "MdviewTableHead")
  -- lead (2) + "│" (3 bytes) + one space
  eq({ hl.line, hl.col_start, hl.col_end }, { 1, 6, 8 })
  eq(find_line_hl(res.decorations, "MdviewTableHeadBg").line, 1)
end

T["tables"]["zebra defaults off -- the rules already separate the rows"] = function()
  local rows = { { { { text = "a" } } }, { { { text = "b" } } } }
  local res = render({ { type = "table", header = { { { text = "h" } } }, align = { "none" }, rows = rows } })
  eq(find_line_hl(res.decorations, "MdviewTableZebra"), nil)
  eq(find_line_hl(res.decorations, "MdviewTableHeadBg") ~= nil, true)
end

T["tables"]["zebra = true still tints alternating body rows"] = function()
  local cfg = cfg_copy()
  cfg.tables.zebra = true
  local rows = {}
  for i = 1, 3 do
    rows[i] = { { { text = "r" .. i } } }
  end
  local res = render({ { type = "table", header = { { { text = "h" } } }, align = { "none" }, rows = rows } }, cfg)
  local bgs = line_bgs(res.decorations)
  eq(bgs[1], "MdviewTableHeadBg") -- header, after the top rule
  eq(bgs[3], nil) -- row 1
  eq(bgs[5], "MdviewTableZebra") -- row 2
  eq(bgs[7], nil) -- row 3
end

T["tables"]["borders = false falls back to │ separators only"] = function()
  local cfg = cfg_copy()
  cfg.tables.borders = false
  local res = render({
    {
      type = "table",
      header = { { { text = "a" } }, { { text = "日本" } } },
      align = { "none", "none" },
      rows = { { { { text = "bb" } }, { { text = "x" } } } },
    },
  }, cfg)
  eq(res.lines, {
    "  a  │ 日本",
    "  bb │ x   ",
  })
  eq(hls_of(res.decorations, "MdviewTableSep"), { { 0, 5, 8 }, { 1, 5, 8 } })
  eq(find_hl(res.decorations, "MdviewTableBorder"), nil)
end

T["tables"]["a table far wider than the target width is never wrapped"] = function()
  local cell = string.rep("x", 60)
  local res = render({
    {
      type = "table",
      header = { { { text = cell } }, { { text = cell } } },
      align = { "none", "none" },
      rows = { { { { text = cell } }, { { text = cell } } } },
    },
  }, cfg_copy(), { width = 40 })
  eq(#res.lines, 5) -- top rule, header, mid rule, row, bottom rule
  for _, line in ipairs(res.lines) do
    -- 2 lead + 3 verticals + 2 cells of 60 + 4 padding spaces
    eq(vim.fn.strdisplaywidth(line), 2 + 3 + 4 + 120)
  end
end

T["tables"]["disabled tables render plain rows"] = function()
  local cfg = cfg_copy()
  cfg.elements.tables = false
  local res = render({
    { type = "table", header = { { { text = "h" } } }, align = { "none" }, rows = { { { { text = "a" } } } } },
  }, cfg)
  eq(res.lines, { "h", "a" })
end

T["links"] = MiniTest.new_set()

T["links"]["disabled links produce no link highlight"] = function()
  local cfg = cfg_copy()
  cfg.elements.links = false
  local res = render({
    { type = "paragraph", inline = { { text = "x", style = "link", url = "u" } } },
  }, cfg)
  eq(res.lines, { "x" })
  eq(find_hl(res.decorations, "MdviewLink"), nil)
end

--------------------------------------------------------------------------
-- marker_style = "block": the v3 background-space markers, kept for fonts
-- that do not even cover the verified-safe glyph set. Same layout, but every
-- marker cell holds a space painted by a background highlight.
--------------------------------------------------------------------------

T["block style"] = MiniTest.new_set()

T["block style"]["heading bars are runs of spaces, text column unchanged"] = function()
  local gutter = config.defaults.heading.gutter
  for level = 1, 6 do
    local res = render({ { type = "heading", level = level, inline = { { text = "T" } } } }, block_cfg())
    -- the buffer holds only spaces; the bar is the coloured run inside them
    eq({ level, res.lines[1] }, { level, string.rep(" ", gutter) .. "  T" })
    eq(hls_of(res.decorations, "MdviewH" .. level .. "Bar"), { { 0, 0, level } })
  end
end

T["block style"]["the underline band still marks H1 and H2"] = function()
  local res = render({ { type = "heading", level = 1, inline = { { text = "T" } } } }, block_cfg())
  eq(find_line_hl(res.decorations, "MdviewHeadingUnderline").line, 1)
  local res3 = render({ { type = "heading", level = 3, inline = { { text = "T" } } } }, block_cfg())
  eq(find_line_hl(res3.decorations, "MdviewHeadingUnderline"), nil)
end

T["block style"]["bullets are one coloured cell, dimming with depth"] = function()
  local res = render({
    { type = "list_item", depth = 0, inline = { { text = "a" } } },
    { type = "list_item", depth = 1, inline = { { text = "b" } } },
    { type = "list_item", depth = 2, inline = { { text = "c" } } },
    { type = "list_item", depth = 3, inline = { { text = "d" } } },
  }, block_cfg())
  eq(res.lines, { "    a", "      b", "        c", "          d" })
  eq(hls_of(res.decorations, "MdviewBulletBar1"), { { 0, 2, 3 }, { 3, 8, 9 } })
  eq(hls_of(res.decorations, "MdviewBulletBar2"), { { 1, 4, 5 } })
  eq(hls_of(res.decorations, "MdviewBulletBar3"), { { 2, 6, 7 } })
  eq(find_hl(res.decorations, "MdviewBullet1"), nil)
end

T["block style"]["quote bars are one coloured cell per depth"] = function()
  local res = render({
    { type = "paragraph", quote = 1, inline = { { text = "one" } } },
    { type = "paragraph", quote = 2, inline = { { text = "two" } } },
    { type = "paragraph", quote = 3, inline = { { text = "three" } } },
  }, block_cfg())
  -- Same continuity under the block style: the separator holds the shallower
  -- neighbour's cells, as spaces carrying the bar background.
  eq(res.lines, { "  one", " ", "   two", "  ", "    three" })
  eq(
    hls_of(res.decorations, "MdviewQuoteBar"),
    { { 0, 0, 1 }, { 1, 0, 1 }, { 2, 0, 2 }, { 3, 0, 2 }, { 4, 0, 3 } }
  )
end

T["block style"]["tables fall back to padding-separated columns"] = function()
  local res = render({
    {
      type = "table",
      header = { { { text = "a" } }, { { text = "日本" } } },
      align = { "none", "none" },
      rows = { { { { text = "bb" } }, { { text = "x" } } } },
    },
  }, block_cfg())
  eq(res.lines, {
    "  a    日本",
    "  bb   x   ",
  })
  eq(find_hl(res.decorations, "MdviewTableSep"), nil)
end

T["block style"]["checkboxes and ordered numbers are unchanged"] = function()
  local res = render({
    { type = "list_item", depth = 0, ordered = true, marker = "1.", inline = { { text = "a" } } },
    { type = "list_item", depth = 0, checkbox = "checked", inline = { { text = "b" } } },
  }, block_cfg())
  -- The glyphs are the same ASCII as under the glyph style. These two do NOT
  -- share a marker slot: a numbered item beside a bullet item is two lists in
  -- CommonMark, so neither is padded to fit the other.
  eq(res.lines, { "  1. a", "  [x] b" })
end

T["block style"]["an unknown marker_style renders as glyph"] = function()
  local cfg = cfg_copy()
  cfg.marker_style = "nonsense"
  local res = render({ { type = "heading", level = 1, inline = { { text = "T" } } } }, cfg)
  eq(res.lines[1], "█       T")
end

--------------------------------------------------------------------------
-- Character-set guarantees
--------------------------------------------------------------------------

---------------------------------------------------------------------------
-- Mermaid
---------------------------------------------------------------------------

T["mermaid"] = MiniTest.new_set()

--- The rendered lines of a single ```mermaid fence.
local function mermaid_lines(body, cfg, block)
  local res = render({ { type = "code_block", lang = "mermaid", lines = body } }, cfg, { width = 60 })
  return res.lines, res.decorations
end

T["mermaid"]["a supported fence is drawn as a diagram"] = function()
  local lines = mermaid_lines({ "flowchart TD", "A[One] --> B[Two]" })
  -- The language label is kept, so a reader can tell a drawn diagram from
  -- hand-written ASCII art in the source.
  eq(lines[1], "  mermaid")
  eq(lines[2], "  ┌─────┐")
  eq(lines[3], "  │ One │")
  eq(vim.tbl_contains(lines, "  │ Two │"), true)
end

T["mermaid"]["an unsupported fence renders exactly like any other code block"] = function()
  -- The fallback must be indistinguishable from the behaviour before diagrams
  -- existed: same lines, same decorations, just a different language tag.
  local body = { "flowchart TD", "subgraph s", "A --> B", "end" }
  local drawn = render({ { type = "code_block", lang = "mermaid", lines = body } }, nil, { width = 60 })
  local plain = render({ { type = "code_block", lang = "text", lines = body } }, nil, { width = 60 })
  eq(#drawn.lines, #plain.lines)
  for i = 2, #plain.lines do
    eq(drawn.lines[i], plain.lines[i])
  end
  eq(#drawn.decorations, #plain.decorations)
end

T["mermaid"]["elements.mermaid = false keeps the fence as source"] = function()
  local cfg = cfg_copy()
  cfg.elements.mermaid = false
  local lines = mermaid_lines({ "flowchart TD", "A --> B" }, cfg)
  eq(lines[2], "  flowchart TD")
end

T["mermaid"]["the block marker style falls back, having no box drawing"] = function()
  local lines = mermaid_lines({ "flowchart TD", "A --> B" }, block_cfg())
  eq(lines[2], "  flowchart TD")
end

T["mermaid"]["mermaid.language_label = false drops the header line"] = function()
  local cfg = cfg_copy()
  cfg.mermaid.language_label = false
  local lines = mermaid_lines({ "flowchart TD", "A[One] --> B[Two]" }, cfg)
  eq(lines[1], "  ┌─────┐")
end

T["mermaid"]["max_nodes falls back rather than drawing a huge diagram"] = function()
  local body = { "flowchart TD" }
  for i = 1, 10 do
    body[#body + 1] = ("N%d --> N%d"):format(i, i + 1)
  end
  local cfg = cfg_copy()
  cfg.mermaid.max_nodes = 5
  eq(mermaid_lines(body, cfg)[2], "  flowchart TD")
  cfg.mermaid.max_nodes = 60
  -- Diagram rows are padded to the canvas width, so this is a prefix check
  -- rather than an equality: the first row is not necessarily the widest.
  eq(mermaid_lines(body, cfg)[2]:sub(1, #"  ┌"), "  ┌")
end

T["mermaid"]["a diagram inside a blockquote keeps the bar and the indent"] = function()
  local res = render({
    { type = "code_block", lang = "mermaid", quote = 1, lines = { "flowchart TD", "A --> B" } },
  }, nil, { width = 60 })
  for _, line in ipairs(res.lines) do
    eq(line:sub(1, #"█ "), "█ ")
  end
end

T["mermaid"]["decoration byte columns land inside their own line"] = function()
  local lines, decs = mermaid_lines({ "flowchart TD", "A[One] -->|yes| B[Two]" })
  local bad = {}
  for _, d in ipairs(decs) do
    if d.kind == "hl" and (d.col_end > #(lines[d.line + 1] or "")) then
      bad[#bad + 1] = d
    end
  end
  eq(bad, {})
end

T["character set"] = MiniTest.new_set()

--- A document exercising every element the renderer knows about, whose own
--- text is pure ASCII: any non-ASCII codepoint in the output therefore comes
--- from the renderer's decoration, not from the document.
local function kitchen_sink()
  local blocks = {}
  for level = 1, 6 do
    blocks[#blocks + 1] = { type = "heading", level = level, inline = { { text = "Heading " .. level } } }
  end
  vim.list_extend(blocks, {
    { type = "paragraph", inline = { { text = "plain " }, { text = "bold", style = "bold" } } },
    { type = "paragraph", inline = { { text = "run " }, { text = ":MdView", style = "code" } } },
    { type = "paragraph", quote = 1, inline = { { text = "quoted" } } },
    { type = "paragraph", quote = 2, inline = { { text = "deeper" } } },
    { type = "paragraph", quote = 3, inline = { { text = "deepest" } } },
    { type = "heading", level = 2, quote = 1, inline = { { text = "quoted heading" } } },
    { type = "list_item", depth = 0, inline = { { text = "one" } } },
    { type = "list_item", depth = 1, inline = { { text = "two" } } },
    { type = "list_item", depth = 2, inline = { { text = "three" } } },
    { type = "list_item", depth = 3, inline = { { text = "four" } } },
    { type = "list_item", depth = 0, ordered = true, marker = "1.", inline = { { text = "num" } } },
    { type = "list_item", depth = 0, checkbox = "checked", inline = { { text = "done" } } },
    { type = "list_item", depth = 0, checkbox = "unchecked", inline = { { text = "todo" } } },
    { type = "code_block", lang = "lua", lines = { "local x = 1", "print(x)" } },
    { type = "code_block", lines = { "no language" } },
    -- A drawn diagram, so the character-set guarantees below cover the mermaid
    -- path too. Under the block style this falls back to a code block whose
    -- body is the ASCII source, which is what keeps that variant pure ASCII.
    { type = "code_block", lang = "mermaid", lines = { "flowchart TD", "A[One] --> B[Two]" } },
    { type = "rule" },
    {
      type = "table",
      header = { { { text = "Command" } }, { { text = "Description" } } },
      align = { "left", "right" },
      rows = {
        { { { text = ":MdView" } }, { { text = "open" } } },
        { { { text = ":MdViewClose" } }, { { text = "close" } } },
      },
    },
    { type = "raw", lines = { "<div>", "html", "</div>" } },
  })
  return blocks
end

--- The config variants that change marker emission.
local function variants(base)
  local cfgs = { base() }
  local numbered = base()
  numbered.code.line_numbers = true
  cfgs[#cfgs + 1] = numbered
  local plain = base()
  for key in pairs(plain.elements) do
    plain.elements[key] = false
  end
  cfgs[#cfgs + 1] = plain
  local narrow = base()
  narrow.heading.gutter = 1
  cfgs[#cfgs + 1] = narrow
  local no_underline = base()
  no_underline.heading.underline_levels = 0
  cfgs[#cfgs + 1] = no_underline
  return cfgs
end

T["character set"]["glyph style emits only the verified-safe codepoints"] = function()
  -- Everything above ASCII must come either from the set confirmed present in
  -- Monaco (`█ • ‣ ·`) or from box drawing, which the terminal draws itself.
  local found = {}
  for _, cfg in ipairs(variants(cfg_copy)) do
    local res = renderer.render(kitchen_sink(), cfg)
    for i, line in ipairs(res.lines) do
      for _, cp in ipairs(non_ascii(line)) do
        if not SAFE[cp] then
          found[#found + 1] = string.format("line %d: U+%04X (%s)", i, cp, line)
        end
      end
    end
  end
  eq(found, {})
end

T["character set"]["glyph style really does emit the whole safe set"] = function()
  local seen = {}
  local res = renderer.render(kitchen_sink(), cfg_copy())
  for _, line in ipairs(res.lines) do
    for _, cp in ipairs(non_ascii(line)) do
      seen[cp] = true
    end
  end
  for cp, name in pairs(SAFE) do
    eq({ name, seen[cp] }, { name, true })
  end
end

T["character set"]["block style emits pure ASCII"] = function()
  local found = {}
  for _, cfg in ipairs(variants(block_cfg)) do
    local res = renderer.render(kitchen_sink(), cfg)
    for i, line in ipairs(res.lines) do
      for _, cp in ipairs(non_ascii(line)) do
        found[#found + 1] = string.format("line %d: U+%04X (%s)", i, cp, line)
      end
    end
  end
  eq(found, {})
end

T["character set"]["geometric shapes and checkboxes are never emitted"] = function()
  -- Box drawing and block elements are drawn by the terminal, but these are
  -- taken from the font, and Monaco simply does not have them.
  local banned = {}
  for _, base in ipairs({ cfg_copy, block_cfg }) do
    for _, cfg in ipairs(variants(base)) do
      local res = renderer.render(kitchen_sink(), cfg)
      for _, line in ipairs(res.lines) do
        for _, cp in ipairs(non_ascii(line)) do
          if UNSAFE[cp] then
            banned[#banned + 1] = string.format("U+%04X (%s)", cp, UNSAFE[cp])
          end
        end
      end
    end
  end
  eq(banned, {})
end

--------------------------------------------------------------------------
-- Renderer-side wrapping. The preview window is always 'nowrap', so hard
-- wrapping happens here -- and only for body text, never for the blocks that
-- horizontal scrolling exists for.
--------------------------------------------------------------------------

T["wrapping"] = MiniTest.new_set()

--- A long Japanese sentence: no spaces at all, every character two cells wide.
local JA = "これは日本語の長い段落です。折り返しは表示幅で測られます、そして禁則処理も行われます。"

T["wrapping"]["no width means no wrapping at all"] = function()
  local long = string.rep("word ", 40)
  local res = render({ { type = "paragraph", inline = { { text = long } } } })
  eq(#res.lines, 1)
end

T["wrapping"]["a long paragraph splits at spaces at the target width"] = function()
  local res = render({
    {
      type = "paragraph",
      inline = { { text = "The quick brown fox jumps over the lazy dog and keeps running for a while." } },
    },
  }, cfg_copy(), { width = 40 })
  eq(res.lines, {
    "The quick brown fox jumps over the lazy",
    "dog and keeps running for a while.",
  })
  for _, line in ipairs(res.lines) do
    eq({ line, vim.fn.strdisplaywidth(line) <= 40 }, { line, true })
    eq({ line, line:sub(-1) ~= " " }, { line, true }) -- no trailing space
  end
end

T["wrapping"]["text_width caps the window width"] = function()
  local cfg = cfg_copy()
  cfg.text_width = 20
  local res = render({
    { type = "paragraph", inline = { { text = "one two three four five six seven" } } },
  }, cfg, { width = 80 })
  for _, line in ipairs(res.lines) do
    eq({ line, vim.fn.strdisplaywidth(line) <= 20 }, { line, true })
  end
  eq(#res.lines > 1, true)
end

T["wrapping"]["wrap = false emits single logical lines"] = function()
  local cfg = cfg_copy()
  cfg.wrap = false
  local text = "The quick brown fox jumps over the lazy dog and keeps running for a while."
  local res = render({ { type = "paragraph", inline = { { text = text } } } }, cfg, { width = 20 })
  eq(res.lines, { text })
end

T["wrapping"]["a word longer than the whole width is emitted on its own line"] = function()
  local long = string.rep("x", 60)
  local res = render({
    { type = "paragraph", inline = { { text = "tiny " .. long .. " end" } } },
  }, cfg_copy(), { width = 20 })
  eq(res.lines, { "tiny", long, "end" })
end

T["wrapping"]["CJK splits by display width with no spaces present"] = function()
  local res = render({ { type = "paragraph", inline = { { text = JA } } } }, cfg_copy(), { width = 40 })
  eq(res.lines, {
    "これは日本語の長い段落です。折り返しは表",
    "示幅で測られます、そして禁則処理も行われ",
    "ます。",
  })
  -- display width, not byte or character count: 40 cells is 20 characters
  eq(vim.fn.strdisplaywidth(res.lines[1]), 40)
  eq(#res.lines[1], 60)
  eq(table.concat(res.lines), JA) -- nothing lost, nothing added
end

T["wrapping"]["kinsoku: closing marks never start a line"] = function()
  -- Without kinsoku the greedy break would put `。` at the head of line 2.
  local res = render({
    { type = "paragraph", inline = { { text = "あいうえおかきくけこ。さしすせそ" } } },
  }, cfg_copy(), { width = 20 })
  eq(res.lines, { "あいうえおかきくけ", "こ。さしすせそ" })
  for _, line in ipairs(res.lines) do
    for _, mark in ipairs({ "。", "、", "」", "）", "・", "？", "！" }) do
      eq({ line, vim.startswith(line, mark) }, { line, false })
    end
  end
end

T["wrapping"]["kinsoku: opening marks never end a line"] = function()
  local res = render({
    { type = "paragraph", inline = { { text = "あいうえおかきくけ「こ」さしすせそ" } } },
  }, cfg_copy(), { width = 20 })
  for _, line in ipairs(res.lines) do
    for _, mark in ipairs({ "「", "『", "（", "［" }) do
      eq({ line, vim.endswith(line, mark) }, { line, false })
    end
  end
end

T["wrapping"]["list items keep a hanging indent"] = function()
  local res = render({
    { type = "list_item", depth = 0, inline = { { text = "a list item whose text is long enough to need a second line" } } },
  }, cfg_copy(), { width = 40 })
  eq(res.lines, {
    "  • a list item whose text is long",
    "    enough to need a second line",
  })
  -- the bullet is decorated once, on the first line only
  eq(hls_of(res.decorations, "MdviewBullet1"), { { 0, 2, 5 } })
end

T["wrapping"]["ordered and task markers set their own hanging indent"] = function()
  local text = "an ordered item whose text needs more than one line to fit"
  local res = render({
    { type = "list_item", depth = 0, ordered = true, marker = "10.", inline = { { text = text } } },
    { type = "list_item", depth = 0, checkbox = "unchecked", inline = { { text = text } } },
  }, cfg_copy(), { width = 40 })
  eq(res.lines, {
    "  10. an ordered item whose text needs",
    "      more than one line to fit",
    "  [ ] an ordered item whose text needs",
    "      more than one line to fit",
  })
end

T["wrapping"]["blockquote continuation lines repeat the █ bar"] = function()
  local res = render({
    { type = "paragraph", quote = 2, inline = { { text = "a blockquote that also runs past the available width" } } },
  }, cfg_copy(), { width = 40 })
  eq(res.lines, {
    "██ a blockquote that also runs past the",
    "██ available width",
  })
  -- both lines carry bars, a dimmed body and the quote background
  eq(hls_of(res.decorations, "MdviewQuoteBar"), { { 0, 0, 6 }, { 1, 0, 6 } })
  local bgs = line_bgs(res.decorations)
  eq({ bgs[0], bgs[1] }, { "MdviewQuoteBg", "MdviewQuoteBg" })
end

T["wrapping"]["headings wrap to the text column and never repeat the bar"] = function()
  local res = render({
    { type = "heading", level = 2, inline = { { text = "a heading long enough that it has to wrap onto a second line" } } },
  }, cfg_copy(), { width = 40 })
  eq(res.lines[1], "██      a heading long enough that it")
  eq(res.lines[2], "        has to wrap onto a second line")
  -- one bar, on the first line only; the heading colour covers both lines
  eq(hls_of(res.decorations, "MdviewH2Bar"), { { 0, 0, 6 } })
  -- byte columns differ (the bar is multibyte) but both are display column 8
  eq(hls_of(res.decorations, "MdviewH2"), { { 0, 12, #res.lines[1] }, { 1, 8, #res.lines[2] } })
end

T["wrapping"]["code blocks and rules are never wrapped"] = function()
  local wide = string.rep("x", 120)
  local res = render({
    { type = "code_block", lang = "lua", lines = { wide } },
    { type = "rule" },
  }, cfg_copy(), { width = 40 })
  eq(res.lines[2], "  " .. wide)
  eq(#res.lines[2], 122)
end

T["wrapping"]["an inline span crossing a break is split per line"] = function()
  -- `:MdViewToggle` is positioned so the break falls inside it.
  local res = render({
    {
      type = "paragraph",
      inline = {
        { text = "run the command " },
        { text = ":MdViewToggle", style = "code" },
        { text = " to flip it" },
      },
    },
  }, cfg_copy(), { width = 20 })
  eq(res.lines, { "run the command", ":MdViewToggle to", "flip it" })
  -- entirely on line 1: one decoration, no split needed
  eq(hls_of(res.decorations, "MdviewCode"), { { 1, 0, 13 } })

  -- now force the break *inside* the span: no break opportunity exists inside
  -- an unbroken ASCII word, so use a CJK span, which breaks anywhere.
  local res2 = render({
    {
      type = "paragraph",
      inline = { { text = "abc " }, { text = "日本語の強調表示", style = "bold" }, { text = " end" } },
    },
  }, cfg_copy(), { width = 14 })
  eq(res2.lines, { "abc 日本語の強", "調表示 end" })
  -- one decoration per emitted line, with columns relative to that line
  eq(hls_of(res2.decorations, "MdviewBold"), { { 0, 4, 19 }, { 1, 0, 9 } })
  eq(res2.lines[1]:sub(5, 19), "日本語の強")
  eq(res2.lines[2]:sub(1, 9), "調表示")
end

T["wrapping"]["a split span keeps its continuation prefix out of the columns"] = function()
  -- Inside a blockquote every continuation line is prefixed by `█ `, so the
  -- second half of the span must start after that prefix, not at column 0.
  local res = render({
    {
      type = "paragraph",
      quote = 1,
      inline = { { text = "abc " }, { text = "日本語の強調表示", style = "bold" }, { text = " end" } },
    },
  }, cfg_copy(), { width = 18 })
  eq(res.lines, { "█ abc 日本語の強調", "█ 表示 end" })
  local bold = hls_of(res.decorations, "MdviewBold")
  eq(#bold, 2)
  -- "█ " is 4 bytes; the first line's span starts 4 bytes past "abc "
  eq(bold[1], { 0, 8, 26 })
  eq(bold[2], { 1, 4, 10 })
  eq(res.lines[2]:sub(bold[2][2] + 1, bold[2][3]), "表示")
end

-- The wrapping engine is the renderer's densest `strdisplaywidth` consumer, and
-- 'ambiwidth' moves it in two independent ways: `break_allowed` decides on
-- whether either side of a boundary is full-width, and the available width is
-- the target minus the display width of the prefix. Both change under "double",
-- so these run under each setting rather than only under the default.
T["wrapping"]["under ambiwidth"] = MiniTest.new_set({
  parametrize = { { "single" }, { "double" } },
})

T["wrapping"]["under ambiwidth"]["never loops and never loses text, at any width"] = function(ambi)
  vim.o.ambiwidth = ambi
  -- Includes strings with no legal break anywhere (`。` may not start a line,
  -- so a run of them has to be emitted long rather than looping forever).
  local samples = {
    "",
    " ",
    "a",
    "あ",
    "「あ」。",
    "。。。。。。",
    string.rep("x", 30),
    "日本語abc混在テキストです。とても長い文章。",
    -- Kana and kanji are East Asian *Wide*: two cells whatever 'ambiwidth'
    -- says. Only AMBIGUOUS characters actually move, so a sample of them is
    -- what makes this case sensitive to the setting at all. Space-free,
    -- because a break consumes the space it happens at -- under "single" every
    -- character here is one cell, so nothing may break and the run comes out
    -- long; under "double" it breaks.
    "±30°C·α→β·±40°C·γ→δ",
  }
  for _, text in ipairs(samples) do
    for w = 1, 20 do
      local res = render({ { type = "paragraph", inline = { { text = text } } } }, cfg_copy(), { width = w })
      eq({ ambi, text, w, table.concat(res.lines) }, { ambi, text, w, text })
    end
  end
end

T["wrapping"]["under ambiwidth"]["a blockquote wraps inside the width its bars leave"] = function(ambi)
  vim.o.ambiwidth = ambi
  -- `█` is ambiguous, so the `██ ` prefix is 3 cells under "single" and 5 under
  -- "double" -- the body gets two fewer cells and breaks one word earlier.
  local golden = {
    single = { "██ a blockquote that also runs past the", "██ available width" },
    double = { "██ a blockquote that also runs past", "██ the available width" },
  }
  local res = render({
    { type = "paragraph", quote = 2, inline = { { text = "a blockquote that also runs past the available width" } } },
  }, cfg_copy(), { width = 40 })
  eq(res.lines, golden[ambi])
  for _, line in ipairs(res.lines) do
    eq({ line, vim.fn.strdisplaywidth(line) <= 40 }, { line, true })
  end
  -- Decoration columns are byte offsets, so they are the same under both
  -- settings even though the cells they cover are not.
  eq(hls_of(res.decorations, "MdviewQuoteBar"), { { 0, 0, 6 }, { 1, 0, 6 } })
end

T["wrapping"]["under ambiwidth"]["no line overflows the target width"] = function(ambi)
  vim.o.ambiwidth = ambi
  -- Every sample here has a legal break available, so nothing is forced long.
  local samples = {
    "one two three four five six seven eight nine ten eleven twelve",
    "日本語のテキストは空白がないので任意の位置で折り返せます",
    "混在した text と日本語が並ぶ場合の折り返し behaviour を確認する",
    "α β γ δ ε ζ η θ ι κ λ μ ν ξ ο π", -- ambiguous: one cell or two
  }
  for _, text in ipairs(samples) do
    for _, w in ipairs({ 12, 20, 33, 40 }) do
      local res = render({ { type = "paragraph", inline = { { text = text } } } }, cfg_copy(), { width = w })
      for _, line in ipairs(res.lines) do
        eq({ ambi, w, line, vim.fn.strdisplaywidth(line) <= w }, { ambi, w, line, true })
      end
    end
  end
end

T["wrapping"]["a column too narrow to read is not wrapped at all"] = function()
  -- 8 cells is the floor. A level-3 heading's prefix is 8 cells, so at width 12
  -- only 4 remain -- two CJK characters per line. Emitting the block long lets
  -- the reader scroll it instead, which is what tables and code blocks do.
  local heading = { { type = "heading", level = 3, inline = { { text = "日本語の見出しです" } } } }
  local narrow = render(heading, cfg_copy(), { width = 12 })
  eq(#narrow.lines, 1)
  eq(narrow.lines[1], "███     日本語の見出しです")

  -- One cell of headroom over the floor and it wraps again.
  local wide = render(heading, cfg_copy(), { width = 20 })
  eq(#wide.lines > 1, true)
  eq(wide.lines[1], "███     日本語の見出")
end

T["wrapping"]["the floor is measured after the prefix, not against the window"] = function()
  -- Same window width, different prefixes: a paragraph has room to wrap where
  -- a level-6 heading does not.
  local text = "日本語のテキストです"
  local w = 14
  local para = render({ { type = "paragraph", inline = { { text = text } } } }, cfg_copy(), { width = w })
  local head = render({ { type = "heading", level = 6, inline = { { text = text } } } }, cfg_copy(), { width = w })
  eq({ #para.lines > 1, #head.lines }, { true, 1 })
end

T["wrapping"]["a deeply nested quote collapses instead of exploding"] = function()
  -- The prefix grows with depth, so without a floor each source character
  -- would become its own line, each carrying a depth-sized bar run.
  local res = render({
    { type = "paragraph", quote = 40, inline = { { text = string.rep("あ", 50) } } },
  }, cfg_copy(), { width = 40 })
  eq(#res.lines, 1)
end

T["wrapping"]["a re-render picks up a changed 'ambiwidth'"] = function()
  -- Per-character widths are memoised, so this is the case that pins the cache
  -- to the option: a cache that outlived the flip would keep measuring `± ° ·`
  -- as one cell and wrap the second render exactly like the first.
  local text = "±30°C · ±40°C · ±50°C · ±60°C"
  local blocks = { { type = "paragraph", inline = { { text = text } } } }

  -- Each result is measured while its own setting is still in force: the same
  -- string measures differently afterwards, which is the whole point here.
  local function fits(res)
    for _, line in ipairs(res.lines) do
      eq({ line, vim.fn.strdisplaywidth(line) <= 20 }, { line, true })
    end
  end

  vim.o.ambiwidth = "single"
  local single = render(blocks, cfg_copy(), { width = 20 })
  fits(single)

  vim.o.ambiwidth = "double"
  local double = render(blocks, cfg_copy(), { width = 20 })
  fits(double)

  -- Same text, same target width: twice the cells per ambiguous mark needs
  -- strictly more lines to hold it.
  eq({ #single.lines < #double.lines, #single.lines, #double.lines }, { true, #single.lines, #double.lines })
end

T["wrapping"]["inline code keeps its chip background on every emitted line"] = function()
  local res = render({
    { type = "paragraph", inline = { { text = "コードの折り返し", style = "code" } } },
  }, cfg_copy(), { width = 8 })
  eq(#res.lines, 2)
  eq(hls_of(res.decorations, "MdviewCode"), hls_of(res.decorations, "MdviewCodeBg"))
  eq(#hls_of(res.decorations, "MdviewCode"), 2)
end

return T
