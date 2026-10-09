# onbehalf: user guide

This host has one AI harness setup for the full team. You use it with your
own account. Your runtime acts as you, with your credentials. It cannot act
as a different user. Other users cannot act as you.

You do not use root for your own changes. You own all the items in your
account: your settings, custom agents, skills, logins, tools and
repositories.

![alice logs in through SSH for the first time and sets up Git and GitHub CLI. The runtime of alice runs whoami and a git commit: both show alice.](assets/demo/user.gif)

## 1. Log in

Log in to the host with your own account:

```
ssh <you>@<host>
```

Do not use a shared account.

On some hosts, onbehalf enrolls you at your first login. Then the first
login takes a few seconds more. If the start message says that onbehalf did
not set up your account, log in again. If the problem stays, speak to the
operator.

## 2. Start the AI harness

At your first interactive login, a short message shows how to start:

```
opencode
```

Each subsequent login shows a few lines about what is important for you
now:

```
onbehalf · start the AI harness: opencode
  · The shared stack changed after your last login: new team settings, custom agents, skills or work tools.
  ! Work tools to finish: onbehalf tools gh
  · Problems: onbehalf status · User guide: /usr/local/share/onbehalf/docs/user-guide.md
```

The stack line shows only after an update. The work tools line shows only
when a tool must still have a login. The states of the work tools can be up
to one day old. `onbehalf status` checks them now.

You get the models, custom agents and skills of the team. The model access
is ready. You do not have to get a model provider key or do a setup. The
gateway records your model use for your account.

## 3. Make your own changes

Do these changes yourself. You do not have to speak to the operator, and
you do not use root.

### Set up your work tools

Your runtime works as you: with your Git identity and your own logins. At
your first interactive login, onbehalf offers a short menu to set them up.
You can skip the menu. You can run it again at any time:

```
onbehalf tools
```

```
◆ Work tools  ·  first login
────────────────────────────────────────────────────────────
  ↑↓ move   space select   enter confirm   esc skip

    Work tools
  ❯ ◉  Git              not set
    ◉  GitHub CLI       not logged in
    ◉  Azure CLI        not logged in

    MCP connections
    ◉  tracker          not logged in

       Continue →
       Skip for now
```

The menu shows two groups. The work tools are first, then the MCP
connections of the team. If there are no MCP connections, the menu shows
only the work tools, without a group name.

The menu selects the tools that are not set up. A tool that is set up shows
its current setup and is not selected. Thus Enter changes nothing. To
change a tool, select it. For each selected tool, the wizard tells you the
step. Then it starts the usual login of that tool:

| Tool | What the wizard does |
|---|---|
| Git | It asks for your name and email for commits (`git config --global`). If your account has a link to an Entra account, the wizard shows that email first. |
| GitHub CLI | It runs `gh auth login`. Then it checks the login with `gh auth status`. |
| Azure CLI | It runs `az login --use-device-code` and shows the account and the tenant. If your account has a link to Entra ID, it makes sure that you used that account. |
| Tools of the team | Your operator can add more tools, for example Vault. The wizard runs the usual login of that tool. |
| MCP servers | It shows the MCP servers of the team that use your own login. Then it runs `opencode mcp auth NAME`. |

At the end, a summary shows the tools that are ready. It also shows the
command for the other tools, for example `onbehalf tools gh`. To stop only
one login, push Ctrl-C during that login. The menu shows a tool that is not
installed on the host, but you cannot select it. Ask the operator to
install it.

Through SSH, an MCP login ends in your browser at an address on
`127.0.0.1`. Your computer cannot open that address. Copy the full address
from the address bar, and paste it into the wizard. The wizard opens the
address on the host. Then OpenCode can complete the login.

Your credentials stay in your home directory, in the usual location of each
tool. Other users cannot read them. onbehalf does not keep or read them.
You can also use the commands of each tool, for example:

```
az login --use-device-code
gh auth login
git config --global user.name 'Your Name'
git config --global user.email you@example.com
opencode mcp auth <server>
```

### Change your settings

