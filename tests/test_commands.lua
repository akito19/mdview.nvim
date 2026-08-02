-- End-to-end command tests in a child Neovim: window lifecycle, autocmds.
local eq = MiniTest.expect.equality

local child = MiniTest.new_child_neovim()

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.restart({ "-u", "tests/minit.lua" })
      -- Capture notifications for assertions.
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

local function write_md(lines)
  local path = child.fn.tempname() .. ".md"
  child.fn.writefile(lines, path)
  return path
end

local function edit_md(lines)
  local path = write_md(lines)
  child.cmd("edit " .. child.fn.fnameescape(path))
  eq(child.bo.filetype, "markdown")
  return path
end

local function win_count()
  return child.lua_get("#vim.api.nvim_list_wins()")
end

--- Buffer handles of all previews (name starts with mdview://).
local function preview_bufs()
  return child.lua_get([[vim.tbl_filter(function(b)
    return vim.api.nvim_buf_get_name(b):find("^mdview://") ~= nil
  end, vim.api.nvim_list_bufs())]])
end

local function preview_lines(buf)
  return child.api.nvim_buf_get_lines(buf, 0, -1, true)
end

--- Move the cursor into the preview window. `:MdView` deliberately keeps focus
--- on the source, so nothing reaches the preview side of a session by accident.
local function focus_preview()
  child.lua([[
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w)):find("^mdview://") then
        vim.api.nvim_set_current_win(w)
        return
      end
    end
    error("no preview window is open")
  ]])
end

local function notifications()
  return child.lua_get("_G.notifications")
end

T[":MdView"] = MiniTest.new_set()

