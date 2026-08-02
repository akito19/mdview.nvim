-- Tests for lua/mdview/highlights.lua: blended background/foreground groups.
-- Runs in a child Neovim so 'termguicolors' and Normal can be mutated freely.
local eq = MiniTest.expect.equality

local child = MiniTest.new_child_neovim()

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.restart({ "-u", "tests/minit.lua" })
    end,
    post_once = child.stop,
  },
})

--- Make heading/Normal colours deterministic, then recompute the blends.
local function blend_with(setup_lua)
  child.lua(([[
    vim.o.termguicolors = true
    vim.api.nvim_set_hl(0, "Normal", { fg = 0xffffff, bg = 0x000000 })
    for i = 1, 6 do
      vim.api.nvim_set_hl(0, "MdviewH" .. i, { fg = 0xffffff })
    end
    vim.api.nvim_set_hl(0, "MdviewQuote", { fg = 0xffffff })
    vim.api.nvim_set_hl(0, "MdviewBullet", { fg = 0xffffff })
    %s
    require("mdview.highlights").apply_blends()
  ]]):format(setup_lua or ""))
end

local function bg_of(group)
  return child.lua_get(('vim.api.nvim_get_hl(0, { name = %q }).bg'):format(group))
end

local function fg_of(group)
  return child.lua_get(('vim.api.nvim_get_hl(0, { name = %q }).fg'):format(group))
end

local function hl_of(group)
  return child.lua_get(('vim.api.nvim_get_hl(0, { name = %q })'):format(group))
end

local function is_empty(group)
  return child.lua_get(('vim.tbl_isempty(vim.api.nvim_get_hl(0, { name = %q }))'):format(group))
end

--- Every group that paints a bar cell -- a `█` glyph under `marker_style =
--- "glyph"`, a background-coloured space under `"block"`.
local MARKERS = {
  "MdviewH1Bar",
  "MdviewH2Bar",
  "MdviewH3Bar",
  "MdviewH4Bar",
  "MdviewH5Bar",
  "MdviewH6Bar",
  "MdviewQuoteBar",
  "MdviewBulletBar1",
  "MdviewBulletBar2",
  "MdviewBulletBar3",
}

--- Every computed background group.
local BACKGROUNDS = {
  "MdviewQuoteBg",
  "MdviewCodeBg",
  "MdviewCodeBlock",
  "MdviewHeadingUnderline",
  "MdviewTableHeadBg",
  "MdviewTableZebra",
  "MdviewRuleBg",
}

--- The backgrounds that may vanish when no base colour resolves, because the
--- element they tint keeps another marker. The two absent from this list --
--- `MdviewCodeBlock` and `MdviewRuleBg` -- are the whole of their element's
--- presentation, so they fall back to a link instead of being cleared.
local CLEARABLE_BACKGROUNDS = {
  "MdviewQuoteBg",
  "MdviewCodeBg",
  "MdviewHeadingUnderline",
  "MdviewTableHeadBg",
  "MdviewTableZebra",
}

--- Backgrounds with no second marker: { group, fallback link }.
local BACKGROUND_FALLBACKS = {
  { "MdviewCodeBlock", "CursorLine" },
  { "MdviewRuleBg", "Visual" },
}

local function link_of(group)
  return child.lua_get(('(vim.api.nvim_get_hl(0, { name = %q }) or {}).link'):format(group))
end

--- A marker group is usable when it carries the same colour as fg and bg (so
--- one group serves both marker styles), or -- when no colour can be resolved
--- -- when it reverses gui and cterm.
local function marker_state(group)
  local hl = hl_of(group)
  if type(hl.bg) == "number" and hl.bg == hl.fg then
    return "colour"
  end
  if hl.reverse == true and type(hl.cterm) == "table" and hl.cterm.reverse == true then
    return "reverse"
  end
  return vim.inspect(hl)
end

