# factory

A [Gas City](https://github.com/gastownhall/gascity) installation that orchestrates
multi-agent work across the `repldriven` repositories.

The city lives in [`gascity/`](gascity/) rather than the repository root, leaving the
root free for other software-factory work.

## Layout

```
.gitignore
gascity/            <- the city root (city.toml, .gc/, .beads/)
```

`gc` locates the city by walking *up* from the working directory, so commands work
from `gascity/` or anywhere beneath it. From the repository root, pass the path
explicitly:

```bash
gc --city gascity status
```

`bd` does not walk up past the city root — run it from `gascity/` or below, or set
`BEADS_DIR`.

## Rigs

The city's HQ is the `factory` rig (bead prefix `fa`). Work happens in two external
rigs, checked out as siblings of this repository:

- **mono** (`mono-`) — `../mono`
- **queenswood** (`qw-`) — `../queenswood`

Rig paths are machine-local and live in `.gc/site.toml`, which is not versioned.
`city.toml` carries only the portable `[[rigs]]` blocks, so a fresh clone declares
the same rigs without inheriting anyone's directory layout. Add or remove rigs with
`gc rig add` / `gc rig remove`.

## Roles and models

Each rig imports the role set from the `gascity/roles` pack, pinned by commit in
`packs.lock`. Roles are split across two models:

- **Fable** — `requirements-planner`, `task-decomposer`, `design-author`,
  `gap-analyst`, `issue-triager`
- **Opus** — `implementation-worker`, `implementation-reviewer`,
  `design-implementation-reviewer`, `design-test-risk-reviewer`,
  `review-synthesizer`, `publisher`, `run-operator`

Two things to know before editing that split in `city.toml`:

- Model selection goes through provider `args`. There is no provider `model` field —
  setting one is accepted silently, dropped, and leaves the agent on the default.
- Every `[[patches.agent]]` needs `dir`. Each role exists once per rig, so a patch
  without it fails to resolve. That is also what lets the rigs diverge.

Agents run as `claude` CLI sessions under tmux, authenticated with the logged-in
account. An `ANTHROPIC_API_KEY` in the environment would silently redirect them to
paid API billing, so keep it unset.

## Running it

```bash
cd gascity
gc start            # register with the supervisor and start the city
gc status           # controller, agents, rigs
gc doctor           # health checks
gc dashboard        # web UI, served by the supervisor
```

Dispatching work — a bead must live in the same database as the agent that will
work it, hence `--rig`:

```bash
gc bd create "title" --rig mono
gc sling mono/gc.implementation-worker <bead-id> --on do-work
```

No `default_sling_target` is configured, so name the target explicitly.

## Conventions

`main` is protected by an organisation ruleset: no force-pushes, linear history,
signed commits, and one approving review. Only the initial commits landed directly;
everything since goes through a pull request.

`.gc/`, `.beads/` (except `identity.toml`) and `.claude/skills/` are generated and
machine-local. The skills are symlinks into `~/.gc/cache`, rebuilt on start from the
pack commits pinned in `packs.lock`.
