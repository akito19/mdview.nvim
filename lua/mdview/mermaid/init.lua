--- Mermaid fence -> decorated lines, or `nil` when the fence is outside the
--- supported subset.
---
--- This module is the package's front door and owns nothing but dispatch: it
--- runs the shared prelude, reads the diagram type off the first statement and
--- hands the rest to the module that owns that type.
---
---   mdview.mermaid.text        trimming, labels, the frontmatter/comment prelude
---   mdview.mermaid.canvas      the column grid, bitmask glyphs, emit
---   mdview.mermaid.flowchart   the `flowchart` / `graph` subset
---   mdview.mermaid.sequence    the `sequenceDiagram` subset
---
--- `plan/mermaid.md` defines the supported subset; everything outside it is a
--- *hard bail* -- `nil, reason` -- so the caller can fall back to rendering the
--- fence as a plain code block. A wrong diagram is worse than no diagram, so
--- every ambiguity resolves towards bailing.
---
--- The package is pure in the same sense `renderer.lua` is: plain Lua string
--- handling, no buffer, window or API access.
local text = require("mdview.mermaid.text")
local flowchart = require("mdview.mermaid.flowchart")
local sequence = require("mdview.mermaid.sequence")

local M = {}

-- Diagram type -> the module that parses and draws it. `graph` is mermaid's
-- legacy spelling of `flowchart`, so both keys reach the same module. A parsed
-- diagram records its key as `kind`, which is how `M.draw` dispatches without
-- re-reading the source.
local KINDS = {
  flowchart = flowchart,
  graph = flowchart,
  sequencediagram = sequence,
}

--- The first word of the first statement, lowercased, or nil if the body has no
--- word in it at all.
---
--- Deliberately loose: it takes the first alphabetic run in the body rather than
--- insisting the line be shaped like a header. It can afford to be, because the
--- module it selects re-reads the header off its OWN first statement and bails
--- if it is not one -- so a false positive costs a wasted lookup, where a false
--- negative would refuse a diagram the kind module would have accepted. What is
--- a statement is not knowable here: `;` separates them in a flowchart and does
--- not in a sequence diagram, so a header preceded by an empty `;` statement
--- must still be found.
local function keyword_of(lines)
  for _, line in ipairs(lines) do
    local word = line:match("%a+")
    if word then
      return word:lower()
    end
  end
end

--- Parse the body of a ```` ```mermaid ```` fence.
---
--- Only the *keyword* is decided here; what the rest of the header means is the
--- diagram type's business, so `flowchart XY` is still `not_flowchart` and the
--- direction vocabulary stays in `flowchart.lua`.
---
--- `not_flowchart` is also the bail for a header naming no diagram type this
--- package supports, and for a body with no statements at all. The name is kept
--- rather than generalised: the reason string is read only by tests, the
--- renderer's fallback keys on `nil`, and renaming it would churn assertions for
--- no behavioural gain.
---@param lines string[] fence body, without the fence markers
---@param opts table|nil { max_nodes = 60, max_edges = 120 }
---@return table|nil graph, string|nil reason
function M.parse(lines, opts)
  local body, reason = text.lines_of(lines)
  if not body then
    return nil, reason
  end

  local keyword = keyword_of(body)
  local kind = keyword and KINDS[keyword]
  if not kind then
    return nil, "not_flowchart"
  end
  return kind.parse(body, opts)
end

--- Lay out and draw a parsed diagram.
---
--- Diagrams join tables, code blocks and rules in the never-wrapped set: they
--- are sized by their content and scroll sideways, so no target width is
--- consulted and a window resize cannot change one.
---@param graph table from `M.parse`
---@param opts table|nil { prefix = "" } prepended to every line
---@return table { lines = string[], decorations = table[] }
function M.draw(graph, opts)
  return KINDS[graph.kind].draw(graph, opts)
end

--- Parse and draw, or `nil` if the fence is outside the supported subset.
---@param lines string[] fence body
---@param opts table|nil
---@return table|nil { lines, decorations }
function M.render(lines, opts)
  opts = opts or {}
  -- `marker_style = "block"` exists for terminals that do not draw box drawing
  -- natively, and a diagram is nothing but box drawing. It degrades to the
  -- plain code block, the same way `tables.borders = false` drops the grid.
  if opts.marker_style == "block" then
    return nil
  end
  local graph = M.parse(lines, opts)
  if not graph then
    return nil
  end
  return M.draw(graph, opts)
end

return M
