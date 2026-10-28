# Changelog

This file gives the important changes in each version of onbehalf. It
tells you if you must update and what the update changes. The version is
in `lib/onbehalf/VERSION`.

## Unreleased

- Show fixed CLI labels and task results in telemetry observation names.
  Add safe categories for structured input, syntax, connection and access errors.
  Raw commands, arguments and error messages stay private.

- `onbehalf status --json` gives the checks of `status` as JSON, for
  scripts.
- `make try` starts the demo environment on a laptop, with a shell as the
  operator `ops`. See "Try it on your laptop" in the README.

- Add operator-controlled `--identity named|pseudonymous` telemetry modes.
  Keep content capture off in both modes and preserve the saved identity setting.

- Send lowercase Langfuse observation types so Code Mode containers remain
  spans and unobserved results remain events, not tool-latency samples.

- Add tool execution spans inside Code Mode, first-response times and task
  counters. Export fixed command labels and authenticated user pseudonyms
  instead of raw commands, account names and host names.
  After an upgrade, regenerate the telemetry configuration with its existing
  destination and authorization. `doctor` warns about stale privacy configuration.
  Keep cancellations and missing timing separate from tool failures and latency.

### Work tools

- A shared MCP server with a personal login can have `"disabled": true`
  in the stack. Then OpenCode does not show it to a user who did not log
  in. After a login with `onbehalf tools`, onbehalf turns it on for that
  user in `opencode.jsonc`. Each stack install updates these copies. See
  the operator guide, section "MCP servers with a personal login".

### Telemetry

- Spans identify the shared stack, the harness and the telemetry plugin.
  Token totals include cache and reasoning categories without double counts.
  Skill names, safe error categories and task results support comparisons.
- Failed telemetry exports retry within a fixed memory limit. Metadata and
  safe warnings report export failures and dropped spans.
- Commands with common credential forms are replaced with `[redacted]`.
  Unmarked secrets can still pass this check. Keep credentials out of
  command arguments.
- `onbehalf telemetry on --export URL` sends the tool calls and the model
  steps of each user to an OpenTelemetry backend, through the OTel
  Collector of the host. Each span has the Unix account of the user. Only
  OpenCode is supported. See the operator guide, section "Telemetry".
- The operator installs `otelcol-contrib`. onbehalf writes its
  configuration and gives each user a personal telemetry key.
- Each prompt is a task: one trace, with the model steps and tool calls
  as child spans. Each span has the OpenCode session and the user.
- `examples/telemetry` runs the OTel Collector and Langfuse with Docker
  Compose.
- The Collector gives each tool call the class `read`, `write` or
  `unknown`, from rules for the tool name and the command. A stack source
  can add rules in `telemetry/classes.json`. They come before the default
  rules.
- `examples/telemetry/dashboards.sh` makes four Langfuse dashboards for
  each user: usage and adoption, cost, tool calls and reliability.
- The Collector keeps only the first line of a command, with a maximum of
  300 characters, and its full length. The rules see the full command. Thus
  the body of an inline script, with paths and tokens, does not get to the
  backend.
- More default class rules: a script or `curl` with an HTTP write method,
  a write command in list form, `--help`, `--version` and `command -v`.
- The installer now checks for `openssl`.

## 0.2.0 (2026-10-12)

This version adds Claude Code and Codex as AI harnesses. The operator
selects one AI harness for each host.

### Shared stack

- A stack source can have `models.json` as its model catalog, and
  `AGENTS.md` and `skills/` at its root. Then the stack source does not
  depend on one AI harness. onbehalf writes the gateway providers of
  OpenCode from `models.json`. A stack source with
  `opencode/opencode.json` and no `models.json` works as before.

### Model gateway

- `onbehalf init --harness NAME` selects the AI harness of the host. The
  value is in `onbehalf.conf`. A host without the value uses OpenCode.
- `init`, `doctor` and `health` check that the gateway serves the API of
  the AI harness. The check sends no model request.
- `doctor --model-check`, `status --model-check` and the health probe
  send their request with the API of the AI harness.
