# Contributing

Thank you for your help. onbehalf decides for which user a runtime acts on
a shared host. Thus we examine each change first for identity, isolation and
attribution.

## Before you start

- Read the [architecture](project.md#architecture) and the
  [current implementation](project.md#current-implementation).
- For a change that is larger than a fix, open an issue first. Describe the
  problem in the issue. When we agree on the approach first, nobody must
  write the change two times.
- Do not put a security problem in a public issue. See
  [SECURITY.md](SECURITY.md).

## Development

The tests run in rootless Docker. Each test run starts from clean
containers:

- An Ubuntu or Arch host.
- A LiteLLM gateway with mock models.
- A fake model for the runtimes.
- A Forgejo Git server.

Docker keeps the images in its cache. It never keeps the containers.

```sh
make lint          # shellcheck, shfmt, hadolint, yamllint, lint-docs (same as CI)
make lint-docs     # ASD-STE100 and terminology checks for the docs
make test          # Ubuntu and Arch
make test-ubuntu   # one distribution
make shell-arch    # root shell in a fresh test host
make rebuild       # rebuild images without cache
```

A change in behavior must have a test in `test/checks/`. The test must fail
without the change.

CI runs on each push and on each pull request. It runs the lint first, and
then the full host tests on Ubuntu and Arch. If a pull request changes only
docs, the site or repository metadata, the host test jobs pass and do not
run the tests. The `changes` job in `.github/workflows/ci.yml` has the list
of these files. A different security workflow runs these checks:

- gitleaks on the full history.
- Dependency review.
- Trivy.
- CodeQL for the workflows.

A fuzz workflow runs the fuzzers in `test/fuzz/` with ClusterFuzzLite. It
runs on each pull request that changes `lib/`, and one time each week. A
fuzzer gives random input to the bash functions and compares the result
with a reference in Python. When you change a name rule in `lib/onbehalf/`,
change the reference in `test/fuzz/` also.

Each action has a pin to a commit SHA. Dependabot keeps the pins current. To
report a vulnerability, see [SECURITY.md](SECURITY.md).

```
bin/onbehalf        the CLI
lib/onbehalf/       commands, output helpers, OpenCode adapter
install.sh          installer
docs/               operator and user guides
examples/           example shared stack and gateway deployment
test/               test environment, checks, fuzzers, fixtures and the docs lint
```

### Add a work tool

For a tool of one team, use a file in the shared stack. See
[Work tools of the shared stack](docs/operator-guide.md#work-tools-of-the-shared-stack).
Add a tool to onbehalf only when many teams use it, or when it must have
more than one check and one login.

A work tool is one file in `lib/onbehalf/tools/`. `onbehalf tools` shows the
tool in the menu. `onbehalf status` checks the tool, and the summary shows
it. The file name sets the sequence. For example,
`lib/onbehalf/tools/40-vault.sh`:

```bash
# shellcheck shell=bash
# Work tool: HashiCorp Vault, logged in with the user's own account.

tool_register vault "Vault" "Your own Vault login, for the team's secrets."

# No prompts. ok, todo (not set up), warn (set up, but wrong) or missing.
tool_vault_state() {
  command -v vault >/dev/null || { TOOL_STATE=missing TOOL_DETAIL="not installed"; return 0; }
  if vault token lookup >/dev/null 2>&1; then
    TOOL_STATE=ok TOOL_DETAIL="logged in"
  else
    TOOL_STATE=todo TOOL_DETAIL="not logged in"
  fi
}

# The guided step: explain, then run the tool's own login.
tool_vault_setup() {
  say "Log in with your own account. The token stays private to you."
  note "Now the usual Vault login: vault login -method=oidc"
  printf '\n'
  tool_native vault login -method=oidc
}
```

Rules for a work tool:

- Use the login and the credential store of the tool. onbehalf never asks
  for a credential. It never keeps or reads a credential.
- Run the login with `tool_native`. Then Ctrl-C stops only that step.
- Return 0 when the step is complete. The wizard then checks the state
  again. Return 3 when the user keeps the current setup. Return a
  different value when the step fails.
- Add the case to `test/checks/11-work-tools.sh`. If the real tool must have
  a network login, add a fake tool in `test/fixtures/`.

## Writing style (ASD-STE100)

Write all text in ASD-STE100 Simplified Technical English. This rule applies
to the docs, the diagrams, the CLI help, the CLI output, the commit messages
and the pull request descriptions. It applies to all future text too.

- Use only words that STE approves. Use each word with its approved meaning
  only. You can also use technical names and technical verbs, for example
  the terms in the [terminology table](#terminology), commands and product
  names.
- Use one word for one thing. Use the same word each time.
- Keep a procedural sentence to 20 words or fewer. Keep a descriptive
  sentence to 25 words or fewer.
- Keep a paragraph to 6 sentences or fewer. Give each paragraph one topic.
- Write an instruction in the imperative. Write one instruction in each
  sentence. Put a list of steps in a vertical list.
- Use the active voice. Write who or what does the action.
- Use the simple tenses: past, present and future.
- Do not use the -ing form of a verb, except in a technical name.
- Do not use contractions. Write `do not`, not `don't`.
- Do not use `e.g.`, `i.e.` or `etc.`. Write "for example" or a full list.
- Start a warning or a caution with a short command. Then give the risk.
- Use the article ("a", "an", "the") before a noun when English permits it.

`make lint-docs` checks the sentence length, contractions, relative links,
and the words in `test/lint/ste-words.txt`. The STE dictionary is not free
to copy, so the list has only frequent mistakes. A reviewer checks the other
rules. Add a new docs file to `test/lint/ste-files.txt`.

## Terminology

Use these terms in the CLI output, the docs, the diagrams and the commit
messages. They agree with the table
[What is shared, what stays personal](docs/how-it-works.md#what-is-shared-what-stays-personal).

<!-- lint-docs: words off -->

| Term | Meaning | Do not use |
|---|---|---|
| Host | The Linux machine that onbehalf manages. Write "shared host" the first time in a text. | server, machine, VM (except where the form of deployment is important) |
| AI harness | The program that every user uses, installed one time on the host. OpenCode today, Oh My Pi planned. Write OpenCode only for a command, file or setting of OpenCode. | agent, coding harness, CLI harness, agent harness |
| Runtime | The running instance of the AI harness for one user: its service, sessions, history and state. It runs as that user. Write "harness runtime" the first time in a text. Write "OpenCode service" only for the unit. | agent, agent service |
| Work tools | Git, GitHub CLI, Azure CLI and the other tools that act as the user. Each tool has its own login. | toolchain |
| Model gateway | The gateway that keeps the provider keys and records the model use (LiteLLM today). An operator runs it or connects the host to it. | |
| Model catalog | The models that the shared stack permits: the enabled provider model entries in `opencode.json`. | model list, curated list, stack list, allowed models |
| Stack source | The directory or Git repository where an operator edits the shared stack. | stack directory, stack repository |
| Shared stack | The reviewed, read-only version that `onbehalf stack install` makes current. Every user gets it: harness settings, harness instructions, custom agents, skills, commands and the model catalog. Releases are an internal detail. | baseline, blueprint, stack release |
| Harness settings | Settings of the AI harness. Shared settings come from the shared stack. Personal settings override them. | |
| Harness instructions | `AGENTS.md`. | agent instructions |
| Custom agents, skills | Named items in the shared stack or in the account of a user. A personal item replaces the shared item with the same name. "Agent" is the name that the AI harness uses for this feature. | |
| MCP connections | MCP servers that the shared stack defines. Each user logs in. | |
| User | A team member whose runtime runs in their own Unix account. | person |
| Operator | An account that can run onbehalf as root. An operator also runs the model gateway or connects the host to it. An operator is never a user. | gateway admin |
| Runtime account | The separate account where the runtime of an operator runs. | agent account |
| Enroll | Prepare a user: account, gateway key, shared stack and runtime. | onboard |
| Offboard | Stop the runtime, revoke the gateway key and remove the user from onbehalf. | unenroll, deprovision |
| Gateway key | The personal key of a user for the model gateway. | |
| Logins | The credentials of a user in each work tool, made with the login of that tool. | |
| Status | A user checks their own setup and logins. | |
| Doctor | An operator checks the host and every user, and sees the fix for each problem. | |
| Health | An automatic check that onbehalf works. It sends an alert when a problem starts or stops. | monitoring (as a command name) |
| Report | An operator sees who uses the runtimes, how much, and which requests fail. | |

<!-- lint-docs: words on -->

Some internal names keep the old words, so that the hosts and the scripts
that use onbehalf continue to work: the names of runtime accounts
(`NAME-agent`), the JSON field `agent_of`, the old option `--agent` of
`operator add` and the old option `--person` of `doctor`. Do not use these
names in new text.

## Pull requests

- Start each branch from `main`. Put one change in each pull request.
- Write commit messages in the imperative: "Add …", "Fix …".
- When the behavior changes, update the
  [operator guide](docs/operator-guide.md), the
  [user guide](docs/user-guide.md) or [project.md](project.md).
- When a user or an operator can see the change, add a line under
  "Unreleased" in [CHANGELOG.md](CHANGELOG.md).
- Do not commit secrets, tokens or real hostnames.
- CI must pass: lint, host tests on Ubuntu and Arch, and the security
  workflow.

## Make a release

1. In a pull request, set the new version in `lib/onbehalf/VERSION`. Use
   [Semantic Versioning](https://semver.org).
2. In `CHANGELOG.md`, move the lines under "Unreleased" to a new section
   `## X.Y.Z (YYYY-MM-DD)`. Add "No changes yet." under "Unreleased".
3. In the README and the operator guide, change the version in the install
   commands.
4. After the merge, tag `main` and push the tag:

   ```sh
   git tag vX.Y.Z && git push origin vX.Y.Z
   ```

The `Release` workflow then makes the GitHub release. It attaches the
source tarball, `SHA256SUMS` and the signed build provenance, and it uses the
notes of the version from `CHANGELOG.md`. The workflow stops if the tag does
not agree with `lib/onbehalf/VERSION`.

## License

When you contribute, you agree to license your contribution under the
[Apache License 2.0](LICENSE), the same license as the project.

## Code of conduct

This project follows the [Contributor Covenant](CODE_OF_CONDUCT.md).
