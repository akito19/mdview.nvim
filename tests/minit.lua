-- Minimal init used both by `make test` and by test child Neovim processes.
-- Manual check: nvim -u tests/minit.lua README.md

-- Make the plugin under development available.
vim.cmd([[let &rtp .= ',' .. getcwd()]])

-- Set up 'mini.test' when running headlessly (like with `make test`).
if #vim.api.nvim_list_uis() == 0 then
  local deps_path = vim.fn.getcwd() .. "/.deps"
  local mini_path = deps_path .. "/mini.nvim"
  if not vim.uv.fs_stat(mini_path) then
    vim.fn.system({
      "git",
      "clone",
      "--filter=blob:none",
      "https://github.com/echasnovski/mini.nvim",
      mini_path,
    })
  end
  vim.o.runtimepath = vim.o.runtimepath .. "," .. mini_path
  require("mini.test").setup()
end
