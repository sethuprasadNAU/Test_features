# TriTrack server — operations

Build/run instructions live in the repository root `README.md`'s "Server"
section. This file is the operational half: the procedures
`TriTrack_Security_Model.md` requires be written down somewhere that is
actually checked (task 10.14).

## Starting the stack: what `scripts/server_up.sh` prints, and what it means (task 11.308)

### A failed build looks like a build in progress, and the previous server keeps answering

`set -euo pipefail` makes `scripts/server_up.sh` exit non-zero when
`docker compose up` fails, correctly — but the terminal you were watching may
already have scrolled the error past, and the last thing on screen mid-build
is a spinner and the word `Building`, which is what *success* looks like too.
**Meanwhile the previous server is still running**, so every later check —
the app connecting, the database answering, sync working — says everything is
fine. This cost an evening in September 2026: a build that could not reach
`pub.dev` inside the Docker build (see "Docker build fails to resolve DNS"
below) failed after 372 seconds, and the failure was missed because nothing
said, afterward, which build was actually serving traffic.

So the script now answers that question directly rather than leaving it to be
inferred from symptoms:

- **On a successful start**, it prints `Now serving commit: <hash>` — asked of
  the *running container's* `org.opencontainers.image.revision` label
  (`server/Dockerfile`), never assumed from the working tree, because the
  working tree can have moved on since the image was built. A build from
  uncommitted changes is labeled with the commit plus `-dirty`, since there is
  no commit that describes what actually got built. Compare this against what
  it was serving before the command, printed on the same line.
- **On a failed start**, it prints `Still serving: <hash>` to **stderr** —
  the previous container, unchanged, because a failed rebuild does not stop
  it. The state after a failed `--build` is not "nothing happened"; it is
  "the previous version is still answering", which is the fact that misled
  everybody the first time.
- **Whether a successful, unchanged result means `--build` found nothing to
  rebuild, or rebuilt and reproduced the same result byte-for-byte, this
  script cannot tell you.** Docker's compose CLI gives an exit code and an
  image, not a "did I actually recompile" flag, and parsing `--build`'s
  progress output for the word `CACHED` would couple this script to output
  Docker makes no promise to keep stable. What the script *can* tell you —
  whether the commit actually serving changed — is the operationally relevant
  half of that question, and it is what gets printed.

### The Postgres startup lines that say `ERROR` and are not one

Every start of the `server` container prints, from Postgres's own log:

```
ERROR:  role "tritrack_app" already exists
ERROR:  tuple concurrently updated
```

Both are harmless, and both say `ERROR` in red on a completely healthy start
— which is this project's other false signal from the same evening, and
`scripts/server_up.sh` now prints a note immediately before these lines can
appear so a person reading the terminal meets the explanation where the
noise actually is, not in this document alone:

- **`role "tritrack_app" already exists`** — `ensureServerAppRole()`
  (`server/lib/src/db/postgres_database.dart`) runs `CREATE ROLE` on every
  start, unconditionally, and only catches the "someone already made it"
  exception in the Dart client (task 10.69). Postgres logs its own `ERROR`
  for that statement before the client's `catch` ever runs — the log line is
  the database being honest about a statement that failed, even though the
  application already expected it to and handled it.
- **`tuple concurrently updated`** — the same function's catalog `GRANT`s
  racing another connection doing the same idempotent setup (task 10.89),
  caught and retried by `_retryOnConcurrentCatalogUpdate`. Same shape: logged
  by Postgres, then retried and resolved by the client.

**These are not quieted**, deliberately: both share Postgres's `ERROR`
severity with statements that fail for real reasons, and turning down
`log_min_messages` to hide them would hide a genuine error at the same time —
quieting a real error to remove noise would be the worse defect. Explaining
them where they appear is the fix; a broken start is still visible, in the
exit code and the "still serving" line above, which these two lines never
affect.

### Docker builds cannot reach the network (it looks like DNS, and mostly is not)

**Corrected 2026-09-23 — the version of this section written on 2026-09-22
prescribed the wrong cure.** It said to hardcode public resolvers in
`/etc/docker/daemon.json` and restart Docker. The restart was the fix; the
resolvers were a coincidence that happened to be applied at the same moment.