local function all(value, n)
  local out = {}
  for _ = 1, n do
    out[#out + 1] = value
  end
  return out
end

T["blend"] = MiniTest.new_set()

T["blend"]["mixes two RGB colours per channel"] = function()
  eq(child.lua_get([[require("mdview.highlights").blend(0xffffff, 0x000000, 0.5)]]), 0x808080)
  eq(child.lua_get([[require("mdview.highlights").blend(0xffffff, 0x000000, 0)]]), 0x000000)
  eq(child.lua_get([[require("mdview.highlights").blend(0xffffff, 0x000000, 1)]]), 0xffffff)
  eq(child.lua_get([[require("mdview.highlights").blend(0xff0000, 0x0000ff, 0.5)]]), 0x800080)
end

T["backgrounds"] = MiniTest.new_set()

T["backgrounds"]["the graduated heading backgrounds are gone"] = function()
  -- v4 removes them: a few percent of alpha between levels is invisible, and
  -- the bar length carries the hierarchy instead.
  blend_with()
  for i = 1, 6 do
    eq({ i, child.lua_get(('vim.fn.hlexists("MdviewH%dBg")'):format(i)) }, { i, 0 })
  end
end

T["backgrounds"]["every computed background is a real colour"] = function()
  blend_with()
  for _, group in ipairs(BACKGROUNDS) do
    eq({ group, type(bg_of(group)) }, { group, "number" })
  end
  -- white over black: the alpha is directly readable as the grey level
  eq(bg_of("MdviewCodeBlock"), 0x141414) -- 0.08
  eq(bg_of("MdviewCodeBg"), 0x1f1f1f) -- 0.12, the inline-code chip
  eq(bg_of("MdviewHeadingUnderline"), 0x292929) -- 0.16, the H1/H2 band
end

T["backgrounds"]["the inline code chip is distinct from the code block band"] = function()
  blend_with()
  eq(bg_of("MdviewCodeBg") ~= bg_of("MdviewCodeBlock"), true)
end

T["bullet foregrounds"] = MiniTest.new_set()

T["bullet foregrounds"]["dim monotonically with depth"] = function()
  blend_with()
  eq(fg_of("MdviewBullet1"), 0xffffff)
  eq(fg_of("MdviewBullet2"), 0xbfbfbf)
  eq(fg_of("MdviewBullet3"), 0x8c8c8c)
end

T["bullet foregrounds"]["fall back to a link when no colour resolves"] = function()
  child.lua([[
    vim.o.termguicolors = false
    require("mdview.highlights").apply()
  ]])
  -- a bullet is a real glyph: never cleared, or it would vanish
  for i = 1, 3 do
    eq({ i, child.lua_get(('vim.api.nvim_get_hl(0, { name = "MdviewBullet%d" }).link'):format(i)) }, {
      i,
      "MdviewBullet",
    })
  end
end

T["marker groups"] = MiniTest.new_set()

T["marker groups"]["heading bars carry the heading colour as fg and bg"] = function()
  blend_with([[
    for i = 1, 6 do
      vim.api.nvim_set_hl(0, "MdviewH" .. i, { fg = 0x102030 * i })
    end
  ]])
  for i = 1, 6 do
    eq({ i, fg_of("MdviewH" .. i .. "Bar") }, { i, 0x102030 * i })
    -- bg too, so `marker_style = "block"` (spaces) works with the same group
    eq({ i, bg_of("MdviewH" .. i .. "Bar") }, { i, 0x102030 * i })
  end
end

T["marker groups"]["quote and bullet markers are dimmer than the source"] = function()
  blend_with()
  eq(fg_of("MdviewQuoteBar") < 0xffffff, true)
  local bullets = { bg_of("MdviewBulletBar1"), bg_of("MdviewBulletBar2"), bg_of("MdviewBulletBar3") }
  for i = 2, 3 do
    eq({ i, bullets[i - 1] > bullets[i] }, { i, true })
  end
  -- the dimmest step is still clearly distinct from the background
  eq(bullets[3] > 0x333333, true)
end

T["marker groups"]["every marker group is defined"] = function()
  blend_with()
  local states = {}
  for _, group in ipairs(MARKERS) do
    states[#states + 1] = marker_state(group)
  end
  eq(states, all("colour", #MARKERS))
end

T["marker groups"]["the removed v3 marker groups are gone"] = function()
  blend_with()
  for _, group in ipairs({ "MdviewQuoteBar1", "MdviewQuoteBar3", "MdviewBulletBar4", "MdviewCodeBarBlock" }) do
    eq({ group, child.lua_get(('vim.fn.hlexists(%q)'):format(group)) }, { group, 0 })
  end
end

T["table groups"] = MiniTest.new_set()

T["table groups"]["MdviewTableBorder is reinstated and overridable"] = function()
  child.lua([[require("mdview.highlights").apply()]])
  -- the grid is back, so the group v2 removed exists again
  eq(child.lua_get([[vim.fn.hlexists("MdviewTableBorder")]]), 1)
  -- `default = true`, so a colorscheme setting it first always wins
  child.lua([[
    vim.api.nvim_set_hl(0, "MdviewTableBorder", { fg = 0x123456 })
    require("mdview.highlights").apply()
  ]])
  eq(fg_of("MdviewTableBorder"), 0x123456)
end

T["graceful degradation"] = MiniTest.new_set()

T["graceful degradation"]["unset Normal.bg skips backgrounds entirely"] = function()
  child.lua([[
    vim.o.termguicolors = true
    vim.api.nvim_set_hl(0, "Normal", { fg = 0xffffff })
    require("mdview.highlights").apply_blends()
  ]])
  eq(child.lua_get([[require("mdview.highlights").base_background()]]), vim.NIL)
  for _, group in ipairs(CLEARABLE_BACKGROUNDS) do
    eq({ group, is_empty(group) }, { group, true })
  end
end

T["graceful degradation"]["no termguicolors skips backgrounds entirely"] = function()
  child.lua([[
    vim.o.termguicolors = false
    vim.api.nvim_set_hl(0, "Normal", { fg = 0xffffff, bg = 0x000000 })
    require("mdview.highlights").apply_blends()
  ]])
  for _, group in ipairs(CLEARABLE_BACKGROUNDS) do
    eq({ group, is_empty(group) }, { group, true })
  end
end

T["graceful degradation"]["code blocks and rules keep a band when nothing resolves"] = function()
  -- These two have no marker besides their background: a code block's fences
  -- are stripped and a rule *is* a blank line, so clearing them would leave a
  -- code block looking like an indented paragraph and a rule like the blank
  -- separator between any two blocks.
  child.lua([[
    vim.o.termguicolors = false
    vim.api.nvim_set_hl(0, "Normal", { fg = 0xffffff, bg = 0x000000 })
    require("mdview.highlights").apply_blends()
  ]])
  for _, pair in ipairs(BACKGROUND_FALLBACKS) do
    eq({ pair[1], is_empty(pair[1]) }, { pair[1], false })
    eq({ pair[1], link_of(pair[1]) }, { pair[1], pair[2] })
  end
end

T["graceful degradation"]["a resolvable base still wins over the fallback"] = function()
  child.lua([[
    vim.o.termguicolors = true
    vim.api.nvim_set_hl(0, "Normal", { fg = 0xc9d1d9, bg = 0x0d1117 })
    require("mdview.highlights").apply()
  ]])
  for _, pair in ipairs(BACKGROUND_FALLBACKS) do
    -- a computed tint, not the degraded link
    eq({ pair[1], link_of(pair[1]) }, { pair[1], vim.NIL })
    eq({ pair[1], type(child.lua_get(('vim.api.nvim_get_hl(0, { name = %q }).bg'):format(pair[1]))) }, { pair[1], "number" })
  end
end

T["graceful degradation"]["the two fallbacks are visually distinct"] = function()
  -- A rule that linked to the same group as a code block would read as one.
  eq(BACKGROUND_FALLBACKS[1][2] ~= BACKGROUND_FALLBACKS[2][2], true)
end

T["graceful degradation"]["foreground groups survive when backgrounds are skipped"] = function()
  child.lua([[
    vim.o.termguicolors = false
    require("mdview.highlights").apply()
  ]])
  local groups = { "MdviewH1", "MdviewHeadingBold", "MdviewQuote", "MdviewTableBorder", "MdviewTableSep", "MdviewCode" }
  for _, group in ipairs(groups) do
    eq({ group, child.lua_get(('vim.fn.hlexists(%q)'):format(group)) }, { group, 1 })
  end
end

T["graceful degradation"]["markers fall back to reverse without termguicolors"] = function()
  child.lua([[
    vim.o.termguicolors = false
    vim.api.nvim_set_hl(0, "Normal", { fg = 0xffffff, bg = 0x000000 })
    require("mdview.highlights").apply()
  ]])
  -- an uncoloured marker cell would silently erase the hierarchy, so the
  -- markers reverse instead of being cleared
  for _, group in ipairs(MARKERS) do
    eq({ group, marker_state(group) }, { group, "reverse" })
  end
end

T["graceful degradation"]["markers fall back to reverse when Normal.bg is unset"] = function()
  child.lua([[
    vim.o.termguicolors = true
    vim.api.nvim_set_hl(0, "Normal", { fg = 0xffffff })
    require("mdview.highlights").apply_blends()
  ]])
  for _, group in ipairs(MARKERS) do
    eq({ group, marker_state(group) }, { group, "reverse" })
  end
end

T["config"] = MiniTest.new_set()

T["config"]["highlights.blend = false skips the computation"] = function()
  blend_with([[require("mdview.config").setup({ highlights = { blend = false } })]])
  eq(is_empty("MdviewTableZebra"), true)
  eq(is_empty("MdviewQuoteBg"), true)
end

T["config"]["highlights.blend = false still delimits code blocks and rules"] = function()
  -- Turning the tints off is a request for fewer computed colours, not for a
  -- code block that reads as a paragraph.
  blend_with([[require("mdview.config").setup({ highlights = { blend = false } })]])
  for _, pair in ipairs(BACKGROUND_FALLBACKS) do
    eq({ pair[1], link_of(pair[1]) }, { pair[1], pair[2] })
  end
end

T["config"]["highlights.blend = false still leaves markers visible"] = function()
  blend_with([[require("mdview.config").setup({ highlights = { blend = false } })]])
  for _, group in ipairs(MARKERS) do
    eq({ group, marker_state(group) }, { group, "reverse" })
  end
end

T["colorscheme"] = MiniTest.new_set()

T["colorscheme"]["blends are recomputed on ColorScheme"] = function()
  child.lua([[
    vim.o.termguicolors = true
    require("mdview.highlights").setup()
    vim.api.nvim_set_hl(0, "Normal", { fg = 0xffffff, bg = 0x000000 })
    for i = 1, 6 do vim.api.nvim_set_hl(0, "MdviewH" .. i, { fg = 0xffffff }) end
    vim.api.nvim_exec_autocmds("ColorScheme", {})
  ]])
  eq(bg_of("MdviewHeadingUnderline"), 0x292929)
  eq(fg_of("MdviewH1Bar"), 0xffffff)
end

return T
