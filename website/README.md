# The TriTrack website

The public site and, eventually, the user guide. It is built from this private
repository and published to a public one, so the source stays private and the
site is still public.

- **Live site:** <https://dynamic-and-active-systems-lab.github.io/tritrack-site/>
- **Plan:** `CLAUDE_DOCS/WEBSITE_PLAN.md`
- **Reports go to:** `CLAUDE_DOCS/WEBSITE_COMMS.md`, never `TASK_COMMS.md`

Work in this directory belongs to the content stream and touches nothing
outside `website/`. See the rules at the top of the plan.

---

## The generator: Hugo, and what it costs

**Hugo 0.165.0**, pinned by version and SHA-256 in
`.github/workflows/website.yml`.

**Why.** It is one statically linked binary with no dependency tree at all.
This repository has no Node, no Ruby and no Python in it today, and the
alternative worth taking seriously — Eleventy — would have added roughly two
hundred npm packages to a project whose own rule is that every dependency is
pinned and reviewed. A pinned Hugo binary is one dependency with one checksum.
It has also been stable for a decade, which matters for a site nobody will
touch for months at a time: the failure mode to design against here is not
"hard to extend", it is "would not build when somebody came back to it".

**The drawback, stated so nobody re-litigates it in six months.** Hugo's
templates are Go templates, and Go template syntax is unlike anything else in
this repository — no Dart, no JavaScript, nothing transferable. Whoever next
changes a layout in `website/layouts/` will be learning `{{ range }}`,
`{{ with }}` and Hugo's page-variable names from scratch, and Hugo's own
documentation is organized around installing themes rather than writing four
layouts by hand, which is what this site does. **Editing content is Markdown
and costs nothing; editing layout has a real learning cost, paid by whoever
happens to be there.** That was judged the cheaper of the two costs, because
content changes weekly and layout changes almost never.

A second, smaller cost: Hugo publishes no macOS tarball, only a `.pkg`. On a
Mac, `brew install hugo` is the practical route.

### Working on it locally

```
brew install hugo                                   # once
hugo server --source website                        # preview at localhost:1313
hugo --source website --destination public          # one-off build
```

You do not need Hugo to run the drift check — that only needs Dart.

---

## The screenshots

**Every image on this site is generated. None is taken by hand, and none may
be** — a hand-taken screenshot cannot be regenerated, so it rots the moment a
screen changes and no check can tell.

One command rebuilds all of them:

```
integration_test/screenshots/regenerate.sh                 # every profile
integration_test/screenshots/regenerate.sh iphone-6.9      # one profile
integration_test/screenshots/regenerate.sh iphone-6.9 --accept
```

The harness lives in `integration_test/screenshots/` — the one place outside
`website/` this lane is allowed to touch — and **its own `README.md` there is
the reference**: what is faked and why, the pixel tolerance and exactly what
that tolerance costs, which screens it cannot photograph honestly today, and
what a full regeneration costs in minutes.

Three things worth knowing from here:

- **The images live in `website/static/screens/<profile>/`** and are committed.
  Hugo serves them from `/screens/<profile>/<name>.png`.
- **A regeneration never overwrites quietly.** It compares, names every screen
  that moved, writes a picture of the difference, and stops. `--accept` is a
  separate command somebody types after looking. *If a screen changes, its
  image changes* — that is the per-screen check the drift check below cannot
  be, but only because a person is made to look.
- **`map` and `position` may now be used.** They could not be until 2026-08-31:
  a simulator can only run a debug build, and both screens drew a debug
  overflow marker over a map credit that ran off the edge of a phone — a
  picture of something a shipped build never shows. Task 11.95 fixed it, all
  four images were regenerated and looked at, and the prohibition is lifted.
- **Two regenerations at once are now refused, rather than asked against.**
  Each empties its own staging directory when it starts, so a second run used
  to delete the first one's images between the capture and the review — and
  that failure reported as an ordinary changed screen rather than as a run that
  could not happen. `/w-06` closed both halves: the second run refuses to start
  while another holds `build/screenshots`, and a file that goes away underneath
  the review is exit 2 with a sentence. The harness README has the detail.

**Do not run it on every push.** It needs macOS, and GitHub Actions bills macOS
minutes at ten times the rate.

### Putting one on a page

```markdown
{{< shot "join-waiting" "What the person who asked to join sees next." >}}
{{< shot "map" "The map." "ipad-13" >}}
```

The profile defaults to `iphone-6.9`, because the guide is the phone. The
caption is required: an uncaptioned screenshot makes the reader guess what they
are looking at, and the reader who guesses wrong stops trusting the page.

