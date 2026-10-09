# Features

This page gives all the features of onbehalf. Each section ends with a
table of claims. The test in `test/checks/` that checks each claim is in the
"Checked by" column.

The tests run on fresh Ubuntu and Arch hosts for each test run. The AI
harness is real OpenCode with a fake model that always gives the same
answer. The tests use a real LiteLLM gateway and a real Forgejo Git server.

## Identity and isolation

- **One Unix account for each user.** The runtime of a user runs in
  that account, with its own service and port. A user cannot read the
  files, the environment or the runtime of a different user.
- **Native logins only.** Each user logs in to Git, GitHub CLI, Azure CLI
  and the MCP servers with the login of each tool. onbehalf never keeps,
  reads or sends a credential.
- **Attribution by default.** Commits, pushes and model use show the user
  whose runtime did them. When a commit has a false author, the push still
  shows the real user.
- **Secrets stay in their place.** Only the model gateway keeps the model
  provider key. No user can read that key or the admin key of the
  gateway.

| Claim | Checked by |
|---|---|
| No user can read the files, the environment or the runtime of a different user | `03-isolation` |
| Commits, pushes and model use show the user whose runtime did them | `08-attribution` |
| When a commit has a false author, the push still shows the real user | `08-attribution` |
| Many users with many sessions each work at the same time. Each session stays with its user | `08-concurrency` |
| No user can read the model provider key or the admin key of the gateway | `06-secrets` |
| Each user logs in to Git, GitHub CLI, Azure CLI and an OAuth MCP server as themselves | `11-work-tools` |

## One shared stack

- **Reviewed in Git, given read-only.** The team keeps `opencode.json`,
  `AGENTS.md`, custom agents, skills and commands in a repository.
  `onbehalf stack install` makes this shared stack current, read-only, for
  every user.
- **Personal overrides.** A personal setting, custom agent or skill replaces
  only the shared item with the same name. The project configuration has
  priority over both.
- **One update for all users.** A change to the shared stack gets to every
  user, also to the runtimes that run. You can go back to the previous
  version. Personal files stay.
- **Shared custom agents with limits.** A shared custom agent asks the
  user before each command that is not in its list of permitted commands.
- **A stack source for each AI harness.** `models.json` is the model
  catalog. `AGENTS.md` and `skills/` at the root are for each AI harness.
  onbehalf writes the gateway providers of OpenCode from `models.json`.

| Claim | Checked by |
|---|---|
| Shared settings, custom agents and skills get to every user | `07-stack-update` |
| One change to the shared stack gets to every user, also to the runtimes that run. Rollback works | `07-stack-update` |
| Personal tools in `~/.local/bin` stay available to the runtime after a change to the shared stack | `07-stack-update` |
| A shared custom agent asks the user before each command that is not in its list | `07-shared-agent` |
| A stack source with `models.json`, a root `AGENTS.md` and root skills gives each user the same result | `12-neutral-stack` |
| Personal settings keep the shared settings. Updates and rollback keep the personal overrides | `09-personal-models` |

## Model access through one gateway

- **A personal gateway key for each user.** The model gateway (LiteLLM)
  records the model use and the cost of each user.
- **A model catalog.** Each user selects from the models that the shared
  stack permits. A personal configuration cannot add a model. The shared
  stack turns off the built-in providers of OpenCode, because they do not
  go through the gateway.
- **One AI harness for each host.** The operator selects it. onbehalf
  checks that the gateway serves the API of that AI harness.

| Claim | Checked by |
|---|---|
| Gateway keys permit only the models in the model catalog, also after a model leaves the catalog | `09-personal-models` |
| Users see only the gateway providers of the shared stack, not the built-in providers of OpenCode | `09-personal-models` |
| `doctor --model-check` shows a refusal from the provider separately from the result of the host | `09-model-access` |
| `init`, `doctor` and `health` check the API of the AI harness of the host, without a model request | `13-harness-setting` |

## Enroll and offboard

- **Guided host setup.** `onbehalf setup` connects the gateway, installs the
  shared stack and adds users. When a necessary item is missing, it stops
  and shows the next step. Scripts use `init`, `stack install` and
  `user add`.
- **Enroll at the first login.** With `onbehalf auto-enroll on`, each user
  who can log in is enrolled at the first SSH login. For example, a user
  can log in with Entra ID on an Azure VM. Administrators are never
  enrolled. When a user does not log in for 30 days, that user loses
  the gateway key.
- **Follow an Entra group.** `onbehalf user sync` adds users to the group
  and removes them from it. It never takes over or removes an account by
  accident.
- **Guided tool logins.** `onbehalf tools` guides each user through the
  logins for Git, GitHub CLI, Azure CLI and the MCP servers of the shared
  stack, without root.
- **Adopt the accounts that you have.** A user keeps their own OpenCode
  configuration and keys.
- **Clean offboarding.** `onbehalf user remove` stops the runtime and
  revokes the gateway key. It leaves no data. The other users continue to
  work.

| Claim | Checked by |
|---|---|
| When the gateway or OpenCode is not ready, setup stops with a next step and changes nothing | `09-setup` |
| Each user who can log in is enrolled at the first login. Administrators are never enrolled | `09-auto-enroll` |
| Users follow an Entra group. No account is taken over or removed by accident | `05-entra-sync` |
| You can safely adopt an account that has its own configuration and keys | `04-adopt` |
| When you offboard an active user, no data stays. The other users continue to work | `10-offboarding` |

## Operators

- **Least privilege for operators.** An operator can run only onbehalf as
  root. The operator has no other sudo permission.
- **A separate runtime account.** The runtime of an operator runs in a
  different account. That account has no sudo permission and no access to
  the home directory of the operator. `onbehalf operator shell` opens it.

| Claim | Checked by |
|---|---|
| Operators can run only onbehalf as root. Their runtime runs in a separate account without sudo | `09-roles` |
| `doctor` and the login message find OpenCode in an operator account | `09-roles` |

## Checks and reports

- **`onbehalf doctor`** checks the host and every user. It shows a fix for
  each problem. `--model-check` sends one real model request. A provider
  can refuse requests when all the host checks pass.
- **`onbehalf status`** lets each user check their own setup, logins and
  model use. Each user can correct problems without root.
- **`onbehalf restart`** restarts the runtime of a user, of a runtime
  account, or of every user.
- **`onbehalf report`** shows who uses the runtimes. It shows logins, work
  tools, model requests, tokens, cost and failed requests for each user
  and model. It never shows what a user asked.
- **`onbehalf health`** checks the gateway, the shared stack, the disk, the
  provider and every key in a few seconds. `health on` runs the check each
  10 minutes. When a problem starts or stops, it sends a message to a Teams
  or Slack webhook.

| Claim | Checked by |
|---|---|
| `doctor` finds problems that break isolation. `status` gives fixes without root | `01-doctor` |
| The operator sees use, cost and failed requests for each user and model, but never what a user asked | `09-report` |
| Each user sees their own model use in `status`, and not the use of other users | `09-report` |
| Health checks send one alert when a problem starts and one when it stops. Only root can read the webhook URL | `09-health` |
