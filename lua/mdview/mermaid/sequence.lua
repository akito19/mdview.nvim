--- The mermaid `sequenceDiagram` subset: source -> a participants-and-messages
--- IR, and that IR -> a drawn canvas.
---
--- `plan/mermaid-sequence.md` defines the supported subset; everything outside
--- it is a *hard bail* -- `nil, reason` -- so the caller can fall back to
--- rendering the fence as a plain code block. A wrong diagram is worse than no
--- diagram, so every ambiguity resolves towards bailing.
---
--- `M.parse` takes the lines of the shared prelude (see `text.lines_of`), not the
--- raw fence body. Unlike a flowchart, a sequence statement ends at the end of
--- its LINE: `;` is not a separator here, because message text is free text that
--- routinely contains one and mermaid's own grammar terminates on the newline.
---
--- On success:
---   { kind         = "sequencediagram",
---     participants = { { id = "A", label = { "line", ... } }, ... }, -- source order
---     index        = { A = 1, ... },                                -- id -> participants[i]
---     messages     = { { from = 1, to = 2, style = , marker = , label = }, ... } }
---
--- On failure: `nil, reason` where reason is one of "unparsed", "bad_id",
--- "unsupported_block", "unsupported_note", "unsupported_activation",
--- "unsupported_message", "unsupported_statement", "self_message", "too_big".
local text = require("mdview.mermaid.text")
local canvas = require("mdview.mermaid.canvas")

local trim, skip_ws, unquote, split_label =
  text.trim, text.skip_ws, text.unquote, text.split_label

local BIT_U, BIT_D, BIT_L, BIT_R = canvas.BIT_U, canvas.BIT_D, canvas.BIT_L, canvas.BIT_R
local EDGE_GROUP, GROUP_BOX, GROUP_EDGE_LABEL =
  canvas.EDGE_GROUP, canvas.GROUP_BOX, canvas.GROUP_EDGE_LABEL
local MARKER_CHAR = canvas.MARKER_CHAR
local cv_bits, cv_span, text_cols = canvas.bits, canvas.span, canvas.text_cols
local draw_box = canvas.draw_box

local M = {}

-- Participants count against `max_nodes` and messages against `max_edges`.
-- Reusing the two existing guards rather than adding a pair of their own: they
-- do the same job -- stop one pathological fence from stalling a `:w` -- and new
-- keys would be config surface with no user-visible benefit.
local DEFAULTS = { max_nodes = 60, max_edges = 120 }

-- Frames nest AND span lifelines, so they change the layout materially rather
-- than adding to it -- this diagram type's `subgraph`. Deferred, not forgotten.
local BLOCK = {
  alt = true,
  ["else"] = true,
  opt = true,
  loop = true,
  par = true,
  ["and"] = true,
  critical = true,
  option = true,
  ["break"] = true,
  rect = true,
  ["end"] = true,
}

local ACTIVATION = { activate = true, deactivate = true }

-- `actor` is here rather than drawn as a participant: the stick figure is the
-- whole difference between the two keywords, so drawing one as the other would
-- be a diagram that says something the source did not.
local UNSUPPORTED = {
  autonumber = true,
  box = true,
  create = true,
  destroy = true,
  links = true,
  link = true,
  actor = true,
}

-- One dash is solid, two are dashed; the terminator picks the end marker.
-- Dashed differs from solid by HIGHLIGHT GROUP alone (`dotted` -> the dim
-- group), exactly as `-.->` does in a flowchart: the glyph set has one line
-- weight, and inventing a second would need characters outside it.
--
-- Tried longest first, so `-->>` is not read as `-->` followed by a `>`.
local ARROWS = {
  { "-->>", { style = "dotted", marker = "arrow" } },
  { "-->", { style = "dotted", marker = "none" } },
  { "--x", { style = "dotted", marker = "cross" } },
  { "--)", { style = "dotted", marker = "async" } },
  { "->>", { style = "solid", marker = "arrow" } },
  { "->", { style = "solid", marker = "none" } },
  { "-x", { style = "solid", marker = "cross" } },
  { "-)", { style = "solid", marker = "async" } },
}

---------------------------------------------------------------------------
-- Parsing
---------------------------------------------------------------------------