**A name that has no image fails the build**, and says which file it looked
for. Hugo has no other check on an `<img>` source, so without this a screen
renamed in the harness would leave a broken image somebody notices in six
months — the same rot the `app` shortcode next door exists to prevent, one
level over. Watched failing on 2026-08-31.

Two or three shots that are one sequence go inside `{{< shots >}}` … `{{< /shots >}}`,
which lays them out side by side where the page is wide enough.

**One trap, and it is not obvious.** The unconfigured screens (`projects`,
`project-members`, `sync-status`, `record`, `record-truth`,
`truth-point-panel`, `truth-point-edit`, `compass`, `app-info`,
`bearing-selected`, `bearing-dragged`, …) are of a device with
no server, and the `joined-`/`owner-`/`join-`/`sync-` ones are of a device that
has joined a project. **A device with no server has no sync bar and one with a
server has one**, so putting the two sets on one page shows the reader two
different apps: they cannot tell that the difference is configuration, and they
read it as an inconsistency. Keep a page to one set, and if a page must explain
the unconfigured case, say so in a sentence.

### The video (`/w-35`)

One short clip, `static/videos/take-on-map.mp4`, on *Recording a bearing*:

```markdown
{{< video "take-on-map" "What the clip shows." >}}
```

It is made the way the pictures are, never by hand:
`integration_test/screenshots/record_video.sh` drives the same Take on map
sweep, records the simulator, plays it four times faster (Michael's choice,
2026-10-01) and writes a muted 60 fps MP4 to `Claude outputs/`. **When the
Take on map screen changes, run it again and copy the file over this one**; a
clip nobody regenerates rots like a hand-taken screenshot. The shortcode shows
it muted, looping, with controls and no autoplay; its poster is the
`take-on-map` screenshot (the clip begins on that screen), and the poster is
what a printed page shows. A missing video or poster fails the build.

---

## The diagrams

**Michael asked for flow/block diagrams (2026-09-18): "those pages are extremely
wordy."** Three pages describe a shape — a dated link between two things, a
request-and-answer with a waiting gap, a small state machine — in sentences, and
`/w-21` drew each one.

**The same rule as the screenshots applies, for the same reason.** Every image on
this site is generated, none is taken by hand, and none may be — a hand-drawn
diagram is wrong the day the thing it shows changes, silently, and nothing checks
it. So a diagram's source is text committed to the repo
(`website/diagrams/*.dot`), reviewable as an ordinary diff, and the SVG is
rendered from it rather than drawn.

**The mechanism is Graphviz (`dot`), not Mermaid.** This repository has no Node
today, and the alternative — Mermaid, rendered client-side — would mean shipping
a JavaScript library to every reader and rendering the diagram in their browser
rather than at build time, on a site that otherwise ships no JavaScript at all.
`dot` is one pinned-by-brew binary that takes plain text and produces
deterministic SVG, which is the same shape of dependency Hugo itself is (see
"The generator" above) — one binary, one thing to have installed, nothing to
review in a lockfile.

**The renderer is `website/tools/render_diagrams.sh`.** It runs `dot -Tsvg` over
every `website/diagrams/*.dot` source and writes the result to
`website/static/diagrams/`. Unlike the screenshots, that output is **not
committed** — see `website/.gitignore` — because a diagram is cheap to
regenerate (one `dot` call, under a second) where a screenshot is not (a macOS
simulator boot). Run it before `hugo build` or `hugo server`; the `diagram`
shortcode refuses to build a page that references one that has not been
rendered yet, the same way the `shot` shortcode refuses a missing screenshot.

```
brew install graphviz                       # once
website/tools/render_diagrams.sh
hugo server --source website                # now the diagrams resolve too
```

