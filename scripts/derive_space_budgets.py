#!/usr/bin/env python3
# gate-instrument: none - a measurement helper for the Flutter layout tests, run by hand when a screen's budget is being priced.
"""Find every size budget written for a child of a `Row` or a `Column`, and
say what could enforce it.

## Why this is in the repository

A Flutter `Column` hands every non-flex child **unbounded height**, and a `Row`
hands one unbounded **width**. So a size budget written for such a child is
arithmetic nobody consults: it reads as enforced, the tests pass, and nothing
says no until a widget grows. Task 11.149 found the class by writing one of
those bounds and measuring it do nothing; task 11.165 swept the height axis
(eleven budgets, one inoperative); task 11.166 swept the width axis.

**11.165's scan lived in a scratchpad and 11.166 had to go and find it.** It is
here so the next sweep — a third axis, or the same axis after a refactor — runs
the same instrument rather than inventing a fourth one that disagrees.

## What it does, and what it cannot see

Three passes, all over `lib/`:

* **A — a bound written at the call site.** Non-flex children of the parent
  whose own source carries a bound token (`maxHeight:`/`maxWidth:`,
  `ConstrainedBox`, `LimitedBox`, `FractionallySizedBox`, a `heightFor`/
  `widthFor` helper, a `* fraction`/`* share` multiply, `math.min`, a named
  `min*/max*Height`/`Width`).
* **B — a child whose own widget class carries budget vocabulary** anywhere in
  its source, comments included.
* **C — a budget written only as prose.** Passes A and B read code; comments
  are stripped before they run, so a rule stated in English is invisible to
  both. C reports comment blocks that mention both the axis and a bound.

**Every pass over-reports on purpose** — it is a list of places to look, never
a finding. `CLAUDE.md`: a grep tells you a token appears, not what it means.
Each hit still needs reading.

**Known blind spots, stated rather than discovered.** The flex test matches
`Expanded`/`Flexible`/`Spacer` at the head of a child, so a flex wrapper inside
a collection `if`, `for` or spread is *not* recognised — that direction is safe
(more candidates, not fewer) and it is why several hits below turn out to be
already-flexed. A budget expressed as a plain fixed size (`SizedBox(width: 52)`)
is not reported: a fixed size binds absolutely, so it is never inoperative —
what it can do instead is push the cost onto the other axis. And `Row`/`Column`
are not the only parents that hand a child an unbounded axis: a horizontally
scrolling `SingleChildScrollView` or `ListView`, `IntrinsicWidth`,
`UnconstrainedBox` and `OverflowBox` do too, and are not scanned.

Usage:  python3 scripts/derive_space_budgets.py [height|width|both]
"""
import os
import re
import sys

ROOT = 'lib'

AXES = {
    'height': {
        'parent': 'Column',
        'call_site': [
            (r'\bmaxHeight\b', 'maxHeight:'),
            (r'\bConstrainedBox\b', 'ConstrainedBox'),
            (r'\bLimitedBox\b', 'LimitedBox'),
            (r'\bFractionallySizedBox\b', 'FractionallySizedBox'),
            (r'\bheightFor\b', 'heightFor()'),
            (r'[A-Za-z_)\]]\s*\*\s*(?:_?[a-zA-Z]*[Ff]raction|_?[a-zA-Z]*[Ss]hare|0\.\d+)',
             'height * fraction'),
            (r'\bAspectRatio\b', 'AspectRatio'),
            (r'\bmath\.min\(', 'math.min()'),
            (r'\b(?:_?min|_?max)\w*Height\b', 'named height bound'),
        ],
        'in_class': (r'constraints\.maxHeight|\.size\.height|maxHeight\s*:|LimitedBox|'
                     r'FractionallySizedBox|heightFor|[Ff]raction|[Ss]hare\b|[Ff]loor\b|'
                     r'[Bb]udget|at most|no more than'),
        'prose': r'\bheight|\btall\b|vertical(?:ly)?|below the fold|band\b|\blines?\b',
    },
    'width': {
        'parent': 'Row',
        'call_site': [
            (r'\bmaxWidth\b', 'maxWidth:'),
            (r'\bConstrainedBox\b', 'ConstrainedBox'),
            (r'\bLimitedBox\b', 'LimitedBox'),
            (r'\bFractionallySizedBox\b', 'FractionallySizedBox'),
            (r'\bwidthFor\b', 'widthFor()'),
            (r'[A-Za-z_)\]]\s*\*\s*(?:_?[a-zA-Z]*[Ff]raction|_?[a-zA-Z]*[Ss]hare|0\.\d+)',
             'width * fraction'),
            (r'\bAspectRatio\b', 'AspectRatio'),
            (r'\bmath\.min\(', 'math.min()'),
            (r'\b(?:_?min|_?max)\w*Width\b', 'named width bound'),
        ],
        'in_class': (r'constraints\.maxWidth|\.size\.width|maxWidth\s*:|LimitedBox|'
                     r'FractionallySizedBox|widthFor|[Ff]raction|[Ss]hare\b|[Bb]udget|'
                     r'at most|no more than|fits|overflow'),
        'prose': (r'\bwidth|\bwide\b|right[- ]hand edge|right edge|off the right|'
                  r'horizontal(?:ly)?|narrow|ellipsis|one line|single line|\bwraps?\b|'
                  r'too long'),
    },
}

