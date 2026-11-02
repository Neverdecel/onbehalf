# Example stack source

Copy this directory into a Git repository of your team. Change it there.
Review each change. To install a change on the host, run
`sudo onbehalf stack install <dir>`.

This stack source is for OpenCode, the AI harness of onbehalf. The team
owns the content.

```
models.json       the model catalog and an optional default model
AGENTS.md         harness instructions for every runtime
skills/           shared skills, one directory with a SKILL.md for each skill
opencode/         optional
  opencode.json   settings of OpenCode
  agents/         shared custom agents, one Markdown file for each custom agent
  plugins/        shared OpenCode plugins, for example onbehalf-status.js
tools/            optional: work tools of the team, one JSON file for each tool
```

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
key and the model catalog into the configuration of OpenCode. Do not set
`providers`, `enabled_providers` or `model` in `opencode/opencode.json`.
`onbehalf stack install` refuses a stack source that sets them.

`AGENTS.md` and each skill must be in one location only: at the root, or in
`opencode/`.

> **WARNING:** Do not put credentials or the file `opencode.jsonc` in the
> stack source. Every user can read the shared stack.

## How the shared stack gets to each user

The shared settings are the link `~/.config/opencode/opencode.json`. Each
user also gets a link for `AGENTS.md`, and for each skill, custom agent and
command, in `~/.config/opencode/`.

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
OpenCode, and the status plugin below. Before you share a
connection, examine how it does the authentication. Each user must log in
as themselves. Or the connection must read a personal secret through a
reference, the same as the gateway key.

## The status plugin

`opencode/plugins/onbehalf-status.js` records a short status for each
session of a user. A session board shows it. See the
[session board design](../../docs/design/session-board.md).

The plugin writes `~/.local/state/onbehalf/sessions.json`, with mode 600.
For each session, the file has these fields:

| Field | Meaning |
|---|---|
| `status` | `in progress`, `blocked`, `done` or `stopped`. |
| `title` | The title of the session. |
| `directory` | The directory of the session. |
| `line` | The last line of the last answer, with a maximum of 200 characters. |
| `question` | The open permission request, when the status is `blocked`. |
| `updated` | The time of the last change, in milliseconds. |

A board reads the file through the OpenCode API of the user, for example
through the [example broker](../broker/README.md):

```text
GET /api/fs/read/.local/state/onbehalf/sessions.json?path=~
```

The plugin writes only to the home directory of the user. It sends
nothing to the network. It keeps the last 200 sessions. The file contains
the last line of each answer, so do not copy it to a shared location.

## Two routes to the gateway

onbehalf writes one provider for each `api` value of `models.json`:

- `onbehalf` uses the OpenAI API (`"api": "openai"`, the default). The
  tests cover this route.
- `onbehalf-anthropic` uses the Anthropic API (`"api": "anthropic"`). This
  route keeps Claude features, for example prompt caching. The tests do not
  cover this route yet.

If the Anthropic route causes problems, remove `"api": "anthropic"` from
the model. The gateway translates the request.

## Tool classes for the telemetry

A stack source can have `telemetry/classes.json`: the rules that give each
tool call the class `read` or `write`. Its rules come before the default
rules of onbehalf. See the operator guide, section "Tool classes". This example
has no file, so the default rules apply.

## A stack source of version 0.1.0

A stack source without `models.json` keeps its function. Then the enabled
provider model entries of `opencode/opencode.json` are the model catalog.
