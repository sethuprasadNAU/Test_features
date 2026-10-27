# Hosting request to NAU ITS — TriTrack research server

> **SUPERSEDED 2026-09-14 — the question was answered in a meeting, not by this letter.**
> Michael met NAU ITS about the server software and *"we are moving forward with a plan to
> deploy on a linux app server soon."* This letter asked exactly one thing — **may this run
> on a NAU host, and does it risk NAU's network?** — and that is now answered yes, in
> principle, so the letter does not need sending.
>
> **It is kept, not deleted, for three reasons.** Its architecture paragraph is a record
> of what an administrator was told at the time; **it is the only written statement of what
> was asked of ITS**, which matters when someone later asks what they actually approved;
> and **one question in it was never answered and is still open** — see the next line.
>
> **Do not quote this letter's architecture paragraph as current, and it is not the source
> of anything any more (2026-09-21).** It says five containers; there are **six** since task
> 11.290, and the PDF it names was deleted by task 11.295. The live description is
> `CLAUDE_DOCS/SERVER_DEPLOYMENT_PRIMER.md` and the diagram is
> `CLAUDE_DOCS/TriTrack-server-architecture.html`. **The count below is left as written on
> purpose** — a superseded letter corrected to match today would stop being a record of what
> was asked, which is the only reason it is still here.
>
> **What did not get answered, and is now Michael's to ask directly: where may an
> encrypted off-host backup copy live?** Task 11.80 has been parked at that single line
> since 2026-09-01 waiting for it. Until it is answered, **no backup of the beta server
> leaves the machine it is a backup of.**
>
> **This does not close Gate C.** The gate's condition is *before any deployment reachable
> beyond localhost* — an agreed plan is not a deployment and not a sign-off. Re-read the
> gate against what ITS actually approves when the host exists.

**Rewritten 2026-08-31, from 278 lines to this.** The previous version asked NAU ITS to
review the application's data-integrity model — how one member of a research team could
enter a misleading record. **That is a real question and it is not theirs.** It has moved
to `CLAUDE_DOCS/DEVELOPER_REVIEW_BRIEF.md`, for a developer joining the project.

**What ITS is being asked is narrow: may this run on a NAU host, and does it create any
risk to NAU's network?** Everything below serves that question and nothing else.

**Recipient: still blank. Only Michael can fill it in and send it.**

**Corrected 2026-09-10.** The architecture bullet said **four** containers. It was true the day
it was written — 2026-08-31 — and **task 11.79 added the audit-retention service on 2026-09-01**,
which nobody carried back here. A count in a letter to a system administrator is exactly the
sentence they will check against `docker compose ps`, so it is now five, derived from
`docker-compose.yml` + `docker-compose.tls.yml` rather than from this paragraph's history.
**`CLAUDE_DOCS/TriTrack-server-architecture.pdf` is the one-page diagram to attach**, derived from
the same two files on the same day.

