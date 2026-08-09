--- Shared text handling for the mermaid package: the small string helpers every
--- diagram type needs, plus the prelude that turns a fence body into the lines a
--- diagram parser sees.
---
--- A module of its own because none of the alternatives work: these are
--- *parsing* helpers, so `canvas.lua` is the wrong place; leaving them in
--- `flowchart.lua` for another diagram type to reach into would couple the two
--- types this package exists to keep apart; and putting them in `init.lua` would
--- make `flowchart.lua` require its own parent.
---
--- Nothing here measures text, so unlike the renderer this module has no
--- `ambiwidth` dependency.
local M = {}

function M.trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

function M.skip_ws(s, pos)
  return (s:match("^%s*()", pos))
end

--- Strip one layer of surrounding double quotes, if present.
function M.unquote(s)
  local inner = s:match('^%s*"(.*)"%s*$')
  return inner or s
end

--- Split a label on `<br>` / `<br/>` / `<br />`, any case. Always returns at
--- least one string, so a label is a non-empty list everywhere downstream.
function M.split_label(text)
  local out = {}
  local pos = 1
  while true do
    local s, e = text:find("<%s*[Bb][Rr]%s*/?%s*>", pos)
    if not s then
      break
    end
    out[#out + 1] = M.trim(text:sub(pos, s - 1))
    pos = e + 1
  end
  out[#out + 1] = M.trim(text:sub(pos))
  return out
end

--- Drop YAML frontmatter, which is allowed only at the very top with the
--- opening `---` alone on its line. Returns the remaining lines, or
--- `nil, reason` if the block is never closed.
function M.strip_frontmatter(lines)
  local first
  for i, line in ipairs(lines) do
    if M.trim(line) ~= "" then
      first = i
      break
    end
  end
  if not first or M.trim(lines[first]) ~= "---" then
    return lines
  end
  for i = first + 1, #lines do
    if M.trim(lines[i]) == "---" then
      local rest = {}
      for j = i + 1, #lines do
        rest[#rest + 1] = lines[j]
      end
      return rest
    end
  end
  return nil, "unparsed"
end

--- Fence body -> the lines a diagram parser sees: frontmatter dropped, comment
--- lines dropped, blank lines dropped, each survivor trimmed.
---
--- Comments and directives are dropped here: `%%` opens a comment only as the
--- first non-whitespace on a line (the docs are explicit that a comment owns its
--- line), so a label containing `%%` survives. `%%{init: ...}%%` directives are
--- comments by that same rule.
---
--- It deliberately stops there. How a line becomes *statements* is the diagram
--- type's business -- a flowchart splits on `;`, a sequence diagram does not --
--- so this is the largest prelude that is genuinely shared rather than assumed.
---
--- Returns the lines, or `nil, reason` when the frontmatter is never closed.
---@param lines string[] fence body, without the fence markers
---@return string[]|nil lines, string|nil reason
function M.lines_of(lines)
  local body, reason = M.strip_frontmatter(lines)
  if not body then
    return nil, reason
  end
  local out = {}
  for _, line in ipairs(body) do
    local s = M.trim(line)
    if s ~= "" and s:sub(1, 2) ~= "%%" then
      out[#out + 1] = s
    end
  end
  return out
end

return M
