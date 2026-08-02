--- Public API for mdview.nvim.
local M = {}

--- Optional setup. The plugin works with defaults when this is never called.
---@param opts table|nil see |mdview-configuration|
---@return table the merged, validated configuration
function M.setup(opts)
  return require("mdview.config").setup(opts)
end

--- Is a preview open for `buf`? Accepts either side of a session, so the
--- preview buffer answers as truthfully as its source does.
---
--- Exported so that a statusline or a conditional keymap never has to reach
--- into `mdview.window`, which is internal and free to change shape.
---@param buf integer|nil buffer handle; defaults to the current buffer
---@return boolean
function M.is_open(buf)
  return require("mdview.window").is_open(buf or vim.api.nvim_get_current_buf())
end

local function ensure_markdown(buf)
  if vim.bo[buf].filetype ~= "markdown" then
    vim.notify("mdview: current buffer is not a markdown buffer", vim.log.levels.WARN)
    return false
  end
  return true
end

--- Open (or re-render) the preview for the current markdown buffer.
---@param direction string|nil "vertical" | "horizontal"; defaults to config.split
---@return boolean opened false when the buffer is not markdown
function M.open(direction)
  local buf = vim.api.nvim_get_current_buf()
  if not ensure_markdown(buf) then
    return false
  end
  require("mdview.highlights").setup()
  local dir = direction or require("mdview.config").get().split
  require("mdview.window").open(buf, dir)
  return true
end

--- Close the preview associated with the current buffer (works from either
--- the source buffer or the preview buffer).
---@return boolean closed false when this buffer had no preview
function M.close()
  local closed = require("mdview.window").close_for(vim.api.nvim_get_current_buf())
  if not closed then
    -- Every other user-facing failure here says so; silence would leave the
    -- user unable to tell "nothing to do" from "the command is broken".
    vim.notify("mdview: no preview open for this buffer", vim.log.levels.INFO)
  end
  return closed
end

--- Toggle the preview for the current buffer.
---@param direction string|nil "vertical" | "horizontal"
---@return boolean open whether a preview is open afterwards
function M.toggle(direction)
  local window = require("mdview.window")
  local buf = vim.api.nvim_get_current_buf()
  if window.is_open(buf) then
    window.close_for(buf)
    return false
  end
  return M.open(direction)
end

return M
