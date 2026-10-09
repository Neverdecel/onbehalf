# How it works

onbehalf manages one shared Linux host for a team. Each user gets the same
reviewed setup. The runtime of each user runs in the account of that
user.

<p align="center">
  <img src="assets/architecture.svg" alt="One host gives one read-only, reviewed shared stack to all users. The runtime of each user runs in the Unix account of that user, with personal overrides, tool logins and a gateway key. The model gateway keeps the provider key of the team. GitHub and Azure record each action as the user." width="100%">
</p>

Every user reads the same reviewed shared stack. The runtime of each
user runs in the Unix account of that user, with personal logins and a
personal gateway key. Only the model gateway keeps the provider key of the
team.

## Three layers

<p align="center">
  <img src="assets/layers.svg" alt="Three layers on one host. The operator installs the host software: an AI harness, the work tools and the model gateway. onbehalf gives the read-only shared stack: opencode.json, AGENTS.md, custom agents, skills and commands. Each user keeps their own settings, custom agents, skills, tool logins, gateway key, sessions and service port. The project configuration has priority over the personal configuration, and the personal configuration has priority over the shared stack. Unix permissions, the gateway key and the external systems control access." width="100%">
</p>

`sudo onbehalf stack install <dir>` makes the shared stack current in
`/opt/onbehalf/stack/current/`. Each user gets a link for each item in
`~/.config/opencode/`. A user cannot edit the shared files.

The configuration has three levels:

1. The project configuration in the repository has the highest priority.
2. The personal configuration of the user is next.
3. The shared stack has the lowest priority.

## What is shared, what stays personal

| Component | Task of the operator | What users share | What stays personal |
|---|---|---|---|
| AI harness | Install and update it for the full host (OpenCode today) | The same program and version | Runtime: service, sessions, history and work |
| Work tools | Install Git, GitHub CLI, Azure CLI and the other work tools of the team | The same program and version | Logins, permissions, configuration and credentials |
| Model gateway | Run LiteLLM and its database, or connect to a gateway that the team has | Gateway infrastructure and model deployments | Personal gateway key and the model use of the user |
| Model catalog | Add deployed models to the shared stack | Available models and the default model | Personal model selection from the permitted models |
| Harness settings | Set shared settings in the shared stack | Shared settings | Personal overrides |
| Harness instructions | Supply a shared `AGENTS.md` | The same instructions for all runtimes | Project instructions. A personal `AGENTS.md` replaces the shared file |
| Custom agents and skills | Add them to the shared stack | Shared custom agents and procedures | Personal custom agents, skills and overrides |
| MCP connections | Define the common connections in the shared stack | Connection definitions | The OAuth login of each user, with help from `onbehalf tools` |
| Plugins | Configure plugins in the shared stack | Common plugin configuration | Personal configuration and state (not tested yet) |
| Accounts | Add users, give gateway keys, set service ports | The same account rules | A separate Unix account and a private home directory |

## What onbehalf does not do

onbehalf is not an ISO or a VM image. It works at the Unix layer of a Linux
host that you have: accounts, file owners, permissions, links and services.
Root does only the work that must have root. Each user makes all the
other changes in their own account.

- **It does not install or operate the AI harness, the model gateway or the
  work tools.** The operator does this with the documentation of each tool.
- **It does not log anybody in.** A tool on the host gives nobody a login.
  Each user logs in to each tool with the login of that tool.
- **The rules of a custom agent are not access control.** The `permission`
  block of a shared custom agent only guides the runtime. Unix permissions,
  the gateway and the external systems control access.
- **The gateway controls the model access, not OpenCode.** Permit outbound
  traffic from the host only to the gateway. Then no runtime can go around
  the gateway.
- **It does not make a shared workspace.** Each user clones repositories
  into their own home directory.
- **The shared stack is not a secret store.** Every user can read the
  shared stack. Do not put a credential in it.

See the [architecture](../project.md#architecture) and the
[scope](../project.md#scope-of-the-mvp-and-phase-1) for the full design.

## Compared to other setups

| | Setup on each laptop | One shared account on a host | Shared configuration in a dotfiles repository | onbehalf |
|---|---|---|---|---|
| One reviewed setup for the team | No | Yes | Yes, if each user pulls it | Yes, read-only for each user |
| Actions recorded as the user | Yes | No | Yes | Yes |
| The credentials of a user are hidden from the other users | Yes | No | Yes | Yes |
| Model use and cost for each user | Only with separate provider keys | No | Only with separate provider keys | Yes, through one gateway |
| Model access only to the model catalog | No | No | No | Yes, the gateway key controls it |
| Offboard without a secret to change | Yes | No | Yes | Yes |