**Both themes, without a second copy of the palette.** The shortcode inlines the
rendered SVG directly into the page rather than loading it as an `<img>`, so its
shapes can be styled by this site's own `style.css` custom properties — the same
`--fg`, `--muted` and `--link` tokens everything else on the site uses — instead
of the diagram carrying its own light/dark colors. See the `.diagram-inner`
rules in `style.css`; a `.dot` source marks a node `class="highlight"`,
`"good"`, `"bad"` or `"wait"` to pick up an accent color, but the words on the
node are always what carries the meaning — a diagram is not exempt from the rule
that color never stands alone on this site (see `sync.md`'s "roughly one man in
twelve cannot tell that amber from that red").

**Diagrams never go through the screenshot harness or its accept gate.** They
are not a capture of the app, they have no device profile, and nothing about
"did this change since the last accepted baseline" applies to a picture that is
regenerated identically from unchanged text every time.

**Two diagrams were considered and rejected, on purpose, so nobody adds them
later:** recording a bearing (a straight line the screenshots already walk — a
flowchart of "tap this, then that" is decoration) and roles and permissions
(`CLAUDE_DOCS/PERMISSIONS_MATRIX.md` is a table; a diagram would be worse than a
table, not better).

---

## The theory page's figures

**The pictures on *How the estimate is calculated* are drawn by
`website/tools/theory_figures.dart` from the app's own numbers** (task
`/w-36`). Task 11.336 committed those numbers in
`test/localization/ellipse_coverage_data/`: six worked fixes with the solver's
every step, and the coverage table. The script reads them, and for what they
do not hold (a likelihood surface, a simulated fix, a fix drawn to show
geometry) it computes it with a copy of the app's method that **must first
reproduce the app**: every worked example's path, estimate, κ, covariance and
ellipses, and all 36,000 simulated fixes to the count. If it cannot, it draws
nothing and says which number disagreed.

```
dart website/tools/theory_figures.dart           # draw into website/static/figures/
dart website/tools/theory_figures.dart --check   # fail if a committed figure differs
```

- **The figures are committed**, like the screenshots (the method check takes
  under a second, but a figure change should be looked at, not regenerated
  silently in a build). `--check` runs in `website.yml`.
- **One color per quantity, everywhere on the page**: a bearing blue, the
  estimate red, the spread κ magenta, the ellipse green, likelihood gray. The
  colors are CSS variables in `static/style.css` (*Theory figures*), with a
  light and a dark value each, checked for colorblind separation and for
  4.5 : 1 as text. The SVGs carry classes, not colors. In the equations,
  `\textcolor{#306afc}{…}` and its siblings are keys that the same stylesheet
  swaps for the theme's color; use exactly those five hex values.
- **No script reaches a reader.** Animations are CSS keyframes inside the SVG.
  `{{< anim >}}` places one with its still version (`<name>-steps.svg`), which
  stands in for print, the PDF, reduced motion, and a reader who ticks *Show
  still pictures instead*. `{{< fig >}}` places a still figure. Both need
  `name`, `alt` (what the picture shows) and `caption` (what to notice).
- **Not checked by the data:** the two lower branches of the κ approximation
  (mean cosine under 0.85). No example reaches them; the script says so beside
  the function.
- **Captions quote numbers** (11 of 24, 3.9 times larger, …) that come from the
  drawing. If the data changes, re-read them.
- **Two pages, one reference list** (`/w-37`). *How the estimate is
  calculated* explains the method in pictures and how far to trust the
  ellipse; *The mathematics of the estimate* holds the full equations, the
  cautions' thresholds, the check against Lenth's example and where TriTrack
  differs. Each links to the other in its opening lines; publish them
  together.
- **Citations are numbered** in the order each source is first cited, reading
  the first page and then the mathematics page. In the text a citation is a
  link, `[[2]](#ref-2)`. Both pages end with `{{< theory-references >}}`,
  which renders `data/theory_references.toml` with each entry's anchor (raw
  HTML is off, so the anchor needs a shortcode), so a number means the same
  source on both pages and there is one copy to correct. A new source cited
  earlier than an existing one renumbers everything after it.

---

## The built-site check (`/w-35`)

`website/tools/check_built_site.dart` reads the HTML Hugo wrote and fails on
two things nothing else catches:

- **an internal link that resolves to nothing**: a page, a picture, a video,
  or a `#heading` the target page does not have. Root-relative links carry the
  site's `/tritrack-site/` prefix, which it reads from `hugo.toml`.
- **TeX printed as text** outside a formula (`\hat`, `$$`, `^{`), which is what
  a formula the passthrough missed looks like to a reader.

```
hugo --source website --destination /tmp/site
dart website/tools/check_built_site.dart /tmp/site
```

Exit 0 clean, 1 something wrong (each finding printed), 2 could not run,
including a directory with no internal links at all, so it cannot pass having
looked at nothing. `selftest.sh` watches both checks go red on the
`fixtures/built_site_*` copies, and `website.yml` runs it on the built site
before publishing.

---

## The drift check

`website/tools/check_app_quotes.dart`, run in CI by
`.github/workflows/website.yml` on every push that touches `website/`, **`lib/`
or `packages/`**. The app half is the important one: drift is nearly always
caused by the app's wording changing, not the site's.

