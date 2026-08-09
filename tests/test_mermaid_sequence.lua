-- Tests for lua/mdview/mermaid/sequence.lua: pure function, runs in this
-- process.
--
-- Structured like `test_mermaid.lua`: parsing first, then layout goldens, then
-- the properties the canvas exists to guarantee. Every bail asserts its reason
-- string rather than merely `nil` -- the reason is the contract the renderer's
-- fallback path reads.
local eq = MiniTest.expect.equality

local mermaid = require("mdview.mermaid")
local renderer = require("mdview.renderer")
local config = require("mdview.config")

local T = MiniTest.new_set()

--- Parse a fence body written as one string, `\n` separated.
local function parse(src, opts)
  return mermaid.parse(vim.split(src, "\n", { plain = true }), opts)
end

--- Parse and require success, reporting the bail reason if there is one.
local function graph(src, opts)
  local g, reason = parse(src, opts)
  if not g then
    error("expected a graph, got bail reason " .. vim.inspect(reason))
  end
  return g
end

--- Assert the parse bailed with exactly `reason`.
local function bails(src, reason, opts)
  local g, r = parse(src, opts)
  eq({ src, g == nil, r }, { src, true, reason })
end

--- Participant ids in column order, as one string.
local function ids(g)
  local out = {}
  for _, p in ipairs(g.participants) do
    out[#out + 1] = p.id
  end
  return table.concat(out, " ")
end

--- Every participant as `id=line/line`, in column order.
local function labels(g)
  local out = {}
  for _, p in ipairs(g.participants) do
    out[#out + 1] = p.id .. "=" .. table.concat(p.label, "/")
  end
  return out
end

--- Every message as `from>to marker style label`, in time order.
local function msgs(g)
  local out = {}
  for _, m in ipairs(g.messages) do
    out[#out + 1] = table.concat({
      g.participants[m.from].id .. ">" .. g.participants[m.to].id,
      m.marker,
      m.style,
      m.label or "-",
    }, " ")
  end
  return out
end

---------------------------------------------------------------------------

T["header"] = MiniTest.new_set()

T["header"]["sequenceDiagram is a diagram type of its own"] = function()
  local g = graph("sequenceDiagram\nA->>B: hi")
  eq(g.kind, "sequencediagram")
end

T["header"]["is matched case-insensitively"] = function()
  eq(graph("SEQUENCEDIAGRAM\nA->>B: hi").kind, "sequencediagram")
  eq(graph("sequencediagram\nA->>B: hi").kind, "sequencediagram")
  eq(graph("SequenceDiagram\nA->>B: hi").kind, "sequencediagram")
end

T["header"]["anything after the keyword is unparsed"] = function()
  -- `init.lua` dispatches on the first alphabetic run in the body, which is
  -- deliberately loose; the header is re-validated here, so a trailing word is
  -- this module's bail rather than a silently ignored direction.
  bails("sequenceDiagram TB\nA->>B: hi", "unparsed")
  bails("sequenceDiagram2\nA->>B: hi", "unparsed")
end

T["header"]["a body whose first statement is not the header is unparsed"] = function()
  bails("42\nsequenceDiagram\nA->>B: hi", "unparsed")
end

T["header"]["a header alone is an empty diagram, not a bail"] = function()
  -- The same shape `flowchart TD` on its own has: a legal, empty document.
  local g = graph("sequenceDiagram")
  eq({ #g.participants, #g.messages }, { 0, 0 })
end

---------------------------------------------------------------------------

T["participants"] = MiniTest.new_set()

T["participants"]["a bare declaration labels itself"] = function()
  local g = graph("sequenceDiagram\nparticipant A")
  eq(labels(g), { "A=A" })
  eq(g.index, { A = 1 })
end

T["participants"]["an alias is free text to the end of the line"] = function()
  eq(labels(graph("sequenceDiagram\nparticipant A as Alice Smith")), { "A=Alice Smith" })
end

T["participants"]["a quoted alias loses one layer of quotes"] = function()
  eq(labels(graph('sequenceDiagram\nparticipant A as "Alice"')), { "A=Alice" })
end

T["participants"]["<br/> splits an alias into box lines"] = function()
  eq(labels(graph("sequenceDiagram\nparticipant A as Web<br/>client")), { "A=Web/client" })
  eq(labels(graph("sequenceDiagram\nparticipant A as a<BR>b<br />c")), { "A=a/b/c" })
end

T["participants"]["an id first seen in a message is registered implicitly"] = function()
  local g = graph("sequenceDiagram\nAlice->>Bob: hi")
  eq(labels(g), { "Alice=Alice", "Bob=Bob" })
end

T["participants"]["columns follow first appearance, declared or not"] = function()
  local g = graph("sequenceDiagram\nparticipant C\nA->>B: hi\nB->>C: on")
  eq(ids(g), "C A B")
end

T["participants"]["a declaration after first mention keeps the earlier column"] = function()
  -- Mermaid does not reorder a participant that has already spoken, and neither
  -- does this: order is first appearance, full stop.
  local g = graph("sequenceDiagram\nA->>B: hi\nparticipant B as Bob")
  eq(ids(g), "A B")
  eq(labels(g), { "A=A", "B=Bob" })
end

T["participants"]["a repeated declaration is last-write-wins"] = function()
  local g = graph("sequenceDiagram\nparticipant A as One\nparticipant A as Two\nA->>B: x")
  eq(ids(g), "A B")
  eq(labels(g), { "A=Two", "B=B" })
end

T["participants"]["a later bare mention does not erase a label"] = function()
  local g = graph("sequenceDiagram\nparticipant A as Alice\nA->>B: x\nA->>B: y")
  eq(labels(g), { "A=Alice", "B=B" })
end

T["participants"]["underscores and digits are fine ids"] = function()
  eq(ids(graph("sequenceDiagram\nnode_1->>N2: x")), "node_1 N2")
end

---------------------------------------------------------------------------

T["messages"] = MiniTest.new_set()

T["messages"]["every arrow form carries a style and a marker"] = function()
  -- One dash is solid, two are dashed; the terminator picks the marker. Dashed
  -- is a highlight group, not a second line weight.
  local cases = {
    { "A->B: x", "none solid" },
    { "A-->B: x", "none dotted" },
    { "A->>B: x", "arrow solid" },
    { "A-->>B: x", "arrow dotted" },
    { "A-xB: x", "cross solid" },
    { "A--xB: x", "cross dotted" },
    { "A-)B: x", "async solid" },
    { "A--)B: x", "async dotted" },
  }
  for _, case in ipairs(cases) do
    local g = graph("sequenceDiagram\n" .. case[1])
    eq({ case[1], msgs(g) }, { case[1], { "A>B " .. case[2] .. " x" } })
  end
end

T["messages"]["whitespace around the arrow is optional"] = function()
  eq(msgs(graph("sequenceDiagram\nA ->> B : hi")), { "A>B arrow solid hi" })
  eq(msgs(graph("sequenceDiagram\nA->>B:hi")), { "A>B arrow solid hi" })
end

T["messages"]["the text part is optional"] = function()
  eq(msgs(graph("sequenceDiagram\nA->>B")), { "A>B arrow solid -" })
  eq(msgs(graph("sequenceDiagram\nA->>B:")), { "A>B arrow solid -" })
  eq(msgs(graph("sequenceDiagram\nA->>B:   ")), { "A>B arrow solid -" })
end

T["messages"]["text runs to the end of the line"] = function()
  -- `;` is NOT a statement separator here: message text is free text and
  -- routinely contains one, and mermaid terminates on the newline.
  eq(msgs(graph("sequenceDiagram\nA->>B: hi; and more: colons")), {
    "A>B arrow solid hi; and more: colons",
  })
end

T["messages"]["quoted text loses its quotes"] = function()
  eq(msgs(graph('sequenceDiagram\nA->>B: "yes, really"')), { "A>B arrow solid yes, really" })
end

T["messages"]["an id may begin with a marker letter"] = function()
  -- `-x` is the cross arrow, so the arrow has to be matched longest-first or
  -- `A->>xray` would be read as `->>x` and bail.
  eq(msgs(graph("sequenceDiagram\nA->>xray: hi")), { "A>xray arrow solid hi" })
end

T["messages"]["`%%` is a comment only at the start of a line"] = function()
  local g = graph("sequenceDiagram\n%% A->>ZZZ: dropped\nA->>B: 100%% sure")
  eq(ids(g), "A B")
  eq(msgs(g), { "A>B arrow solid 100%% sure" })
end

T["messages"]["YAML frontmatter is skipped"] = function()
  local g = graph("---\ntitle: A chat\n---\nsequenceDiagram\nA->>B: hi")
  eq(msgs(g), { "A>B arrow solid hi" })
end

T["messages"]["an init directive is skipped"] = function()
  local g = graph('%%{init: {"theme": "dark"}}%%\nsequenceDiagram\nA->>B: hi')
  eq(msgs(g), { "A>B arrow solid hi" })
end

T["messages"]["blank lines are ignored"] = function()
  eq(#graph("sequenceDiagram\n\n\nA->>B: hi\n\n").messages, 1)
end

---------------------------------------------------------------------------

T["bails"] = MiniTest.new_set()

T["bails"]["frame blocks"] = function()
  -- Frames nest AND span lifelines, so they are this diagram's `subgraph`:
  -- deferred, not forgotten.
  for _, word in ipairs({
    "alt yes",
    "else no",
    "opt maybe",
    "loop every day",
    "par one",
    "and two",
    "critical make a call",
    "option fallback",
    "break oops",
    "rect rgb(0,0,0)",
    "end",
  }) do
    bails("sequenceDiagram\nA->>B: x\n" .. word, "unsupported_block")
  end
end

T["bails"]["notes"] = function()
  bails("sequenceDiagram\nNote left of A: hi", "unsupported_note")
  bails("sequenceDiagram\nNote right of A: hi", "unsupported_note")
  bails("sequenceDiagram\nNote over A,B: hi", "unsupported_note")
  bails("sequenceDiagram\nnote over A: hi", "unsupported_note")
end

T["bails"]["activations, as statements and as arrow suffixes"] = function()
  bails("sequenceDiagram\nactivate A", "unsupported_activation")
  bails("sequenceDiagram\ndeactivate A", "unsupported_activation")
  bails("sequenceDiagram\nA->>+B: x", "unsupported_activation")
  bails("sequenceDiagram\nA->>-B: x", "unsupported_activation")
  bails("sequenceDiagram\nA-->>+B: x", "unsupported_activation")
end

T["bails"]["a self message"] = function()
  bails("sequenceDiagram\nA->>A: thinking", "self_message")
  bails("sequenceDiagram\nA ->> A", "self_message")
end

T["bails"]["bidirectional arrows"] = function()
  bails("sequenceDiagram\nA<<->>B: x", "unsupported_message")
  bails("sequenceDiagram\nA<<-->>B: x", "unsupported_message")
end

T["bails"]["<br/> in message text"] = function()
  -- The text is drawn on the single row of its arrow, so keeping it literal
  -- would print `<br/>` inside the diagram.
  bails("sequenceDiagram\nA->>B: one<br/>two", "unsupported_message")
  bails("sequenceDiagram\nA->>B: one<BR>two", "unsupported_message")
end

T["bails"]["statements outside the subset"] = function()
  bails("sequenceDiagram\nautonumber", "unsupported_statement")
  bails("sequenceDiagram\nbox Grey Group\nA->>B: x", "unsupported_statement")
  bails("sequenceDiagram\ncreate participant C", "unsupported_statement")
  bails("sequenceDiagram\ndestroy C", "unsupported_statement")
  bails('sequenceDiagram\nlinks A: {"Dashboard": "https://x"}', "unsupported_statement")
  bails("sequenceDiagram\nlink A: Dashboard @ https://x", "unsupported_statement")
end

T["bails"]["actor, because the stick figure is the whole difference"] = function()
  bails("sequenceDiagram\nactor A", "unsupported_statement")
end

T["bails"]["an id outside [A-Za-z0-9_]"] = function()
  bails("sequenceDiagram\na.b->>B: x", "bad_id")
  bails("sequenceDiagram\nA->>b.c: x", "bad_id")
  bails("sequenceDiagram\nparticipant a.b", "bad_id")
  bails("sequenceDiagram\nparticipant #hash", "bad_id")
end

T["bails"]["a line the parser does not recognise"] = function()
  bails("sequenceDiagram\nthis is not a message", "unparsed")
  bails("sequenceDiagram\nA", "unparsed")
  bails("sequenceDiagram\nA->>", "unparsed")
  bails("sequenceDiagram\nA-->>>B: x", "unparsed")
  bails("sequenceDiagram\nparticipant", "unparsed")
  bails("sequenceDiagram\nparticipant A Alice", "unparsed")
  bails("sequenceDiagram\nparticipant A as", "unparsed")
end

T["bails"]["unclosed frontmatter is unparsed"] = function()
  bails("---\ntitle: t\nsequenceDiagram\nA->>B: x", "unparsed")
end

T["bails"]["more participants than max_nodes"] = function()
  -- Participants count against `max_nodes` and messages against `max_edges`:
  -- the two existing guards do the same job, so stage 2 adds no config keys.
  bails("sequenceDiagram\nA->>B: x\nB->>C: y", "too_big", { max_nodes = 2 })
  eq(#graph("sequenceDiagram\nA->>B: x\nB->>C: y", { max_nodes = 3 }).participants, 3)
end

T["bails"]["more messages than max_edges"] = function()
  bails("sequenceDiagram\nA->>B: x\nB->>A: y", "too_big", { max_edges = 1 })
  eq(#graph("sequenceDiagram\nA->>B: x\nB->>A: y", { max_edges = 2 }).messages, 2)
end

T["bails"]["the limits default without opts"] = function()
  local lines = { "sequenceDiagram" }
  for i = 1, 61 do
    lines[#lines + 1] = ("N%d->>N%d: x"):format(i, i + 1)
  end
  eq({ mermaid.parse(lines) == nil, select(2, mermaid.parse(lines)) }, { true, "too_big" })
end

---------------------------------------------------------------------------
-- Layout and drawing
---------------------------------------------------------------------------

--- 'ambiwidth' is process-global and several cases below flip it, so it is
--- restored after each one rather than at the end of the set.
local ambiwidth_saved
T["layout"] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      ambiwidth_saved = vim.o.ambiwidth
      vim.o.ambiwidth = "single"
    end,
    post_case = function()
      vim.o.ambiwidth = ambiwidth_saved
    end,
  },
})

local function draw(src, opts)
  local r = mermaid.render(vim.split(src, "\n", { plain = true }), opts)
  if not r then
    error("expected a diagram, got a bail")
  end
  return r
end

--- Rendered rows with their padding removed. Goldens are written trimmed so
--- they survive an editor that strips trailing whitespace; the padding itself
--- is what the equal-width case below asserts.
local function rows(src, opts)
  local out = {}
  for _, line in ipairs(draw(src, opts).lines) do
    out[#out + 1] = (line:gsub("%s+$", ""))
  end
  return out
end

local PAIR = "sequenceDiagram\nparticipant A as Alice\nparticipant B as Bob\nA->>B: hello"
local TRIO = "sequenceDiagram\nAlice->>Bob: ask\nBob->>Carol: check\nCarol-->>Alice: done"
local BACK = "sequenceDiagram\nA->>B: ping\nB-->>A: pong"
local SKIP = "sequenceDiagram\nparticipant A\nparticipant B\nparticipant C\nA->>C: over B\nB->>C: near"
local OVER = "sequenceDiagram\nparticipant A\nparticipant B\nparticipant C\nA->>C: right past B\nB->>C: near"
local WIDE = "sequenceDiagram\nA->>B: a much longer message than either box"
local ALIAS =
  "sequenceDiagram\nparticipant A as Web<br/>client\nparticipant B as API\nA->>B: GET /x"
local ARROWS = table.concat({
  "sequenceDiagram",
  "A->B: open",
  "A-->B: dash",
  "A->>B: solid",
  "A-->>B: dashed",
  "A-xB: lost",
  "A--xB: dlost",
  "A-)B: async",
  "A--)B: dasync",
}, "\n")
-- Made entirely of East Asian *Ambiguous* characters, which are one cell under
-- `ambiwidth = "single"` and two under "double" -- so this fixture, unlike an
-- ASCII or a kana one, really does move with the option.
local AMBIG = "sequenceDiagram\nparticipant A as ±°\nparticipant B as αβ\nA->>B: ─│─"

local GOLDENS = { PAIR, TRIO, BACK, SKIP, OVER, WIDE, ALIAS, ARROWS, AMBIG }

T["layout"]["two participants and one message"] = function()
  -- The `┬` under each box is the bitmask's doing: the bottom border cell gains
  -- one BIT_D and picks its own glyph. Likewise `├` and `┤` where the message
  -- meets a lifeline.
  eq(rows(PAIR), {
    "┌───────┐  ┌─────┐",
    "│ Alice │  │ Bob │",
    "└───┬───┘  └──┬──┘",
    "    │         │",
    "    ├hello───>┤",
    "    │         │",
  })
end

T["layout"]["a three-participant conversation"] = function()
  eq(rows(TRIO), {
    "┌───────┐  ┌─────┐  ┌───────┐",
    "│ Alice │  │ Bob │  │ Carol │",
    "└───┬───┘  └──┬──┘  └───┬───┘",
    "    │         │         │",
    "    ├ask─────>┤         │",
    "    │         │         │",
    "    │         ├check───>┤",
    "    │         │         │",
    "    ├<────────┼─────done┤",
    "    │         │         │",
  })
end

T["layout"]["a right-to-left message points back"] = function()
  -- The marker sits in the run cell next to the TARGET either way, and the text
  -- sits against the SOURCE, so direction reads off the row without colour.
  eq(rows(BACK), {
    "┌───┐  ┌───┐",
    "│ A │  │ B │",
    "└─┬─┘  └─┬─┘",
    "  │      │",
    "  ├ping─>┤",
    "  │      │",
    "  ├<─pong┤",
    "  │      │",
  })
end

T["layout"]["a message over a non-adjacent pair crosses the lifeline between"] = function()
  eq(rows(SKIP), {
    "┌───┐  ┌───┐  ┌───┐",
    "│ A │  │ B │  │ C │",
    "└─┬─┘  └─┬─┘  └─┬─┘",
    "  │      │      │",
    "  ├over B┼─────>┤",
    "  │      │      │",
    "  │      ├near─>┤",
    "  │      │      │",
  })
end

T["layout"]["message text may cover a lifeline it passes"] = function()
  -- The X sweep sizes the run for the text and the marker, not for the
  -- lifelines in between, so a long enough label hides one for its own row.
  -- Deliberate, and the same call `flowchart.lua` makes for an edge label that
  -- collides with a line: text over a line is cosmetic, where displacing it
  -- would cost a whole column of layout or the label itself.
  eq(rows(OVER), {
    "┌───┐  ┌───┐  ┌───┐",
    "│ A │  │ B │  │ C │",
    "└─┬─┘  └─┬─┘  └─┬─┘",
    "  │      │      │",
    "  ├right past B>┤",
    "  │      │      │",
    "  │      ├near─>┤",
    "  │      │      │",
  })
end

T["layout"]["a label wider than its boxes widens the gap"] = function()
  eq(rows(WIDE), {
    "┌───┐                                  ┌───┐",
    "│ A │                                  │ B │",
    "└─┬─┘                                  └─┬─┘",
    "  │                                      │",
    "  ├a much longer message than either box>┤",
    "  │                                      │",
  })
end

T["layout"]["a <br/> alias makes a taller box, and every box matches it"] = function()
  -- All boxes take the tallest one's height so that every lifeline starts on
  -- the same row; the spare interior rows are blank label lines.
  eq(rows(ALIAS), {
    "┌────────┐  ┌─────┐",
    "│ Web    │  │ API │",
    "│ client │  │     │",
    "└────┬───┘  └──┬──┘",
    "     │         │",
    "     ├GET /x──>┤",
    "     │         │",
  })
end

T["layout"]["every arrow form on one diagram"] = function()
  -- `->` and `-->` draw no marker at all; `-->` differs from `->` only in
  -- highlight group, which is why rows 5 and 7 are identical text.
  eq(rows(ARROWS), {
    "┌───┐   ┌───┐",
    "│ A │   │ B │",
    "└─┬─┘   └─┬─┘",
    "  │       │",
    "  ├open───┤",
    "  │       │",
    "  ├dash───┤",
    "  │       │",
    "  ├solid─>┤",
    "  │       │",
    "  ├dashed>┤",
    "  │       │",
    "  ├lost──x┤",
    "  │       │",
    "  ├dlost─x┤",
    "  │       │",
    "  ├async─)┤",
    "  │       │",
    "  ├dasync)┤",
    "  │       │",
  })
end

T["layout"]["one participant and no messages still gets a lifeline"] = function()
  eq(rows("sequenceDiagram\nparticipant Solo as Just one"), {
    "┌──────────┐",
    "│ Just one │",
    "└─────┬────┘",
    "      │",
  })
end

T["layout"]["a prefix shifts every line and every byte column"] = function()
  local plain = draw(TRIO)
  local shifted = draw(TRIO, { prefix = "  " })
  for i, line in ipairs(plain.lines) do
    eq(shifted.lines[i], "  " .. line)
  end
  for i, d in ipairs(plain.decorations) do
    eq(
      { shifted.decorations[i].col_start, shifted.decorations[i].col_end },
      { d.col_start + 2, d.col_end + 2 }
    )
  end
end

---------------------------------------------------------------------------
-- The same goldens under `ambiwidth = "double"`
---------------------------------------------------------------------------

T["ambiwidth"] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      ambiwidth_saved = vim.o.ambiwidth
      vim.o.ambiwidth = "double"
    end,
    post_case = function()
      vim.o.ambiwidth = ambiwidth_saved
    end,
  },
})

T["ambiwidth"]["double redraws the same diagram twice as wide"] = function()
  -- Box drawing is Ambiguous, so every canvas column is two cells here. The
  -- ASCII label `hello` is five cells either way and so shrinks from five
  -- columns to three, taking one padding space with it -- which is exactly the
  -- drift a layout padded by character count would get wrong.
  eq(rows(PAIR), {
    "┌─────┐    ┌────┐",
    "│  Alice   │    │  Bob   │",
    "└──┬──┘    └──┬─┘",
    "      │                │",
    "      ├hello ────> ┤",
    "      │                │",
  })
end

T["ambiwidth"]["an ambiguous-width label keeps its column count"] = function()
  -- The label doubles with the column, so the COLUMN layout is identical to the
  -- single-width one and only the spacing between boxes grows. Compare with the
  -- case above, where the ASCII label did not double and the layout moved.
  eq(rows(AMBIG), {
    "┌────┐    ┌────┐",
    "│  ±°  │    │  αβ  │",
    "└──┬─┘    └──┬─┘",
    "      │              │",
    "      ├─│────> ┤",
    "      │              │",
  })
  vim.o.ambiwidth = "single"
  eq(rows(AMBIG), {
    "┌────┐  ┌────┐",
    "│ ±° │  │ αβ │",
    "└──┬─┘  └──┬─┘",
    "   │       │",
    "   ├─│────>┤",
    "   │       │",
  })
end

---------------------------------------------------------------------------
-- The properties the canvas exists to guarantee
---------------------------------------------------------------------------

T["invariants"] = MiniTest.new_set({
  parametrize = { { "single" }, { "double" } },
  hooks = {
    pre_case = function()
      ambiwidth_saved = vim.o.ambiwidth
    end,
    post_case = function()
      vim.o.ambiwidth = ambiwidth_saved
    end,
  },
})

T["invariants"]["every row of a diagram is the same width"] = function(ambi)
  vim.o.ambiwidth = ambi
  -- Measured with `strwidth`: `strdisplaywidth` is not additive over a long run
  -- of `─` and reports misalignment that is not there.
  for _, src in ipairs(GOLDENS) do
    local widths = {}
    for _, line in ipairs(draw(src).lines) do
      widths[vim.fn.strwidth(line)] = true
    end
    eq({ ambi, src, vim.tbl_count(widths) }, { ambi, src, 1 })
  end
end

T["invariants"]["only verified-safe glyphs are drawn"] = function(ambi)
  vim.o.ambiwidth = ambi
  -- The sequence path adds `x ) (` to the markers, all ASCII, so the eleven
  -- box-drawing characters already in the renderer's safe set are still the
  -- whole of what it emits. The fixtures' own `± ° α β` are label TEXT, which
  -- passes through untouched, so they are excluded by name rather than by
  -- widening the set.
  local SAFE = {
    ["─"] = true,
    ["│"] = true,
    ["┌"] = true,
    ["┬"] = true,
    ["┐"] = true,
    ["├"] = true,
    ["┼"] = true,
    ["┤"] = true,
    ["└"] = true,
    ["┴"] = true,
    ["┘"] = true,
  }
  local FROM_SOURCE = { ["±"] = true, ["°"] = true, ["α"] = true, ["β"] = true }
  local found = {}
  for _, src in ipairs(GOLDENS) do
    for _, line in ipairs(draw(src).lines) do
      for _, char in ipairs(vim.fn.split(line, "\\zs")) do
        if #char > 1 and not SAFE[char] and not FROM_SOURCE[char] then
          found[#found + 1] = char
        end
      end
    end
  end
  eq({ ambi, found }, { ambi, {} })
end

T["invariants"]["decorations stay inside their line and name known groups"] = function(ambi)
  vim.o.ambiwidth = ambi
  -- Stage 2 adds NO highlight group: lifelines and boxes are structure, so they
  -- take the box group, and a message takes the edge groups an edge does.
  local GROUPS = {
    MdviewMermaidBox = true,
    MdviewMermaidLabel = true,
    MdviewMermaidEdge = true,
    MdviewMermaidEdgeDim = true,
    MdviewMermaidEdgeLabel = true,
  }
  local bad = {}
  for _, src in ipairs(GOLDENS) do
    local res = draw(src)
    for _, d in ipairs(res.decorations) do
      local line = res.lines[d.line + 1]
      if
        d.kind ~= "hl"
        or not line
        or not GROUPS[d.group]
        or d.col_start >= d.col_end
        or d.col_end > #line
      then
        bad[#bad + 1] = { src, d }
      end
    end
  end
  eq({ ambi, bad }, { ambi, {} })
end

T["layout"]["a lifeline junction is coloured as structure, not as an edge"] = function()
  -- First-writer-wins on a cell, and lifelines are drawn before messages, so
  -- the `├` / `┤` / `┼` where a message meets one stay border-coloured -- the
  -- same thing flowchart does where an edge meets a box.
  local res = draw(PAIR)
  local row = res.lines[5] -- "    ├hello───>┤"
  local at = {}
  for _, d in ipairs(res.decorations) do
    if d.line == 4 then
      at[#at + 1] = { row:sub(d.col_start + 1, d.col_end), d.group }
    end
  end
  eq(at, {
    { "├", "MdviewMermaidBox" },
    { "hello", "MdviewMermaidEdgeLabel" },
    { "───>", "MdviewMermaidEdge" },
    { "┤", "MdviewMermaidBox" },
  })
end

T["layout"]["a dashed message is coloured, not redrawn"] = function()
  -- The glyph set has one line weight, so `-->>` differs from `->>` by
  -- highlight group alone. The drawn characters must be identical.
  eq(rows("sequenceDiagram\nA-->>B: x"), rows("sequenceDiagram\nA->>B: x"))
  local function groups(src)
    local seen = {}
    for _, d in ipairs(draw(src).decorations) do
      seen[d.group] = true
    end
    return seen
  end
  eq(groups("sequenceDiagram\nA-->>B: x")["MdviewMermaidEdgeDim"], true)
  eq(groups("sequenceDiagram\nA->>B: x")["MdviewMermaidEdge"], true)
  eq(groups("sequenceDiagram\nA-->>B: x")["MdviewMermaidEdge"], nil)
end

---------------------------------------------------------------------------
-- Fallback
---------------------------------------------------------------------------

T["fallback"] = MiniTest.new_set()

T["fallback"]["render returns nil for anything the parser bails on"] = function()
  for _, src in ipairs({
    "sequenceDiagram\nalt yes\nA->>B: x\nend",
    "sequenceDiagram\nNote over A: hi",
    "sequenceDiagram\nactivate A",
    "sequenceDiagram\nA->>A: x",
    "sequenceDiagram\nA<<->>B: x",
    "sequenceDiagram\nA->>B: one<br/>two",
    "sequenceDiagram\nactor A",
    "sequenceDiagram\na.b->>B: x",
    "sequenceDiagram TB\nA->>B: x",
  }) do
    eq({ src, mermaid.render(vim.split(src, "\n", { plain = true })) }, { src, nil })
  end
end

T["fallback"]["the block marker style has no box drawing to fall back on"] = function()
  local src = vim.split(PAIR, "\n", { plain = true })
  eq(mermaid.render(src, { marker_style = "block" }), nil)
  eq(mermaid.render(src, { marker_style = "glyph" }) ~= nil, true)
end

T["fallback"]["an unsupported fence renders byte-for-byte like another language"] = function()
  -- The fallback must be indistinguishable from the behaviour before sequence
  -- diagrams existed: same lines, same decorations, just a different tag.
  local body = { "sequenceDiagram", "loop every minute", "A->>B: poll", "end" }
  local cfg, opts = config.get(), { width = 60 }
  local drawn = renderer.render({ { type = "code_block", lang = "mermaid", lines = body } }, cfg, opts)
  local plain = renderer.render({ { type = "code_block", lang = "text", lines = body } }, cfg, opts)
  eq(#drawn.lines, #plain.lines)
  for i = 2, #plain.lines do
    eq(drawn.lines[i], plain.lines[i])
  end
  eq(#drawn.decorations, #plain.decorations)
end

T["fallback"]["a supported fence really does reach the renderer"] = function()
  local body = vim.split(PAIR, "\n", { plain = true })
  local res =
    renderer.render({ { type = "code_block", lang = "mermaid", lines = body } }, config.get(), { width = 60 })
  eq(res.lines[1], "  mermaid")
  eq(res.lines[2], "  ┌───────┐  ┌─────┐")
  eq(res.lines[3], "  │ Alice │  │ Bob │")
end

return T
