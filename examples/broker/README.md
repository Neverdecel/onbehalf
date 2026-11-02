# Example interface broker: single sign-on to the runtime of each user

This example sends a user from a web browser to their own OpenCode runtime.
The user signs in with Entra ID. The client never selects the user, and it
never gets the service password. It is step 3 of the
[session board design](../../docs/design/session-board.md).

| Part | Task |
|---|---|
| nginx | Serves `board.example.com` with TLS. It asks oauth2-proxy for the login of each request, and sends the login to the broker. |
| oauth2-proxy | Does the single sign-on with Entra ID through OIDC. |
| `broker.js` | Gets the route of the login with `onbehalf route --upn`. Then it sends the request to the OpenCode service of that user, with its password. |
| OpenCode | The service of each user. It serves its web interface and its API. |

```text
browser --TLS--> nginx --auth_request--> oauth2-proxy --OIDC--> Entra ID
                   |
                   +--login header, Unix socket--> broker.js
                                                     |
                     sudo onbehalf route --upn UPN --+--Basic auth--> OpenCode of the user
```

The OpenCode web interface is the test client. A board client can use the
same API at the same address.

## How the broker finds the user

1. nginx gets the login from oauth2-proxy. For Entra ID, this is the UPN,
   for example `alice@example.com`. nginx replaces a login header from the
   client with this value.
2. The broker runs `sudo -n onbehalf route --upn LOGIN`. onbehalf finds the
   user that is linked to the UPN in `/etc/onbehalf/entra.map`.
   `user sync` writes the UPN of each user in this map.
3. onbehalf checks that the runtime of that user runs, and that the port
   belongs to that user. Then it gives the URL and the password.
4. The broker sends the request to that URL. It removes the
   `Authorization` and `Cookie` headers of the client, and it adds the
   service password.

The broker refuses the request in these cases:

| Case | HTTP code |
|---|---|
| The request has no login header. | 401 |
| No user on the host is linked to the login. An account name is not a login. | 403 |
| The runtime of the user does not run. | 503 |

The broker writes one line to its log for each request: the login, the
user, the method, the path and the HTTP code. It does not write the
password.

## Set up

Do these steps as root on the host of onbehalf. Use your own host name,
tenant and client in place of the example values.

1. Link each user to their Entra account. `sudo onbehalf user sync` does
   this for the users of the Entra group. See the
   [operator guide](../../docs/operator-guide.md).
2. Make the broker account. Give it permission to run only the route
   lookup for a UPN:

   ```bash
   useradd -r -M -s /bin/false onbehalf-broker
   echo 'onbehalf-broker ALL=(root) NOPASSWD: /usr/local/bin/onbehalf route --upn *' \
     >/etc/sudoers.d/onbehalf-broker
   chmod 0440 /etc/sudoers.d/onbehalf-broker
   ```

3. Install the broker and its service:

   ```bash
   install -D -m 0644 broker.js /opt/onbehalf-broker/broker.js
   install -m 0644 onbehalf-broker.service /etc/systemd/system/
   systemctl enable --now onbehalf-broker
   ```

4. Add the nginx account to the group of the broker. Only this group can
   open the socket directory. Use `http` in place of `www-data` on Arch
   Linux.

   ```bash
   usermod -aG onbehalf-broker www-data
   ```

5. Register an application in Entra ID with the redirect URI
   `https://board.example.com/oauth2/callback`. Write its values in
   `oauth2-proxy.cfg`. Start oauth2-proxy with this file.
6. Install `nginx.conf` as a site of nginx, with your TLS certificate.
   Then reload nginx.

Open `https://board.example.com`. After the sign-in, you see the OpenCode
web interface of your own runtime.

## Settings of the broker

| Variable | Default | Meaning |
|---|---|---|
| `BROKER_SOCKET` | `/run/onbehalf-broker/broker.sock` | The Unix socket where the broker listens. |
| `BROKER_LOGIN_HEADER` | `x-auth-request-preferred-username` | The header with the login. |
| `BROKER_ROUTE` | `sudo -n onbehalf route --upn` | The route lookup. The broker adds the login. |

## Limits of this example

- The broker trusts the login header. Thus only nginx can connect to it.
  The socket is in a directory with mode 0750. Do not make the broker
  listen on TCP.
- Each request starts a new route lookup. This is slow for a large number
  of users. A cache of a short time is possible, but a stopped runtime then
  stays in the cache.
- The runtime of the user must run. The broker does not start it.

> **WARNING:** Make sure that nginx sets the login header for each request
> to the broker. If a client can set the header, the client can select the
> user.
