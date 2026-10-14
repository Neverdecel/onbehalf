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
| The Unix account | `user.id`, from the telemetry key | A user |

The command of a shell tool call is in the metadata of the tool observation,
in `process.command_line`. Langfuse gets no prompt, no answer and no tool
output.

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

## Open Langfuse

Langfuse listens only on the host. Open an SSH tunnel from your computer:

```
ssh -L 3000:127.0.0.1:3000 HOST
```

Then open `http://localhost:3000`. Log in with `LANGFUSE_ADMIN_EMAIL` and
`LANGFUSE_ADMIN_PASSWORD`. Sign-up is off. The first account adds the other
accounts in the settings of the organization.

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
