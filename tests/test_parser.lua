-- Tests for lua/mdview/parser.lua: markdown string -> IR shape.
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

--- Parse markdown lines in a scratch buffer of the child Neovim.
local function parse(lines)
  child.api.nvim_buf_set_lines(0, 0, -1, true, lines)
  local blocks = child.lua_get([[require("mdview.parser").parse(0)]])
  eq(type(blocks), "table")
  return blocks
end

T["headings"] = MiniTest.new_set()

T["headings"]["parses ATX levels"] = function()
  local blocks = parse({ "# One", "", "## Two", "", "###### Six" })
  eq(#blocks, 3)
  for i, level in ipairs({ 1, 2, 6 }) do
    eq(blocks[i].type, "heading")
    eq(blocks[i].level, level)
  end
  eq(blocks[1].inline[1].text, "One")
  eq(blocks[3].inline[1].text, "Six")
end

T["headings"]["parses setext headings"] = function()
  local blocks = parse({ "First", "=====", "", "Second", "------" })
  eq(blocks[1].type, "heading")
  eq(blocks[1].level, 1)
  eq(blocks[1].inline[1].text, "First")
  eq(blocks[2].level, 2)
end

T["inline"] = MiniTest.new_set()

T["inline"]["extracts emphasis styles"] = function()
  local blocks = parse({ "plain *it* **bo** ***bi*** `co` ~~st~~" })
  local inline = blocks[1].inline
  eq(blocks[1].type, "paragraph")
  eq(inline[1], { text = "plain " })
  eq(inline[2], { text = "it", style = "italic" })
  eq(inline[4], { text = "bo", style = "bold" })
  eq(inline[6], { text = "bi", style = "bold_italic" })
  eq(inline[8], { text = "co", style = "code" })
  eq(inline[10], { text = "st", style = "strikethrough" })
end

T["inline"]["extracts links with url"] = function()
  local blocks = parse({ "see [docs](https://example.com/x) now" })
  local inline = blocks[1].inline
  eq(inline[2].text, "docs")
  eq(inline[2].style, "link")
  eq(inline[2].url, "https://example.com/x")
  eq(inline[3].text, " now")
end

T["inline"]["joins soft line breaks with a space"] = function()
  local blocks = parse({ "first line", "second line" })
  eq(#blocks, 1)
  eq(blocks[1].inline[1].text, "first line second line")
end

T["code blocks"] = MiniTest.new_set()

T["code blocks"]["fenced block keeps language and lines"] = function()
  local blocks = parse({ "```lua", "local x = 1", "return x", "```" })
  eq(blocks[1].type, "code_block")
  eq(blocks[1].lang, "lua")
  eq(blocks[1].lines, { "local x = 1", "return x" })
end

T["code blocks"]["fenced block without language"] = function()
  local blocks = parse({ "```", "text", "```" })
  eq(blocks[1].type, "code_block")
  eq(blocks[1].lang == nil, true)
  eq(blocks[1].lines, { "text" })
end

T["code blocks"]["indented block is dedented"] = function()
  local blocks = parse({ "para", "", "    indented", "      deeper" })
  eq(blocks[2].type, "code_block")
  eq(blocks[2].lines, { "indented", "  deeper" })
end

T["lists"] = MiniTest.new_set()

T["lists"]["nested unordered list carries depth"] = function()
  local blocks = parse({ "- one", "- two", "  - nested", "    - deep" })
  eq(#blocks, 4)
  eq(blocks[1].type, "list_item")
  eq(blocks[1].depth, 0)
  eq(blocks[1].ordered, false)
  eq(blocks[3].depth, 1)
  eq(blocks[3].inline[1].text, "nested")
  eq(blocks[4].depth, 2)
end

T["lists"]["ordered list keeps numbers"] = function()
  local blocks = parse({ "1. first", "2. second", "10. tenth" })
  eq(blocks[1].ordered, true)
  eq(blocks[1].marker, "1.")
  eq(blocks[3].marker, "10.")
  eq(blocks[3].inline[1].text, "tenth")
end

T["lists"]["task markers become checkbox field"] = function()
  local blocks = parse({ "- [ ] todo", "- [x] done" })
  eq(blocks[1].checkbox, "unchecked")
  eq(blocks[1].inline[1].text, "todo")
  eq(blocks[2].checkbox, "checked")
end

T["blockquotes"] = MiniTest.new_set()

T["blockquotes"]["quote depth is tracked"] = function()
  local blocks = parse({ "> quoted", ">", "> > deeper" })
  eq(blocks[1].type, "paragraph")
  eq(blocks[1].quote, 1)
  eq(blocks[1].inline[1].text, "quoted")
  eq(blocks[2].quote, 2)
  eq(blocks[2].inline[1].text, "deeper")
end

T["rules"] = MiniTest.new_set()

T["rules"]["thematic break becomes rule"] = function()
  local blocks = parse({ "a", "", "---", "", "b" })
  eq(blocks[2].type, "rule")
end

T["tables"] = MiniTest.new_set()

T["tables"]["header, alignment and rows"] = function()
  local blocks = parse({
    "| Left | Center | Right |",
    "|:-----|:------:|------:|",
    "| a    | *b*    | c     |",
  })
  local tbl = blocks[1]
  eq(tbl.type, "table")
  eq(#tbl.header, 3)
  eq(tbl.header[1][1].text, "Left")
  eq(tbl.align, { "left", "center", "right" })
  eq(#tbl.rows, 1)
  eq(tbl.rows[1][2][1], { text = "b", style = "italic" })
end

T["fallback"] = MiniTest.new_set()

T["fallback"]["html block is kept as raw text"] = function()
  local blocks = parse({ "<div>", "hi", "</div>" })
  eq(blocks[1].type, "raw")
  eq(blocks[1].lines, { "<div>", "hi", "</div>" })
end

return T
