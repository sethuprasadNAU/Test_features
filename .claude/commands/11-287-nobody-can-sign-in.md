---
description: "Task 11.287 — in production the server sends no email, so nobody can sign in"
model: opus
---

Implement task **11.287** from `CLAUDE_DOCS/DEVELOPMENT_PLAN.md`. Read that entry first.

**This task is not blocked on NAU.** An earlier version of the entry said it was; that was corrected
on 2026-09-19. A generic SMTP client does not care which relay it points at, so build it now and
verify against a local relay. The entry says exactly what remains for NAU.

## What is wrong

`resolveEmailSender` returns `NullEmailSender` whenever `TRITRACK_ENV=production`, and
`NullEmailSender.sendMagicLink` is an empty method. **A production deployment accepts
`POST /auth/magic-link`, answers `202`, and delivers nothing.** Sign-in is the first thing anybody
does, and it is the first thing that fails.

**The `202` is correct** — §4.5 requires an identical response whether or not delivery worked, so the
endpoint cannot tell anybody. **This is the account-enumeration defense working as designed and
hiding a total outage behind it.** It is also why you cannot judge this feature from the outside:
a build that compiles and a build that delivers look identical.

## 1. A real sender, relay-agnostic

**The interface already exists and is already the right shape.** `sendMagicLink` takes the address,
the URL and the expiry, and its contract already says: *"implementations must not include any
caller-supplied content in the message beyond the address itself — otherwise this becomes a
message-delivery channel for whoever can hit the endpoint."* **Honor that. It is the whole security
surface of this feature.**

- **Host, port, credentials, sending address and TLS mode are configuration**, the way every other
  secret in this deployment already is. **Do not hard-code a provider.**
- **Verify against a local test relay** on the host. That gets the behavior right without waiting on
  anybody.

## 2. Header injection is the named risk, already written down

The plan records that `a@b.com\r\nBcc: attacker@example.org` **has already reached `EmailSender`**,
and was harmless only because neither existing sender sends anything. **It stops being harmless in
this task.** Check whatever library you use for header-injection handling, and **write the finding
down rather than assuming it.**

## 3. A delivery failure must reach the operator and must not reach the caller

`FileEmailSender` already solved this shape, and the comment explains why: on 2026-08-30 a
root-owned directory meant no link was ever written, and **neither the response nor the container's
log said anything at all. Eleven gate instruments could only report the symptom.**

So: the HTTP response stays an identical `202`, and the diagnosis goes to this container's stderr.
**Watch it fail before you make it work.**

## 4. Two sentences you are about to falsify

`CLAUDE_DOCS/TriTrack-server-architecture.html` currently says **"the server sends no email and makes
no outbound request at all"** and **"Outbound TCP 443 — the proxy renewing its certificate. Nothing
else."**

**That diagram was given to NAU's infosec reviewers.** Correcting both is part of this task, not a
follow-up — and check `SERVER_DEPLOYMENT_PRIMER.md` for the same claims. The diagram's source is
`CLAUDE_DOCS/TriTrack-server-architecture.svg`, shared by two documents; edit it once.

## Report `Partial`, and say what remains

**A local catcher is not an inbox.** Close `Partial` and name the one remaining step: a link reaching
a real address through NAU's chosen relay. **Do not claim `Done` on a test relay** — the whole defect
you are fixing is that delivery can be absent while everything looks fine.

## Before you report

`scripts/run_server_tests_docker.sh` and `flutter test`. **GitHub's checks are paused** (task 11.325) — your local runs
and the local nightly batch are the evidence.

## Acceptance

- The sender is relay-agnostic and configured, **no provider hard-coded**, and delivers end to end
  against a local relay.
- Header injection checked, **finding written down**.
- A delivery failure reaches stderr and leaves the response an identical `202`, **watched failing
  first**.
- The production path no longer resolves to `NullEmailSender`.
- **Both outbound-traffic claims corrected in the architecture SVG in the same commit.**
- Reported `Partial`, naming the real-inbox step.
