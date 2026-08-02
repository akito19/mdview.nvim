# CLAUDE.md

A Neovim plugin that renders the current markdown buffer as decorated text in a
split window. Pure Lua, Neovim 0.10+, no runtime dependencies.

Read [plan/design.md](plan/design.md) before changing rendering behaviour, and
[plan/decisions.md](plan/decisions.md) before revisiting a decision that looks
odd — several of them are the result of a failed earlier attempt.

## Commands

```sh
make test                              # full headless suite (mini.test)
make test_file FILE=tests/test_x.lua   # one file
```

mini.nvim is cloned into `.deps/` on first run. Tests must pass before you
finish; there is no CI to catch it later.

Manual check: `nvim -u tests/minit.lua README.md`, then `:MdView`.

## Layout

| Path | Role |
|---|---|
| `plugin/mdview.lua` | user commands only, so the Lua tree loads lazily |
| `lua/mdview/init.lua` | `setup()` / `open()` / `close()` / `toggle()` |
| `lua/mdview/config.lua` | defaults + deep merge; `setup()` is optional |
| `lua/mdview/parser.lua` | tree-sitter walk → flat IR |
| `lua/mdview/renderer.lua` | IR → `{ lines, decorations }` |
| `lua/mdview/highlights.lua` | `Mdview*` groups, some computed by blending |
| `lua/mdview/window.lua` | scratch buffer, split, sessions, extmarks |

## Invariants

**`renderer.lua` is a pure function.** No buffer, window or API access — the
target width arrives via `opts.width`. It holds the most logic (wrapping, table
layout, span splitting) and purity is what makes it unit-testable. Anything
needing a buffer, a window or a colour belongs in `window.lua` or
`highlights.lua`.

It has exactly one global dependency: a module-level memo of per-character
display widths, which `M.render` re-keys on `vim.o.ambiwidth` once per call.
That is not a new dependency — `strdisplaywidth` already read the same option on
every call — but it is the reason `sync_width_cache()` must stay at the top of
`M.render`. Drop it and the second of two renders straddling an `ambiwidth`
change silently reuses the first one's widths.

**Measure, never count.** All widths go through `strdisplaywidth`. This user
runs `ambiwidth = "double"`, which makes `█ │ ─ • ·` two cells wide while `‣`
stays one, so anything padded by character count drifts by a cell per unit.
There are regression tests under both settings — keep them passing.

Only East Asian **Ambiguous** characters move with the option. Kana and kanji
are Wide: two cells either way. So a test fixture made of Japanese prose is
*not* sensitive to `ambiwidth` — pin that behaviour with ambiguous characters
(`█ │ ─ • · ± ° α →`) or the case passes under both settings for the wrong
reason.

**The glyph set is closed.** Decoration may emit only `█`, `• ‣ ·`, and box
drawing `┌ ┬ ┐ ├ ┼ ┤ └ ┴ ┘ ─ │`. Not `● ◦ ▪ ■ ░ ▓ ☐ ☑` — those are absent from
Monaco and get substituted from a fallback face with mismatched metrics. Box
drawing and block elements are safe because Ghostty draws those ranges itself
rather than taking them from the font. A test asserts nothing else appears.

**Heading depth is bar length in whole cells**, one `█` per `#`. Do not
reintroduce graduated background alpha or partial-block thickness — both were
tried and are invisible in practice. See decision 2 in the log.

**The preview window is always `nowrap`.** Prose is wrapped by the renderer so
that tables and code blocks can run off the edge and scroll horizontally.
Tables, code blocks and rules are never wrapped.

**Sessions are keyed by source buffer** with one idempotent teardown path. Every
autocmd routes through it; the session is removed first so re-entrant callbacks
no-op.

## Git workflow

**Never commit to `main`.** Branch first, then commit — including for a one-line
fix. `main` only moves through merged pull requests.

Branch names are `<type>/<short-description>`, kebab-case:

| Prefix | Use for |
|---|---|
| `feat/` | a new capability |
| `bug/` | fixing broken behaviour |
| `chore/` | tooling, deps, housekeeping |
| `docs/` | documentation only |
| `refactor/` | restructuring with no behaviour change |
| `test/` | tests only |

```sh
git switch -c feat/scroll-sync
git switch -c bug/table-width-under-ambiwidth-double
git switch -c chore/bump-mini-test
```

Run `make test` before every commit. Commit only when asked; push only when
asked.

## Conventions

- Comments explain *why*, especially where a value compensates for an
  environment quirk. The reason is rarely recoverable from the code.
- Any change to rendered output needs its golden test updated, not deleted.
- When adding config, keep `setup()` optional — defaults must stand alone.
