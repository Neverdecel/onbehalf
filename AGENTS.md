# Instructions for AI contributors

These instructions apply to each AI harness that edits this repository.

## Text

- Write all text in ASD-STE100 Simplified Technical English. This rule
  applies to docs, diagrams, CLI help, CLI output, commit messages and pull
  request descriptions. See
  [Writing style](CONTRIBUTING.md#writing-style-asd-ste100).
- Use the terms in the [terminology table](CONTRIBUTING.md#terminology). Do
  not use the words in its "Do not use" column.
- Run `make lint-docs` after each change to the docs. The script cannot
  check all of the STE rules. Read your text again for the other rules.
- When you add a docs file, add it to `test/lint/ste-files.txt`.

## Code and commits

- Follow [CONTRIBUTING.md](CONTRIBUTING.md). Run `make lint`, and run
  `make test` for a change in behavior.
- Do not put real account names, hostnames, tokens or other secrets in
  code, docs, commits or pull requests. Use the example names `alice`,
  `bob`, `carol` and `ops`.
- `main` is protected. Make a branch and a pull request.
