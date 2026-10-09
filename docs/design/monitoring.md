# Design: monitor the use and the health

Status: complete, 2026-10-08. These steps are merged:

- Step 1: `onbehalf report` (#38, #40).
- Step 2: `onbehalf health` (#42).
- Step 3: the model use of the user in `onbehalf status` (#43).

The steps are installed on the test VM. On that VM, `health` writes only to
the journal. It has no webhook.

## Goal

While onbehalf enrolls the users one by one, the operator must see:

1. **Does it work?** The gateway, the shared stack, and the runtime of each
   user.
2. **Do users use it?** Who is enrolled, who stopped at a step, who is
   active.
3. **How much do they use it?** The requests, tokens, cost and errors for
   each user and model.

Most of the data is already available. Each gateway key contains `user_id`
(the Unix name) and Entra metadata. Thus the cost logs of the gateway show
each user. One view that puts together the Unix data and the gateway data
was missing.

## Decisions

| Topic | Decision |
|---|---|
| Audience | The operator in a terminal. Sponsors who want graphs use the LiteLLM admin UI. We do not make a dashboard. |
| First deliverable | `onbehalf report`. `onbehalf health` and the timer come after it. |
| Gateway scope | The gateway serves only onbehalf. The report uses all cost logs, with no filter. |
| Report content | Adoption steps, use for each model, errors and refusals. The service state stays in `doctor`. |
| Alerts | A webhook message only when the state changes (ok to fail, fail to ok). Off when there is no URL. |
| Model probe | Off by default. `PROBE=yes` sends one short request at each health run. Model checks must have consent. |
| Privacy | Only metadata, never the content of a prompt or an answer. `doctor` gives a warning if the gateway keeps prompts. |
| Own use | `onbehalf status` shows the use of the user. It reads the use with the key of that user. |

## 1. `onbehalf report` (operator, root, read-only)

One row for each user, with `--days N` (default 7) and `--json`.

- **Adoption steps:**
  - Enrolled: the date when the key was made.
  - Last login (`lastlog`).
  - Work tools set up: the `tools` state for git, gh, az and MCP.
  - First model request.
  - Active in the period.
- **Use:** the requests, tokens and cost for each model, in the period.
- **Errors:** refusals and failures (403, 429, 5xx) for each user and
  model. They show blocked models, rate limits and provider outages. They
  use no tokens.

A summary row for the host is at the top of the table. It shows the number
of users at each adoption step, the total cost and the top models.

The report puts each gateway user in one of four groups (#46). The first
group that agrees with the user is the group of that user:

1. **Current users:** the users on this host now, with the runtime
   accounts. Only this group is in the adoption numbers.
2. **Service usage:** the health probe, and the names in
   `/etc/onbehalf/report-services`. onbehalf does not make the gateway key
   of each service, so the operator must name the services.
3. **Past users:** the names in `/var/lib/onbehalf/removed`. onbehalf
   writes a record when it revokes the access of a user: `user remove`,
   `user prune` and `operator add`. It removes the record when the user
   gets a new gateway key.
4. **Other usage:** all other names. A user that is not on this host is not
   always a past user. Thus the report does not guess.

The model totals include the use of all four groups.

## 2. `onbehalf health` and the timer

- Host: the gateway answers, the gateway database is ready, the current
  shared stack is valid, the providers are limited, there is disk space.
  It also checks the failed enrollments since the last run and the error
  rate of the recent real requests.
- For each user: the key is valid, the service runs.
- A systemd timer runs the check each 10 minutes. It uses the same pattern
  as `onbehalf-prune.timer`. It writes `/var/lib/onbehalf/health.json` and
  writes to the log with `-t onbehalf`.
- `/etc/onbehalf/alert.conf`: `WEBHOOK_URL=` (Teams, Slack or a different
  service) and `PROBE=no`. onbehalf sends a message only when the full state
  changes.
- The probe uses its own gateway key, not the key of a user. Thus it is
  not part of the use of a user.

The result of the implementation:

- An alert occurs when the set of checks that are not ok (warn or fail)
  changes. Not only when the state changes between ok and fail.
- If an alert fails, the next run sends it again.
- Formats: Slack (`{"text"}`) and Teams (an adaptive card for a Workflows
  webhook).
- Provider failures include only the errors with an `llm_provider`. They do
  not include refusals from the gateway. The check fails at 3 or more
  failures in 15 minutes, when they are also half or more of the requests.

## 3. Own use in `onbehalf status`

The command shows the requests, tokens and cost of the user for 7 and 30
days. It reads them with the key of the user. The user cannot get the
data of a different user this way.

For this, `GATEWAY_USER_ROUTES` must contain `/user/daily/activity`.
Before this change, personal keys permitted only inference. The old keys
keep their old routes. Thus each user must get a key update.
`stack install` already updates the models of each key. We extended it to
update the routes too.

## Limits

- No content: the reports show who, when, the model, the tokens, the cost
  and the status. They never show what a user asked.
- Only the operators and the user can see the use of that user.
- This is not the audit log of the runtime actions. That log stays in
  Phase 2.
- onbehalf does not operate the gateway. It reads the API of the gateway
  with the admin key, the same as `user` and `doctor`.

## Gateway API (checked with LiteLLM v1.104.0, 2026-10-08)

| Endpoint | Admin key | Personal key | Used for |
|---|---|---|---|
| `/spend/logs/v2?start_date&end_date&page&page_size` | Yes. One row for each request: account, model group, status, tokens, cost, error code and message | 401 | Report: use and errors |
| `/key/list?return_full_object=true` | Yes: `user_id`, `created_at`, `last_active` (null until the first use; it changes approximately each minute) | 403 | Report: enrollment, last request |
| `/user/daily/activity` | Yes, for each day, with the filter `user_id` | Yes, only the data of the user. A different `user_id` gives 403 | Own use (step 3) |
| `/config/field/info?field_name=store_prompts_in_spend_logs` | Yes | - | `doctor` warning |
| `/health/readiness` | Yes: `{"status":"healthy","db":"connected"}` | - | Health (step 2) |
| `/global/spend/report` | Enterprise only | - | Not used |

The dates use the format `YYYY-MM-DD` or `YYYY-MM-DD HH:MM:SS` (UTC). They do
not use ISO 8601 with `T`. The cost logs come in groups, in approximately
one minute.

## Lessons from the real host

- `last --time-format iso NAME` writes "wtmp begins DATE", also for an
  account without logins. Use only the lines with the account in the first
  field. The health PR fixed this. Before the fix, #40 showed that date as
  the last login of each user.
- A login with `sudo -iu` or `su` makes no wtmp record. Thus runtime
  accounts frequently show "no login recorded".
