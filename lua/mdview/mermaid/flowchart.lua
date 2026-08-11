--- The mermaid `flowchart` / `graph` subset: source -> a guaranteed-acyclic
--- graph IR, and that IR -> a drawn canvas.
---
--- `plan/mermaid.md` defines the supported subset; everything outside it is a
--- *hard bail* -- `nil, reason` -- so the caller can fall back to rendering the
--- fence as a plain code block. A wrong diagram is worse than no diagram, so
--- every ambiguity resolves towards bailing.
---
--- `M.parse` takes the lines of the shared prelude (see `text.lines_of`), not
--- the raw fence body: frontmatter, comments and blanks are already gone, and
--- turning what is left into statements -- splitting on `;` -- is this diagram
--- type's own business.
---
--- On success:
---   { kind   = "flowchart",
---     dir    = "TB" | "BT" | "LR" | "RL",
---     nodes  = { { id = "A", label = { "line", ... } }, ... },  -- source order
---     index  = { A = 1, ... },                                  -- id -> nodes[i]
---     edges  = { { from = 1, to = 2, marker = ..., style = ..., label = ... } } }
---
--- On failure: `nil, reason` where reason is one of "not_flowchart",
--- "subgraph", "cycle", "bad_id", "unsupported_node", "unsupported_edge",
--- "unparsed", "too_big".
local text = require("mdview.mermaid.text")
local canvas = require("mdview.mermaid.canvas")

local trim, skip_ws, unquote, split_label =
  text.trim, text.skip_ws, text.unquote, text.split_label

local BIT_U, BIT_D, BIT_L, BIT_R = canvas.BIT_U, canvas.BIT_D, canvas.BIT_L, canvas.BIT_R
local EDGE_GROUP, GROUP_EDGE_LABEL = canvas.EDGE_GROUP, canvas.GROUP_EDGE_LABEL
local MARKER_CHAR = canvas.MARKER_CHAR
local cv_bits, cv_span, text_cols = canvas.bits, canvas.span, canvas.text_cols
local draw_box, draw_path = canvas.draw_box, canvas.draw_path

local M = {}

local DEFAULTS = { max_nodes = 60, max_edges = 120 }

-- `TD` is a synonym of `TB`; normalising here means downstream layout has four
-- directions to handle, not five.
local DIRECTIONS = { TB = "TB", TD = "TB", BT = "BT", LR = "LR", RL = "RL" }

-- Statements parsed only far enough to be ignored.
local SKIPPED = {
  classDef = true,
  class = true,
  style = true,
  linkStyle = true,
  click = true,
}

local MARKERS = { [">"] = "arrow", ["o"] = "circle", ["x"] = "cross", [""] = "none" }

-- The fifteen classic bracket forms, longest opener first: `[[x]]` must not be
-- read as `[` + `[x]`. Shape is discarded after parsing (v1 draws every node as
-- a rectangle) but the delimiters still have to be consumed correctly.
-- `[/x/]` and `[\x\]` accept either slash as the closer, which is what makes
-- the trapezoid forms `[/x\]` and `[\x/]` fall out for free.
local SHAPES = {
  { "(((", { ")))" } },
  { "((", { "))" } },
  { "([", { "])" } },
  { "[[", { "]]" } },
  { "[(", { ")]" } },
  { "[/", { "/]", "\\]" } },
  { "[\\", { "\\]", "/]" } },
  { "{{", { "}}" } },
  { "[", { "]" } },
  { "(", { ")" } },
  { "{", { "}" } },
  { ">", { "]" } },
}

---------------------------------------------------------------------------
-- Line -> statement splitting
---------------------------------------------------------------------------

