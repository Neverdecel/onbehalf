# Design: tool-call telemetry for each user

Status: step 1 in progress, 2026-10-14. Issue #18.

## Goal

The operator, the platform team and a later audit must see what the users
and their runtimes do:

- The tool calls for each user, each tool and each AI harness.
- The split between tool calls that only read (`az group list`,
  `terraform plan`) and tool calls that change a system
  (`terraform apply`, `az group delete`).
- The result, the duration and the token use of each call.

The solution must not depend on one cloud provider or one observability
product. It uses OpenTelemetry (OTel) and the OTel GenAI semantic
conventions.

## Three rings

1. **The AI harness** emits the tool calls and the model steps.
2. **onbehalf** turns the export on, gives each span the identity of the
   Unix account, and classifies each tool call.
3. **The backend** keeps and shows the data. The operator selects and
   operates it, the same as the model gateway. onbehalf does not install
   it.

## Test result: OpenCode 2.x

We tested OpenCode 2.0.26 with the fake model and an OTLP capture server:

- OpenCode 2.x removed the setting `experimental.openTelemetry`. The OTLP
  export starts from `OTEL_EXPORTER_OTLP_ENDPOINT` alone.
- The export has approximately 200 internal spans, for example
  `Tool.execute` and `Shell.wait`. They have no attributes: no tool name, no
  command and no tokens. A failed command has the status OK.
- One log record contains the command line of OpenCode. Thus
  `opencode run "PROMPT"` sends the prompt.
- The event stream of OpenCode has all the necessary data:
  `session.tool.called` (the tool input), `session.tool.success` (the exit
  code), `session.tool.failed`, and `session.step.ended` (the tokens).
- A plugin in `~/.config/opencode/plugins/` can read the event stream with
  `ctx.event.subscribe()`. The plugin must stop the stream at the event
  `location.shutdown`. If not, `opencode run` does not stop.

Thus onbehalf does not use the native export of OpenCode. A plugin of
onbehalf makes the spans.

## Decisions

| Topic | Decision |
|---|---|
| First AI harness | OpenCode. Claude Code and Codex come later, with their native OTel export. |
| Data source for OpenCode | A plugin of onbehalf, `lib/onbehalf/telemetry/opencode.js`. It reads the session events and sends OTLP/JSON spans. |
| Identity | A personal telemetry key for each user, the same model as the gateway key. The Collector checks the key (`basicauth`, htpasswd file) and sets `user.name` from `auth.username`. A value in the span cannot change it. |
| Collector | The operator installs `otelcol-contrib`. onbehalf writes its configuration. The Collector reads it again at `SIGHUP`. |
| Content | The command of a shell tool call goes to the backend, because it is necessary for the audit. A prompt, a model answer and a tool output never go. |
| Classification | In the Collector, from the tool name and the command. The rules are data in the shared stack. Step 2. |

## Spans

| Span | Attributes |
|---|---|
| `execute_tool NAME` | `gen_ai.operation.name`, `gen_ai.tool.name`, `gen_ai.tool.call.id`, `gen_ai.conversation.id`, `process.command_line` (shell only), `process.exit.code`, `error.type` |
| `chat MODEL` | `gen_ai.operation.name`, `gen_ai.provider.name`, `gen_ai.request.model`, `gen_ai.conversation.id`, `gen_ai.response.finish_reasons`, `gen_ai.usage.input_tokens`, `gen_ai.usage.output_tokens`, `error.type` |

All spans of one session are in one trace. The Collector adds `user.name`
and `host.name`.

## Steps

1. `onbehalf telemetry on|off`, the plugin, the telemetry keys and the
   Collector configuration with the identity. (This change.)
2. The classes `read`, `write` and `unknown`. A rules file in the shared
   stack. onbehalf makes Collector `transform` statements from it.
3. Claude Code and Codex, with their native OTel export and the same
   Collector.

## Limits

- A user can remove the plugin from their own account. Then the backend
  gets no spans of that user. The user cannot send spans as a different
  user.
- The command can contain a secret, for example a token in an argument.
- This is not yet the audit log of the sessions of phase 2. Step 2 and
  step 3 make it a part of that log.