**What counts as the app is `lib/` plus every `packages/*/lib/`**, worked out
at run time rather than listed, so a package added later is covered by whoever
adds it. `/w-06` widened it after `/w-03` found the hole the hard way: the role
names and the five record-type buttons on the record screen are `enum` labels
in `packages/tritrack_sync/lib/`, so the guide's most-read table had to be
written as unmarked prose.

### How to quote the app

Write the string through the shortcode:

```markdown
Open More and choose {{< app "Join a project" >}}.
```

That renders as a bold, tinted label, and the exact string is verified against
the app's own source on every build. **Any string the app displays that you want on a page
goes through this shortcode.** It is the only quoting mechanism the site has.

To make forgetting impossible rather than merely discouraged, the check also
refuses two things outright in `website/content/`:

- **Double quotation marks in prose.** Quoting the app by typing `"..."` would
  be invisible to the check, so typing it is an error that names the
  shortcode. Quotes inside code fences, inline code, link destinations,
  front matter and HTML comments are left alone.
- **`**bold**` in prose.** Bold is what a UI label looks like when somebody
  forgot the shortcode, and the shortcode already renders bold. Use
  `_italics_` for emphasis.

Both have one escape hatch, `website/quote-waivers.txt`: the exact text, a
tab, and a written reason. It is deliberately awkward — a waiver with no
reason will not load, a waiver written twice is a hard error rather than a
last-write-wins, and a waiver that stops matching anything fails the build so
the list cannot rot.

### And one thing the shortcode itself refuses: a database value

**A quote that cannot go red is not evidence, so it is refused rather than
accepted** (`/w-08`). The check knows which strings are `enum` storage values —
the exact text a Dart `enum` writes into a database column — and no
`{{< app "..." >}}` may be one of them.

The case that produced the rule: this guide had
`{{< app "owner" >}}`, `{{< app "contributor" >}}` and `{{< app "viewer" >}}`,
which are not wording from any screen at all — they are what `ProjectRole`
stores in SQLite. **The schema pins them, so no change to any screen could ever
have turned those three quotes red**, and task 11.99 rewrote both screens the
page describes while all three stayed green. There is no waiver: if a screen
really does print a stored value, that is the defect
`test/documentation/role_vocabulary_test.dart` exists to fail on, and the app
is what has to change.

**The labels beside them are untouched.** `GroundTruthKind` is
`animalOnly('animal_only', 'Animal only')`, and `Animal only` is exactly what
the record screen shows a person, so it may be quoted. The check reads the
enum's constructor to find which argument is the stored one rather than
assuming it is the first, so an enum written the other way round is handled
too.

### Running it

```
dart pub get --directory website/tools     # once
dart run website/tools/check_app_quotes.dart
website/tools/selftest.sh                  # is the check itself still able to fail?
```

Exit codes are the contract: **0** no drift, **1** drift or a rule violation,
**2** the check could not run. Two is not a pass, and CI treats it as failure.

`selftest.sh` drives the checker at fixtures under `website/tools/fixtures/`
and asserts the exit code for eighteen cases: six must go red on a violation
and seven must refuse to run rather than report success. It was watched failing
on 2026-08-31, against a real modified copy of `lib/`, with the checker's own
comparison stubbed out, and — `/w-06`'s four new cases — with the
`packages/*/lib` discovery stubbed out, which turns two of them red.

### What the drift check does not catch

A green run means every quoted string still exists somewhere in `lib/`. It
does **not** mean any of the following, and none of them should be inferred
from it:

1. **That the string is still reachable.** A label on a screen no longer
   routed to, or behind a feature flag that is now off, is still a string in
   `lib/` and still passes. The check knows what the app contains, not what
   it shows.
2. **That the string is still on the screen the page says it is on.** The
   search is across all of `lib/`, not per file. During this task the check
   correctly stayed green when one occurrence of a label was renamed, because
   the same words were still a tooltip elsewhere — which was the right answer
   to the question it asks, and the wrong answer to "does that screen still
   say this".

   **`/w-16` found the sharper version of this, where both strings are real
   and only the sentence around them is wrong.** `recording-a-bearing.md` said
   *"+ Quick-add tag at the bottom of the wheel"*. The control at the bottom of
   the wheel reads **＋ Add new tag**; *+ Quick-add tag* is a **different
   button, on the screen a project with no tags at all shows**. Both strings
   are in `lib/`, so the quote is still true and the claim built around it is
   false — the check verified the four words and never looked at the six that
   place them.

   **No instrument was built, and what one would need is worth writing down
   rather than guessing at later.** The check would have to know, for each
   quote, **which screen the page says it is on** and **which screens in `lib/`
   draw it** — so: a way for a page to name a screen (a parameter on the
   shortcode, or a per-page front-matter field), and a way to map a string
   literal in `lib/` back to a screen, which means attributing every literal to
   the widget that builds it rather than to the file it sits in. The second
   half is the expensive one and it is where this would most likely go wrong:
   a shared widget, a constant in a `_strings` file, or a label passed in as an
   argument each belong to whatever builds them, and the file they are written
   in does not know. **A version that guessed by filename would be a
   hand-maintained list of screen names wearing a derivation's clothes**, and
   this project's own rule about those applies. Until somebody needs it enough
   to do the attribution properly, this stays a hole a person closes by reading
   the page beside the app.