PROSE_BUDGET = re.compile(
    r'at most|no more than|budget|floor|ceiling|stays that|may not|must not|'
    r'never (?:grow|exceed|push)|share of|fraction of|does not go on|cannot push|'
    r'it stays', re.I)

FLEX = re.compile(r'^\s*(?:Expanded|Flexible|Spacer)\b')


def strip_noncode(src):
    """Blank comments and string contents, preserving every offset."""
    out = list(src)
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if c == '/' and i + 1 < n and src[i + 1] == '/':
            j = src.find('\n', i)
            j = n if j < 0 else j
            for k in range(i, j):
                out[k] = ' '
            i = j
        elif c == '/' and i + 1 < n and src[i + 1] == '*':
            j = src.find('*/', i + 2)
            j = n if j < 0 else j + 2
            for k in range(i, j):
                out[k] = ' '
            i = j
        elif c in '"\'':
            triple = src[i:i + 3] in ('"""', "'''")
            q = src[i:i + 3] if triple else c
            j = i + len(q)
            while j < n:
                if src[j] == '\\':
                    j += 2
                    continue
                if src[j:j + len(q)] == q:
                    j += len(q)
                    break
                j += 1
            for k in range(i + len(q), min(j - len(q), n)):
                out[k] = ' '
            i = j
        else:
            i += 1
    return ''.join(out)


def match(code, open_idx):
    """Index of the bracket closing the one at [open_idx], or -1."""
    pairs = {'(': ')', '[': ']', '{': '}'}
    stack = []
    for i in range(open_idx, len(code)):
        c = code[i]
        if c in '([{':
            stack.append(pairs[c])
        elif c in ')]}':
            if not stack or stack[-1] != c:
                return -1
            stack.pop()
            if not stack:
                return i
    return -1


def split_top(code, a, b):
    """code[a:b] split on top-level commas, as (start, end) pairs."""
    parts = []
    depth = 0
    start = a
    for i in range(a, b):
        c = code[i]
        if c in '([{':
            depth += 1
        elif c in ')]}':
            depth -= 1
        elif c == ',' and depth == 0:
            parts.append((start, i))
            start = i + 1
    if code[start:b].strip():
        parts.append((start, b))
    return parts


def dart_files():
    out = []
    for d, _, names in os.walk(ROOT):
        for n in sorted(names):
            if n.endswith('.dart'):
                out.append(os.path.join(d, n))
    return out


def children_of(code, parent):
    """Yield (file-relative start, end) for each direct child of each `parent`."""
    for m in re.finditer(r'\b%s\s*\(' % parent, code):
        op = code.index('(', m.start())
        cl = match(code, op)
        if cl < 0:
            continue
        cm = re.search(r'\bchildren\s*:\s*\[', code[op:cl])
        if not cm:
            yield None  # counted, but has no children list
            continue
        ci = op + cm.end() - 1
        cend = match(code, ci)
        if cend < 0:
            continue
        for span in split_top(code, ci + 1, cend):
            yield span


