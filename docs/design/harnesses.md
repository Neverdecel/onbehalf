# Design: Claude Code and Codex as AI harnesses

Status: investigation, 2026-10-09. No code changed. The tests below used
Claude Code 2.1.287, Codex 0.160.0 and the test gateway of `make test`
(LiteLLM v1.104.0).

## Goal

The operator selects one AI harness for the host: OpenCode, Claude Code or
Codex. A host never has more than one AI harness. onbehalf gives the same
contract for each AI harness:

- The runtime runs in the Unix account of the user.
- The runtime uses only the personal gateway key of the user.
- The shared stack gives the harness settings, the harness instructions and
  the named items to each user. Personal settings override them.
- The gateway key permits only the model catalog.

The model gateway must serve the API of the AI harness that the operator
selects. onbehalf checks this. It does not configure the gateway.

## Where the code expects OpenCode

| Area | Files | What expects OpenCode |
|---|---|---|
| Adapter | `lib/onbehalf/harness-opencode.sh` | The links into `~/.config/opencode`, the `opencode.jsonc` adoption, the service port of each user, the checks, the warning for `auth.json` |
| Model catalog | `common.sh`: `stack_models`, `stack_default_model`, `stack_validate`, `stack_providers_limited` | The model catalog comes from the providers in `opencode/opencode.json` |
| Callers | `cmd-stack.sh`, `cmd-user.sh`, `enroll.sh`, `cmd-doctor.sh`, `cmd-status.sh`, `cmd-health.sh`, `cmd-setup.sh` | They call `harness_opencode_*`, or use the `opencode` path or command |
| Runtime control | `cmd-restart.sh`, `roles.sh`, `login-profile.sh` | `opencode service restart`, `pgrep 'serve --service'`, the guard for operators |
| MCP work tool | `tools/90-mcp.sh` | `.mcp.servers` of `opencode.json`, `opencode mcp list` and `opencode mcp auth` |
| Installation | `install.sh`, `bin/onbehalf` | Only the `opencode` command, only `harness-opencode.sh` |
| Tests | `test/images/*`, `test/checks/*`, `test/stack/opencode` | Each runtime check uses `opencode run` |

These parts do not expect one AI harness: accounts, gateway keys and their
policy, offboarding, Entra, roles, `report`, and the work tools Git, GitHub
CLI and Azure CLI.

## Test results

The tests used a personal key with the onbehalf policy: two models of the
model catalog and the routes of `GATEWAY_USER_ROUTES`.

| Test | Result |
|---|---|
| The key calls `/v1/chat/completions`, `/v1/messages`, `/v1/messages/count_tokens` and `/v1/responses` | All four routes answer. The current routes are sufficient |
| Claude Code with `ANTHROPIC_BASE_URL` and an `apiKeyHelper` that reads `~/.config/onbehalf/gateway.key` | Claude Code answers through the gateway |
| Claude Code: `/etc/claude-code/managed-settings.json` sets `model`, `~/.claude/settings.json` sets a different `model` | The managed `model` wins. A personal default is not possible |
| Claude Code: managed settings without `model`, a personal `model` | The personal `model` applies |
| Claude Code: a model that is not in the model catalog | The gateway refuses it (403). Claude Code tries again until the timeout. The user sees no clear error |
| Codex with a provider in `/etc/codex/config.toml`, `wire_api = "responses"`, and `auth.command` that reads the key file through `$HOME` | Codex sends the request as the user. The gateway accepts the key |
| Codex: `~/.codex/config.toml` sets a different `model` | The personal `model` wins over `/etc/codex/config.toml` |
| Codex: a model that is not in the model catalog | The gateway refuses it |
| Codex reads `/v1/models` of LiteLLM | Codex cannot read the format. It writes an error and continues |

The test gateway could not give a full answer to Claude Code or Codex. This
is a problem of the test models, not of the AI harnesses:

- LiteLLM cannot stream a `mock_response` through `/v1/responses`.
- LiteLLM sends `/v1/responses` for `agent-model` to the fake model without
  a change. The fake model has no `/v1/responses` handler.
- LiteLLM cannot change the answer of the fake model into an Anthropic
  message.
- The fake model makes a tool call only for a tool with the name `shell`.
  Claude Code uses `Bash`.

## How each AI harness agrees with the contract

| Contract | OpenCode (today) | Claude Code | Codex |
|---|---|---|---|
| Gateway API | Chat completions or Anthropic messages | `/v1/messages` | `/v1/responses` only |
| Personal key | `{file:~/.config/onbehalf/gateway.key}` | `apiKeyHelper`: `cat "$HOME/.config/onbehalf/gateway.key"` | Provider `auth.command`: `sh -c 'cat "$HOME/..."'` |
| Shared harness settings | Link to the shared `opencode.json` | `/etc/claude-code/managed-settings.json`. Managed settings win over the user | `/etc/codex/config.toml`. The user wins |
| Personal settings | `~/.config/opencode/opencode.jsonc` | `~/.claude/settings.json` | `~/.codex/config.toml` |
| Model catalog in the AI harness | `enabled_providers` and the provider models | `availableModels` | The provider of `/etc/codex/config.toml` |
| Credentials that go around the gateway | `~/.local/share/opencode/auth.json` | `~/.claude/.credentials.json` | `~/.codex/auth.json` |
| Harness instructions | Link `~/.config/opencode/AGENTS.md` | Link `~/.claude/CLAUDE.md` | Link `~/.codex/AGENTS.md` |
| Custom agents, skills, commands | Links in `agents/`, `skills/`, `commands/` | Links in `~/.claude/agents/`, `skills/`, `commands/` | Skills only. The path is not tested yet |
| Service of each user | Yes, with a port for each user | No | No |
| Change of the shared stack | `opencode service restart` | Claude Code reads changed settings again. New sessions read new links | New sessions read the new configuration |
| MCP login | `opencode mcp auth NAME` | No command. The login is in the session (`/mcp`) | `codex mcp login NAME` |

