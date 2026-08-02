--- Session management: scratch buffer, split window, autocmds, decorations.
---
--- INTERNAL. The supported surface is `require("mdview")` -- see init.lua.
--- Nothing here is contract; signatures change without notice.
local api = vim.api

local M = {}

-- [src_buf] = { preview_buf, preview_win, direction, augroup }
local sessions = {}

local ns = api.nvim_create_namespace("mdview")
local ns_code = api.nvim_create_namespace("mdview_code")

-- 'sidescroll' is global-only, so opening a preview would otherwise change
-- horizontal scrolling for every window in the session, permanently. Hold the
-- value we displaced until the last session closes.
local SIDESCROLL_NUDGE = 1
local sidescroll_saved = nil

local function restore_sidescroll()
  if next(sessions) ~= nil or sidescroll_saved == nil then
    return
  end
  -- Only take it back if it is still the value we set: the user may have
  -- picked their own while a preview was open, and that choice wins.
  if vim.o.sidescroll == SIDESCROLL_NUDGE then
    vim.o.sidescroll = sidescroll_saved
  end
  sidescroll_saved = nil
end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function resolve_size(value, total)
  if type(value) ~= "number" or value <= 0 then
    return nil
  end
  if value <= 1 then
    return math.floor(total * value)
  end
  return math.floor(value)
end

local function preview_name(src_buf)
  local name = api.nvim_buf_get_name(src_buf)
  if name == "" then
    name = "[No Name] (" .. src_buf .. ")"
  end
  return "mdview://" .. name
end

--- Find the session a buffer belongs to (as source or preview).
---@return integer|nil src_buf, table|nil session
function M.session_for(buf)
  if sessions[buf] then
    return buf, sessions[buf]
  end
  for src, sess in pairs(sessions) do
    if sess.preview_buf == buf then
      return src, sess
    end
  end
end

function M.is_open(buf)
  return M.session_for(buf) ~= nil
end

---------------------------------------------------------------------------
-- Decorations
---------------------------------------------------------------------------

--- Apply tree-sitter highlighting for one fenced code block region.
local function highlight_code(buf, dec)
  local lang = vim.treesitter.language.get_lang(dec.lang) or dec.lang
  if not pcall(vim.treesitter.language.add, lang) then
    return
  end
  local text = table.concat(dec.lines, "\n")
  local ok_parser, parser = pcall(vim.treesitter.get_string_parser, text, lang)
  if not ok_parser or not parser then
    return
  end
  local ok_query, query = pcall(vim.treesitter.query.get, lang, "highlights")
  if not ok_query or not query then
    return
  end
  local ok_parse, trees = pcall(parser.parse, parser, true)
  if not ok_parse or not trees or not trees[1] then
    return
  end
  local root = trees[1]:root()
  local offset = dec.col_offset
  for id, node in query:iter_captures(root, text, 0, -1) do
    local name = query.captures[id]
    if not vim.startswith(name, "_") then
      local sr, sc, er, ec = node:range()
      -- One extmark per source row. A single multi-row extmark would also
      -- cover the rendered left bar / gutter of the intermediate lines,
      -- which must keep their own highlight.
      for row = sr, er do
        local src_line = dec.lines[row + 1] or ""
        local col_start = (row == sr) and sc or 0
        local col_end = (row == er) and ec or #src_line
        if col_end > col_start then
          pcall(api.nvim_buf_set_extmark, buf, ns_code, dec.row + row, col_start + offset, {
            end_row = dec.row + row,
            end_col = col_end + offset,
            hl_group = "@" .. name .. "." .. lang,
            priority = 120,
          })
        end
      end
    end
  end
end

local function apply_decoration(buf, dec, cfg)
  if dec.kind == "hl" then
    pcall(api.nvim_buf_set_extmark, buf, ns, dec.line, dec.col_start, {
      end_col = dec.col_end,
      hl_group = dec.group,
      priority = dec.priority or 100,
    })
  elseif dec.kind == "line_hl" then
    pcall(api.nvim_buf_set_extmark, buf, ns, dec.line, 0, {
      line_hl_group = dec.group,
      priority = dec.priority or 90,
    })
  elseif dec.kind == "virt_text" then
    pcall(api.nvim_buf_set_extmark, buf, ns, dec.line, 0, {
      virt_text = { { dec.text, dec.group } },
      virt_text_pos = dec.pos or "right_align",
    })
  elseif dec.kind == "code" then
    if cfg.code_block_syntax then
      highlight_code(buf, dec)
    end
  end
end

---------------------------------------------------------------------------
-- Render
---------------------------------------------------------------------------

--- Current text width of a session's preview window, or nil when it is gone.
---
--- 'number', 'signcolumn' and 'foldcolumn' are all off in the preview, so the
--- window width *is* the text width.
local function preview_width(sess)
  if sess.preview_win and api.nvim_win_is_valid(sess.preview_win) then
    return api.nvim_win_get_width(sess.preview_win)
  end
end

--- Re-parse the source buffer and refresh the preview contents.
function M.render(src_buf)
  local sess = sessions[src_buf]
  if not sess or not api.nvim_buf_is_valid(sess.preview_buf) then
    return
  end
  local blocks, err = require("mdview.parser").parse(src_buf)
  if not blocks then
    vim.notify("mdview: " .. (err or "failed to parse buffer"), vim.log.levels.ERROR)
    return
  end
  local cfg = require("mdview.config").get()
  local win_valid = api.nvim_win_is_valid(sess.preview_win)
  -- The window is 'nowrap', so the renderer hard-wraps body text itself and
  -- needs the live window width. Remember it: a later resize re-renders only
  -- when this number actually changed.
  local width = preview_width(sess)
  sess.width = width
  local result = require("mdview.renderer").render(blocks, cfg, { width = width })

  -- Preserve the preview scroll position across re-renders.
  local view
  if win_valid then
    view = api.nvim_win_call(sess.preview_win, vim.fn.winsaveview)
  end

  local buf = sess.preview_buf
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, true, result.lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false

  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  api.nvim_buf_clear_namespace(buf, ns_code, 0, -1)
  for _, dec in ipairs(result.decorations) do
    apply_decoration(buf, dec, cfg)
  end

  if view then
    api.nvim_win_call(sess.preview_win, function()
      pcall(vim.fn.winrestview, view)
    end)
  end