Put your personal settings in `~/.config/opencode/opencode.jsonc`. For
example, set a personal default model:

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "model": "onbehalf-openai/gpt-5.4"
}
```

Use an entry from the model catalog of your team. Then restart your
runtime:

```
onbehalf restart
```

Your settings replace the shared settings with the same name. The other
shared settings stay. Stack updates and rollbacks keep your file.

Do not edit `~/.config/opencode/opencode.json`. It is a link to the shared
stack, and you cannot change it.

### Add your own custom agents and skills

Put your own custom agents in `~/.config/opencode/agents/`. Use one
Markdown file for each custom agent. Put your own skills in
`~/.config/opencode/skills/`. Use one directory with a `SKILL.md` file for
each skill.

A personal item with the same name as a shared item replaces only that
shared item for you. The other shared items stay. Stack updates do not
remove your files.

### Install tools in your home directory

Install your own tools in your home directory, for example in
`~/.local/bin`:

```
npm config set prefix ~/.local     # npm install -g then goes to ~/.local
pipx install <package>             # if pipx is on the host
```

If `~/.local/bin` is not in your `PATH`, add it to your login profile. Do
not use `~/.bashrc`. Your runtime does not read it when the operator
changes the shared stack. Run these commands one time:

```
f=~/.profile; [ -f ~/.bash_profile ] && f=~/.bash_profile
echo 'export PATH="$HOME/.local/bin:$PATH"' >>"$f"
```

The commands use `~/.bash_profile` if it is there, for example on Arch
Linux. If not, they use `~/.profile`. Then log in again and restart your
runtime. Speak to the operator only for system packages.

### Work in your repositories

Clone repositories into a directory in your home directory. onbehalf does
not set a layout. The project configuration in a repository, for example
`opencode.json` or `AGENTS.md`, has a higher priority than your personal
settings and the shared settings.

### Check your setup

```
onbehalf status
```

The command shows your shared stack, your model access, your model use,
your work tools and your logins. It shows a fix for each problem. For a
work tool, the fix is `onbehalf tools <tool>`. The command also gives a
warning if your Azure login uses a different Entra account.

Your model use is the number of requests, failed requests, tokens and the
estimated cost of the last 7 and 30 days. Only you and the operators of the
host can see it. Nobody can see what you asked.

If the runtime gets no answer from the model, send one short test request:

```
onbehalf status --model-check
```

It shows if the gateway or the model provider refused the request. The
request is part of your model use.

To see as which accounts your tools act, do these steps:

1. Start `opencode`.
2. Push Shift+Tab until you select the `whoami` custom agent.
3. Ask: *Who do my tools act as?*

The `whoami` custom agent looks for the tools that you installed. It asks
you before each command. It cannot change files.

## Tasks for the operator

Speak to the operator only for these tasks:

- An account and a personal gateway key.
- A change to the shared stack of the team. Propose the change in the stack
  source of the team.
- A new model. An operator deploys it on the gateway first. Then the team
  adds it to the shared stack.
- System packages and the OpenCode installation for the full host.

## Useful information

- **Select a model.** For the current session, use `/models`. For one run,
  use `opencode run --model <provider/model> 'your prompt'`. The selected
  model of a session has priority over your default model.
- **Many sessions at the same time.** Open more terminals or tabs. They all
  use your one runtime. A restart of the runtime stops the work in all of
  them, also a restart from a stack update. Your sessions stay.
- **Model access.** Your gateway key can use only the models of the team.
  When you add a model to a personal file, you do not get access to it. If
  a model leaves the model catalog, select a different model. Your personal
  file does not change.
- **Do not add personal model keys**, for example with
  `opencode auth login`. The team gives model access through the gateway. A
  personal key goes around the records of the gateway. `onbehalf status`
  gives a warning about it.
- **Do not change your gateway key. Do not let other users read your home
  directory.** These rules keep your identity safe. The operator checks them
  with `onbehalf doctor`.
- **Changes to the shared stack.** When the operator changes the shared
  stack, your runtime restarts. The work that runs at that time stops.
- **Problems.** Run `onbehalf status`. If the fix must have root, send the
  output to your operator.