3. **Prose that describes the interface without quoting it. This is the
   biggest hole in the check and it has now been measured.** A sentence that
   *describes* a control — where it is, what shape it is, who it is for —
   quotes nothing, so nothing verifies it, and it goes on being served after
   the control it describes has been deleted.

   Not a hypothetical. Task 11.99 changed two screens, and `/w-08` had to
   correct eight sentences afterwards. **Six of the eight were this shape:**
   _the cloud icon at the top right_, _the icons on the row_, _the first icon
   on a project's row_, _the two-people icon on your project's row_, and a
   whole paragraph explaining that the members screen was for owners only. The
   app had no cloud icon, no icons on that row, and no owner-only members
   screen. **Every one of those sentences passed the drift check**, on every
   run, for as long as it was wrong.

   **So: green means the quoted labels survive. It has never meant the guide is
   current, and after 11.99 that is a measured claim rather than a caution.**
   The only thing that catches this class today is somebody re-reading the page
   beside the app — and the screenshots, which is why a regeneration makes a
   person look.

   No check is proposed for it. A rule against writing *the cloud icon at the
   top right* would be a rule against describing the interface, which is most
   of what a user guide is; and a checker that understood the sentence would
   have to understand the app. **What is proposed instead is that whoever
   changes user-visible copy says so in their comms entry** — which is already
   an obligation on both lanes, and is how these eight were found.
4. **Server-side or platform copy.** `lib/` and `packages/*/lib/` are
   searched; `packages/` was added by `/w-06` and this entry no longer lists it
   as a hole. Strings that live in `server/`, `ios/`, `android/`, `macos/` or in
   an operating-system dialog are still invisible to it. `server/` is out
   deliberately rather than by omission — this project's standing rule is that
   no server prose is ever shown to a person, so a quoted string that only
   `server/` contains would be a defect in the app rather than a gap here.
5. **Screenshots.** An image showing wording the app no longer uses passes
   untouched. That is `/w-02`'s problem, not this one's.
6. **Ordering and navigation.** "Open More, then Sync" can be entirely wrong
   about the path while both words still exist in `lib/`.
7. **Anything outside `website/content/`.** Copy written into a layout, a
   shortcode, or `website/static/` is not scanned.

8. **A short quoted word passes on any longer string that contains it.** The
   match is containment, deliberately — the guide often quotes one sentence of
   a two-sentence message. The cost is that a one-word quote is checked very
   weakly: `/w-06` marked the three role names the members screen shows in
   lower case, and each of them is satisfied by an unrelated sentence
   elsewhere in `lib/` such as the one telling a viewer to ask an owner to
   change their role. **The marking is honest and the check is real; it is just
   not evidence that the dropdown still spells them that way.** Of the eight
   labels `/w-06` marked, exactly two — the record screen's first and fourth
   buttons — could only be found in `packages/`, and those two are the ones
   whose quotes would go red on a rename.

9. **Copy the guide has never mentioned at all.** Points 1–8 are about a quote
   or a sentence going stale. This one is the opposite and `/w-10` measured it:
   between 2026-09-01 and 2026-09-03 the app changed three sign-in strings,
   split its refused-character message in two and rewrote a name rule into an
   allowlist — **and the drift check stayed green through all of it, correctly,
   because `website/` quoted none of them.** The guide had no sentence about
   signing in and no sentence about what a name may contain, so there was
   nothing to drift.

   **A check that verifies the strings a page quotes can never notice a string
   the page ought to quote and does not.** No check is proposed, for the same
   reason as point 3 — the only thing that works is the standing obligation on
   both lanes to say in a comms entry when user-visible copy changes, and it is
   what caught these three: every one arrived through `WEBSITE_PLAN.md`'s
   *user-visible copy the guide must not quote from memory* section rather than
   through a red build.

Points 1, 3, 6, 8 and 9 are the ones most likely to bite, and **point 3 is the
one that has actually bitten.** **A drift check that verified quoted labels is not a
check that the guide is correct**, and the guide should not be written as though
it were.
