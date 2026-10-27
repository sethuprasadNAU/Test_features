# gate-instrument: none - a wrapper imported by nightly_check.sh to run one command under a time limit with its output in a log file; it checks nothing itself and reaches no server.
"""Run one command, log everything it prints, and never let it run forever.

**Task 11.325.** `scripts/nightly_check.sh` runs about twenty commands one after
another and is meant to be left alone overnight. Two things make that unsafe with
a plain shell call, and this is the whole of what this file adds:

  * **A hang eats the night.** A build waiting on a prompt, a container that
    never becomes healthy, a download that stalls: the commands after it never
    run, and the report says nothing because the script is still waiting. macOS
    has no `timeout` command. So the limit is enforced here, on the command's
    whole process group (a Flutter build starts dozens of children, and killing
    only the first leaves the rest running into the next step).
  * **A step must not be able to ask a question.** Standard input is closed, so
    a command that wants a keypress fails at once instead of waiting for nobody.

Usage:  run_step.py LOG TIMEOUT_SECONDS -- COMMAND [ARG...]

The command's standard output and error go to LOG (appended, line-buffered by
the child's own behavior). Exit status: the command's own; **124** if the limit
killed it (the same number GNU `timeout` uses, so a reader recognizes it); 128+N
if it died of signal N. SIGTERM or SIGINT sent to this wrapper kills the command's
process group first, so stopping the night with Ctrl-C leaves nothing running.
"""

import os
import signal
import subprocess
import sys
import time


def kill_group(proc, sig):
    # The command is its own session leader (`start_new_session`), so its pid
    # is its process-group id — and stays one after the leader is reaped, as
    # long as anything it started is still in the group.
    try:
        os.killpg(proc.pid, sig)
    except (ProcessLookupError, PermissionError):
        pass


def main():
    if len(sys.argv) < 5 or sys.argv[3] != "--":
        sys.stderr.write(__doc__)
        return 2
    log_path, timeout = sys.argv[1], float(sys.argv[2])
    command = sys.argv[4:]

    with open(log_path, "ab", buffering=0) as log:
        started = time.time()
        try:
            proc = subprocess.Popen(
                command, stdin=subprocess.DEVNULL, stdout=log,
                stderr=subprocess.STDOUT, start_new_session=True)
        except OSError as err:
            log.write(f"could not start {command[0]!r}: {err}\n".encode())
            return 127

        def stop(signum, _frame):
            kill_group(proc, signal.SIGTERM)
            deadline = time.time() + 10
            while proc.poll() is None and time.time() < deadline:
                time.sleep(0.2)
            kill_group(proc, signal.SIGKILL)
            log.write(f"\nSTOPPED: signal {signum} reached the step runner.\n".encode())
            sys.exit(128 + signum)

        signal.signal(signal.SIGTERM, stop)
        signal.signal(signal.SIGINT, stop)

        try:
            status = proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            kill_group(proc, signal.SIGTERM)
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                kill_group(proc, signal.SIGKILL)
                proc.wait()
            limit = f"{timeout / 60:.0f} minute(s)" if timeout >= 120 else f"{timeout:.0f} s"
            log.write((f"\nTIMED OUT: no exit after {limit}, so the step runner "
                       f"killed it (it had run {time.time() - started:.0f} s).\n"
                       ).encode())
            return 124
        # Anything the command started and left behind would run into the next step.
        kill_group(proc, signal.SIGKILL)
        return status if status >= 0 else 128 - status


if __name__ == "__main__":
    sys.exit(main())