**What was measured on 2026-09-23, one step at a time, on the Parallels VM:**
the VM itself resolved names fine; a container resolved nothing, **even when
pointed at the home router's own resolver** (`docker run --rm --dns
192.168.0.1 debian:bookworm-slim getent hosts deb.debian.org` printed
nothing). So containers could not reach the network at all — DNS was only the
first thing to fail. IP forwarding was on, Docker's `MASQUERADE` rule was
present, and the `FORWARD` chain looked ordinary. **`sudo systemctl restart
docker` fixed it**, and the same container test then resolved immediately.

**Check before you fix:**

```bash
docker run --rm debian:bookworm-slim getent hosts deb.debian.org
```

Nothing printed means containers have no way out. **Restart Docker first**
(`sudo systemctl restart docker` — this restarts every container on the host,
including a running TriTrack server, which comes back on its own; check with
`docker compose ps`). Only if that does not fix it, investigate further.

**Two things worth knowing about this host.** **What fails is `docker0`
losing its IPv4 address** — measured on 2026-09-28, the third occurrence in
five days. Docker's forwarding and address-translation rules were intact, UFW
logged nothing from a container, a UFW rule allowing container traffic changed
nothing, and putting the address back by hand did not help; only the restart
did. **The one-line check is `ip -4 addr show docker0`**: no `inet` line means
this fault, and restarting Docker fixes it. What removes the address is still
unknown. (UFW was the earlier suspect; the measurements count against it.) And **hardcoded
public resolvers in `daemon.json` are fragile**: a network that blocks
outbound DNS to `8.8.8.8` breaks every build that relies on them. If
`daemon.json` has a `dns` key you did not deliberately need, removing it lets
Docker follow the host's own resolver, which follows you between networks.

**A third: an IPv6 address with no IPv6 route** (measured 2026-10-06, task 11.330). If a build fails with
`dial tcp [2a06:…]:443: connect: network is unreachable`, the host has an IPv6 address (often a private
`fd…` one) but no way out over IPv6, and Docker's builder sometimes tries Docker Hub's IPv6 address and does
not fall back to IPv4, so the failure comes and goes. Check with `ip -6 route show default` (empty means no
route). On a host that does not serve anyone over IPv6, turn IPv6 off for its network connection
(`sudo nmcli connection modify "<connection>" ipv6.method disabled`, then `sudo nmcli connection up
"<connection>"`); this leaves the loopback and the containers' own networks alone.

## Database credentials — one admin login, three demoted roles (§12.5, task 10.63)

`POSTGRES_USER`/`POSTGRES_PASSWORD` (`.env`) is a superuser on the official
`postgres` image — that is what let `COPY ... FROM PROGRAM` demonstrate
arbitrary command execution live, from the credential the always-on,
network-facing server connection held (finding J-3). No connection in this
project runs application SQL as that superuser any more; each demotes itself
with `SET ROLE` (or, for `pg_dump`, `PGOPTIONS`) to a `NOSUPERUSER NOLOGIN`
role scoped to what that connection actually does, immediately after opening:

| Role | Used by | Privileges |
| --- | --- | --- |
| `tritrack_app` | The server's own sync/auth connection and its separate audit-write connection (`server.dart`); the two sweeps that delete synced rows, `project_destruction.dart` (task 11.290) and `tombstone_retention.dart` (task 11.291) | `SELECT, INSERT, UPDATE, DELETE` on every table — except `DELETE`/`TRUNCATE` on the two audit tables, revoked (task 10.83) |
| `tritrack_retention` | `audit_retention.dart` (task 11.79) | `SELECT, DELETE` on the three audit-retention tables and nothing else |
| `tritrack_backup` | `server/backup/backup.sh` | `SELECT` on every table — `pg_dump` and the schema-version marker query never write |
| `tritrack_restore` | `server/backup/restore.sh` (task 10.59, finding I-10) | `CREATE` on the schema of the one disposable staging database a restore targets — never `TARGET`, never an existing database |

Each role is a privilege label, not a second credential: it is created (if
missing) and granted `TO CURRENT_USER` by the same admin connection that then
assumes it, so there is nothing to provision, rotate, or leak beyond the one
admin password already in `.env`. `NOSUPERUSER` is what actually removes
`COPY ... FROM PROGRAM` — that capability checks the superuser attribute, not
a `GRANT`-able privilege, so none of the grants above can hand it back. See
`TriTrack_Security_Model.md` §12.5 and the doc comments on
`ensureServerAppRole`/`assumeServerAppRole` (`postgres_database.dart`) and at
the top of `restore.sh` for the full reasoning.

**What is deliberately unchanged:** the test suite (`server/test/**`) and the
gate's drill/verification scripts (`scripts/backup_restore_drill.sh`,
`verify_h6_archive_forgery.sh`, `verify_i1_source_identity.sh`,
`verify_c5_denial_audit.py`, `gate_c_adversarial_pass.py`) still connect as
the admin superuser. They run against disposable, non-network-facing
databases (a fresh schema-per-test-file, or a throwaway Docker Compose
project torn down with `-v` afterward) and several need admin-only operations
a least-privilege role structurally cannot have — `CREATE`/`DROP`/`RENAME
DATABASE` to simulate restore scenarios, `DROP SCHEMA ... CASCADE` for
per-file test isolation. None of them is the always-on, network-facing
connection the finding is about.

## Transport security (§4.1)

The server **binds loopback only** unless told otherwise. A deployment that
configures nothing is unreachable from another machine rather than publishing
session tokens and coordinates in cleartext — a forgotten setting fails closed.

| Configuration | Result |
| --- | --- |
| Nothing set | Loopback only, cleartext |
| `TRITRACK_ALLOW_CLEARTEXT_LAN=1`, machine has only private addresses | All interfaces, cleartext, **warns on every start** |
| `TRITRACK_ALLOW_CLEARTEXT_LAN=1`, machine has a public address | **Refuses to start** |
| `TRITRACK_ALLOW_CLEARTEXT_LAN=1` + `TRITRACK_ENV=production` | **Refuses to start** |
| `TRITRACK_TLS_CERT_PATH` + `TRITRACK_TLS_KEY_PATH` | All interfaces, TLS |
| Only one of the two TLS paths | **Refuses to start** (a half-configured cert must not silently serve cleartext) |

A refusal prints `REFUSING TO START — transport security`, the reason, and both
ways out, then exits `78` (`EX_CONFIG`). Under `restart: unless-stopped` the
container will loop; the message is printed in full on every pass, so
`docker compose logs server` shows it rather than a stack trace.

### Who can actually reach it (task 10.22)

The row above is about what the *server process* binds. Under Docker there is a
second control, and it is the one that decides exposure:

| | Default | Override |
| --- | --- | --- |
| Container bind | all interfaces of the container's private bridge | fixed in `docker-compose.yml` |
| Host publish | `127.0.0.1` — this machine only | `SERVER_PUBLISH_ADDRESS=0.0.0.0` in `.env` |

So `docker compose up` on a clean checkout serves this machine and nothing else.
Letting a phone on the Wi-Fi reach it is one deliberate line in `.env`.

**Security Gate C finding C-3** was that this used to be the other way round:
`docker-compose.yml` defaulted the cleartext flag on behind a `0.0.0.0` publish,
so the artifact everyone ran was cleartext on every interface, while
`TRITRACK_ENV=production` — the refusal that was supposed to prevent this — was
defaulted to `development` in the same file. Reproduce and re-check with
`scripts/verify_c3_cleartext_defaults.py`.

**The gap this leaves, stated because it is load-bearing.** A container cannot
see its host's addresses, so the private-range refusal cannot fire inside
Docker: on a public VPS the container sees only `172.x` and starts happily.
`SERVER_PUBLISH_ADDRESS` is what stands in for it there, and it is a comment in
a file rather than a control. **Do not run this compose file on a
publicly-addressed host without TLS.** §4.1's real answer for that deployment is
`TRITRACK_TLS_CERT_PATH`/`TRITRACK_TLS_KEY_PATH`, which the table above covers
and which is refused-if-half-configured for the same reason.

### TLS termination (task 10.49, Security Model §8.6)

Three gates in a row asked for a reverse proxy and found nothing outside
`CLAUDE_DOCS/`. `docker-compose.tls.yml` is that artifact — a `caddy` service
that terminates real TLS on 443 and reconfigures `server` so the only way in
from outside the compose network is through it. It is opt-in, layered on top
of the base file the same way the e2e and server-test overlays are:

```bash
docker compose -f docker-compose.yml -f docker-compose.tls.yml up --build -d
```

**Setup, once.** Two things `.env` needs beyond the base file (see
`.env.example`):

- `TRITRACK_TLS_DOMAIN` — the public site address Caddy serves. A real,
  publicly-resolvable domain for a real deployment; `localhost` (or another
  address Caddy's own heuristic treats as internal — a bare IP, a `.local`
  name) for the local verification run below. Caddy decides how to get a
  certificate from this value alone: a real domain gets a real one from
  Let's Encrypt, automatically, over ACME's HTTP-01 challenge on port 80; an
  internal-looking address gets one from Caddy's own local CA instead. See
  `proxy/Caddyfile`'s own comment.
- `TRITRACK_TLS_ORIGIN_CERT` / `TRITRACK_TLS_ORIGIN_KEY` — a **second**,
  separate certificate, for `server`'s own TLS. Needed because `server`
  refuses to serve cleartext beyond loopback without either
  `TRITRACK_ALLOW_CLEARTEXT_LAN` (the table above) or its own TLS configured,
  and the table above already shows that `TRITRACK_ALLOW_CLEARTEXT_LAN=1` +
  `TRITRACK_ENV=production` **refuses to start** — which is exactly the
  combination `docker-compose.yml` hardcodes and this overlay requires (a
  real deployment behind this proxy should run with `TRITRACK_ENV=production`,
  which the overlay sets for you). Giving `server` its own certificate is the
  documented way out of that refusal, not a workaround for it. This
  certificate authenticates nothing to Caddy — the reverse-proxy hop to it
  runs with certificate verification intentionally off
  (`tls_insecure_skip_verify` in `proxy/Caddyfile`), the same trust boundary
  Postgres's own cleartext connection already crosses on this network — its
  only job is to make `server`'s "am I speaking TLS" requirement true.
  Generate it once, on the machine that will run the stack, and never commit
  it (`*.crt`/`*.key` are gitignored, but keep it out of the repo tree
  entirely — the same discipline as the backup signing key below):

  ```bash
  mkdir -p ~/.config/tritrack
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout ~/.config/tritrack/tls-origin.key \
    -out ~/.config/tritrack/tls-origin.crt \
    -subj "/CN=tritrack-origin"
  ```

  ```
  TRITRACK_TLS_ORIGIN_CERT=/home/you/.config/tritrack/tls-origin.crt
  TRITRACK_TLS_ORIGIN_KEY=/home/you/.config/tritrack/tls-origin.key
  ```

**Local self-signed verification, re-runnable:**

```bash
scripts/verify_tls_termination.sh
```

Generates its own throwaway origin certificate, brings the overlay up under
its own compose project (`tritrack-tls-drill`, never touching a real
deployment's data), and tears everything down on exit. What it checks, and
what was actually run for this task, entirely on loopback with no real
domain or open ports needed:

1. `server` logs `TriTrack server listening on https://…` — TLS enabled, not
   refused.
2. Caddy's own log shows `"certificate obtained successfully"`,
   `"issuer":"local"` — its internal CA, not ACME, exactly as
   `proxy/Caddyfile`'s comment says `localhost` should resolve.
3. `curl --cacert <exported Caddy root> https://localhost/health` returns
   `{"status":"ok"}` with the certificate chain **verified**, not `curl -k` —
   proving real termination and correct forwarding, not just "a response came
   back" — and a request trusting nothing is refused, proving the check
   above is a real chain verification.
4. The origin has no published host port — the proxy is the only way in.

**10.48's actual client code**, both branches of `createPlatformHttpClient`,
was additionally exercised by hand against the drill's live proxy over a real
network round trip in a `flutter test` (not folded into the script above — it
needs `flutter test`, not `bash`), trusting Caddy's exported root via
`HttpOverrides` (never the OS keychain):

- `http.Client()` — the Android/Linux/Windows path — connects and reads
  `{"status":"ok"}` once the root is trusted.
- `CupertinoClient` — the iOS/macOS path — makes a genuine `NSURLSession`
  request and **correctly refuses** the same certificate, because
  `HttpOverrides` has no effect on it; `NSURLSession` only trusts the
  platform keychain, which this verification deliberately did not modify.
  That refusal is the correct behavior for an unrecognized certificate, not
  a gap — it demonstrates real certificate validation is active on that path
  too. A real deployment's Let's Encrypt certificate is already in every
  platform's trust store by construction, so no client-side change is
  needed for it to work there.

**What this did not verify, named as its own step because a local run cannot
cover it.** Everything above ran on loopback with a certificate this
verification minted itself. A real deployment needs, separately, by a human:
DNS for the real `TRITRACK_TLS_DOMAIN` pointed at the host; ports 80 and 443
actually reachable from the internet (80 for the ACME HTTP-01 challenge, not
optional); and then confirming Caddy's log shows `"issuer":"acme"` /
`"issuer":"letsencrypt"` rather than `"issuer":"local"`, and that an
unmodified device (nothing added to its trust store) reaches `https://<the
real domain>/health` and gets a certificate it already trusts. **No host, no
DNS, and no public deployment exist in this repository to run that against —
this is the check §8.6 named as unverifiable, and it stays that way until
someone runs it against a real one.**

**On certificate custody.** Task 10.43 built a signature scheme
(`minisign`) for backup archives, with its own key pair and its own custody
arrangement (§4.9.2, below). This TLS work uses entirely separate key
material — Caddy's ACME account key and issued certificates (real or
internal), stored in the `tritrack_caddy_data` named volume, and the origin's
self-signed pair above — and the two do not interact anywhere: different
keys, different formats, different purposes (transport encryption here,
archive-origin authentication there), never mounted into the same container.
Checked, not assumed, because the task asked for this to be flagged rather
than decided quietly if it turned out otherwise.

## If you only run one command, run this one (task 11.140)

```
scripts/operator_status.sh
```

It asks the three questions an operator would otherwise have to remember to ask
separately, and prints one report:

1. **Is there a recent backup?** — `scripts/backup_status.sh`, below.
2. **Was anybody refused because the database was unreachable?** — the durable
   degradation record, below.
3. **Is the sign-in rate limit turning people away?** — the `rate_limit_tripped`
   rows in `auth_audit_log`.

**Why one command.** All three answers already existed and each had its own
command. The record is that nobody remembers to run three things. This needs no
mail sender, no credentials and no new authenticated route, and it gives any
future notification exactly one place to read from.

**What it does not do is tell you.** There is no email, no push, no alert.
Nothing changes that by running it; a server that stops between two runs is
invisible for as long as that gap lasts. That limit was accepted deliberately
when this command was chosen over building a mail sender, and the command prints
it in its own output so it is never a surprise.

**It works with the database down**, which is when two of the three questions
matter most. Nothing in it connects to Postgres before asking anything, and
question 3 uses `docker compose exec` rather than `run` on purpose: **a stopped
database is reported as a stopped database rather than started by the command
that came to ask about it.**

**The property it lives or dies by: an input that could not answer says so.**
Each section ends in exactly one of `OK`, `PROBLEM` or `COULD NOT CHECK`, and
the exit status carries the same distinction — `0` all three answered and
nothing wrong, `1` at least one `PROBLEM`, `2` no problem but at least one
question unanswered. A container that cannot read `backups/` (which is what
task 11.125 measured on a real host), a degradation record that is missing or
unparseable, and a database that will not answer are all `COULD NOT CHECK`, and
none of them is ever printed as good news. That is not a nicety: **a summary
that folded "I could not check" into "nothing to report" would be worse than
the three commands it replaces**, because it would convert three honest
silences into one confident lie.

**What it is not.** A snapshot of three things, not a monitor of everything. It
says nothing about disk space, certificate expiry, whether the audit retention
sweep is running (`scripts/audit_retention_status.sh`), whether a scheduled
project deletion is overdue (`scripts/project_destruction_status.sh`), whether
deleted records are being purged after their window
(`scripts/tombstone_retention_status.sh`), whether an archive has been copied
off this machine (none has — task 11.80), or whether the server is reachable
from a phone.

## Is the server working? `/health` and `/ready` mean two different things

**Task 11.128.** Two routes, both unauthenticated, both cheap, and they answer
different questions. Reading the wrong one is how task 11.125 spent a session
looking at a `200` on a server whose every sign-in was dead.

| | `GET /health` | `GET /ready` |
| --- | --- | --- |
| **Asks** | Is this process alive and answering HTTP? | Can this server actually do its job? |
| **Answers** | Always `200 {"status":"ok"}` while the process is up | `200 {"status":"ready"}`, or `503 {"status":"not_ready","degraded":["database"]}` |
| **Says nothing about** | The database. A server started with no database answers `200` here, deliberately | Nothing else — `database` is the only word it can say |
| **Point it at** | A container healthcheck, where the remedy is a restart | An uptime monitor, a load balancer, and yourself |

**Why `/health` does not go red when the database is down, and must not.** The
only thing that acts on a failed liveness probe is a restart, and restarting
this server cannot make an unreachable database reachable — it would produce a
restart loop on top of an outage. Fourteen instruments under `scripts/` also
read a `200` from `/health` as "the process came up"; changing it would
silently redefine what all of them measure. So `/health` stayed exactly as it
was and readiness got its own route.

**`/ready` is unauthenticated on purpose.** A monitor cannot hold a token, and
the diagnostics console — where any richer detail belongs — is loopback-only.
It discloses nothing a stranger cannot already get: on a database-less server
`POST /auth/magic-link` answers `404` while a healthy one answers `202`, which
was measured, and is why this was recorded as a settled decision rather than a
judgement call. The set of words `/ready` can print is fixed in code (the
`Subsystem` enum in `server/lib/src/readiness.dart`), so it can never grow an
exception type or a hostname by accident.

**What `/ready` can and cannot see.** It reports the database as degraded when
the server started without one, and when a connection that was open has since
closed — both measured below. It does **not** notice a database that is
reachable and answering with errors (a full disk, say). Its probe is
deliberately query-free, because an unauthenticated route that issued a
database statement would be an amplifier.

```
$ curl -i http://127.0.0.1:8080/ready
HTTP/1.1 503 Service Unavailable
{"status":"not_ready","degraded":["database"]}
```

### The container healthcheck, and the one thing it does not do

The `server` service had no `healthcheck:` at all until 2026-09-02, so
`docker compose ps` said nothing about the one process anybody uses. It has one
now. It runs `/app/bin/server --health-check` — a second mode of the same
binary, not a `curl`, because the runtime image is `debian:bookworm-slim` with
`ca-certificates` and nothing else and `server/Dockerfile` gives up the entire
Dart SDK on the argument that a smaller image is a smaller attack surface.

**Its verdict is liveness. Its message is readiness.** A server whose database
is unreachable is reported **healthy**, on purpose — `unhealthy` is the slot a
restart hangs off, and a restart cannot reach a database that is down. But
Docker keeps each probe's output, so the health log says what `docker compose
ps` cannot:

```
$ docker inspect -f '{{json .State.Health.Log}}' <container> | jq -r '.[-1].Output'
healthy: alive, but NOT READY — degraded: database. Sign-in and sync are dead
while this lasts. ...
```

**What it does not do: restart anything.** `restart: unless-stopped` reacts to
the container *exiting*. Docker Engine's restart policies do not act on a
failing healthcheck at all — that is a Swarm or Kubernetes behaviour and this
stack is neither. **Measured on 2026-09-02** by forcing a `server` container
unhealthy: it sat at `Up (unhealthy)` for as long as it was watched, same
process id, restart count still zero. So what the healthcheck buys is an honest
`docker compose ps` and an honest health log, and nothing automatic. Anything
that recovers on its own has to be built on top and does not exist.

The probe reads no configuration. It asks `http://127.0.0.1:$PORT/health` and,
if nothing answers, `https://` — so it works under `docker-compose.tls.yml`,
where the origin serves its own self-signed pair, without keeping a second copy
of what "TLS is configured" means. **Measured on 2026-09-02** against a
loopback TLS server with a self-signed certificate.

### The record that survives a dead database (task 11.129)

**The problem, measured on 2026-09-02 with the server up and Postgres stopped.**
A sign-in request answers `202 {"status":"sent"}` — correctly. That response is
byte-identical whether a link was sent, the address is unknown, or nothing
worked at all, and that uniformity is the whole anti-enumeration control (§4.5);
the app cannot be told why, and task 11.119 settled that it must not guess.
`auth_routes.dart` therefore says, in as many words, that the operational
visibility comes from the audit log instead.

**The audit log is a Postgres table.** So with Postgres gone: the person is told
"sent", no link arrives, the audit write fails too, and the entire surviving
record was one line on the container's stdout. **The compensating control is
unavailable in exactly the failure it compensates for**, and afterwards nobody
could establish that any of it happened.

There is now one file that survives it:

```
$ docker compose exec server /app/bin/server --degradation-report
Durable degradation record: /var/lib/tritrack/degradation.json
Server last started: 2026-09-02T18:41:07.000Z
The audit log LOST 6 write(s) — first 2026-09-02T18:44:31.100Z, last 2026-09-02T18:47:02.884Z.
While that was happening the database was unreachable, so sign-in and sync were
refused: a person asking for a sign-in link was still answered "sent" (that
response is uniform on purpose) and no link was sent. This is a count of LOST
AUDIT WRITES, not of people — one person retrying six times is six.
By day (UTC):
  2026-09-02  6
What to do: fix the database, then read auth_audit_log for the periods either
side — the rows inside the window above do not exist and will not appear later.
```

**It needs no database**, which is the point: it answers during the outage and
after it.

**What it contains is a decision, not a default: it names nobody.** No email
address, no user id, no device id, no source address, no request id — a count
per day, a first and a last timestamp, and nothing else. Three reasons, in order
of weight:

1. **§4.7's rules are properties of the table.** The one-year window, the
   `audit-retention` sweep that applies it, the never-log list enforced by there
   being no token column — all of that machinery reaches `auth_audit_log` and
   reaches nothing on a filesystem. An address written here would have no
   window, nothing sweeping it, and would outlive the account it names. That is
   not a smaller audit log; it is an unretained copy of one.
2. **A file's ownership has cost this project twice already** — task 11.70's
   backup archive and task 11.125's freshness check. A file with no personal
   data in it is one where that question cannot cost anybody anything.
3. **The question does not need a name.** The question is *"was sign-in broken
   on Tuesday, and how badly?"*, and a per-day count with a first and last
   timestamp answers it exactly. The remedy for all of the affected people is
   the same single remedy.

There is deliberately **no breakdown by event type** either. A gap means the
database was unreachable, so *every* authenticated route was refused, not some;
a breakdown would imply the outage was selective, and it is the first step back
toward being a second copy of the audit log. **Two logs that disagree is a worse
problem than one that stops.** This file holds no events at all — it holds the
shape of the hole in the audit log, which is disjoint from anything the audit
log contains, so the two can never contradict each other.

**What reads it — plainly, and nothing pushes.**

- **You, at the point you already suspect something**, via the command above —
  or via `scripts/operator_status.sh`, which asks it as one of three questions
  and works with the server container stopped as well as the database.
- **`--health-check`**, which the compose healthcheck already runs every thirty
  seconds and whose output Docker keeps. For 24 hours after a loss it appends
  one sentence, so a `docker compose ps` reading `healthy` still says the audit
  log lost writes this morning. It never changes the exit code: a gap that has
  already happened is not a reason to restart anything.

**There is no monitor and nothing sends you a message.** Where a warning should
go when something stops was decided on 2026-09-02: **one command an operator
runs**, `scripts/operator_status.sh`, which reads this record as its second
question. It still does not push — that limit was chosen deliberately over
building a mail sender, and the command says so in its own output. A durable
record and a notification are different problems; this is the first one and
there is still no second one.

**Where the file is, and why it is a named volume.** `/var/lib/tritrack/degradation.json`
inside the container, on the named Docker volume `tritrack_server_state`.
Named, not a bind mount, deliberately: a bind mount passes host ownership
straight through on Linux, which is what made task 11.70's backup silently
unwritable and task 11.125's two status commands give opposite answers about the
same backups. Read it through `docker compose exec`, not from the host.

Running the server outside a container (`dart run bin/server.dart`) will
normally find that path unwritable and will say so at startup, loudly, naming
`TRITRACK_DEGRADATION_PATH`. **That warning is the design, not an annoyance:**
the record's own writability is proven while things are healthy, because a
fallback first discovered broken during the outage is the defect this whole
section is about, one layer out. For the same reason the server writes the file
on every healthy start — so an absent file means "could not be written", never
"nothing has failed".

## Sign-in email — the relay that carries the link (§4.5, §4.6, task 11.287)

TriTrack has no passwords. A person types their address, the server emails
them a link, and opening it signs them in. **So the relay that carries that
email is the whole of sign-in**, and until task 11.287 a production server had
none: `TRITRACK_ENV=production` resolved to a sender whose delivery method was
empty. Every sign-in request answered `202` — correctly, because §4.5 requires
an identical response whether or not delivery worked — and no link went
anywhere. Nobody could sign in, and nothing said so. **A production server now
refuses to start unless a relay is configured.**

### Configuring it

Seven variables, all in `.env`, all documented in `.env.example`. The short
version:

| Variable | What it is | Required |
| --- | --- | --- |
| `TRITRACK_SMTP_HOST` | the relay's hostname | in production; setting it turns the real sender on anywhere |
| `TRITRACK_SMTP_PORT` | blank picks 587 / 465 / 25 by TLS mode | no |
| `TRITRACK_SMTP_TLS` | `starttls` (default), `implicit`, or `none` | no |
| `TRITRACK_SMTP_USERNAME`, `TRITRACK_SMTP_PASSWORD` | credentials, both or neither | only if the relay asks |
| `TRITRACK_SMTP_FROM` | the address links are sent from | with the host |
| `TRITRACK_SMTP_CA_CERT` | host path to a PEM of extra trusted roots | only for a relay behind a private CA |

**Any relay works** — a campus relay that trusts this host's address and needs
no credentials, a commercial sending service that issues a username and
password, or a throwaway catcher on a laptop. Nothing in the server names a
provider. Refused at startup, each naming the variable and never its value:
`none` in production; `none` together with credentials in any environment (a
password on an unencrypted hop); half a credential pair; a placeholder
password; a relay *and* `TRITRACK_DEV_MAGIC_LINK_DIR` at once.

**`starttls` is required, not opportunistic.** The client connects in
cleartext, and if the relay does not offer `STARTTLS` in its greeting it sends
nothing further — not the credentials, not the message — and logs that. A
relay that only speaks TLS from the first byte (port 465) wants `implicit`.

### How you know it works

**Three places, and only the third is proof.**

1. **At startup.** The server connects to the relay, negotiates TLS,
   authenticates, and hangs up without sending anything. `docker compose logs
   server | grep "Sign-in email"` shows either

   ```
   Sign-in email: relay smtp.example.edu:587 answered as "...", TLS established, credentials accepted. No message was sent; ...
   ```

   or a `WARNING` naming what failed. A failed probe does not stop the server
   — a relay that is down is not a configuration that is wrong, and a server
   that will not boot until its relay answers cannot serve sync to people who
   are already signed in. It is a warning on every boot, not once.

2. **Per delivery.** A link the relay would not take is logged as
   `[auth] MAGIC LINK NOT DELIVERED. Relay host:port (mode): <what the relay
   said>`, with the recipient redacted and never the token. **The person who
   asked for the link sees the same `202` either way** — that is §4.5, and it
   is why this log line is the only place a delivery failure appears. A
   deployment nobody is reading the log of is a deployment whose sign-in can
   be silently broken; `docker compose logs server | grep "NOT DELIVERED"` is
   the question to ask when somebody says their link never came.

3. **A message in a real inbox.** The two above are the relay's promises. This
   is delivery:

   ```sh
   docker compose run --rm --no-deps server --send-test-email you@example.edu
   ```

   It reads the same `TRITRACK_SMTP_*` the server does, sends one plain
   message with no link in it, and prints what the relay said. Exit 0 means
   the relay accepted it; **then open the inbox.** A message that arrives is
   the whole proof. One that does not is a question for whoever runs the
   relay — the server's part is done — and the usual answers are a sending
   address the relay will not send as, or a spam folder.

   `scripts/verify_smtp_delivery.sh` runs that same command against a local
   catcher with STARTTLS required and authentication on, the wrong password
   first, and reads the message back out. It proves the client against a
   relay this project did not write. **It does not prove anything about the
   relay a deployment actually uses.**

### What the message contains, and what it never can

The address, once, in the `To:` header. The link. Two sentences saying what it
is and that it works once. **Nothing a caller typed reaches the message** —
that is the bound §4.5 states, and it is what stops `POST /auth/magic-link`
from being a way to send mail to anybody from this server's address. The
address itself is checked twice before it touches the wire, **by the same
rule** (task 11.298): at the HTTP boundary, which answers `400 invalid_email`
to anything outside one `@` between plain ASCII, and again in the sender,
independently, so a second route reaching it could not skip the check — so
`a@b.com\r\nBcc: attacker@example.org`, the payload the plan recorded as
reaching `EmailSender` harmlessly while nothing sent anything, is refused at
the boundary, and refused again before a connection is opened if it ever got
past it.

**What that `400` means for a person, because until 2026-09-21 they were not
told.** The boundary used to apply a looser rule than the sender, so an
address with an accented or non-Latin character — `josé@universidad.mx` — got
the same `202` as everybody, no message, and a `NOT DELIVERED` line in this
log that only you can read. It now gets a `400`, which the app renders as a
sentence about the address. **This server sends to plain-ASCII addresses
only.** Internationalized addresses (SMTPUTF8, RFC 6531) need the relay to
advertise support and a message format this sender does not build; the first
real person refused for one is the trigger to build it — see the plan entry
for task 11.298 — and the `400` is what lets them tell you.

## Secret rotation (§4.6)

The full Phase 10 secret inventory is **the Postgres password** and **the SMTP
credentials** (`TRITRACK_SMTP_PASSWORD`, task 11.287). That is the whole list, kept short
deliberately: there is no signing key (no JWTs, §4.3) and no pepper (§4.2).
Nothing else in the database is a credential — the three demoted roles at the
top of this file are `NOLOGIN` privilege labels with no passwords of their own,
so **`POSTGRES_PASSWORD` is the only Postgres secret there is to rotate.**

### Rotating the Postgres password

**These steps were run, on 2026-09-02, against a real Compose stack with an
existing `tritrack_postgres_data` volume — twice, plus once in the wrong order
on purpose to see what that looks like.** That matters because the four steps
that stood here until task 11.128 had never been run by anybody: they said
"create the new credential alongside the old one", "update `.env`", "restart",
"revoke the old credential", and **they did not rotate anything.** A Postgres
role has one password, not two, so steps 1 and 4 had nothing to act on; and
`POSTGRES_PASSWORD` is read by `initdb` when the volume is first created and by
nothing afterwards, so editing `.env` changed only what the server *presents*.
An operator following them ended up with a server that could not talk to its
own database — and, before `/ready` existed, a `/health` still saying `200`.

The step that was missing is the `ALTER ROLE`. Substitute your own
`POSTGRES_USER` for `tritrack` throughout.

1. **Change the password in the database.** This is the step that rotates
   anything; everything else is bookkeeping. Existing connections are
   unaffected, so the running server keeps working — this is not the
   disruptive moment.

   ```sql
   ALTER ROLE tritrack WITH PASSWORD '<new password>';
   ```

   From the Compose stack, using the credentials still in `.env`:

   ```sh
   docker compose exec -e PGPASSWORD="$OLD_PASSWORD" postgres      psql -v ON_ERROR_STOP=1 -U tritrack -h postgres -d tritrack      -c "ALTER ROLE tritrack WITH PASSWORD '<new password>'"
   ```

   **`-h postgres`, not `-h 127.0.0.1`, and not the default socket.** The
   official image ships `host all all 127.0.0.1/32 trust` in `pg_hba.conf`, so
   a `psql` aimed at loopback *inside the container* ignores the password
   entirely. The first run of this drill checked the rotation that way and
   watched the old password keep "working" — the check was blind, not the
   rotation. Anything you do to confirm a password must go over the network
   path, where `scram-sha-256` applies.

2. **Update `POSTGRES_PASSWORD`** in `.env`, or in the deployment's secret
   store. On its own this changes nothing about the database; it changes what
   the server will present at its next start.

3. **Recreate the server container** — do not `restart` it:

   ```sh
   docker compose up -d --force-recreate server
   ```

   **`docker compose restart server` does not pick up a changed `.env`.** It
   restarts the existing container with the environment already baked into it,
   so the server comes back presenting the *old* password and cannot connect.
   Measured: `/ready` answered `503 {"degraded":["database"]}` and
   `/health` answered `200`. `up -d --force-recreate server` then fixed it on
   the next try. Only the `server` service needs recreating; leave `postgres`
   alone.

4. **Verify, rather than assume:**

   ```sh
   curl -i http://127.0.0.1:8080/ready     # expect 200 {"status":"ready"}
   docker compose logs server | tail -5    # expect "Connected to Postgres"
   ```

   `curl /health` is **not** a verification of this procedure — it answers
   `200` in both outcomes. That is the whole point of the section above.

There is no separate revocation step and nothing to clean up afterwards: the
`ALTER ROLE` in step 1 *is* the revocation, because the role has exactly one
password and the old one stops working the instant it runs. Watched, over the
network path: before the `ALTER`, the old password connects and the new one is
refused; after it, exactly the reverse.

**If you have other things holding that password** — a backup job's
environment, a colleague's `.env`, a `psql` alias — step 2 is where they all
have to be updated, and nothing here can check that for you.

### Rotating the SMTP credentials

This *is* the two-credential case the original four steps described, because a
mail relay can hold two credentials at once where a Postgres role cannot. Do
not assume the Postgres steps above transfer.

1. **Provision the new credential at the relay** (or ask whoever runs it to)
   alongside the old one. Nothing changes yet; the running server keeps using
   the old pair.
2. **Update `TRITRACK_SMTP_USERNAME` / `TRITRACK_SMTP_PASSWORD`** in `.env`.
3. **Recreate the server container** — `docker compose up -d --force-recreate
   server`, not `restart`, for the reason given above.
4. **Verify, rather than assume:** `docker compose logs server | grep
   "Sign-in email"` — the startup probe authenticates with the new pair and
   says so, or says what the relay answered. Then `--send-test-email` to an
   inbox you can read.
5. **Revoke the old credential at the relay.** Step 4 is what makes this safe
   to do.

**Written 2026-09-20 and not yet run against a real relay** — the procedure is
shaped by the client, which is done, and by the relay, which NAU has not named.
Run it once when it is, and correct this paragraph.

**After a suspected database dump**, additionally:

- Rotate the Postgres password as above.
- Revoke all sessions. Token *hashes* in a dump are not usable tokens, so this
  is precautionary rather than strictly required — but it is cheap, and the
  blast radius if the reasoning is wrong is one round of sign-ins:

  ```sql
  UPDATE auth_sessions SET revoked_at = now(), revoked_reason = 'db_dump'
  WHERE revoked_at IS NULL;
  ```

- Magic links do **not** need mass invalidation on hash exposure alone; they
  expire in 15 minutes regardless.

The server refuses to start if a required secret is missing, empty, or a known
placeholder (`changeme`, `password`, `1234`, …). That is deliberate: a default
that works is the mechanism by which a prototype reaches production with a
guessable credential.

## Session revocation (§4.3)

Two granularities, both self-service over HTTP for the authenticated caller:

- `POST /auth/sessions/revoke-all` — every session, every device ("sign out
  everywhere").
- `POST /auth/sessions/revoke-device` with `{"device_id": "..."}` — one device,
  for the lost-or-stolen-phone case.

Both take the `user_id` from the **validated session**, never from the request
body, so a forged value can only ever revoke the caller's own rows.

**There is deliberately no cross-user revocation endpoint.** Member removal
does **not** call `AuthService.revokeAllSessionsForUser` — sessions belong to a
person, not a project, and revoking them on removal from one project would
sign that person out of every other project they hold. What actually makes
removal immediate is that project access is re-resolved from membership on
every request with no cached decision (§4.3 of the security model); the
removed member's session stays valid, and their next request to that project
is refused anyway.

**One request is answered rather than refused, and it is deliberate — task
11.60, §4.27.** A `POST /sync/pull` from somebody whose stint has ended comes
back with *their own closed membership row and nothing else*: no project data,
no other person's row, and `push`/`ack` still refused. It exists because a
removed member's device otherwise never learns it was removed — the pull that
would carry the news is the request being refused — so the app showed "the
server is refusing access" and a delete control that did nothing. It is
inventory entry 28 in `SECURITY_SCOPE_AND_EXIT.md`, with an Open verdict until
Gate C attacks it. To revoke someone else's sessions today, do it in `psql`
using the SQL above with a `WHERE user_id = ...` clause.

## Rate limiting — a deployment precondition (§4.4, §6 item 7)

> **The rate limiter keeps its counters in process memory. This is a
> prototype-only shortcut and it must move to Postgres or Redis before any
> second instance or load-balanced deployment.**

Per-instance counters silently multiply the effective limit by the instance
count, which is the failure mode that looks like the control is working: every
instance dutifully enforces "3 per 15 minutes" while the user receives one email
per instance. Re-checked at task 10.16.

Current limits, from §4.4:

| Route | Per normalized email | Per source address |
| --- | --- | --- |
| `POST /auth/magic-link` | 3 / 15 min, 10 / day | 10 / 15 min, 60 / hour |
| `POST /auth/redeem` | — | 20 / min |
| `GET /auth/link-status/<id>` | — | 30 / min |

A per-**email** limit returns the same `202` a successful request returns and
silently does not send, because a `429` keyed on an address would tell the
caller that somebody recently requested links for it. A per-**source** limit
returns an honest `429` — that fact is about the caller and nobody else.

**The e2e integration suite is exempt from the per-source limits (task
10.26).** Docker's port proxy collapses every e2e client's connection onto the
same source address before it ever reaches `SourceIdentity`, so the suite's
own well-behaved traffic — not an attacker — tripped `magic-link, per source`
and `redemption, per source` roughly 18 tests in, regardless of `-j`.
**That sentence was true, load-bearing, and describing a live defect in the
deployment this same file documents; nobody connected the two for four gates.
It is finding J-2 — see "Does your host even have a source address?" below.**
`docker-compose.e2e.yml` sets `TRITRACK_RATE_LIMIT_PER_SOURCE_DISABLED=1`,
which `RateLimitPolicy.fromEnvironment` reads to raise (not remove) those
three rules to an effectively unlimited ceiling; the per-**email** limit, which the
suite never approaches, is untouched. The flag does nothing outside that one
compose override — it is refused outright when `TRITRACK_ENV=production`, and
has no `.env.example` entry, so a real deployment cannot pick it up by
accident. The end-to-end suite (`scripts/run_e2e_tests.sh`) now passes in a single
pass with no `docker compose restart server` between files.

### Source identity behind a proxy (task 10.52, §4.4.1)

> **`TRITRACK_TRUSTED_PROXIES` is required whenever anything other than this
> host can reach the server. The server refuses to start without it, and that
> refusal is the control.**
>
> Task 10.62 widened that from "when `TRITRACK_ENV=production`" and removed
> `none` from the acceptable answers — see "Does your host even have a source
> address?" below, which is the question to read first.
>
> Both variables here are an operator's own claim about their own network,
> measured rather than assumed. Full reasoning:
> `CLAUDE_DOCS/SECURITY_SCOPE_AND_EXIT.md`, "What `TRITRACK_TRUSTED_PROXIES` /
> `TRITRACK_PROXY_SOURCE_IDENTITY` mean".

"Per source address" above means the TCP peer. Behind a reverse proxy, every
request's TCP peer is the proxy — so unless the server is told, the per-source
bucket becomes **one bucket shared by every user of the deployment**. Ten
unauthenticated requests then deny magic-link sign-in to everybody for fifteen
minutes, and every audit row records the proxy's address instead of the
caller's. That is Security Gate finding I-1, and it was live in both this
repository's deployments for four gates.

Set exactly one of:

```sh
# These peers are proxies you operate. Addresses or CIDR blocks, comma- or
# space-separated.
TRITRACK_TRUSTED_PROXIES=172.31.242.10
TRITRACK_TRUSTED_PROXIES=203.0.113.4,10.0.0.0/8

# Nothing is in front of this server, the TCP peer IS the client, and you have
# MEASURED that on this deployment (see the next section). X-Forwarded-For is
# never read. `none` used to be the spelling here and is no longer accepted for
# a server anything else can reach — task 10.62, finding J-2.
TRITRACK_TRUSTED_PROXIES=peer-verified
```

`docker-compose.tls.yml` sets this itself, to the fixed address it pins the
Caddy container to (`TRITRACK_TLS_PROXY_ADDRESS`, default `172.31.242.10`, on
`TRITRACK_TLS_PROXY_SUBNET`, default `172.31.242.0/24`). If that range collides
with something else on your host, override **both**, together. You do not need
to fill `TRITRACK_TRUSTED_PROXIES` in yourself for that path.

**If you put a different proxy in front, two things are on you:**

1. **It must OVERWRITE `X-Forwarded-For`, not append to it.** `proxy/Caddyfile`
   does (`header_up X-Forwarded-For {remote_host}`). A proxy that forwards a
   caller's own header unchanged lets that caller pick their own rate-limit
   bucket. The origin parses a multi-hop chain correctly — right to left,
   skipping hops that are themselves on the allowlist — but do not rely on that
   instead of configuring the proxy properly.
2. **`TRITRACK_TRUSTED_PROXIES` must name it.** The allowlist is of *sockets*.
   A header from any peer not on it is ignored entirely, which is what makes
   the scheme safe — nobody can talk their way onto the allowlist — and also
   what makes a typo silently reinstate the merged bucket. A malformed entry is
   refused at startup rather than skipped, for that reason.

**If a declared proxy sends no usable header**, the server cannot tell its
callers apart, so it **suspends the per-source limits** for that traffic rather
than refusing everyone, keeps enforcing the per-email limits, logs a warning
every fifteen minutes, and records `proxy-unattributed` in the audit log's
`source_address`. That is a misconfiguration to fix, not a mode to run in — but
it fails toward everyone being able to sign in rather than nobody.

Verify any of this with `scripts/verify_i1_source_identity.sh`, which brings up
the TLS overlay and attacks it from two client containers at distinct
addresses. It includes a negative control: with the allowlist deliberately
wrong, the merged bucket must come back, and the drill fails if it does not.

### Does your host even have a source address? (task 10.62, §4.4.2)

Everything above answers "who is the caller" **given** a source address that
distinguishes callers. Whether you have one is a separate question, it belongs
to your host rather than to this server, and getting it wrong makes every
control above vacuous while all of them still test green.

Between a caller and this container sits whatever forwards the host's published
port. Linux with `iptables` DNAT normally preserves the caller's address.
**Docker Desktop does not** — the VM boundary rewrites every inbound connection
to one gateway address before any container sees it. When that happens the
per-source limit is one bucket for everybody, `auth_audit_log.source_address`
names a gateway, and nothing in the server can detect it: inside a container
every interface is the Docker bridge.

That was finding J-2, live in the deployment `README.md` used to document.
Measure it rather than assume it:

```sh
./scripts/verify_source_identity.sh --assisted
```

It stands up a throwaway origin and proxy, prints one URL per device, and waits
for **two devices that are not this host** to open them. Then it reads its own
access log and reports per shape:

| Shape | What it stands for |
| --- | --- |
| `direct` | an exposed base compose — governs `peer-verified` |
| `proxied` | `docker-compose.tls.yml`, reached from a real network |

Only a `PRESERVED` verdict licenses `TRITRACK_TRUSTED_PROXIES=peer-verified`
— an operator's own claim about their own network, made by reading this
verdict off the host being licensed, never generated on their behalf.

**`--assisted` is the only mode that can produce one, and that is deliberate**
(task 10.110, Security Model §4.4.4). The question — *does a caller from outside
reach this host with its own address attached?* — needs two real network
endpoints, and a probe holding only containers cannot manufacture one. Without
the flag the probe runs a screen that can return `COLLAPSED` or `NO VERDICT` and
never `PRESERVED`. The previous version answered automatically by having two
containers on a second Docker network dial the host's LAN address; on Linux that
measured the host's own hairpin NAT and returned `COLLAPSED` for **every Linux
host it was ever run on**, so nothing could be licensed at all.

You supply the traffic and the probe supplies the verdict. There is no flag,
prompt or environment variable by which you can assert `PRESERVED`, and every
address that arrives is classified first against the set of addresses the host
is *measured* to be able to produce by itself — loopback, its own interfaces,
its Docker subnets, and whatever it arrives as when it calls its own published
port. None of those can fill a device slot.

Three controls run before any verdict is read: **attribution** (the probe's own
containers must never classify as off-host — the regression control for the
defect above), **falsifiability** (the verdict engine must be shown able to
return `PRESERVED`, `COLLAPSED` and `NO VERDICT`, so a probe that has lost its
PASS branch fails loudly instead of quietly refusing every host), and
**machinery** (the on-network path, which proves the log and the proxy header
work and *nothing about the publish path* — it used to be described as a
negative control for the verdicts, and it passed in the same run that produced
two wrong ones). Prove them: `TRITRACK_PROBE_SELFTEST=blind-filter` and
`TRITRACK_PROBE_SELFTEST=break-machinery` each sabotage one and must exit
non-zero.

`--report-only` runs the screen and exits non-zero only when a control fails;
that is the mode `gate_smoke_test.sh` registers, because a `COLLAPSED` verdict
is a true fact about a macOS host rather than a broken tool, and an instrument
that is permanently red gets switched off.

### The proxy has the same problem, one hop up (task 10.74, finding K-2)

The `proxied` shape collapses on Docker Desktop too, because Caddy forwards the
address *it* sees and that address has already been rewritten. The allowlist is
then correct, the header is then honest, and the per-source limit is still one
bucket for everybody. `verify_i1_source_identity.sh` does not see this — its
clients sit on the compose network and reach Caddy directly, crossing no
publish path.

So **an allowlist now requires a second answer**, and the server refuses to
start without it:

```sh
# scripts/verify_source_identity.sh --assisted, run ON THIS HOST from two
# real off-host devices, reported `proxied: PRESERVED`. The only value that
# qualifies a deployment to be exposed — including the one
# docker-compose.tls.yml describes.
TRITRACK_PROXY_SOURCE_IDENTITY=probe-verified

# Nothing off this host reaches the proxy either: every caller is on the
# compose network, crossing no publish path, where identity survives by
# construction. What verify_i1_source_identity.sh and verify_tls_termination.sh
# both set. NOT an answer for a deployment a phone can reach.
TRITRACK_PROXY_SOURCE_IDENTITY=on-network-only
```

`docker-compose.tls.yml` fills in every other variable it needs and **passes
this one through from your `.env` with no default**. That asymmetry is the
point: the allowlist is a fact about that file, and this one is an operator's
own claim about their own network, which the file cannot know and this
repository must not assume. §4.4.2. Full reasoning:
`CLAUDE_DOCS/SECURITY_SCOPE_AND_EXIT.md`, "What `TRITRACK_TRUSTED_PROXIES` /
`TRITRACK_PROXY_SOURCE_IDENTITY` mean".

## Audit logs and retention (§4.7)

Three classes, different windows because their sensitivity and their questions
differ:

| Table | Retains | Answers |
| --- | --- | --- |
| `auth_audit_log` | 1 year | "Was my account compromised in March?" — asked in September |
| `sync_traffic_log` | 180 days | "Where did my observation go?" — asked at the end of a field season |
| `project_join_requests` (decided only) | 30 days | "Did they let me in?" — and then it stops being on their screen |

**Undecided join requests are never swept.** A pending request is somebody
waiting for an answer, and deleting it would answer them by silence.

### The schedule, and how you know it is working (task 11.79)

**You do not have to schedule this either.** `docker compose up` starts an
`audit-retention` service that sweeps whenever a row passes its window and comes
back after a reboot.

This section used to say that nothing ran the sweep — and it was worse than
that. The command it gave, `dart run bin/purge_audit_logs.dart`, **could not run
in the shipped container at all**: `server/Dockerfile` AOT-compiles into a bare
`debian:bookworm-slim` with no Dart SDK and no source, so the one documented way
to apply §4.7 worked on a developer's laptop and nowhere the operator would ever
be. The entrypoint is compiled into the image now, as
`/app/bin/tritrack-audit-retention`.

**What tells you: the age of the oldest surviving row.**

```bash
docker compose ps                       # audit-retention shows (healthy) / (unhealthy)
scripts/audit_retention_status.sh       # the same answer as a sentence
docker compose run --rm audit-retention --once   # sweep now, by hand
```

```
auth_audit_log: oldest of sign-in events is 41d (984h) old — within the
  365-day window (+48h grace).
sync_traffic_log: no sync-traffic rows held at all — nothing to prune.
RETENTION IS BEING APPLIED — nothing on this server is past its window.

RETENTION HAS STOPPED BEING APPLIED — this server is still holding 412-day-old
  sign-in events in auth_audit_log (window 365 days). Those rows carry
  researcher email addresses and device identifiers past the window that
  justified keeping them, and the sweep that should have deleted them has not
  run.

AUDIT RETENTION UNKNOWN — no database available (...), so the age of the oldest
  surviving row cannot be measured.
```

**The check measures the rows, never the schedule.** It knows nothing about
whether the loop is running, which is the whole design: a wedged sweep, a
container somebody stopped, a database the purge cannot write to and a `.env`
edited last month all go red, because to a person they are one fact — *we are
still holding rows we said we would have deleted.* A check that asked "is the
scheduler up?" would have been green through every one of them.

**"I cannot reach the database" is a third outcome, not a flavour of green.** A
check that cannot measure must never answer "nothing is past its window".

**An empty table is healthy here**, and that is the one place this differs from
the backup freshness check next door. An empty backup directory means every
observation exists only on the phones that recorded it; an empty audit table
means there is nothing here to leak.

**The 48-hour grace (`TRITRACK_AUDIT_RETENTION_GRACE_HOURS`) was chosen, not
inherited.** The sweep runs on an interval, so between runs a row legitimately
sits a few hours past its window; a check with no grace would be red for part of
every day and would therefore be ignored — which is the only failure mode that
would put us back where this started. Two days past a 30-day window is a
schedule that has stopped, not a schedule that is late. One line in `.env`;
Michael has the final say and changing it costs nothing.

Read both logs through the diagnostics console — `/diagnostics/auth-events` and
`/diagnostics/traffic`. **How to turn that on is the next section**, and until
task 10.80 it was written down nowhere, which meant the audit trail this section
describes had no documented reader at all (finding D-5).

## Destroying a project on a schedule (task 11.290)

**What it is.** A project owner can ask, from the app, for a project to be
destroyed — not hidden behind a `deleted_at` flag, but every row of it removed
from this server: the project, its members' rows, every bearing, animal, collar
and estimate in it. The need is governance rather than disk space: a permit
condition, a landowner agreement, a collaborator who withdraws consent, and a
researcher who has to be able to say *"that project is gone"* and have it be
true.

**How it works, in order.**

1. The owner schedules the deletion (Projects → ⋮ → *Delete from server…*).
   **The server sets the date** — now plus the grace period below, on this
   machine's clock. The app sends an action and nothing else; no device can
   shorten or extend the period.
2. Every member's app shows the project with the date and the days left, and
   offers an export from the same row. A contributor cannot cancel; the owner
   can, until the date.
3. On the date, the `project-destruction` service deletes the project. **No
   device is involved.** An owner who schedules a deletion and then spends a
   month out of signal still gets the deletion.
4. *Delete now* skips the wait, behind a second confirmation. **It does not
   say "permanently", because that would not be true:** the nightly backups
   keep `TRITRACK_BACKUP_KEEP` archives (30 by default), so the project is
   recoverable from a dump for about a month whatever the live server does.
   The app's words are *"removed from the server now, and out of the backups
   within 30 days"*, and that is the promise this server can keep.

**What "gone" reaches, and what it leaves.** Every project-scoped sync table,
the project's sync cursors and purge floor, its join settings and requests.
**Not** the audit log or the sync-traffic log — Michael's decision, 2026-09-20:
sign-in events keep a year and data-access rows 180 days under §4.7, and both
name the project id. Not `Users`: people are not project data. And each
member's copy on their own phone stays where it is — the app explains why, and
that copy is theirs to export.

**A destroyed project's identifier is retired.** The server keeps one row per
destroyed project (`project_destruction`, with `executed_at` set) so that a
device which was offline across the deletion and still holds the project cannot
put it back: its next push is refused with `403 project_destroyed`, which the
app turns into a sentence rather than the bare *"access refused"* a removed
member sees. That refusal is a deliberate, narrow exception to §4.13's rule
that a forbidden project and a fabricated one answer identically; the
alternative is a project resurrected by a pending rename with nobody deciding
to. What it discloses is that an identifier once named a project here — to a
signed-in caller who already holds that identifier.

### The grace period

`TRITRACK_PROJECT_DELETION_GRACE_DAYS` in `.env`. **Blank means
`TRITRACK_BACKUP_KEEP`** — 30 days — and that default was chosen rather than
inherited: a shorter grace period would promise a speed the backups do not
deliver, and the person clicking *delete* is often the one who has to make a
truthful statement to somebody else about when the data is gone. An
institution whose rules differ sets its own number; both the server and the
sweep read the same two lines, so the number an owner is shown before
committing is the number applied.

### The schedule, and how you know it is working

`docker compose up` starts a `project-destruction` service: a loop that wakes
every `TRITRACK_PROJECT_DESTRUCTION_CHECK_SECONDS` (hourly), destroys every
project whose date has passed, and prints what it did. Its healthcheck runs
`--check`, which reads **how far past its date the most overdue scheduled
deletion is** — never whether the loop is up:

```
docker compose ps                          # (healthy) or (unhealthy)
scripts/project_destruction_status.sh      # the sentence
```

```
No project deletion is scheduled on this server — nothing to carry out.

2 scheduled deletions are waiting for their date. DELETIONS ARE BEING CARRIED
  OUT — nothing on this server is past its date by more than 2h.

DELETIONS HAVE STOPPED BEING CARRIED OUT — this server is still holding 1
  project whose deletion date has passed by 74h (3d). Somebody was told that
  project would be gone by now, and the sweep that should have destroyed it
  has not run.

PROJECT DELETION UNKNOWN — no database available (...), so whether any
  scheduled deletion is overdue cannot be measured.
```

The two-hour grace (`TRITRACK_PROJECT_DESTRUCTION_GRACE_HOURS`) is one hourly
cycle plus slack; a check with no grace would be red for most of every hour and
would therefore be ignored. **"I cannot reach the database" is its own
outcome**, never a flavor of green.

**Who reads it.** `docker compose ps` and the status script answer when asked,
and this project has already lost ten days to a red nobody was looking at
(2026-09-12). The reader this design actually has is the owner: they scheduled
the deletion, their screen shows the countdown, and a project that outlives its
own date is something they notice. `scripts/operator_status.sh` names this as a
question it does not ask.

### A project an owner deleted but never destroyed — the operator path (task 11.292)

**What this is for.** Deleting a project in the app's Projects list (the plain
*Delete*, not *Delete from server…*) hides it and, since task 11.289, sends that
deletion to the server as a **tombstone**: the `Projects` row gets a
`deleted_at` and every record in it stays. A tombstoned project is on no
screen of any device — `GET /projects/mine` leaves it out for everybody — so
until task 11.292 built the app's own listing of them (the join screen's
*Deleted from your devices, still on the server* section, owner only), the one
way to destroy such a project was the three commands below. **They still work,
and they are the reach when the app cannot be used** — a project deleted by an
account nobody can sign in as any more, or a tombstone whose `last_modified_by`
is not the owner (the app's listing shows an owner only the tombstones they
sent themselves). Michael ran the equivalent by hand for four projects on
2026-09-20; this text was run against a throwaway project on 2026-09-21 to
prove it says what it does.

**1. See what is flagged deleted, and who deleted it.** Nothing here changes
anything.

```bash
# Single quotes on the outside on purpose: POSTGRES_USER and POSTGRES_DB are
# expanded inside the container, where they are set.
docker compose exec postgres sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
  -c "SELECT project_id, project_name, owner_user_id, last_modified_by, deleted_at \
        FROM \"Projects\" WHERE deleted_at IS NOT NULL ORDER BY deleted_at;"'
```

**2. Schedule the ones you have decided on, one `INSERT` per project id.** The
date is the server's `now()`, so the next sweep carries it out; put
`now() + interval '30 days'` there instead if you want the grace period the
app would have given (the countdown is visible to the owner in the app's
listing, and to nobody else — a tombstoned project is not on any member's
screen). `scheduled_by` is a free-text column that the route fills with the
owner's user id; write `operator` so the row does not claim a person did this
from a phone. `ON CONFLICT DO NOTHING` means a project already scheduled from
the app keeps its date.

```bash
# -T: no pseudo-terminal, so the SQL arrives on stdin from the heredoc.
docker compose exec -T postgres sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1' <<'SQL'
INSERT INTO project_destruction (project_id, scheduled_by, destroy_at)
VALUES ('<project_id from step 1>', 'operator', now())
ON CONFLICT (project_id) DO NOTHING;
SQL
```

**3. Run the sweep now rather than waiting for its hourly wake.** This is the
same code the app's *Delete immediately* runs; the id is retired afterwards
(`project_destruction.executed_at` is set, and every `/sync/*` request for it
draws `403 project_destroyed`).

```bash
docker compose run --rm project-destruction --once
```

The sweep prints what it destroyed. To confirm, re-run step 1: the project
should be gone from the result, and
`SELECT project_id, executed_at FROM project_destruction WHERE executed_at IS NOT NULL;`
should name it.

**What this does not do.** It does not touch the audit log or the sync-traffic
log, and it does not touch any phone: a device that still holds the project
keeps every record and learns on its next sync that the project was deleted
from the server, exactly as after an app-scheduled deletion.

**Bringing one back instead of destroying it (task 11.302).** The owner who
deleted a project can restore it from the same section of the app —
*Restore* on its row — and that is the way to do it. **Do not do it with a bare
`UPDATE "Projects" SET deleted_at = NULL`.** That makes the project live on the
server, but it leaves the row's `revision` and `server_seq` where the tombstone
put them, so the row sits below every member's sync position and ties with the
tombstone every phone already holds: **no phone that already had the project
gets it back on its own**, and each person would have to find it on *Join a
project* and tap *Restore* there. The app's route also bumps the revision,
re-stamps `server_seq` and withdraws any scheduled destruction in the same
transaction, which is what makes every phone fetch it on its next foreground.
If a tombstone ever needs restoring that the app cannot reach — an account
nobody can sign in as, or a tombstone with no `last_modified_by` from a build
older than the stamp — that is a new operator command to write and prove, not
this `UPDATE`; ask for it rather than improvising it on a server you care about.

## Deleted records are purged after 24 months, and what the first purge does (task 11.291)

A record somebody deletes does not vanish from the server: it survives as a
**tombstone** — the row, marked deleted — so a device that was away can be
told what to delete when it comes back. Tombstones are purged once they are
**24 months** old (`tombstoneRetention` in the shared package, sized against a
phone shelved across two field seasons), and a device whose last recorded
position is below what was purged is **refused**: it may have missed a delete
the server can no longer describe, so accepting its rows could bring a deleted
record back. The app tells the person *"This device has been offline too long
to sync this project safely"*, and nothing on the phone is changed.

**Until 2026-09-21 the refusal existed and the purge ran from nowhere** — task
10.11 wrote both, tested both, and nothing called `purge()`. So every server's
purge floor was zero, no device had ever been refused, and the retention the
security model describes had never operated. `docker compose up` now starts a
`tombstone-retention` service, `bin/audit_retention.dart` one table over.

### What the first sweep does on a server with history

**A tombstone's age is measured on the server's own clock** — `received_at`,
when this server accepted the delete — **never on the device's deletion
stamp.** A record deleted on a phone in 2023 and uploaded when the project was
published in 2026 is, to the sweep, a 2026 deletion. Two things follow, and
both are the point:

- The first sweep purges only deletes this server has itself held for 24
  months, and can refuse only a device that has not synced that project in
  24 months. **On a server younger than 24 months the first sweep purges
  nothing and refuses nobody**; the first real purge lands 24 months after the
  oldest delete the server has seen.
- A phone with a wrong clock cannot make a fresh deletion purgeable by
  stamping it in the past.

The cost is that pre-upload deletions are kept for 24 months from their
upload rather than from their deletion — kilobytes.

Purging is additionally held back by every device that has synced the project
inside the window, at the lowest such device's recorded position, so a device
that keeps syncing is never stranded however far behind it is. **Every pull
now records the device's position** (task 11.291): before, only an
acknowledgement did, and the app acknowledges only a page that moved, so a
project's publisher — or any device on a quiet project — had no recorded
position at all and could not be held back for.

### Before switching it on: read what it would refuse

```bash
scripts/tombstone_retention_status.sh      # starts Postgres only, never the sweep
```

It prints what the server holds, what the next sweep would purge, and **how
many devices that would refuse** — the number to read before the first
`docker compose up` that starts the service on a server with history.

### The schedule, and how you know it is working

The loop wakes every `TRITRACK_TOMBSTONE_RETENTION_CHECK_SECONDS` (hourly),
purges in one transaction per run, and prints what it did. Its healthcheck runs
`--check`, which reads **how long the oldest purgeable tombstone has been past
the window** — a row the sweep should have deleted and has not — never whether
the loop is up. A row an active device has not yet received is not overdue.

```
docker compose ps                          # (healthy) or (unhealthy)
scripts/tombstone_retention_status.sh      # the sentence
docker compose run --rm tombstone-retention --once   # sweep now, by hand
```

```
No deleted record is held on this server at all — nothing to purge and nobody
  to refuse.

Holding 41 deleted records; the oldest reached this server 52d ago and becomes
  purgeable in 678d (window 730 days).
RETENTION IS BEING APPLIED — nothing on this server is past its 730-day window,
  so the next sweep will purge nothing and refuse nobody.

2 deleted records in 1 project (proj-a) are past the window and will be purged
  on the next cycle. The sweep will refuse 1 device on 1 project (proj-a) — a
  device that has not synced that project in 730 days, or whose acknowledgement
  never reached this server. Each will be told it has been offline too long to
  sync safely, and keeps its own records. The app then offers that device no
  way back onto the project: it can export its records, and that is all.
  Before this sweep runs, decide whether to build the recovery flow
  (development plan, task 10.11's Discovered Scope; task 11.299).
RETENTION IS BEING APPLIED — nothing on this server is past its 730-day window
  by more than 48h.

RETENTION HAS STOPPED BEING APPLIED — this server is still holding 2 deleted
  records in 1 project (proj-a) past the 730-day window, the oldest by 70d
  (1680h). The sweep that should have purged them has not run. ...

TOMBSTONE RETENTION UNKNOWN — no database available (...), so whether any
  deleted record is past its window cannot be measured.
```

The 48-hour grace (`TRITRACK_TOMBSTONE_RETENTION_GRACE_HOURS`) is the audit
sweep's, for the audit sweep's reason. **"I cannot reach the database" is its
own outcome**, never a flavor of green.

**A refused device has no built way back onto the project at all.** Its records
stay on the phone and can be exported, and that is the whole of what the app
offers it. Re-joining does *not* give it the server's copy: joining a project
the device already holds relinks the copy that is there (`ProjectDirectoryClient`
in the app), and the sync round that follows pushes first — the request being
refused. Getting what it recorded while away onto the server without also
offering stale copies of purged records is task 10.11's deliberately unbuilt
recovery flow; the sentence above is the trip-wire for deciding it (task 11.299).
See `TriTrack_Technical_Context.md`, "Tombstone retention".

## The diagnostics console — seeing what the server actually holds (§4.10)

**What it is.** Nine read-only routes that answer "what is really in there?" —
the projects on this server, who is a member of each, how many rows of each kind
they hold, the identities and devices that have signed in, every sign-in event,
every sync round, and any record whose revision counter has been pushed
somewhere it can no longer be overtaken from. Every route is a `GET` and every
query is a `SELECT`; there is no route that can change anything (§4.10 — use
`psql` for that, deliberately).

**Read this before you turn it on.** The console has **no per-user login**. The
token below is its entire authentication, and anyone holding it reads *every*
project on the server, including other people's collar locations. That is a
deliberate design decision for a tool whose intended user is the person who
already has a shell on the machine, and **task 10.80 did not change it** — what
10.80 changed is which configurations are allowed to hold that token. Treat the
token exactly like the Postgres password: it goes in `.env`, never in a commit,
never in a chat message, and rotating it is a restart.

### Turning it on

```bash
# 1. Generate a token. 64 hex characters; anything under 32 is refused.
openssl rand -hex 32

# 2. Put it in server/.env, along with the switch itself.
TRITRACK_DIAGNOSTICS_ENABLED=true
TRITRACK_DIAGNOSTICS_TOKEN=<the 64 characters from step 1>

# 3. Restart. Nothing is read from .env until the process starts.
docker compose up -d server
docker compose logs server | tail -5      # look for the line below
```

A server that came up with the console on says so, on every start:

```
Diagnostics console enabled (localhost only).
```

If instead the server refuses to start, read the block it printed: **every
refusal names the variable to change and what to change it to.** There are four,
and they are the whole of what this console will not do (task 10.80):

| What you set | What happens | Why |
| --- | --- | --- |
| `ENABLED=true`, no `TOKEN` | refuses to start | there is no per-user login behind it |
| `TOKEN=changeme` (or any known placeholder) | refuses to start | §4.6 — a guessable token is not a token |
| a `TOKEN` under 32 characters | refuses to start | nothing rate-limits guesses against this console |
| `ENABLED=true` with `TRITRACK_ENV=production` | refuses to start | §4.10 — never on a production deployment |
| `ALLOW_REMOTE=true` without TLS | refuses to start | §4.1 — that publishes the token, and every coordinate, in cleartext |

None of these can stop a server that did not ask for the console: they fire only
when `TRITRACK_DIAGNOSTICS_ENABLED=true` is set.

### Reading it

The console answers on loopback only. On the machine itself — **reading the
token out of `.env` rather than pasting it**, because a pasted bearer credential
ends up in your shell history and in whatever you copied the command into:

```bash
set -a; . ./.env; set +a
H="Authorization: Bearer $TRITRACK_DIAGNOSTICS_TOKEN"

curl -s -H "$H" http://127.0.0.1:8080/diagnostics/health
curl -s -H "$H" http://127.0.0.1:8080/diagnostics/projects
```

Pipe anything through `python3 -m json.tool` to read it as a person:

```bash
curl -s -H "$H" \
  "http://127.0.0.1:8080/diagnostics/auth-events?limit=20" | python3 -m json.tool
```

| Route | Answers |
| --- | --- |
| `/diagnostics/health` | is it up, and which schema and protocol version is it speaking |
| `/diagnostics/projects` | every project on the server |
| `/diagnostics/projects/<id>` | that project's row counts per table, and its members |
| `/diagnostics/projects/<id>/rows/<table>` | the most recent rows of one table (`?limit=`, default 50, max 500) |
| `/diagnostics/identities` | the accounts that exist |
| `/diagnostics/devices` | the devices that have signed in (`?user_id=` to narrow) |
| `/diagnostics/auth-events` | `auth_audit_log` — every sign-in attempt (`?email=`, `?limit=`) |
| `/diagnostics/revision-anomalies` | records whose revision counter is pinned out of reach |
| `/diagnostics/traffic` | `sync_traffic_log` — every sync round (`?lost_only=true` for the rows that lost) |

**From your laptop to a server somewhere else, use an SSH tunnel** — not
`TRITRACK_DIAGNOSTICS_ALLOW_REMOTE`. The tunnel gives you SSH's encryption and
SSH's authentication on top of the token, and it leaves the console unreachable
from anything else on the network:

```bash
# On your laptop. Leave it running; the console is then on YOUR 8080.
ssh -N -L 8080:127.0.0.1:8080 you@the-server

# In another terminal, the same curl commands as above. Read the token off the
# server over the same SSH connection rather than keeping a second copy of it
# on your laptop:
ssh you@the-server 'grep DIAGNOSTICS_TOKEN /path/to/tritrack/.env'
```

`TRITRACK_DIAGNOSTICS_ALLOW_REMOTE=true` exists for the case where the server
already serves TLS and you have a reason to reach the console across the
network; without TLS it refuses to start, because it would otherwise put the
token on the wire.

### On a production deployment, the console is not the answer

`TRITRACK_ENV=production` refuses the console outright (§4.10), so on a
deployment marked production the way to read the audit trail is `psql` — which
is also the only way to read anything if you would rather not run the console at
all:

```bash
# The quotes are single on the outside on purpose: POSTGRES_USER and
# POSTGRES_DB are expanded INSIDE the container, where they are set, rather
# than by your own shell, where they are not.
docker compose exec postgres sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
  -c "SELECT occurred_at, event, email, source_address, outcome, reason \
        FROM auth_audit_log ORDER BY occurred_at DESC LIMIT 20;"'
```

**Which of the two you use is a decision about the deployment, not about the
day.** A machine marked production is one whose data belongs to other people; a
console with one shared token and no per-user login is a developer's tool, and
`psql` at least leaves a record of who typed it in the shell history of an
account somebody owns.

## Dependency audit (§3.8)

Server dependencies are **pinned to exact versions** in `pubspec.yaml`, with
`pubspec.lock` committed. Upgrading is a deliberate edit, reviewed like any
other change. Before changing a pin, and at each review gate:

```bash
cd server
dart pub outdated              # what has moved, and how far
dart pub deps --style=compact  # the full transitive set being trusted
```

Two dependencies get scrutiny beyond the rest because they sit directly on
assets 1–3: `postgres` (handles every row) and whatever sends email (handles
magic-link tokens). Prefer the most boring option for both.

## Database backups (§4.9)

Every archive is `age`-encrypted to public keys whose private halves are not on
this machine, so a host compromise yields the live database but not every
historical snapshot of it. `pg_dump | age` runs inside one container and only
ciphertext is ever written to a filesystem.

**Read §4.9.1 of `TriTrack_Security_Model.md` before the first backup of real
data.** It is the key custody arrangement, and it is the part that cannot be
fixed afterwards: an archive's recipients are fixed when it is written, so a
custody mistake surfaces during a recovery. The short version — two holders,
each with their own `age` identity, a paper offline copy each, no key on the
server, and no break-glass copy anywhere.

### Where the archive is not (task 11.80) — the copy that does not exist yet

**`backup_db.sh` dumps this server's database, encrypts it, signs it, and
writes it into a folder on this same machine.** That covers a corrupted
database, a bad migration, a botched restore. **It does not cover losing the
machine**, and today the machine is a virtual machine on one laptop. Nothing in
this repository carries an archive anywhere else — no script, no step, no
instruction. `scripts/backup_status.sh` says so on every run, and
`scripts/backup_restore_drill.sh` ends by saying it has never restored from a
copy that is not on this host.

**What losing the machine would actually cost, counted rather than assumed.**
The server holds fourteen tables that also live on every device, and **ten that
live nowhere else**: `auth_accounts`, `auth_sessions`, `auth_magic_links`,
`auth_link_requests`, `auth_audit_log`, `project_invites`, `sync_cursors`,
`sync_seq_counter`, `sync_traffic_log`, `tombstone_purge_floor`.

So **losing this machine does not lose field data** — every phone keeps its own
copy of every bearing. It loses every account, every session, the sign-in audit
trail, any outstanding invitation, and **the numbered line every device's sync
bookmark points into**. That last one is the failure task 11.58 is about,
arriving by a different road: each device left holding a bookmark into a
sequence that no longer exists.

**Why this is a gap rather than a decision anybody made.** The archive is
encrypted to a key that deliberately **does not live on this server**, and
signed so a restore can tell a genuine archive from a planted one. **That design
only makes sense if the file goes somewhere the server cannot read.** §4.9
reasons about "the off-site copy" throughout. Something was meant to carry it.
Nothing does.

**This is not the app's cloud backup coming back, and the difference is the
whole point.** Michael removed that on 2026-08-30 (task 11.30): it sent
**unencrypted project data, on by default, to a third party**. What is missing
here is **an archive encrypted to a key the destination does not hold, signed
against forgery, moved deliberately by an operator who chose the destination.**
Those are different propositions and neither decision touches the other.

**The destination is Michael's decision and it is not made.** A second machine,
an external drive, object storage — and one part of it is a question for NAU
rather than a choice of ours: where an encrypted off-host copy is permitted to
live, and whether ITS would prefer a location they provide. **That question is
in `CLAUDE_DOCS/NAU_infosec_review_request.md`, which has not been sent.** When
the answer arrives, whatever carries the archive must be measured the way the
schedule is: **check that a recent archive exists at the destination** — fresh,
stale, absent, or unreachable, in four distinguishable sentences — and the drill
must restore from that copy, or say that it has not.

### Who the backup container runs as (task 11.70)

**You do not have to do anything here. This section exists because until
2026-08-30 you did, and nothing said so.**

The backup image runs as its own `postgres` user, uid 70, not as root — see
`server/backup/Dockerfile`; this container needs no root and does not get any.
But uid 70 is a stranger on your server. The `backups/` directory and the
mode-600 signing key below are yours, and on Linux a bind mount hands the
container the host's ownership unchanged, so a container running as uid 70
could neither create the archive nor read the key. `backup.sh` reported that as
`pg_dump | age pipeline failed; no archive written` — a message about the
database for a failure entirely about a directory. **Somebody following these
instructions exactly would have seen what reads like a transient error and
believed they had encrypted backups when no archive had ever been written.**

On macOS with Docker Desktop none of it happens: its file-sharing layer
presents host files to whatever user the container runs as. That is why the
procedure worked on one laptop for months and had never been run on a Linux
server.

**What fixes it, and why it is not a step you perform.** `docker-compose.yml`'s
`backup` service now declares a `user:`, and `scripts/backup_db.sh` and
`scripts/restore_db.sh` set it to whoever runs them (via
`scripts/lib/backup_user.sh`). So the archive and the signing key stay owned by
**you** rather than by a shared internal account — which matters, because the
signing key is what decides whose archives a restore will trust — and the fix
travels with the repository instead of depending on a `chown` somebody has to
remember and nothing can check.

Two consequences worth knowing:

- **Use `scripts/backup_db.sh`, not a raw `docker compose run backup`.** The
  raw compose line still gets the image's uid 70. It is no longer silent about
  it: `backup.sh` and `restore.sh` now refuse **before touching the database**
  and print which user the container is, who owns the path, and what to run
  instead. If you must use the raw line, export `TRITRACK_BACKUP_UID=$(id -u)`
  and `TRITRACK_BACKUP_GID=$(id -g)` first.
- **Take backups as the same user every time**, normally the one that owns
  `backups/`. A cron entry under a different account will be refused by name
  rather than writing archives that account owns and you cannot read.

#### If your `backups/` directory predates 2026-08-30 (task 11.80)

**The fix above works on new installations and leaves existing ones stranded**,
and this is the paragraph that was missing. If you brought the stack up with a
bare `docker compose up` *before* the `user:` line existed, the `backups/`
directory it created is owned by **root**, and it stays owned by root
afterwards. `scripts/server_up.sh` and `scripts/backup_db.sh` set who the
**container** runs as; nothing in this repository can change who owns a
**directory on your host**. So the backup keeps failing, and the message used
to answer with the one remedy you had already tried.

**This happened to a real backup on 2026-08-31, on this project's own server.**
One line, once:

```bash
sudo chown -R "$(id -u):$(id -g)" backups/
```

The failure message now prints that command with your actual numbers already
filled in, and says out loud that having run the scripts was not your mistake.

**And the drill measures this again.** `scripts/backup_restore_drill.sh` and
`scripts/verify_h6_archive_forgery.sh` used to pass `--user` themselves, which
let them run on Linux while the shipped procedure stayed broken — a green
instrument over a deployment that could not write a backup. They no longer do:
both take the user from the same compose declaration you do, and the drill's
step 0 asks a container who it is and fails if the answer is not you. A green
drill is evidence about your deployment again.

### Setup, once

```bash
# On YOUR machine, never on the server:
age-keygen -o ~/.config/tritrack/backup-identity.txt
chmod 600 ~/.config/tritrack/backup-identity.txt
```

That file is the private key. **Write its single `AGE-SECRET-KEY-...` line on
paper and store it somewhere physically separate** — that half stays manual on
purpose; see "Steps that stay manual" in the root `README.md`.

The **public** key is not a secret and there is no reason to transcribe it.
Have the command produce the finished line instead of describing which line to
copy:

```bash
printf 'TRITRACK_BACKUP_RECIPIENTS=%s\n' \
  "$(awk '/^# public key: /{print $4}' ~/.config/tritrack/backup-identity.txt)"
# -> TRITRACK_BACKUP_RECIPIENTS=age1abc...
```

Paste that whole line into `.env`. When the second holder sends you their
public key, append it comma-separated:

```
TRITRACK_BACKUP_RECIPIENTS=age1abc...,age1def...
```

Two recipients, not one: the second holder's own key, so that neither person
ever has to send the other a private key. The backup job warns on every run
while only one is configured, because "one recipient with an offline copy" and
"one recipient and nothing else" look identical from inside the container.

#### And the signing key — the other half (§4.9.2)

The keys above decide who may **read** an archive. This one decides who may
**write** one that a restore will trust, and until task 10.43 nothing did.
That is finding H-6: because the recipient string is public, *anyone who could
create a file in the backup directory* could write an archive that matched its
checksum, declared a supported schema, decrypted perfectly under your own
private key — and was then executed as a Postgres superuser and renamed over
the live database. `age` proves the bytes were not altered after encryption. It
cannot prove who encrypted them.

```bash
# ON THE MACHINE THAT TAKES BACKUPS — the opposite of the age keys above.
# An unattended cron job has to sign without a human, so this key lives with
# the job. -W means no password, for the same reason.
minisign -G -W -p backup-verify.pub -s ~/.config/tritrack/backup-sign.sec
chmod 600 ~/.config/tritrack/backup-sign.sec
```

Then have the command write both `.env` lines rather than describing which
line of which file to copy:

```bash
printf 'TRITRACK_BACKUP_SIGNING_KEY=%s\nTRITRACK_BACKUP_VERIFY_KEY=%s\n' \
  "$HOME/.config/tritrack/backup-sign.sec" \
  "$(tail -1 backup-verify.pub)"
```

```
TRITRACK_BACKUP_SIGNING_KEY=/home/you/.config/tritrack/backup-sign.sec
TRITRACK_BACKUP_VERIFY_KEY=RWQf6L...
```

**Why the command and not the description.** This used to read "the `RW...`
line of `backup-verify.pub`", and `backup-verify.pub` has two lines — an
`untrusted comment:` header and the key. Naming a line by its prefix, in prose,
is the shape of defect that cost task 11.38 a debugging round on a different
file (README.md's Team ID). The signing-key path had the same problem in a
quieter form: it was written `/home/you/...`, which is not the shape of a home
directory on macOS at all.

`TRITRACK_BACKUP_VERIFY_KEY` is public, but it has to be **authentic** — which
is a different property from secret. It belongs here, with the restore
procedure, and **never beside the archives**: a directory that supplies its own
verifying key proves only that it is internally consistent, which the forged
archive was too. Record it in the drill log at the bottom of this page when you
generate it, so there is a second place to check it against. It accepts a
comma-separated list, so rotating the signing key does not strand older
archives.

Losing this key costs nothing but future verifiability — there is no data
behind it. Generate a new pair, publish the new verifying key, take a fresh
backup. §4.9.2 has the full blast-radius table.

### Taking a backup

```bash
scripts/backup_db.sh
```

Writes `backups/tritrack-<UTC>.age` plus a `.sha256`, a `.schema` sidecar and a
`.minisig` signature. **Copy that directory off this machine** — an archive
that only exists on the server is not a backup of the server. The `.age` is
already ciphertext, so the destination does not need to be trusted with it.

**Pruning to the newest `TRITRACK_BACKUP_KEEP` (default 30) needs
`TRITRACK_BACKUP_VERIFY_KEY` set — the same key from "the signing key" above,
not a separate step.** Leave it unset and every run prints a `NOTE` and keeps
every archive it has ever written, forever, silently, with no further warning
after the first one (task 10.59, finding I-11). That is the fail-safe and
correct behaviour, not a bug — retention only prunes archives it can prove it
wrote (task 10.44/10.53, findings H-7/I-2), so with nothing to verify against
it refuses to guess. But it means an operator who never sets this key gets a
`backups/` directory that grows without bound and no signal that it will,
beyond a log line easy to miss in a cron job's output. If disk usage on this
machine is climbing, this is the first thing to check.

The `.minisig` (task 10.43) is what tells your archives from anybody else's.
It covers the archive bytes, and its *signed* comment carries the checksum and
the schema marker — so one signature binds all three of the things a restore
checks, and the two cleartext sidecars stop being independently forgeable. If
no signing key is configured the job **warns and still writes the archive**:
an unsigned backup is a complete, encrypted, restorable backup that merely
cannot prove where it came from, and refusing to take one would trade a real
data-loss risk for a paper control. The enforcement is on the restore side,
where the trust decision actually is.

The `.schema` sidecar is plain text (`schema_major=…`, `schema_version=…`) —
readable without the private key, so you can tell which schema an archive
holds before deciding whether to restore it (task 10.36). Archives from before
this task have no sidecar; restoring one treats it as schema major 1, the
last major before task 10.35's bump.

### The schedule, and how you know it is working (task 11.78)

**You do not have to schedule this, and you should not have to notice it
working.** `docker compose up` starts a `backup-scheduler` service that takes a
backup every `TRITRACK_BACKUP_INTERVAL_HOURS` (default 24) and comes back after
a reboot. `scripts/server_up.sh` is the one-word way to bring the stack up as
yourself — see "Who the backup container runs as" above for why that matters on
Linux.

This paragraph used to say *"schedule it the same way as the audit purge — a
daily cron. Nothing schedules it for you."* That is a step a human performs and
nothing checks — the class task 11.70 rejected one section up when it chose a
`user:` line in `docker-compose.yml` over a `chown` in these instructions. **The
result was that 11.70 turned a backup that fails loudly into a backup that is
never taken**, and nothing anywhere would have said so.

**What tells you: the age of the newest archive.**

```bash
docker compose ps                # backup-scheduler shows (healthy) / (unhealthy)
scripts/backup_status.sh         # the same answer as a sentence
```

```
newest backup: 6h old, within the 48h limit — backups are being taken.
NEWEST BACKUP IS 34 DAYS OLD (816h), past the 48h limit — backups have stopped
  being taken. Anything recorded since tritrack-…age exists only on the devices
  that recorded it.
NO BACKUP HAS EVER BEEN TAKEN — there is no archive in backups/. Every
  observation on this server exists only here and on the devices that
  recorded it.
```

**Stale and absent are deliberately different sentences.** Stale means the
schedule broke at a knowable moment and there is still a restorable copy of
something. Absent means every observation on this server exists only on the
phones that recorded it. Reading them as the same thing would cost somebody a
season.

**The check measures the archive, never the schedule.** It knows nothing about
whether the scheduler is running, and that asymmetry is the design: a wedged
loop, an empty `TRITRACK_BACKUP_RECIPIENTS`, a full disk, and a `.env` edited
last month all produce the same red, because to a person they are the same
fact. A check that asked "is the scheduler up?" would have been green through
every one of them. The age is read from the archive's **filename**, and a
filename is believed only when `minisign` verifies the archive under that exact
name against `TRITRACK_BACKUP_VERIFY_KEY` — retention's predicate (tasks
10.44/10.53), against the same attacker: otherwise anyone who can write into
`backups/` could plant `tritrack-29991231T235959Z.age` and turn this green
forever. Without that key set the age is still reported and labelled
`UNVERIFIED`, because an unauthenticated age beats no age as long as you are
told which one you have.

**48 hours is the complaint threshold, and it was chosen rather than
inherited.** One missed daily run is a reboot, a slow dump or a clock nudge, and
paging somebody for that teaches them to ignore the one signal that would tell
them backups had stopped — which is the only failure mode that puts us back
where this started. Two consecutive missed runs is not a hiccup; it is a
schedule that has stopped. 48h also bounds what is at risk to two days of
observations: a bad week rather than a lost season. Change it with
`TRITRACK_BACKUP_MAX_AGE_HOURS` if a day of your data is worth more than a false
alarm.

**Who is meant to notice, honestly.** The operator — the person who runs
`docker compose ps` on the machine — and nobody else. **A project owner in the
app is not told, and today has no way to find out.** The diagnostics console is
off by default and loopback-only, and the app's sync screen belongs to a project
rather than to a server, so neither could carry this. That is a deliberate
limit, not an oversight: an operator and a project owner may not be the same
human being, and the person who can fix a stopped backup is the one holding the
machine. If they are different people, somebody has to look at `docker compose
ps`, and no part of this repository can make them.

**Manual backups still count.** The schedule is a statement about archives, not
about the scheduler process, so a `scripts/backup_db.sh` you ran yourself
satisfies it exactly as a scheduled run does.

The job **refuses to run** with no recipients configured rather than falling
back to anything; there is no unencrypted path. It writes each archive under a
`.part` name and renames only after both `pg_dump` and `age` succeed, so an
interrupted or failed run leaves nothing that looks restorable.

### Restoring

```bash
scripts/restore_db.sh tritrack-20260809T211500Z.age tritrack_restored \
  ~/.config/tritrack/backup-identity.txt
```

Restores into a **new** database and leaves the live one alone; recovering in
place is available but has to be typed out (`TRITRACK_RESTORE_REPLACE=I_UNDERSTAND`),
because a restore happens under time pressure by definition.

Before touching the key, it checks the archive's origin, then its checksum,
then its schema major, refusing if the major is outside what this build
supports and naming both versions — the same which-side-is-behind reporting
the wire protocol gives (task 10.11, task 10.36).

#### Who wrote this archive? (task 10.43, finding H-6)

The first question the restore asks, and the only one an attacker cannot answer
for it. The signature is verified against `TRITRACK_BACKUP_VERIFY_KEY` from
`.env` — never against anything found in the backup directory. If it verifies,
the checksum and schema major recorded *inside* the signature are the ones the
script decides on, and a cleartext sidecar that disagrees is reported as a file
somebody else wrote rather than as bitrot.

An archive whose origin cannot be established — which is **every archive
written before task 10.43** — still restores, into a new database name, once
you say so:

```bash
TRITRACK_RESTORE_UNSIGNED=I_ACCEPT_UNVERIFIED_ORIGIN \
  scripts/restore_db.sh tritrack-20260809T211500Z.age tritrack_old \
  ~/.config/tritrack/backup-identity.txt
```

What it may **never** do is take over the name the server reads. No combination
of flags permits that, `TRITRACK_RESTORE_REPLACE=I_UNDERSTAND` included — that
flag says you accept losing what is in the target, not that you have
established where the replacement came from. Restore it into its own name, look
at it, and rename it into place yourself: one `ALTER DATABASE`, and it is the
difference between "a strange archive is sitting in a database" and "the field
record is now whatever an attacker wrote".

A signature that is **present and does not verify** is fatal with no override
at all. A missing signature is a legacy archive; an invalid one is a file
claiming an origin it does not have, and there is no benign reading of it.

#### Nothing is destroyed until the archive has been read (task 10.37)

The order matters more than anything else on this page, so it is spelled out:

1. the **signature** is checked, because it is the only one of these an
   attacker cannot author (task 10.43);
2. the recorded `.sha256` is checked, so damage in transit is reported as
   damage rather than as a confusing `age` error;
3. the `.schema` sidecar is checked — against the signed value, when there is
   one;
4. the archive is **decrypted end to end** and required to be a complete
   `pg_dump` — `age` authenticates per STREAM chunk, so reading to the end is
   the only thing that establishes the file is whole;
5. only then is it restored, into a `<target>_restore_<stamp>` database of its
   own — a name the script first checks nobody is using — in a
   `--single-transaction` so a mid-stream abort commits nothing;
6. only then are names swapped — and the existing database is **renamed** to
   `<target>_replaced_<stamp>`, not dropped.

Steps 1 and 4 answer two different questions and it is worth not confusing
them, because for three tasks this page did. Step 4 proves the bytes are whole
and were not altered *after* encryption. Step 1 proves they came from your
backup job. `age` can only do the first.

If the swap itself goes wrong, **nothing is cleaned up** — deliberately (task
10.43, finding H-9). By that point the staging database holds a fully verified
restore, so every failure message names both databases you are left with and
neither is dropped. Earlier failures still clean up their own staging database,
including on Ctrl-C, which is safe because step 5 established that the name was
free to begin with.

So a restore that goes wrong leaves you exactly where you started, and a
restore that succeeds still leaves the thing it replaced sitting there.
Nothing deletes that copy for you; check the restore holds what you expect and
then `DROP DATABASE "<target>_replaced_<stamp>";` by hand. A disk is cheaper
than a season.

**Retention rule (task 10.40): never automatic.** Unlike the `.age` archives
below, which are safe to prune by count because the encrypted originals stay
intact, a `_replaced_` database may be the only copy of the thing a bad
restore needs recovering from — the exact case this design exists for.
Auto-pruning it on any schedule reintroduces G-3's shape one layer up. So
there is no cron, no count limit, and no age limit: `restore.sh` prints a
`NOTE` listing any other `_replaced_` databases still sitting around every
time it creates a new one, so accumulation is visible at the moment an
operator is already looking, rather than discovered later as unexplained disk
usage. Dropping them stays a deliberate, manual act — the same reasoning
task 10.11 applied to tombstone retention: expiry chosen for a plausible
field-offline window and a device past it forced through an explicit,
readable failure rather than a silent one. Here it's a person past their own
verification window and a `NOTE` rather than a refusal, because nothing else
is waiting on this database being reclaimed.

Taking over a name requires renaming the existing database, which Postgres
refuses while anything is connected to it, so **stop the server first**. The
script checks for connections up front and says so rather than discovering it
after a full decrypt.

This is finding G-3. The previous version dropped and recreated the target and
*then* decrypted; at the second Gate C re-run that destroyed a live database
holding the only copy of an observation, using this page's own documented
procedure. The root cause of an unreadable archive getting that far was that
the checksum check lived in `scripts/restore_db.sh` — the wrapper that cannot
perform an in-place replace, because it never sets `TRITRACK_RESTORE_REPLACE`.
The single path that could destroy data was the single path with no integrity
check, and this section previously credited the check anyway.

Prefer restoring on your own laptop against a scratch Postgres rather than on
the server: the server is the machine §4.9 assumes may already be compromised,
and a restore is the one moment a backup private key would be near it.

### The drill — §4.9's "a backup that has never been restored is not a backup"

```bash
scripts/backup_restore_drill.sh
```

Unattended, self-contained, and destructive to nothing: its own compose project,
its own volumes, its own throwaway key pair, all removed on exit. It brings up a
real server so the *server's own* migration code builds the schema, seeds an
observation with coordinates, and then checks a couple of dozen things —
including the ones that are easy to get wrong and impossible to notice: that
the archive contains no seeded coordinate in the clear, that an unrelated key
is refused, that every column of every table survives the round trip, that a
failed `pg_dump` leaves nothing behind, that retention prunes the *oldest*
archives rather than the newest, that the `.schema` sidecar is readable and
correct without the key, that an archive with no sidecar (task 10.36) still
restores, and that a schema major outside this build's supported range refuses
instead of restoring.

Steps 7h–7m are the ones added by task 10.43, and they are the case none of the
others were. Every check the drill had before them is an **accident** — a
checksum that rotted, a file cut short, the wrong holder's key. Step 7h forges
an archive using nothing but the public recipient string, exactly as an entity
with write access to the backup directory would, and aims it at the live
database: it must be refused with the canary intact, **and refused again with
no verifying key configured**, because that is the state a deployment is in on
the day the fix lands. 7i–7j prove the escape hatch does not re-open the
in-place path, that a signature from an untrusted key is worse than none, and
that a genuine signature does not carry over to substituted bytes. 7k–7l force
the swap's rollback to run — it never had — including the double failure where
both renames fail and both copies must survive. 7m forces a staging-name
collision and checks that the refused restore drops none of the databases it
did not create.

Steps 7d–7g are the ones added by task 10.37, and they are the point of the
whole exercise: they stop the server, type
`TRITRACK_RESTORE_REPLACE=I_UNDERSTAND` **against the live database holding the
only copy of the seeded observation**, and check that a checksum-mismatched
archive, a truncated one and one encrypted to a key we do not hold each leave
that observation exactly where it was — and that a good archive still replaces
in place, with the database it replaced kept rather than dropped. Before
10.37 every target the drill restored into was a fresh name, so the one path
capable of losing data was exercised by nothing, which is how eleven green
checks and finding G-3 coexisted. **A drill that avoids the dangerous path is
not a drill.**

The drill prints its own check count on the last line rather than trusting a
number written here, because the recorded count and the real one had already
drifted twice.

**Run it quarterly, and after any change to the schema, the backup image, or the
pinned `age` or `minisign` version.** Record the date here:

| Date | Result | Notes |
| --- | --- | --- |
| 2026-08-09 | PASS (9/9) | Task 10.24, first drill. 21 tables, restored schema and rows identical. |
| 2026-08-13 | PASS (11/11) | Task 10.36: schema-marker sidecar readable without the key (step 5b), missing-marker archive still restores as major 1 (step 7b), out-of-range major refuses naming both versions (step 7c). |
| 2026-08-13 | PASS (20 checks) | Task 10.37, finding G-3. First run that exercises the in-place replace path at all (steps 7d–7g), against a live database holding the only copy of the seeded observation: it survived a checksum-mismatched archive, a truncated one and a wrong-key one, and a good archive replaced in place with the previous database kept as `tritrack_replaced_<stamp>`. Step 6 also strengthened — it used to accept any non-zero exit as "the wrong key was refused". |
| 2026-08-14 | PASS (33 checks) | Task 10.43, findings H-6 and H-9. First run with an adversary in it rather than only accidents: a forged archive made from the public recipient alone is refused with the canary intact, with and without a verifying key configured (7h–7j), as is one signed by an untrusted key and a genuine signature paired with substituted bytes. The swap's rollback executed for the first time, single and double failure (7k–7l), and a forced staging-name collision dropped none of the five planted databases (7m). `scripts/verify_h6_archive_forgery.sh` refuses in both configurations, and was confirmed load-bearing by neutralising the origin gate alone and watching H-6 reproduce. The archives now carry a `.minisig`; **the verifying key is regenerated per drill run and is not recorded here — a real deployment's belongs in this column** (§4.9.2). |
| 2026-08-14 | PASS (35 checks) | Task 10.44, finding H-7. Retention no longer trusts filenames: a "genuine archive" is now task 10.43's predicate — one whose `.minisig` verifies against `TRITRACK_BACKUP_VERIFY_KEY` — not a lexical timestamp. Step 10 plants a future-dated, unsigned `tritrack-29991231T235959Z.age` (exactly what write-only access to the directory can produce) and confirms retention refuses to prune ANYTHING that run, not even the genuinely oldest archive, and names the unaccountable file in its refusal. Step 10b confirms ordinary oldest-first pruning resumes once the planted file is removed, and step 9's existing keep-the-newest check still passes unchanged. |
| 2026-08-16 | PASS (38 checks) | Task 10.59, findings I-10 and I-11. **I-10:** the SQL inside the archive no longer runs as the Postgres superuser — restore.sh creates a `NOSUPERUSER` role once and `SET ROLE`s to it for the single connection that replays the dump, so `COPY … FROM PROGRAM` and every other superuser-only capability are unavailable to an archive's contents regardless of origin, not merely contained by 10.43's database-name isolation. Steps 7/7b/7c/7c2 (byte-identical restore, missing/out-of-range/rewritten schema markers) all now run through the demoted role and still pass. **I-11:** new step 8b exercises the configuration `docker-compose.yml` and `.env.example` actually ship — `TRITRACK_BACKUP_VERIFY_KEY` unset — and confirms the backup still succeeds, retention prunes nothing, and the NOTE explicitly says this recurs on every run. Closes task 10.54's sweep entry for this control. |
| 2026-08-30 | PASS (39 checks) | Task 11.70. **The first run since 11.69 whose result is evidence about a real deployment again.** 11.69 had made this drill pass `--user` on every container so it could run on Linux at all, which left it green over a shipped procedure that could not write an archive there. The overrides are gone: `docker-compose.yml`'s `backup` service declares the `user:` itself and this drill takes it from there, exactly as `scripts/backup_db.sh` does. New step 0 asks a container who it is and refuses if the answer is not the invoking user — watched failing, with the `user:` line removed, where it reports `the backup container runs as '70:70'` as its first line rather than a pg_dump error six steps later. The three new permission refusals in `backup.sh`/`restore.sh` (unwritable backup directory, unreadable signing key, unreadable archive or identity) were each watched firing against a volume owned by another uid, and each refuses **before** the database connection. |
| 2026-09-01 | PASS (39 checks) | Task 11.80. No new checks — the run is recorded because the drill now **states what it does not test**. Every archive it wrote and restored lives in a folder on the same host, there is no second location, and no restore has ever been performed from one; the drill says so in its own final output rather than only in this file. **A copy nobody has restored from is a belief, not a backup — and a copy that does not exist is not one either.** The destination is an unmade decision (see "Where the archive is not"), so this line is a standing gap rather than a failing check. |
| 2026-09-02 | PASS (42 checks) | Task 11.125. **Three new checks, and they are the first time `freshness.sh`'s `_is_genuine` has ever executed.** It is the defence that stops a file merely *named* like tomorrow's archive from reporting a deployment as backed up, and until now nothing set a verifying key when the freshness check ran, so that arm was skipped every time and the property was asserted by a test that read the script's text. New step 11 runs the real check three times against the archives this drill just wrote: with the key it names the newest signed archive and calls the age verified; with a future-dated **unsigned** plant in the directory it ignores the plant and still names the genuine archive; **and with the key removed it believes the plant and labels the age UNVERIFIED**, which is what makes the refusal above it evidence about the signature check rather than a coincidence. |
| 2026-09-29 | PASS (43 checks) | Task 11.58. **One new check: a restored database must not inherit the original's database identifier** (`server_database_identity`), the value that tells every device which database answered. The original holds one; the restore must hold none, so the server mints a new one on its next start and devices that synced against the original start their sync over rather than asking the restored database for rows after a number it never reached. `backup.sh` dumps the table without its row and `restore.sh` empties it in the staging copy; the check reads the outcome. **Both halves watched separately, the same day:** with `backup.sh`'s exclusion removed, so the archive carried the row, the drill still passed on `restore.sh` alone (the first run in which that `DELETE` had a row to delete); with both removed, it failed at this check, naming it, during step 7. |
