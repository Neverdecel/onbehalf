# Demo casts

The casts show what the operator and a user do on a shared host. They are
in `docs/assets/demo`. The README and the site show the `user` cast only.
The user guide and the operator guide show the casts for each role.

| Cast | What it shows |
|---|---|
| `operator-setup` | The operator `ops` installs onbehalf, runs `sudo onbehalf init`, installs the example stack and adds `alice` and `bob`. |
| `user` | `alice` logs in through SSH for the first time and sets up Git and GitHub CLI. Then the runtime of `alice` runs a command as `alice`. |
| `operator-report` | The operator runs `sudo onbehalf report` and `sudo onbehalf health`. The report shows the model use of `alice`. |

## Make the casts again

Make the casts again after a change to the CLI output. You must have Docker
with Compose.

```sh
make demo
```

The command starts a clean environment, records the three casts in order and
removes the environment. Each cast continues from the state of the last cast.
If a cast fails, read the log in `demo/.<cast>.log`.

## The environment

`demo/compose.yaml` starts these containers:

- `devbox`: the shared host. It is the clean Ubuntu test host with an SSH
  server and the operator account `ops`. onbehalf is not installed. The
  `operator-setup` cast installs it.
- `gateway`: a real LiteLLM model gateway with a PostgreSQL database.
- `fake-model`: the stand-in model of the tests,
  `test/fake-model/server.js`. For a prompt line `RUN: <command>`, it tells
  the runtime to run that command.
- `vhs`: [VHS](https://github.com/charmbracelet/vhs). It runs each `.tape`
  file in this directory and connects to `devbox` through SSH.

The gateway has the models of `examples/stack`. Thus the operator installs
the example stack. No request goes to a real model provider.

`fixtures/gh.sh` and `fixtures/az.sh` are stand-ins for the GitHub CLI and
the Azure CLI. They show a device login, but they do not connect to GitHub
or Azure.

All keys in `compose.yaml` are fixed values for this environment only. They
give no access to a real model or a real account.

## Change a cast

1. Edit the `.tape` file. `settings.tape` has the size, the theme and the
   speed for all casts. `prompt.tape` sets a short local prompt.
2. Run `make demo`.
3. Look at each new GIF file before you commit it.

Keep each cast short. A visitor must read each screen before the next
one. Show one step on each screen (`clear`), and keep the last screen for
some seconds.

Use `Wait` with a regular expression for the shell prompt or the last line.
`Wait+Screen` does not find text after the screen scrolls.
