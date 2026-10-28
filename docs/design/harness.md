# Design: only OpenCode as the AI harness

Status: decision, 2026-10-24. Done in version 0.3.0.

## Decision

onbehalf supports only one AI harness: OpenCode. Version 0.2.0 also
supported Claude Code and Codex. Version 0.3.0 removes that support. We do
not add a different AI harness again.

## Reasons

- OpenCode is the best AI harness for this project now. It has a
  configuration loader with a shared layer and a personal layer. The
  shared stack and the personal overrides of onbehalf use these layers.
- OpenCode can use all models. It connects to each model that the LiteLLM
  gateway serves. Thus a team does not have to use a different AI harness for a
  different model.
- Each AI harness has its own configuration, login, plugins and telemetry.
  Each one adds an adapter, tests and docs. Each update of an AI harness
  can break its adapter.
- More AI harnesses give more risk. Each adapter must keep the identity of
  the user correct. An error in one adapter can let a runtime act with a
  wrong identity.
- More AI harnesses gave no real benefit to the users. The shared stack,
  the model catalog and the telemetry are better with one AI harness.

## Results

- `onbehalf harness NAME` and `onbehalf init --harness NAME` are removed.
- `onbehalf stack install` ignores the `claude/` and `codex/` directories
  of a stack source.
- A host that has `ONBEHALF_HARNESS` in `onbehalf.conf` stops with an
  error. The operator guide, section "Move a host from Claude Code or
  Codex", gives the steps to move the host.
- The host tests run only OpenCode. Fewer tests run in each CI run.
