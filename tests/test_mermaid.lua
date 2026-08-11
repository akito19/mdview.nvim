-- Tests for lua/mdview/mermaid.lua: pure function, runs in this process.
--
-- Stage 1 covers `M.parse` only -- fence body lines in, graph IR or a bail
-- reason out. Every bail asserts the reason string, not merely that the result
-- was nil: the reason is the contract the renderer's fallback path reads.
local eq = MiniTest.expect.equality

local mermaid = require("mdview.mermaid")

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
  eq({ g == nil, r }, { true, reason })
end

--- One statement whose `&` groups make an `a` x `b` cross product, all ids
--- distinct. Used by the resource-bound cases below.
local function cross_product(a, b)
  local left, right = {}, {}
  for i = 1, a do
    left[i] = ("A%d"):format(i)
  end
  for i = 1, b do
    right[i] = ("B%d"):format(i)
  end
  return table.concat(left, " & ") .. " --> " .. table.concat(right, " & ")
end

--- Assert the parse bails with `reason` *and* does not take a pathological
--- amount of time getting there. The bound is loose on purpose: it is here to
--- catch a quadratic coming back, not to measure anything, so the inputs below
--- are sized to be two or three orders of magnitude outside it.
local BAIL_BUDGET_MS = 500

local function bails_fast(src, reason, opts)
  local t0 = vim.uv.hrtime()
  bails(src, reason, opts)
  local ms = (vim.uv.hrtime() - t0) / 1e6
  if ms > BAIL_BUDGET_MS then
    error(("bailed with %q as expected, but took %.0f ms"):format(reason, ms))
  end
end

