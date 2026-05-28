# Installation and configuration

## Prerequisites

- Neovim >= 0.10 (for `vim.system()` and the extmark `sign_text` API)
- git >= 2.30 (the floor may be lower; not tested below 2.30)
- [diffview.nvim](https://github.com/dlyongemallo/diffview.nvim) (active
  fork; the original `sindrets/diffview.nvim` also works)

## Install

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

For active development (pointing at a local checkout), use `dir` instead
of the repo URL:

```lua
{
  dir = "~/dev/neovim-code-review",
  cmd = { "CodeReview", "CodeReviewSessions" },
  config = function()
    require("code-review").setup({})
  end,
}
```

With `dir`, changes you save in the repo are picked up on next plugin
load — no `:Lazy update` needed. Use `:Lazy reload code-review` to
reload without restarting Neovim.

### packer.nvim

```lua
use {
  "jhoskin/neovim-code-review",
  requires = { "dlyongemallo/diffview.nvim" },
  config = function()
    require("code-review").setup({})
  end,
}
```

### Manual

```bash
git clone https://github.com/jhoskin/neovim-code-review.git \
  ~/.local/share/nvim/site/pack/plugins/start/neovim-code-review
git clone https://github.com/dlyongemallo/diffview.nvim.git \
  ~/.local/share/nvim/site/pack/plugins/start/diffview.nvim
```

Add to your `init.lua`:

```lua
require("code-review").setup({})
```

## Health check

After install, verify everything wired up correctly:

```vim
:checkhealth code-review
```

You should see green checks for: Neovim version, git, repo detection,
diffview.nvim load, diffview API surface, audit trail directory.

## Configuration reference

The full `setup()` table with defaults:

```lua
require("code-review").setup({
  -- Buffer-local keymaps set on diffview's diff and file-panel buffers
  -- during a review session.
  keymaps = {
    add_comment    = "<leader>Rc",  -- line comment at cursor
    file_comment   = "<leader>Rf",  -- file-level comment
    delete_comment = "<leader>Rd",  -- delete comment at cursor
    summary        = "<leader>Rs",  -- show summary + submit
    cancel         = "<leader>Rq",  -- discard review, close
    pause          = "<leader>Rp",  -- save session for later
    confirm_comment = "<C-s>",      -- confirm comment in float
  },
  -- Highlight groups (defaults link to standard groups, overridable by
  -- your colorscheme).
  highlights = {
    comment      = { link = "Comment" },
    sign         = { link = "DiagnosticInfo" },
    file_comment = { link = "Comment" },
    file_sign    = { link = "DiagnosticHint" },
  },
  -- Sign column markers
  sign_text      = "●",   -- line comments
  file_sign_text = "📄",  -- file comments (on line 1)
})
```

All keymap strings accept the usual Neovim `<leader>`, `<C-x>`,
`<S-...>` syntax. Set any to `false` to disable that default and bind
it yourself with `vim.keymap.set`.

## Recommended LazyVim layout

The plugin's keymaps default to the `<leader>R` prefix (Review) to
avoid colliding with LazyVim's `<leader>c*` code submenu. For the
launch commands, group them under `<leader>g` so they live next to
diffview's git mappings.

Drop this in `~/.config/nvim/lua/plugins/code-review.lua` (or merge
into your existing git plugin file):

```lua
return {
  {
    "jhoskin/neovim-code-review",
    dependencies = { "dlyongemallo/diffview.nvim" },
    cmd = { "CodeReview", "CodeReviewSessions" },
    keys = {
      { "<leader>gr", "<cmd>CodeReview<cr>",         desc = "Code review: working tree" },
      { "<leader>gR", "<cmd>CodeReviewSessions<cr>", desc = "Code review: sessions" },
    },
    config = function()
      require("code-review").setup({})
    end,
  },
}
```

Once a review session is active, the buffer-local keymaps activate:

| Key          | Action                              |
|--------------|-------------------------------------|
| `<leader>Rc` | Add/edit line comment at cursor     |
| `<leader>Rf` | Add/edit file-level comment         |
| `<leader>Rd` | Delete comment at cursor            |
| `<leader>Rs` | Show summary and submit             |
| `<leader>Rp` | Pause session (save for later)      |
| `<leader>Rq` | Cancel review (discard)             |
| `<C-s>`      | Confirm comment (in input float)    |
| `q`          | Cancel comment/summary (in float)   |

In a session-scoped command list:

| Command              | Where                  |
|----------------------|------------------------|
| `:CodeReview [range]`| Always                 |
| `:CodeReviewSessions`| Always                 |
| `:CodeReviewSubmit`  | Only during a session  |
| `:CodeReviewCancel`  | Only during a session  |
| `:CodeReviewPause`   | Only during a session  |
| `:CodeReviewCopy`    | Only during a session  |

## Common review scenarios

| Scenario                                | Command                          |
|-----------------------------------------|----------------------------------|
| Uncommitted changes (working tree)      | `:CodeReview`                    |
| Last commit                             | `:CodeReview HEAD`               |
| Last N commits                          | `:CodeReview HEAD~3..HEAD`       |
| Branch vs main                          | `:CodeReview main..HEAD`         |
| Branch vs main (merge-base)             | `:CodeReview main...HEAD`        |
| Arbitrary range                         | `:CodeReview abc1234..def5678`   |

## Where reviews are stored

Submitted reviews accumulate as JSON files under
`~/.local/share/nvim/code-review/<project-hash>/`. The directory is
per-project (hash of the git root path). Sessions paused with
`:CodeReviewPause` live in `<project-hash>/sessions/` and are deleted
when resumed and submitted.

The plugin never deletes old review files. To prune:

```bash
# Delete reviews older than 30 days across all projects
find ~/.local/share/nvim/code-review -name '*.json' -mtime +30 -delete
```

## Troubleshooting

`:checkhealth code-review` reports a problem
: Follow the diagnostic — it names the missing dependency or
  unwritable directory.

`:CodeReview` does nothing
: Make sure diffview.nvim is loaded (`:Lazy` if you use lazy.nvim).
  Verify you're inside a git repository.

Keymaps don't fire on diff buffers
: They're buffer-local and registered when diffview fires
  `DiffviewDiffBufRead`. If you opened diffview directly (not via
  `:CodeReview`), the keymaps won't be there — that's intentional.

`:messages` shows an LSP error
: Open `:lua vim.cmd('edit ' .. vim.lsp.get_log_path())` to inspect.
  The plugin force-stops LSP clients on diff buffers using graceful
  `shutdown`/`exit` (REQ-LSP-0001 in `spec.md`); a clean exit code 0
  is expected. If you see a crash from a markdown LSP like Marksman,
  that means the LSP attached before the plugin's `LspAttach`
  autocmd fired — file an issue with the log excerpt.

The submit dialog asks to save a file
: This should not happen; the plugin uses `:quitall!` in agent mode
  and `DiffviewClose` in interactive mode. If you see it, capture
  `:messages` and the diff range you were reviewing.

## Next

- [Claude Code integration](claude-integration.md) — wire the plugin up
  as a slash command so an agent can request reviews on demand.
- [Specification](spec.md) — full requirements and design reference.
