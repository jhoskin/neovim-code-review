# neovim-code-review

Local code review for LLM coding agent output. No GitHub, no third-party
services.

A coding agent launches Neovim into a side-by-side diff. You add comments on
diff lines or files. On exit, the review is persisted as a JSON file and the
agent reads it to act on your feedback.

The diff is rendered in-plugin (pure Lua on top of `vim.diff`), so there are
no plugin dependencies.

## How it works

1. Agent runs `nvim -c 'CodeReview HEAD~3..HEAD'` with
   `$NVIM_CODE_REVIEW_RESULT` set to a temp file path.
2. Neovim opens a side-by-side diff of the changes.
3. You add line and file comments using `<leader>R*` keymaps.
4. You submit with `<leader>Rs`, confirming the markdown preview.
5. The plugin writes a JSON file under
   `~/.local/share/nvim/code-review/<project>/` and writes that path to
   the temp file. In agent mode, Neovim exits with code 0.
6. The agent reads the temp file, parses the JSON, and acts.

## Quick install (lazy.nvim)

```lua
{
  "jhoskin/neovim-code-review",
  cmd = { "CodeReview", "CodeReviewSessions" },
  config = function()
    require("code-review").setup({})
  end,
}
```

Then `:checkhealth code-review` to verify.

## Documentation

- [Installation and configuration](docs/installation.md) — setup,
  recommended LazyVim layout, full `setup()` reference, troubleshooting.
- [Claude Code integration](docs/claude-integration.md) — wire it up as
  a `/code-review` slash command so an agent can request reviews on
  demand.
- [Specification](docs/spec.md) — full requirements, JSON schema, exit
  codes, verification matrix.

## Commands

| Command                | Where                  |
|------------------------|------------------------|
| `:CodeReview [range]`  | Always                 |
| `:CodeReviewSessions`  | Always                 |
| `:CodeReviewSubmit`    | Only during a session  |
| `:CodeReviewCancel`    | Only during a session  |
| `:CodeReviewPause`     | Only during a session  |
| `:CodeReviewCopy`      | Only during a session  |

## Keybindings (defaults)

During a review session, on diff buffers and the file panel:

| Key          | Action                                       |
|--------------|----------------------------------------------|
| `<leader>Rn` | Next file (focus the new-side window)        |
| `<leader>RN` | Previous file                                |
| `<leader>Rr` | Add/edit line comment                        |
| `<leader>RR` | Add/edit file comment                        |
| `<leader>Rd` | Delete comment at cursor                     |
| `<leader>Rz` | Zoom current diff side to full width (drops diff paint for syntax) |
| `<leader>Rs` | Show summary and submit                      |
| `<leader>Rp` | Pause session (save for later)               |
| `<leader>Rq` | Cancel review (discard)                      |
| `<C-s>`      | Confirm comment (in float)                   |
| `q`          | Cancel comment/summary (in float)            |

The `<leader>R` prefix avoids collision with LazyVim's `<leader>c*`
code submenu. Every keymap is configurable, and a value may be a single
key, a list of keys, or `false` to disable. For a faster, single-keystroke
setup (`<Tab>`/`<S-Tab>` to move between files, `r`/`R` to comment) see the
recommended layout in [installation.md](docs/installation.md).

## Agent integration

```bash
result=$(mktemp)
NVIM_CODE_REVIEW_RESULT="$result" nvim -c 'CodeReview HEAD~3..HEAD'
case $? in
  0) review_path=$(cat "$result"); cat "$review_path" ;;
  2) echo "User cancelled" ;;
  *) echo "Error" >&2 ;;
esac
rm -f "$result"
```

See [claude-integration.md](docs/claude-integration.md) for the full
Claude Code slash command example.

## Dependencies

- Neovim >= 0.10
- git >= 2.30

No plugin dependencies. The diff renderer is built in (pure Lua +
`vim.diff`).

## Bundled scripts

`scripts/interactive-review-launch` is the wrapper the Claude Code
slash command exec's to hand off to Neovim (zmx session, kitty window,
sentinel polling, exit-code dispatch). See
[docs/claude-integration.md](docs/claude-integration.md) for the
install-once-then-forget setup.

## Development

```bash
make test          # launch Neovim with the minimal test config
make test-e2e      # run the tmux-driven end-to-end test suite (43 tests)
make health        # run :checkhealth headless
```

## License

MIT (see `LICENSE` if present, otherwise consider it MIT for now).
