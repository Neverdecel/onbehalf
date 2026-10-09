# Security policy

onbehalf records who did each action on a shared host. Thus an isolation
problem is serious.

## Report a vulnerability

**Do not open a public issue.** Send a private report through GitHub:
<https://github.com/Neverdecel/onbehalf/security/advisories/new>
(**Security → Report a vulnerability** on this repository).

Write the commands that you ran, the result that you expected, and the
result that you got.

## What occurs after your report

- We tell you that we got your report in 3 work days or less.
- In 14 days or less, we tell you if the vulnerability is real. We tell you
  about our progress while we prepare a fix.
- When the fix is on `main`, we publish a GitHub security advisory. We give
  you credit for the report, if you agree. Do not publish the details
  before that time. Our target is to publish in 90 days or less after the
  report.

## In scope

- A user can read the files, credentials or sessions of a different
  user.
- A path that lets a user get the key of the model gateway.
- An action that shows the incorrect identity.
- A problem in the installer or in the CLI that gives a user more
  privileges.

## Supported versions

We apply fixes to the last release and to `main`. We do not apply fixes to
old releases. The [changelog](CHANGELOG.md) gives the releases.

Each release has a build provenance that GitHub Actions signs. To make sure
that this repository built a release tarball, run:

```sh
gh attestation verify onbehalf-VERSION.tar.gz -R Neverdecel/onbehalf
```
