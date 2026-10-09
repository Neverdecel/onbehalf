# Example stack source

Copy this directory into a Git repository of your team. Change it there.
Review each change. To install a change on the host, run
`sudo onbehalf stack install <dir>`.

The team owns the content. onbehalf keeps only these items for its use:
`@GATEWAY_URL@`, the personal key reference
`{file:~/.config/onbehalf/gateway.key}` and the file name `opencode.jsonc`.

```
opencode/
  opencode.json   models and settings; the install writes the address for @GATEWAY_URL@
  AGENTS.md       harness instructions for every runtime
  agents/         shared custom agents, one Markdown file for each custom agent
  skills/         shared skills, one directory with a SKILL.md for each skill
tools/            optional: work tools of the team, one JSON file for each tool
```

For the format of a work tool, see
[Work tools of the shared stack](../../docs/operator-guide.md#work-tools-of-the-shared-stack).

## The whoami custom agent

`agents/whoami.md` is a small shared custom agent. It shows the accounts as
which the tools of the user act. It works with the tools that the user
installed, and it does not expect a specific tool.

Its `permission` block refuses file edits and web access. It permits
`id -un`. For each other command, it asks the user first. An
`opencode run` that is not interactive cannot ask, so it refuses those
commands. `opencode run --auto` approves them.

> **WARNING:** Do not use `opencode run --auto` with this custom agent.

## How the shared stack gets to each user

The shared `opencode.json` is a link in the `~/.config/opencode/` directory
of each user. OpenCode V2 applies the personal `opencode.jsonc` after these
settings. onbehalf links each named custom agent and skill separately. Thus
a personal item does not hide the other items of the shared stack.

> **WARNING:** Do not put `opencode.jsonc` or credentials in the stack
> source. Every user can read the shared stack.

`AGENTS.md` is one file, not a directory. When a user makes their own
`~/.config/opencode/AGENTS.md`, it replaces the shared harness
instructions. onbehalf keeps that file and does not merge the two files. A
project `AGENTS.md` in a repository also applies.

MCP connections and plugins are OpenCode settings too, so the shared stack
can share them. The tests cover a remote MCP server with OAuth. The tests do
not cover plugins yet. Before you share a connection, examine how it does
the authentication. Each user must log in as themselves. Or the
connection must read a personal secret through a reference, for example
`{file:~/...}`, the same as the gateway key.

## The model catalog

The enabled provider model entries are the model catalog. An operator
deploys a model on the gateway first. Then add the name of the model here.
The `modelID` values must be the same as the `model_name` values of the
gateway, for example in `examples/gateway/litellm.yaml`. If an entry has no
`modelID`, its entry name must be the same as a `model_name`.

A default `model` is optional. If you set it, it must be in the model
catalog. The installation and the rollback apply the model catalog to the
gateway keys. A user can select each model of the model catalog. A
personal configuration cannot give more gateway access.

## Two routes to the gateway

- `onbehalf-openai` uses the OpenAI API. The tests cover this route.
- `onbehalf-anthropic` uses the Anthropic API. This route keeps Claude
  features, for example prompt caching. The tests do not cover this route
  yet.

If the Anthropic route causes problems, add the Claude models to
`onbehalf-openai`. The gateway translates the request.
