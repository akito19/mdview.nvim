--- Highlight groups for mdview.nvim.
---
--- INTERNAL module -- but the `Mdview*` GROUP NAMES it defines are public, and
--- colorschemes link to them. Renaming a group is a breaking change; adding
--- one is not. See |mdview-highlights|.
---
--- Four families are defined here:
---
--- 1. Foreground groups, defined with `default = true` so user/colorscheme
---    overrides always win. Links target the first *existing* candidate group
---    so the defaults degrade gracefully on minimal colorschemes; when no
---    candidate exists, plain attributes are used as a last resort.
---
--- 2. Background groups (`*Bg`, `MdviewTableZebra`, `MdviewHeadingUnderline`),
---    which are **computed** by blending a foreground colour into `Normal`'s
---    background at a chosen alpha. These cannot be `default = true` links
---    because the shade has to stay consistent regardless of the colorscheme.
---    If `Normal.bg` cannot be resolved (transparent terminal, no
---    'termguicolors') the groups are cleared instead: backgrounds disappear
---    and the markers alone carry the hierarchy. That reasoning only holds for
---    elements that HAVE another marker -- code blocks and horizontal rules do
---    not, so those two fall back to a link rather than being cleared.
---
--- 3. Computed *foreground* groups (`MdviewBullet1..3`), which dim the bullet
---    glyph with nesting depth. When no colour can be resolved they fall back
---    to a link to their source group, so a bullet is never invisible.
---
--- 4. Marker groups (`*Bar`), which carry the same colour as **both** fg and
---    bg. Under `marker_style = "glyph"` the marker cell holds `█`, which
---    fills its cell, so the foreground is what shows; under
---    `marker_style = "block"` the cell holds a space and the background is
---    what shows. Setting both makes one group serve both styles. Unlike the
---    tint groups these are never cleared: without a resolvable colour they
---    fall back to `reverse` (gui and cterm) so the marker still renders from
---    the terminal's own palette. An invisible marker would silently erase the
---    document hierarchy.
---
--- All families are recomputed on `ColorScheme`.
local M = {}

-- { name, link_candidates, fallback_attrs? }
local defs = {
  { "MdviewH1", { "@markup.heading.1.markdown", "@markup.heading.1", "markdownH1", "Title" } },
  { "MdviewH2", { "@markup.heading.2.markdown", "@markup.heading.2", "markdownH2", "Title" } },
  { "MdviewH3", { "@markup.heading.3.markdown", "@markup.heading.3", "markdownH3", "Title" } },
  { "MdviewH4", { "@markup.heading.4.markdown", "@markup.heading.4", "markdownH4", "Title" } },
  { "MdviewH5", { "@markup.heading.5.markdown", "@markup.heading.5", "markdownH5", "Title" } },
  { "MdviewH6", { "@markup.heading.6.markdown", "@markup.heading.6", "markdownH6", "Title" } },
  -- Applied on top of MdviewH1..H6 so the level colour keeps coming from a
  -- `default = true` link (Neovim cannot attach `bold` to a link).
  { "MdviewHeadingBold", {}, { bold = true } },
  { "MdviewBold", { "@markup.strong" }, { bold = true } },
  { "MdviewItalic", { "@markup.italic" }, { italic = true } },
  { "MdviewBoldItalic", {}, { bold = true, italic = true } },
  { "MdviewStrikethrough", { "@markup.strikethrough" }, { strikethrough = true } },
  { "MdviewCode", { "@markup.raw.markdown_inline", "@markup.raw", "String" } },
  { "MdviewCodeHeader", { "Comment" } },
  { "MdviewCodeLineNr", { "LineNr", "NonText" } },
  { "MdviewLink", { "@markup.link.url", "Underlined" } },
  { "MdviewQuote", { "@markup.quote", "Comment" } },
  { "MdviewBullet", { "@markup.list", "Special" } },
  { "MdviewCheckbox", { "@markup.list", "Special" } },
  { "MdviewTableHead", {}, { bold = true } },
  -- The grid: every `┌ ┬ ┐ ├ ┼ ┤ └ ┴ ┘ ─ │` the table draws.
  { "MdviewTableBorder", { "@punctuation.delimiter", "Comment", "NonText" } },
  -- Column separator when `tables.borders = false` (no horizontal rules).
  { "MdviewTableSep", { "@punctuation.delimiter", "Comment", "NonText" } },
  -- A mermaid diagram. Node borders read as structure, like a table's grid;
  -- edges are the same weight, because the glyph set has only one. `-.->` and
  -- `==>` therefore differ from `-->` by COLOUR alone -- there is no dashed or
  -- heavy box-drawing character to switch to.
  { "MdviewMermaidBox", { "@punctuation.delimiter", "Comment", "NonText" } },
  { "MdviewMermaidLabel", {} },
  { "MdviewMermaidEdge", { "@punctuation.delimiter", "Comment", "NonText" } },
  { "MdviewMermaidEdgeDim", { "NonText", "Comment" } },
  { "MdviewMermaidEdgeStrong", { "@punctuation.delimiter", "Comment", "NonText" }, { bold = true } },
  { "MdviewMermaidEdgeLabel", { "Comment" } },
}

