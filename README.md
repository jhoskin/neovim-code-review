# neovim-code-review

Local code review for LLM coding agent output. No GitHub, no third-party
services.

A coding agent launches Neovim into a diff view. You add comments on diff lines,
files, or the review as a whole. On exit, the review is persisted as a custom git
ref containing JSON. The agent reads the ref and acts on your feedback.

## How it works

1. Agent runs `nvim -c 'CodeReview HEAD~3..HEAD'`
2. Neovim opens with a diffview showing the changes
3. You add line comments, file comments, and a verdict
4. You submit the review
5. A git ref is created under `refs/reviews/<id>` containing `review.json`
6. The ref name is written to `$NVIM_CODE_REVIEW_RESULT` for the agent to read

Reviews are stored as git objects. Read any review with:

```bash
git show refs/reviews/<id>:review.json
```

## Dependencies

- Neovim >= 0.10
- [diffview.nvim](https://github.com/dlyongemallo/diffview.nvim)
- git >= 2.30

## Specification

See [docs/spec.md](docs/spec.md) for the full requirements and design
specification.
