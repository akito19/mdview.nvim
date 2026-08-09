--- Configuration for mdview.nvim: defaults + validated deep merge.
local M = {}

M.defaults = {
  split = "vertical", -- "vertical" | "horizontal"
  -- Size is one overloaded number: a value <= 1 is a fraction of the screen,
  -- anything larger is an absolute cell count. So `width = 1` means the FULL
  -- screen, not one column -- use `0.99` for "almost all of it", or an integer
  -- from 2 upwards for a fixed column count.
  width = 0.5, -- fraction of &columns, or integer = absolute columns
  height = 0.5, -- fraction of &lines, or integer = absolute rows
  -- The preview window is ALWAYS 'nowrap' -- a window-local option cannot
  -- reflow prose while leaving tables and code blocks scrollable, so the
  -- renderer hard-wraps body text itself instead.
  wrap = true, -- hard-wrap paragraphs, list items, quotes and headings
  -- text_width = nil,      -- nil (the default, hence absent here) wraps to the
  --                           preview window's live width; a number caps it.
  code_block_syntax = true, -- tree-sitter highlighting inside fenced code blocks
  elements = {
    headings = true,
    emphasis = true,
    code_blocks = true,
    lists = true,
    blockquotes = true,
    links = true,
    tables = true,
    horizontal_rules = true,
    mermaid = true, -- draw ```mermaid flowcharts; off renders them as code
  },
  -- How every bar/bullet/border is drawn.
  --   "glyph" (default) -- real characters, from the verified-safe set only:
  --                        `█ • ‣ ·` (present in Monaco) plus box drawing
  --                        `┌ ┬ ┐ ├ ┼ ┤ └ ┴ ┘ ─ │`, which the terminal draws
  --                        with its own sprite renderer rather than from the
  --                        font, so it tiles in both directions.
  --   "block"           -- the v3 fallback for terminals without that native
  --                        drawing: ordinary spaces carrying a background
  --                        highlight, and tables without a grid. A space has
  --                        no glyph outline, so a run of them is a solid
  --                        rectangle in *any* font.
  -- The layout (gutter width, bar length, indents) is identical under both.
  marker_style = "glyph",
  heading = {
    gutter = 6, -- bar gutter width in cells. The bar is `level` cells -- one
    -- per `#` in the source -- and is LEFT-aligned in the gutter,
    -- so the staircase grows from the left edge while the heading
    -- text starts at the same column at every level.
    bar = "█", -- U+2588 FULL BLOCK: fills its cell, so no background trickery
    bold = true, -- heading text is bold (GitHub renders every heading bold)
    underline_levels = 2, -- levels 1..N get GitHub's `border-bottom` band; 0 disables
  },
  code = {
    language_label = true, -- dim header line carrying the fence language
    line_numbers = false,
  },
  -- A ```mermaid fence is drawn as a box-and-line diagram when it falls inside
  -- the supported subset (`flowchart`/`graph`, TB/TD/BT/LR/RL, rectangular
  -- nodes, single-ended edges). Anything else -- a subgraph, a cycle, an
  -- unrecognised statement -- falls back to an ordinary labelled code block.
  -- A wrong diagram is worse than no diagram, so the fallback is deliberate
  -- rather than best-effort.
  mermaid = {
    language_label = true, -- keep the dim `mermaid` header line above a diagram
    -- Guards against a pathological fence costing a visible pause on every
    -- `:w`. Past either limit the fence renders as a code block.
    max_nodes = 60,
    max_edges = 120,
  },
  tables = {
    borders = true, -- full box-drawing grid: `┌ ┬ ┐ ├ ┼ ┤ └ ┴ ┘ ─ │`. The
    -- terminal draws U+2500..U+257F natively, so the rules
    -- tile whatever the font covers. `false` falls back to
    -- `│` column separators with no horizontal rules.
    zebra = false, -- redundant once every row is ruled; `true` restores it
  },
  highlights = {
    blend = true, -- compute background groups by blending into Normal.bg
  },
  icons = {
    -- GitHub's own bullet first, then two shapes that read as "deeper".
    bullets = { "•", "‣", "·" }, -- U+2022, U+2023, U+00B7; cycled by depth
    -- ASCII checkboxes: no font can be assumed to have ☐/☑.
    checkbox = { unchecked = "[ ]", checked = "[x]" },
  },
}

--- Options that have no default value, because `nil` is meaningful for them.
--- They cannot be discovered from `M.defaults` -- an absent key and a key set
--- to nil are the same table -- so their accepted type is recorded here and
--- the validator consults both tables. Keyed by full dotted path.
M.optional = {
  text_width = "number",
}

local current = vim.deepcopy(M.defaults)

local function warn(fmt, ...)
  vim.notify(("mdview: " .. fmt):format(...), vim.log.levels.WARN)
end

--- Walk the user's options against the defaults tree, repairing `merged` in
--- place. A typo is otherwise a silent no-op: `marker_syle = "block"` merges
--- cleanly, never matches anything, and leaves the user believing the option
--- took effect.
---@param opts table the user's subtree
---@param spec table the corresponding defaults subtree
---@param merged table the deep-merged subtree, repaired in place
---@param path string dotted path of `opts`, "" at the top level
local function validate(opts, spec, merged, path)
  if type(opts) ~= "table" then
    return
  end
  for key, val in pairs(opts) do
    local full = path == "" and tostring(key) or (path .. "." .. tostring(key))
    local default = spec[key]
    if default == nil then
      local want = M.optional[full]
      if want == nil then
        warn("unknown option `%s`, ignored", full)
        merged[key] = nil
      elseif type(val) ~= want then
        warn("option `%s` expects %s, got %s -- ignoring it", full, want, type(val))
        merged[key] = nil
      end
    elseif type(default) == "table" then
      if type(val) ~= "table" then
        warn("option `%s` expects table, got %s -- using the default", full, type(val))
        merged[key] = vim.deepcopy(default)
      elseif vim.islist(default) then
        -- `vim.tbl_deep_extend` merges lists element-by-element, so a shorter
        -- user list keeps the tail of the default one -- `bullets = { "*" }`
        -- would silently become `{ "*", "‣", "·" }`. A list-valued option is a
        -- single value, so it replaces the default wholesale.
        merged[key] = vim.deepcopy(val)
      else
        validate(val, default, merged[key], full)
      end
    elseif type(val) ~= type(default) then
      warn("option `%s` expects %s, got %s -- using the default", full, type(default), type(val))
      merged[key] = default
    end
  end
end

--- One of a fixed set of strings, or the default.
local function enforce_enum(merged, key, allowed, fallback)
  if not vim.tbl_contains(allowed, merged[key]) then
    warn(
      "invalid `%s` value %q (expected %s), using %q",
      key,
      tostring(merged[key]),
      table.concat(vim.tbl_map(function(v)
        return ('"%s"'):format(v)
      end, allowed), " or "),
      fallback
    )
    merged[key] = fallback
  end
end

--- A number above `min`, or the default. Sizes that are zero or negative used
--- to reach `window.resolve_size`, which returned nil and silently left the
--- split at its natural size -- a different failure contract from every other
--- option here.
local function enforce_number(merged, key, min, fallback)
  local v = merged[key]
  -- `v ~= v` is the NaN test: it compares false against every bound above.
  if type(v) ~= "number" or v ~= v or v <= min then
    warn(
      "invalid `%s` value %s (expected a number greater than %s), using %s",
      key,
      tostring(v),
      min,
      tostring(fallback)
    )
    merged[key] = fallback
  end
end

--- Merge user options over defaults. May be called multiple times; each call
--- starts from the pristine defaults.
---@param opts table|nil
---@return table merged config
function M.setup(opts)
  opts = opts or {}
  local merged = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)
  validate(opts, M.defaults, merged, "")

  enforce_enum(merged, "split", { "vertical", "horizontal" }, "vertical")
  enforce_enum(merged, "marker_style", { "glyph", "block" }, "glyph")
  enforce_number(merged, "width", 0, M.defaults.width)
  enforce_number(merged, "height", 0, M.defaults.height)

  -- `text_width` is optional, so it falls back to absent -- meaning "wrap to
  -- the live window width" -- rather than to a value.
  local tw = merged.text_width
  if tw ~= nil and (tw ~= tw or tw <= 0) then
    warn("invalid `text_width` value %s (expected a positive number), ignoring it", tostring(tw))
    merged.text_width = nil
  end

  -- The mermaid limits are guards, so a zero or negative value would disable
  -- diagrams entirely by way of a size check -- a confusing way to spell
  -- `elements.mermaid = false`. `validate` has already rejected non-numbers.
  for _, key in ipairs({ "max_nodes", "max_edges" }) do
    local v = merged.mermaid[key]
    if v ~= v or v < 1 or v ~= math.floor(v) then
      warn("invalid `mermaid.%s` value %s (expected a positive integer), using %s", key, tostring(v), tostring(M.defaults.mermaid[key]))
      merged.mermaid[key] = M.defaults.mermaid[key]
    end
  end

  -- The renderer indexes `bullets` by depth and falls back to "-" on a miss, so
  -- an empty or non-string list degrades quietly rather than erroring.
  local bullets = merged.icons.bullets
  local ok = #bullets > 0
  for _, shape in ipairs(bullets) do
    ok = ok and type(shape) == "string"
  end
  if not ok then
    warn("`icons.bullets` must be a non-empty list of strings, using the default")
    merged.icons.bullets = vim.deepcopy(M.defaults.icons.bullets)
  end

  current = merged
  return current
end

---@return table the active configuration
function M.get()
  return current
end

return M
