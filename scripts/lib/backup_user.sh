#!/usr/bin/env sh
# gate-instrument: none - a sourced helper, not a runnable instrument.
# The one place that knows which user the BACKUP container runs as
# (task 11.70).
#
# Source it from the repository root, the same way as `load_env.sh`:
#
#   . scripts/lib/backup_user.sh
#
# ## What it is for
#
# `server/backup/Dockerfile` ends `USER postgres` — uid 70 — deliberately: the
# container mounts the backup directory and, during a restore, briefly the
# private key, and neither needs root. That choice is right and this file does
# not change it.
#
# What it changes is that uid 70 is a *stranger on the host*. The backup
# directory and the signing key belong to the operator, and
# `server/README.md` tells them to create both as themselves — the signing key
# mode 600, because it is the key that decides which archives a restore will
# trust. On Linux a bind mount passes host ownership straight through, so a
# container running as uid 70 can neither create the archive in that directory
# nor read that key.
#
# On macOS with Docker Desktop none of this happens: its file-sharing layer
# presents host files to whatever user the container runs as. That is why the
# documented procedure worked on one machine for months and had never been run
# on a Linux server.
#
# So `docker-compose.yml`'s `backup` service declares
# `user: "${TRITRACK_BACKUP_UID:-70}:${TRITRACK_BACKUP_GID:-70}"`, and this
# file is what sets those two variables to the invoking user. The archive and
# the key stay owned by the operator; nothing is chowned to a shared internal
# account; and the fix travels with the repository rather than depending on a
# step somebody performs correctly.
#
# ## Why the fallback is uid 70 and not the invoking user
#
# Compose has no way to spell "the user who typed this". A default of `0:0`
# would work and would leave every archive on the host owned by root and mode
# 600 — an operator who cannot read their own backups. A default of 70:70 is
# exactly what the image does today, so a raw `docker compose run backup`
# behaves as its Dockerfile says, and `server/backup/backup.sh` now refuses
# **before dumping anything** with a message naming the ownership mismatch
# rather than `pg_dump | age pipeline failed`.
#
# ## Its sibling
#
# `scripts/lib/host_user.sh` does the same job for the *server* container in
# the development and end-to-end stacks, where the mismatch runs the other way
# (that container runs as root and writes a mode-600 sign-in link the
# developer then cannot read). Kept separate rather than merged: host_user.sh
# also creates the two magic-link directories, which have no business being
# created on a machine whose only job is taking backups.

export TRITRACK_BACKUP_UID="${TRITRACK_BACKUP_UID:-$(id -u)}"
export TRITRACK_BACKUP_GID="${TRITRACK_BACKUP_GID:-$(id -g)}"
