# Changelog

This file gives the important changes in each version of onbehalf. It
tells you if you must update and what the update changes. The version is
in `lib/onbehalf/VERSION`.

## Unreleased

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

### Docs

- Recorded casts show the operator setup, the first login of a user and
  the report. The README, the site and the guides show them. `make demo`
  records them again from a clean test host. See `demo/README.md`.

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
