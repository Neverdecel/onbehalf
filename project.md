# Project: onbehalf

## Scope of the MVP and phase 1

### Goal

The MVP and phase 1 have one goal: a shared host that works.

- Root does only the work that must have root.
- Each user makes all the other changes in their own account, without
  the operator. These changes include personal configuration, their own
  custom agents and skills, tool logins, tools in their home directory, and
  repositories.
- onbehalf stays at the Unix layer: accounts, file owners, permissions,
  links and services. onbehalf does not install, operate or configure the
  applications. The only exception is the small contract below.

### Rule

- onbehalf owns WHO acts and HOW the shared stack gets to each user.
- The applications own WHAT runs and HOW it runs.
- The user owns all the items in their own account.

### Owners

| Area | Owner | Root necessary |
|---|---|---|
| Installation of the AI harness (for the full host; OpenCode today) | Operator, with the documentation of the AI harness | Yes |
| Installation of the work tools (Git, GitHub CLI, Azure CLI and others) | Operator, with the documentation of each tool | Yes |
| Model gateway (LiteLLM, database, provider keys, models) | Operator, with the LiteLLM documentation. `examples/gateway` is only an example | Yes (on its own host or in Docker) |
| Connection to the gateway (`onbehalf init`) | onbehalf | Yes |
| Shared stack (`onbehalf stack install`) | onbehalf gives it to each user. The team owns the content | Yes |
| Accounts, personal gateway keys, isolation, offboarding | onbehalf | Yes |
| Personal settings (`opencode.jsonc`), own custom agents and skills | The user | No |
| Logins to work tools and MCP connections (with help from `onbehalf tools`) | The user, with the login of each tool | No |
| Tools in the home directory (`~/.local/bin`, npm prefix, pipx and similar tools) | The user | No |
| Repositories and project configuration | The user and the AI harness | No |
| Check of the personal setup (`onbehalf status`), restart of the own runtime | The user | No |

### Contract

1. The model gateway and the AI harness are prerequisites.
   - `onbehalf setup` connects to a model gateway that runs. It never
     installs a gateway.
   - If a prerequisite is missing, the setup stops before it changes the
     host. It shows the steps to do.
   - Host checks send no model requests. A check of the model access sends
     one short request as a user, only when the operator asks for it.
2. Each model is in two locations. This is intentional. An operator deploys
   a model on the gateway first. Then the team adds the model name to the
   model catalog in the shared stack. onbehalf only makes sure that the
   gateway has each model of the model catalog.
3. The shared stack is configuration of the AI harness. onbehalf keeps only
   these items for its use: `@GATEWAY_URL@`, the personal key reference
   `{file:~/.config/onbehalf/gateway.key}` and the file name
   `opencode.jsonc`.
4. onbehalf does not set a workspace layout. It does not stop a change that
   a user makes in their own account. The only exceptions are the files
   that keep identity and isolation safe: the gateway key and the mode of
   the home directory.