T[":MdView"]["opens a vertical preview and keeps focus"] = function()
  edit_md({ "# Hello" })
  eq(win_count(), 1)
  child.cmd("MdView")
  eq(win_count(), 2)
  -- vertical split -> windows laid out in a row
  eq(child.fn.winlayout()[1], "row")
  -- focus stays in the source window
  eq(child.api.nvim_buf_get_name(child.api.nvim_win_get_buf(0)):find("^mdview://") == nil, true)
  -- preview contains the rendered heading (marker stripped, weight bar added)
  local pbufs = preview_bufs()
  eq(#pbufs, 1)
  eq(preview_lines(pbufs[1]), { "█       Hello", "", "" })
end

T[":MdView"]["horizontal argument overrides split direction"] = function()
  edit_md({ "# Hi" })
  child.cmd("MdView horizontal")
  eq(win_count(), 2)
  eq(child.fn.winlayout()[1], "col")
end

T[":MdView"]["invalid argument warns and does nothing"] = function()
  edit_md({ "# Hi" })
  child.cmd("MdView diagonal")
  eq(win_count(), 1)
  local notes = child.lua_get("_G.notifications")
  eq(#notes, 1)
  eq(notes[1].msg:find("invalid direction") ~= nil, true)
end

T[":MdView"]["warns on non-markdown buffer"] = function()
  child.cmd("enew")
  child.cmd("MdView")
  eq(win_count(), 1)
  local notes = child.lua_get("_G.notifications")
  eq(#notes, 1)
  eq(notes[1].msg, "mdview: current buffer is not a markdown buffer")
  eq(notes[1].level, child.lua_get("vim.log.levels.WARN"))
end

T[":MdView"]["re-running re-renders without opening a second window"] = function()
  edit_md({ "# One" })
  child.cmd("MdView")
  child.cmd("MdView")
  eq(win_count(), 2)
  eq(#preview_bufs(), 1)
end

T["auto re-render"] = MiniTest.new_set()

T["auto re-render"][":w updates the preview"] = function()
  edit_md({ "# Before" })
  child.cmd("MdView")
  local pbuf = preview_bufs()[1]
  eq(preview_lines(pbuf)[1], "█       Before")
  child.api.nvim_buf_set_lines(0, 0, -1, true, { "# After", "", "new *text*" })
  child.cmd("write")
  local lines = preview_lines(pbuf)
  eq(lines[1], "█       After")
  eq(lines[4], "new text")
end

T["wrapping"] = MiniTest.new_set()

--- Window handle of the (single) preview window.
local function preview_win()
  return child.lua_get([[ (function()
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w)):find("^mdview://") then
        return w
      end
    end
  end)() ]])
end

T["wrapping"]["the preview window is always nowrap and scrolls smoothly"] = function()
  edit_md({ "# Hi" })
  child.cmd("MdView")
  local win = preview_win()
  -- 'wrap' is window-local, so it could not spare tables; the renderer wraps.
  eq(child.lua_get("vim.wo[" .. win .. "].wrap"), false)
  eq(child.lua_get("vim.wo[" .. win .. "].sidescrolloff"), 0)
  eq(child.lua_get("vim.o.sidescroll"), 1)
end

T["wrapping"]["prose reflows to the preview width, tables do not"] = function()
  local prose = "The quick brown fox jumps over the lazy dog and then keeps on running for quite a while longer."
  edit_md({ prose, "", "| a | b |", "|---|---|", "| " .. string.rep("x", 60) .. " | y |" })
  child.cmd("MdView")
  local win = preview_win()
  child.api.nvim_win_set_width(win, 40)
  child.cmd("MdView") -- re-render at the new width
  local lines = preview_lines(preview_bufs()[1])
  local prose_lines, wide = 0, 0
  for _, l in ipairs(lines) do
    if l:find("fox") or l:find("running") then
      prose_lines = prose_lines + 1
    end
    if child.fn.strdisplaywidth(l) > 40 then
      wide = wide + 1
    end
  end
  eq(prose_lines > 1, true) -- the paragraph was split
  eq(wide > 0, true) -- the table still runs off the right edge
end

T["wrapping"]["the grid table renders with box-drawing borders"] = function()
  edit_md({ "| a | b |", "|---|---|", "| 1 | 2 |" })
  child.cmd("MdView")
  eq(preview_lines(preview_bufs()[1]), {
    "  ┌───┬───┐",
    "  │ a │ b │",
    "  ├───┼───┤",
    "  │ 1 │ 2 │",
    "  └───┴───┘",
  })
end

T["wrapping"]["resizing the preview reflows it"] = function()
  edit_md({ "The quick brown fox jumps over the lazy dog and keeps running for a good while yet." })
  child.cmd("MdView")
  local before = preview_lines(preview_bufs()[1])
  -- narrowing the preview fires WinResized, which reflows the paragraph
  child.api.nvim_win_set_width(preview_win(), 24)
  child.cmd("doautocmd WinResized")
  local after = preview_lines(preview_bufs()[1])
  eq(#after > #before, true)
  for _, l in ipairs(after) do
    eq({ l, child.fn.strdisplaywidth(l) <= 24 }, { l, true })
  end
end

T["wrapping"]["a resize that leaves the width alone costs nothing"] = function()
  edit_md({ "The quick brown fox jumps over the lazy dog and keeps running for a good while yet." })
  child.cmd("MdView")
  local src = child.api.nvim_get_current_buf()
  -- the width is compared against the one used for the last render, so a
  -- resize elsewhere in the tab page never re-renders
  eq(child.lua_get("require('mdview.window').on_resize(" .. src .. ")"), false)
  child.cmd("doautocmd WinResized")
  eq(child.lua_get("require('mdview.window').on_resize(" .. src .. ")"), false)
  eq(child.lua_get("require('mdview.window').is_open(" .. src .. ")"), true)
end

T["cleanup"] = MiniTest.new_set()

T["cleanup"]["manual close of the preview window deregisters autocmds"] = function()
  edit_md({ "# Hi" })
  child.cmd("MdView")
  eq(win_count(), 2)
  local src_buf = child.api.nvim_get_current_buf()
  -- close the preview window manually (equivalent of :q in it)
  child.lua([[
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      local b = vim.api.nvim_win_get_buf(w)
      if vim.api.nvim_buf_get_name(b):find("^mdview://") then
        vim.api.nvim_win_close(w, true)
      end
    end
  ]])
  eq(win_count(), 1)
  -- session and augroup are gone
  eq(child.lua_get("require('mdview.window').is_open(" .. src_buf .. ")"), false)
  eq(
    child.lua_get("select(1, pcall(vim.api.nvim_get_autocmds, { group = 'MdviewSession" .. src_buf .. "' }))"),
    false
  )
  -- a later :w must not raise
  child.cmd("write")
  eq(child.lua_get("#_G.notifications"), 0)
end

T["cleanup"][":MdViewClose closes the preview"] = function()
  edit_md({ "# Hi" })
  child.cmd("MdView")
  eq(win_count(), 2)
  child.cmd("MdViewClose")
  eq(win_count(), 1)
  eq(#preview_bufs(), 0)
end

T["cleanup"]["wiping the source buffer closes the preview"] = function()
  edit_md({ "# Hi" })
  child.cmd("MdView")
  eq(win_count(), 2)
  child.cmd("bwipeout!")
  eq(win_count(), 1)
end

T[":MdViewToggle"] = MiniTest.new_set()

T[":MdViewToggle"]["toggles open and closed"] = function()
  edit_md({ "# Hi" })
  child.cmd("MdViewToggle")
  eq(win_count(), 2)
  child.cmd("MdViewToggle")
  eq(win_count(), 1)
  child.cmd("MdViewToggle")
  eq(win_count(), 2)
end

-- `:MdView` keeps focus on the source window, so every test above drives the
-- session from that side and the `sess.preview_buf == buf` branch of
-- `session_for` never runs. These close from the other end.
T["from the preview side"] = MiniTest.new_set()

T["from the preview side"][":MdViewClose closes the session"] = function()
  edit_md({ "# Hi" })
  child.cmd("MdView")
  focus_preview()
  child.cmd("MdViewClose")
  eq(win_count(), 1)
  eq(#preview_bufs(), 0)
end

T["from the preview side"][":MdViewToggle closes the session"] = function()
  edit_md({ "# Hi" })
  child.cmd("MdView")
  focus_preview()
  child.cmd("MdViewToggle")
  eq(win_count(), 1)
  eq(#preview_bufs(), 0)
end

T["from the preview side"]["is_open() answers for the preview buffer too"] = function()
  local src = edit_md({ "# Hi" })
  eq(src ~= nil, true)
  child.cmd("MdView")
  eq(child.lua_get([[require("mdview").is_open()]]), true) -- from the source
  focus_preview()
  eq(child.lua_get([[require("mdview").is_open()]]), true) -- and from the preview
  child.cmd("MdViewClose")
  eq(child.lua_get([[require("mdview").is_open()]]), false)
end

T["public API"] = MiniTest.new_set()

T["public API"]["setup() returns the merged config"] = function()
  eq(child.lua_get([[require("mdview").setup({ heading = { gutter = 4 } }).heading.gutter]]), 4)
  -- and it really is the active one, not a detached copy
  eq(child.lua_get([[require("mdview").setup({}) == require("mdview.config").get()]]), true)
end

T["public API"]["open() reports whether it opened anything"] = function()
  edit_md({ "# Hi" })
  eq(child.lua_get([[require("mdview").open()]]), true)
  child.cmd("enew")
  eq(child.lua_get([[require("mdview").open()]]), false) -- not a markdown buffer
end

T["public API"]["close() reports whether it closed anything"] = function()
  edit_md({ "# Hi" })
  child.cmd("MdView")
  eq(child.lua_get([[require("mdview").close()]]), true)
  eq(child.lua_get([[require("mdview").close()]]), false)
end

T["public API"]["toggle() reports whether the preview is open afterwards"] = function()
  edit_md({ "# Hi" })
  eq(child.lua_get([[require("mdview").toggle()]]), true)
  eq(child.lua_get([[require("mdview").toggle()]]), false)
  eq(child.lua_get([[require("mdview").toggle()]]), true)
end

T["no session"] = MiniTest.new_set()

T["no session"][":MdViewClose says so instead of doing nothing quietly"] = function()
  edit_md({ "# Hi" })
  child.cmd("MdViewClose") -- never opened
  local notes = notifications()
  eq(#notes, 1)
  eq(notes[1].msg, "mdview: no preview open for this buffer")
  eq(notes[1].level, child.lua_get("vim.log.levels.INFO"))
  eq(win_count(), 1)
end

T["no session"]["a parse failure is reported at ERROR"] = function()
  edit_md({ "# Hi" })
  child.cmd("MdView")
  child.lua([[
    _G.notifications = {}
    local parser = require("mdview.parser")
    parser.parse = function() return nil, "boom" end
  ]])
  child.cmd("write") -- BufWritePost re-renders through the stubbed parser
  local notes = notifications()
  eq(#notes, 1)
  eq(notes[1].msg, "mdview: boom")
  eq(notes[1].level, child.lua_get("vim.log.levels.ERROR"))
end

T["global options"] = MiniTest.new_set()

T["global options"]["sidescroll is handed back when the last preview closes"] = function()
  -- Set it explicitly rather than relying on the default: Neovim 0.12 already
  -- ships 1, so on that version the nudge is a no-op and the test would prove
  -- nothing.
  child.lua("vim.o.sidescroll = 0")
  edit_md({ "# Hi" })
  child.cmd("MdView")
  eq(child.lua_get("vim.o.sidescroll"), 1)
  child.cmd("MdViewClose")
  eq(child.lua_get("vim.o.sidescroll"), 0)
end

T["global options"]["a sidescroll the user chose is never touched"] = function()
  child.lua("vim.o.sidescroll = 5")
  edit_md({ "# Hi" })
  child.cmd("MdView")
  eq(child.lua_get("vim.o.sidescroll"), 5)
  child.cmd("MdViewClose")
  eq(child.lua_get("vim.o.sidescroll"), 5)
end

T["global options"]["the last close hands it back, not the first"] = function()
  child.lua("vim.o.sidescroll = 0")
  local a = edit_md({ "# A" })
  child.cmd("MdView")
  local b = edit_md({ "# B" })
  child.cmd("MdView")
  eq({ a ~= b, child.lua_get("vim.o.sidescroll") }, { true, 1 })
  child.cmd("MdViewClose")
  eq(child.lua_get("vim.o.sidescroll"), 1) -- one session still open
  child.cmd("edit " .. child.fn.fnameescape(a))
  child.cmd("MdViewClose")
  eq(child.lua_get("vim.o.sidescroll"), 0)
end

T["multiple buffers"] = MiniTest.new_set()

T["multiple buffers"]["each source owns an independent preview"] = function()
  edit_md({ "# Doc A" })
  child.cmd("MdView")
  local path_b = write_md({ "# Doc B" })
  child.cmd("split " .. child.fn.fnameescape(path_b))
  child.cmd("MdView")
  eq(win_count(), 4)
  local pbufs = preview_bufs()
  eq(#pbufs, 2)
  local firsts = { preview_lines(pbufs[1])[1], preview_lines(pbufs[2])[1] }
  table.sort(firsts)
  eq(firsts, { "█       Doc A", "█       Doc B" })
  -- closing the current (Doc B) preview leaves Doc A's intact
  child.cmd("MdViewClose")
  eq(win_count(), 3)
  eq(#preview_bufs(), 1)
end

T["config"] = MiniTest.new_set()

T["config"]["the default glyph style renders real markers"] = function()
  edit_md({ "# Hi", "", "- a", "", "> q" })
  child.cmd("MdView")
  eq(preview_lines(preview_bufs()[1]), { "█       Hi", "", "", "  • a", "", "█ q" })
end

T["config"]["marker_style = block switches the whole document over"] = function()
  edit_md({ "# Hi", "", "- a", "", "> q" })
  child.lua([[require("mdview").setup({ marker_style = "block" })]])
  child.cmd("MdView")
  -- every marker cell is an ordinary space carrying a background highlight
  eq(preview_lines(preview_bufs()[1]), { "        Hi", "", "", "    a", "", "  q" })
end

T["config"]["an invalid marker_style warns and falls back to glyph"] = function()
  child.lua([[require("mdview").setup({ marker_style = "sparkle" })]])
  local notes = child.lua_get("_G.notifications")
  eq(#notes, 1)
  eq(notes[1].msg:find("invalid `marker_style`") ~= nil, true)
  eq(child.lua_get([[require("mdview.config").get().marker_style]]), "glyph")
end

T["config"]["a shortened bullet list shortens the depth cycle"] = function()
  -- Through `setup()`, not by poking the config table: `tbl_deep_extend` merges
  -- lists index-by-index, so before the list-replacement fix depth 2 kept the
  -- default `‣` and only depths 1 and 3 followed the user.
  edit_md({ "- a", "  - b", "    - c" })
  child.lua([[require("mdview").setup({ icons = { bullets = { "·" } } })]])
  child.cmd("MdView")
  eq(preview_lines(preview_bufs()[1]), { "  · a", "    · b", "      · c" })
end

T["decorations"] = MiniTest.new_set()

T["decorations"]["extmarks are applied, including code-block syntax"] = function()
  edit_md({ "# T", "", "**bold**", "", "```lua", "local x = 1", "```" })
  child.cmd("MdView")
  local pbuf = preview_bufs()[1]
  local counts = child.lua_get(([[ (function()
    local ns = vim.api.nvim_get_namespaces()
    return {
      main = #vim.api.nvim_buf_get_extmarks(%d, ns.mdview, 0, -1, {}),
      code = #vim.api.nvim_buf_get_extmarks(%d, ns.mdview_code, 0, -1, {}),
    }
  end)() ]]):format(pbuf, pbuf))
  eq(counts.main > 0, true)
  eq(counts.code > 0, true)
end

T["decorations"]["code highlights never reach into the left bar"] = function()
  -- A multi-line string used to be one multi-row extmark, which would have
  -- covered the rendered bar prefix of the continuation lines.
  edit_md({ "```lua", "local s = [[", "one", "two]]", "print(s)", "```" })
  child.cmd("MdView")
  local pbuf = preview_bufs()[1]
  local marks = child.lua_get(([[ (function()
    local ns = vim.api.nvim_get_namespaces()
    local out = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(%d, ns.mdview_code, 0, -1, { details = true })) do
      out[#out + 1] = { row = m[2], col = m[3], end_row = m[4].end_row, end_col = m[4].end_col }
    end
    return out
  end)() ]]):format(pbuf))
  eq(#marks > 0, true)
  -- v4 drops the left bar: code text starts at the 2-cell content indent
  for _, m in ipairs(marks) do
    eq({ m.col >= 2, m.end_row == m.row }, { true, true })
  end
end

T["decorations"]["heading bars form a left-aligned staircase"] = function()
  edit_md({ "# One", "", "## Two", "", "###### Six" })
  child.cmd("MdView")
  local pbuf = preview_bufs()[1]
  local bars = child.lua_get(([[ (function()
    local ns = vim.api.nvim_get_namespaces()
    local out = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(%d, ns.mdview, 0, -1, { details = true })) do
      if type(m[4].hl_group) == "string" and m[4].hl_group:match("^MdviewH%%dBar$") then
        out[#out + 1] = { group = m[4].hl_group, col = m[3], end_col = m[4].end_col }
      end
    end
    return out
  end)() ]]):format(pbuf))
  eq(#bars, 3)
  -- every bar starts at column 0 ("█" is 3 bytes, so 1/2/6 cells = 3/6/18)
  eq({ bars[1].group, bars[1].col, bars[1].end_col }, { "MdviewH1Bar", 0, 3 })
  eq({ bars[2].group, bars[2].col, bars[2].end_col }, { "MdviewH2Bar", 0, 6 })
  eq({ bars[3].group, bars[3].col, bars[3].end_col }, { "MdviewH6Bar", 0, 18 })
  eq(preview_lines(pbuf), {
    "█       One",
    "",
    "",
    "██      Two",
    "",
    "",
    "██████  Six",
  })
end

T["decorations"]["H1 gets a computed underline band, H3 does not"] = function()
  edit_md({ "# Title", "", "### Sub" })
  child.cmd("MdView")
  child.lua([[
    vim.o.termguicolors = true
    vim.api.nvim_set_hl(0, "Normal", { fg = 0xffffff, bg = 0x000000 })
    require("mdview.highlights").apply()
  ]])
  eq(child.lua_get([[type(vim.api.nvim_get_hl(0, { name = "MdviewHeadingUnderline" }).bg)]]), "number")
  local pbuf = preview_bufs()[1]
  local groups = child.lua_get(([[ (function()
    local ns = vim.api.nvim_get_namespaces()
    local out = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(%d, ns.mdview, 0, -1, { details = true })) do
      if m[4].line_hl_group then out[#out + 1] = m[4].line_hl_group end
    end
    return out
  end)() ]]):format(pbuf))
  eq(groups, { "MdviewHeadingUnderline" })
end

return T