--- Node ids in order, as one string.
local function ids(g)
  local out = {}
  for _, n in ipairs(g.nodes) do
    out[#out + 1] = n.id
  end
  return table.concat(out, " ")
end

--- Every label as `id=line/line`, in node order.
local function labels(g)
  local out = {}
  for _, n in ipairs(g.nodes) do
    out[#out + 1] = n.id .. "=" .. table.concat(n.label, "/")
  end
  return out
end

--- Every edge as `from>to marker style label`, in edge order.
local function edges(g)
  local out = {}
  for _, e in ipairs(g.edges) do
    out[#out + 1] = table.concat({
      g.nodes[e.from].id .. ">" .. g.nodes[e.to].id,
      e.marker,
      e.style,
      e.label or "-",
    }, " ")
  end
  return out
end

---------------------------------------------------------------------------

T["header"] = MiniTest.new_set()

T["header"]["accepts every direction"] = function()
  for _, dir in ipairs({ "TB", "BT", "LR", "RL" }) do
    eq(graph("flowchart " .. dir .. "\nA --> B").dir, dir)
  end
end

T["header"]["normalises TD to TB"] = function()
  eq(graph("flowchart TD\nA --> B").dir, "TB")
  eq(graph("graph TD\nA --> B").dir, "TB")
end

T["header"]["treats graph and flowchart as interchangeable"] = function()
  eq(graph("graph LR\nA --> B").dir, "LR")
end

T["header"]["defaults to TB when the direction is omitted"] = function()
  eq(graph("flowchart\nA --> B").dir, "TB")
  eq(graph("graph\nA --> B").dir, "TB")
end

T["header"]["matches keyword and direction case-insensitively"] = function()
  eq(graph("FlowChart td\nA --> B").dir, "TB")
  eq(graph("GRAPH lr\nA --> B").dir, "LR")
end

T["header"]["may share a line with statements via `;`"] = function()
  local g = graph("flowchart TD;A-->B;B-->C")
  eq(g.dir, "TB")
  eq(ids(g), "A B C")
  eq(edges(g), { "A>B arrow solid -", "B>C arrow solid -" })
end

T["header"]["another diagram type is not_flowchart"] = function()
  -- Deliberately a type the package does not know at all: `sequenceDiagram` is
  -- dispatched to its own module now and no longer reaches this bail.
  bails("gantt\ntitle A schedule", "not_flowchart")
  bails("stateDiagram-v2\n[*] --> Still", "not_flowchart")
end

T["header"]["an empty body is not_flowchart"] = function()
  bails("", "not_flowchart")
  bails("\n\n", "not_flowchart")
end

T["header"]["an unknown direction is not_flowchart"] = function()
  bails("flowchart XY\nA --> B", "not_flowchart")
end

---------------------------------------------------------------------------

T["nodes"] = MiniTest.new_set()

T["nodes"]["a bare id labels itself"] = function()
  local g = graph("flowchart TB\nA --> B")
  eq(labels(g), { "A=A", "B=B" })
  eq(g.index, { A = 1, B = 2 })
end

T["nodes"]["a lone node with no edges is still a node"] = function()
  local g = graph("flowchart TB\nA")
  eq(labels(g), { "A=A" })
  eq(#g.edges, 0)
end

T["nodes"]["every bracket shape parses to the same rectangle"] = function()
  -- v1 draws every shape as a rectangle, so only the label has to survive; the
  -- delimiters still have to be consumed correctly to get there.
  local forms = {
    "A[text]",
    "A(text)",
    "A((text))",
    "A(((text)))",
    "A{text}",
    "A{{text}}",
    "A([text])",
    "A[[text]]",
    "A[(text)]",
    "A>text]",
    "A[/text/]",
    "A[\\text\\]",
    "A[/text\\]",
    "A[\\text/]",
  }
  for _, form in ipairs(forms) do
    local g = graph("flowchart TB\n" .. form .. " --> B")
    eq({ form, labels(g) }, { form, { "A=text", "B=B" } })
  end
end

T["nodes"]["a quoted label keeps its delimiters out of the text"] = function()
  local g = graph('flowchart TB\nA["a ] bracket"] --> B')
  eq(labels(g), { "A=a ] bracket", "B=B" })
end

T["nodes"]["a label is trimmed"] = function()
  eq(labels(graph("flowchart TB\nA[  spaced  ]")), { "A=spaced" })
end

T["nodes"]["<br/> splits a label into lines"] = function()
  eq(labels(graph("flowchart TB\nA[first<br/>second]")), { "A=first/second" })
  eq(labels(graph("flowchart TB\nA[first<br>second]")), { "A=first/second" })
  eq(labels(graph("flowchart TB\nA[first<br />second]")), { "A=first/second" })
  eq(labels(graph("flowchart TB\nA[a<BR/>b<br/>c]")), { "A=a/b/c" })
end

T["nodes"]["a ::: class suffix is stripped, not treated as a statement"] = function()
  local g = graph("flowchart TB\nA:::someClass --> B")
  eq(labels(g), { "A=A", "B=B" })
  eq(edges(g), { "A>B arrow solid -" })
end

T["nodes"]["a ::: class suffix follows a shape too"] = function()
  local g = graph("flowchart TB\nA[text]:::my-class --> B:::other")
  eq(labels(g), { "A=text", "B=B" })
  eq(edges(g), { "A>B arrow solid -" })
end

T["nodes"]["numeric entity codes stay literal"] = function()
  -- Decoding `#9829;` would make the renderer synthesise a glyph outside the
  -- safe set from pure-ASCII source. The `;` must also not split the statement.
  local g = graph('flowchart TB\nA["#35; and #9829;"] --> B')
  eq(labels(g), { "A=#35; and #9829;", "B=B" })
  eq(edges(g), { "A>B arrow solid -" })
end

T["nodes"]["a repeated id keeps its position and takes the last label"] = function()
  local g = graph("flowchart TB\nB[one] --> C\nA --> B[two]")
  eq(ids(g), "B C A")
  eq(labels(g), { "B=two", "C=C", "A=A" })
end

T["nodes"]["a later bare reference does not erase an earlier label"] = function()
  local g = graph("flowchart TB\nA[keep me] --> B\nA --> C")
  eq(labels(g), { "A=keep me", "B=B", "C=C" })
end

T["nodes"]["are ordered by first appearance"] = function()
  local g = graph("flowchart TB\nZ --> M\nM --> A\nQ --> Z")
  eq(ids(g), "Z M A Q")
  eq(g.index, { Z = 1, M = 2, A = 3, Q = 4 })
end

---------------------------------------------------------------------------

T["edges"] = MiniTest.new_set()

T["edges"]["solid forms and their lengths"] = function()
  local cases = {
    { "A --- B", "none" },
    { "A ---- B", "none" },
    { "A ----- B", "none" },
    { "A --> B", "arrow" },
    { "A ---> B", "arrow" },
    { "A ----> B", "arrow" },
    { "A --o B", "circle" },
    { "A ---o B", "circle" },
    { "A --x B", "cross" },
    { "A ---x B", "cross" },
  }
  for _, case in ipairs(cases) do
    local g = graph("flowchart TB\n" .. case[1])
    eq({ case[1], edges(g) }, { case[1], { "A>B " .. case[2] .. " solid -" } })
  end
end

T["edges"]["dotted forms lengthen with dots, not dashes"] = function()
  local cases = {
    { "A -.- B", "none" },
    { "A -..- B", "none" },
    { "A -...- B", "none" },
    { "A -.-> B", "arrow" },
    { "A -..-> B", "arrow" },
    { "A -...-> B", "arrow" },
  }
  for _, case in ipairs(cases) do
    local g = graph("flowchart TB\n" .. case[1])
    eq({ case[1], edges(g) }, { case[1], { "A>B " .. case[2] .. " dotted -" } })
  end
end

T["edges"]["thick forms"] = function()
  local cases = {
    { "A === B", "none" },
    { "A ==== B", "none" },
    { "A ==> B", "arrow" },
    { "A ===> B", "arrow" },
  }
  for _, case in ipairs(cases) do
    local g = graph("flowchart TB\n" .. case[1])
    eq({ case[1], edges(g) }, { case[1], { "A>B " .. case[2] .. " thick -" } })
  end
end

T["edges"]["~~~ is an invisible edge, not a dropped one"] = function()
  -- It still constrains layering downstream, so it has to reach the IR.
  local g = graph("flowchart TB\nA ~~~ B")
  eq(edges(g), { "A>B none invisible -" })
end

T["edges"]["need no whitespace around them"] = function()
  eq(edges(graph("flowchart TB\nA-->B")), { "A>B arrow solid -" })
  eq(edges(graph("flowchart TB\nA---B")), { "A>B none solid -" })
  eq(edges(graph("flowchart TB\nA---oB")), { "A>B circle solid -" })
  eq(edges(graph("flowchart TB\nA-.->B")), { "A>B arrow dotted -" })
end

T["edges"]["both label spellings are equivalent"] = function()
  eq(edges(graph("flowchart TB\nA -->|yes| B")), { "A>B arrow solid yes" })
  eq(edges(graph("flowchart TB\nA -- yes --> B")), { "A>B arrow solid yes" })
  eq(edges(graph("flowchart TB\nA---|yes|B")), { "A>B none solid yes" })
  eq(edges(graph("flowchart TB\nA-- yes ---B")), { "A>B none solid yes" })
end

T["edges"]["dotted and thick carry labels too"] = function()
  eq(edges(graph("flowchart TB\nA -. no .-> B")), { "A>B arrow dotted no" })
  eq(edges(graph("flowchart TB\nA -. no .- B")), { "A>B none dotted no" })
  eq(edges(graph("flowchart TB\nA == yes ==> B")), { "A>B arrow thick yes" })
  eq(edges(graph("flowchart TB\nA -.->|late| B")), { "A>B arrow dotted late" })
end

T["edges"]["a quoted label loses its quotes"] = function()
  eq(edges(graph('flowchart TB\nA -->|"yes, really"| B')), { "A>B arrow solid yes, really" })
end

T["edges"]["a label may contain a dash"] = function()
  eq(edges(graph("flowchart TB\nA -- a-b --> B")), { "A>B arrow solid a-b" })
end

T["edges"]["chaining makes one edge per link"] = function()
  local g = graph("flowchart TB\nA --> B --> C")
  eq(ids(g), "A B C")
  eq(edges(g), { "A>B arrow solid -", "B>C arrow solid -" })
end

T["edges"]["& fans out as a cross product"] = function()
  local g = graph("flowchart TB\nA & B --> C & D")
  eq(ids(g), "A B C D")
  eq(edges(g), {
    "A>C arrow solid -",
    "A>D arrow solid -",
    "B>C arrow solid -",
    "B>D arrow solid -",
  })
end

T["edges"]["chaining and & are the same rule"] = function()
  -- Every adjacent pair of node groups is a cross product; that single rule
  -- covers chaining, fan-out and this mixed form without special cases.
  local g = graph("flowchart TB\na --> b & c --> d")
  eq(ids(g), "a b c d")
  eq(edges(g), {
    "a>b arrow solid -",
    "a>c arrow solid -",
    "b>d arrow solid -",
    "c>d arrow solid -",
  })
end

T["edges"]["a chain may mix styles and labels"] = function()
  local g = graph("flowchart LR\nA -- one --> B -.-> C ==> D")
  eq(edges(g), {
    "A>B arrow solid one",
    "B>C arrow dotted -",
    "C>D arrow thick -",
  })
end

T["edges"]["labelled nodes may appear inside a chain"] = function()
  local g = graph("flowchart TB\nA[Start] --> B{Choice} -->|no| C((End))")
  eq(labels(g), { "A=Start", "B=Choice", "C=End" })
  eq(edges(g), { "A>B arrow solid -", "B>C arrow solid no" })
end

---------------------------------------------------------------------------

T["statements"] = MiniTest.new_set()

T["statements"]["`;` splits one line into several"] = function()
  local g = graph("flowchart TB\nA --> B; B --> C; C --> D")
  eq(ids(g), "A B C D")
  eq(#g.edges, 3)
end

T["statements"]["a trailing `;` is not an empty statement"] = function()
  local g = graph("flowchart TB\nA --> B;\n")
  eq(#g.edges, 1)
end

T["statements"]["`%%` is a comment only at the start of a line"] = function()
  local g = graph("flowchart TB\n%% A --> ZZZ\nA --> B")
  eq(ids(g), "A B")
  eq(#g.edges, 1)
end

T["statements"]["`%%` inside a label is not a comment"] = function()
  -- A blanket strip of `%%`-to-end-of-line would eat the rest of this
  -- statement, silently losing the edge.
  local g = graph("flowchart TB\nA[100%% done] --> B")
  eq(labels(g), { "A=100%% done", "B=B" })
  eq(edges(g), { "A>B arrow solid -" })
end

T["statements"]["an init directive is skipped"] = function()
  local g = graph('%%{init: {"theme": "dark"}}%%\nflowchart TB\nA --> B')
  eq(g.dir, "TB")
  eq(#g.edges, 1)
end

T["statements"]["YAML frontmatter is skipped"] = function()
  local g = graph("---\ntitle: A diagram\nconfig:\n  look: neo\n---\nflowchart LR\nA --> B")
  eq(g.dir, "LR")
  eq(ids(g), "A B")
end

T["statements"]["unclosed frontmatter is unparsed"] = function()
  bails("---\ntitle: A diagram\nflowchart LR\nA --> B", "unparsed")
end

T["statements"]["blank lines are ignored"] = function()
  local g = graph("flowchart TB\n\n\nA --> B\n\n")
  eq(#g.edges, 1)
end

T["statements"]["styling statements are recognised and ignored"] = function()
  local g = graph(table.concat({
    "flowchart TB",
    "A:::warn --> B",
    "classDef warn fill:#f96,stroke:#333",
    "class A,B warn",
    "style A fill:#fff",
    "linkStyle 0 stroke:#f00,stroke-width:2px",
    'click A "https://example.com" _blank',
  }, "\n"))
  eq(ids(g), "A B")
  eq(edges(g), { "A>B arrow solid -" })
end

T["statements"]["a keyword followed by a connector is still an edge"] = function()
  -- Skipping it would drop an edge silently, which is the one failure mode
  -- this parser refuses. `style` here is an ordinary node id.
  local g = graph("flowchart TB\nstyle --> B")
  eq(ids(g), "style B")
  eq(edges(g), { "style>B arrow solid -" })
end

---------------------------------------------------------------------------

T["bails"] = MiniTest.new_set()

T["bails"]["subgraph containers"] = function()
  bails("flowchart TB\nsubgraph one\nA --> B\nend", "subgraph")
end

T["bails"]["a bare end line"] = function()
  bails("flowchart TB\nA --> B\nend", "subgraph")
end

T["bails"]["`end` used as a node id"] = function()
  bails("flowchart TB\nA --> end", "subgraph")
  bails("flowchart TB\nend --> A", "subgraph")
end

T["bails"]["a self loop is a cycle"] = function()
  bails("flowchart TB\nA --> A", "cycle")
end

T["bails"]["a two-node cycle"] = function()
  bails("flowchart TB\nA --> B\nB --> A", "cycle")
end

T["bails"]["a long cycle"] = function()
  bails("flowchart TB\nA --> B --> C --> D --> B", "cycle")
end

T["bails"]["a cycle through an invisible edge"] = function()
  -- `~~~` constrains layering, so a cycle through it is a real cycle.
  bails("flowchart TB\nA --> B\nB ~~~ A", "cycle")
end

T["bails"]["a diamond is not a cycle"] = function()
  local g = graph("flowchart TB\nA --> B & C\nB --> D\nC --> D")
  eq(#g.edges, 4)
end

T["bails"]["an id outside [A-Za-z0-9_]"] = function()
  bails("flowchart TB\nmy.node --> B", "bad_id")
  bails("flowchart TB\nA --> B.C", "bad_id")
  bails("flowchart TB\nA --> #hash", "bad_id")
  bails("flowchart TB\nA:B --> C", "bad_id")
end

T["bails"]["underscores and digits are fine ids"] = function()
  local g = graph("flowchart TB\nnode_1 --> N2")
  eq(ids(g), "node_1 N2")
end

T["bails"]["@{ ... } node metadata"] = function()
  bails("flowchart TB\nA@{ shape: rect, label: hi }\nA --> B", "unsupported_node")
  bails("flowchart TB\nA@{ icon: fa:bell }", "unsupported_node")
  bails("flowchart TB\nA --> B@{ img: x.png }", "unsupported_node")
end

T["bails"]["a markdown-string label"] = function()
  bails("flowchart TB\nA[\"`**bold**`\"] --> B", "unsupported_node")
end

T["bails"]["double-ended arrows"] = function()
  bails("flowchart TB\nA <--> B", "unsupported_edge")
  bails("flowchart TB\nA o--o B", "unsupported_edge")
  bails("flowchart TB\nA x--x B", "unsupported_edge")
  bails("flowchart TB\nA <-.-> B", "unsupported_edge")
  bails("flowchart TB\nA <==> B", "unsupported_edge")
end

T["bails"]["an edge id"] = function()
  bails("flowchart TB\nA e1@--> B", "unsupported_edge")
end

T["bails"]["a line the parser does not recognise"] = function()
  bails("flowchart TB\nthis is not a diagram", "unparsed")
  bails("flowchart TB\nA -->", "unparsed")
  bails("flowchart TB\nA --> B --> ", "unparsed")
  bails("flowchart TB\nA -- dangling label B", "unparsed")
end

T["bails"]["one bad `;` piece bails the whole fence"] = function()
  bails("flowchart TB\nA --> B; nonsense here", "unparsed")
end

T["bails"]["more nodes than max_nodes"] = function()
  bails("flowchart TB\nA --> B --> C", "too_big", { max_nodes = 2 })
  eq(graph("flowchart TB\nA --> B --> C", { max_nodes = 3 }).dir, "TB")
end

T["bails"]["more edges than max_edges"] = function()
  bails("flowchart TB\nA --> B --> C", "too_big", { max_edges = 1 })
  eq(#graph("flowchart TB\nA --> B --> C", { max_edges = 2 }).edges, 2)
end

T["bails"]["the limits default without opts"] = function()
  local lines = { "flowchart TB" }
  for i = 1, 61 do
    lines[#lines + 1] = ("N%d --> N%d"):format(i, i + 1)
  end
  eq({ mermaid.parse(lines) == nil, select(2, mermaid.parse(lines)) }, { true, "too_big" })
end

T["bails"]["a graph just inside the default limits parses"] = function()
  local lines = { "flowchart TB" }
  for i = 1, 59 do
    lines[#lines + 1] = ("N%d --> N%d"):format(i, i + 1)
  end
  local g = mermaid.parse(lines)
  eq(#g.nodes, 60)
  eq(#g.edges, 59)
end

T["bails"]["a cross product exactly at max_edges still parses"] = function()
  -- The budget is now enforced inside the cross product, so its boundary is
  -- worth pinning from both sides: 10 x 10 edges is exactly the budget.
  local g = graph(
    "flowchart TB\n" .. cross_product(10, 10),
    { max_nodes = 20, max_edges = 100 }
  )
  eq(#g.edges, 100)
  bails("flowchart TB\n" .. cross_product(10, 11), "too_big", { max_nodes = 21, max_edges = 100 })
end

T["bails"]["an oversized `&` group bails before building it"] = function()
  -- 3200 members a side: one statement, 48 KB, all ids distinct. Before the
  -- budget moved inside the loops this materialised 10.2M edge tables first --
  -- 1.1 s and 2.6 GB on the machine this was written on -- because the guard
  -- ran only once `parse_statement` had returned. The size is chosen so that
  -- the old behaviour is two orders of magnitude outside the bound below; the
  -- bound itself is loose enough not to depend on the machine.
  bails_fast("flowchart TB\n" .. cross_product(3200, 3200), "too_big")
end

T["bails"]["a cross product bails as soon as the budget is spent"] = function()
  -- Same shape and size, but with `max_nodes` raised so the `&`-group cap
  -- cannot fire and the in-loop edge check is what stops it. Both guards need
  -- their own case: with the defaults the group cap gets there first, so this
  -- is the only way to exercise the cross product's own bail.
  bails_fast(
    "flowchart TB\n" .. cross_product(3200, 3200),
    "too_big",
    { max_nodes = 10000, max_edges = 120 }
  )
end

T["bails"]["a long dotted run bails quickly"] = function()
  -- `-.` sends the connector parser into `labelled`, whose only dotted closer
  -- is `%.+%-`: it used to be retried at every offset, backtracking over the
  -- whole remaining run each time. 32,000 dots took 2.1 s.
  bails_fast("flowchart TB\nA-." .. string.rep(".", 32000), "unparsed")
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

local CHAIN = "flowchart TD\nA[Parse] --> B[Layout] --> C[Draw]"
local FANOUT = "flowchart TD\nA[Root] --> B[Left]\nA --> C[Right]"
local DIAMOND = "flowchart TD\nA[Start] --> B[Yes]\nA --> C[No]\nB --> D[End]\nC --> D"
local LONG = "flowchart TD\nA --> B\nB --> C\nA --> C"
local LABEL = "flowchart TD\nA[Check] -->|ok| B[Done]"
local MULTILINE = "flowchart TD\nA[one<br/>two] --> B[x]"
local MARKERS = "flowchart TD\nA --o B\nA --x C\nA --- D"
local LR = "flowchart LR\nA[Parse] --> B[Layout] --> C[Draw]"
-- LR mirrors of LABEL, FANOUT and LONG. The horizontal layout is a separate
-- code path from the vertical one -- its own channel planner, its own segment
-- drawing -- so the vertical goldens above cover none of it beyond the straight
-- chain `LR` already pins.
local LR_LABEL = "flowchart LR\nA[Check] -->|ok| B[Done]"
local LR_FANOUT = "flowchart LR\nA[Root] --> B[Left]\nA --> C[Right]"
local LR_LONG = "flowchart LR\nA --> B\nB --> C\nA --> C"
-- A LABELLED fan-out, the shape issue #7 is about: every segment leaves one
-- port, so a label anchored to the source lands on the shared trunk and cannot
-- be attributed to a branch. Both the two-label and the one-label form are
-- pinned -- the one-label form is the more misleading of the two, since a label
-- on the trunk then looks like it applies to the unlabelled branch as well.
--
-- The fan-in sources are the control: their labels must STAY on the source
-- side, which is what would break if the anchor were unconditionally the target.
local FANOUT_LABELS = "flowchart TD\nA[Root] -->|yes| B[Left]\nA -->|no| C[Right]"
local FANOUT_ONE_LABEL = "flowchart TD\nA --> B\nA -->|no| C"
local FANIN_LABELS = "flowchart TD\nB -->|yes| D\nC -->|no| D"
local LR_FANOUT_LABELS = "flowchart LR\nA[Root] -->|yes| B[Left]\nA -->|no| C[Right]"
local LR_FANOUT_ONE_LABEL = "flowchart LR\nA --> B\nA -->|no| C"
local LR_FANIN_LABELS = "flowchart LR\nB -->|yes| D\nC -->|no| D"
local BT_FANOUT_LABELS = "flowchart BT\nA[Root] -->|yes| B[Left]\nA -->|no| C[Right]"
local RL_FANOUT_LABELS = "flowchart RL\nA[Root] -->|yes| B[Left]\nA -->|no| C[Right]"

-- Every golden source, for the two properties asserted over all of them below.
-- One list rather than two copies: a source added to only one of them is a case
-- that silently stops being checked under `ambiwidth = "double"`.
local ALL = {
  CHAIN,
  FANOUT,
  DIAMOND,
  LONG,
  LABEL,
  MULTILINE,
  MARKERS,
  LR,
  LR_LABEL,
  LR_FANOUT,
  LR_LONG,
  FANOUT_LABELS,
  FANOUT_ONE_LABEL,
  FANIN_LABELS,
  LR_FANOUT_LABELS,
  LR_FANOUT_ONE_LABEL,
  LR_FANIN_LABELS,
  BT_FANOUT_LABELS,
  RL_FANOUT_LABELS,
}

T["layout"]["a chain runs straight down"] = function()
  -- Ports, not boxes, are what get aligned: `Parse` is 9 columns wide and
  -- `Layout` 10, so centring the boxes would put their ports one column apart
  -- and jog the connector at every step.
  eq(rows(CHAIN), {
    " ┌───────┐",
    " │ Parse │",
    " └───┬───┘",
    "     v",
    "┌────┴───┐",
    "│ Layout │",
    "└────┬───┘",
    "     v",
    " ┌───┴──┐",
    " │ Draw │",
    " └──────┘",
  })
end

T["layout"]["a fan-out splits in the channel"] = function()
  eq(rows(FANOUT), {
    "     ┌──────┐",
    "     │ Root │",
    "     └───┬──┘",
    "    ┌────┴────┐",
    "    v         v",
    "┌───┴──┐  ┌───┴───┐",
    "│ Left │  │ Right │",
    "└──────┘  └───────┘",
  })
end

T["layout"]["a labelled fan-out labels the branches, not the trunk"] = function()
  -- Issue #7. A channel has two label bands: one BEFORE its jog rows, on the
  -- source-side run, and one AFTER them, on the target-side run. Both these
  -- edges leave Root's port, so the source-side run is shared and neither label
  -- could be attributed there; both go in the post band instead, where each
  -- segment has already jogged onto its own target column.
  --
  -- That is the row between the jog and the markers: `yes` sits beside the
  -- column that ends at `Left`, `no` beside the one that ends at `Right`.
  eq(rows(FANOUT_LABELS), {
    "     ┌──────┐",
    "     │ Root │",
    "     └───┬──┘",
    "    ┌────┴────┐",
    "    │yes      │no",
    "    v         v",
    "┌───┴──┐  ┌───┴───┐",
    "│ Left │  │ Right │",
    "└──────┘  └───────┘",
  })
end

T["layout"]["only the labelled branch of a fan-out carries the label"] = function()
  -- The misleading half of issue #7: with one branch labelled, a label on the
  -- shared trunk reads as applying to both. The post band puts it on C's own
  -- column, so B's branch is visibly bare -- the row still exists, because the
  -- band is sized by the widest label in it and B's segment simply draws its
  -- line through it.
  eq(rows(FANOUT_ONE_LABEL), {
    "   ┌───┐",
    "   │ A │",
    "   └─┬─┘",
    "  ┌──┴───┐",
    "  │      │no",
    "  v      v",
    "┌─┴─┐  ┌─┴─┐",
    "│ B │  │ C │",
    "└───┘  └───┘",
  })
end

T["layout"]["a labelled fan-in keeps its labels on the source side"] = function()
  -- The control for the case above. Here the shared end is the TARGET, so the
  -- source-side run of each segment is that edge's alone and the labels stay in
  -- the pre band -- above the jog, beside the column leaving their own box.
  -- Anchoring unconditionally to the target would pile both onto D's trunk and
  -- reintroduce issue #7 the other way round.
  eq(rows(FANIN_LABELS), {
    "┌───┐  ┌───┐",
    "│ B │  │ C │",
    "└─┬─┘  └─┬─┘",
    "  │yes   │no",
    "  └───┬──┘",
    "      v",
    "    ┌─┴─┐",
    "    │ D │",
    "    └───┘",
  })
end

T["layout"]["two paths rejoin on one node"] = function()
  -- The `├` on the second-to-last row is the whole point of the bitmask: two
  -- edges meeting in one cell produce the junction without a special case.
  eq(rows(DIAMOND), {
    "   ┌───────┐",
    "   │ Start │",
    "   └───┬───┘",
    "   ┌───┴────┐",
    "   v        v",
    "┌──┴──┐  ┌──┴─┐",
    "│ Yes │  │ No │",
    "└──┬──┘  └──┬─┘",
    "   └────┬───┘",
    "        v",
    "     ┌──┴──┐",
    "     │ End │",
    "     └─────┘",
  })
end

T["layout"]["an edge spanning two layers routes past the layer between"] = function()
  -- A --> C skips B's layer, so it gets a dummy there and runs down the
  -- channel column instead of crossing B's box.
  eq(rows(LONG), {
    "  ┌───┐",
    "  │ A │",
    "  └─┬─┘",
    "  ┌─┴──┐",
    "  v    │",
    "┌─┴─┐  │",
    "│ B │  │",
    "└─┬─┘  │",
    "  └──┬─┘",
    "     v",
    "   ┌─┴─┐",
    "   │ C │",
    "   └───┘",
  })
end

T["layout"]["an edge label sits beside its vertical run"] = function()
  eq(rows(LABEL), {
    "┌───────┐",
    "│ Check │",
    "└───┬───┘",
    "    │ok",
    "    v",
    "┌───┴──┐",
    "│ Done │",
    "└──────┘",
  })
end

T["layout"]["a <br/> label makes a taller box"] = function()
  eq(rows(MULTILINE), {
    "┌─────┐",
    "│ one │",
    "│ two │",
    "└──┬──┘",
    "   v",
    " ┌─┴─┐",
    " │ x │",
    " └───┘",
  })
end

T["layout"]["circle and cross end markers keep their own character"] = function()
  -- `--o` and `--x` are drawn as literal `o` and `x` rather than collapsed to
  -- an arrowhead, so no meaning is lost; `---` gets no marker at all.
  eq(rows(MARKERS), {
    "       ┌───┐",
    "       │ A │",
    "       └─┬─┘",
    "  ┌──────┼──────┐",
    "  o      x      │",
    "┌─┴─┐  ┌─┴─┐  ┌─┴─┐",
    "│ B │  │ C │  │ D │",
    "└───┘  └───┘  └───┘",
  })
end

T["layout"]["BT draws the same graph upwards"] = function()
  eq(rows("flowchart BT\nA[Bottom] --> B[Top]"), {
    "  ┌─────┐",
    "  │ Top │",
    "  └──┬──┘",
    "     ^",
    "┌────┴───┐",
    "│ Bottom │",
    "└────────┘",
  })
end

T["layout"]["LR lays the layers out across"] = function()
  eq(rows(LR), {
    "┌───────┐   ┌────────┐   ┌──────┐",
    "│ Parse ├──>┤ Layout ├──>┤ Draw │",
    "└───────┘   └────────┘   └──────┘",
  })
end

T["layout"]["RL is LR reversed"] = function()
  eq(rows("flowchart RL\nA[One] --> B[Two]"), {
    "┌─────┐   ┌─────┐",
    "│ Two ├<──┤ One │",
    "└─────┘   └─────┘",
  })
end

T["layout"]["an LR edge label sits on its horizontal run"] = function()
  -- The horizontal counterpart of LABEL. Vertically a label goes *beside* the
  -- line, because a run of `│` has no room for text; horizontally it goes *on*
  -- it. The channel is sized to hold it: one column per label slot plus a
  -- separating column plus the marker, so `ok` widens the gap from the three
  -- columns of `LR` above to four.
  eq(rows(LR_LABEL), {
    "┌───────┐    ┌──────┐",
    "│ Check ├ok─>┤ Done │",
    "└───────┘    └──────┘",
  })
end

T["layout"]["an LR fan-out jogs in the channel"] = function()
  -- The horizontal counterpart of FANOUT, and the only golden that exercises
  -- the `seg.cy ~= seg.ty` path: both targets sit off Root's port row, so each
  -- connector turns in the channel instead of running straight across.
  --
  -- The two branches share the jog column rather than taking one each -- they
  -- meet at Root's port, which is what the `┤` on Root's row is. Both boxes in
  -- the second layer are `Right`-wide even though `Left` is shorter: uniform
  -- widths in a layer are what keep the left ports aligned.
  eq(rows(LR_FANOUT), {
    "           ┌───────┐",
    "        ┌─>┤ Left  │",
    "┌──────┐│  └───────┘",
    "│ Root ├┤",
    "└──────┘│  ┌───────┐",
    "        └─>┤ Right │",
    "           └───────┘",
  })
end

T["layout"]["an LR labelled fan-out labels the branches, not the trunk"] = function()
  -- The horizontal half of issue #7, and the worse-reading one: both labels used
  -- to sit on the shared run out of Root as `├yes─no──┤`, which reads as a
  -- single token. The post band is the stretch of channel after the jog column,
  -- where each segment is already on its target's row, so each label is drawn on
  -- the branch it belongs to.
  --
  -- Label first, then a separating column, exactly as the pre-band `├ok─>┤` of
  -- LR_LABEL: `┌yes─>┤ Left │`. The band is one label wide even with two labels
  -- in it, because labels on different rows share a slot.
  eq(rows(LR_FANOUT_LABELS), {
    "              ┌───────┐",
    "        ┌yes─>┤ Left  │",
    "┌──────┐│     └───────┘",
    "│ Root ├┤",
    "└──────┘│     ┌───────┐",
    "        └no──>┤ Right │",
    "              └───────┘",
  })
end

T["layout"]["only the labelled branch of an LR fan-out carries the label"] = function()
  -- As FANOUT_ONE_LABEL, horizontally. `no` is on C's run alone; B's run is the
  -- same length but bare, so the two branches are told apart by the label rather
  -- than by a convention the output does not state.
  eq(rows(LR_FANOUT_ONE_LABEL), {
    "          ┌───┐",
    "     ┌───>┤ B │",
    "┌───┐│    └───┘",
    "│ A ├┤",
    "└───┘│    ┌───┐",
    "     └no─>┤ C │",
    "          └───┘",
  })
end

T["layout"]["an LR labelled fan-in keeps its labels on the source side"] = function()
  -- The horizontal control: the shared end is D, so both labels stay in the pre
  -- band, on the run leaving their own box and before the jog column they share.
  eq(rows(LR_FANIN_LABELS), {
    "┌───┐",
    "│ B ├yes─┐",
    "└───┘    │ ┌───┐",
    "         ├>┤ D │",
    "┌───┐    │ └───┘",
    "│ C ├no──┘",
    "└───┘",
  })
end

T["layout"]["the fan-out fix is orientation independent"] = function()
  -- Issue #7 reproduced on all four directions, so both reversed layouts are
  -- pinned too. `BT` is `TB` with the channel rows counted the other way, so the
  -- band order is unchanged relative to the source box: markers nearest the
  -- target, then the post-band labels, then the jog.
  eq(rows(BT_FANOUT_LABELS), {
    "┌──────┐  ┌───────┐",
    "│ Left │  │ Right │",
    "└───┬──┘  └───┬───┘",
    "    ^         ^",
    "    │yes      │no",
    "    └────┬────┘",
    "     ┌───┴──┐",
    "     │ Root │",
    "     └──────┘",
  })
  -- `RL` is `LR` with the channel columns counted the other way, and each label
  -- is again on its own branch's run. Its exact position is off by its own width
  -- -- a span is placed at a column and grows rightwards, which mirrors wrongly
  -- in a leftward channel, so `yes` sits past the end of the run rather than at
  -- its head and covers the corner glyph it should stop before. That is a
  -- PRE-EXISTING horizontal-label defect, visible on `flowchart RL` with a
  -- single labelled edge long before this change and orthogonal to it: the label
  -- is attributable here, which is what issue #7 is about.
  eq(rows(RL_FANOUT_LABELS), {
    "┌───────┐",
    "│ Left  ├<───yes",
    "└───────┘     │┌──────┐",
    "              ├┤ Root │",
    "┌───────┐     │└──────┘",
    "│ Right ├<───no",
    "└───────┘",
  })
end

T["layout"]["an LR edge spanning two layers routes past the layer between"] = function()
  -- The horizontal counterpart of LONG, and the only golden that draws a
  -- horizontal dummy: A --> C skips B's layer, so it gets a dummy there and
  -- runs along the row below B as `───` rather than crossing B's box.
  --
  -- The vertical it climbs into C is shared with B --> C: the two segments may
  -- touch because C is a target for both, so the merge draws a connection that
  -- really exists.
  eq(rows(LR_LONG), {
    "        ┌───┐",
    "┌───┐┌─>┤ B ├┐",
    "│ A ├┤  └───┘│  ┌───┐",
    "└───┘│       ├─>┤ C │",
    "     └───────┘  └───┘",
  })
end

T["layout"]["an empty label line does not break box sizing"] = function()
  -- `A[a<br/>]` parses to { "a", "" }, so a box has to tolerate a blank row.
  eq(rows("flowchart TD\nA[a<br/>] --> B[b]"), {
    "┌───┐",
    "│ a │",
    "│   │",
    "└─┬─┘",
    "  v",
    "┌─┴─┐",
    "│ b │",
    "└───┘",
  })
end

T["layout"]["an invisible edge places its nodes but draws nothing"] = function()
  -- `~~~` still constrains layering, so B lands on the layer below A.
  eq(rows("flowchart TD\nA ~~~ B"), {
    "┌───┐",
    "│ A │",
    "└───┘",
    "",
    "┌───┐",
    "│ B │",
    "└───┘",
  })
end

-- The canvas exists to make alignment structural rather than something to be
-- checked afterwards, so the property it guarantees is asserted directly, under
-- both settings of the option that would break it.
T["layout"]["equal width"] = MiniTest.new_set({
  parametrize = { { "single" }, { "double" } },
})

T["layout"]["equal width"]["every row of a diagram is the same width"] = function(ambi)
  vim.o.ambiwidth = ambi
  -- Box drawing is East Asian *Ambiguous*: `─ │ ┌` are one cell under "single"
  -- and two under "double", while the ASCII markers stay one either way. A
  -- layout padded by character count drifts a cell per unit and this fails.
  --
  -- Measured with `strwidth`: `strdisplaywidth` is not additive over a long run
  -- of `─` and reports misalignment that is not there.
  --
  -- The horizontal sources earn their place here separately: an LR row is
  -- padded to a width that comes out of the channel planner rather than out of
  -- a box, and with a label in it that width is a label span rounded up to
  -- whole `─` columns -- the one number in the layout that is not obvious by
  -- inspection under "double".
  --
  -- The labelled fan-outs are exactly that number twice over: their channels are
  -- sized from two label bands rather than one, so a rounding error in either
  -- band shows up here as a row that is a cell short.
  for _, src in ipairs(ALL) do
    local lines = draw(src).lines
    local widths = {}
    for _, line in ipairs(lines) do
      widths[vim.fn.strwidth(line)] = true
    end
    eq({ ambi, src, vim.tbl_count(widths) }, { ambi, src, 1 })
  end
end

T["layout"]["equal width"]["only verified-safe glyphs are drawn"] = function(ambi)
  vim.o.ambiwidth = ambi
  -- The sixteen bitmask states map onto exactly the eleven box-drawing
  -- characters already in the renderer's safe set, so drawing must not have
  -- introduced a twelfth. End markers are ASCII.
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
  local found = {}
  for _, src in ipairs(ALL) do
    for _, line in ipairs(draw(src).lines) do
      for _, char in ipairs(vim.fn.split(line, "\\zs")) do
        if #char > 1 and not SAFE[char] then
          found[#found + 1] = char
        end
      end
    end
  end
  eq({ ambi, found }, { ambi, {} })
end

T["layout"]["decorations stay inside their line and name known groups"] = function()
  local GROUPS = {
    MdviewMermaidBox = true,
    MdviewMermaidLabel = true,
    MdviewMermaidEdge = true,
    MdviewMermaidEdgeDim = true,
    MdviewMermaidEdgeStrong = true,
    MdviewMermaidEdgeLabel = true,
  }
  local res = draw(DIAMOND .. "\nA -.-> D")
  local bad = {}
  for _, d in ipairs(res.decorations) do
    local line = res.lines[d.line + 1]
    if
      d.kind ~= "hl"
      or not line
      or not GROUPS[d.group]
      or d.col_start >= d.col_end
      or d.col_end > #line
    then
      bad[#bad + 1] = d
    end
  end
  eq(bad, {})
end

T["layout"]["a dotted edge is coloured, not redrawn"] = function()
  -- The glyph set has one line weight, so `-.->` differs from `-->` by
  -- highlight group alone. The drawn characters must be identical.
  eq(rows("flowchart TD\nA -.-> B"), rows("flowchart TD\nA --> B"))
  local function groups(src)
    local seen = {}
    for _, d in ipairs(draw(src).decorations) do
      seen[d.group] = true
    end
    return seen
  end
  eq(groups("flowchart TD\nA -.-> B")["MdviewMermaidEdgeDim"], true)
  eq(groups("flowchart TD\nA ==> B")["MdviewMermaidEdgeStrong"], true)
end

T["layout"]["a prefix shifts every line and every byte column"] = function()
  local plain = draw(CHAIN)
  local shifted = draw(CHAIN, { prefix = "  " })
  for i, line in ipairs(plain.lines) do
    eq(shifted.lines[i], "  " .. line)
  end
  for i, d in ipairs(plain.decorations) do
    eq({ shifted.decorations[i].col_start, shifted.decorations[i].col_end }, { d.col_start + 2, d.col_end + 2 })
  end
end

T["layout"]["drawing one parsed graph twice draws the same diagram"] = function()
  -- `draw` is documented as pure, so the graph it is handed has to come back
  -- untouched. It did not: the "this edge's label is already placed" flag lived
  -- on the shared edge table, so a second draw skipped every label -- and the
  -- routing rows that carry them, which changes the row count too.
  --
  -- Both label placers are covered: vertical puts the label beside the run, and
  -- horizontal on it, and each used to set the flag.
  for _, src in ipairs({
    "flowchart TD\nA[Check] -->|ok| B[Done]\nA -->|no| C[Stop]",
    "flowchart LR\nA[Check] -->|ok| B[Done]\nA -->|no| C[Stop]",
  }) do
    local graph = mermaid.parse(vim.split(src, "\n", { plain = true }))
    local before = vim.inspect(graph)
    local first = mermaid.draw(graph)
    local second = mermaid.draw(graph)
    eq({ src, second.lines }, { src, first.lines })
    eq({ src, vim.inspect(graph) }, { src, before })
  end
end

---------------------------------------------------------------------------
-- Fallback
---------------------------------------------------------------------------

T["fallback"] = MiniTest.new_set()

T["fallback"]["render returns nil for anything the parser bails on"] = function()
  for _, src in ipairs({
    "flowchart TD\nsubgraph s\nA --> B\nend",
    "flowchart TD\nA --> B\nB --> A",
    "flowchart TD\nA <--> B",
    "flowchart TD\na.b --> c",
    "gantt\ntitle A schedule",
    "flowchart TD\nA -->|x<br/>y| B",
  }) do
    eq({ src, mermaid.render(vim.split(src, "\n", { plain = true })) }, { src, nil })
  end
end

T["fallback"]["render returns nil when a valid parse draws nothing"] = function()
  -- These are not bails: the parse succeeds, with zero nodes. `classDef` and
  -- `style` are recognised-and-skipped statements, so a header plus one of them
  -- is a well-formed flowchart with nothing in it -- exactly what a diagram
  -- looks like halfway through being typed. An empty canvas is still no
  -- diagram, so `render` must offer the caller the same `nil` a bail does,
  -- rather than a truthy result with no lines in it.
  for _, src in ipairs({
    "flowchart TD",
    "flowchart TD\n  classDef warn fill:#f00",
    "flowchart TD\n  style A fill:#f00",
  }) do
    local lines = vim.split(src, "\n", { plain = true })
    eq({ src, mermaid.parse(lines) ~= nil }, { src, true })
    eq({ src, mermaid.render(lines) }, { src, nil })
  end
end

T["fallback"]["render returns nil when a label cannot be attributed"] = function()
  -- Also not bails: both parse cleanly, and the refusal happens in the layout.
  -- An edge whose source fans out AND whose target fans in owns no run in its
  -- channel -- the source-side run is shared with its siblings and the
  -- target-side one with the edges arriving alongside it -- so there is nowhere
  -- to draw the label that a reader could attach to one edge. A label the reader
  -- cannot attribute is a wrong diagram, not a missing one, so the fence falls
  -- back to the code block whole.
  --
  -- Two parallel labelled edges are the smallest instance (`A -->|x| B` twice
  -- over is a fan-out and a fan-in between the same pair of boxes); the second
  -- source is the general one, where the two ends are shared with different
  -- edges.
  for _, src in ipairs({
    "flowchart TD\nA -->|x| B\nA -->|y| B",
    "flowchart TD\nA -->|x| C\nA --> D\nB --> C",
    "flowchart LR\nA -->|x| B\nA -->|y| B",
    "flowchart LR\nA -->|x| C\nA --> D\nB --> C",
  }) do
    local lines = vim.split(src, "\n", { plain = true })
    eq({ src, mermaid.parse(lines) ~= nil }, { src, true })
    eq({ src, mermaid.render(lines) }, { src, nil })
  end
end

T["fallback"]["an unlabelled fan-out crossing a fan-in still draws"] = function()
  -- The bail is about the LABEL, not about the shape: the same graph without one
  -- has nothing to attribute and renders as before.
  eq(mermaid.render(vim.split("flowchart TD\nA --> C\nA --> D\nB --> C", "\n", { plain = true })) ~= nil, true)
end

T["fallback"]["the block marker style has no box drawing to fall back on"] = function()
  -- `marker_style = "block"` exists for terminals that do not draw
  -- U+2500..U+257F themselves, and a diagram is nothing but those characters.
  local src = vim.split(CHAIN, "\n", { plain = true })
  eq(mermaid.render(src, { marker_style = "block" }), nil)
  eq(mermaid.render(src, { marker_style = "glyph" }) ~= nil, true)
end

return T
