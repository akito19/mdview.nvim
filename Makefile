DEPS_DIR := .deps
MINI_DIR := $(DEPS_DIR)/mini.nvim

.PHONY: test test_file deps clean

# Run the full test suite in a headless Neovim.
test: deps
	nvim --headless --noplugin -u ./tests/minit.lua -c "lua MiniTest.run()"

# Run a single test file: make test_file FILE=tests/test_parser.lua
test_file: deps
	nvim --headless --noplugin -u ./tests/minit.lua -c "lua MiniTest.run_file('$(FILE)')"

deps: $(MINI_DIR)

$(MINI_DIR):
	git clone --filter=blob:none https://github.com/echasnovski/mini.nvim $(MINI_DIR)

clean:
	rm -rf $(DEPS_DIR)
