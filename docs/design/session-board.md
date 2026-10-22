# Design: a session board behind the interface broker

Status: proposal, 2026-10-21. Step 1 is complete (2026-10-22). See issue #52.

## Goal

A user often runs many sessions of the AI harness at the same time, for
example six topics. It is difficult to go back to a topic:

- The session summaries of the AI harness are short and not clear.
- The sidebar of a terminal multiplexer is hard to read, and a plugin
  cannot change its layout.
- The user cannot see quickly which sessions wait for the user.

A session board is a local web client. It shows each OpenCode session of
the user as a ticket. The board is a client, not a part of onbehalf. A new
web interface is out of scope (see [project.md](../../project.md#out-of-scope)).

onbehalf gives the identity and the routes that the board must have. This
work is the [interface broker](../../project.md#phase-3-interface-broker)
of Phase 3. A web client must never select the identity that acts.

## Decisions

| Topic | Decision |
|---|---|
| Owner of the board | The team or a different project. onbehalf does not supply the board. |
| Owner of the identity | The interface broker of onbehalf. The board gets no setting that changes the user. |
| Runtime | The OpenCode service that runs as the user. onbehalf starts it now, and it runs all the time. There is no shared OpenCode server. A start on request is a later step. |
| Login | Single sign-on at a reverse proxy, for example Entra ID through OIDC. |
| Credentials | The board never gets the logins of Azure CLI, GitHub or other work tools. Each action stays the action of the user. |
| Status data | The OpenCode API and its events. A plugin can add a short summary later (step 4). |
| Client API | The board uses only the OpenCode server API and SDK. It does not use parts of `herdr-web-ui`, and herdr is not necessary on the host. |
| Connection | The service password of each user, with HTTP Basic authentication. OpenCode 2.0.26 has no Unix socket option (see [Result of step 1](#result-of-step-1)). |
| Replacement | It is possible to replace the board. OpenChamber or a different client can replace it with no change to the identity contract. |

## What the board does

The board uses only the API of the OpenCode service of the user:

1. It shows each OpenCode session as a ticket with a short topic name.
2. Each ticket has one status. The status changes when an event of OpenCode
   comes.
3. The tickets that wait for the user are at the top.
4. Each ticket shows one line: the last answer, decision or question of the
   session.
5. A click on a ticket opens the session.

A ticket has four statuses. The board selects the status from the
OpenCode events.

| Status | Meaning |
|---|---|
| In progress | The session works on a request. |
| Blocked | The session waits for the user: a permission request or a question. |
| Done | The session is idle after its last answer. |
| Stopped | The session stopped with an error, or the user stopped it. |

## The broker contract

The broker is between the reverse proxy and the OpenCode service of each
user. It does these steps for each request:

1. It reads the login name that the reverse proxy sends after the single
   sign-on.
2. It maps the login name to one Unix account. This is the same map as
   `user add` and the Entra sync.
3. It finds the service port of that account. onbehalf records it now
   (`harness_opencode_port`).
4. It checks that the process on that port runs as that Unix account.
5. It sends the request to that port only, with the service password of
   that account. If a step fails, it refuses the request.

The owner check (step 4 above) stops a wrong configuration. Without it, a changed port can send a
user to the runtime of a different user. The owner check also protects the
password. When a runtime stops, a different local account can listen on
its port. Without the owner check, the broker sends the password to that account.

The broker does not merge the sessions of two users. A request has the
identity of one login, and it goes to one runtime.

## Identity and isolation

- The board shows only the sessions of the runtime of the login.
- The broker does not show an action as the action of a different user.
- The plugin of step 4 writes in the home directory of the user. Its files
  have the same permissions as the other runtime state.
- The OpenCode service listens on `127.0.0.1`. A different local account
  can connect to the port, but the service refuses it without the password
  (HTTP 401). The test `test/checks/03-isolation.sh` checks this for each
  pair of users.
- Only the user and root can read the service password. The broker must
  not give it to the board or write it to a log.

## Steps

Each step is one small pull request.

1. **Proof of the routes.** Done. See [Result of step 1](#result-of-step-1).
2. **Route lookup.** A root command gives the service port of a Unix account
   and checks the owner of the process on that port. The reverse proxy can
   call it. It gives the service password only to root. Tests: the right
   port, a refusal for a port of a different user, and a refusal for a
   stopped runtime.
3. **Reverse proxy example.** An example in `examples/` with OIDC at the
   reverse proxy and the route lookup of step 2. A test client shows the
   sessions of one user only.
4. **Status plugin.** An OpenCode plugin in the example stack source. When
   a session becomes idle or stops, it records a short status: what the
   session did, a decision, and the question for the user. It writes no
   prompt or answer to a location outside the home directory.

The board itself is not a step of onbehalf. A team can test it on the
example of step 3.

## Result of step 1

We examined OpenCode 2.0.26, the version of the test hosts, on
2026-10-22.

| Item | Result |
|---|---|
| Address | `opencode serve --service` listens on `127.0.0.1` and the port of `opencode service set port`. |
| Authentication | HTTP Basic. The user name is `opencode`. A request without the password gets HTTP 401. A bearer token gets HTTP 401. |
| Password | OpenCode makes a random password. It keeps it in `~/.config/opencode/service.json`, with mode 600. `opencode service set password` changes it. |
| Unix socket | No option. The service settings are `disabled`, `remote`, `hostname`, `port`, `password`, `cors` and `env`. A socket path as `hostname` stops the service with an error. |
| CORS | `opencode service set cors` adds origins. It is not necessary when the broker serves the board and the API at one origin. |

Thus the broker uses the password, not a Unix socket. We can examine the
socket option again for each new version of OpenCode.

## Not in this design

- A fork or a change of herdr.
- Messages or coordination between sessions.
- Claude Code and Codex. They have no service for each user.

## Open questions

- Which fields does a ticket show, in addition to the topic name, the
  status and the one line? A test with real users decides.
- When does the broker start and stop runtimes on request? See the open
  questions in [project.md](../../project.md#open-questions).