## Recommended design

### 1. The operator selects the AI harness

`onbehalf setup` and `onbehalf init` write `ONBEHALF_HARNESS` to
`onbehalf.conf`. The value is one of `opencode`, `claude` or `codex`. A
host that has no value uses `opencode`, so the current hosts do not
change. Each adapter gives the routes of its API:

| AI harness | Routes |
|---|---|
| OpenCode | `/v1/chat/completions` (and `/v1/messages` for an Anthropic provider) |
| Claude Code | `/v1/messages`, `/v1/messages/count_tokens` |
| Codex | `/v1/responses` |

Before the setup changes the host, it sends one short request through the
routes of the AI harness. If the gateway does not answer, the setup stops and shows
the fix. `doctor` and `health` do the same check. `model_access_check` in
`common.sh` gets the API as a parameter.

`GATEWAY_USER_ROUTES` becomes the model routes, `/user/daily/activity`, and
the routes of the AI harness of the host. Thus a key cannot use an API that
the host does not use.

### 2. A model catalog that does not depend on the AI harness

Add `models.json` to the root of the stack source. It contains the model
catalog and an optional default model. The Codex configuration has no
setting for the models of a custom provider. Thus the model catalog must
have its own file. If the file
is not there, onbehalf reads the model catalog from
`opencode/opencode.json`, as today. `stack_validate` makes sure that the
configuration of the AI harness uses only models of the model catalog.

### 3. An adapter interface

Add `lib/onbehalf/harness.sh`. It loads only the adapter of the AI harness
of the host, and calls it:

- `user_add`, `stack_changed`, `user_remove`
- `check` (for `doctor` and `status`)
- `restart`, `runs` (for `restart` and the operator checks)
- `stack_installed` (root, one time for each installation)

`stack install` refuses a stack source without the directory of the AI
harness of the host: `opencode/`, `claude/` or `codex/`. A stack source
can have the directories of more AI harnesses. Then one stack source can
serve hosts with different AI harnesses. `doctor` shows an error when the
command of the AI harness is not installed for the host.

The operator can change the AI harness of a host. Then onbehalf removes the
links and the files in `/etc` of the old adapter, and enrolls each user
again with the new adapter. The personal settings and the private state of
the old AI harness stay in the account of the user.

`harness_opencode_link` and `harness_opencode_item` become one shared
function. Each adapter gives its source directory, its target directory and
the file name that it keeps for personal settings.

### 4. The Claude Code adapter

- `stack_installed` writes `/etc/claude-code/managed-settings.json` from
  `claude/managed-settings.json` in the shared stack. onbehalf adds
  `apiKeyHelper`, `env.ANTHROPIC_BASE_URL`, `availableModels` and
  `env.CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`.
- `stack_validate` refuses `model` in the managed settings. A team default
  in managed settings stops each personal default.
- `user_add` links `CLAUDE.md` and each named item into `~/.claude/`.
- `check` gives a warning for `~/.claude/.credentials.json`.
- There is no port and no service.

### 5. The Codex adapter

- `stack_installed` writes `/etc/codex/config.toml` from `codex/config.toml`
  in the shared stack. onbehalf adds the provider for the gateway and the
  `auth.command` for the personal key.
- `user_add` links `AGENTS.md` and each skill.
- `check` gives a warning for `~/.codex/auth.json`.
- There is no port and no service.

### 6. The other commands

- `restart` acts only for an AI harness with a service. For Claude Code and
  Codex, it tells the user to start a new session.
- `login-profile.sh` and `roles.sh` also find `claude` and `codex` in an
  operator account.
- The MCP work tool supports Codex in a later step, with `codex mcp login`.
  Claude Code has no login command, so the MCP work tool does not support
  it.

### 7. Tests

- Add Claude Code and Codex to the test images, with a lock file, as for
  OpenCode.
- Give the fake model a `/v1/responses` handler and an Anthropic answer.
  Let it accept `Bash` as the name of the shell tool.
- Add `claude/` and `codex/` to `test/stack`.
- For each AI harness, check these items:
  - It answers through the gateway as the user.
  - Git records the user.
  - A personal setting stays after a stack update.

## Risks

- Claude Code: managed settings win over personal settings. The shared
  stack can give no default that a user can change.
- Claude Code: a model that the gateway refuses gives no clear error.
- The quality of the API change in LiteLLM for models of other providers.
  A Claude model behind Codex, or a GPT model behind Claude Code, can lose
  features.
- Codex: the path of the shared skills is not tested yet.

## Steps

1. Model catalog and adapter interface. This step changes no behavior.
2. The selection of the AI harness and the gateway checks.
3. The Claude Code adapter and its tests.
4. The Codex adapter and its tests.
5. The docs: `project.md`, `CONTRIBUTING.md` (the terminology table), the
   operator guide, the user guide, the FAQ, the README and `examples/stack`.