--- Split one line into statements on `;`.
---
--- Not a plain `gmatch`: a `;` inside a label must not split, or the numeric
--- entity codes the subset deliberately leaves literal (`A["#35;"]`) would tear
--- in half. Bracket depth, double quotes and `|edge label|` all suppress it.
local function split_line(line, out)
  local depth, in_quote, in_pipe = 0, false, false
  local start = 1
  for i = 1, #line do
    local c = line:sub(i, i)
    if in_quote then
      if c == '"' then
        in_quote = false
      end
    elseif c == '"' then
      in_quote = true
    elseif c == "|" then
      in_pipe = not in_pipe
    elseif in_pipe then -- inside an edge label: nothing is structural
    elseif c == "[" or c == "(" or c == "{" then
      depth = depth + 1
    elseif c == "]" or c == ")" or c == "}" then
      depth = math.max(0, depth - 1)
    elseif c == ";" and depth == 0 then
      out[#out + 1] = line:sub(start, i - 1)
      start = i + 1
    end
  end
  out[#out + 1] = line:sub(start)
end

--- Prelude lines -> trimmed, non-empty statements. `;` separates statements in
--- a flowchart, so one line may carry several.
local function statements(lines)
  local out = {}
  for _, line in ipairs(lines) do
    split_line(line, out)
  end
  local stmts = {}
  for _, s in ipairs(out) do
    s = trim(s)
    if s ~= "" then
      stmts[#stmts + 1] = s
    end
  end
  return stmts
end

---------------------------------------------------------------------------
-- Node parsing
---------------------------------------------------------------------------

--- Read a label body between `open` (already consumed) and one of `closers`.
--- A quoted body may contain the closer, so quoting is handled first.
--- Returns `body, pos_after_closer` or `nil, reason`.
local function read_label(s, pos, closers)
  local at = skip_ws(s, pos)
  if s:sub(at, at) == '"' then
    local body, after = s:match('^"([^"]*)"%s*()', at)
    if not body then
      return nil, "unparsed"
    end
    for _, c in ipairs(closers) do
      if s:sub(after, after + #c - 1) == c then
        return body, after + #c
      end
    end
    return nil, "unparsed"
  end
  for i = pos, #s do
    for _, c in ipairs(closers) do
      if s:sub(i, i + #c - 1) == c then
        return s:sub(pos, i - 1), i + #c
      end
    end
  end
  return nil, "unparsed"
end

--- Parse one node reference at `pos`.
--- Returns `{ id = , label = list|nil }, pos` or `nil, reason`.
--- `label` is nil for a bare id, which is what lets a later bare reference keep
--- an earlier explicit label instead of resetting it to the id.
local function parse_node(s, pos)
  pos = skip_ws(s, pos)
  local id, after = s:match("^([%w_]+)()", pos)
  if not id then
    if pos > #s or s:match("^[%-=~<>|&]", pos) then
      return nil, "unparsed"
    end
    -- Something id-shaped was expected and the character cannot start one.
    return nil, "bad_id"
  end
  -- `end` as an id is the same hazard as an `end` statement: mermaid itself
  -- misparses it, and the container it closes is out of scope anyway.
  if id == "end" then
    return nil, "subgraph"
  end
  pos = after

  if s:sub(pos, pos + 1) == "@{" then
    return nil, "unsupported_node" -- v11.3+ `@{ shape: ... }` metadata
  end

  local label
  for _, shape in ipairs(SHAPES) do
    local open, closers = shape[1], shape[2]
    if s:sub(pos, pos + #open - 1) == open then
      local body, np = read_label(s, pos + #open, closers)
      if body == nil then
        return nil, np
      end
      local body_text = trim(body)
      if body_text:sub(1, 1) == "`" and body_text:sub(-1) == "`" then
        return nil, "unsupported_node" -- markdown-string label
      end
      label = split_label(body_text)
      pos = np
      break
    end
  end

  -- `:::class` is an inline suffix, not a statement: strip it and forget the
  -- class name, which v1 does not use.
  local np = s:match("^:::[%w_%-]*()", pos)
  if np then
    pos = np
  end
  if s:sub(pos, pos + 1) == "@{" then
    return nil, "unsupported_node"
  end
  -- A character that cannot follow an id means the id was never valid: ids are
  -- `[A-Za-z0-9_]` only, so `a.b` is a bad id rather than an unknown statement.
  if not (pos > #s or s:match("^[%s%-=~<>|&]", pos)) then
    return nil, "bad_id"
  end
  return { id = id, label = label }, pos
end

--- The largest `&` group worth building. A group a connector follows makes at
--- least `#members` edges (the smallest partner has one member); a lone group
--- makes at most `max_nodes` distinct nodes. The sum bounds both, so nothing
--- that would have parsed is lost -- except a lone group padded past the sum
--- with repeated ids, which draws nothing extra and bails the safe way.
local function group_cap(limits)
  return limits.max_nodes + limits.max_edges
end

--- Parse a `&`-separated group of node references, registering each in the
--- graph as it is seen (so `nodes` ends up in first-appearance order).
--- Returns `{ index, ... }, pos` or `nil, reason`.
local function parse_group(s, pos, graph, limits)
  local members = {}
  local cap = group_cap(limits)
  while true do
    local node, np = parse_node(s, pos)
    if not node then
      return nil, np
    end
    local i = graph.index[node.id]
    if i then
      if node.label then
        graph.nodes[i].label = node.label -- repeated id: last write wins
      end
    else
      graph.nodes[#graph.nodes + 1] = { id = node.id, label = node.label or { node.id } }
      i = #graph.nodes
      graph.index[node.id] = i
    end
    members[#members + 1] = i
    if #members > cap then
      return nil, "too_big"
    end
    pos = skip_ws(s, np)
    if s:sub(pos, pos) ~= "&" then
      return members, pos
    end
    pos = pos + 1
  end
end

---------------------------------------------------------------------------
-- Connector parsing
---------------------------------------------------------------------------

--- Try each closing pattern at `i`. Patterns either capture a marker and a
--- position, or only a position (meaning "no marker").
local function try_close(s, i, patterns)
  for _, pat in ipairs(patterns) do
    local a, b = s:match(pat, i)
    if a ~= nil then
      if b == nil then
        return "", a
      end
      return a, b
    end
  end
end

--- Scan forward for the closing half of a labelled link (`-- text -->`).
--- Returns `label, marker, pos` or nil.
---
--- Every closer below opens with a `+`-quantified run of one character (`-`,
--- `=` or `.`), so a closer matching at `i` when `s[i-1]` is that same character
--- also matches -- one character longer -- at `i - 1`, where this scan would
--- already have returned. Mid-run offsets can therefore be skipped, and that is
--- what keeps the scan linear: a failing `%.+%-` backtracks over the whole
--- remaining run, so retrying it at every offset of an n-character run of dots
--- costs O(n^2). Skipping leaves one attempt per run, and runs are disjoint.
local function labelled(s, pos, patterns)
  for i = pos, #s do
    if i == pos or s:sub(i - 1, i - 1) ~= s:sub(i, i) then
      local marker, after = try_close(s, i, patterns)
      if marker then
        return trim(s:sub(pos, i - 1)), marker, after
      end
    end
  end
end

local SOLID_CLOSE = { "^%-%-+([>ox])()", "^%-%-%-+()" }
local THICK_CLOSE = { "^==+([>ox])()", "^===+()" }
local DOTTED_CLOSE = { "^%.+%-([>ox]?)()" }

--- Attach an optional `|text|` label and finish the connector.
local function finish(style, marker, label, s, pos)
  local at = skip_ws(s, pos)
  local body, after = s:match("^|([^|]*)|()", at)
  if body then
    label = trim(unquote(body))
    pos = after
  elseif label then
    label = trim(unquote(label))
  end
  if label == "" then
    label = nil
  end
  -- A `<br/>` in an EDGE label bails, where a node label splits on it. An edge
  -- label is drawn on a single routing row, so keeping it literal would print
  -- the characters `<br/>` inside the diagram -- wrong text, and by this
  -- module's own rule a wrong diagram is worse than none. Multi-row edge labels
  -- would complicate channel routing for a rare construct; v1 refuses instead.
  if label and label:lower():find("<br", 1, true) then
    return nil, "unsupported_edge"
  end
  return { style = style, marker = MARKERS[marker], label = label }, pos
end

--- Parse one connector at `pos`. Returns `{ style, marker, label }, pos` or
--- `nil, reason`. Length is deliberately ignored: extra dashes only lengthen
--- the edge in mermaid's rank model, and layout here does not use it.
local function parse_connector(s, pos)
  pos = skip_ws(s, pos)

  -- `A e1@--> B`: an edge id. Bail rather than drop the id silently.
  if s:match("^[%w_]+@", pos) then
    return nil, "unsupported_edge"
  end
  -- Double-ended forms (`<-->`, `o--o`, `x--x`): a source-end marker would
  -- collide with the box border, and drawing them one-directional would be a
  -- semantically wrong diagram.
  if s:sub(pos, pos) == "<" or s:match("^[ox][%-=~]", pos) then
    return nil, "unsupported_edge"
  end

  local p = s:match("^~~~+()", pos)
  if p then
    -- Invisible, not absent: it still constrains layering downstream.
    return finish("invisible", "", nil, s, p)
  end

  local marker, after = s:match("^%-%.+%-([>ox]?)()", pos)
  if marker then
    return finish("dotted", marker, nil, s, after)
  end
  marker, after = s:match("^%-%-+([>ox])()", pos)
  if marker then
    return finish("solid", marker, nil, s, after)
  end
  after = s:match("^%-%-%-+()", pos)
  if after then
    return finish("solid", "", nil, s, after)
  end
  marker, after = s:match("^==+([>ox])()", pos)
  if marker then
    return finish("thick", marker, nil, s, after)
  end
  after = s:match("^===+()", pos)
  if after then
    return finish("thick", "", nil, s, after)
  end

  -- Labelled forms, tried last so that `---` is an open link rather than an
  -- unterminated `--` + label.
  local label
  if s:sub(pos, pos + 1) == "-." then
    label, marker, after = labelled(s, pos + 2, DOTTED_CLOSE)
    if label then
      return finish("dotted", marker, label, s, after)
    end
  elseif s:sub(pos, pos + 1) == "--" then
    label, marker, after = labelled(s, pos + 2, SOLID_CLOSE)
    if label then
      return finish("solid", marker, label, s, after)
    end
  elseif s:sub(pos, pos + 1) == "==" then
    label, marker, after = labelled(s, pos + 2, THICK_CLOSE)
    if label then
      return finish("thick", marker, label, s, after)
    end
  end

  return nil, "unparsed"
end

---------------------------------------------------------------------------
-- Statement dispatch
---------------------------------------------------------------------------

--- `flowchart <DIR>` / `graph <DIR>`, both keyword and direction matched
--- case-insensitively. Returns the normalised direction or nil.
---
--- The keyword itself has already selected this module (`init.lua` dispatches on
--- it), but the direction has not been looked at: `flowchart XY` is
--- `not_flowchart`, and that judgement belongs to the diagram type that owns the
--- direction vocabulary.
local function parse_header(s)
  local keyword, rest = s:match("^(%a+)%s*(.*)$")
  if not keyword then
    return nil
  end
  keyword = keyword:lower()
  if keyword ~= "flowchart" and keyword ~= "graph" then
    return nil
  end
  rest = trim(rest)
  if rest == "" then
    return "TB" -- direction omitted
  end
  return DIRECTIONS[rest:upper()]
end

--- A statement is a sequence of node groups separated by connectors; each
--- adjacent pair becomes the cross product of its members. Chaining, `&`
--- fan-out and the mixed form are all that one rule, not three special cases.
--- Returns nil on success, a reason string on failure.
local function parse_statement(s, graph, limits)
  local group, pos = parse_group(s, 1, graph, limits)
  if not group then
    return pos
  end
  while true do
    pos = skip_ws(s, pos)
    if pos > #s then
      return nil
    end
    local conn, np = parse_connector(s, pos)
    if not conn then
      return np
    end
    local next_group, np2 = parse_group(s, np, graph, limits)
    if not next_group then
      return np2
    end
    for _, from in ipairs(group) do
      for _, to in ipairs(next_group) do
        graph.edges[#graph.edges + 1] = {
          from = from,
          to = to,
          marker = conn.marker,
          style = conn.style,
          label = conn.label,
        }
        -- The budget is enforced inside the cross product, not after the
        -- statement: one `A & ... --> B & ...` materialises the full product
        -- first, so a check that runs afterwards can only fire once the memory
        -- it exists to prevent has already been allocated. O(1) per edge.
        if #graph.edges > limits.max_edges then
          return "too_big"
        end
      end
    end
    group, pos = next_group, np2
  end
end

--- True if the statement is one of the recognised-and-ignored keyword forms.
--- The keyword must be followed by whitespace or end there, and what follows
--- must not start a connector -- otherwise `style --> B` would vanish, which is
--- exactly the silent wrong diagram this parser refuses to produce.
local function is_skipped(s)
  local word, rest = s:match("^(%a[%w_]*)()")
  if not word or not SKIPPED[word] then
    return false
  end
  local tail = s:sub(rest)
  if tail ~= "" and not tail:match("^%s") then
    return false
  end
  return not trim(tail):match("^[%-=~<&]")
end

---------------------------------------------------------------------------
-- Cycle check
---------------------------------------------------------------------------

--- Depth-first three-colour search. Invisible edges take part: they constrain
--- layering, so a cycle through one is still a cycle. A successful `parse` is
--- therefore guaranteed acyclic and layout may assume a DAG.
local function has_cycle(graph)
  local adj = {}
  for _, e in ipairs(graph.edges) do
    local list = adj[e.from]
    if not list then
      list = {}
      adj[e.from] = list
    end
    list[#list + 1] = e.to
  end
  local state = {} -- nil = unseen, 1 = on the stack, 2 = done
  local function visit(v)
    state[v] = 1
    for _, w in ipairs(adj[v] or {}) do
      if state[w] == 1 then
        return true
      end
      if state[w] == nil and visit(w) then
        return true
      end
    end
    state[v] = 2
    return false
  end
  for i = 1, #graph.nodes do
    if state[i] == nil and visit(i) then
      return true
    end
  end
  return false
end

---------------------------------------------------------------------------
-- Parse entry point
---------------------------------------------------------------------------

--- Parse a flowchart.
---@param lines string[] prelude lines, from `text.lines_of`
---@param opts table|nil { max_nodes = 60, max_edges = 120 }
---@return table|nil graph, string|nil reason
function M.parse(lines, opts)
  opts = opts or {}
  local max_nodes = opts.max_nodes or DEFAULTS.max_nodes
  local max_edges = opts.max_edges or DEFAULTS.max_edges
  local limits = { max_nodes = max_nodes, max_edges = max_edges }

  local stmts = statements(lines)
  local dir = stmts[1] and parse_header(stmts[1])
  if not dir then
    return nil, "not_flowchart"
  end

  local graph = { kind = "flowchart", dir = dir, nodes = {}, index = {}, edges = {} }
  for i = 2, #stmts do
    local s = stmts[i]
    local word = s:match("^(%a[%w_]*)")
    if word == "subgraph" or word == "end" then
      return nil, "subgraph"
    end
    if not is_skipped(s) then
      local err = parse_statement(s, graph, limits)
      if err then
        return nil, err
      end
      if #graph.nodes > max_nodes or #graph.edges > max_edges then
        return nil, "too_big"
      end
    end
  end

  if #graph.nodes > max_nodes or #graph.edges > max_edges then
    return nil, "too_big"
  end
  if has_cycle(graph) then
    return nil, "cycle"
  end
  return graph
end

---------------------------------------------------------------------------
-- Layering
---------------------------------------------------------------------------

local GAP = 2 -- columns between sibling boxes when layers run down the screen
local VGAP = 1 -- rows between sibling boxes when layers run across the screen

--- Longest-path layering. `M.parse` guarantees acyclicity, so a Kahn sweep
--- reaches every node and no cycle guard is needed here.
local function assign_layers(graph)
  local n = #graph.nodes
  local outs, indeg, layer = {}, {}, {}
  for i = 1, n do
    outs[i], indeg[i], layer[i] = {}, 0, 0
  end
  for _, e in ipairs(graph.edges) do
    table.insert(outs[e.from], e.to)
    indeg[e.to] = indeg[e.to] + 1
  end
  local queue, head = {}, 1
  for i = 1, n do
    if indeg[i] == 0 then
      queue[#queue + 1] = i
    end
  end
  while head <= #queue do
    local u = queue[head]
    head = head + 1
    for _, v in ipairs(outs[u]) do
      if layer[u] + 1 > layer[v] then
        layer[v] = layer[u] + 1
      end
      indeg[v] = indeg[v] - 1
      if indeg[v] == 0 then
        queue[#queue + 1] = v
      end
    end
  end
  return layer
end

--- Nodes and dummies, bucketed by layer, plus the per-layer segments an edge
--- decomposes into. An edge spanning k layers becomes k segments chained
--- through k-1 one-column dummies, so a long edge routes through the channels
--- instead of crossing the boxes in between.
---
--- Ordering within a layer is FIRST APPEARANCE (real nodes in source order,
--- then dummies in edge order). Deterministic ordering is worth more here than
--- minimal crossings: it is what makes a golden test meaningful, and it matches
--- what the author wrote.
local function build_items(graph, layer)
  local nlayers = 1
  for i = 1, #graph.nodes do
    nlayers = math.max(nlayers, layer[i] + 1)
  end
  local layers = {}
  for l = 0, nlayers - 1 do
    layers[l] = {}
  end
  local of_node = {}
  for i, node in ipairs(graph.nodes) do
    local it = { node = i, layer = layer[i], label = node.label }
    of_node[i] = it
    table.insert(layers[layer[i]], it)
  end

  local segments = {}
  for _, e in ipairs(graph.edges) do
    local prev = of_node[e.from]
    for l = layer[e.from] + 1, layer[e.to] - 1 do
      -- The dummy carries its edge so the run THROUGH it (the part of the
      -- column no segment endpoint touches) can be drawn in the edge's colour.
      local d = { dummy = true, layer = l, edge = e }
      table.insert(layers[l], d)
      segments[#segments + 1] = { from = prev, to = d, edge = e, layer = l - 1 }
      prev = d
    end
    segments[#segments + 1] =
      { from = prev, to = of_node[e.to], edge = e, layer = layer[e.to] - 1, last = true }
  end
  return layers, nlayers, segments
end

--- Box geometry in canvas units. A dummy is a single cell the line passes
--- through.
local function size_items(layers, nlayers, rule_w)
  for l = 0, nlayers - 1 do
    for _, it in ipairs(layers[l]) do
      if it.dummy then
        it.w, it.h = 1, 1
      else
        local cols = 1
        for _, line in ipairs(it.label) do
          cols = math.max(cols, text_cols(line, rule_w))
        end
        it.label_cols = cols
        it.w = cols + 4 -- border + pad + label + pad + border
        it.h = #it.label + 2
      end
    end
  end
end

--- Screen position k holds this layer. `flip` reverses it, which is the whole
--- of BT (relative to TB) and RL (relative to LR).
local function screen_order(nlayers, flip)
  local order = {}
  for k = 0, nlayers - 1 do
    order[k] = flip and (nlayers - 1 - k) or k
  end
  return order
end

--- Lowest slot at which `span` fits beside what is already there. Used for the
--- jog rows of a channel and for its edge-label rows.
---
--- Two runs may TOUCH at a single coordinate when that coordinate is the same
--- kind of port for both of them -- a shared source (a fan-out leaving one node)
--- or a shared target (a fan-in arriving at one). That cell is a real junction,
--- and forcing the two runs onto separate slots instead is what made a fan-out
--- come out as a staircase rather than the symmetric `┌───┴───┐` it should be.
---
--- The check is deliberately narrow. Two runs touching anywhere else -- or at a
--- coordinate that is one segment's source and another's target, which can
--- happen when a box in the layer above and one in the layer below share a port
--- column -- would draw a junction where there is no connection.
---
--- Channel routing is the whole of what a flowchart layout does and no other
--- diagram type has, so this stays here rather than in `canvas.lua`.
---@param ports table|nil { src = , dst = } coordinates of this segment's ports
local function greedy_slot(rows, span, ports)
  local r = 0
  while true do
    local occupied, ok = rows[r], true
    if occupied then
      for _, s in ipairs(occupied) do
        local lo = math.max(span[1], s[1])
        local hi = math.min(span[2], s[2])
        if lo <= hi then
          local junction = lo == hi
            and ports
            and s.ports
            and ((ports.src == lo and s.ports.src == lo) or (ports.dst == lo and s.ports.dst == lo))
          if not junction then
            ok = false
            break
          end
        end
      end
    end
    if ok then
      rows[r] = occupied or {}
      span.ports = ports
      table.insert(rows[r], span)
      return r
    end
    r = r + 1
  end
end

local function slot_count(rows)
  local n = 0
  for r in pairs(rows) do
    n = math.max(n, r + 1)
  end
  return n
end

--- Group the segments by the channel they cross. `seg.layer` is always the
--- lower of the two layer indices, which is what makes this work for BT too:
--- flipping the screen order does not change which pair of layers a segment
--- joins, only which of them is drawn on top.
local function by_channel(segments, order, nlayers)
  local out = {}
  for k = 0, nlayers - 2 do
    out[k] = {}
  end
  local channel_of = {}
  for k = 0, nlayers - 2 do
    channel_of[math.min(order[k], order[k + 1])] = k
  end
  for _, seg in ipairs(segments) do
    local k = channel_of[seg.layer]
    if k then
      table.insert(out[k], seg)
    end
  end
  return out
end

---------------------------------------------------------------------------
-- Vertical layout (TB / BT)
---------------------------------------------------------------------------

--- Column an edge leaves or enters an item by.
local function port_col(it)
  if it.dummy then
    return it.x
  end
  return it.x + math.floor(it.w / 2)
end

--- Decide where the edge label sits relative to the vertical run it is anchored
--- to. Preference is the right of the line; the left is tried when a port column
--- of the same band would be underneath. If both collide the right is used
--- anyway -- the text then interrupts a line, which is cosmetic, where dropping
--- the label or bailing the diagram would cost real information.
---
--- `anchor` is the column of the run the label belongs to -- the SOURCE port for
--- a label in the pre band, the TARGET port for one in the post band -- and
--- `ports` holds the columns occupied in that band alone. Passing the other
--- band's columns too would push a label aside for a run that is nowhere near
--- it.
local function label_col(anchor, cols, ports)
  local function clear(a, b)
    for _, p in ipairs(ports) do
      if p >= a and p <= b and p ~= anchor then
        return false
      end
    end
    return true
  end
  if clear(anchor + 1, anchor + cols) then
    return anchor + 1
  end
  if anchor - cols >= 0 and clear(anchor - cols, anchor - 1) then
    return anchor - cols
  end
  return anchor + 1
end

--- How many non-invisible segments of this channel leave each source item and
--- arrive at each target item. Keyed on the ITEM, not on its port coordinate:
--- two boxes can share a column by coincidence of layout without sharing a port.
---
--- An invisible (`~~~`) segment draws nothing, so it cannot make a label
--- ambiguous and must not count towards either total.
local function share_counts(segs)
  local from_n, to_n = {}, {}
  for _, seg in ipairs(segs) do
    if seg.edge.style ~= "invisible" then
      from_n[seg.from] = (from_n[seg.from] or 0) + 1
      to_n[seg.to] = (to_n[seg.to] or 0) + 1
    end
  end
  return from_n, to_n
end

--- Which end of a labelled segment the label may be attributed to.
--- Returns `"pre"`, `"post"`, or nil meaning the whole diagram must bail.
---
--- A segment's run sits on its source coordinate up to and including its jog,
--- and on its target coordinate after it. So a label in the PRE band names the
--- source-side run and a label in the POST band names the target-side run --
--- after every jog in the channel, hence after any split.
---
--- | source shared | target shared | anchor |
--- |---|---|---|
--- | no  | either | pre: the source run is this edge's alone |
--- | yes | no     | post: the target run is this edge's alone |
--- | yes | yes    | bail: no run in this channel belongs to this edge alone |
---
--- Fan-in therefore keeps the source anchor, which is right: `B -->|yes| D` and
--- `C -->|no| D` leave different boxes and meet at one, so the source side is
--- where they are still distinguishable.
---
--- The both-shared case (`A -->|x| B` twice over, or a fan-out crossing a
--- fan-in) has no attributable placement at all, and a label the reader cannot
--- attach to an edge is a wrong diagram rather than a missing one. Per the
--- subset's own rule the fence falls back to the code block instead.
---
--- The post band relies on one guarantee: targets in a layer have distinct
--- ports, so of the segments sharing a source port at most one can run straight
--- and the rest must jog. In the post band every segment is therefore already on
--- its own target coordinate.
local function label_band(seg, from_n, to_n)
  if (from_n[seg.from] or 0) <= 1 then
    return "pre"
  end
  if (to_n[seg.to] or 0) <= 1 then
    return "post"
  end
  return nil
end

--- Plan one channel: how many rows it needs, and which row each jog and each
--- edge label goes in. Returns `{ size, pre, jogs, post }` -- the channel height
--- and the row counts of its three bands, in screen order away from the source
--- layer -- or nil when a label in it cannot be attributed to one edge.
---
--- `drawn` is the per-draw set of edges whose label has already been placed. It
--- is threaded in rather than flagged on the edge itself because the edge table
--- belongs to the graph, and `M.draw` must leave the graph exactly as `M.parse`
--- returned it -- a flag left behind there makes the second draw of one graph
--- drop every label, and the routing rows that carry them with it.
local function plan_channel(segs, rule_w, drawn)
  local jog_rows = {}
  local rows = { pre = {}, post = {} }
  -- Band-specific occupancy: the pre band holds the source-side runs, the post
  -- band the target-side ones.
  local ports = { pre = {}, post = {} }
  for _, seg in ipairs(segs) do
    seg.cx, seg.tx = port_col(seg.from), port_col(seg.to)
    table.insert(ports.pre, seg.cx)
    table.insert(ports.post, seg.tx)
  end
  local from_n, to_n = share_counts(segs)
  for _, seg in ipairs(segs) do
    if seg.edge.style ~= "invisible" then
      if seg.cx ~= seg.tx then
        seg.jog = greedy_slot(
          jog_rows,
          { math.min(seg.cx, seg.tx), math.max(seg.cx, seg.tx) },
          { src = seg.cx, dst = seg.tx }
        )
      end
      -- An edge's label is drawn once, on the first segment of its chain.
      if seg.edge.label and not drawn[seg.edge] then
        drawn[seg.edge] = true
        local band = label_band(seg, from_n, to_n)
        if not band then
          return nil
        end
        seg.label = seg.edge.label
        seg.label_band = band
        seg.label_cols = text_cols(seg.label, rule_w)
        seg.label_col =
          label_col(band == "pre" and seg.cx or seg.tx, seg.label_cols, ports[band])
        -- Only the slot WITHIN the band is known here; the band's own offset
        -- depends on how many rows the pre band ends up with, which is not
        -- settled until the whole channel is planned.
        seg.label_slot =
          greedy_slot(rows[band], { seg.label_col, seg.label_col + seg.label_cols - 1 })
      end
    end
  end
  local npre, nj, npost = slot_count(rows.pre), slot_count(jog_rows), slot_count(rows.post)
  return { size = npre + nj + npost + 1, pre = npre, jogs = nj, post = npost }
end

--- Route one segment through its channel and draw it.
---
--- `rows[i]` counts AWAY from the from-box, so the same code serves TB and BT:
--- pre-band label rows first, then jog rows, then the post-band label rows, then
--- the end-marker row nearest the target. The line is on the segment's source
--- column for everything up to and including its jog and on its target column
--- after it, which is exactly what makes the post band the attributable side of
--- a fan-out.
local function draw_segment(cv, seg, rows, plan, down)
  local group = EDGE_GROUP[seg.edge.style] or EDGE_GROUP.solid
  -- `rows` is 0-indexed, so its length comes from the plan rather than from `#`.
  local last = plan.size - 1
  local path = {}
  local function push(row, col)
    path[#path + 1] = { row = row, col = col }
  end

  push(down and (seg.from.y + seg.from.h - 1) or seg.from.y, seg.cx)
  if seg.jog then
    local j = plan.pre + seg.jog
    for i = 0, j do
      push(rows[i], seg.cx)
    end
    local step = seg.tx > seg.cx and 1 or -1
    local c = seg.cx + step
    while true do
      push(rows[j], c)
      if c == seg.tx then
        break
      end
      c = c + step
    end
    for i = j + 1, last do
      push(rows[i], seg.tx)
    end
  else
    for i = 0, last do
      push(rows[i], seg.cx)
    end
  end
  push(down and seg.to.y or (seg.to.y + seg.to.h - 1), seg.tx)

  draw_path(cv, path, group)

  -- The end marker replaces the line glyph in the cell next to the target. A
  -- span always wins over a mask at emit time, so the bits underneath still
  -- join the box border into `┴` / `┬`.
  if seg.last then
    local char = MARKER_CHAR[down and "down" or "up"][seg.edge.marker]
    if char then
      cv_span(cv, rows[last], seg.tx, char, 1, group)
    end
  end
  if seg.label then
    local row = seg.label_band == "post" and (plan.pre + plan.jogs + seg.label_slot)
      or seg.label_slot
    cv_span(cv, rows[row], seg.label_col, seg.label, seg.label_cols, GROUP_EDGE_LABEL)
  end
end

local function layout_vertical(layers, nlayers, segments, flip, cv, rule_w, drawn)
  local order = screen_order(nlayers, flip)

  -- X placement, layer by layer in dependency order so predecessors are always
  -- already positioned.
  --
  -- Centring each layer over the widest one is not enough: a box's port sits at
  -- `floor(w/2)`, so two boxes whose widths differ in parity end up with ports
  -- one column apart and even a straight chain jogs at every step. Instead each
  -- item aims its port at the mean port of its predecessors, and the layer is
  -- then shifted so the group as a whole sits under them. A chain comes out
  -- perfectly straight; a fan-out stays centred under its parent.
  local preds = {}
  for _, seg in ipairs(segments) do
    local list = preds[seg.to]
    if not list then
      list = {}
      preds[seg.to] = list
    end
    list[#list + 1] = seg.from
  end

  for l = 0, nlayers - 1 do
    local items = layers[l]
    local desired = {}
    for i, it in ipairs(items) do
      local ps = preds[it]
      if ps and #ps > 0 then
        local sum = 0
        for _, p in ipairs(ps) do
          sum = sum + port_col(p)
        end
        desired[i] = sum / #ps
      end
    end

    local cursor = 0
    for i, it in ipairs(items) do
      local off = it.dummy and 0 or math.floor(it.w / 2)
      local want = desired[i] and math.floor(desired[i] - off + 0.5) or cursor
      it.x = math.max(cursor, want)
      cursor = it.x + it.w + GAP
    end

    -- Packing can only push items right of where they wanted to be, so the
    -- layer is re-centred on the average of what it wanted.
    local n, want_sum, got_sum = 0, 0, 0
    for i, it in ipairs(items) do
      if desired[i] then
        n, want_sum, got_sum = n + 1, want_sum + desired[i], got_sum + port_col(it)
      end
    end
    if n > 0 then
      local shift = math.floor((want_sum - got_sum) / n + 0.5)
      if shift ~= 0 then
        for _, it in ipairs(items) do
          it.x = it.x + shift
        end
      end
    end
  end

  -- Aiming at a predecessor can push a layer left of the origin.
  local min_x = math.huge
  for l = 0, nlayers - 1 do
    for _, it in ipairs(layers[l]) do
      min_x = math.min(min_x, it.x)
    end
  end
  if min_x ~= 0 and min_x ~= math.huge then
    for l = 0, nlayers - 1 do
      for _, it in ipairs(layers[l]) do
        it.x = it.x - min_x
      end
    end
  end

  local channels = by_channel(segments, order, nlayers)
  local plans = {}
  for k = 0, nlayers - 2 do
    local plan = plan_channel(channels[k], rule_w, drawn)
    -- An unattributable edge label bails the whole diagram, and it bails here
    -- rather than in `M.parse`: the source is well formed, it is the layout that
    -- has nowhere to put the label. Nothing has been drawn yet.
    if not plan then
      return false
    end
    plans[k] = plan
  end

  -- Y: layer bands separated by their channels. A dummy is stretched to the
  -- band height so the line runs through the whole of it.
  local y, ch_y = 0, {}
  for k = 0, nlayers - 1 do
    local l = order[k]
    local band = 1
    for _, it in ipairs(layers[l]) do
      band = math.max(band, it.h)
    end
    for _, it in ipairs(layers[l]) do
      it.y = y
      if it.dummy then
        it.h = band
      end
    end
    y = y + band
    if k < nlayers - 1 then
      ch_y[k] = y
      y = y + plans[k].size
    end
  end

  for l = 0, nlayers - 1 do
    for _, it in ipairs(layers[l]) do
      if it.dummy then
        if it.edge.style ~= "invisible" then
          local group = EDGE_GROUP[it.edge.style] or EDGE_GROUP.solid
          for r = it.y, it.y + it.h - 1 do
            cv_bits(cv, r, it.x, { BIT_U, BIT_D }, group)
          end
        end
      else
        draw_box(cv, it)
      end
    end
  end

  local down = not flip
  for k = 0, nlayers - 2 do
    local plan = plans[k]
    local rows = {}
    for i = 0, plan.size - 1 do
      rows[i] = down and (ch_y[k] + i) or (ch_y[k] + plan.size - 1 - i)
    end
    for _, seg in ipairs(channels[k]) do
      if seg.edge.style ~= "invisible" then
        draw_segment(cv, seg, rows, plan, down)
      end
    end
  end
  return true
end

---------------------------------------------------------------------------
-- Horizontal layout (LR / RL)
---------------------------------------------------------------------------

--- Row an edge leaves or enters an item by.
local function port_row(it)
  if it.dummy then
    return it.y
  end
  return it.y + math.floor(it.h / 2)
end

--- Plan one vertical channel. Mirrors `plan_channel`, with rows and columns
--- swapping roles: jogs occupy columns, and an edge label is drawn ON its
--- horizontal run (`──label──>`) rather than beside it, because a run of `─`
--- has room for text where a run of `│` does not.
---
--- The two label bands are the same idea as the vertical planner's, transposed:
--- a pre-band label sits on the source row before the jog columns, a post-band
--- one on the target row after them. Returns `{ size, pre, jogs, post,
--- widest_pre, widest_post }` -- `pre` and `post` in COLUMNS, since a horizontal
--- band is as wide as the labels in it -- or nil to bail the diagram.
local function plan_channel_h(segs, rule_w, drawn)
  local jog_cols = {}
  local slots = { pre = {}, post = {} }
  local widest = { pre = 0, post = 0 }
  for _, seg in ipairs(segs) do
    seg.cy, seg.ty = port_row(seg.from), port_row(seg.to)
  end
  local from_n, to_n = share_counts(segs)
  for _, seg in ipairs(segs) do
    if seg.edge.style ~= "invisible" then
      if seg.cy ~= seg.ty then
        seg.jog = greedy_slot(
          jog_cols,
          { math.min(seg.cy, seg.ty), math.max(seg.cy, seg.ty) },
          { src = seg.cy, dst = seg.ty }
        )
      end
      if seg.edge.label and not drawn[seg.edge] then
        drawn[seg.edge] = true
        local band = label_band(seg, from_n, to_n)
        if not band then
          return nil
        end
        seg.label = seg.edge.label
        seg.label_band = band
        seg.label_cols = text_cols(seg.label, rule_w)
        widest[band] = math.max(widest[band], seg.label_cols)
        -- Labels share a slot only when they sit on different rows -- keyed on
        -- the row the label is actually drawn at, which is the target row in the
        -- post band. Branch labels of a fan-out therefore all take slot 0 and
        -- the band stays one label wide.
        seg.label_slot =
          greedy_slot(slots[band], band == "pre" and { seg.cy, seg.cy } or { seg.ty, seg.ty })
      end
    end
  end
  local nj = slot_count(jog_cols)
  local npre, npost = slot_count(slots.pre), slot_count(slots.post)
  local pre_w = npre > 0 and npre * (widest.pre + 1) or 0
  local post_w = npost > 0 and npost * (widest.post + 1) or 0
  -- At least three columns even when only the marker needs one: a bare
  -- `├>┤` between adjacent boxes reads as a typo rather than an arrow, and the
  -- spare columns simply lengthen the run the marker sits at the end of.
  return {
    size = math.max(3, pre_w + nj + post_w + 1),
    pre = pre_w,
    jogs = nj,
    post = post_w,
    widest_pre = widest.pre,
    widest_post = widest.post,
  }
end

local function draw_segment_h(cv, seg, cols, plan, right)
  local group = EDGE_GROUP[seg.edge.style] or EDGE_GROUP.solid
  local last = plan.size - 1
  local path = {}
  local function push(row, col)
    path[#path + 1] = { row = row, col = col }
  end

  push(seg.cy, right and (seg.from.x + seg.from.w - 1) or seg.from.x)
  local j = seg.jog and (plan.pre + seg.jog) or last
  for i = 0, j do
    push(seg.cy, cols[i])
  end
  if seg.jog then
    local step = seg.ty > seg.cy and 1 or -1
    local r = seg.cy + step
    while true do
      push(r, cols[j])
      if r == seg.ty then
        break
      end
      r = r + step
    end
    for i = j + 1, last do
      push(seg.ty, cols[i])
    end
  end
  push(seg.ty, right and seg.to.x or (seg.to.x + seg.to.w - 1))

  draw_path(cv, path, group)

  if seg.last then
    local char = MARKER_CHAR[right and "right" or "left"][seg.edge.marker]
    if char then
      cv_span(cv, seg.ty, cols[last], char, 1, group)
    end
  end
  if seg.label then
    -- Label first, then the separating column, in both bands: a post-anchored
    -- branch reads `┌yes─>┤ Left │`, the same shape as the pre-anchored
    -- `├ok─>┤ Done │`.
    local post = seg.label_band == "post"
    local base = post and (plan.pre + plan.jogs) or 0
    local width = post and plan.widest_post or plan.widest_pre
    cv_span(
      cv,
      post and seg.ty or seg.cy,
      cols[base + seg.label_slot * (width + 1)],
      seg.label,
      seg.label_cols,
      GROUP_EDGE_LABEL
    )
  end
end

local function layout_horizontal(layers, nlayers, segments, flip, cv, rule_w, drawn)
  local order = screen_order(nlayers, flip)

  -- Every box in a layer takes the layer's widest width. In a horizontal
  -- layout edges leave the right border and enter the left one, so uniform
  -- widths align BOTH ports at once -- otherwise every narrower box would need
  -- a jog. Labels are re-centred in the widened box.
  for l = 0, nlayers - 1 do
    local w = 1
    for _, it in ipairs(layers[l]) do
      w = math.max(w, it.w)
    end
    for _, it in ipairs(layers[l]) do
      it.w = w
      if not it.dummy then
        it.label_off = math.floor((w - it.label_cols) / 2)
      end
    end
  end

  -- Y placement: same priority rule as the vertical layout, aiming each item's
  -- port row at the mean port row of its predecessors.
  local preds = {}
  for _, seg in ipairs(segments) do
    local list = preds[seg.to]
    if not list then
      list = {}
      preds[seg.to] = list
    end
    list[#list + 1] = seg.from
  end

  for l = 0, nlayers - 1 do
    local items = layers[l]
    local desired = {}
    for i, it in ipairs(items) do
      local ps = preds[it]
      if ps and #ps > 0 then
        local sum = 0
        for _, p in ipairs(ps) do
          sum = sum + port_row(p)
        end
        desired[i] = sum / #ps
      end
    end
    local cursor = 0
    for i, it in ipairs(items) do
      local off = it.dummy and 0 or math.floor(it.h / 2)
      local want = desired[i] and math.floor(desired[i] - off + 0.5) or cursor
      it.y = math.max(cursor, want)
      cursor = it.y + it.h + VGAP
    end
    local n, want_sum, got_sum = 0, 0, 0
    for i, it in ipairs(items) do
      if desired[i] then
        n, want_sum, got_sum = n + 1, want_sum + desired[i], got_sum + port_row(it)
      end
    end
    if n > 0 then
      local shift = math.floor((want_sum - got_sum) / n + 0.5)
      if shift ~= 0 then
        for _, it in ipairs(items) do
          it.y = it.y + shift
        end
      end
    end
  end

  local min_y = math.huge
  for l = 0, nlayers - 1 do
    for _, it in ipairs(layers[l]) do
      min_y = math.min(min_y, it.y)
    end
  end
  if min_y ~= 0 and min_y ~= math.huge then
    for l = 0, nlayers - 1 do
      for _, it in ipairs(layers[l]) do
        it.y = it.y - min_y
      end
    end
  end

  local channels = by_channel(segments, order, nlayers)
  local plans = {}
  for k = 0, nlayers - 2 do
    local plan = plan_channel_h(channels[k], rule_w, drawn)
    -- Same bail as the vertical planner: a label with no attributable run
    -- takes the whole diagram back to the code block.
    if not plan then
      return false
    end
    plans[k] = plan
  end

  -- X: layer bands separated by their channels.
  local x, ch_x = 0, {}
  for k = 0, nlayers - 1 do
    local l = order[k]
    local band = 1
    for _, it in ipairs(layers[l]) do
      band = math.max(band, it.w)
    end
    for _, it in ipairs(layers[l]) do
      it.x = x
      if it.dummy then
        it.w = band
      end
    end
    x = x + band
    if k < nlayers - 1 then
      ch_x[k] = x
      x = x + plans[k].size
    end
  end

  for l = 0, nlayers - 1 do
    for _, it in ipairs(layers[l]) do
      if it.dummy then
        if it.edge.style ~= "invisible" then
          local group = EDGE_GROUP[it.edge.style] or EDGE_GROUP.solid
          for c = it.x, it.x + it.w - 1 do
            cv_bits(cv, it.y, c, { BIT_L, BIT_R }, group)
          end
        end
      else
        draw_box(cv, it)
      end
    end
  end

  local right = not flip
  for k = 0, nlayers - 2 do
    local plan = plans[k]
    local cols = {}
    for i = 0, plan.size - 1 do
      cols[i] = right and (ch_x[k] + i) or (ch_x[k] + plan.size - 1 - i)
    end
    for _, seg in ipairs(channels[k]) do
      if seg.edge.style ~= "invisible" then
        draw_segment_h(cv, seg, cols, plan, right)
      end
    end
  end
  return true
end

---------------------------------------------------------------------------
-- Draw entry point
---------------------------------------------------------------------------

--- Lay out and draw a parsed flowchart, or nil when the layout has to bail.
---
--- Diagrams join tables, code blocks and rules in the never-wrapped set: they
--- are sized by their content and scroll sideways, so no target width is
--- consulted and a window resize cannot change one.
---
--- Not every bail is a parse bail. An edge label whose source fans out AND whose
--- target fans in has no run in its channel that belongs to it alone, so there
--- is nowhere to draw it that a reader could attribute -- and that is only
--- knowable once the channel is planned. The source is well formed, so `M.parse`
--- succeeds and the refusal happens here, the same shape as an empty canvas.
---@param graph table from `M.parse`
---@param opts table|nil { prefix = "" } prepended to every line
---@return table|nil { lines = string[], decorations = table[] }
function M.draw(graph, opts)
  opts = opts or {}
  local prefix = opts.prefix or ""
  local rule_w = canvas.rule_width()

  local layer = assign_layers(graph)
  local layers, nlayers, segments = build_items(graph, layer)
  size_items(layers, nlayers, rule_w)

  local cv = canvas.new_canvas(rule_w)
  local vertical = graph.dir == "TB" or graph.dir == "BT"
  local flip = graph.dir == "BT" or graph.dir == "RL"
  -- Which edges have had their label placed, for this draw only. An edge spans
  -- several channels once it is split by dummies, and its label belongs on the
  -- first segment alone; keeping that state here rather than on the edge is what
  -- keeps `graph` identical to what `M.parse` returned, so drawing the same
  -- graph twice draws the same diagram.
  local drawn = {}
  local ok
  if vertical then
    ok = layout_vertical(layers, nlayers, segments, flip, cv, rule_w, drawn)
  else
    ok = layout_horizontal(layers, nlayers, segments, flip, cv, rule_w, drawn)
  end
  if not ok then
    return nil
  end

  local lines, decorations = {}, {}
  canvas.emit(cv, prefix, lines, decorations)
  return { lines = lines, decorations = decorations }
end

return M
