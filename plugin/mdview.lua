-- Entry point for mdview.nvim: user command definitions only.
if vim.g.loaded_mdview then
  return
end
vim.g.loaded_mdview = true

local function complete_direction(arg_lead)
  return vim.tbl_filter(function(item)
    return vim.startswith(item, arg_lead)
  end, { "vertical", "horizontal" })
end

local function validated_direction(arg)
  if arg == nil or arg == "" then
    return nil, true
  end
  if arg == "vertical" or arg == "horizontal" then
    return arg, true
  end
  vim.notify(
    ("mdview: invalid direction %q (expected \"vertical\" or \"horizontal\")"):format(arg),
    vim.log.levels.WARN
  )
  return nil, false
end

vim.api.nvim_create_user_command("MdView", function(opts)
  local direction, ok = validated_direction(opts.fargs[1])
  if not ok then
    return
  end
  require("mdview").open(direction)
end, {
  nargs = "?",
  complete = complete_direction,
  desc = "Open (or re-render) the markdown preview for the current buffer",
})

vim.api.nvim_create_user_command("MdViewClose", function()
  require("mdview").close()
end, { desc = "Close the markdown preview" })

vim.api.nvim_create_user_command("MdViewToggle", function(opts)
  local direction, ok = validated_direction(opts.fargs[1])
  if not ok then
    return
  end
  require("mdview").toggle(direction)
end, {
  nargs = "?",
  complete = complete_direction,
  desc = "Toggle the markdown preview",
})