--- { name, source group whose fg is blended, alpha }
-- { name, blend_source, alpha, fallback_when_unresolvable? }
--
-- Most of these may simply vanish when no base background can be resolved: the
-- element they tint keeps another marker (a quote its bars, a heading its bar
-- and bold, a table its box borders, inline code its own foreground group), so
-- only the shading is lost. Two have no such second marker and are given an
-- explicit fallback -- clearing them erases the element itself.
local blend_defs = {
  { "MdviewQuoteBg", "MdviewQuote", 0.10 },
  { "MdviewCodeBg", "Normal", 0.12 }, -- GitHub's inline-code chip
  -- A fenced block's band is its ONLY delimiter: the fences are stripped at
  -- parse time and v3's left bar was deliberately removed. Cleared, a code
  -- block is indistinguishable from an indented paragraph.
  { "MdviewCodeBlock", "Normal", 0.08, { link = "CursorLine" } }, -- GitHub's grey code box
  { "MdviewHeadingUnderline", "Normal", 0.16 }, -- GitHub's h1/h2 border-bottom
  { "MdviewTableHeadBg", "Normal", 0.13 },
  { "MdviewTableZebra", "Normal", 0.05 },
  -- A rule is a blank line and nothing else, so cleared it is indistinguishable
  -- from the blank separator between any two blocks. `Visual` rather than
  -- `CursorLine` so that a divider never reads as a code block.
  { "MdviewRuleBg", "Normal", 0.13, { link = "Visual" } },
}

--- Computed foreground groups: `{ name, source, alpha, fallback link }`.
--- Blending the source colour *towards the background* dims it, so deeper
--- bullets read as quieter without ever changing hue.
local fg_blend_defs = {
  { "MdviewBullet1", "MdviewBullet", 1.00 },
  { "MdviewBullet2", "MdviewBullet", 0.75 },
  { "MdviewBullet3", "MdviewBullet", 0.55 },
}

--- Marker groups: `{ name, source group whose fg becomes fg *and* bg, alpha }`.
---
--- Heading bars use the heading's own foreground at full strength, so the bar
--- is a solid swatch in the heading's colour. Quote and (block-style) bullet
--- markers are dimmer.
local marker_defs = {
  { "MdviewH1Bar", "MdviewH1", 1.00 },
  { "MdviewH2Bar", "MdviewH2", 1.00 },
  { "MdviewH3Bar", "MdviewH3", 1.00 },
  { "MdviewH4Bar", "MdviewH4", 1.00 },
  { "MdviewH5Bar", "MdviewH5", 1.00 },
  { "MdviewH6Bar", "MdviewH6", 1.00 },
  { "MdviewQuoteBar", "MdviewQuote", 0.85 },
  { "MdviewBulletBar1", "MdviewBullet", 0.95 },
  { "MdviewBulletBar2", "MdviewBullet", 0.75 },
  { "MdviewBulletBar3", "MdviewBullet", 0.55 },
}

--- Last-resort marker appearance: swap fg/bg from whatever the terminal is
--- already using, in both 'termguicolors' and cterm modes.
local MARKER_FALLBACK = { reverse = true, cterm = { reverse = true } }

local function first_existing(candidates)
  for _, group in ipairs(candidates) do
    if vim.fn.hlexists(group) == 1 then
      return group
    end
  end
end

--- Effective (link-resolved) attributes of a highlight group.
local function resolved(name)
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
  if ok and type(hl) == "table" then
    return hl
  end
  return {}
