# Installation and usage

This guide gets the plugin installed, verifies it works, defines the
terms used elsewhere, lists the configuration options and commands,
and covers the most common failure modes. If you just want the
shortest path, the
[Quick install](../README.md#quick-install-lazynvim) block in the
README is enough.

## Prerequisites

- Neovim >= 0.10. Check with `nvim --version`. The plugin uses two
  Neovim 0.10 APIs (`vim.system()` and extmark `sign_text`), so older
  versions will fail at startup.
- git >= 2.30. Check with `git --version`. Older versions may work but
  are untested.

The plugin has no plugin dependencies. The side-by-side diff is
rendered in-plugin, in pure Lua on top of `vim.diff`, so there is
nothing else to install.

## Concepts

A few terms are used throughout this guide:

- `<leader>` is Neovim's user-configurable prefix key, set with
  `vim.g.mapleader`. The default is `\`, so unconfigured `<leader>Rc`
  means `\Rc`. Most Neovim users set it to space with
  `vim.g.mapleader = " "`.
- A review session begins when you run `:CodeReview` and ends when you
  submit (`<leader>Rs`), cancel (`<leader>Rq`), or pause
  (`<leader>Rp`). While a session is active, the plugin's keymaps are
  bound on the renderer's buffers and the session-only commands
  (`:CodeReviewSubmit`, `:CodeReviewCancel`, `:CodeReviewPause`,
  `:CodeReviewCopy`) are available.
- The plugin has two modes. Interactive mode is when you launch Neovim
  yourself and run `:CodeReview`; on submit, the review closes and you
  are returned to your editor. Agent mode is when an LLM coding agent
  launches Neovim non-interactively with `$NVIM_CODE_REVIEW_RESULT`
  set; on submit, Neovim exits and the agent reads the result file.
  The Claude Code integration doc covers agent mode in depth.
- The renderer opens two kinds of buffers: diff buffers showing the
  before/after of a single file side-by-side, and a file-panel buffer
  listing every changed file in the review. The plugin's keymaps bind
  on both, so you can comment on a line from a diff buffer or comment
  on a whole file from the panel.

## How the renderer is built

When you run `:CodeReview`, the renderer creates two scratch diff
buffers per file, named `code-review://old/<path>` and
`code-review://new/<path>`, plus a file panel with filetype
`codereview-panel`. The diff buffers are `buftype=nofile`,
`buflisted=false`, `bufhidden=wipe`, and `modifiable=false` after they
fill. Both diff windows set `winfixbuf=true`, which structurally blocks
swapping another buffer into a diff window, plus `scrollbind` and
`cursorbind` so the two sides stay aligned.

Because the diff buffers are `nofile`, no LSP attaches to them. Nothing
files diagnostics against the transient git blobs, and there is no
cleanup to do.

The renderer applies the plugin's buffer-local keymaps to the diff
buffers and the file panel at the moment it builds them, during
`:CodeReview`. There are no autocmds in the loop.

## Install

If you already use a plugin manager, jump to the matching subsection.
If you do not know what a plugin manager is, it is the tool that
downloads and loads Neovim plugins for you. The most common ones today
are [lazy.nvim](https://github.com/folke/lazy.nvim) and
[packer.nvim](https://github.com/wbthomason/packer.nvim). lazy.nvim
is the current default in most starter configs (including LazyVim and
kickstart.nvim); pick it if you are starting fresh. The "Manual" path
uses Neovim's built-in package loader and needs no plugin manager at
all (the simplest option if you just want to try the plugin).

### lazy.nvim

```lua
{
  "jhoskin/neovim-code-review",
  cmd = { "CodeReview", "CodeReviewSessions" },
  main = "code-review",
  opts = {},
}
```

For active development against a local checkout, prefer LazyVim's
standard `dev = true` pattern. Set a global dev path once in your
`lazy.setup` config:

```lua
require("lazy").setup({ ... }, {
  dev = { path = "~/dev" },
})
```

Then mark the plugin as dev in its spec; lazy.nvim will look for
`<dev.path>/<plugin-name>` automatically:

```lua
{
  "jhoskin/neovim-code-review",
  dev = true,
  cmd = { "CodeReview", "CodeReviewSessions" },
  main = "code-review",
  opts = {},
}
```

If you would rather hard-code the path, use `dir` and include `name`
so lazy registers the plugin under a stable key:

```lua
{
  dir = "~/dev/neovim-code-review",
  name = "code-review",
  cmd = { "CodeReview", "CodeReviewSessions" },
  main = "code-review",
  opts = {},
}
```

With `dir`, changes you save in the repo are picked up the next time
the plugin is loaded by lazy.nvim (the first `:CodeReview` /
`:CodeReviewSessions` after a Neovim restart). `:Lazy update` is only
for git-pulled plugins, so it would be a no-op here anyway. Inside a
running Neovim, `:Lazy reload code-review` re-requires the Lua modules
without restarting. Mid-session it also tears down the
`code_review_session` augroup, so reload between sessions, not during
one.

### packer.nvim

```lua
use {
  "jhoskin/neovim-code-review",
  config = function()
    require("code-review").setup({})
  end,
}
```

### Manual

Neovim's built-in `pack/*/start/*` mechanism auto-loads any plugin
cloned under `~/.local/share/nvim/site/pack/<group>/start/`. You can
pick any `<group>` name; this guide uses `plugins`. `git clone`
creates the directories for you.

```bash
git clone https://github.com/jhoskin/neovim-code-review.git \
  ~/.local/share/nvim/site/pack/plugins/start/neovim-code-review
```

Then add the setup call to your config. If your config is `init.lua`,
append:

```lua
require("code-review").setup({})
```

If your config is `init.vim`, append:

```vim
lua require("code-review").setup({})
```

## Health check

After install, verify everything wired up correctly:

```vim
:checkhealth code-review
```

You should see green checks for:

- `Neovim >= 0.10`
- `git available` (reports the git version)
- `Inside git repo` (reports the git root)
- `Audit trail directory` (exists, was created, or could not be
  created)

The "Inside git repo" check downgrades to a warning if you ran
`:checkhealth` outside a git work tree, which is expected; the other
checks should all be green. If any line is yellow or red, the
diagnostic text names the missing dependency or unwritable path. Search
this page for the named symbol: most failures have a Troubleshooting
entry below.

## Try it

1. `cd` into any git repository with at least one uncommitted change.
2. Run `nvim` and then `:CodeReview`. The review opens with the
   working-tree changes side-by-side.
3. Put your cursor on a changed line. Press `<leader>Rc`. A floating
   window prompts for a comment. Type, then press `<C-s>` to confirm.
4. Press `<leader>Rs` to preview the review and submit it. The plugin
   writes a JSON file under
   `~/.local/share/nvim/code-review/<project-hash>/`.

If any step fails, see Troubleshooting below.

## Configuration reference

The full `setup()` table with defaults. This block is the source of
truth; the keymap table further down restates the defaults in a more
scannable form, but the values come from here.

```lua
require("code-review").setup({
  -- Buffer-local keymaps set on the renderer's diff and file-panel
  -- buffers during a review session. A value may be a string (one key), a
  -- list of strings (bind several keys to the action), or false (disable).
  keymaps = {
    next_file       = "<leader>Rn",  -- next changed file (focus new side)
    prev_file       = "<leader>RN",  -- previous changed file
    add_comment     = "<leader>Rc",  -- line comment at cursor
    file_comment    = "<leader>Rf",  -- file-level comment
    delete_comment  = "<leader>Rd",  -- delete comment at cursor
    summary         = "<leader>Rs",  -- show summary, then submit
    cancel          = "<leader>Rq",  -- discard review, close
    pause           = "<leader>Rp",  -- save session for later
    confirm_comment = "<C-s>",       -- confirm and save the comment in the input float
  },
  -- Highlight groups (defaults link to standard groups, overridable
  -- by your colorscheme).
  highlights = {
    comment      = { link = "Comment" },
    sign         = { link = "DiagnosticInfo" },
    file_comment = { link = "Comment" },
    file_sign    = { link = "DiagnosticHint" },
  },
  -- Sign column markers
  sign_text      = "●",   -- line comments
  file_sign_text = "📄",  -- file comments (on line 1); 2-cell emoji
})
```

All keymap strings accept Neovim's standard keycode notation:
`<leader>` for your leader key, `<C-x>` for Ctrl-x, `<S-x>` for
Shift-x, `<CR>` for Enter, `<Esc>` for Escape. See
`:help key-notation`. Set any keymap to `false` to disable the default
and bind it yourself with `vim.keymap.set`.

`setup()` deep-merges your table over the defaults
(`vim.tbl_deep_extend("force", ...)`), so partial overrides are safe.
Only the keys you set are touched, and anything you omit stays at its
default. The same is true when you pass the table via lazy.nvim's
`opts`. A LazyVim spec that overrides one keymap looks like:

```lua
-- in lua/plugins/code-review.lua
{
  "jhoskin/neovim-code-review",
  main = "code-review",
  opts = {
    keymaps = {
      -- A value is a string, a list of keys ({ "c", "<leader>Rc" }), or false.
      add_comment = "<leader>rc", -- remap to lowercase prefix
      cancel      = false,        -- disable default; bind yourself
    },
  },
}
```

Terminal users: many terminals leave XON/XOFF flow control on by
default, which swallows `Ctrl-S` before Neovim sees it. If pressing
`<C-s>` in the comment float does nothing, run `stty -ixon` in the
shell that launched Neovim, or rebind `confirm_comment` to something
the terminal does not consume (`<C-CR>`, `<C-j>`, `<F2>`). GUI Neovim
(Neovide, nvim-qt) is not affected. `<C-s>` is also a common user
mapping for `:w`. If you have that mapping globally, the float's
buffer-local binding shadows it inside the float but your `:w` mapping
is untouched elsewhere.

Neovim's extmark `sign_text` requires `strdisplaywidth(sign_text)` to
be 1 or 2. Most modern terminals render `📄` as width 2, but some
report it as width 1 (older iTerm2, urxvt, kitty without emoji-width
tuning, terminals where Neovim sees `ambiwidth=single` and the font
lacks an emoji glyph). If `:CodeReview` errors with
`sign_text must have a display width of 1 or 2`, override
`file_sign_text` to a single BMP code point such as `"📝"` (still
emoji, width 2 across more terminals) or `"F"` / `"※"` for a plain
ASCII / Unicode marker. The same applies to `sign_text` (default `●`)
if you set `ambiwidth=double`.

Once a review session is active, the buffer-local keymaps register on
the renderer's diff and file-panel buffers. They carry `desc` strings,
so which-key shows them under the `<leader>R` group as soon as you hit
`<leader>R` on a session buffer.

| Key          | Action                                  | Diff buffers | File panel |
|--------------|-----------------------------------------|:------------:|:----------:|
| `<leader>Rn` | Next file (focus the new-side window)   | yes          | yes        |
| `<leader>RN` | Previous file                           | yes          | yes        |
| `<leader>Rc` | Add/edit line comment at cursor         | yes          | no         |
| `<leader>Rd` | Delete comment at cursor                | yes          | no         |
| `<leader>Rf` | Add/edit file-level comment             | yes          | yes        |
| `<leader>Rs` | Show summary and submit                 | yes          | yes        |
| `<leader>Rp` | Pause session (save for later)          | yes          | yes        |
| `<leader>Rq` | Cancel review (discard)                 | yes          | yes        |
| `<C-s>`      | Confirm and save the comment in the input float | float only | float only |
| `q`          | Cancel comment/summary (in float; hardcoded, not in `keymaps`) | float only | float only |

`<leader>Rc` and `<leader>Rd` are absent from the file panel because
the panel has no cursor "line" to anchor a line comment to.

## Commands

The plugin registers these user commands. Session-scoped commands only
resolve during an active review.

| Command                  | Where                  |
|--------------------------|------------------------|
| `:CodeReview [gitref]`   | Always (argument is a git revision or revision range) |
| `:CodeReviewSessions`    | Always                 |
| `:CodeReviewSubmit`      | Only during a session  |
| `:CodeReviewCancel`      | Only during a session  |
| `:CodeReviewPause`       | Only during a session  |
| `:CodeReviewCopy`        | Only during a session  |

## Recommended LazyVim layout

This section is for users of [LazyVim](https://lazyvim.org), a
preconfigured Neovim distribution built on top of the lazy.nvim plugin
manager. (LazyVim and lazy.nvim are not the same thing: LazyVim is a
full config, lazy.nvim is just the manager.) If you used the
"Install / lazy.nvim" block above, you do not need to add this one as
well; replace that block with this one if you want the recommended
keymaps for the launch commands.

The plugin's keymaps default to `<leader>R` (Review, uppercase) to
stay clear of LazyVim's `<leader>c*` code submenu and the common
user-defined `<leader>r*` (REPL, run, rest.nvim). Uppercase is a less
common primary prefix because every keystroke is shifted, so if you
have nothing else on `<leader>r`, remapping to lowercase via
`opts.keymaps` is reasonable:

```lua
    opts = {
      -- Single key (fast) + <leader>R* (discoverable in which-key). The maps
      -- are buffer-local to the review's nofile buffers, so they don't affect
      -- normal editing. Destructive actions keep only <leader>R* so a stray
      -- key can't end a review.
      keymaps = {
        next_file    = { "<Tab>",   "<leader>Rn" },
        prev_file    = { "<S-Tab>", "<leader>RN" },
        add_comment  = { "c",       "<leader>Rc" }, -- line comment (diff)
        file_comment = { "C",       "<leader>Rf" }, -- file comment (panel/diff)
      },
    },
```

For the launch commands, group them under `<leader>g` so they live
next to your other git mappings. Drop this in
`~/.config/nvim/lua/plugins/code-review.lua` (or merge into your
existing git plugin file):

```lua
return {
  {
    "jhoskin/neovim-code-review",
    cmd = { "CodeReview", "CodeReviewSessions" },
    keys = {
      { "<leader>gr", "<cmd>CodeReview<cr>",         desc = "Code review: working tree" },
      { "<leader>gR", "<cmd>CodeReviewSessions<cr>", desc = "Code review: sessions" },
    },
    main = "code-review",
    opts = {},
  },
}
```

Register `<leader>R` with which-key so the prefix shows a "review"
label in the popup once a session is active:

```lua
-- in the same plugins/code-review.lua, or in your which-key spec
{
  "folke/which-key.nvim",
  opts = {
    spec = {
      { "<leader>R", group = "review" },
    },
  },
}
```

The plugin sets `desc` on each buffer-local keymap, so once the prefix
is grouped, which-key picks up the individual entries
(`Add comment`, `File comment`, etc.) automatically during a review
session.

## Common review scenarios

| Scenario                                | Command                          |
|-----------------------------------------|----------------------------------|
| Uncommitted changes (working tree)      | `:CodeReview`                    |
| Last commit                             | `:CodeReview HEAD`               |
| Last N commits                          | `:CodeReview HEAD~3..HEAD`       |
| Branch vs main                          | `:CodeReview main..HEAD`         |
| Branch vs main (merge-base)             | `:CodeReview main...HEAD`        |
| Arbitrary range                         | `:CodeReview abc1234..def5678`   |

Two dots (`main..HEAD`) reviews every commit on your branch that is
not on `main`. Three dots (`main...HEAD`) reviews everything since
your branch diverged from `main`, useful if `main` has moved on since
you branched and you only want to see your work. If you are unsure,
three dots is usually what you want.

## Where reviews are stored

Submitted reviews accumulate as JSON files under
`~/.local/share/nvim/code-review/<project-hash>/`. The directory is
per-project (hash of the git root path). Sessions paused with
`:CodeReviewPause` live in `<project-hash>/sessions/` and are deleted
when resumed and submitted.

On Linux and macOS, this resolves to `~/.local/share/nvim/...`. On
Windows it is `%LOCALAPPDATA%\nvim-data\...`. The plugin always uses
whatever `:echo stdpath("data")` reports; run that to see your actual
path. To list all stored projects:

```bash
ls ~/.local/share/nvim/code-review/
```

Each subdirectory is the hash of one project's git root. From inside
Neovim, the current project's full review directory is:

```vim
:lua print(vim.fn.stdpath("data") .. "/code-review/")
```

The plugin never deletes old review files. To prune submitted reviews
only (and leave paused sessions alone):

```bash
# Preview first.
find ~/.local/share/nvim/code-review \
  -mindepth 2 -maxdepth 2 \
  -type f -name '*.json' -mtime +30 -print

# Then delete.
# Paths look like <data>/code-review/<hash>/<id>.json; paused
# sessions live one level deeper, under <hash>/sessions/.
find ~/.local/share/nvim/code-review \
  -mindepth 2 -maxdepth 2 \
  -type f -name '*.json' -mtime +30 -delete
```

If you also want to clear stale paused sessions, raise `-maxdepth` to
3 or run a second `find` against `*/sessions/*.json`.

## Troubleshooting

#### lazy.nvim fails to clone from GitHub: `fatal: could not read Username for 'https://github.com'`

The plugin's repo is reachable over HTTPS only with a credential
helper, and lazy.nvim runs `git clone` with terminal prompts disabled.
If you maintain a private mirror (or any private fork), tell lazy.nvim
to clone over SSH so it uses your SSH key:

```lua
{
  "owner/repo",
  url = "git@github.com:owner/repo.git",
  -- ... rest of the spec
}
```

Drop the `url =` line again once the repo is public, or if you set up
an HTTPS credential helper that does not need a TTY.

#### lazy.nvim leaves a `<repo>.cloning` directory and refuses to install

If you killed Neovim mid-clone, or if `:CodeReview` fired before
lazy.nvim finished installing the plugin for the first time, lazy
leaves a half-finished clone at
`~/.local/share/nvim/lazy/<repo>.cloning`. Subsequent installs see
the marker and refuse to overwrite it.

Move the directory aside and re-run install. Using this repo's
[TRASH convention](https://github.com/jhoskin/neovim-code-review/blob/main/.gitignore):

```bash
mkdir -p ~/.local/share/nvim/lazy/TRASH
mv ~/.local/share/nvim/lazy/neovim-code-review.cloning \
   ~/.local/share/nvim/lazy/TRASH/
```

Then `nvim --headless +'Lazy! install' +qa` or `:Lazy install` inside
Neovim.

#### `:CodeReview` is not a recognized command (`E492: Not an editor command: CodeReview`)

Your plugin manager has not loaded code-review yet.

- lazy.nvim: the snippet uses `cmd = { "CodeReview", "CodeReviewSessions" }`,
  so the plugin only loads when one of those commands is invoked. If you
  typed `:CodeReview` and got `E492`, lazy.nvim itself is not installed
  or your config file was not sourced. Confirm with
  `:lua print(vim.inspect(package.loaded['lazy']))`.
- packer.nvim: run `:PackerSync` to install.
- Manual: confirm the clone landed in
  `~/.local/share/nvim/site/pack/plugins/start/neovim-code-review`
  and restart Neovim.

#### Opening a file into a diff pane errors out

The diff windows set `winfixbuf=true`, so opening a file into one of
them (via Telescope, snacks-picker, fzf-lua, or `<leader>ff` while a
review session is active) errors instead of swapping the buffer. This
is deliberate: it keeps the two diff panes pointing at the same file's
old and new versions. Navigate files with the renderer's own file
panel: `j`/`k` to move and `<CR>` to open.

#### `:CodeReview <range>` errors with `fatal: ambiguous argument '<rev>': unknown revision or path not in the working tree`

Git could not resolve the revision you passed. Common causes:

- The repo has fewer commits than the range expects (e.g., `HEAD~3`
  on a repo with one commit).
- You are on a shallow clone (`git clone --depth 1`). Run
  `git fetch --unshallow` or use a smaller range.
- The branch name is misspelled or not fetched locally (`main` vs
  `master`, missing `origin/`).
- You passed a path instead of a revision; quote ranges that contain
  `..` to avoid shell expansion.

#### `<leader>Rc` has no effect in a diff buffer

The plugin binds its keymaps when you launch the review with
`:CodeReview`; the renderer applies them to the diff buffers and the
file panel as it builds them. If a key has no effect, confirm you are
in a buffer the renderer created and that `setup()` ran.

1. Confirm the keymap is bound on the buffer:
   `:verbose nmap <leader>Rc`. The output should name a buffer-local
   mapping defined in `lua/code-review/init.lua`.
2. Confirm `setup()` ran. With lazy.nvim's `cmd =` lazy spec, this is
   delayed until the first `:CodeReview`. Check that your `opts = {}` /
   `config = function() require("code-review").setup({}) end` block is
   present.
3. Confirm you are inside a git repository:
   `:!git rev-parse --show-toplevel`. If git answers
   `fatal: not a git repository`, run `:cd <repo>` first or open Neovim
   from inside the repo.

#### `:CodeReviewSubmit` errors with `E482: Can't create file ...` or `mkdir() failed: Permission denied`

The plugin writes review JSON under
`vim.fn.stdpath("data") .. "/code-review/"`. If that path is not
writable, submit fails with the OS error above.

1. Run `:checkhealth code-review`. The "Audit trail directory" line
   reports the failure.
2. Check the path: `:echo stdpath("data") .. "/code-review/"`. Verify
   it is writable: `:!test -w %:p:h && echo OK`.
3. On macOS, ensure the directory is not inside a path that System
   Integrity Protection blocks (a synced iCloud folder may quarantine
   new files).
4. If you need to relocate the directory, set `XDG_DATA_HOME` before
   launching Neovim. The plugin reads `stdpath("data")` and does not
   have a config knob.

#### Submit shows `E37: No write since last change` or a `Save changes to ...?` prompt

This should not happen. The plugin uses `:quitall!` in agent mode and
closes the renderer in interactive mode (see
`lua/code-review/review.lua` and `lua/code-review/init.lua`). If you
hit a save prompt:

1. Press `:q!` to discard and avoid corrupting the audit trail.
2. Capture `:messages` (last 50 lines).
3. Note the exact `:CodeReview <range>` you ran.
4. File a bug with the template in
   [Filing a bug report](#filing-a-bug-report).

### Filing a bug report

If the entries above do not explain what you are seeing, open an issue
at <https://github.com/jhoskin/neovim-code-review/issues> with:

- `nvim --version` output
- Plugin commit: `:Lazy log code-review` (or
  `git -C ~/.local/share/nvim/site/pack/.../neovim-code-review log -1`)
- OS and shell
- Output of `:checkhealth code-review`
- Relevant `:messages` excerpt (last 50 lines: run `:messages`, then
  yank with `"+y`)
- Minimal repro: the exact `:CodeReview <range>` invocation and, if
  possible, a public repo or commit hash that triggers it

## See also

- [Claude Code integration](claude-integration.md): wire up the plugin
  as a slash command so an agent can request reviews on demand.
- [Specification](spec.md): full requirements and design reference.