--- `sequenceDiagram`, alone on its line, matched case-insensitively.
---
--- `init.lua` has already dispatched on the first alphabetic run in the body,
--- which is deliberately loose, so the header is re-validated here against this
--- module's OWN first statement -- anything else is not a diagram this module
--- can draw.
local function is_header(s)
  local keyword, rest = s:match("^(%a+)%s*(.*)$")
  return keyword ~= nil and keyword:lower() == "sequencediagram" and trim(rest) == ""
end

--- Read a participant id at `pos`. Ids are `[A-Za-z0-9_]`, the same class and
--- the same reasoning as flowchart node ids: mermaid documents no id grammar,
--- so a conservative class is the only defensible choice.
---
--- `bad_id` when the character there cannot start an id; `unparsed` when the
--- statement ran out or an arrow starts where an id was expected.
local function read_id(s, pos)
  local id, after = s:match("^([%w_]+)()", pos)
  if not id then
    if pos > #s or s:match("^[%-<>%)]", pos) then
      return nil, "unparsed"
    end
    return nil, "bad_id"
  end
  return id, after
end

--- Parse the arrow between two participants.
--- Returns `{ style, marker }, pos` or `nil, reason`.
local function parse_arrow(s, pos)
  -- `<<->>` / `<<-->>`: bidirectional. A source-end marker has nowhere to go
  -- that is not the lifeline junction, and drawing it one-directional would say
  -- something the source did not.
  if s:sub(pos, pos + 1) == "<<" then
    return nil, "unsupported_message"
  end
  for _, entry in ipairs(ARROWS) do
    local token = entry[1]
    if s:sub(pos, pos + #token - 1) == token then
      -- `A->>+B` / `A->>-B` are activation shorthand, which changes the
      -- lifeline's shape rather than decorating it.
      if s:match("^[+%-]", pos + #token) then
        return nil, "unsupported_activation"
      end
      return entry[2], pos + #token
    end
  end
  return nil, "unparsed"
end

--- Register a participant, or update the label of one already seen.
---
--- Column order is FIRST APPEARANCE, whether the participant was declared or
--- only mentioned -- the same rule flowchart nodes follow. A repeated
--- `participant` is last-write-wins for its label, as a repeated node id is, and
--- a bare mention carries no label so it cannot erase one.
local function register(graph, id, label)
  local i = graph.index[id]
  if i then
    if label then
      graph.participants[i].label = label
    end
    return i
  end
  graph.participants[#graph.participants + 1] = { id = id, label = label or { id } }
  graph.index[id] = #graph.participants
  return #graph.participants
end

--- `participant A` / `participant A as Alice` / `participant A as "Alice"`.
--- `rest` is everything after the keyword. Returns nil, or a reason string.
local function parse_participant(rest, graph)
  rest = trim(rest)
  if rest == "" then
    return "unparsed"
  end
  local id, after = rest:match("^([%w_]+)()")
  if not id then
    return "bad_id"
  end
  local tail = rest:sub(after)
  -- A character that cannot follow an id means the id was never valid.
  if tail ~= "" and not tail:match("^%s") then
    return "bad_id"
  end
  tail = trim(tail)

  local label
  if tail == "" then
    label = { id }
  else
    local alias = tail:match("^[Aa][Ss]%s+(.*)$")
    if not alias then
      return "unparsed"
    end
    alias = trim(unquote(alias))
    if alias == "" then
      return "unparsed"
    end
    -- An alias splits on `<br/>` into a multi-line box, exactly as a node label
    -- does; only MESSAGE text refuses it, because that is drawn on one row.
    label = split_label(alias)
  end
  register(graph, id, label)
end

--- `A <arrow> B` with an optional `: text`. Returns nil, or a reason string.
local function parse_message(s, graph)
  local from, pos = read_id(s, 1)
  if not from then
    return pos
  end
  if pos <= #s and not s:match("^[%s%-<]", pos) then
    return "bad_id"
  end
  pos = skip_ws(s, pos)

  local arrow, np = parse_arrow(s, pos)
  if not arrow then
    return np
  end
  pos = skip_ws(s, np)

  local to, np2 = read_id(s, pos)
  if not to then
    return np2
  end
  pos = np2
  if pos <= #s and not s:match("^[%s:]", pos) then
    return "bad_id"
  end
  -- A self-message needs a loop back onto one lifeline, which is a second row
  -- shape this layout does not have.
  if from == to then
    return "self_message"
  end

  pos = skip_ws(s, pos)
  local label
  if pos <= #s then
    -- The text part is optional, but anything other than `:` after the target
    -- is not a statement this parser knows.
    if s:sub(pos, pos) ~= ":" then
      return "unparsed"
    end
    label = trim(unquote(trim(s:sub(pos + 1))))
    if label == "" then
      label = nil
    end
  end
  -- Message text is drawn on the single row of its arrow, so keeping a `<br/>`
  -- literal would print those characters inside the diagram -- wrong text, and
  -- by this package's own rule a wrong diagram is worse than none.
  if label and label:lower():find("<br", 1, true) then
    return "unsupported_message"
  end

  -- Registered in this order, and only once the statement is known good: an
  -- implicit participant takes its column at first MENTION, source before
  -- target.
  local a = register(graph, from)
  local b = register(graph, to)
  graph.messages[#graph.messages + 1] = {
    from = a,
    to = b,
    style = arrow.style,
    marker = arrow.marker,
    label = label,
  }
end

--- Dispatch one statement. Returns nil on success, a reason string on failure.
---
--- A leading keyword is taken as a keyword whenever the statement's first word
--- is one, without the "unless a connector follows" escape `flowchart.lua`
--- needs. The two cases pull opposite ways: there, mistaking a node id for a
--- keyword would SKIP a statement and silently draw a wrong diagram, so the
--- doubt has to resolve towards parsing; here every keyword below BAILS, so the
--- doubt resolves towards bailing all by itself. A participant that shares a
--- name with a reserved word is unusable in mermaid anyway.
local function parse_statement(s, graph)
  local word = s:match("^(%a[%w_]*)")
  local key = word and word:lower()
  if key == "participant" then
    return parse_participant(s:sub(#word + 1), graph)
  elseif BLOCK[key] then
    return "unsupported_block"
  elseif key == "note" then
    return "unsupported_note"
  elseif ACTIVATION[key] then
    return "unsupported_activation"
  elseif UNSUPPORTED[key] then
    return "unsupported_statement"
  end
  return parse_message(s, graph)
end

--- Parse a sequence diagram.
---@param lines string[] prelude lines, from `text.lines_of`
---@param opts table|nil { max_nodes = 60, max_edges = 120 }
---@return table|nil graph, string|nil reason
function M.parse(lines, opts)
  opts = opts or {}
  local max_nodes = opts.max_nodes or DEFAULTS.max_nodes
  local max_edges = opts.max_edges or DEFAULTS.max_edges

  if not lines[1] or not is_header(lines[1]) then
    return nil, "unparsed"
  end

  local graph = { kind = "sequencediagram", participants = {}, index = {}, messages = {} }
  for i = 2, #lines do
    local err = parse_statement(lines[i], graph)
    if err then
      return nil, err
    end
    if #graph.participants > max_nodes or #graph.messages > max_edges then
      return nil, "too_big"
    end
  end
  return graph
end

---------------------------------------------------------------------------
-- Layout and drawing
---------------------------------------------------------------------------

local GAP = 2 -- canvas columns between two participant boxes

--- The lifeline column of a participant: the same `floor(w / 2)` port rule
--- flowchart boxes use.
local function port_col(it)
  return it.x + math.floor(it.w / 2)
end

--- Box geometry, in canvas columns and rows.
---
--- Every box takes the height of the tallest, so every lifeline starts on the
--- same row. `draw_box` fills the spare interior rows with empty label lines.
local function size_boxes(graph, rule_w)
  local boxes = {}
  local band = 3
  for i, p in ipairs(graph.participants) do
    local cols = 1
    for _, line in ipairs(p.label) do
      cols = math.max(cols, text_cols(line, rule_w))
    end
    boxes[i] = { label = p.label, label_cols = cols, w = cols + 4, h = #p.label + 2, y = 0 }
    band = math.max(band, boxes[i].h)
  end
  for _, it in ipairs(boxes) do
    it.h = band
  end
  return boxes, band
end

--- One left-to-right sweep. Every constraint runs from a lower index to a
--- higher one, so this is a longest-path solve rather than a search: there is
--- nothing to iterate to convergence and no ordering choice to make.
---
--- `x[j]` clears the previous box by `GAP`, and clears every message touching
--- `j` from the left by enough run to hold its text plus the marker column.
local function place_x(boxes, messages, mcols)
  if #boxes == 0 then
    return
  end
  boxes[1].x = 0
  for j = 2, #boxes do
    local x = boxes[j - 1].x + boxes[j - 1].w + GAP
    for k, msg in ipairs(messages) do
      local lo = math.min(msg.from, msg.to)
      if math.max(msg.from, msg.to) == j then
        -- Run columns needed strictly between the two lifelines: the text, plus
        -- one for the end marker. An unlabelled message still gets one, so no
        -- pair ever collapses to `├┤`.
        local run = mcols[k] + 1
        x = math.max(x, port_col(boxes[lo]) + 1 + run - math.floor(boxes[j].w / 2))
      end
    end
    boxes[j].x = x
  end
end

--- Lay out and draw a parsed sequence diagram.
---
--- Rows are the header band, one lifeline row, then a message row and a
--- lifeline row per message. The trailing lifeline row is what stops the diagram
--- ending on an arrow.
---
--- There are no bottom participant boxes. Mermaid repeats them; three rows and a
--- duplicate of every label to restate what the top of the diagram already says
--- is not worth it at this size.
---@param graph table from `M.parse`
---@param opts table|nil { prefix = "" } prepended to every line
---@return table { lines = string[], decorations = table[] }
function M.draw(graph, opts)
  opts = opts or {}
  local rule_w = canvas.rule_width()
  local cv = canvas.new_canvas(rule_w)

  local boxes, band = size_boxes(graph, rule_w)
  local mcols = {}
  for k, msg in ipairs(graph.messages) do
    mcols[k] = msg.label and text_cols(msg.label, rule_w) or 0
  end
  place_x(boxes, graph.messages, mcols)

  local last_row = band + 2 * #graph.messages

  for _, it in ipairs(boxes) do
    draw_box(cv, it)
  end

  -- Lifelines are drawn before the messages so that first-writer-wins makes the
  -- `├` / `┤` / `┼` junctions border-coloured: a lifeline is part of its
  -- participant's structure, like a box border, which is also why it takes
  -- `MdviewMermaidBox` rather than a group of its own.
  --
  -- The `┬` under each box falls out of adding one BIT_D to the bottom border
  -- cell; the bitmask needs no help.
  for _, it in ipairs(boxes) do
    local c = port_col(it)
    cv_bits(cv, band - 1, c, { BIT_D }, GROUP_BOX)
    for r = band, last_row do
      cv_bits(cv, r, c, { BIT_U, BIT_D }, GROUP_BOX)
    end
  end

  for k, msg in ipairs(graph.messages) do
    local row = band + 2 * k - 1
    local cs, ct = port_col(boxes[msg.from]), port_col(boxes[msg.to])
    local group = EDGE_GROUP[msg.style] or EDGE_GROUP.solid
    local right = ct > cs

    cv_bits(cv, row, cs, { right and BIT_R or BIT_L }, group)
    cv_bits(cv, row, ct, { right and BIT_L or BIT_R }, group)
    for c = math.min(cs, ct) + 1, math.max(cs, ct) - 1 do
      cv_bits(cv, row, c, { BIT_L, BIT_R }, group)
    end

    -- The end marker sits in the run cell adjacent to the TARGET, so it points
    -- the way the message travels. `none` has no character and simply leaves the
    -- line unbroken.
    local char = MARKER_CHAR[right and "right" or "left"][msg.marker]
    if char then
      cv_span(cv, row, right and (ct - 1) or (ct + 1), char, 1, group)
    end

    -- Text sits on the run, against the SOURCE lifeline and reading towards the
    -- target -- the same convention a horizontal flowchart edge label uses.
    -- `place_x` has already reserved the room, so there is no collision case and
    -- nothing to displace.
    if msg.label then
      local col = right and (cs + 1) or (cs - mcols[k])
      cv_span(cv, row, col, msg.label, mcols[k], GROUP_EDGE_LABEL)
    end
  end

  local lines, decorations = {}, {}
  canvas.emit(cv, opts.prefix or "", lines, decorations)
  return { lines = lines, decorations = decorations }
end

return M