end

--- Foreground colour of `source`, falling back to `Normal`'s.
local function source_fg(source)
  local fg = resolved(source).fg
  if type(fg) ~= "number" then
    fg = resolved("Normal").fg
  end
  if type(fg) == "number" then
    return fg
  end
end

--- Blend two 24-bit RGB colours: `alpha` of `fg` over `bg`.
---@param fg integer 0xRRGGBB
---@param bg integer 0xRRGGBB
---@param alpha number 0..1
---@return integer 0xRRGGBB
function M.blend(fg, bg, alpha)
  local function channel(shift)
    local f = math.floor(fg / shift) % 256
    local b = math.floor(bg / shift) % 256
    local v = math.floor(f * alpha + b * (1 - alpha) + 0.5)
    return math.max(0, math.min(255, v))
  end
  return channel(65536) * 65536 + channel(256) * 256 + channel(1)
end

--- Resolve the base background to blend into.
---@return integer|nil nil when backgrounds must be skipped entirely
function M.base_background()
  if not vim.o.termguicolors then
    return nil
  end
  local bg = resolved("Normal").bg
  if type(bg) == "number" then
    return bg
  end
  return nil
end

--- (Re-)compute the blended background and foreground groups.
function M.apply_blends()
  local ok_cfg, config = pcall(require, "mdview.config")
  local cfg = ok_cfg and config.get() or {}
  local enabled = not (cfg.highlights and cfg.highlights.blend == false)
  local base = enabled and M.base_background() or nil

  for _, def in ipairs(blend_defs) do
    local name, source, alpha, fallback = def[1], def[2], def[3], def[4]
    local color
    if base and alpha > 0 then
      local fg = source_fg(source)
      if fg then
        color = M.blend(fg, base, alpha)
      end
    end
    -- No resolvable colour -> clear the group: no background, markers remain.
    -- Unless the element has no other marker, in which case a cleared group
    -- would erase it entirely and the def carries a fallback link instead.
    vim.api.nvim_set_hl(0, name, color and { bg = color } or vim.deepcopy(fallback or {}))
  end

  for _, def in ipairs(fg_blend_defs) do
    local name, source, alpha = def[1], def[2], def[3]
    local color
    if base then
      local fg = source_fg(source)
      if fg then
        color = M.blend(fg, base, alpha)
      end
    end
    -- A bullet is a real glyph: never clear it, link it back to its source.
    vim.api.nvim_set_hl(0, name, color and { fg = color } or { link = source })
  end

  -- `false` (not nil) so a disabled `highlights.blend` forces the fallback
  -- instead of re-resolving the base background.
  M.apply_markers(base or false)
end

--- (Re-)compute the marker (`*Bar`) groups.
---
--- These paint either a `█` glyph or a run of spaces, so they set fg and bg to
--- the same colour and must always end up visible: without a resolvable colour
--- they fall back to `reverse` rather than being cleared.
---@param base integer|false|nil base background; `false` forces the `reverse`
---            fallback, `nil` resolves it from `Normal`
function M.apply_markers(base)
  if base == nil then
    base = M.base_background()
  end
  for _, def in ipairs(marker_defs) do
    local name, source, alpha = def[1], def[2], def[3]
    local color
    if base then
      local fg = source_fg(source)
      if fg then
        color = M.blend(fg, base, alpha)
      end
    end
    vim.api.nvim_set_hl(0, name, color and { fg = color, bg = color } or vim.deepcopy(MARKER_FALLBACK))
  end
end

--- (Re-)apply all highlight definitions.
function M.apply()
  for _, def in ipairs(defs) do
    local name, candidates, attrs = def[1], def[2], def[3]
    local target = first_existing(candidates)
    local hl
    if target then
      hl = { link = target, default = true }
    else
      hl = vim.tbl_extend("force", {}, attrs or { link = "Normal" })
      hl.default = true
    end
    vim.api.nvim_set_hl(0, name, hl)
  end
  M.apply_blends()
end

local did_setup = false

--- Define highlight groups once and keep them alive across `:colorscheme`.
function M.setup()
  if did_setup then
    return
  end
  did_setup = true
  M.apply()
  local group = vim.api.nvim_create_augroup("MdviewHighlights", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = M.apply,
    desc = "Re-apply mdview highlights and recompute blended backgrounds",
  })
end

return M
