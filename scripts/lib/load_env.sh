#!/usr/bin/env bash
# gate-instrument: none - a sourced helper, not a runnable instrument.
# The one place that knows how a script loads `.env` (task 11.40, carrying
# task 11.52).
#
# Source it from the repository root, after the usual `cd "$(dirname
# "${BASH_SOURCE[0]}")/.."`:
#
#   . scripts/lib/load_env.sh
#
# ## Why this exists
#
# Seven scripts carried a byte-identical eight-line block — `backup_db.sh`,
# `backup_restore_drill.sh`, `restore_db.sh`, `run_e2e_tests.sh`,
# `run_server_tests_docker.sh`, `verify_i1_source_identity.sh` and
# `verify_tls_termination.sh`. Seven copies of a setup step is seven places
# that have to change together, and the whole finding behind task 11.52 is
# that **converting a step does not remove the copies of it living elsewhere,
# and nothing looks for them.**
#
# The message matters as much as the sourcing. It is the sentence a person
# sees at the moment they are trying to run something and cannot, and it names
# the file they need and what to do with it. Having one copy of it means it
# can be improved once.
#
# Guarded by `test/documentation/setup_step_ownership_test.dart`, which fails
# if that sentence reappears anywhere outside this file.

if [ ! -f .env ]; then
  echo "Missing .env — copy .env.example to .env and fill it in first." >&2
  exit 1
fi

# Task 11.312 round 2: three of this file's callers (audit_retention_status.sh,
# project_destruction_status.sh, tombstone_retention_status.sh) are also run
# by the gate, which has already exported its own throwaway credentials
# (scripts/lib/shipped_compose_settings.py, task 11.310) into this process's
# environment before it gets here. Sourcing `.env` unconditionally clobbered
# them with the operator's real values — six of round one's VM reds. Compose
# itself ranks an exported variable above `.env` (that file's own docstring);
# mirror the same ranking here, once, so a variable already set in the
# environment wins over `.env` instead of the reverse. An operator running
# any of these scripts by hand, with nothing pre-exported, still gets `.env`
# exactly as before.
_load_env_preset_names=""
for _load_env_name in $(sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' .env); do
  if [ -n "${!_load_env_name+x}" ]; then
    _load_env_preset_names="$_load_env_preset_names $_load_env_name"
    printf -v "_load_env_preset_${_load_env_name}" '%s' "${!_load_env_name}"
  fi
done

# `set -a` so everything in `.env` is exported to the docker compose and
# `dart`/`flutter` child processes that actually need it, which is the only
# reason any of these scripts reads it.
set -a
# shellcheck disable=SC1091
source .env
set +a

for _load_env_name in $_load_env_preset_names; do
  _load_env_preset_var="_load_env_preset_${_load_env_name}"
  export "$_load_env_name=${!_load_env_preset_var}"
  unset "$_load_env_preset_var"
done
unset _load_env_preset_names _load_env_name _load_env_preset_var
