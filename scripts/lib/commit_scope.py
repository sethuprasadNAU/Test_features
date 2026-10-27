# gate-instrument: none - a reader imported by pre_commit_suite.sh to work out which files a `git commit` command will take; it runs nothing and reaches no server.
"""Say which checks a `git commit` command needs, by asking what it will commit.

**Task 11.325 item 3.** `scripts/pre_commit_suite.sh` used to ask
`git diff --cached --name-only -- lib/` whether a commit touched `lib/`. That
is the right question for `git commit` and the wrong one for
`git commit -- <path>`, the form `CLAUDE.md` requires: a commit that names its
paths takes the *working-tree* content of those paths and ignores the index, so
an edit that was never staged is committed without the index ever showing it.
Reproduced 2026-10-01 (task 11.318): a stale hash line in a generated file was
committed to a throwaway branch with no refusal, because the check never ran.

So this reads the command, works out which of the three shapes it is, and asks
git what that shape takes:

  index     `git commit` / `git commit --amend`: what is staged.
  all       `git commit -a`: every tracked change, staged or not.
  pathspec  `git commit -- a b` or `git commit a b`: the working-tree change in
            those paths **and** whatever is staged. The staged half is
            deliberately kept even though git would ignore it, so that this
            stays a superset of what the commit takes — a check that runs once
            too often costs seconds, one that does not run costs a stale file
            on main.
  unparsed  The command could not be read (unbalanced quotes, say). Treated as
            "everything changed", for the same reason.

Usage: commit_scope.py REPO_ROOT < command-text

Prints `key=value` lines: `mode`, `files` (a count), `generated_check` (yes if
any file under `lib/` is taken), `analyze` (yes if any Dart source or package
file is taken), and one `worktree_generated=<path>` per taken generated file
whose working-tree content, not its staged content, is what will be committed.
Exits 2 and prints nothing useful when git itself fails: the caller must treat
that as a refusal, never as "nothing to check".
"""

import re
import shlex
import subprocess
import sys

# Options that consume the next token as their value. `-m"msg"` and `--message=msg`
# carry the value inside the same token and need no help.
SHORT_WITH_ARG = set("mFCct")
LONG_WITH_ARG = {
    "--message", "--file", "--reuse-message", "--reedit-message", "--template",
    "--author", "--date", "--fixup", "--squash", "--cleanup", "--trailer",
    "--pathspec-from-file",
}
COMMIT_RE = re.compile(
    r"(^|[^[:alnum:]_.-])git([ \t]+-[^ \t]+([ \t]+[^-\s][^ \t]*)?)*[ \t]+commit([ \t]|$)"
    .replace("[:alnum:]", "A-Za-z0-9"))
DART_PATHS = ("pubspec.yaml", "pubspec.lock", "analysis_options.yaml")
GENERATED_SUFFIXES = (".g.dart", ".freezed.dart")


def logical_lines(text):
    """Split on newlines that are outside quotes, so one command per piece."""
    lines, current, quote, escaped = [], [], None, False
    for ch in text:
        if escaped:
            current.append(ch)
            escaped = False
            continue
        if ch == "\\" and quote != "'":
            current.append(ch)
            escaped = True
            continue
        if quote:
            if ch == quote:
                quote = None
        elif ch in "'\"":
            quote = ch
        elif ch == "\n":
            lines.append("".join(current))
            current = []
            continue
        current.append(ch)
    lines.append("".join(current))
    return lines


def parse(command):
    """Return (mode, paths) for the first `git commit` in the command."""
    for line in logical_lines(command):
        match = COMMIT_RE.search(line)
        if not match:
            continue
        tail = line[match.start():]
        try:
            lexer = shlex.shlex(tail, posix=True, punctuation_chars=True)
            lexer.whitespace_split = True
            tokens = list(lexer)
        except ValueError:
            return "unparsed", []
        # From the word `commit` up to the first shell operator.
        try:
            start = tokens.index("commit") + 1
        except ValueError:
            return "unparsed", []
        paths, take_all, after_dashes, skip_next = [], False, False, False
        for token in tokens[start:]:
            if not after_dashes and token and set(token) <= set("&|;()<>"):
                break
            if skip_next:
                skip_next = False
                continue
            if after_dashes:
                paths.append(token)
            elif token == "--":
                after_dashes = True
            elif token.startswith("--"):
                if token in LONG_WITH_ARG:
                    skip_next = True
                elif token == "--all":
                    take_all = True
            elif token.startswith("-") and len(token) > 1:
                cluster = token[1:]
                if "a" in cluster.split("m")[0].split("F")[0]:
                    take_all = True
                for index, letter in enumerate(cluster):
                    if letter in SHORT_WITH_ARG:
                        skip_next = index == len(cluster) - 1
                        break
            else:
                paths.append(token)
        if paths:
            return "pathspec", paths
        return ("all" if take_all else "index"), []
    return "unparsed", []


def git_lines(repo_root, *args):
    result = subprocess.run(
        ["git", "-C", repo_root, *args], capture_output=True, text=True)
    if result.returncode != 0:
        sys.stderr.write(f"commit_scope: git {' '.join(args)} failed: "
                         f"{result.stderr.strip()}\n")
        sys.exit(2)
    return [line for line in result.stdout.splitlines() if line]


def scope(repo_root, command):
    mode, paths = parse(command)
    staged = git_lines(repo_root, "diff", "--cached", "--name-only")
    if mode == "index":
        taken, worktree = set(staged), set()
    elif mode == "pathspec":
        named = git_lines(repo_root, "diff", "--name-only", "HEAD", "--", *paths)
        taken, worktree = set(staged) | set(named), set(named)
    else:  # all, unparsed
        everything = git_lines(repo_root, "diff", "--name-only", "HEAD")
        taken, worktree = set(staged) | set(everything), set(everything)
    return {
        "mode": mode,
        "files": len(taken),
        "generated_check": any(p.startswith("lib/") for p in taken),
        "analyze": any(p.endswith(".dart") or p in DART_PATHS
                       or p.endswith(("/pubspec.yaml", "/analysis_options.yaml"))
                       for p in taken),
        "worktree_generated": sorted(
            p for p in worktree if p.endswith(GENERATED_SUFFIXES)),
    }


def main():
    if len(sys.argv) != 2:
        sys.stderr.write("usage: commit_scope.py REPO_ROOT < command\n")
        return 2
    result = scope(sys.argv[1], sys.stdin.read())
    print(f"mode={result['mode']}")
    print(f"files={result['files']}")
    print(f"generated_check={'yes' if result['generated_check'] else 'no'}")
    print(f"analyze={'yes' if result['analyze'] else 'no'}")
    for path in result["worktree_generated"]:
        print(f"worktree_generated={path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
