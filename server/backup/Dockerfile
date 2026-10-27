# Backup image (task 10.24 / Security Model §4.9).
#
# One image holding both halves of the pipeline, so `pg_dump | age` runs
# entirely inside a single container and the only thing ever written to a
# filesystem is ciphertext. Splitting it across two containers would route
# plaintext through the host, which §4.9's "plaintext never lands on disk, not
# even in a temp directory" is written to prevent.
#
# Pinned to the same Postgres major as docker-compose.yml's database: pg_dump
# refuses to dump a server newer than itself, so these two move together. The
# `alpine3.24` half of the tag is the package pin for age and minisign below
# (task 11.327); the database's own image does not need it and keeps
# `16-alpine`. Both are Postgres 16, which is the only thing pg_dump compares.
FROM postgres:16-alpine3.24

# age (https://age-encryption.org) — the encryptor §4.9 names.
#
# minisign (task 10.43 / finding H-6) — the signer §4.9.2 names. `age` has no
# signing mode, and encryption is not authentication: anyone holding the public
# recipient string (which §4.9.1 says may appear in a commit) can write an
# archive that decrypts perfectly with the operator's own key. H-6 reproduced
# exactly that, and the forged SQL reached psql as a superuser. Ed25519 over
# the archive is what tells "written by the backup job" from "written by
# whoever can create a file in that directory".
#
# How these two are pinned (task 11.327, replacing 11.175's reasoning, which
# the calendar disproved). Security Model §3.8 carries the same argument.
#
# THE PIN IS THE ALPINE RELEASE IN `FROM`, NOT A VERSION ON THIS LINE. apk
# installs from the package index of the Alpine release the base image is
# built on, fetched over the network at build time. No Alpine index keeps old
# versions of a package, and that includes a stable release: on 2026-09-04
# Alpine's 3.24-stable rebuilt age against a new Go (`-r` number changed), and
# on 2026-10-04 it upgraded age from 1.3.1 to 1.3.2 ("community/age: upgrade
# to 1.3.2"). So every pin written on this line so far has broken on somebody
# else's schedule: `age=1.3.1-r5` (an exact packaging revision) on 2026-09-06,
# and `age=~1.3.1` (an exact upstream version) on 2026-10-04, each time taking
# the restore drill and two other gate instruments down with it. The first was
# caught within two days by GitHub's runners, which have no build cache; the
# second was hidden by the VM's cache until it was cleared, because GitHub's
# checks are paused. A new server deployment has no cache.
#
# What a release gives that a version cannot: Alpine's stable branch is the
# unit that moves only for fixes, and the release's index never disappears
# (old releases stay on the mirrors, and old `postgres:16-alpine3.NN` tags stay
# on Docker Hub). So this builds on any date, and moving to a new Alpine
# release — and with it to whatever age and minisign that release carries — is
# a deliberate edit of the `FROM` line above.
#
# The `>=` floors are not the pin. They hold the versions whose behavior was
# last reviewed (age 1.3.2, minisign 0.12), so an edit of `FROM` to an *older*
# release is refused at build time (3.23 carries age 1.2.1) rather than quietly
# downgrading. Inside 3.24 they can never refuse anything.
#
# What this gives up, and the alternatives:
#   - An upgrade that Alpine ships *inside* 3.24 is taken without an edit here.
#     1.3.2 was exactly that, and it was fixes and hardening only (headers
#     over 2 MiB and more than 1024 recipients refused, malformed SSH
#     recipients refused, raw binary to a terminal refused; nothing in the
#     file format, or in the `-r`, `--decrypt -i` and piped use that
#     backup.sh and restore.sh rely on). The nightly check builds this image
#     with no cache and prints the versions it installed, so such a change is
#     visible the next morning rather than silent.
#   - The release stops receiving fixes for these two when Alpine retires its
#     community repository, which is when the next stable release ships —
#     2026-11-01 for 3.24, about six months for each release after. From then
#     on this goes stale rather than broken. The nightly check's preflight
#     reads that date from alpinelinux.org/releases.json and warns from a
#     month before it, so moving `FROM` forward is a planned edit, not a
#     surprise.
#   - An exact version (`=~1.3.1`) makes every upgrade a deliberate edit, which
#     is what §3.8 wanted, but only by turning every fix release into an outage
#     on Alpine's schedule, as 1.3.2 just did. A minor-version window (`=~1.3`)
#     would have survived 1.3.2 and breaks the same way the day Alpine ships a
#     1.4 into the release. Refused, both: the outage is the cost, and it
#     lands on whoever builds next, which may be a new deployment.
#   - Pinning `FROM` by digest freezes the base image but not the index apk
#     reads (11.175 was right about that much), so it would not have helped.
#   - Vendoring the release binaries with a checksum pins the bytes and never
#     breaks on the calendar. It costs a hand-tracked download URL and two
#     checksums per tool (the VM is arm64, a server may be amd64), and nobody
#     is told when a security fix ships. Refused for two widely used tools this
#     project does not otherwise maintain.
RUN apk add --no-cache 'age>=1.3.2' 'minisign>=0.12'

COPY backup.sh /usr/local/bin/tritrack-backup
COPY restore.sh /usr/local/bin/tritrack-restore
# Task 11.78. The schedule and the check on it. `tritrack-backup-schedule` is
# what the `backup-scheduler` service in docker-compose.yml runs, so that
# taking a backup stops being a step a human remembers; `tritrack-backup-
# freshness` is that service's healthcheck and answers the one question this
# whole arrangement exists to make answerable — how old is the newest archive.
# The check measures the archive, never the schedule, so it goes red for a
# wedged scheduler, a missing recipient and a deleted cron entry alike.
COPY schedule.sh /usr/local/bin/tritrack-backup-schedule
COPY freshness.sh /usr/local/bin/tritrack-backup-freshness
# Sourced by both of the above (task 11.70). It holds the one explanation both
# scripts need when a bind-mounted host path belongs to somebody other than
# the user this container runs as — the failure that used to be reported as
# `pg_dump | age pipeline failed`.
COPY permissions.sh /usr/local/lib/tritrack-permissions.sh
RUN chmod 0755 /usr/local/bin/tritrack-backup /usr/local/bin/tritrack-restore \
        /usr/local/bin/tritrack-backup-schedule /usr/local/bin/tritrack-backup-freshness \
 && chmod 0644 /usr/local/lib/tritrack-permissions.sh

# Clear the base image's entrypoint. `postgres:16-alpine` ships
# docker-entrypoint.sh, which exists to initialise a database cluster — this
# container never runs one, and inheriting it would put a layer of unrelated
# setup between the call site and the pipeline.
ENTRYPOINT []

# Runs as the `postgres` user, not root: this container mounts the backup
# directory, and briefly the private key during a restore. Neither needs root.
#
# Task 11.70: uid 70 is nevertheless a stranger on a Linux host, where a bind
# mount passes ownership through unchanged and the backup directory and
# signing key belong to the operator. `docker-compose.yml`'s `backup` service
# declares a `user:` that overrides this with the invoking user; this line is
# what a raw `docker run` of the image still gets, and permissions.sh is what
# says so out loud instead of blaming pg_dump.
USER postgres

# No default CMD. Every invocation names tritrack-backup or tritrack-restore
# explicitly, so what is being run is visible at the call site.
