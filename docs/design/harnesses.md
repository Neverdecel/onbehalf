# Design: Claude Code and Codex as AI harnesses

Status: accepted, 2026-10-09. The work starts with step 1. The tests below used
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

## Design

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

Before `init` saves the configuration, it checks the routes of the AI
harness. The check sends a GET to each route. The gateway gives 405 for a
route that it serves, and 404 for a route that it does not serve. The check
sends no model request and uses no key, because the
[contract](../../project.md#contract) does not permit model requests in host
checks. If a route is missing, `init` stops and shows the fix. `doctor` and
`health` do the same check.

The model access check (`doctor --model-check`, `status --model-check` and
the health probe) sends its one request with the API of the AI harness. It
runs only when the operator or the user asks for it, as before.

`GATEWAY_USER_ROUTES` becomes the model routes, `/user/daily/activity`, and
the routes of the AI harness of the host. Thus a key cannot use an API that
the host does not use.

### 2. A stack source that does not depend on the AI harness

onbehalf promises that it does not depend on one AI harness. Thus a team
can change the AI harness of a host and keep its stack source.
The items that the three AI harnesses share go to the root of the stack
source. A directory for each AI harness keeps only the settings of that AI
harness:

```
models.json      the model catalog and an optional default model
AGENTS.md        the harness instructions
skills/          the skills, one directory with a SKILL.md for each skill
tools/           the work tools of the team, as today
opencode/        settings, custom agents and commands of OpenCode
claude/          settings, custom agents and commands of Claude Code
codex/           settings of Codex
```

- **Model catalog.** onbehalf reads `models.json`. Each adapter writes the
  models into the configuration of its AI harness: the providers of
  OpenCode, `availableModels` of Claude Code, the default model of Codex.
  The team does not write the model catalog two times.
- **Harness instructions.** OpenCode and Codex read `AGENTS.md`. The Claude
  Code adapter links `~/.claude/CLAUDE.md` to the same file.
- **Skills.** The three AI harnesses use the same `SKILL.md` format. Each
  adapter links each skill into the skills directory of its AI harness.
- **Custom agents, commands, MCP connections.** The formats are different,
  so they stay in the directory of each AI harness. A neutral format for
  MCP connections is possible later.

The format of `models.json`:

```json
{
  "model": "gpt-5.4",
  "models": {
    "gpt-5.4": { "api": "openai" },
    "claude-sonnet-4-5": { "api": "anthropic" }
  }
}
```

Each key of `models` is a `model_name` of the gateway. `api` is optional.
The default is `openai`. Only the OpenCode adapter uses it, to select the
provider package. `model` is the optional default model.

`stack install` builds the release in two steps:

1. It copies the stack source, as today.
2. For each harness directory in the release, it copies the root
   `AGENTS.md` and the root `skills/` into that directory. Then the adapter
   of that AI harness writes its configuration from `models.json`. A stack
   source with only `models.json`, `AGENTS.md` and `skills/` gets an
   `opencode/`, a `claude/` and a `codex/` directory.

Thus each adapter links only its own directory of the release. One release
serves each AI harness. A change of the AI harness does not make a new release.

For OpenCode, the adapter writes the providers `onbehalf` (OpenAI API) and
`onbehalf-anthropic` (Anthropic API), `enabled_providers` and `model` into
`opencode.json`. The `opencode.json` of the team must not set these keys.

`stack_validate` refuses these stack sources:

- The same item at the root and in a harness directory: `AGENTS.md`, or a
  skill with the same name.
- A harness configuration that sets the model catalog, the providers or the
  default model when `models.json` is there.

The current stack sources keep their function. If `models.json` is not
there, onbehalf reads the model catalog from `opencode/opencode.json`, as
today. Such a stack source serves only OpenCode.

### 3. An adapter interface

Add `lib/onbehalf/harness.sh`. It calls the adapter of the AI harness of
the host. Each adapter `harness-NAME.sh` gives the same functions:

| Function | Use |
|---|---|
| `build DIR` | Write the harness configuration into the release directory DIR (root, at `stack install`) |
| `activate` | Write the files of the AI harness in `/etc` (root, after the release is current) |
| `deactivate` | Remove the files of the AI harness in `/etc` (root, at a change of the AI harness) |
| `user_add`, `stack_changed`, `user_remove`, `user_unlink` | The links and the state of one user |
| `check` | The checks of one user, for `doctor` and `status` |
| `host_check` | The checks of the host, for `doctor` and `health` |
| `restart`, `runs` | For `restart` and the operator checks |

The link code of the OpenCode adapter becomes one shared function. Each
adapter gives its source directory, its target directory and the file name
that it keeps for personal settings.

`doctor` shows an error when the command of the AI harness is not
installed for the host.

### 4. A change of the AI harness

`sudo onbehalf harness NAME` changes the AI harness of a host:

1. It checks that the command of the new AI harness is installed for the
   host.
2. It checks that the current release has the directory of the new AI
   harness.
3. It checks that the gateway serves the API of the new AI harness.
4. It updates the routes of each gateway key.
5. It removes the links of the old adapter from each user, and calls
   `deactivate` of the old adapter.
6. It writes `ONBEHALF_HARNESS`, calls `activate` of the new adapter, and
   calls `user_add` for each user.

The personal settings and the private state of the old AI harness stay in
the account of the user.

### 5. The Claude Code adapter

- `build` writes `claude/managed-settings.json` in the release. `activate`
  copies it to `/etc/claude-code/managed-settings.json`. onbehalf adds
  `apiKeyHelper`, `env.ANTHROPIC_BASE_URL`, `availableModels` (from
  `models.json`) and `env.CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`.
- `stack_validate` refuses `model` in the managed settings. A team default
  in managed settings stops each personal default.
- `user_add` links `~/.claude/CLAUDE.md` to the shared `AGENTS.md`. It
  links each skill, and each custom agent and command of `claude/`, into
  `~/.claude/`.
- `check` gives a warning for `~/.claude/.credentials.json`.
- There is no port and no service.

### 6. The Codex adapter

- `build` writes `codex/config.toml` in the release. `activate` copies it
  to `/etc/codex/config.toml`. onbehalf adds the provider for the gateway, the
  `auth.command` for the personal key, and the default model of
  `models.json`.
- `user_add` links `~/.codex/AGENTS.md` to the shared `AGENTS.md`, and
  links each skill.
- `check` gives a warning for `~/.codex/auth.json`.
- There is no port and no service.

### 7. The other commands

- `restart` acts only for an AI harness with a service. For Claude Code and
  Codex, it tells the user to start a new session.
- `login-profile.sh` and `roles.sh` also find `claude` and `codex` in an
  operator account.
- The MCP work tool supports Codex in a later step, with `codex mcp login`.
  Claude Code has no login command, so the MCP work tool does not support
  it.

### 8. Tests

- Add Claude Code and Codex to the test images, with a lock file, as for
  OpenCode.
- Give the fake model a `/v1/responses` handler and an Anthropic answer.
  Let it accept `Bash` as the name of the shell tool.
- Add `claude/` and `codex/` to `test/stack`.
- The full test suite stays on OpenCode, for Ubuntu and Arch.
- Claude Code and Codex get a smaller suite, on Ubuntu only. It checks
  these items:
  - The runtime answers through the gateway as the user.
  - Git records the user.
  - A user cannot read the gateway key of a different user.
  - A personal setting stays after a stack update.
  - `doctor` finds personal credentials that go around the gateway.
- CI runs four host test jobs: OpenCode on Ubuntu and Arch, Claude Code
  and Codex on Ubuntu.

## Risks

- Claude Code: managed settings win over personal settings. The shared
  stack can give no default that a user can change.
- Claude Code: a model that the gateway refuses gives no clear error.
- The quality of the API change in LiteLLM for models of other providers.
  A Claude model behind Codex, or a GPT model behind Claude Code, can lose
  features.
- Codex: the path of the shared skills is not tested yet.

## Steps

Each step is one pull request. Each pull request starts from the previous
one.

1. The neutral stack source and the adapter interface. A current stack
   source gives the same result as before.
2. The selection of the AI harness, and the gateway checks.
3. The Claude Code adapter and its tests.
4. The Codex adapter and its tests.
5. `onbehalf harness NAME`.
6. The docs: `project.md`, `CONTRIBUTING.md` (the terminology table), the
   operator guide, the user guide, the FAQ, the README and `examples/stack`.