end

--- Re-render `src_buf`'s preview only if its width changed since the last one.
---@return boolean re-rendered
function M.on_resize(src_buf)
  local sess = sessions[src_buf]
  if not sess then
    return false
  end
  local width = preview_width(sess)
  if width == nil or width == sess.width then
    return false
  end
  M.render(src_buf)
  return true
end

---------------------------------------------------------------------------
-- Open / close
---------------------------------------------------------------------------

--- Open a preview for `src_buf` (or just re-render if one is already open).
---@param src_buf integer
---@param direction string "vertical" | "horizontal"
function M.open(src_buf, direction)
  local sess = sessions[src_buf]
  if sess and api.nvim_win_is_valid(sess.preview_win) then
    M.render(src_buf)
    return
  end
  if sess then
    M.close(src_buf) -- stale session; rebuild from scratch
  end

  local cfg = require("mdview.config").get()

  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "mdview"
  pcall(api.nvim_buf_set_name, buf, preview_name(src_buf))

  local win = api.nvim_open_win(buf, false, {
    split = direction == "horizontal" and "below" or "right",
    win = 0,
  })
  if direction == "horizontal" then
    local height = resolve_size(cfg.height, vim.o.lines)
    if height then
      api.nvim_win_set_height(win, height)
    end
  else
    local width = resolve_size(cfg.width, vim.o.columns)
    if width then
      api.nvim_win_set_width(win, width)
    end
  end

  local wo = vim.wo[win]
  -- Always 'nowrap': 'wrap' is window-local, so it could not reflow prose
  -- while leaving tables and code blocks intact. The renderer wraps body text
  -- instead (config `wrap`), and the wide blocks scroll sideways -- smoothly,
  -- and all the way back to column 0.
  wo.wrap = false
  wo.linebreak = false
  -- Reach column 0 again when scrolling back left.
  wo.sidescrolloff = 0
  -- 'sidescroll' is global-only. A value of 0 jumps half a screen at a time,
  -- which is jarring in a horizontally scrolling preview -- so nudge it to 1
  -- (smooth), but only from 0, which is the one value nobody chooses on
  -- purpose. Neovim 0.12 already defaults to 1, so this is a no-op there and
  -- only fires on 0.10/0.11. Remember what we displaced: a global that a
  -- preview sets has to come back. See `restore_sidescroll`.
  if vim.o.sidescroll == 0 then
    if sidescroll_saved == nil then
      sidescroll_saved = vim.o.sidescroll
    end
    vim.o.sidescroll = SIDESCROLL_NUDGE
  end
  wo.number = false
  wo.relativenumber = false
  wo.signcolumn = "no"
  wo.foldcolumn = "0"
  wo.foldenable = false
  wo.spell = false
  wo.list = false
  wo.cursorline = false
  wo.colorcolumn = ""

  local augroup = api.nvim_create_augroup("MdviewSession" .. src_buf, { clear = true })
  sessions[src_buf] = {
    preview_buf = buf,
    preview_win = win,
    direction = direction,
    augroup = augroup,
  }

  api.nvim_create_autocmd("BufWritePost", {
    group = augroup,
    buffer = src_buf,
    callback = function()
      M.render(src_buf)
    end,
    desc = "mdview: re-render preview on save",
  })
  api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
    group = augroup,
    buffer = src_buf,
    callback = function()
      M.close(src_buf)
    end,
    desc = "mdview: close preview when source buffer goes away",
  })
  api.nvim_create_autocmd("WinClosed", {
    group = augroup,
    pattern = tostring(win),
    callback = function()
      M.close(src_buf)
    end,
    desc = "mdview: clean up session when preview window is closed",
  })
  -- The wrap width is the preview's own width now, so a resize has to reflow.
  -- `WinResized` fires for any window; comparing against the width used for the
  -- last render makes resizing an unrelated window cost one integer compare.
  -- `VimResized` covers terminal resizes on Neovim versions without it.
  api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
    group = augroup,
    callback = function()
      M.on_resize(src_buf)
    end,
    desc = "mdview: reflow the preview when its width changes",
  })

  M.render(src_buf)
end

--- Idempotent single teardown path. All autocmd callbacks route here.
---@param src_buf integer
---@return boolean closed
function M.close(src_buf)
  local sess = sessions[src_buf]
  if not sess then
    return false
  end
  sessions[src_buf] = nil -- first: makes re-entrant calls no-ops
  pcall(api.nvim_del_augroup_by_id, sess.augroup)
  if sess.preview_win and api.nvim_win_is_valid(sess.preview_win) then
    pcall(api.nvim_win_close, sess.preview_win, true)
  end
  if sess.preview_buf and api.nvim_buf_is_valid(sess.preview_buf) then
    pcall(api.nvim_buf_delete, sess.preview_buf, { force = true })
  end
  restore_sidescroll()
  return true
end

--- Close the session that `buf` belongs to (source or preview side).
---@return boolean closed
function M.close_for(buf)
  local src = M.session_for(buf)
  if src then
    return M.close(src)
  end
  return false
end

return M
