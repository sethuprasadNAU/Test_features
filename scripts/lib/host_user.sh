#!/usr/bin/env bash
# gate-instrument: none - a sourced helper, not a runnable instrument.
# The one place that knows which user the development stacks run their server
# container as (task 11.69).
#
# Source it from the repository root, the same way as `load_env.sh`:
#
#   . scripts/lib/host_user.sh
#
# ## What it is for
#
# `FileEmailSender` writes each magic link `mode 600`, on purpose — the file
# holds a live sign-in credential and §4.7 forbids putting one in a log, so a
# file that only its owner can read is the affordance that replaces printing
# it. **Nothing here changes that.** The file is still 600.
#
# What this changes is *who owns it*. The server container runs as root, and on
# a Linux host a bind mount passes ownership straight through: the file lands
# `root:root 0600` and the developer — or the CI runner — cannot read the link
# it just asked for. On Docker Desktop the same write is remapped to the host
# user by the file-sharing layer, which is why every one of these stacks worked
# on a Mac and nothing about that was written down anywhere.
#
# Measured on the 2026-08-30 CI run: eleven of the eighteen gate instruments,
# and the whole broken-control workflow, died on
# `PermissionError: [Errno 13] Permission denied: '.e2e_magic_links/….link'`.
#
# So the development and end-to-end overlays run the server as the invoking
# user, and the credential is 600 and owned by the person who asked for it —
# which is what "owner-only" was always supposed to mean. **The base
# `docker-compose.yml` declares no `user:` at all and is untouched**;
# `server/test/security/shipped_defaults_test.dart` asserts both halves.
#
# ## Why it is a variable rather than a literal
#
# Compose has no way to spell "the invoking user", so the overlays read
# `TRITRACK_DEV_UID`/`TRITRACK_DEV_GID` and fall back to `0:0` — today's
# behaviour — when nobody set them. Every script that brings one of those
# stacks up sources this file. Someone running the raw `docker compose` line by
# hand on Linux still gets the old behaviour, and `scripts/gate_wire.py` and
# `test/e2e/support/magic_link_reader.dart` both now say so in a sentence when
# the link turns out to be unreadable, rather than reporting an errno.
#
# ## The second user of these two variables
#
# `backup_restore_drill.sh` and `verify_h6_archive_forgery.sh` read them for a
# related but distinct problem, and it is worth keeping straight. There the
# mismatch runs the other way: the backup image ships `USER postgres` (uid 70),
# and on Linux it cannot traverse the drill's own 0700 working directory, read
# the 0600 signing key mounted out of it, or create a file in the backup
# directory. Those two scripts pass `--user` on every `docker compose run` so
# the container is the invoking user instead. Same fact, same owner, opposite
# direction — which is why it lives here rather than being computed twice.

export TRITRACK_DEV_UID="${TRITRACK_DEV_UID:-$(id -u)}"
export TRITRACK_DEV_GID="${TRITRACK_DEV_GID:-$(id -g)}"

# ## The other half of the same fact: the directory that file lands in
#
# Task 11.69, second pass. Setting the user was necessary and was not
# sufficient. The magic-link directory is bind-mounted from the host
# (`./.e2e_magic_links`, `./.dev_magic_links`) and both are in `.gitignore` —
# they are directories full of live sign-in credentials, so that is right. But
# it means **a clean checkout does not have them**, and when a bind-mount
# source is missing, Docker Engine creates it *as root*. The server then runs
# as the invoking user, exactly as arranged above, and cannot create a file in
# the root-owned directory it was just handed.
#
# The failure is silent from the outside. `auth_routes.dart` swallows a
# delivery failure on purpose — §4.5's byte-identical response means a caller
# must not be able to tell a working address from a broken mailer — so
# `/auth/magic-link` still answers `202` and no link ever appears. Measured on
# the 2026-08-30 CI run: eleven gate instruments aborted with "no magic link
# appeared", and the first pass's diagnosis (`Errno 13`) no longer applied,
# because with a root-owned directory there is no file to be denied.
#
# **The broken-control workflow is the control that proves it.** It brings the
# same stack up with the same overlay and the same user, and it passed its
# whole magic-link surface on that run — the one thing it does differently is
# a `mkdir -p .e2e_magic_links` line of its own.
#
# This is the same class as the `server/.dart_tool/package_config.json` failure
# this task started with, and it hid the same way: on the development machine
# the directory has been sitting there since the first e2e run.
# **Something that is not committed is not part of the build** — a directory
# included.
#
# Created here rather than in each caller because each caller is where the
# previous copy of this line was missing: `run_e2e_tests.sh` had one,
# `gate_smoke_test.sh` and `dev_lan_address.sh` did not, and nothing said they
# should. `test/documentation/dev_stack_host_prerequisites_test.dart` is the
# guard that fails if a future script brings one of these stacks up without
# sourcing this file.
for _tritrack_link_dir in .e2e_magic_links .dev_magic_links; do
  if [ ! -d "$_tritrack_link_dir" ]; then
    mkdir -p "$_tritrack_link_dir" || {
      echo "WARNING: could not create $_tritrack_link_dir. Docker will create it" >&2
      echo "         instead, as root, and the development server will not be" >&2
      echo "         able to write a sign-in link into it." >&2
      continue
    }
  fi
  # An existing directory owned by somebody else is the *residue* of this bug
  # rather than the bug — a raw `docker compose up` on a Linux host, run once
  # without these variables set, leaves a root-owned directory behind that
  # every later run inherits. `mkdir -p` succeeds on it and says nothing, so
  # the stack comes up and the links silently never arrive. Say so here, where
  # the cause is still visible, rather than five minutes later in an instrument
  # that can only report the symptom.
  #
  # Never fatal: this file is sourced by scripts running under `set -e`, and a
  # warning that aborts the drill it was only trying to annotate would be a
  # worse bug than the one it reports.
  _tritrack_dir_uid="$(ls -ldn "$_tritrack_link_dir" 2>/dev/null | awk '{print $3}')" || _tritrack_dir_uid=""
  if [ -n "$_tritrack_dir_uid" ] && [ "$_tritrack_dir_uid" != "$TRITRACK_DEV_UID" ]; then
    echo "WARNING: $_tritrack_link_dir is owned by uid $_tritrack_dir_uid, but the" >&2
    echo "         development server will run as uid $TRITRACK_DEV_UID and writes each" >&2
    echo "         magic link into it. It will not be able to, and the sign-in" >&2
    echo "         link will silently never appear — /auth/magic-link still" >&2
    echo "         answers 202 either way (§4.5). Fix the directory's owner:" >&2
    echo "             sudo chown -R $TRITRACK_DEV_UID:$TRITRACK_DEV_GID $_tritrack_link_dir" >&2
    echo "         It most likely got that owner from a raw 'docker compose up'" >&2
    echo "         that did not source this file — Docker creates a missing" >&2
    echo "         bind-mount source as root." >&2
  fi
done
unset _tritrack_link_dir _tritrack_dir_uid
