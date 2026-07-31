# .dev — developer-local links into this project's AI-tooling state

Symlinks to the state that AI tooling reads and writes **for this repo
only** — no global/all-projects state is linked here. Same convention as
`writeonce-all/.dev`: **user-specific absolute paths, gitignored** (only
this README is committed). Each developer recreates them for their own
machine (commands below).

| Link | Points at | What a developer uses it for |
| --- | --- | --- |
| `claude-project/` | `~/.claude/projects/<this-repo, slashes→dashes>` | Claude Code's per-project state: session transcripts (`*.jsonl`) and `memory/` (the persistent memory index + facts). Grep a past session, read/curate what Claude remembers about this repo. |

## reference/ — related source trees

`reference/` holds read-only symlinks to related projects under
`~/projects/` used as reference material — analyze the referenced files
when their behavior matters to this repo:

| Link | Points at | Why it's a reference |
| --- | --- | --- |
| `reference/cronie/` | `~/projects/cronie` | The cronie cron daemon sources — the authority on cron.d parsing and scheduling semantics that `src/Cron.hx` mimics. |

Deliberately **not** linked (global, cross-project state): `~/.claude`
(all projects' transcripts), `~/.config/opencode` and
`~/.local/share/opencode` (global config; sessions for every project,
keyed by opaque project hashes), `~/.cache/llama.cpp` (shared model
weights). If opencode is used on this repo later, its per-project
`storage/session/<project-hash>` directory can be linked here once the
hash exists.

Related: project-level agent definitions go in `.claude/agents/*.md`
(Claude Code) and `.opencode/agents/*.md` (opencode) at the repo root —
those are *committed* when they should be shared with the team, unlike
these links.

## Recreate on a new machine

Run from the repo root:

```bash
ln -sfn "$HOME/.claude/projects/$(pwd | tr / -)" .dev/claude-project
mkdir -p .dev/reference
ln -sfn "$HOME/projects/cronie" .dev/reference/cronie
```

(`claude-project`: Claude Code names the directory after the repo's absolute
path with `/` replaced by `-`, hence the `pwd | tr` trick.)

## Privacy

This link points into **private state**: full conversation transcripts and
Claude's memory for this repo. It is gitignored so none of it can be
committed — keep it that way, and don't bulk-feed the directory to tools
that upload content.
