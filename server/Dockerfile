# Built from the repository root (see docker-compose.yml's `context: .`) —
# the build needs both server/ and ../packages/tritrack_sync, since the
# server depends on that package by relative path, not a pub.dev version.

FROM dart:stable AS build
WORKDIR /app
# Task 11.316. Only the dependency files are copied before `dart pub get` —
# the server's pubspec.yaml and pubspec.lock, and tritrack_sync's pubspec.yaml
# (the server depends on it by path) — so the downloaded packages are a cached
# layer that an edit to source does not invalidate. Copying the source first
# meant every server edit re-fetched every package from pub.dev, and a build
# with no network could not happen at all. tritrack_sync's own pubspec.lock is
# deliberately not copied: .gitignore excludes it (packages/* do not commit a
# lockfile), so it exists only on machines that happen to have run `pub get`
# there — naming it here built on the Mac and failed on the VM's clean
# checkout. The server's lockfile pins every version, the path package's too.
COPY packages/tritrack_sync/pubspec.yaml packages/tritrack_sync/
COPY server/pubspec.yaml server/pubspec.lock server/
WORKDIR /app/server
RUN dart pub get
# The source arrives now. Packages are already in the cache from the step
# above, so this second `pub get` is offline: it only rewrites the package
# map next to the real source, and cannot reach pub.dev even by accident.
WORKDIR /app
COPY packages/tritrack_sync packages/tritrack_sync
COPY server server
WORKDIR /app/server
RUN dart pub get --offline
# AOT-compiling to a standalone executable means the runtime image below
# needs no Dart SDK at all — smaller image, smaller attack surface.
RUN dart compile exe bin/server.dart -o /app/server/bin/server
# Task 11.79. §4.7's retention sweep and the measurement on it, compiled for
# the same reason the server is: the runtime stage below has no Dart SDK and no
# source, so the command server/README.md used to give — `dart run
# bin/purge_audit_logs.dart` — could not run in this image at all. It worked on
# a developer's laptop and nowhere the operator would ever be, which is why the
# retention windows in the documentation described an intention rather than
# what was on disk.
RUN dart compile exe bin/audit_retention.dart -o /app/server/bin/audit-retention
# Task 11.290. The sweep that destroys projects on the date their owner
# scheduled, compiled beside the audit sweep for the same reason it is: the
# runtime stage has no Dart SDK, and a deletion that only a developer's
# laptop can carry out is a promise the deployed server cannot keep.
RUN dart compile exe bin/project_destruction.dart -o /app/server/bin/project-destruction
# Task 11.291. The tombstone sweep — task 10.11's purge, which was written,
# tested and called from nowhere for seven weeks — compiled beside the other
# two for the same reason: the runtime stage has no Dart SDK, and a purge that
# only a developer's laptop can run is a retention window the deployed server
# does not apply.
RUN dart compile exe bin/tombstone_retention.dart -o /app/server/bin/tombstone-retention

FROM debian:bookworm-slim
# Task 11.308. What commit this image was built from, asked of the *running
# container* rather than assumed from the working tree that happened to be
# checked out when somebody typed `docker compose up --build` — the working
# tree can have moved on since, and after a failed build it is the ONLY
# record, because the container that failed to build never starts.
# scripts/server_up.sh passes this via `--build-arg`, computed with
# `git rev-parse` and suffixed `-dirty` when the tree that was actually built
# had uncommitted changes; `unknown` is what an image built outside that
# script (a bare `docker build`, or `docker-compose.yml`'s other services that
# share this Dockerfile) gets, and the label says so rather than guessing.
ARG GIT_COMMIT=unknown
LABEL org.opencontainers.image.revision="${GIT_COMMIT}"
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /app/server/bin/server /app/bin/server
COPY --from=build /app/server/bin/audit-retention /app/bin/tritrack-audit-retention
COPY --from=build /app/server/bin/project-destruction /app/bin/tritrack-project-destruction
COPY --from=build /app/server/bin/tombstone-retention /app/bin/tritrack-tombstone-retention

# Task 11.129. Where the durable degradation record lives — the one record that
# has to survive the database being gone, because the audit log cannot. The
# directory is created here rather than left to the server's own
# `createSync(recursive: true)` so that a deployment which forgets to mount a
# volume still gets a writable path (inside the container layer, lost on
# recreate) instead of no record at all. docker-compose.yml mounts a NAMED
# VOLUME over it — named, not a bind mount, because a bind mount passes host
# ownership straight through on Linux and that is what made task 11.70's backup
# unwritable and task 11.125's two status commands disagree.
RUN mkdir -p /var/lib/tritrack

EXPOSE 8080
ENTRYPOINT ["/app/bin/server"]
