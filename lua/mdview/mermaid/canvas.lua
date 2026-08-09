--- The grid every mermaid diagram is drawn on, and the emit pass that walks it
--- into lines plus `hl` decorations.
---
--- This module owns the two mechanisms that make diagram alignment structural
--- rather than something a test has to check: the column whose width is exactly
--- one `─`, and the per-cell bitmask that turns overlapping line segments into
--- the right junction glyph. It knows how to put a glyph, a box or a run of text
--- into cells; *where* they go is the diagram type's business.
---
--- It is the only part of the package that measures text, so it is also the only
--- part with an `ambiwidth` dependency -- see `rule_width`.
local M = {}

local displaywidth = vim.fn.strdisplaywidth

-- Which directions a line leaves a cell. The glyph is chosen once, at emit
-- time, from the accumulated mask -- so crossings, T-junctions and the joins
-- where an edge meets a box border all fall out of OR-ing bits together
-- instead of being special-cased per shape.
local BIT_U, BIT_D, BIT_L, BIT_R = 1, 2, 4, 8
M.BIT_U, M.BIT_D, M.BIT_L, M.BIT_R = BIT_U, BIT_D, BIT_L, BIT_R

-- All sixteen masks land on the eleven box-drawing characters already in the
-- plugin's verified-safe set. Nothing here may grow that set.
local GLYPH = {
  [BIT_U + BIT_D] = "│",
  [BIT_L + BIT_R] = "─",
  [BIT_D + BIT_R] = "┌",
  [BIT_D + BIT_L] = "┐",
  [BIT_U + BIT_R] = "└",
  [BIT_U + BIT_L] = "┘",
  [BIT_U + BIT_D + BIT_R] = "├",
  [BIT_U + BIT_D + BIT_L] = "┤",
  [BIT_D + BIT_L + BIT_R] = "┬",
  [BIT_U + BIT_L + BIT_R] = "┴",
  [BIT_U + BIT_D + BIT_L + BIT_R] = "┼",
  -- A one-directional stub still has to draw as a line.
  [BIT_U] = "│",
  [BIT_D] = "│",
  [BIT_L] = "─",
  [BIT_R] = "─",
}

local GROUP_BOX = "MdviewMermaidBox"
local GROUP_LABEL = "MdviewMermaidLabel"
local GROUP_EDGE_LABEL = "MdviewMermaidEdgeLabel"
local EDGE_GROUP = {
  solid = "MdviewMermaidEdge",
  dotted = "MdviewMermaidEdgeDim",
  thick = "MdviewMermaidEdgeStrong",
}
M.GROUP_BOX = GROUP_BOX
M.GROUP_LABEL = GROUP_LABEL
M.GROUP_EDGE_LABEL = GROUP_EDGE_LABEL
M.EDGE_GROUP = EDGE_GROUP

M.MARKER_CHAR = {
  down = { arrow = "v", circle = "o", cross = "x" },
  up = { arrow = "^", circle = "o", cross = "x" },
  right = { arrow = ">", circle = "o", cross = "x" },
  left = { arrow = "<", circle = "o", cross = "x" },
}

--- The width of one canvas column in display cells.
---
--- Re-measured per call rather than memoised at module level: 'ambiwidth' can
--- change between two renders in one session, and this single number is what a
--- whole layout is denominated in.
function M.rule_width()
  return math.max(1, displaywidth("─"))
end

--- LuaJIT has no `|` operator, and this module stays plain Lua rather than
--- reaching for `require("bit")`. The four flags are distinct powers of two, so
--- OR is "add it unless it is already there".
local function set_bit(mask, bit)
  if mask % (bit + bit) >= bit then
    return mask
  end
  return mask + bit
end

--- A grid whose every column is exactly `rule_w` display cells wide.
---
--- That is the whole answer to 'ambiwidth'. Box drawing is East Asian
--- Ambiguous, so `─ │ ┌ ┐ …` are one cell normally and two under
--- `ambiwidth = "double"`, while ASCII stays one either way. Measuring the
--- layout in units of `strdisplaywidth("─")` -- rather than correcting for the
--- discrepancy afterwards, as `render_table` has to -- makes alignment
--- structural: a glyph fills exactly one column by definition, and text is
--- padded out to a whole number of them.
function M.new_canvas(rule_w)
  return { rule_w = rule_w, mask = {}, group = {}, spans = {}, rows = 0, cols = 0 }
end

local function cv_touch(cv, row, col)
  if row + 1 > cv.rows then
    cv.rows = row + 1
  end
  if col + 1 > cv.cols then
    cv.cols = col + 1
  end
end

