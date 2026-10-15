# Example telemetry backend: OTel Collector and Langfuse

This example runs the telemetry backend on the host of onbehalf, with
Docker Compose. It is one example. `onbehalf telemetry` can send to each
backend that accepts OTLP/HTTP.

| Service | Task |
|---|---|
| `collector` | The OTel Collector. It accepts the spans of the runtimes on `127.0.0.1:4318`, only with a telemetry key. It sets the user from the key. Then it sends the spans to Langfuse. |
| `langfuse-web`, `langfuse-worker` | Langfuse keeps and shows the traces. The web interface is on `127.0.0.1:3000`. |
| `postgres`, `clickhouse`, `redis`, `minio` | The data stores of Langfuse. |

onbehalf writes the configuration of the Collector. Do not write your own
configuration for this Collector.

## What Langfuse shows

| OpenCode | Span | Langfuse |
|---|---|---|
| A task: one prompt and its answer | `invoke_agent NAME` | A trace. Its first observation has the Langfuse type `agent` |
| A model step | `chat MODEL` | A generation, with the model and the tokens |
| A tool call | `execute_tool TOOL` | A tool observation. A failed command has the level ERROR |
| The OpenCode session | `session.id` | A session |
| The authenticated user | Pseudonymous `user.id`, from the telemetry key and a private secret | A user |

Tool metadata has a fixed `command_summary`, for example `kubectl get`.
Langfuse gets no raw commands, arguments, prompts, answers or tool output.
Code Mode containers have type `SPAN`; their actual tool calls have child spans.
Model spans include first-token time. Task metadata includes first-text time,
tool counts, failures, model steps and scheduled retries.

Keep the pseudonym secret outside backend backups. Restrict backend access
and confirm the approved retention period. Historical data stays unchanged.
See the [operator guide](../../docs/operator-guide.md#telemetry) for privacy limits.

## Set up

Do these steps as root on the host.

1. Make the group of the Collector:

   ```
   groupadd --system otelcol-contrib
   ```

2. Copy this directory to `/etc/onbehalf-telemetry`. Copy `.env.example` to
   `.env` and set the mode to 600. Fill in each value. `.env.example` tells
   how to make each value.
3. Start Langfuse:

   ```
   cd /etc/onbehalf-telemetry
   docker compose up -d --wait langfuse-web langfuse-worker
   ```

4. Start the telemetry of onbehalf. Give the API keys of the project in
   `.env` as the authorization header:

   ```
   . ./.env
   printf 'Basic %s' "$(printf '%s:%s' "$LANGFUSE_PUBLIC_KEY" "$LANGFUSE_SECRET_KEY" | base64 -w0)" \
     | onbehalf telemetry on --export http://127.0.0.1:3000/api/public/otel
   ```

5. Start the Collector, then restart the runtimes:

   ```
   docker compose up -d collector
   onbehalf restart --all
   onbehalf doctor
   ```

6. Make the dashboards: `./dashboards.sh`.

## Open Langfuse

Langfuse listens only on the host. Open an SSH tunnel from your computer:

```
ssh -L 3000:127.0.0.1:3000 HOST
```

Then open `http://localhost:3000`. Log in with `LANGFUSE_ADMIN_EMAIL` and
`LANGFUSE_ADMIN_PASSWORD`. Sign-up is off. The first account adds the other
accounts in the settings of the organization.

## Dashboards

`dashboards.json` defines four dashboards. Each one shows the data for
each user:

| Dashboard | Widgets |
|---|---|
| `onbehalf: usage and adoption` | Active users, sessions and tasks over time. Tasks, sessions and tool calls per user |
| `onbehalf: cost` | Cost and tokens per user and per model, cost over time, a table of user and model |
| `onbehalf: tool calls` | Tool calls and failed tool calls per tool. All, write, read and unknown tool calls per user. A table of tool and result |
| `onbehalf: reliability` | Latency per model and per tool, task duration, errors over time, failed tasks per user, a table of user and error type |

Make or replace the dashboards, as root:

```
cd /etc/onbehalf-telemetry
./dashboards.sh
```

The script uses the API keys in `.env`. Run it again after a change to
`dashboards.json`. It replaces the dashboards and widgets with the same
names. Langfuse calls its dashboard API "unstable": a new Langfuse version
can change it.

Langfuse cannot group by a metadata key and cannot divide two values. Thus
the read-and-write split is three widgets with the same users: all tool
calls, write tool calls and read tool calls.

## Cost

Langfuse calculates the cost from the tokens and the price of each model.
The model names are the names of the model gateway, for example
`gpt-5.2`. Langfuse does not know their prices. Add each model of the model
catalog in the project settings, in "Models", with the price of the
provider.

## Limits

- Langfuse shows the traces of all users to each Langfuse account. Give a
  Langfuse account only to the operators and the audit team.
- The Collector does not send its own metrics. Its default port 8888 is
  frequently in use on the host.
- Back up the volumes `postgres`, `clickhouse` and `minio` if you must keep
  the data.
