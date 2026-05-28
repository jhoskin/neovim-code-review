# neovim-code-review

Local code review for LLM coding agent output. No GitHub, no third-party
services.

A coding agent launches Neovim into a diff view. You add comments on diff
lines, files, or the review as a whole. On exit, the review is persisted as
a JSON file. The agent reads the file and acts on your feedback.

## How it works

1. Agent runs `nvim -c 'CodeReview HEAD~3..HEAD'`
2. Neovim opens with a diffview showing the changes
3. You add line comments, file comments, and a verdict
4. You submit the review
5. A JSON file is saved to the audit trail directory
6. The file path is written to `$NVIM_CODE_REVIEW_RESULT` for the agent

## Installation

### lazy.nvim

```lua
{
  "jhoskin/neovim-code-review",
  dependencies = { "dlyongemallo/diffview.nvim" },
  cmd = { "CodeReview", "CodeReviewSessions" },
  config = function()
    require("code-review").setup({})
  end,
}
```

### Manual

Clone the repo and add both it and diffview.nvim to your runtimepath:

```bash
git clone https://github.com/jhoskin/neovim-code-review.git ~/.local/share/nvim/site/pack/plugins/start/neovim-code-review
git clone https://github.com/dlyongemallo/diffview.nvim.git ~/.local/share/nvim/site/pack/plugins/start/diffview.nvim
```

Add to your `init.lua`:

```lua
require("code-review").setup({})
```

## Commands

| Command | Description |
|---------|-------------|
| `:CodeReview [range]` | Start a review session |
| `:CodeReviewSubmit` | Show summary and submit |
| `:CodeReviewPause` | Save session for later |
| `:CodeReviewCancel` | Discard review, exit (code 2) |
| `:CodeReviewSessions` | List and resume saved sessions |
| `:CodeReviewCopy` | Export review as Markdown to clipboard |

## Keybindings

Active during a review session (buffer-local on diff buffers):

| Key | Action |
|-----|--------|
| `<leader>Rc` | Add/edit line comment |
| `<leader>Rf` | Add/edit file comment |
| `<leader>Rv` | Set/edit verdict |
| `<leader>Rd` | Delete comment at cursor |
| `<leader>Rs` | Show summary and submit |
| `<leader>Rp` | Pause session (save for later) |
| `<leader>Rq` | Cancel review (discard, exit 2 in agent mode) |
| `<C-s>` | Confirm comment (in float) |
| `q` | Cancel comment/summary (in float) |

The capital `R` prefix avoids collision with LazyVim's `<leader>c*` code
submenu. All keybindings are configurable via `setup({ keymaps = { ... } })`.

All keybindings are configurable via `setup()`.

## Agent integration

```bash
export NVIM_CODE_REVIEW_RESULT=$(mktemp)
nvim -c 'CodeReview HEAD~3..HEAD'
if [ $? -eq 0 ]; then
  review_path=$(cat "$NVIM_CODE_REVIEW_RESULT")
  cat "$review_path"  # JSON review data
fi
# Exit code 0 = submitted, 2 = cancelled, 1 = error
rm -f "$NVIM_CODE_REVIEW_RESULT"
```

## Health check

```vim
:checkhealth code-review
```

## Development

Test in isolation (downloads diffview.nvim automatically):

```bash
make test          # Launch Neovim with minimal config
make health        # Run health check headless
make clean         # Remove test dependencies
```

## Dependencies

- Neovim >= 0.10
- [diffview.nvim](https://github.com/dlyongemallo/diffview.nvim)
- git >= 2.30

## Specification

See [docs/spec.md](docs/spec.md) for the full requirements and design
specification.
