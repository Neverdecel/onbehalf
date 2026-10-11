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

## How to work

Make a strong product with a small scope, a small change and a clear style.

1. Make a small proof first. A small change that works gets more support
   than a large plan.
2. Use limits as a tool. Keep the scope of each change small. A small scope
   makes each decision fast and clear.
3. Keep each module independent, with a clear interface. Design the
   connections between the modules at the start.
4. Remove what is slow. Delete the code, the options and the features that
   do not help the user.
5. Use the plan as a start point. Test the real result, then change the
   plan.
6. Use the tools and the patterns that the repository uses now. Do not add
   a new dependency when a current tool can do the work.
7. Make small pull requests frequently. After a failure, go back to the
   last version that worked and continue from there.

Do not add a design that gives no benefit to the user. A smart design has
no value if the user gets no benefit.
