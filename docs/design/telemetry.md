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
| Content | The backend gets fixed command labels, never raw commands, arguments, prompts, answers or output. Unknown commands stay unknown. |
| Performance | Execution hooks observe actual tools, including Code Mode children. Model spans end at the stream boundary. Tasks record counters and first-text time. |
| Privacy | The Collector derives a stable pseudonym from the authenticated account and a private secret. It removes account names, host names and unknown attributes. |
| Classification | In the Collector, from the tool name and the command. The rules are data: `telemetry/classes.json` of the shared stack, then the default rules of onbehalf. The first rule that agrees gives the class. |

## Spans

| Span | Attributes |
|---|---|
| `invoke_agent AGENT` | The root span of a task (one prompt). `gen_ai.operation.name`, `gen_ai.agent.name`, `error.type` |
| `execute_tool NAME` | `gen_ai.operation.name`, `gen_ai.tool.name`, `gen_ai.tool.call.id`, `gen_ai.conversation.id`, fixed command label, `process.exit.code`, `error.type` |
| `chat MODEL` | `gen_ai.operation.name`, `gen_ai.provider.name`, `gen_ai.request.model`, `gen_ai.conversation.id`, `gen_ai.response.finish_reasons`, `gen_ai.usage.input_tokens`, `gen_ai.usage.output_tokens`, `error.type` |

All spans of one task are in one trace. Each span has `session.id`. The
Collector sets the pseudonymous `user.id` on each span, because Langfuse
reads the user from the span and not from the resource. It removes
account names, host names and unknown attributes before export.

The Collector does not send its own metrics. Its default port 8888 is
frequently in use on the host.

## Steps

1. `onbehalf telemetry on|off`, the plugin, the telemetry keys and the
   Collector configuration with the identity. (This change.)
2. The example backend `examples/telemetry`: the Collector and Langfuse,
   with Docker Compose.
3. The classes `read`, `write` and `unknown`. A rules file in the shared
   stack. onbehalf makes Collector `transform` statements from it. The
   class is in `tool.class`, and in the metadata key `tool_class` for
   Langfuse.
4. Dashboards in Langfuse for each user, as code: `dashboards.json` and
   `dashboards.sh` in `examples/telemetry`. Langfuse groups by the user
   only as a list of the top values, and it cannot group by metadata. Thus
   the read-and-write split is widgets side by side.
5. Claude Code and Codex, with their native OTel export and the same
   Collector.

## Limits

- A user can remove the plugin from their own account. Then the backend
  gets no spans of that user. The user cannot send spans as a different
  user.
- Historical telemetry can still contain commands and account names.
- Code Mode HTTP extensions have no tool execution hooks.
- This is not yet the audit log of the sessions of phase 2. Step 3 and
  step 5 make it a part of that log.