The work that is larger than the shared host is in
[Later phases](#later-phases).

## Architecture

### Runtime limits

onbehalf owns the runtime limit at the Unix account. It also gives the
shared stack to each user. An adapter for each AI harness uses this
contract. A terminal client or a web client connects to the runtime of a
user. The client does not set the identity that acts.

Each runtime runs as the Unix account that owns the session. The work tools
(Git, GitHub CLI, Azure CLI and others) use the login stores and the
permissions of that account. A different AI harness must keep the same
contract for identity and isolation. OpenCode is the first adapter. Oh My
Pi is the planned second adapter.

Attribution comes from the account that the external system records. A name
that a user can configure, for example the Git commit author, is not
sufficient. Linux permissions keep usual accounts apart. The host
administrators stay trusted. The isolation between accounts does not give
protection against root.

### Configuration: three levels

| Level | Contents | Owner and change path |
|---|---|---|
| Shared stack | Harness settings, default model, model catalog, harness instructions, shared custom agents and skills | The team keeps and reviews it in its Git repository. It is read-only on the host |
| Personal state | Tool credentials, personal gateway key, sessions and other runtime state | Private to the Unix account that owns it. It is never part of the shared stack |
| Personal overrides | Personal harness settings, model selection, own custom agents and skills | The user can edit them. They replace items of the shared stack when the runtime reads the configuration |

The runtime reads the shared stack. Then it applies the overrides of the
user. When a setting or a named item is in the two levels, the personal
override has priority. The shared items that the user did not replace
stay. The runtime does not change the personal overrides. It does not copy
them into the shared stack. The private state is not part of the
configuration.

An adapter must use the configuration loader of the AI harness when that
loader has the same priority rules. A user can select a personal default
model from the model catalog. The gateway controls the model access, not a
configuration file that a user can change. Overrides do not give access to
the state of a different user. They do not change permissions in Azure,
GitHub or other external systems.

### OpenCode adapter contract

| Layer | Path | Behavior |
|---|---|---|
| Shared stack | `/opt/onbehalf/stack/current/opencode/` | A release that root owns. `opencode.json` supplies the shared settings and the model catalog |
| Personal overrides | `~/.config/opencode/opencode.jsonc` | The V2 loader of OpenCode applies these settings after the shared `opencode.json`. The project configuration has a higher priority |
| Named items | `~/.config/opencode/{agents,skills,commands}/` | Personal directories contain a link to each shared named item. A personal entry replaces only the item with the same name |
| Private state | `~/.config/onbehalf/gateway.key` and the stores of each tool | One Unix account owns them. The shared stack contains no credentials or sessions |

The adapter does not make a merged configuration. A user selects the
model of a session with the selector of OpenCode. A user sets personal
defaults with JSONC. The enabled provider model entries are the model
catalog. The API ID is `modelID` when the entry has it. If not, the API ID
is the name of the model entry. Disabled entries give no access.

Enrollment makes or updates a gateway key. The key permits only the model
catalog, inference, and the model use of the user. A stack installation
does these steps:

1. It checks the optional default model and the models of the gateway.
2. It updates and checks the policies of the gateway keys.
3. It makes the new release current on the host.

If a key update fails, the host release does not change. But the keys that
the installation updated before the failure can keep the new policy. Then
install the reviewed source again, or install the previous reviewed source.
This is not a distributed transaction. A rollback puts back the access. It
does not change keys, personal overrides or private state.

The configuration that a user can change controls the model selection,
not the authorization. The gateway refuses requests for models that are not
in the key. It refuses the management routes for personal keys. These
controls do not stop a user who has their own provider credentials. That
user can use the provider without the gateway of the team.

The built-in providers of OpenCode use no credentials. Thus the shared stack
must turn them off with `enabled_providers`. That setting is configuration,
not a control. Only a control of the outbound traffic of the host stops a
user who runs OpenCode with a different configuration. Permit outbound
HTTPS only to the gateway.

### Governance and delivery of the shared stack

A user can always change their own layer, without the approval of a
curator. Each user can propose a shared improvement. The team decides who
approves a change to the shared stack.

The team keeps the stack source in its own Git repository. We recommend
this sequence:

1. A user proposes a change.
2. The team reviews the change.
3. An approved user merges the change.
4. An operator runs `stack install` for that revision.

A rollback installs a previous revision. It does not change the personal
state or the overrides.

The shared stack contains custom agent definitions, harness instructions,
harness settings, the default model, the model catalog and the gateway
endpoint. Each host installs one release of it that root owns. A user does
not get a checkout that they can change. Every user reads the same
reviewed version, and nobody can change it for the other users.
Infrastructure code, for example Terraform, makes the host and installs the
AI harness and the work tools. onbehalf gives the shared stack to each
user.

The shared stack does not select the work tools that a user uses or logs
in to. Each user brings their own logins. Shared custom agents work with
the tools that the user has. They ask before they act.

Shared skills run with the credentials of each user. Thus an unsafe shared
change can have an effect on the full team. Review each change to the
stack source before you install it.

In the MVP and phase 1, the team does this review with its own tools.
`stack install` installs the directory that root gives it. onbehalf does not
enforce a curator role, a reviewed merge or a Git source. These controls are
in [Phase 2](#phase-2-make-a-product).

### Provisioning and the account lifecycle

onbehalf configures a Linux installation that you have. It does not supply
an OS image. The operator installs the AI harness, the work tools and the
other applications with the documentation of each application. onbehalf
installs only the system packages for its own use. When it runs again, it
must keep the state of each account and the personal overrides.

When onbehalf makes an account, it starts a bootstrap for that user. The
bootstrap can run again with the same result. It connects the configuration
of the AI harness to the shared stack. It prepares a private credential
store and the personal gateway access. With auto-enroll, the first SSH login
starts the same bootstrap for accounts that onbehalf did not make. An
example is an account of the Azure Entra login.

The bootstrap does not log in to Azure or GitHub for the user. Each user
completes the login of each tool. Offboarding stops the runtimes of the
user, revokes the personal gateway access and removes the private state
from the host. Revoke the external access in the systems that own it.

### Credential types

| Type | Function | Examples | Owner | Shared |
|---|---|---|---|---|
| Acting credential | Does actions in external systems | GitHub, Azure CLI, other cloud APIs | One user | Never |
| Model credential | Gives the runtime access to a model | Model provider API key | The team | Yes, but only through the model gateway |

The gateway keeps the model provider keys out of the configuration that
users can read. Each runtime uses its own personal gateway key. The
gateway records the model use and the cost of each user. It controls the
model access. Use limits for each user are Phase 2 work.

## Scope

This section applies to the MVP and phase 1. See
[Scope of the MVP and phase 1](#scope-of-the-mvp-and-phase-1).

### In scope

- Accounts for each user: make, adopt, isolate and offboard them.
- A connection from the host to one model gateway that runs, and one
  personal gateway key for each user.
- One shared stack for each user, with personal overrides. OpenCode is
  the only supported AI harness.
- Runtimes that run only as the user who starts them.
- Personal acting credentials through the login of each tool. Azure CLI,
  GitHub and OAuth MCP servers are the first integrations. onbehalf guides
  and checks these logins (`onbehalf tools`). It never keeps a credential.
- Attribution through the records of the external systems: the push
  credential, the Entra account and the gateway records.
- Documentation for operators and for users.
- A package of onbehalf that other teams can install.

### Out of scope

- The installation and operation of OpenCode, the model gateway or other
  applications. The operator uses the documentation of each application.
- Configuration of applications that is not in the [contract](#contract).
- A workspace layout, or rules for repositories in the home directory.
- Tools that a user installs in their own home directory.
- Work for later phases: curator control, a gateway adapter layer, a stack
  scaffold, `stack install` from Git, and the interface broker. See
  [Later phases](#later-phases).
- A new web interface or chat interface. Clients connect through a runtime
  broker for each user (Phase 3).
- The domain custom agents, skills and context of the team. onbehalf gives
  the distribution and the promotion controls, not the content.
- The management of cloud permissions or Git permissions. Azure RBAC and
  the GitHub organization roles stay with their current owners.
- The selection and the evaluation of models. The team selects the models.
  onbehalf only gives shared access to them.
- Runtimes on the local computers of users.
- A fixed ISO or OS image, or shared hosts with Windows or macOS.

## Current implementation

The MVP uses OpenCode and the terminal on Ubuntu and Arch Linux.
[Features](docs/features.md) gives the automated checks. The implementation
does not do all of the target architecture yet:

- You can run `install.sh` again. `user add` and the Entra sync enroll
  accounts. With auto-enroll, sshd enrolls each account at its first login,
  for example an account of the Azure Entra login. Administrators are never
  enrolled.
- An interactive login offers the host setup to root. Users get a short
  start message and one offer of the work tool wizard (`onbehalf tools`).
- Operators can run only `onbehalf` as root, and they never have a gateway
  key. An operator who wants a runtime gets a separate runtime account.
  `doctor` and the login message find OpenCode in an operator account.
- `onbehalf restart` restarts the runtime of a user, of a runtime account,
  or of every runtime that runs.
- `onbehalf report` shows adoption, model use, cost and failed requests for
  each user and model, from the gateway records. It never shows prompts.
- `onbehalf health` checks the host, the gateway and the provider. With
  `health on`, it runs each 10 minutes and sends an alert when a problem
  starts or stops. See [monitoring](docs/design/monitoring.md).
- `onbehalf status` shows the model use of the user, and only of that
  user.
- The OpenCode adapter uses the V2 loader of OpenCode. It reads the shared
  `opencode.json` first, then the personal `opencode.jsonc` overrides.
  Named custom agents and skills replace shared items one by one. The
  project configuration has a higher priority.
- The provider model entries of the shared stack are the model catalog.
  Enrollment, updates and rollback limit the personal gateway keys to the
  model catalog.
- `enabled_providers` in the shared stack permits only the gateway
  providers. `stack install` refuses a stack source without it, and
  `doctor` shows the problem. This setting guides OpenCode. The gateway and
  the network rules of the host control the access.
- The activation on the host and the updates of the gateway keys are not
  one transaction. After a failed installation, install again.
- Each stack installation makes a release with a version. But a root
  operator can install each source directory. There is no curator role or
  reviewed merge that onbehalf enforces.
- OpenCode is the only supported AI harness. External Azure attribution
  checks and signed commits are planned work.

### Acceptance criteria for the target design

- The bootstrap can run again, and it does not lose credentials, sessions
  or overrides.
- A personal override changes only the configuration of that user. The
  other users continue to read the shared stack.
- Updates and rollbacks of the shared stack keep the private state and the
  personal overrides.
- A shared change must have a merge that a curator approves, and a reviewed
  delivery (Phase 2).
- Each supported AI harness keeps the identity of the user. External audit
  records show that user. A usual account cannot read or use the private
  state of a different account.

## Later phases

### Phase 2: Make a product

- Curator control: only a revision that a curator approves can become the
  shared stack, with a tested rollback.
- `stack install` from a Git repository and a revision, not only from a
  local directory.
- A stack scaffold command that makes a new stack source.
- A gateway adapter layer: onbehalf makes or applies the gateway
  configuration from one model manifest. In the MVP, an operator keeps the
  gateway configuration.
- Full repeatable Linux provisioning. Enrollment at the first login also for
  logins that are not SSH. The MVP enrolls when it makes an account and,
  with auto-enroll, at the first SSH login.
- The same override contract for the second AI harness.
- Changes to the shared stack without lost work. In the MVP, a change to the
  shared stack restarts all runtimes that run, and stops their work. Phase 2
  restarts only runtimes with no work. It restarts the other runtimes when
  their work is complete.
- Credentials with a short life, where the provider supports them. This
  decreases the damage when a credential leaks.
- An audit log of the sessions of each user. The log shows who did each
  action, and when.
- Model use limits and cost reports for each user, through the model
  gateway.
- Support for Oh My Pi as the second AI harness. This shows that onbehalf
  does not depend on one AI harness.
- A first production host, Azure attribution checks, signed commits and
  more tool integrations.
- Delegated access through OAuth on-behalf-of (OBO) for one downstream API.
  This is not implemented yet. It must have:
  - A client application and a middle-tier application.
  - Delegated scopes and consent.
  - An MSAL OBO test.

  Until then, the login of each tool is the acting credential.

### Phase 3: Interface broker

- Identify the users who come from a web interface. Send each user to
  their own runtime.
- First integration: OpenChamber, without a shared password and without a
  shared OpenCode server.
- Session control for each user: start, stop, and stop after a period
  with no activity.

### Phase 4: Extended governance

- Policy controls for the actions of the runtimes, for each user or each
  role.
- Audit records that the team can export for compliance.
- Support for more than one host, with one shared stack for all hosts.

## Open questions

- Does the runtime of a user start only on request, for example through a
  broker or a socket? Or does it run all the time?
- Which GitHub authentication method becomes the standard: `gh` CLI
  authentication, fine-grained tokens or SSH keys?
- Can Azure access use credentials with a short life in the MVP? Or must
  this wait for Phase 2?
- How does the adapter for each AI harness show overrides for settings and
  named skills?
- Which login integration starts the bootstrap for Unix accounts that a
  different system makes?
