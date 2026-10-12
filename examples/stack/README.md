# Example stack source

Copy this directory into a Git repository of your team. Change it there.
Review each change. To install a change on the host, run
`sudo onbehalf stack install <dir>`.

This stack source does not depend on one AI harness. It works on a host
with OpenCode, with Claude Code or with Codex. The team owns the content.

```
models.json       the model catalog and an optional default model
AGENTS.md         harness instructions for every runtime
skills/           shared skills, one directory with a SKILL.md for each skill
opencode/         only for OpenCode
  opencode.json   settings of OpenCode
  agents/         shared custom agents, one Markdown file for each custom agent
tools/            optional: work tools of the team, one JSON file for each tool
```

You can add these directories:

- `claude/` for Claude Code: `managed-settings.json` with the team
  settings, and the directories `agents/` and `commands/`.
- `codex/` for Codex: `config.toml` with the team settings.

For the format of a work tool, see
[Work tools of the shared stack](../../docs/operator-guide.md#work-tools-of-the-shared-stack).

## The model catalog

`models.json` is the model catalog. An operator deploys a model on the
gateway first. Then add the name of the model here:

```json
{
  "model": "gpt-5.4",
  "models": {
    "gpt-5.4": { "api": "openai" },
    "claude-sonnet-4-5": { "api": "anthropic" }
  }
}
```

- Each name in `models` must be a `model_name` of the gateway, for example
  in `examples/gateway/litellm.yaml`.
- `model` is the default model. It is optional. Without it, the first model
  is the default model.
- `api` is optional. Only OpenCode uses it. See
  [Two routes to the gateway](#two-routes-to-the-gateway).

The installation and the rollback apply the model catalog to the gateway
keys. A user can select each model of the model catalog. A personal
configuration cannot give more gateway access.

## What onbehalf writes

onbehalf writes the gateway address, the reference to the personal gateway
key and the model catalog into the configuration of each AI harness. Do not
set these items in the stack source. `onbehalf stack install` refuses a
stack source that sets them.

| File | Do not set |
|---|---|
| `opencode/opencode.json` | `providers`, `enabled_providers`, `model` |
| `claude/managed-settings.json` | `model`, `apiKeyHelper`, `availableModels`, `env.ANTHROPIC_*`, `env.CLAUDE_CODE_USE_*` |
| `codex/config.toml` | `model`, `model_provider`, the provider `onbehalf` |

`AGENTS.md` and each skill must be in one location only: at the root, or in
the directory of one AI harness.

> **WARNING:** Do not put credentials or the file `opencode.jsonc` in the
> stack source. Every user can read the shared stack.

## How the shared stack gets to each user

| AI harness | Shared settings | Links in the account of the user |
|---|---|---|
| OpenCode | The link `~/.config/opencode/opencode.json` | `AGENTS.md`, and each skill, custom agent and command, in `~/.config/opencode/` |
| Claude Code | `/etc/claude-code/managed-settings.json` | `CLAUDE.md`, and each skill, custom agent and command, in `~/.claude/` |
| Codex | `/etc/codex/config.toml` | `AGENTS.md` and each skill, in `~/.codex/` |

onbehalf links each named item separately. Thus a personal item does not
hide the other items of the shared stack.

The harness instructions are one file, not a directory. When a user makes
their own file, it replaces the shared harness instructions. onbehalf keeps
that file and does not merge the two files. A project `AGENTS.md` in a
repository also applies.

## The whoami custom agent

`opencode/agents/whoami.md` is a small shared custom agent for OpenCode. It
shows the accounts as which the tools of the user act. It works with the
tools that the user installed, and it does not expect a specific tool.

Its `permission` block refuses file edits and web access. It permits
`id -un`. For each other command, it asks the user first. An
`opencode run` that is not interactive cannot ask, so it refuses those
commands. `opencode run --auto` approves them.

> **WARNING:** Do not use `opencode run --auto` with this custom agent.

## MCP connections and plugins

MCP connections and plugins are settings of the AI harness, so the shared
stack can share them. The tests cover a remote MCP server with OAuth for
OpenCode. The tests do not cover plugins yet. Before you share a
connection, examine how it does the authentication. Each user must log in
as themselves. Or the connection must read a personal secret through a
reference, the same as the gateway key.

## Two routes to the gateway

This section applies only to OpenCode. onbehalf writes one provider for
each `api` value of `models.json`:

- `onbehalf` uses the OpenAI API (`"api": "openai"`, the default). The
  tests cover this route.
- `onbehalf-anthropic` uses the Anthropic API (`"api": "anthropic"`). This
  route keeps Claude features, for example prompt caching. The tests do not
  cover this route for OpenCode yet.

If the Anthropic route causes problems, remove `"api": "anthropic"` from
the model. The gateway translates the request.

## A stack source of version 0.1.0

A stack source without `models.json` keeps its function. Then the enabled
provider model entries of `opencode/opencode.json` are the model catalog.
Such a stack source works only for OpenCode. To use Claude Code or Codex,
add `models.json`, and remove `providers`, `enabled_providers` and `model`
from `opencode.json`.
