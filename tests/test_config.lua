-- Config merge and validation, in a child Neovim so that `vim.notify` can be
-- captured and every case starts from a pristine module state.
local eq = MiniTest.expect.equality

local child = MiniTest.new_child_neovim()

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.restart({ "-u", "tests/minit.lua" })
      child.lua([[
        _G.notifications = {}
        vim.notify = function(msg, level)
          table.insert(_G.notifications, { msg = msg, level = level })
        end
      ]])
    end,
    post_once = child.stop,
  },
})

local function setup(lua_table)
  child.lua(("require(\"mdview\").setup(%s)"):format(lua_table))
end

--- Read one dotted path out of the active config.
local function get(path)
  return child.lua_get(("require(\"mdview.config\").get().%s"):format(path))
end

local function notes()
  return child.lua_get("_G.notifications")
end

--- The single warning message, asserting there was exactly one.
local function only_note()
  local n = notes()
  eq(#n, 1)
  eq(n[1].level, child.lua_get("vim.log.levels.WARN"))
  return n[1].msg
end

local function warned(msg, needle)
  eq({ needle, msg:find(needle, 1, true) ~= nil }, { needle, true })
end

---------------------------------------------------------------------------

T["defaults"] = MiniTest.new_set()

T["defaults"]["stand alone when setup() is never called"] = function()
  -- `setup()` is optional, so requiring the plugin must already yield a
  -- complete config -- not an empty table filled in later.
  eq(get("split"), "vertical")
  eq(get("marker_style"), "glyph")
  eq(get("width"), 0.5)
  eq(get("heading.gutter"), 6)
  eq(get("icons.bullets"), { "•", "‣", "·" })
  eq(get("elements.tables"), true)
  eq(#notes(), 0)
end

T["merge"] = MiniTest.new_set()

T["merge"]["a partial table keeps its sibling defaults"] = function()
  setup([[{ heading = { gutter = 3 } }]])
  eq(get("heading.gutter"), 3)
  eq(get("heading.bar"), "█")
  eq(get("heading.bold"), true)
  eq(get("heading.underline_levels"), 2)
  -- and untouched top-level keys survive too
  eq(get("split"), "vertical")
  eq(#notes(), 0)
end

T["merge"]["a second setup starts from the pristine defaults"] = function()
  setup([[{ tables = { zebra = true }, heading = { gutter = 3 } }]])
  eq(get("tables.zebra"), true)
  setup([[{}]])
  eq(get("tables.zebra"), false)
  eq(get("heading.gutter"), 6)
  eq(#notes(), 0)
end

T["merge"]["a list option is replaced, not element-merged"] = function()
  -- `vim.tbl_deep_extend` merges lists index-by-index, so a one-entry list
  -- would otherwise keep the tail of the default one.
  setup([[{ icons = { bullets = { "·" } } }]])
  eq(get("icons.bullets"), { "·" })
  eq(#notes(), 0)
end

T["merge"]["a map option still merges key by key"] = function()
  setup([[{ icons = { checkbox = { checked = "[X]" } } }]])
  eq(get("icons.checkbox"), { unchecked = "[ ]", checked = "[X]" })
  eq(#notes(), 0)
end

T["validation"] = MiniTest.new_set()

T["validation"]["an invalid split warns and falls back to vertical"] = function()
  setup([[{ split = "diagonal" }]])
  warned(only_note(), "invalid `split`")
  eq(get("split"), "vertical")
end

T["validation"]["an unknown top-level option warns and is dropped"] = function()
  setup([[{ marker_syle = "block" }]])
  warned(only_note(), "unknown option `marker_syle`")
  eq(child.lua_get([[require("mdview.config").get().marker_syle == nil]]), true)
  eq(get("marker_style"), "glyph")
end

T["validation"]["an unknown nested option warns with its full path"] = function()
  setup([[{ elements = { headins = false } }]])
  warned(only_note(), "unknown option `elements.headins`")
  eq(child.lua_get([[require("mdview.config").get().elements.headins == nil]]), true)
  eq(get("elements.headings"), true)
end

T["validation"]["a wrong-typed leaf warns and keeps the default"] = function()
  setup([[{ heading = { gutter = "6" } }]])
  warned(only_note(), "option `heading.gutter` expects number, got string")
  eq(get("heading.gutter"), 6)
end

T["validation"]["a wrong-typed table warns and keeps the default"] = function()
  setup([[{ icons = { bullets = "•" } }]])
  warned(only_note(), "option `icons.bullets` expects table, got string")
  eq(get("icons.bullets"), { "•", "‣", "·" })
end

T["validation"]["a bad value is reported once, not twice"] = function()
  -- The structural walk repairs the type, so the value-level check must then
  -- see a valid default and stay quiet.
  setup([[{ split = 5 }]])
  warned(only_note(), "option `split` expects string, got number")
  eq(get("split"), "vertical")
end

T["size"] = MiniTest.new_set()

T["size"]["a fraction and an absolute count are both accepted"] = function()
  setup([[{ width = 0.3, height = 20 }]])
  eq(get("width"), 0.3)
  eq(get("height"), 20)
  eq(#notes(), 0)
end

T["size"]["width = 1 is the full screen, and is accepted silently"] = function()
  -- The <= 1 boundary is the documented overload: 1 is not "one column".
  setup([[{ width = 1 }]])
  eq(get("width"), 1)
  eq(#notes(), 0)
end

T["size"]["a non-positive width warns and falls back"] = function()
  setup([[{ width = 0 }]])
  warned(only_note(), "invalid `width`")
  eq(get("width"), 0.5)
end

T["size"]["a non-numeric width warns and falls back"] = function()
  setup([[{ width = "50%" }]])
  warned(only_note(), "option `width` expects number, got string")
  eq(get("width"), 0.5)
end

T["text_width"] = MiniTest.new_set()

T["text_width"]["is accepted even though it has no default"] = function()
  setup([[{ text_width = 80 }]])
  eq(get("text_width"), 80)
  eq(#notes(), 0)
end

T["text_width"]["defaults to absent, meaning the live window width"] = function()
  eq(child.lua_get([[require("mdview.config").get().text_width == nil]]), true)
end

T["text_width"]["a wrong-typed value warns and is ignored"] = function()
  setup([[{ text_width = "80" }]])
  warned(only_note(), "option `text_width` expects number, got string")
  eq(child.lua_get([[require("mdview.config").get().text_width == nil]]), true)
end

T["text_width"]["a non-positive value warns and is ignored"] = function()
  setup([[{ text_width = 0 }]])
  warned(only_note(), "invalid `text_width`")
  eq(child.lua_get([[require("mdview.config").get().text_width == nil]]), true)
end

T["bullets"] = MiniTest.new_set()

T["bullets"]["an empty list warns and falls back"] = function()
  setup([[{ icons = { bullets = {} } }]])
  warned(only_note(), "`icons.bullets` must be a non-empty list of strings")
  eq(get("icons.bullets"), { "•", "‣", "·" })
end

T["bullets"]["a non-string entry warns and falls back"] = function()
  setup([[{ icons = { bullets = { "•", 7 } } }]])
  warned(only_note(), "`icons.bullets` must be a non-empty list of strings")
  eq(get("icons.bullets"), { "•", "‣", "·" })
end

T["mermaid"] = MiniTest.new_set()

T["mermaid"]["defaults stand alone"] = function()
  eq(get("elements.mermaid"), true)
  eq(get("mermaid.language_label"), true)
  eq(get("mermaid.max_nodes"), 60)
  eq(get("mermaid.max_edges"), 120)
end

T["mermaid"]["a non-positive limit warns and keeps the default"] = function()
  -- Zero would disable diagrams by way of a size check, which is a confusing
  -- way to spell `elements.mermaid = false`.
  setup([[{ mermaid = { max_nodes = 0 } }]])
  warned(only_note(), "invalid `mermaid.max_nodes`")
  eq(get("mermaid.max_nodes"), 60)
end

T["mermaid"]["a fractional limit warns and keeps the default"] = function()
  setup([[{ mermaid = { max_edges = 2.5 } }]])
  warned(only_note(), "invalid `mermaid.max_edges`")
  eq(get("mermaid.max_edges"), 120)
end

T["mermaid"]["a wrong-typed limit is caught by the shared validator"] = function()
  setup([[{ mermaid = { max_nodes = "lots" } }]])
  warned(only_note(), "option `mermaid.max_nodes` expects number, got string")
  eq(get("mermaid.max_nodes"), 60)
end

T["mermaid"]["a valid limit is kept"] = function()
  setup([[{ mermaid = { max_nodes = 10 } }]])
  eq(get("mermaid.max_nodes"), 10)
  eq(get("mermaid.max_edges"), 120)
end

T["tables"] = MiniTest.new_set()

T["tables"]["the column cap defaults to 32 without setup()"] = function()
  eq(get("tables.max_columns"), 32)
  eq(#notes(), 0)
end

T["tables"]["a non-positive column cap warns and keeps the default"] = function()
  -- Zero would send every table down the plain-text path, a confusing way to
  -- spell `elements.tables = false`.
  setup([[{ tables = { max_columns = 0 } }]])
  warned(only_note(), "invalid `tables.max_columns`")
  eq(get("tables.max_columns"), 32)
end

T["tables"]["a fractional column cap warns and keeps the default"] = function()
  setup([[{ tables = { max_columns = 8.5 } }]])
  warned(only_note(), "invalid `tables.max_columns`")
  eq(get("tables.max_columns"), 32)
end

T["tables"]["a wrong-typed column cap is caught by the shared validator"] = function()
  setup([[{ tables = { max_columns = "wide" } }]])
  warned(only_note(), "option `tables.max_columns` expects number, got string")
  eq(get("tables.max_columns"), 32)
end

T["tables"]["a valid column cap is kept"] = function()
  setup([[{ tables = { max_columns = 8 } }]])
  eq(get("tables.max_columns"), 8)
  eq(get("tables.borders"), true)
end

return T
