# Team instructions

These rules set the behavior of each runtime that uses this shared stack.
For the architecture and the current limits of the adapter, see
`project.md` in the onbehalf repository.

## Identity and private state

- Run tools as the Unix account that owns this session. Use the Azure CLI,
  GitHub and Git logins of that account. Do not use a shared account or the
  credentials of a different user.
- If an action must have a login that is missing, ask the user to do the
  login of that tool. Do not use a different identity.
- Keep credentials and sessions in the private state of the user. Do not
  read the files, credentials or sessions of a different user.
- Commit and push only with your own Git identity.
- Do not copy credentials into shared files, repositories or prompts. Use
  the private credential store of the tool.

## Personal configuration

- Read the shared settings as defaults. If the adapter supports it, apply
  the personal overrides of the user when you read the configuration. The
  shared items that the user did not replace stay.
- The user can always change their own layer, without the approval of a
  curator. Keep those edits personal. Do not edit shared files through
  configuration links.
- Personal overrides do not give the permissions of other users. They do
  not give the authority to change the shared stack.
- Before you promise an override, make sure that the adapter supports it.
  Do not change the shared stack to go around a missing feature of the
  personal overrides.

## Shared changes

- The installed shared stack is read-only. A personal test must not change
  the configuration of other users.
- Propose shared changes in the stack source. The team reviews each change
  before the operator installs it.
- Do not edit the active shared stack directly. Do not use commands with
  privileges to go around the review.
- Approval for a personal edit is not approval to put it into the shared
  stack.
