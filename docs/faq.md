# FAQ

## How do I give a team one AI harness setup without a shared account?

Put the setup in a Git repository: `opencode.json`, `AGENTS.md`,
custom agents, skills and the model catalog. Run `sudo onbehalf stack install <dir>`
on a Linux host. Each user gets the setup read-only in their own Unix
account. The runtime of each user runs as that user.

## Which AI harnesses does onbehalf support?

OpenCode today. onbehalf connects to the AI harness through an adapter
(`lib/onbehalf/harness-opencode.sh`). Oh My Pi is planned.

## Which models can the team use?

Each model that the LiteLLM gateway serves and that the shared stack
permits. The tests cover the OpenAI API route to the gateway. The tests do
not cover the Anthropic API route yet.

## Is the runtime a sandbox?

No. The runtime of a user can do all that the user can do, with the
files and logins of that user. onbehalf keeps users apart from each
other. It does not limit a user. Unix permissions, the gateway key and the
external systems control access.

## Does onbehalf show what users ask?

No. `onbehalf report` shows logins, requests, tokens, cost and failures for
each user and model. It never shows what a user asked.
`onbehalf doctor` gives a warning when the gateway keeps prompts.

Root on the host can read all files. Give the operator role only to users
that the team trusts.

## Do I need Azure or Entra ID?

No. Users can be local Unix accounts that you add with
`onbehalf user add`. With `onbehalf auto-enroll on`, each user who can
log in is enrolled at the first SSH login. For example, a user can log in
with Entra ID on an Azure VM. `onbehalf user sync` follows an Entra group.
Azure CLI is one of the work tools, and it is optional.

## What occurs when a user leaves the team?

`sudo onbehalf user remove <name>` does these steps:

1. It stops the runtime of the user.
2. It revokes the gateway key of the user.
3. It removes the home directory with the credentials of the user.
4. It removes a local account.

An Entra account stays in the directory. Remove its login permission there.
Nobody shared a secret with the user, so you have no secret to change. The
other users continue to work.

## What does it cost?

onbehalf is free and open source under the Apache License 2.0. The team
pays its model provider through the gateway. `onbehalf report` shows the
cost of each user.