--- Add one connection bit to a cell. The first writer of a cell owns its
--- highlight group, so an edge meeting a box border is coloured as border.
function M.bits(cv, row, col, bits, group)
  local m = cv.mask[row]
  if not m then
    m = {}
    cv.mask[row] = m
    cv.group[row] = {}
  end
  local cur = m[col] or 0
  for _, bit in ipairs(bits) do
    cur = set_bit(cur, bit)
  end
  m[col] = cur
  if group and not cv.group[row][col] then
    cv.group[row][col] = group
  end
  cv_touch(cv, row, col)
end

--- Place text starting at `col`, occupying `cols` canvas columns.
function M.span(cv, row, col, text, cols, group)
  local s = cv.spans[row]
  if not s then
    s = {}
    cv.spans[row] = s
  end
  s[col] = { text = text, cols = cols, group = group }
  cv_touch(cv, row, col + cols - 1)
end

--- Canvas columns needed to hold `text`.
function M.text_cols(text, rule_w)
  return math.ceil(displaywidth(text) / rule_w)
end

--- Walk the grid into lines plus `hl` decorations. Byte columns are recorded
--- while the string is being built, never recomputed from display columns.
function M.emit(cv, prefix, lines, decs)
  local rule_w = cv.rule_w
  local blank = string.rep(" ", rule_w)
  for row = 0, cv.rows - 1 do
    local line = #lines -- 0-based index of the line about to be appended
    local parts, bytes = { prefix }, #prefix
    local run_group, run_start

    local function close_run()
      if run_group then
        decs[#decs + 1] = {
          kind = "hl",
          line = line,
          col_start = run_start,
          col_end = bytes,
          group = run_group,
          priority = 100,
        }
        run_group, run_start = nil, nil
      end
    end

    local function put(text, group)
      if group ~= run_group then
        close_run()
        if group then
          run_group, run_start = group, bytes
        end
      end
      parts[#parts + 1] = text
      bytes = bytes + #text
    end

    local col = 0
    while col < cv.cols do
      local span = cv.spans[row] and cv.spans[row][col]
      if span then
        put(span.text, span.group)
        -- Padding sits outside the highlight, so a label's background does not
        -- run past the text it belongs to.
        local pad = span.cols * rule_w - displaywidth(span.text)
        if pad > 0 then
          put(string.rep(" ", pad), nil)
        end
        col = col + span.cols
      else
        local m = cv.mask[row] and cv.mask[row][col]
        local glyph = m and GLYPH[m]
        if glyph then
          put(glyph, cv.group[row][col])
        else
          put(blank, nil)
        end
        col = col + 1
      end
    end
    close_run()
    -- Deliberately NOT right-trimmed. Every row is padded to the full canvas
    -- width, which makes "all rows are the same display width" an exact
    -- property of the output rather than something a test has to reconstruct --
    -- and that property is the one the whole column model exists to guarantee.
    -- The trailing spaces are invisible and carry no decoration.
    lines[#lines + 1] = table.concat(parts)
  end
end

--- Draw one node box, label included.
function M.draw_box(cv, it)
  local x, y, w, h = it.x, it.y, it.w, it.h
  local right = x + w - 1
  local bottom = y + h - 1
  M.bits(cv, y, x, { BIT_D, BIT_R }, GROUP_BOX)
  M.bits(cv, y, right, { BIT_D, BIT_L }, GROUP_BOX)
  M.bits(cv, bottom, x, { BIT_U, BIT_R }, GROUP_BOX)
  M.bits(cv, bottom, right, { BIT_U, BIT_L }, GROUP_BOX)
  for c = x + 1, right - 1 do
    M.bits(cv, y, c, { BIT_L, BIT_R }, GROUP_BOX)
    M.bits(cv, bottom, c, { BIT_L, BIT_R }, GROUP_BOX)
  end
  for r = y + 1, bottom - 1 do
    M.bits(cv, r, x, { BIT_U, BIT_D }, GROUP_BOX)
    M.bits(cv, r, right, { BIT_U, BIT_D }, GROUP_BOX)
    -- One column of padding inside each border, unless the box has been
    -- widened to match its layer (horizontal layouts do that), in which case
    -- the label is re-centred in the extra room.
    M.span(cv, r, x + (it.label_off or 2), it.label[r - y] or "", it.label_cols, GROUP_LABEL)
  end
end

--- Apply connection bits along a path of adjacent cells. Corners, crossings
--- and T-junctions need no special case: each step tells both of its cells
--- which way the line leaves them.
function M.draw_path(cv, path, group)
  for i = 1, #path - 1 do
    local a, b = path[i], path[i + 1]
    if a.col == b.col then
      local down = b.row > a.row
      M.bits(cv, a.row, a.col, { down and BIT_D or BIT_U }, group)
      M.bits(cv, b.row, b.col, { down and BIT_U or BIT_D }, group)
    else
      local right = b.col > a.col
      M.bits(cv, a.row, a.col, { right and BIT_R or BIT_L }, group)
      M.bits(cv, b.row, b.col, { right and BIT_L or BIT_R }, group)
    end
  end
end

return M