def sweep(axis):
    spec = AXES[axis]
    parent = spec['parent']
    files = dart_files()
    if not files:
        sys.exit('REFUSED: no .dart files under %s — an empty scan and an empty '
                 'subject are indistinguishable from in here.' % ROOT)

    print('=' * 72)
    print('%s axis — budgets written for a child of a `%s`' % (axis.upper(), parent))
    print('=' * 72)

    # ---- pass A: a bound written at the call site -----------------------
    parents = children = flexed = 0
    hits = []
    for path in files:
        src = open(path).read()
        code = strip_noncode(src)
        for m in re.finditer(r'\b%s\s*\(' % parent, code):
            del m
            parents += 1
        for span in children_of(code, parent):
            if span is None:
                continue
            a, b = span
            seg = code[a:b]
            if not seg.strip():
                continue
            children += 1
            s = seg.strip()
            if FLEX.match(s) or s.startswith('...'):
                flexed += 1
                continue
            labels = sorted({lab for pat, lab in spec['call_site'] if re.search(pat, seg)})
            if labels:
                hits.append((path, src[:a].count('\n') + 1,
                             s.split('(')[0].strip()[:40], labels))
    if parents == 0 or children == 0:
        sys.exit('REFUSED: found %d `%s`s and %d children — the scan derived '
                 'nothing, which is not the same as there being nothing.'
                 % (parents, parent, children))
    print('\nA. bound at the call site')
    print('   `%s`s: %d; direct children: %d; of those flex or spread: %d'
          % (parent, parents, children, flexed))
    print('   non-flex children carrying a bound token: %d' % len(hits))
    for path, line, head, labels in hits:
        print('   %s:%d  child=%r  %s' % (path, line, head, ','.join(labels)))

    # ---- pass B: the child's own class carries budget vocabulary ---------
    bound = re.compile(spec['in_class'])
    classes = {}
    for path in files:
        src = open(path).read()
        code = strip_noncode(src)
        for m in re.finditer(r'\bclass\s+(_?\w+)\b', code):
            b = code.find('{', m.end())
            if b < 0:
                continue
            e = match(code, b)
            if e < 0:
                continue
            toks = sorted(set(bound.findall(src[b:e])))
            if toks:
                classes[m.group(1)] = (path, src[:m.start()].count('\n') + 1, toks)
    found = []
    for path in files:
        src = open(path).read()
        code = strip_noncode(src)
        for span in children_of(code, parent):
            if span is None:
                continue
            a, b = span
            seg = code[a:b].strip()
            if not seg or FLEX.match(seg):
                continue
            for nm in re.findall(r'\b(_?[A-Z]\w+)\s*\(', seg):
                if nm in classes and nm not in (
                        'SizedBox', 'Padding', 'Text', 'Row', 'Column', 'Container'):
                    cp, cl, toks = classes[nm]
                    found.append((path, src[:a].count('\n') + 1, nm, cp, cl, toks))
                    break
    print('\nB. the child class carries budget vocabulary')
    print('   classes in %s expressing any: %d' % (ROOT, len(classes)))
    print('   of those, instantiated as a non-flex `%s` child: %d' % (parent, len(found)))
    for path, line, nm, cp, cl, toks in found:
        print('   %s:%d  <%s>  defined %s:%d  %s' % (path, line, nm, cp, cl, toks))

    # ---- pass C: a budget written only as prose -------------------------
    axis_re = re.compile(spec['prose'], re.I)
    prose = []
    comment_lines = 0
    for path in files:
        lines = open(path).read().split('\n')
        i = 0
        while i < len(lines):
            if re.match(r'\s*///?', lines[i]):
                j = i
                while j < len(lines) and re.match(r'\s*///?', lines[j]):
                    j += 1
                comment_lines += j - i
                block = '\n'.join(lines[i:j])
                if axis_re.search(block) and PROSE_BUDGET.search(block):
                    prose.append((path, i + 1, block.strip().split('\n')[0].strip()))
                i = j
            else:
                i += 1
    if comment_lines == 0:
        sys.exit('REFUSED: read no comments at all.')
    print('\nC. a budget written only as prose')
    print('   comment lines read: %d' % comment_lines)
    print('   blocks naming both this axis and a bound: %d' % len(prose))
    for path, line, head in prose:
        print('   %s:%d  %s' % (path, line, head[:78]))
    print()


if __name__ == '__main__':
    which = sys.argv[1] if len(sys.argv) > 1 else 'both'
    for axis in (['height', 'width'] if which == 'both' else [which]):
        if axis not in AXES:
            sys.exit('unknown axis %r — expected height, width or both' % axis)
        sweep(axis)