> **As-of note, 2026-09-21 (task 11.295's follow-up).** Both sentences above are true of
> 2026-09-10 and false today: the count is **seven** since task 11.290 added
> `project-destruction` and task 11.291 added `tombstone-retention`, and the PDF no
> longer exists — print
> `CLAUDE_DOCS/TriTrack-server-architecture.html` instead. **Left standing rather than
> rewritten**, for the reason in the banner: this paragraph's job is to record what was
> said, not what is so.

---

## Draft email

**Subject:** Hosting request — small research server for a wildlife-telemetry app (TriTrack)

Dear [name],

I lead the Dynamic and Active Systems Lab, and we have built a field application called
TriTrack that wildlife biologists use to record radio-telemetry bearings offline and then
sync them to a small server so a field team shares one dataset. I would like to run that
server on a NAU-hosted machine — something like `tritrack.nau.edu` — rather than on a lab
box under a desk, and I would like your sign-off on doing so. The users are a handful of
researchers on my own projects; there is no public sign-up, no student data, and nothing
that falls under FERPA or HIPAA. **In short, the architecture is:**

- **One Linux host running five Docker containers** — a reverse proxy, the application
  server, a PostgreSQL database, a scheduled backup job, and a job that applies our log
  retention windows. Nothing else.
- **Exactly one port is exposed: 443.** A Caddy reverse proxy terminates TLS and obtains
  its own certificate; the application server and the database publish no host ports at
  all and are reachable only from inside the Docker network. The database is not reachable
  from the network under any configuration.
- **It initiates no connections into NAU systems.** No LDAP, no campus SSO, no shared file
  storage, no database outside its own container. It does not currently send email; if we
  later add sign-in links by email it would need an SMTP relay, and I would come back to
  you before doing that.
- **What it stores:** researchers' names and email addresses, and the field records
  themselves — coordinates, times, and radio frequencies of collared animals. Sensitive in
  a conservation sense (locations of protected species), not in a regulatory one.
- **Backups** are AES-encrypted, taken daily by a container on the same host, and currently
  stay on that host. Getting a second copy somewhere else is on our list, and where that
  copy is allowed to live is one of the questions below.
- **Authentication** is per-user with server-side sessions; the server refuses plain
  `http://` entirely, so there is no unencrypted path to it.

I am asking for three things, and the middle one genuinely changes how we configure the
server. **First, approval to host this and whatever process that involves.** **Second: does
anything sit in front of a NAU-hosted machine — a load balancer, reverse proxy or WAF — and
if so, does it preserve the client's IP address?** Our rate limiting and our audit log both
key on the caller's source address, and if something upstream rewrites it then every caller
collapses into one bucket and the audit log records the proxy instead of the user. **The
server will refuse to start with a proxy in front of it until we have verified that
end-to-end from two off-site devices**, so this is not a question we can answer from our
side without knowing what is there. **Third: where are we permitted to keep an encrypted
off-host backup**, and is there a NAU-provided location you would prefer we use?

I am happy to provide anything further that is useful — the deployment configuration, the
threat inventory we maintain, or a walk-through of the server. I have deliberately kept
this short and about your infrastructure rather than about our data model; the
application-level security review is being done separately by a developer on my team.

Best regards,
Michael Shafer
Dynamic and Active Systems Lab, Northern Arizona University

---

## Notes for whoever next edits this, not for the email

- **The proxy question is the one that must be asked before deployment, not after.** It is
  finding J-2 in `TriTrack_Security_Model.md`: if something upstream rewrites the source
  address, the per-source rate limit becomes one shared bucket and `auth_audit_log` records
  the proxy — **and nothing in the server can detect that while every test stays green.**
  The server refuses to start with a proxy allowlist unless
  `TRITRACK_PROXY_SOURCE_IDENTITY=probe-verified`, and only
  `scripts/verify_source_identity.sh --assisted` — run **on the NAU host, with two real
  off-host devices** — earns that value. **Michael has to run it, and only after he has the
  host.**
- **Deliberately not in the email:** the trust-boundary inventory, the bar, the eight gate
  rounds, and every application-level finding. **None of it answers "does this endanger NAU's
  network", and including it invites a review nobody asked for from a team who would rightly
  decline to give it.** It is all in `DEVELOPER_REVIEW_BRIEF.md`.
- **The convenient coincidence, worth knowing before the conversation:** hosting on a NAU
  machine almost certainly requires ITS sign-off anyway. **The hosting request and the
  security review are one errand, not two** — which is why this letter asks for hosting and
  gets the review as a consequence, rather than the other way round.
- **If ITS asks for the application-level material,** send `DEVELOPER_REVIEW_BRIEF.md` and
  `SECURITY_SCOPE_AND_EXIT.md`. Both exist; neither is what this letter is for.
- **The draft's own bullet still says "five Docker containers" and lists five** (reverse
  proxy, application server, database, backup job, retention job) — found while building
  `CLAUDE_DOCS/CONTAINER_COUNT.md`'s instrument on 2026-09-21, and left standing for the same
  reason as the banner and the As-of note above: this is a record of what the letter said,
  not what is so. **If this letter is ever revived, the bullet needs a sixth and a seventh
  item**, `project-destruction` (applies data-deletion requests) and `tombstone-retention`
  (purges deleted records after 24 months), and the count updated to match
  whatever the count is by then — the count is **seven** today; see
  `CLAUDE_DOCS/CONTAINER_COUNT.md` for how to check.