- `sudo onbehalf harness NAME` changes the AI harness of a host. It
  checks the command, the shared stack and the gateway first. Then it
  updates the routes of each gateway key and stops the runtimes of the
  old AI harness. It removes the links of the old AI harness and gives
  each user the links of the new AI harness. Each user keeps the gateway
  key, the personal settings and the private state.

### Claude Code

- `onbehalf init --harness claude` selects Claude Code. The stack source
  must have `models.json`.
- `stack install` writes the managed settings of Claude Code from
  `models.json`: the gateway, the personal gateway key, the model catalog
  and the default model. `/etc/claude-code/managed-settings.json` is a
  link to the current release. Team settings go in
  `claude/managed-settings.json` of the stack source.
- Each user gets links in `~/.claude`: `CLAUDE.md` to the shared
  `AGENTS.md`, and each shared skill, custom agent and command.
- A user can set a different default model in `~/.claude/settings.json`.
- `doctor` and `status` warn about `~/.claude/.credentials.json`.
- Claude Code has no service. `onbehalf restart` tells the user to start
  a new session.

### Codex

- `onbehalf init --harness codex` selects Codex. The stack source must
  have `models.json`.
- `stack install` writes the system configuration of Codex from
  `models.json`: the gateway provider, the personal gateway key and the
  default model. `/etc/codex/config.toml` is a link to the current
  release. Team settings go in `codex/config.toml` of the stack source.
- Each user gets links in `~/.codex`: `AGENTS.md` to the shared
  `AGENTS.md`, and each shared skill.
- A user can set a different default model in `~/.codex/config.toml`.
- `doctor` and `status` warn about `~/.codex/auth.json`.
- Codex has no service. `onbehalf restart` tells the user to start a new
  session.
- The gateway key of a user on a Codex host permits only the responses
  API.

### Docs

- The guides give the setup and the use of each AI harness. The operator
  guide has a section about a change of the AI harness.
- `examples/stack` is now a stack source with `models.json`. It works for
  each AI harness. In OpenCode, its provider of the OpenAI API has the
  name `onbehalf`, not `onbehalf-openai`. A stack source that you copied
  from version 0.1.0 does not change.
- Recorded casts show the operator setup, the first login of a user and
  the report. The README, the site and the guides show them. `make demo`
  records them again from a clean test host. See `demo/README.md`.

### Upgrade

Get the files of this version and run the installer again. A host keeps
OpenCode as its AI harness, and its stack source keeps its function. Then
run `sudo onbehalf doctor`. To use Claude Code or Codex, see the
[operator guide](https://github.com/Neverdecel/onbehalf/blob/main/docs/operator-guide.md#change-the-ai-harness).

## 0.1.0 (2026-10-09)

This is the first version. It is for a proof of concept on one shared
host with Ubuntu or Arch.

### Users and operators

- `onbehalf user add` and `onbehalf user remove` enroll and offboard a
  user: account, gateway key, shared stack and runtime.
- `onbehalf user sync` keeps the users the same as the members of an
  Entra group.
- A user can enroll at their first SSH login.
- Operators are separate from users. The runtime of an operator runs in a
  separate runtime account.
- `onbehalf restart` starts the runtime of a user again.

### Shared stack and work tools

- `onbehalf stack install` makes a reviewed shared stack current for each
  user. It starts the runtimes again.
- The model catalog permits only the providers of the model gateway.
- `onbehalf tools` guides a user through the login of each work tool and
  each MCP connection. Operators can add work tools in the shared stack.

### Checks

- `onbehalf setup` guides the first setup of the host and checks the
  access to the model gateway.
- `onbehalf doctor` checks the host and each user, and gives the fix for
  each problem.
- `onbehalf status` shows a user their setup, their logins and their
  model use. It also shows at each login.
- `onbehalf report` shows who uses the runtimes, how much, and which
  requests fail.
- `onbehalf health` sends an alert when a problem starts or stops.

### Security

- Each user has a personal gateway key. A user cannot read the files,
  logins or sessions of a different user. The tests prove this.
- Account names use only lowercase ASCII letters, digits and the signs
  `.`, `_`, `@` and `-`. A fuzzer checks the name rules.

### Upgrade

There is no earlier version. To install, follow the
[operator guide](https://github.com/Neverdecel/onbehalf/blob/main/docs/operator-guide.md).
