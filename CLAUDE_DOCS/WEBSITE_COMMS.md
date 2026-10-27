# Website and user-guide comms

**The content stream's comms file.** Same protocol as `TASK_COMMS.md`, separate file so the
two streams never write to the same document. Read `CLAUDE_DOCS/WEBSITE_PLAN.md` first —
it carries the rules that keep this lane disjoint from the code lane.

## How to use it

**Every content task writes an entry, including a task with nothing to ask.** A missing
entry is indistinguishable from a task that had nothing to say.

**The content session appends** to "Open — waiting on the planning session". It never edits
an existing entry, never deletes one, and never writes in "Resolved" — that half belongs to
the planning session. Reading "Resolved" for context is fine.

**A content task never edits `DEVELOPMENT_PLAN.md` and never fixes the app.** An app defect
found while writing goes under **"Findings for the code stream"** in the entry, and the
planning session turns it into a numbered task.

**The planning session** moves an entry to "Resolved" once it has acted, adding what it did
and the date.

---

## Open — waiting on the planning session

### Task `/w-35` — resolved 2026-10-11 by the planning session — `Done`

Findings 1, 3 and 4 are task 11.340; finding 2 went to Michael (battery and data), also 11.340, with a copy list for the next
content task. The judgment calls (no merge tool yet; backups kept on the same machine; the compass caption) stand. Michael reads the
PDF and pushes.

### Task `/w-35` — 2026-10-10 — commit `0df30ea` — Done

**The guide now has a page on setting up a project, the Take on map video, a page-by-page pass for Michael's printed-guide
comments, and two new checks on the built site. `check_app_quotes` is green: all 9 red lines (8 from task 11.324, 1 from
11.339) are fixed.** Nothing is live until Michael pushes (`website.yml` publishes on a push that changes `website/**`).

- **Item 1, the video.** The approved 4× clip is committed as `website/static/videos/take-on-map.mp4` (1.39 MB) and sits
  on *Recording a bearing* under the two Take on map pictures. A new `video` shortcode shows it muted, looping, with
  controls and no autoplay; its poster is the `take-on-map` picture, which also stands in for it on paper. A missing
  video or poster fails the build. `record_video.sh`'s comment and the website README say how to replace it.
- **Item 2:** nothing to do; the theory pages' links are checked by item 3's check (all resolve).
- **Item 3, two checks on the built site** (`website/tools/check_built_site.dart`): every internal link resolves,
  including `#heading` anchors, and no TeX appears as text outside a formula. **Watched red first** on four broken
  copies in `website/tools/fixtures/built_site_*` (a missing page, a missing heading, raw `\hat{x}`, and a site with no
  internal links, which is exit 2 rather than a pass); those cases now run in `selftest.sh` (28 cases, PASS). The real
  site: 18 pages, 316 internal links (77 to a heading), none broken, no raw TeX, in both the plain and the `--minify` build; deleting one page from a copy turned it red with 11 broken links. `website.yml` runs it on the built site before publishing.
- **Item 4, *Setting up a project*** (`docs/setting-up-a-project.md`, about 800 words with its comment, weight 7, after
  the quick start): the *New Project* form with the area and time zone (task 11.331), the *Finish setting up* sheet
  (task 11.324), more offline maps (linking the map page's steps), the Pre-Trip Checklist's two new lines, and
  publishing before the crew can join. Quick start steps 1, 3, 4 and 5 point to it; step 1 now names the area and the
  sheet (item 7).
- **New pictures (all three profiles):** `new-project-form`, `finish-setting-up`, `offline-data-selection`,
  `projects-trash-menu`, `app-info-support`. **Re-shot**, because the app changed under them: `app-info`, `checklist` (its new offline-maps line), `delete-project-dialog`, `projects-countdown`, `projects-deleted-section` (the Trash wording), the four Position pictures (task 11.323's solver moved Sage's estimate, and `position-cautions` now shows the few-bearings caution), `link-tag-confirm` (today's date) and `bearing-dragged` (only the test's finger mark moved). Accepting also rewrote the pictures that moved under the 0.12% threshold, as the harness always does: 81 changed files and 15 new across the three profiles. I looked at every new picture and at each
  changed one or its difference picture before accepting. The `delete-project-dialog` capture had a stale readiness
  check (it waited for the words "from the server?", which task 11.324 changed to "permanently?"); fixed.
- **Items 6–18** (Michael's printed-guide comments): "signal" meaning coverage is now "cell or wifi coverage" on every
  page (the tag's signal is untouched); *When asking to join does not work*, with the owner's rejection quoted; every
  *On a Mac* section is gone and the guide index has one sentence instead; the roles table says *Exclude a bearing
  from position estimates* and names the Log's *Exclude from estimates…*; two Graphviz diagrams on the projects page
  (`trash-move-restore`, `trash-delete-permanently`; checked against `projects_screen.dart`,
  `project_deletion_dialogs.dart`, `project_merger.dart` and the permissions matrix, not the guide; both under the
  335 px phone column, 255 and 247 px); why the server waits 30 days (time to change your mind and export); the
  `device-and-server` diagram's "never syncs" label is inside the Tag Library box; *Only when I ask* is for battery;
  every "whoever runs your server" now points to TriTrack support; the Privacy page has *How long the server keeps
  things*; the tags page has *A Tag ID the project already has*; the scripted-compass sentence is gone from both Take
  on map captions.
- **Items 19–27:** 19 and 21 survived `/w-36` (checked); 20, `position_estimates.csv` and the receipt; 22, the
  `position-cautions` picture now shows the few-bearings caution and its caption says so; 23, the 8 red quotes plus
  11.339's, and "Two deleted sections" rewritten as *The Trash*, with its three kinds of row and *Restore* instead of
  UNDO; 24, the new screens described; 25, re-shot; 26, the Support page is ready (contact, what to include, App Info's
  support link, links to the guide's troubleshooting sections), with no promise the code does not keep; 27, the
  few-bearings caution quoted in full.
- **Item 5:** the copy-changes list's 11.241 line in `WEBSITE_PLAN.md` now names `deployments.csv` (the one edit to a
  planning document; the entry itself asks for it). Task 11.331's `deployments.csv` columns (`time_zone`,
  `attached_day`, `removed_day`) are explained on *Getting your data out*.
- **Judgment calls, made because nobody could be asked:** (a) Michael's comment 17 said two phones' duplicate Tag IDs
  are "resolved later by merging"; **no merge tool exists yet** (`near_duplicate_tags.dart` names it Phase 12), so the
  page says the app does not merge them yet and to agree who adds tags. (b) Comment 16 said server backups are "planned
  but not in place"; **the server code does keep 30 daily copies on the same machine** (`server/backup/backup.sh`), so
  the page says that, and that a backup kept anywhere else is planned. (c) The compass tab's caption keeps "a fixed 47°,
  because the simulator … has no compass"; comment 18 named only the Take on map caption.
- **Checks:** `check_app_quotes` PASS (386 quotes on 18 pages, 0 waivers); `check_built_site` PASS; `selftest.sh` PASS (28 cases);
  `hugo` clean; `dart analyze website/tools` and `flutter analyze` of `website/tools` and the harness clean;
  `theory_figures.dart --check` green (14 figures); full `flutter test` 4,083 passed, 0 failed, 16 skipped by design. The 6.1-inch `take-on-map-released` again stopped one logical pixel short of a full map, as `/w-32` recorded; it is the same picture as before (under the threshold). **PDF:** `Claude outputs/TriTrack-guide-2026-10-10-w35.pdf`, 115 pages, every page except the two theory pages, printed by Chrome (videos print as their poster). I looked at two of its pages.

**Findings for the code stream**
1. **The Offline Data Map's bottom buttons break mid-word** once a selection is drawn: "Downlo / ad" on the 6.9-inch
   iPhone, and "Canc / el", "Eras / e", "Down / load" on the 6.1-inch (visible in `offline-data-selection`). A release
   build draws it the same way, with nothing logged.
2. **Sync Status still gives data cost as the reason for *Only when I ask*** ("On a metered or satellite plan, choose
   …"). Michael's review says the reason is battery; the guide now says battery. Decide whether the app's note should
   say battery too.
3. **The nightly batch builds the site but does not run `check_built_site.dart` on it** (`scripts/nightly_check.sh`,
   the `mac-web-build` step). Since 11.325 the workflow runs only by hand, so today only `selftest.sh` (in the nightly)
   exercises the checker, on fixtures. Add one line after `mac-web-build`:
   `dart website/tools/check_built_site.dart '$RUN_DIR/site'`. The content lane may not edit `scripts/`.
4. A member's notice when an owner moves a project to the Trash still says "*Name* deleted *project*"
   (`describeDeletedArrivals`), while everything else now says Trash. Small; say if it should match.

**For the planning session**
1. File findings 1 and 3 as code tasks; put finding 2 to Michael (product wording); finding 4 is optional.
2. `/w-35` is closed: its command file is deleted in this commit.

**For Michael**
1. Push when ready; that publishes everything above.
2. Read `TriTrack-guide-2026-10-10-w35.pdf` in `Claude outputs/` (or `hugo server --source website`), especially *Setting up a project*, the
   two Trash diagrams, and the Privacy page's new section (comment 16's backup wording is a judgment call above).
3. After the push, open *Recording a bearing* on your phone and play the video once.

### Task `/w-38` — resolved 2026-10-10 by the planning session — `Done`

Both theory pages published in the source (live on Michael's push); support email on the Support page. 1: `/w-35`'s
`PUBLISH-WITH-THEORY` instruction removed from its command file and plan entry. Task 11.338 can run now.

### Task `/w-38` — 2026-10-10 — commit `cb5e8a9` — Done

**The two theory pages are published, and the Support page now gives michael.shafer@nau.edu as the way to reach TriTrack support.** The
site goes live when Michael pushes: `website.yml` runs on a push that changes `website/**`. Nothing is live until then.

- **Both pages:** `draft: true` and each page's draft note are removed. The pages' other maintainer notes (the source list, the
  figures, the shared references) stay in their comments. Plain `hugo` (without `-D`) builds both, and the guide index lists them.
- **The four `PUBLISH-WITH-THEORY` comments** (`how-it-works.md`, two in `estimating-a-position.md`, and the theory page's own
  list) are applied and deleted; no copy is left in `website/`. The only remaining mentions are in `WEBSITE_PLAN.md`,
  `WEBSITE_COMMS.md` and `.claude/commands/w-35-…md`, which describe history.
- **A broken link, found by the check and fixed.** The sentence in `how-it-works.md` was written as `docs/how-the-estimate…`, but that
  page is served at `/how-it-works/`, so the link pointed at `/how-it-works/docs/…`, which does not exist. It is now `../docs/…`.
- **Support page, *Getting in touch*:** the email as a `mailto:` link, then what to include (the version from App Info, the phone
  model and its operating system, what happened with a screenshot). The repository link stays, now described as the place for a
  problem with the website. The "not written yet" line and the rest of the page are left for `/w-35` item 26.
- **Checks:** 204 internal links, none broken, including 4 that use `#how-often-does-the-95-ellipse-contain-the-animal` (checked
  against the built pages, with the site's `/tritrack-site/` prefix handled). `theory_figures.dart --check` green (14 figures).
  `check_app_quotes`: the same 8 known reds, all in `projects-members-and-roles.md` (7) and `sync.md` (1). No raw TeX or math
  errors on either page.
- **PDFs** (stills in place of the animations), made with Chrome's print:
  `Claude outputs/How-the-estimate-is-calculated-2026-10-10-published.pdf` and
  `Claude outputs/The-mathematics-of-the-estimate-2026-10-10-published.pdf`. **I could not look at them** (no PDF viewer tool on
  this Mac), so I know they were written and their sizes, not how they paginate.

**Closed:** `.claude/commands/w-38-publish-theory-support-email.md` is deleted in the commit that adds this entry.

**For the planning session**
1. `/w-35`'s command file still tells that window to look for `PUBLISH-WITH-THEORY` comments; there are none now. Remove that
   instruction when `/w-35` is next touched.
2. Nothing else.

**For Michael**
1. Push when ready; that publishes the two theory pages and the new Support text.
2. After the site updates, open the Support page and click the email link once, to see that your mail program opens.

### `/w-37` review round — read 2026-10-10 by the planning session — `Done`

1. Fixed: 11.338's Status now starts "Not started" (the planning session's own slip in `c37fd50`; `main` was red from it).
2. `/w-38` waits for Michael to read the tracked Word files; it publishes whatever text is current then. 3. Michael's
"thoughts" document is read and put to him as a product question against standing decision 5.

### `/w-37` review round — 2026-10-10 — commit `154db8f` — Done

Michael left 27 Word comments on the first theory page and none on the mathematics page. All 27 are answered in the website
source, and the ones that apply to the mathematics page are carried over.

- **"Leftover angle" is now "residual"** on both pages and in the figures. "Residual" is the standard term, a biologist
  knows it from regression, and the methods sentence already used it. The step 4 heading changed with it, so its address is
  now `#4-how-spread-out-the-bearings-are-κ-from-the-residuals`; the mathematics page's two links follow it. "Real κ" and
  "real error" are now "true κ" and "true error", and the coverage table's True κ column is defined under it.
- **Step 4 says why the residuals understate the errors.** Taken together, they are smaller than the true errors in every
  fix, because the estimate is the point that makes them smallest. Two bearings always cross, so their residuals are zero
  however poor they were; that is the worked reason, and n − 2 bearings' worth is what is left. The step also says why an
  average cosine is used and what A(κ) means (A(132) = 0.996, A(33) = 0.985, A(15) = 0.966), and rewrites the "nowhere else
  to go" field note.
- **Step 3** says what the search looks for: zero slope, meaning both derivatives of the log-likelihood are zero. "A hundred"
  is now "100 m". The close-up figure now prints how many of the ten bearings cross it, computed by the script (4).
- **Step 5** explains why 2.45 and not 1.96, with a **new figure, `chi-square-scale`**: 68% and 95% in one direction, 39%
  and 95% in two. The script computes those shares and refuses to draw if they stop rounding as printed. The hill-to-ellipse
  caption and legend now say the dotted line is the hill's own 95% outline (5% of its top, which is where the 95% ellipse
  would lie if the hill were a perfect oval) and that the shading is the likelihood.
- **Smaller fixes:** a citation for the semi-axes (White and Garrott pp. 62–63); the λs named as Q's eigenvalues; the
  information matrix explained; the containment test and its 5.991 explained; the simulation described (stations in a half
  circle 500 m to 2 km away, von Mises errors, and "scatter" defined as the circular standard deviation, with about two
  bearings in three inside ±scatter).
- **The coverage section now opens by saying TriTrack uses the standard method**, and that this section measures that
  method's known limitation (the LOAS manual reports the same shortfall). The field-test item now says which cause it means.
- **Length:** the first page is **3,401 words of prose**, up from 2,499 and now over the 2,700 that `/w-37` aimed for. The
  growth is the explanations Michael asked for. The mathematics page is 2,830.
- **Checks:** `theory_figures.dart --check` green (14 figures); `hugo` and `hugo -D` clean; 218 internal links, none broken;
  no math rendering errors. `check_app_quotes` shows only the 8 known failures on other pages.
- **Word files in `Claude outputs/`:** `How-the-estimate-is-calculated-2026-10-10-tracked.docx` (Michael's 27 comments
  kept, 123 insertions and 75 deletions by "Claude") and `The-mathematics-of-the-estimate-2026-10-10-tracked.docx` (54
  insertions, 11 deletions), plus clean 2026-10-10 copies. Made with Word's own Compare.
- **Committed through the escape hatch** (`TRITRACK_PRECOMMIT_RED_IS_PREEXISTING=1`). The one failing test is
  `command_file_staleness_test.dart`: planning commit `c37fd50` gave task 11.338 the status "Above the line, after `/w-38`",
  which contains none of the status words the check reads. Reproduced on the clean tree with this task's files stashed. A run
  of all 374 test files with these changes, made just before, showed that test as the only failure.
- **Not acted on:** "My thoughts on ellipse error regions for Claude.docx", in `Claude outputs/`. It proposes computing the
  true 95% region on a grid, with a κ for each bearing, as an option beside the ellipse. That would change the estimate
  itself, which reopens Michael's 2026-10-07 standing decision, and the file ends mid-word, so it looks unfinished.

**For the planning session**
1. Fix 11.338's Status line so it contains a status word (for example "Not started — above the line, after `/w-38`").
   Until then every commit is red on that test.
2. `/w-38` will publish this revised text. Keep it after Michael has read the tracked Word files; this round added about
   900 words he has not yet seen in place.
3. Michael's "thoughts" document is a product question, not a website one: a computed 95% region and a κ for each bearing,
   offered as an option beside the standard ellipse. Take it up with him once he says it is finished, against standing
   decision 5.

**For Michael**
1. Read the two `-tracked.docx` files. Reply or resolve in Word as you like, and send back anything still unclear.
2. Run `/w-38` only once you are happy with the text, because it publishes it.
3. Push when ready.

### `/w-37` follow-up — resolved 2026-10-09 by the planning session — `Done`

Michael's step-1 redraw (bearing as a fading wedge over its von Mises curve). Nothing to file; the pages stay drafts.

### `/w-37` follow-up — 2026-10-09 — commit `63922fb` — Done

Michael reviewed the split and asked for step 1's figure to be redrawn. **The old figure plotted the von Mises curve in polar
form, so each bearing looked like an ellipse.** That shape reads as "the animal is about this far away", and it is easy to
confuse with the error ellipse in step 5. **Each bearing is now a wedge that fades with angle:** solid along the bearing,
clear at the sides. It also fades out at its far end, because a bearing says nothing about distance. **Under each wedge is
its von Mises curve** (−40° to +40°), with the same 10° and 20° guides. All three curves share one vertical scale, so
κ = 132 is tall and narrow and κ = 15 is low and wide over the same area. Each wedge is shaded to its own peak, so the wide
one stays visible; the curves carry the heights. The guide labels, which overlapped in the old figure, no longer do.

- **Changed:** `website/tools/theory_figures.dart` (the step 1 drawing), `website/static/figures/bearing-fan.svg`, and step
  1 of `how-the-estimate-is-calculated.md`: two sentences, the alt text and the caption. The White and Garrott sentence and
  its citation are unchanged. **The first page is 2,499 words of prose** (2,484 before).
- **Four style notes from the analyzer fixed in the same script.** The commit hook runs `flutter analyze`, whose lint rules
  are stricter than the plain `dart analyze` `/w-36` checked with. Three of the notes were already in the file, one was mine.
  `--check` confirms the other 12 figures are byte-identical.
- **Checks:** `theory_figures.dart --check` green; `hugo` and `hugo -D` clean; 210 internal links, none broken.
  `check_app_quotes` has the same 8 failures as before, on `projects-members-and-roles.md` (7) and `sync.md` (1), already
  assigned to `/w-35`; none on the theory pages. Full suite green at the commit (3,996 tests).
- **PDF:** `Claude outputs/How-the-estimate-is-calculated-2026-10-09-wedges.pdf` (18 pages; the figure is on page 2). I
  checked both themes in a browser and the printed page at full resolution.

**For the planning session:** nothing. The `/w-35` publishing instruction is unchanged; this is still the same draft page.

**For Michael**
1. Look at page 2 of the PDF, or run `hugo server -D --source website`.
2. Push when ready (`1326640`, `cc69ba7`, `63922fb` and this entry's commit).

### Task `/w-37` — resolved 2026-10-09 by the planning session — `Done`

1. The staleness check's `Done (…)` blind spot is task 11.332 item 5. 2. `/w-35` told: the theory is two drafts, published
together, and only when Michael says so after reading them. 3. Kept as split; Michael can say otherwise after reading.

### Task `/w-37` — 2026-10-08 — commit `1326640` — Done

**The theory page is now two draft pages: one explains the method in pictures and says how far to trust the ellipse, the
other holds the full mathematics.** A biologist can read the first without meeting a derivation. Each page links to the
other in its opening lines. Both are still `draft: true`, and they should be published together.

**How the estimate is calculated** (`docs/how-the-estimate-is-calculated.md`) keeps the short "idea in one paragraph",
the five assumptions, all seven pictures with the colored equation each one explains, *How often does the 95% ellipse
contain the animal?* (advice first; the anchor task 11.338 links to is unchanged), *What TriTrack does not do (yet)*, the
methods sentence and the references. **Prose: 2,484 words**, down from 5,342. That counts the page minus its comments,
display equations and figure shortcodes, with the reference list included. The same count gives the page before `/w-36`
2,691, close to the 2,669 `/w-36` reported. **That is 8% under the old 2,700, not a dramatic cut.** The pictures with
their equations and the coverage section, which the brief keeps whole, are about 1,800 words on their own, so going much
lower means cutting into them. I tightened sentences rather than dropping content.

**The mathematics of the estimate** (`docs/the-mathematics-of-the-estimate.md`, new, weight 39, 2,656 words) takes the
following sections **word for word**, except that links pointing back to the first page now name it: *Coordinates and
angles*, *The model and its likelihood*, *Finding the position*, *How spread out the bearings are*, *The ellipse*, *Why
not just average where the bearings cross?*, *When it goes wrong*, *Validation against Lenth's own example* and *Where
TriTrack differs from the paper*. The code file list moved with them, into its header comment.

**One judgment call:** the brief placed neither *Why not just average…* nor *When it goes wrong* (what each caution
measures, with its threshold). Both went to the mathematics page. The first page still says the two things a field
reader needs from them: no ellipse can see a bounce, and untick a doubtful bearing (assumption 2 and the advice list,
which link to the Lenth bounce example on the mathematics page). The how-to page already lists the cautions in plain
words.

**One reference list for both pages.** The five sources are in `website/data/theory_references.toml`, and a new
`theory-references` shortcode renders it at the foot of each page. So [2] means White and Garrott on both pages, and
there is one copy to correct. The entries are unchanged except "this page" → "these pages" in the Garrott note.
Numbering stays first-cited order (the first page, then the mathematics page). That is still 1–5, because Fisher [5] is
now cited only on the mathematics page. The `refnum` shortcode this replaces is deleted; `website/README.md` describes
the two pages and the shared list.

**Where every equation went (none lost).** *Stayed on the first page:* the von Mises density; the log-likelihood ℓ(x, y);
the two "flat at the top" conditions; the leftover angle rᵢ, the mean cosine C̄ and A(κ̂) = C̄; Q = (κ̂Î)⁻¹ with a, b
and k = 5.991; the approximate information Î; the coverage inequality; and *does not do (yet)*'s n − 2. *Moved to the
mathematics page:* the projection xᵢ, yᵢ and R; θᵢ = 90° − βᵢ; the symbol list with μᵢ and dᵢ; the model
θᵢ = μᵢ + εᵢ; the von Mises density, ℓ(x, y, κ) and the flatness conditions again in full context; sᵢ, cᵢ, zᵢ, sᵢ*,
cᵢ*; Lenth's linear system and the starting point; the halving (30 times) and stopping rules; A(κ) = I₁/I₀; Fisher's
three-branch κ̂; Î_xx, Î_yy, Î_xy; Q written out; SE(x̂), SE(ŷ), ρ; λ₁,₂; a, b with k = −2 ln(1 − p); the axis angle ψ;
Eq. 4.6's area; the circular standard deviation √(−2 ln R̄); n(n − 1)/2 crossings; and both validation tables.
**Counted in the built pages:** 116 formulas (32 + 84) against 117 before, and 95 colored symbols against 96. A diff of
every formula shows that the one missing is an inline κ̂ in a sentence explaining the hat. That sentence now says it in
words ("a hat always means a value estimated from the bearings"); the mathematics page keeps it. Two other changes are
wording only: step 5 says "k is chi-square's 95% point" right under the equation that sets k = 5.991, and step 4's
equation ends in a comma instead of a period.

**Where every citation went (all 30 in-text citations kept: 20 + 10).** *First page:* Lenth [1] in the intro, assumption 5,
step 3 (twice), step 5 (Eqs. 2.7–2.9) and *does not do* (section 4). White and Garrott [2] in the intro, step 1
(Figs. 4.11–4.12), step 4 (p. 69), step 5 (pp. 62–63, Eq. 4.6), the coverage "why" (Eq. 4.4, p. 59), the field test
(Table 4.1, p. 70) and *does not do* (ch. 5 and Eq. 4.4, p. 59; pp. 68–69; p. 72; pp. 70–71). LOAS [3] in the coverage
sources and *does not do* (twice), all p. 11. Garrott et al. [4] with Table 4.1. *Mathematics page:* Lenth [1] at
Eq. 2.6, section 2, Eqs. 2.7–2.9, section 1, Tables 1 and 2, and Eq. 2.10 in *differs*. White and Garrott [2] at Eq. 4.6's
area and pp. 62–63 in *differs*. Fisher [5] twice. The 31st citation, [2] inside the Garrott reference entry, is in the
shared list.

**Checks.** `theory_figures.dart --check`: green (13 figures; the method still reproduces the app). `hugo -D` and plain
`hugo`: clean, and both drafts are absent from the plain build. **Internal links:** 210 in the draft build and 148 in the
plain build, every page and every `#anchor` resolving. That includes the five links from the mathematics page to the
first page's numbered steps; one of those anchors contains κ. I checked this with a throwaway script and watched it fail
on a copy with one anchor and one page name broken. No raw TeX outside a formula on either page. `check_app_quotes`:
**both theory pages are green.** The run shows 8 reds, all on `projects-members-and-roles.md` (7) and `sync.md` (1).
They are task 11.324's committed wording, already assigned to `/w-35`; this task touched neither page. The commit gate
ran the whole suite: 3,996 tests across 374 files, green, no escape hatch.

**PDFs** (stills in place of the animations): `Claude outputs/How-the-estimate-is-calculated-2026-10-08-split.pdf`
(17 pages) and `Claude outputs/The-mathematics-of-the-estimate-2026-10-08.pdf` (9 pages). `/w-36`'s single 26-page PDF is
left beside them, unchanged.

**Closed:** `.claude/commands/w-37-split-theory-page.md` is deleted in the commit that adds this entry, because this
heading now says `Done`.

**For the planning session**
1. **The command-file staleness check misses a website heading like `/w-36`'s.** The check is
   `test/documentation/command_file_staleness_test.dart`. It counts a website task as finished only when the text after
   the heading's last dash is exactly `Done`. `/w-36`'s heading ended "Done (the theory page stays a draft)", so the
   check read it as still running, and that is why its command file passed while still present. **Ask for a code task to
   classify by the leading status word rather than by the whole text**, and to watch it fail on a `Done (…)` heading
   first. This lane may not edit `test/`.
2. **Tell `/w-35` that the theory is now two pages, to be published together.** Removing `draft: true` from both is one
   edit; the `PUBLISH-WITH-THEORY` links can keep pointing at the first page, which links onward. Its link and raw-TeX
   checks will cover both pages automatically, since they read the built site.
3. If *When it goes wrong* or *Why not just average…* should be on the first page after all, say so; moving either back
   adds about 370 or 130 words.

**For Michael**
1. **Read the two drafts:** `Claude outputs/How-the-estimate-is-calculated-2026-10-08-split.pdf` and
   `Claude outputs/The-mathematics-of-the-estimate-2026-10-08.pdf`. Or run `hugo server -D --source website` to see the
   animations. Worth your judgment: whether the first page now reads end to end without the mathematics, and whether
   2,484 words is short enough. Going shorter would mean trimming the seven picture steps or the coverage section.
2. **Push when ready.** Nothing has been pushed.

### `/w-36` and its follow-up — resolved 2026-10-08 by the planning session — `Done` (page stays a draft)

1. LOAS page corrected to p. 11 in the plan and `WEBSITE_PLAN.md`. 2. The figure check joins the nightly run (task 11.332 item
4). 3. Written into task 11.338. 4. `/w-35` told items 19 and 21 are done. 5. 11.324's entry names them; `/w-35` fixes them. 6.
Command file removed. 7. Fixed: the three citations rewritten, `TASK_COMMS.md` back to 20. Michael's reading and the one-page or
two-page decision are put to him.

### `/w-36` follow-up — 2026-10-08 — commit `5961abe` — Done (numbered citations; the page stays a draft)

Michael asked for citation numbers. The theory page's references are now numbered [1]–[5] in the
order each is first cited (Lenth; White and Garrott; the LOAS manual; Garrott et al. 1986; Fisher),
and all 31 citations in the text link to their entry. Garrott et al. (1986) now has its exact
citation, from White and Garrott's chapter 4 reference list, still marked as not read. The quoted
methods sentence keeps author–year, since it is written to be pasted into a paper. New shortcode
`refnum`; README updated. Fresh PDF, same name. Committed through the escape hatch for the same
pre-existing red (task 11.324's `TASK_COMMS.md` citations).

**For the planning session:** nothing new.

**For Michael**
1. Push when ready.

### Task `/w-36` — 2026-10-08 — commit `10808e3` — Done (the theory page stays a draft)

**The draft theory page now explains how the estimate and its 95% ellipse are made in pictures before any equation, and says plainly how often that ellipse contains the animal.** Thirteen figures, three of them animated, are drawn by a script from the app's own numbers (task 11.336's data). The script will not draw anything unless its copy of the method reproduces the app. The page is still `draft: true`; a fresh PDF is at `Claude outputs/How-the-estimate-is-calculated-2026-10-08.pdf` (26 pages; the 1 October one is kept beside it).

**What a reader gets** (`docs/how-the-estimate-is-calculated.md`):
- **"The method in pictures"**, seven steps, each in words, then a picture, its equation and one line for the field: (1) a bearing as a fan of likely directions at 5°, 10° and 15° (κ 132, 33, 15); (2) ridges multiplying into a likelihood "hill" (animated); (3) the app's own climb to the top for a 10-bearing fix (animated), plus the step-halving safeguard on the real fix the app's tests pin; (4) κ from the leftover angles, and why three bearings make it far too large (κ 228 against a true 15); (5) the hill's shape becoming the 1-SD and 95% ellipses, and the same bearings with the real κ, whose ellipse is 3.9 times larger and contains the animal; (6) geometry; (7) simulated fixes filling in ticks and crosses, ending at 11 of 24 with three bearings and 22 of 24 with ten (animated).
- **"How often does the 95% ellipse contain the animal?"**: the advice comes first (take more bearings; the app cautions at five or fewer, quoted; read a three- to five-bearing ellipse as a minimum; spread the stations; untick a doubtful bearing). Then the reason, and three sources: the LOAS manual, White and Garrott's Table 4.1, and TriTrack's simulation. It has a coverage chart, a table and two worked examples (a miss at 3 bearings, a hit at 5).
- **The 95% ellipse is now described as White and Garrott's (1990, pp. 62–63, Eq. 4.6) construction**, taken out of *Where TriTrack differs*. Also new: a **"What TriTrack does not do (yet)"** section (system testing, the goodness-of-fit test, a maximum ellipse size, the Andrews estimator, F-based ellipses, each with its page), a methods-section sentence that cites the chi-square ellipse, and exact references.
- **One color per quantity across the page, figures and equations alike:** bearing blue, estimate red, κ magenta, ellipse green, likelihood gray. Each color has its own light and dark value. All pairs passed a colorblind separation check (worst pair 10.0 in light, 8.9 in dark, target 8), and every color reads as text at 4.5 : 1 or better. Every figure also names things in words. In the equations, KaTeX's `\textcolor{#hex}` becomes a MathML `mathcolor`, and `style.css` swaps in the theme color, so dark mode recolors the equations too. Checked in the built page: 117 formulas, 96 colored symbols, no raw TeX outside a formula.
- **Length, stated rather than rounded away: the page's prose went from 2,669 to 5,138 words.** The brief asked for the method to be explained again in pictures before the full equations, which stay. Say if the full mathematics should move to a page of its own.

**How the figures are made.** `website/tools/theory_figures.dart` is Dart with no dependencies, like the other site tools. **Before drawing, it re-solves all six worked examples** and must match the app's starting point, every solver step, estimate, κ, leftover angles, covariance and both ellipses (positions to 1 mm, ratios to 1 in 10,000). **It also re-runs the whole coverage simulation, 36,000 fixes on task 11.323's seed, and must match every count in the CSV exactly.** It did, so the coverage animation shows the app's own first 24 fixes of two cells. `--check` fails if a committed figure differs from what the script draws now. **Watched red both ways:** a hand-edited label in a figure, and a changed constant in the κ formula. **And one break that stayed green, recorded beside the function:** a mistake in the two lower branches of Fisher's κ approximation (average cosine under 0.85) would not show, because no example and no simulated fix reaches them. No figure depends on them. `--check` now runs in `website.yml`; the script is clean under `dart analyze`.

**No script reaches a reader.** Animations are CSS keyframes inside the SVG. A new `anim` shortcode places each with a still version of its steps. The still version stands in when the page is printed or made into a PDF, for readers who ask for reduced motion, and when a reader ticks *Show still pictures instead*, which is also the way to stop the movement. A new `fig` shortcode places the still figures. Both require alt text and a caption, and fail the build if the file is missing. Every figure is drawn for a 360-unit phone width, and I looked at each one at a 350-pixel column in both themes, and at frames from each animation. Fixes made after looking: label collisions; the "x̂" hat drifting off its letter in SVG text (the figures now say "estimate" in words); ellipses spilling out of the coverage grid's squares; a running count that cross-faded so two numbers overlapped.

**Where the brief's spec did not match the sources (entry 109):**
1. **The LOAS "45–85%" sentence is on page 11 of the manual, not page 10.** Page 10 ends at "Select Estimators"; *Error Ellipses* is on the page footed "1/1/2005 Page 11". The page cites p. 11.
2. **None of the six worked examples has a shortened step**, as 11.336 said. The halving picture uses the fix `lenth_mle_test.dart` pins for exactly that, read from the test file rather than copied. Its path is the script's re-computation; the app's data holds no path for it. The script checks that a halved step occurs, which is what the test pins.
3. **White and Garrott's 41% (Table 4.1) is a bounce-prone field test, and their κ came from system testing (Eq. 4.4).** So the page calls that shortfall "probably mostly bounce" and keeps it apart from the few-bearings cause. "Probably" is my inference; the book does not separate the two.
4. **The 95% ellipse is only close to where the likelihood hill falls to 5% of its height, not on it.** In the running example the hill at the ellipse's four ends is 1.7% and 6.6% (long axis, lopsided) and 5.6% (short axis). The figure draws both lines and the page says "close"; the script fails if any end leaves 1–10%.

**Also done, ahead of `/w-35`:** its item 19 (`estimating-a-position.md`: the stale two-bearing "nothing on screen says so … 0×0 m" paragraph is corrected, and the no-ellipse cautions are in the cautions list) and item 21 (the theory page's two-bearing caution and the step-shortening). `/w-35` only needs to check them. **11.336's copy list is in:** the few-bearings caution in the how-to page's list, with its 40–70% and a pointer sentence held in a `PUBLISH-WITH-THEORY` comment.

**Michael's Word file** (`Claude outputs/TriTrack-theory-review.docx`, 2 October) has **no edits**: no tracked changes, no comments, and its prose matches the page as it stood (only the math reads differently). Nothing to list.

**Checks.** `check_app_quotes`: **green against the committed app** with this task's pages (334 quotes, 0 waivers; run on a copy of `HEAD`'s `lib/` and `packages/`). In the shared working tree it shows 8 reds, **all on pages this task did not touch**: `projects-members-and-roles.md` (7) and `sync.md` (1). They come from another window's uncommitted app changes (renamed deletion actions; "whoever runs your project server"). That task should name them. `hugo` builds clean with and without drafts (the draft is absent from the normal build). All 162 internal links in the draft build resolve. The pre-commit suite passed: 3,996 tests across 374 files.

**A cosmetic I did not chase:** the hat on x̂ or κ̂ sits low over its letter in Chrome. KaTeX's MathML writes it as a plain `^` over the letter. That was already true of this page before this task, and it is the same for colored and uncolored symbols.

**For the planning session**
1. **Correct the LOAS page number from 10 to 11** in `DEVELOPMENT_PLAN.md` (task 11.337 item 5, line ~36015; the 11.334 history at line ~46221) and in `WEBSITE_PLAN.md`'s `/w-36` item 2.
2. **Ask for `dart website/tools/theory_figures.dart --check` to be added to `scripts/nightly_check.sh`**, next to the website checks. It is in `website.yml`, but that workflow only runs by hand now, and this lane may not edit `scripts/`.
3. **Task 11.338** (the caution points to the guide): the section to point at is `#how-often-does-the-95-ellipse-contain-the-animal` on this page.
4. **Tell `/w-35` that its items 19 and 21 are done here**, so it only checks them.
5. Whichever code task is changing the deletion and server-help wording should name the 8 `check_app_quotes` reds above in its comms entry.
6. Remove `.claude/commands/w-36-ellipse-theory-figures.md` when you resolve this. I left it in place (`command_file_staleness_test.dart` passes with it present).
7. **`main` is red, and not from this task.** Task 11.324's commit `4b44e41` (21:19 today) added three file-and-line citations to `TASK_COMMS.md`, so `planning_document_citations_test.dart` fails ("TASK_COMMS.md: 20 allowed, 23 found (+3)"). Reproduced on `HEAD` with only this report uncommitted. **This report's two commits (`43ad464` and the one adding this item) went through the escape hatch (`TRITRACK_PRECOMMIT_RED_IS_PREEXISTING=1`) for that red alone.** I recorded it here rather than in `TASK_COMMS.md`, because this lane reports here. The fix is to rewrite those three citations, not to raise the budget.

**For Michael**
1. **Read the draft**: `Claude outputs/How-the-estimate-is-calculated-2026-10-08.pdf` (stills in place of animations), or `hugo server -D --source website` and open *How the estimate is calculated* to see the animations. Things worth your judgment as a biologist: whether steps 1–7 read without college mathematics; the advice to "read a three- to five-bearing ellipse as a minimum"; and the "probably mostly bounce" reading of White and Garrott's 41%.
2. **One decision, when you have read it:** keep the page as it is (5,138 words: pictures first, full equations after), or move the full equations to a page of their own.
3. **Push when ready.** Nothing has been pushed. `main` currently has one red test, from task 11.324's commit, not this one (planning-session item 7).

### Overnight batch (`/w-31`, `/w-32`, `/w-33`, `/w-34`) — resolved 2026-10-01 by the planning session

**All four are `Done`**; `/w-31` and `/w-32` close here and their leftovers move to new numbers.
- **`/w-31`:** Michael approved publication (he will read it in detail later). Publishing it is
  **`/w-35`** item 2. Its code findings 1 and 3 (the two-bearing 0 × 0 ellipse; no estimates file
  in the export) are **task 11.323** items 1 and 3. **Finding 2** (the small-sample ellipse): Michael
  asked for a citation before any change to the math, so 11.323 item 2 **measures the coverage by
  simulation and changes nothing**.
- **`/w-32`:** Michael approved the 4× video. Committing and placing it is **`/w-35`** item 1. Code
  findings 1–4 are **task 11.323** items 4–6. The viewshed finding is task 11.318 item 5.
- **`/w-33`:** the link fix is `/w-35` item 2, the link and raw-TeX checks are item 3, and
  `deployments.csv` is item 5.
- **`/w-34`:** gaps 1, 3 and 4 become a short *Setting up a project* page, `/w-35` item 4, with the
  two pictures.

### `/w-32` follow-up — 2026-10-01 — commit `217f380` — Done (the video plays 4x and smoothly; still not committed)

**Michael chose 4x for the Take on map clip and said it was a little choppy. It now plays at a steady 60 frames a second, and the recording script produces exactly that clip.** The choppiness was in the recording, not the speed-up: the first recording had **7.4 frames a second**, because the test binding draws only the frames a test pumps and the harness's `settle` pumps every 120 ms. `video_test.dart` now switches the binding to `fullyLive` while the recorder runs, and turns the compass continuously by the clock instead of in 20 steps of 350 ms. Measured: the new raw recording is **44.5 frames a second**. The new step, `retime_video.swift`, replaces `avconvert` in `record_video.sh`. It plays the recording 4x faster and resamples it to 60 fps. Result: **3.85 s, 60 fps, 588×1280, 1.39 MB** (budget 2 MB), no audio. A plain time-squeeze kept every frame and wrote a 178 fps, 3 MB file, which is why it resamples. I looked at frames from the start, middle and end of the sweep and at the released state. The screenshot pictures are untouched: only the video test changed, and only between `VIDEO_START` and `VIDEO_STOP`.

**The clip is still not committed**, per Michael's overnight instruction. It is at `Claude outputs/take-on-map.mp4`, and the earlier versions are in `Claude outputs/take-on-map-earlier/`.

**Findings for the code stream**
1. **The Map screen's viewshed calculation writes to a provider that has already been disposed.** After the video test ends, `_MapScreenState._computeViewshedAt` (in `map_screen.dart`) calls `ComputationStatusNotifier.fail`, and Riverpod throws `UnmountedRefException`. The test's log shows it as "Test failed … after it had already completed", while the run still exits 0. **This predates tonight.** I ran the unchanged `video_test.dart` from `HEAD` once to check, and it throws the identical exception. In the app, the same thing would happen if the screen holding that provider is torn down while a viewshed is computing. That is probably harmless but logs an error. I did not reproduce it outside the test.

**For the planning session**
1. Michael has approved 4x. The leftover `/w-32` work is: commit the clip, add a video shortcode with the `take-on-map` picture as its poster, and place it on Recording a bearing. Give that a new number. The clip now regenerates with `record_video.sh` alone.
2. Consider filing the viewshed finding above as a code task.

**For Michael:** nothing beyond the leftover `/w-32` work above.

### `/w-31` follow-up — 2026-10-01 — commit `b57962f` — Done (one formula fixed; the page stays a draft)

**One equation on the draft theory page showed as raw math code instead of a formula, and it now renders.** Michael found it while reviewing the page. In the system-of-equations block under the Gauss–Newton step, the `=` sat alone on its own line. Markdown reads a line of just `=` as "make the paragraph above a heading", which split the `$$ … $$` block before the math step saw it. The `=` now ends the line before it. Checked on the rendered page: that span is one MathML formula with no heading, and no raw TeX is left outside a formula anywhere on the page (84 formulas). A scan of every `$$` block on the site for lines Markdown would misread (a line of only `=` or `-`, a blank line, or a list, quote or heading marker) found only this one.

**For the planning session**
1. Optionally, a check in `website.yml` that fails when a rendered page has raw TeX outside a `<math>` element. Hugo builds this mistake without complaint, and the only reason it was caught is that Michael read the page.
2. The take-on-map video: Michael asked for it faster. 2× (8.5 s) and 4× (4.3 s) versions are in `Claude outputs/` (not committed), made from the same raw recording with the same 1280×720 export. Once he picks one, the leftover `/w-32` work should give `record_video.sh` a speed setting so a regenerated clip comes out the same.

**For Michael**
1. Look at the 2× and 4× clips and say which speed you want.

### Task `/w-33` — 2026-10-01 — commit `d4136f5` — Done

**Every page except the draft theory page is rewritten to lead with what to do, and the site is about half as long: 20,092 words to 10,620 (47% fewer), not counting the theory page, which is untouched at 2,885.** Run unattended overnight. `check_app_quotes` is **green: 0 failures, 324 quotes** (it was 13 failures and 341 quotes; the 13 were task 11.320's, every one fixed by reading the new wording from the widget). `hugo` builds clean. A link check over the built site found **148 internal links, 0 broken** after one repair (below). No published page links to the draft theory page, and both `PUBLISH-WITH-THEORY` comments are byte-identical to before.

**Word counts per page, before → after** (body text a reader sees: front matter, HTML comments and shortcode syntax removed, quoted app text and captions kept; same script both times):

| Page | Before | After |
|---|---|---|
| Front page (`_index.md`) | 801 | 541 |
| How it works | 550 | 398 |
| Guide index | 194 | 77 |
| Quick start | 462 | 439 |
| Joining a project | 1,577 | 855 |
| Projects, members and roles | 2,719 | 1,211 |
| Recording a bearing | 2,553 | 1,337 |
| Your tags, and a project's tags | 1,631 | 985 |
| Truth points | 1,778 | 750 |
| Comparing bearings on the map | 1,145 | 499 |
| Estimating a position | 1,291 | 782 |
| Sync | 3,163 | 1,489 |
| Getting your data out | 1,087 | 560 |
| Privacy | 810 | 478 |
| Support | 331 | 219 |
| _How the estimate is calculated (draft, not touched)_ | _2,885_ | _2,885_ |
| **Total without the draft** | **20,092** | **10,620** |

**The three passages cut most, for Michael to judge the style from:**
1. *Recording a bearing → Taking the range on a map*: 734 → 338 words. Kept every step and button (what is drawn, Hold to sweep, the 180° warning, Confirm does not save, Retake, Cancel, North up / Facing up, Back to me, the north arrow, the shared map-type switch, hidden with no compass); cut the explanations of why each one behaves as it does.
2. *Projects → deleting from the server* plus *the two deleted sections*: 489 + 439 → 228 + 142 words. Kept who may do it, that it destroys every member's records, the server-set countdown, Export records, Cancel scheduled deletion, Delete immediately / Remove now, the backups window, both sections at the bottom of Projects, and restore. The bullet lists replace paragraphs.
3. *Sync → what a name may contain*: 483 → 178 words. Kept the whole allowlist with its examples, what is refused and why, visible versus invisible characters, and what happens to an already-saved name.

**Descriptions that were false and that the quote check could not see** (entry 99's class; each found by reading the page against the code):
1. *Recording a bearing* said the wheel lists "the tags in this project, by frequency, pulse rate and name". Since tasks 11.249 and 11.260 it lists only tags on an animal right now, each as frequency and animal name, with a two-icon sort switch. Rewritten from `_tagLine` and `tagIdsAudibleOn`.
2. *Truth points* and *Getting your data out* both said the export writes several files, asks where to put each, and names the truth-point file with a `_truthpoints.csv` ending. Since task 11.241 it is **one zip**, named for the project and date, holding `observations.csv`, `non_detections.csv`, `truth_points.csv`, `tags.csv`, `individuals.csv` and `deployments.csv`. Both pages now say so.
3. *Truth points* quoted *"You can undo this from the confirmation that follows."* as the delete confirmation. It passed because the Log's bearing delete says it; the truth-point dialog, used from both the map and the Log, says *"You can undo it straight after."* Fixed.
4. *How it works* had **five broken links since `/w-28`** (`docs/...` relative to `/how-it-works/`, which resolves to a page that does not exist). Fixed to `../docs/...`. Hugo does not check Markdown links, and nothing else does either.

**The four screens the brief named as described without quoting:**
- *Sync Status held-record cards*: read in `sync_status_screen.dart` and `held_row_details.dart`. The page now names the card's parts (*Why it is waiting*, *What you can do*, when it was last tried, *Try again*) and quotes the new pasted-text remedy.
- *Projects delete and leave dialogs*: read in `projects_screen.dart` and `project_deletion_dialogs.dart`. The page's descriptions match the new wording (leave: stop syncing, records stay under your name, copy works offline, two ways back; in-app delete: kept but hidden, undoable).
- *Server Connection sign-out dialogs*: **the guide had never described sign-out at all**, so nothing was stale. I added one short paragraph to *Joining a project* (see decision 2).
- *The tag-copy (i)*: the old quote is gone; the tags page now says the (i) beside the copy line explains the copy, and quotes the visible line.

**Tasks 11.321 and 11.322 are on the tags page**: the grouped Tag Library and its search, dragging a tag onto a project heading (and reordering headings), the one-step *Link a tag* with its *Tag went on* date and *Change*, the bearings warning for a back-dated link, and Quick add. `/w-32`'s first-draft section was rewritten into it.

**Pictures: none captured.** The existing ones covered every page.

**Decided overnight without Michael**
1. **The privacy page was shortened (810 → 478) but every claim was kept**: the backup is deliberate and why; Apple holds iCloud backup keys; Google's coverage is unclear; the per-app switch on iPhone and on Android (June 2026 rollout, seen on Pixel, not yet Samsung); no in-app switch, and why; what turning it off costs. It is a page informing a decision, so I changed wording only.
2. **Added a short sign-out paragraph to *Joining a project*** (about 70 words): *SIGN OUT* for this phone, and *SIGN OUT EVERYWHERE* for a lost phone, with the fact that a lost phone keeps the data it already downloaded. The brief listed the sign-out dialogs and the guide had nothing; a lost phone is the case a field team needs this for. Read from `server_config_screen.dart`.
3. **Put the offline-map download steps into the map page's existing section** (*More → Manage Offline Maps → Manage on map → New selection → Download*, keep the app open, each phone keeps its own), which is where the quick start already linked. This answers `/w-34`'s gap 2 inside an existing page. **I did not write pages for gaps 1, 3 or 4** (creating a project, the Pre-Trip Checklist, publishing before inviting). That placement is still the planning session's call. The quick start's step 3 was shortened to point at it.
4. **Left both `PUBLISH-WITH-THEORY` comments exactly as they were**, including one that will produce a broken link (finding 1 below).
5. **Removed internal names from reader text**: `Tag_Versions`, the "a guide that documents an unfinished feature" history on the guide index, its "nine flows" count, and the "if you have read elsewhere" sentences.
6. **Kept, though long, because a reader acts on them:** the full roles table; the Lenth reflected-bearing example on *Estimating a position* (it is the reason to untick a doubtful bearing); the *Bounce?* versus *Malfunctioning* distinction; *STRENGTH* is about distance, not direction quality.

**Findings for the code stream:** nothing new. Every behavior I described was read from the code, and nothing I read looked wrong.

**For the planning session**
1. **When the theory page is published, fix the link inside `how-it-works.md`'s `PUBLISH-WITH-THEORY` comment**: it says `docs/how-the-estimate-is-calculated/`, which is broken from that page for the same reason as the five links above; it must be `../docs/how-the-estimate-is-calculated/`. The one in `estimating-a-position.md` is correct. I left both unchanged on instruction.
2. **Consider a link check for the site.** Five links on a top-level page were broken for two days, and nothing could notice: Hugo does not check Markdown links and `check_app_quotes` does not look at them. A short script over the built HTML (the one I used checks 148 links and anchors in under a second) could run in `website.yml` beside the quote check. Whether that is worth a content task is your call; I did not add it.
3. **Place `/w-34`'s gaps 1, 3 and 4** (creating a project, the Pre-Trip Checklist, publishing before inviting) as you decide. Gap 2 (offline maps) now has its steps on the map page.
4. **Note for the copy-changes list:** the CSV zip also holds `deployments.csv`, which the list's 11.241 entry does not name.

**For Michael**
1. **Read a few pages as a field tech would**: `hugo server --source website`, then *Guide*. The best sample is *Recording a bearing* and *Sync*, which changed most. Say if anything you would act on is missing; it is easy to put a sentence back.
2. Push when ready. Nothing has been pushed.

### Task `/w-34` — 2026-10-01 — commit `df54695` — Done

**The guide now opens with a quick start: six steps from a new install to the first bearing, each one or two sentences with a link to its full page.** Run unattended overnight. New page `website/content/docs/quick-start.md` (weight 5, so it is first in the guide's list), linked from the front page's closing list and from the top of the guide's index. About 490 words with captions, so roughly a two-minute read. Steps: create the project; add the animals and their tags with Quick add (the date the tags went on, pasting rows); download offline maps; run the Pre-Trip Checklist; invite the crew (sign in, Publish to server, Members, the join code); take the first bearing. A closing line points to the Position tab.

**Every quoted string was read from the widgets**, and the files are named in an HTML comment at the top of the page. `hugo` builds clean. `check_app_quotes` shows **the same 13 failures as before this task** (task 11.320's, assigned to `/w-33`), compared line by line against a run taken before any edit; 341 quotes checked, up from 313, none failing on the new page. All internal links and both section anchors resolve in the built site, and no published page links to the draft theory page.

**Pictures: none captured.** Four existing ones are reused: `quick-add`, `checklist`, `owner-members-and-code`, `record`.

**Decided overnight without Michael**
1. **No new pictures, and so step 1 (create the project) and step 3 (offline maps) have none.** Creating a project is one button. The offline-maps step would help most from a picture of the Offline Data Map with a selection drawn, but capturing it means a new harness state and a full three-profile run whose `--accept` rewrites all 156 images, including the ones whose dates change every run. I took the more conservative option. The wish is below.
2. **Added one sentence above the six steps** saying the app asks for your name and email the first time it opens (`identity_setup_screen.dart`), because a new user meets that screen before step 1.
3. **Step 3 says every crew member downloads maps on their own phone.** This is read from the code: `offline_region_store.dart` keeps maps in the app's own folder, and nothing in the sync code reads them. The guide did not say so anywhere.
4. **Step 5 names *Publish to server* before *Members*.** The brief said "invite the crew (the join code)", but a project that has never been published has no join code. No other guide page says publishing is the step before inviting.
5. **Closed the command file** (`git rm`), since the task is Done.

**Gaps the quick start exposed, for the content lane** (none fixed here; each is a link target that does not really explain its step)
1. **No guide page says how to create a project.** Step 1 links to *Projects, members and roles*, which covers the three-dot menu and roles but never mentions the + button, *New Project*, the extent, or *SAVE PROJECT*.
2. **No guide page says how to download offline maps.** Step 3 links to the one section that mentions them, on *Comparing bearings on the map*, which only explains what Retry does when tiles are missing. Nothing describes *Manage Offline Maps*, *Manage on map*, *New selection*, or the *Keep TriTrack open* warning.
3. **The Pre-Trip Checklist has no guide page.** Step 4 links to *How it works*, which gives it three sentences.
4. **No guide page says a project must be published before its crew can join.** *Joining a project* goes straight from signing in to *Members*.

**Findings for the code stream:** nothing.

**For the planning session**
1. Decide whether gaps 1–4 above go into `/w-33` (which is already rewriting every page) or become a new content task. My suggestion is a short "Setting up a project" page covering creation, the extent, offline maps and the checklist, which the quick start's steps 1, 3 and 4 would then link to.
2. If Michael wants a picture for step 3, add a harness state for the Offline Data Map with a selection drawn (More → Manage Offline Maps → Manage on map → New selection) to whichever task next runs the harness. A picture of the *New Project* form would fit step 1 if that page is written.

**For Michael**
1. Read the page: `hugo server --source website`, then *Guide* → *Quick start*. Nobody has looked at it in a browser; it was checked through the built HTML only.
2. Push when ready. Nothing has been pushed.

### Task `/w-32` — 2026-10-01 — commit `52925be` — Partial

**The guide now has the pictures the overnight tasks asked for, on all three phone and tablet sizes, and a first Take on map video exists but is not committed.** Run unattended overnight. `Partial` for one reason only: **the brief says to ask Michael before committing the video, and nobody could be asked.** Everything else is done. Thirteen new states, all against the harness's own in-memory fake server (no server, no sign-in, **nothing added under `test/`**, so the narrow exception was not used). Three profiles re-shot, **52 of 52 states on each, 156 images, and I looked at every one of the 39 new ones and a sheet of the rest on each profile before copying them in.** `hugo` builds. `check_app_quotes` shows **the same 13 failures it showed before this task** (task 11.320's, assigned to `/w-33`), checked by running it against `HEAD`'s content as well; none are on a line I wrote. The full `flutter test` passed (3,861 tests, 16 skipped) before the commit.

**The pictures, and where each went**
- **Take on map** (`take-on-map`, `take-on-map-released`): the screen before a sweep (two earlier bearings drawn to the edge, the dashed pointing line, `31°`) and after release (`48° ± 17°`, Cancel / Retake / Confirm, the sweep crossing both earlier bearings). On *Recording a bearing* and on the front page. The Record screen with the round map button is the ordinary `record` picture, which shows it.
- **Deleting a project:** `delete-project-dialog`, `projects-countdown`, `projects-deleted-section` on *Projects, members and roles*; `sync-project-deleted` on *Sync*. **Members on the More screen** is `more`, on the Projects page beside the sentence that says so.
- **Tags, from tasks 11.321 and 11.322:** `link-tag-picker`, `link-tag-confirm` (with the *Tag went on* card), `quick-add`, `quick-add-review`, on *Your tags*. `tags` and `project-tags` were re-shot (project headings, drag handles, search box) and `tags`'s caption now says so.
- **The three pictures `/w-31` asked for:** `position-cautions`, `position-legend`, `position-past-estimates`, on *Estimating a position*. They are in this task's list now; they fit its rules and cost almost nothing.
- **Existing pictures placed:** `checklist` and `joined-sync-indicator` on the front page and on *How it works*, each beside the claim it backs.
- **`/w-29`'s "no picture of it in this guide yet" sentence is removed.** `truth-points.md` now says the map label begins *Truth* (an estimate's begins *Estimate*), read from `_markerLabel`.

**What the harness gained** (all in `integration_test/screenshots/`, described in its README): a compass heading that is a variable the script can move, so a sweep can be scripted (`take_on_map.dart`); two earlier bearings dated today, aimed from computed positions at one spot and **hard-deleted afterward** (a soft delete leaves a row the later sync-status pictures would count); an animal with no collar and a library-only tag, written for the link picker and removed afterward; `awaitCameraSettled` and the card-by-widget readiness check from task 11.319; one `capturing <name>` line per picture; and a `guarded` wrapper so one block that throws costs its own pictures and not the run (the first run lost 24 states behind one finder that matched nothing).

**The video pilot.** `integration_test/screenshots/record_video.sh` regenerates it: it boots the iPhone 17 Pro Max simulator, runs `video_test.dart` (the same script, slower), starts `xcrun simctl io ... recordVideo` when the test prints `VIDEO_START` and stops on `VIDEO_STOP`, then shrinks it with Apple's `avconvert` (there is no ffmpeg here). **The file is `/Users/mws22/Developer/tritrack/Claude outputs/take-on-map.mp4`: 17.1 seconds, 588 × 1280, 749 KB (budget 2 MB), no audio track at all.** The still first frame for readers who do not play it would be `take-on-map.png`, which the clip begins on. **Not committed and not embedded on any page**, so there is no video shortcode yet either. Two things in the clip are not the app's: the green crosshair the test binding draws where it holds its finger (the same one the bearing-drag picture discloses) and the simulator's own status bar, whose clock reads 1:35. The 2.3 MB uncompressed recording is beside it as `take-on-map-raw.mov`.

**Decided overnight without Michael**
1. **Took `/w-31`'s three Position pictures** into this task rather than leaving them outstanding.
2. **Wrote a short new section on *Your tags*** ("Putting a tag on an animal": the link picker, the *Tag went on* date, Quick add), because the guide did not mention either feature and a picture of something the page never describes would be a puzzle. Every quote in it is checked. `/w-33` is told to rewrite this page, so it should treat the section as a first draft.
3. **Copied all 52 images per profile into the site, not only the changed ones**, which is what `--accept` writes (a second 30-minute run would have produced the same files). 138 of the 156 differ from what was committed; the other 18 were identical.
4. **Left one image with a known flaw:** `iphone-6.1/take-on-map-released` hit its 60-second ceiling because **one logical pixel at the very bottom of the map was a tile short**. I looked: it is a pale strip a few pixels deep above the button panel, and the other two profiles drew completely. I did not re-run for it.
5. **Two dates in the new pictures are the day they were made**, because the app reads `DateTime.now()`: the countdown row (`30 days left (2026-10-31)`) and the Quick add / link date card. They will differ on every regeneration; the captions of the countdown and the date card say so where it matters.
6. **Kept the closing `Partial` and left this task's command file in place**, so a window that is told the video is approved can finish it.

**Findings for the code stream** (none fixed; the first and last are the most likely to matter)
1. **On the iPhone 6.1 size, the owner's countdown row is cut off mid-sentence:** *"Export from ⋮ before then, or cancel f…"*. The words that tell an owner they can cancel are the ones lost. The other two sizes show the whole sentence. Read it in `iphone-6.1/projects-countdown.png`.
2. **On the iPhone 6.1, the "+" button sits over the last row's controls** in the *Deleted from your devices, still on the server* section: the Restore button is partly covered and the three-dot menu is hidden under it, and there is nothing further to scroll to. It does not happen on the 6.9-inch phone. I have not tried to reach the menu by hand, so whether it can be reached at all is unconfirmed. `iphone-6.1/projects-deleted-section.png`.
3. **A debug-build crash while opening Take on map, which I worked around and did not fix:** with the More tab left on a screen that has a floating button (Animals, Projects, Tag Library) and the Map tab's own "+", opening Take on map raised *"There are multiple heroes that share the same tag within a subtree"* twice, on open and on close, in the harness. Both buttons use Flutter's default hero tag. **A release build does not run that assertion, so nothing is known to be wrong on a phone**; it would show in Michael's debug logs. The harness now goes to the More menu first.
4. **The seeded Sage estimate carries the caution *"Solver did not fully converge — treat this estimate as provisional"*** with five bearings of decent spread, and the `position-cautions` picture shows it, so the guide's one picture of a caution is a convergence warning rather than a geometry one. I do not know whether five bearings that spread should converge. `/w-31`'s validation table says the clean example converges in 8 steps, so this deserves a look from whoever owns the solver.

**For the planning session**
1. File code tasks for findings 1 and 2 (the cut-off countdown sentence and the "+" over the last row on the 6.1-inch phone) and decide whether finding 3 (the hero-tag assertion in debug builds) and finding 4 (the convergence caution on the fixture) need tasks.
2. `/w-33` and `/w-34` can use the new pictures. Names: `take-on-map`, `take-on-map-released`, `delete-project-dialog`, `projects-countdown`, `projects-deleted-section`, `sync-project-deleted`, `link-tag-picker`, `link-tag-confirm`, `quick-add`, `quick-add-review`, `position-cautions`, `position-legend`, `position-past-estimates`. **`/w-33` should rewrite *Your tags*' new section**, which is a first draft written to give the Quick add pictures somewhere to sit.
3. When Michael has watched the video: close this task and give the leftover (commit the clip, add a `video` shortcode with the `take-on-map` picture as its poster, place it on *Recording a bearing*) **a new number**, since a closed task's number is closed. Or tell Michael to say no, and the clip stays an uncommitted file.

**For Michael**
1. **Watch `Claude outputs/take-on-map.mp4`** (17 seconds, no sound). Decide whether it goes on the site; it is not committed and no page refers to it. Tell the planning session your answer.
2. Look at three pictures on the built site or in `website/static/screens/iphone-6.9/`: `take-on-map-released.png`, `projects-countdown.png`, `quick-add-review.png`.
3. Push when ready; nothing has been pushed (`52925be` and the comms commit after it).

### Task `/w-31` — 2026-10-01 — commit `4df499d` — Partial

**The guide now has a page on the Position tab, and a theory page explaining how the estimate is calculated, held as a draft for Michael's review.** Run unattended overnight. `Partial`, stopped at the line the brief set: theory page committed with `draft: true`, waiting for Michael to read it. `hugo` builds clean with and without drafts (the draft is absent from the normal build). `check_app_quotes` shows 13 failures, **the same 13 as before this task**, checked by running it on `HEAD`'s content and comparing. They are task 11.320's broken quotes, assigned to `/w-33`. None are on the new pages: 297 quotes, up from 294 before the how-to page's additions.

**What changed**, all in `website/`:
- New `content/docs/estimating-a-position.md` (how-to, published). It covers choosing the animal; which bearings are listed and which are ticked when you arrive (six hours and 50 km from the newest bearing); unticking for one estimate versus *Exclude from estimates…* in the Log for good; the rays, wedges, dot and 95% ellipse; every caution string with its threshold; resizing and closing the panel; *SAVE POSITION*, the viewer sentence, and past estimates with UNDO. Every quote is read from `position_estimation_screen.dart` (and `log_screen.dart` for the exclude label).
- New `content/docs/how-the-estimate-is-calculated.md` (theory, **draft**). It gives the assumptions, the projection, the von Mises model and likelihood, the iteration (Eq. 2.6), the starting point and stopping rule, the concentration, the covariance and ellipse (Eqs. 2.7–2.9, 95%, k = 5.991), why not to average the crossings, what each caution measures, a validation table, where TriTrack differs from the paper, a methods-section sentence, and references. Every equation and number is read from `lib/localization/`, and the source files are named in an HTML comment at the top of the page, which the build drops.
- **Math rendering:** `layouts/_markup/render-passthrough.html` and a passthrough block in `hugo.toml`. Hugo turns `$…$` and `$$…$$` into MathML when it builds, using the KaTeX that is compiled into Hugo itself (`transform.ToMath`). **Cost:** one 20-line template, about 10 lines of config, and 9 lines of CSS so a wide formula scrolls sideways on a phone. No script, stylesheet or font is sent to readers, there is no CDN, and nothing is newly pinned beyond the Hugo version already pinned. A formula KaTeX cannot read fails the build. **Not checked by eye:** the browser extension was not connected, so nobody has seen the formulas drawn. The build output contains 53 `<math>` elements and no `<script>`.
- `sync.md`: *Project deleted* is now described as gray, per task 11.319, which made it `SyncSeverity.quiet` in `sync_status_presentation.dart`. I also added it to the page's list of gray states, with its glyph (still the exclamation-in-a-circle, `Icons.error_outline`).
- `hugo.toml`: the "six-page site" comment now names the parts of the site rather than a count.
- `recording-a-bearing.md`: one sentence said a bearing is left out of estimates "on the position screen, with its own mark on the row". The lasting version is in the Log, so the sentence now names both places and links the new page. `docs/_index.md` now says nine flows. `how-it-works.md` links the new how-to page.

**Validation numbers** (theory page). TriTrack's values come from running `LenthSolver.solve` on exactly the inputs `test/localization/lenth_mle_test.dart` uses. The "published" column is **what that test file records from Lenth's Tables 1–2. I do not have the paper and did not check it against the paper.** Seven bearings: 7.228, 1.981 (published 7.23, 1.98); standard errors 0.1557 and 0.1559 (0.156 each); correlation 0.6640 (0.664); distance from truth 0.349 (0.349); 8 steps (the test comment gives the paper's 7). With the reflected bearing: 5.871, 1.134 (5.87, 1.13); standard errors 1.507 and 1.753. The test comment gives these as "~1.49/1.73", and the page says "about". The test checks the eight-bearing standard errors only as above 1, not against those numbers.

**Where the brief's spec did not match the code (entry 109):**
1. The brief said the code inverts the von Mises function for κ directly where the paper approximates. **It does not.** `_besselRatioInverse` uses Fisher's (1993) three-piece approximation. The page says that, names it as a departure from Lenth's Eq. 2.10, and does not claim an exact inverse.
2. The brief said to describe "the intersections layer, if it is user-visible". **It is not.** `BearingIntersections` is used by no screen, and the page says TriTrack does not show the crossings.

**Decided overnight without Michael:**
1. **Links to the draft are held in HTML comments marked `PUBLISH-WITH-THEORY`**, one in `estimating-a-position.md` and one in `how-it-works.md`. A link to a draft page is a 404 on the live site. Publishing the theory page is therefore one front-matter line plus moving those two sentences out of their comments. The page's own top comment says so.
2. **No screenshots built and the harness not run.**
3. **Repository paths stay out of the visible text** (`hugo.toml`: nothing that should not be public). The page says "a test in TriTrack's code" and names the file only in the source comment.
4. **One statement is from my knowledge of the paper, not from the code:** that Lenth also describes robust estimators that give a stray bearing less weight, and that TriTrack implements only the maximum-likelihood one. The second half is true of the code (it is "the clean data case" in `lenth_mle.dart`). Michael should confirm the first half against the paper.

**Findings for the code stream:**
1. **Two bearings give a position with no ellipse, nothing on screen says why, and saving it records an ellipse of 0×0 m.** Measured: with two bearings that cross, `LenthGeographic.solve` returns an estimate, κ = infinity, no covariance, and only the `nearSingular` warning. That warning has no sentence in `warningMessagesFor`, so no caution appears. `_save` then writes `semiMajorAxis: result.ellipseSemiMajorMeters ?? 0`, so Past estimates lists it as "ellipse 0×0m". Anyone reading the saved record or a backup sees a perfectly precise position. The guide now says so plainly. **Ask the planning session to file a code task:** a caution for an estimate with no ellipse, and a stored "no ellipse" rather than 0 × 0.
2. **Smaller, and a question rather than a defect:** κ is estimated from residuals with no allowance for the two fitted coordinates, and the ellipse is scaled with a chi-square quantile that treats κ as known. With three or four bearings the ellipse is therefore optimistic. The theory page says so. Whether the app should widen it (for example with an F-based scale) is a decision for Michael and the planning session, not a bug.
3. **A question:** the spreadsheet export (`data_export_screen.dart`) writes no file of saved position estimates. Somebody writing a methods section would want them. Is that deliberate?

**Pictures wished for, for `/w-32`:**
1. `estimating-a-position.md`, *The cautions*: the cautions sheet open over the Position tab with two or three cautions. It shows that cautions are words and do not block saving.
2. Same page, *Read the map*: the legend card open, which shows the included, excluded and estimate key.
3. Same page, *Save it*: the past-estimates sheet with a saved estimate.

**For the planning session**
1. Turn finding 1 (two-bearing 0×0 ellipse) into a numbered code task.
2. Decide whether finding 2 (the small-sample ellipse) and finding 3 (estimates not exported) need tasks.
3. Add the three pictures above to `/w-32`'s list if Michael wants them.
4. When Michael approves the theory page, its publication is: remove `draft: true`, move the two `PUBLISH-WITH-THEORY` sentences out of their comments, then rebuild. `/w-33` should leave the theory page alone (its brief already says so). It may tighten the how-to page, which is published.

**For Michael**
1. Read the theory page: `hugo server -D --source website`, then open *How the estimate is calculated* under the Guide. Check especially that the equations draw properly in your browser (nobody has looked at them), and **check the "Published" column of both validation tables, and the robust-estimators sentence, against your copy of Lenth (1981).** I took those numbers from the test file, not the paper.
2. Tell the planning session to publish it, or what to change.
3. Push when ready. Nothing has been pushed.

### Task `/w-28` — resolved 2026-09-30 by the planning session

`Done`, run overnight. **Michael has three decisions** (his list above): read the two pages as an
outsider, choose pictures, and whether to publish a contact email. The `hugo.toml` comment is folded
into `/w-31`. The pictures wait for his choice across all three overnight tasks.

### Task `/w-28` — 2026-09-29 — commit `0658eb6` — Done

**The front page no longer says "under construction": it now says why a wildlife biologist would want TriTrack, and a new page walks a field day.** Run unattended overnight, so no screenshots were built (Michael's ruling); the two pages reuse three pictures that already exist. `check_app_quotes` PASS (272 quotes, up from 261) and `hugo` builds clean. This task's command file was removed with `git rm`, and `command_file_staleness_test.dart` passes.

**What changed**, all in `website/`: `content/_index.md` rewritten (the why); new `content/how-it-works.md` (the how: night before, take a bearing, see the estimate, sync, export, each linking to the guide page behind it); `hugo.toml` gains a "How it works" menu entry. No page per feature.

**The five pain points, checked against `lib/`:**
1. Bearings transcribed from paper: **survived.** Each bearing is saved on the phone with time, position, direction, quality.
2. No fix until back at the truck: **survived, and it was the unverified one.** `position_estimation_screen.dart` calls `LenthGeographic.solve` on the phone over the selected local bearings; nothing in `lib/localization` touches the network. Two bearings from different places give an estimate; one gives only a ray; near-parallel and poor-geometry cautions are real strings.
3. No cell service: **survived with a qualification.** Recording and the estimate need no network; map tiles must be downloaded beforehand (Pre-Trip Checklist and Offline Data exist). The page says so rather than claiming a fully offline map.
4. Several people, several datasets: **survived, phrased conditionally** ("if your team has a project server"), since sync needs a server the guide describes as separately set up.
5. Which collar on which animal: **survived** via the deployment model (tag, animal and dated link), the guide's tags page and the export's recorded-versus-current tag columns.

**Decided overnight without Michael:**
- The page asks the reader to read the guide and use the Support page to get in touch. It says plainly, twice, that the app is not available to download yet, and that the guide is written from an iPhone with nothing on Android. No download, TestFlight, availability or timeline promise anywhere.
- No "our team" or "we": "developed by one person in the Dynamic and Active Systems Lab at Northern Arizona University", which `support.md` already says publicly. No testimonials, counts or logos.
- The "how it works" page is a top-level page in the menu (weight 5), not under the guide.
- The estimate is described only as "calculated on the phone", with no accuracy claim.

**Screenshot wish-list (nothing built or run tonight; pages currently reuse `position`, `record`, `map` from the iPhone 6.9 set):**
1. The Record tab with the round *Take on map* button next to RANGE, so the front page can show the sweep feature it mentions in words. The existing `record` shot may already show it; check.
2. The Take on map screen mid-sweep, wedge crossing earlier bearings. It is the most persuasive single picture for a telemetry person and the only one showing the crossing.
3. The Pre-Trip Checklist, to back the "works with no signal" claim (the harness may already have it as `checklist.png`; if so, just add it to the how-it-works page).
4. The Sync Status screen or `joined-sync-indicator`, for the "several people" claim (existing shots, not yet used on these pages).

**For the planning session**
1. Nothing to add to tasks. Note `hugo.toml` still says "six-page site"; it now has seven top-level pages plus the guide, which is a comment only.

**For Michael**
1. Read the two pages on the site as an outsider; especially the "Where it stands" section of the front page, which is the honest no-download wording I chose.
2. Decide which of the wish-list pictures to add (items 3 and 4 need no new capture).
3. Decide whether the closing "get in touch" is enough, or you want a direct email address (I did not add one; the only contact route published today is the site's repository, via Support).
4. Push when ready; nothing has been pushed.

### Task `/w-29` — resolved 2026-09-30 by the planning session

`Done`, run overnight. The pictures wait for Michael's choice; the "no picture yet" sentence goes
when one is added.

### Task `/w-29` — 2026-09-29 — commit `d06afe2` — Done

**The Record page of the guide now explains *Take on map*, the round map button beside RANGE.**
Run unattended overnight, so no screenshots were built (Michael's ruling). `check_app_quotes` PASS
(261 quotes, up from 247) and `hugo` builds clean.

**What went in**, as a new subsection *Taking the range on a map* right after the RANGE and POINT
text in `website/content/docs/recording-a-bearing.md`, every quoted label read from
`bearing_map_capture_screen.dart`, `map_furniture.dart` and `observation_logging_screen.dart`:
what it is for (seeing the sweep cross the day's earlier bearings before committing); which
bearings it draws (same tag, today, everyone on the project; other collars, other days, notes,
no-direction records and deleted ones left out; on a collar-swap day the previous animal's are
left out); the no-tag line; how to take it (*HOLD TO SWEEP*, the map ignoring touches while held,
the readout, the 180-degree warning); *Confirm* (fills the form, saves nothing, *SAVE
OBSERVATION* still saves), *Retake*, *Cancel*; the two orientations (*North up*, *Facing up*,
remembered, pauses on drag, *Back to me*, north arrow); the shared *Terrain / Street / Satellite*
switch; that the button is absent with no compass. The old bright/faint key card is not described.

**Second-hand, not read from a widget:** "from everyone on the project", "on a collar-swap day the
previous animal's bearings are left out", the map ignoring touches while held, and "remembers your
choice on that phone" come from the 11.315 and 11.317 comms entries and the screen's doc comments.
Nobody has looked at any of it on a phone in this task. The guide's screen-reader label
*Take on map* is real (`semanticLabel` and the title).

**Decided overnight without Michael:** no screenshots built; the page says there is no picture yet
(the sentence goes when a picture is added). I did not describe the Position Estimation screen's
own map-type switch (11.317 says it is not yet the shared one).

**Screenshot wish-list (nothing built or run tonight):**
1. `recording-a-bearing.md`, *Taking the range on a map*: the map before a sweep, earlier
   bearings drawn to the edge and the thin pointing line. Shows the crossing the text describes.
2. Same section, after release: readout with Cancel / Retake / Confirm. Shows that Confirm is one
   of three and that nothing has saved.
3. Same section, the Record screen with the round map button beside RANGE, so a reader can find it.
   (The existing `record` shot may already show it; check before adding.)

**For the planning session**
1. Nothing.

**For Michael**
1. Decide which of the three pictures above, if any, to add; then remove the "no picture of it in
   this guide yet" sentence at the end of the new subsection.
2. Read the new subsection once on the site, against the app if convenient.
3. Push when ready; nothing has been pushed.

### Task `/w-27` — resolved 2026-09-30 by the planning session

`Done`, run overnight.
1. ***Project deleted* drawn red:** the planning session's call is gray, like *no longer on this
   project*, since nothing is wrong on the device. That is task 11.319 item 3, unless the red turns
   out to be a written, deliberate choice. `sync.md`'s sentence changes in `/w-31`.
2. **The five pictures** wait for Michael's choice.

### Task `/w-27` — 2026-09-29 — commit `27b9779` — Done

**The guide now says that a project can be destroyed on the server, what a member sees when it
happens, and how to get out with the records; and its stale amber paragraph and its silence about
long absences and restored servers are fixed.** Run unattended overnight, so no screenshots were
built (Michael's ruling); the pictures I would add are listed below for a morning decision.
`check_app_quotes` PASS (247 quotes, up from 208) and `hugo` builds clean.

**What went where, all read out of the widgets rather than out of comms entries:**

1. **`projects-members-and-roles.md`**, a new section *Deleting a project has two meanings, and they
   are two separate acts*: the app's *Delete project* versus *Delete from server…*; who may (owner
   only, grayed with a reason for everybody else); that it destroys every member's records; the
   countdown, its being set by the server's clock, and every member seeing it and getting *Export
   records*; *Cancel scheduled deletion*; *Delete immediately…* with its second dialog and *Remove
   now*; what "removed" does and does not promise about backups (the word the app's test forbids
   is not used anywhere); that phones keep their copies. Then the two "deleted" sections at the
   bottom of Projects (*Deleted from your devices, still on the server*, and *Deleted here, not yet
   on the server*), the member's "an owner deleted it" message, *Restore* and its confirmation
   (which says a scheduled deletion is canceled), and the restored-project notice. Also: Members is
   now on the More tab beside Animals; one row added to the roles table; the older-server sentence
   on the deleted section (heading plus one sentence, no rows, two causes and neither picked).
2. **`sync.md`**: *The project was deleted from the server* (heading *Project deleted*; nothing on
   the device is lost; export is the way out), *Away too long* (the more-than-two-years state and
   that the app has no step to put the phone back in sync), *The server does not offer what the
   app asked for* (two causes, neither picked), *The server's records were replaced* (starts over
   from the beginning, nothing deleted). **The amber "refusing access" paragraph is rewritten** to
   name no cause and give both remedies, matching `_advice` in `sync_status_screen.dart`.
3. **`joining-a-project.md`**: one paragraph on the address refusal. It says the address is valid
   but this server's mail path will not carry it, not that the address is invalid.

**A green quote check proved nothing here, as the brief said.** The new quotes are checked (208 to
247) but the check cannot say whether the guide ought to quote something it does not.

**Claims that came from a comms entry or plan text and not from a widget, so Michael or the
planning session should know they are second-hand:**

- "A server left on its default gives 30 days" (from task 11.290's comms; the dialog itself only
  shows whatever the server sends).
- "More than two years" for the away-too-long state (the widget sentence has no number; it is from
  the task brief and the server's 730-day window in `server/README.md`).
- That an owner's *Delete project* on a published project reaches the server as a hidden deletion
  and hides it for every member, with the records kept (task 11.289's comms).
- The colors: *Project deleted*, *Offline too long* and *Server doesn't offer this* are all in the
  same red state as `versionRefused` in `sync_status_presentation.dart`. Nobody has looked at them
  on a phone in this task.

**Screenshot wish-list (nothing built or run tonight):**

1. `projects-members-and-roles.md`, the first *Delete from server…* dialog: the only picture that
   shows the three buttons and the grace period. Needs a published project on a server.
2. Same page, a Projects row mid-countdown (tinted, "N days left"): shows what every member sees.
   Needs a server.
3. `sync.md`, the *Project deleted* Sync Status screen: the other side of the act. Needs a server.
4. Same page, the *Deleted from your devices, still on the server* section at the bottom of
   Projects: Restore and the menu. Needs a server.
5. `projects-members-and-roles.md`, the More tab showing Members beside Animals: no server needed,
   cheapest of the five.

**Decided overnight without Michael:**

- **No pictures**, per his ruling; nothing is claimed that a picture was needed to show.
- Wrote no new diagram. A diagram of the two paths (schedule versus immediately) may earn its place
  beside the dialog text; the brief did not ask and inventing one unreviewed seemed worse.
- Quoted the buttons by the widget's current names *Schedule delete* and *Delete immediately…*,
  and *Remove now* on the second dialog. The first-report *Delete now* is not used anywhere.
- **The "Deleted here, not yet on the server" section** got a short paragraph beside the other
  deleted section, since a reader meets both and they mean different things.
- Described the two-year state as "more than two years" without a threshold in the app's own
  words, because the app's sentence carries no number.
- Closed `/w-27`'s command file (`git rm`) in this task's second commit, since the entry says
  `Done`. If you want to hold it open for the missing pictures, that is a `/w-` task of its own.

**Findings for the code stream:** none that is a defect. One question: **`Project deleted` is drawn
red like a fault** although the app's own sentence says nothing is wrong on the device and
membership-ended, the nearest neighbor, is gray. Deliberate or not, it is the planning session's
call; the guide says "red, because nothing further will reach that project, not because anything
was damaged".

**For the planning session**
1. Decide whether the *Project deleted* state should be gray like *no longer on this project*
   (see above). If yes, file a code task and tell the content lane to change one sentence in
   `sync.md`.
2. Move the pictures in the wish-list to a task if Michael wants them; they need a running server.
3. `/w-27`'s command file is deleted in this task's second commit (its entry says `Done`).

**For Michael**
1. Push when you are ready.
2. Read the new section on the Projects page once, especially *What removing does and does not
   promise*, since it is the sentence a landowner might quote back.
3. Say which of the five pictures you want.

### Task `/w-30` — resolved 2026-09-30 by the planning session

`Done`. **Findings 1 and 2** (identical labels on the estimate and the truth point, and a tap that
opens the wrong card when they are close) are **task 11.319**, items 1 and 2. That task also takes
the map-type switch's pale labels, which the planning session saw in the old pictures. **The one
unreproduced red** (`map_screen_test.dart`, the navigation panel's color) is a trip-wire: if it
fails again in any run, it gets a task.

### Task `/w-30` — 2026-09-29 — commit `80525d4` — Done

**The six Map-tab pictures now show the day's bearings in the clear middle of the map instead of
as fragments under the buttons, and the purple "visible from here" overlay is gone from all of
them.** Re-shot at all three sizes (iPhone 6.1, iPhone 6.9, iPad 13); I looked at all eighteen
before committing. Only those eighteen images were copied in — the same runs also moved `more`,
`record` and (barely) `compass` by 0.85–1.6%, which is older drift this task did not cause and
did not accept.

**The Map-tab pictures, found from the routes and the tap-driven sequences in `shots.dart`:**
`map`, `truth-point-panel`, `truth-point-edit` (the correction dialog sits over the same map),
`bearing-selected`, `bearing-dragged`, and `joined-sync-indicator`. No other route is a map.

**What was wrong, measured.** The map opens on the person's own position at about 200 m across;
the day's bearings are 1–2 km away, so they showed only at the edges. The harness had never asked
where the map's own controls are.

**What changed.**

1. **Framing.** New `integration_test/screenshots/map_framing.dart`. It reads the map's own keyed
   blocks off the screen (`map-right-controls`, `map-bottom-band`, `map-record-fab`,
   `map-bottom-panels`, plus the map-type switch) and fits the camera to Sage's five morning
   bearings (each origin and its 400 m tip) plus the estimated position and the truth point, with
   padding equal to those measured rectangles. **Then it projects every one of those points onto
   the screen and checks it against the same rectangles; a miss is a capture error, not a
   picture.** On all three sizes: 12 of 12 points clear.
2. **The viewshed is out of all six, and that decision is written down in the file.** No guide
   picture is about the viewshed (the site's only mention of it is one line in `docs/_index.md`),
   and in each of these it hid the thing the caption is about. **If a page is ever written about
   the viewshed, it needs its own picture and its own framing.** The run still waits for the
   viewshed to finish computing before it switches the layer off (`awaitViewshedComputed`), so
   the 72-tile terrain download is over before the shutter, which is the `/w-09` defect in
   reverse. The readiness conditions for the six states now require the overlay to be absent
   (`_viewshedOut`).
3. **The two truth-point pictures are framed tighter than the rest** (zoom 15.5, the truth point
   and the estimate only). At the wide framing the two markers are 13 points apart, the app's tap
   radius is 24, and the first run's tap on the truth point opened the *estimate's* card. A
   picture whose subject is a marker has to be at a zoom where a finger can tell it from its
   neighbor. **Cost: the bearings are mostly out of those two frames**, and at the right edge a
   piece of one bearing shows next to the "+" on `truth-point-panel` (iPhone sizes). They are not
   the subject of those pictures; say so if you would rather they were.
4. **The drag search's four fixed margins** (40 in from the left, 80 from the right, 130 down, top
   55%) are replaced by the measured clear area. They were right for an unframed map and wrong for
   one framed on the bearings.
5. **Caption/prose fixes** in `comparing-bearings-on-the-map.md`: the crosshair's color was named
   ("blue") and is mint green in the new iPad picture, so the color is no longer named; and the
   note saying the dragged bearing "is a short one near the top corner" was true of the old
   framing and is not of this one — it now says the tool chose a bearing with room to drag.
   `truth-points.md` and `sync.md` captions describe the panel and the icon, not the frame, and
   needed nothing.

**Item 3 of the brief — the two identical "Sage · 150.284 MHz" labels.** They are two different
markers, both the app's own drawing. **The hollow round ring is the estimated position** (where
the bearings say the animal is) **and the hollow square is the truth point** (where somebody
found it). Both are labeled with the tag's name and frequency and nothing else, so the two labels
look like a duplicate. In the seeded data the two are 100 m apart, so at any zoom that also shows
the bearings the labels overlap. This is not the picture's fault and I did not hide it.

**Findings for the code stream**

1. **The estimated-position marker and the truth-point marker carry identical labels.** Ask the
   planning session to file a task: a person reading the map cannot tell which label is which
   without tapping. A word in each label (the way the info card already says "Truth point ·" and
   "Estimated position ·") would settle it. Check `_EstimateMarker` and `_TagLocationMarker` in
   `map_screen.dart`.
2. **When the estimate and truth point are closer than about 24 points on screen, tapping the
   truth point opens the estimate's card** (found on the first run at the wide framing). The two
   markers overlap and the app picks one. Worth a look together with item 1.

**Notes for the next person who touches the map harness**

- The Layers sheet is a lazy list and the Viewshed switch is its seventh row, so it must be
  scrolled to before it is read. It is switched off through the switch's own callback rather than
  a tap: two tap-based versions landed on a neighboring row while the sheet was still settling.
  It is closed by popping its route, found by the sheet's type, because its title scrolls out of
  the tree.
- The map keeps its state across tab changes. `map_framing.dart` recognizes a map it has already
  handled by the identity of its `MapController`; the first version asked the Layers sheet
  instead and was fooled by a map that had a result but had not yet turned the layer on.
- `readiness.dart` gained `awaitViewshedComputed` and `_awaitCheck`; `awaitReady` is a thin
  wrapper over it. No state was left without a readiness condition.

**One unrelated red, reported because the pre-commit suite hit it once.** The first commit
attempt failed the suite on `test/features/map/map_screen_test.dart` ("the navigation panel is
drawn in the navigation line's own colour", an error raised after the test had finished). That
file passed three runs out of three on its own, this task changed nothing under `lib/` or
`test/`, and the identical commit passed the suite on the second attempt. **One observation, so I
am not calling it a flake** — it is a failure that did not reproduce. If it recurs, that test
deserves a look.

**For the planning session**
1. File a task for the two identical labels (finding 1) and, with it, the tap that picks the wrong
   marker when they overlap (finding 2).
2. `/w-30`'s command file is deleted in this task's second commit (its entry says `Done`).

**For Michael**
1. Push when you are ready (`80525d4` and the comms commit after it).
2. Open the six pictures once on the built site, or in `website/static/screens/iphone-6.1/`, and
   say if you want the truth-point pair to show more bearings (item 3 above).

### Task `/w-26` — resolved 2026-09-19 by the planning session

**`Done`, and Michael confirmed it in the browser: *“w.26 looks better.”* All five are under the
target with numbers, not impressions.**

1. **It found the second cause, which the brief did not name.** `rankdir=TB` alone would not have
   done it: three diagrams had **a node fanning out to two or three others, or a side-annotation
   pinned onto the same rank with `{rank=same}`** — both of which make a diagram wide again after
   the turn. Restructuring them into one vertical column, with `constraint=false` on the edges that
   would otherwise force a rank and an invisible edge setting the order, is the actual fix. **A task
   that had only done what it was told would have turned five diagrams and reported two failures.**

2. **The long unwrapped note line was the third.** On two diagrams the width was being set by an
   explanatory note, **not by the diagram's own chain** — so the thing making the picture unreadable
   was the sentence next to it. Rewrapped with `\l`, matching how every other multi-line label in
   those files was already written.

3. **Widths: 514→301, 716→175, 522→322, 684→228, 908→320.** All five under the 335px column, all
   read from `dot`'s own `viewBox` rather than estimated, and the column width read from
   `style.css` rather than taken from the brief. **No exception needed to be named**, which the
   brief explicitly made room for.

4. **The text-size table is the part that proves it.** Because every diagram is now *narrower* than
   the column, the browser scales each one **up** — so node text lands at 13.5–24.9px against the
   site's 16px body copy, where it had been scaling **down** to roughly 6px. **The defect is
   measured as gone, not asserted as fixed.**

5. **It carried task 11.284's stale quote and checked the surrounding prose** — finding none,
   because that paragraph already used `±12 m` rather than the word. **A nil check, reported.** It
   also fixed two British spellings in a `.dot` header comment it had open, which is the right
   amount of opportunism.

**`/w-26`'s command file is deleted with this resolution.**

### Task `/w-26` — 2026-09-18 — commit `5554135` — Done

**Michael looked at all five diagrams in a browser and found they were unreadable on a phone —
all five were flowing left to right, so a phone-width column scaled them down to fit, and
scaling an SVG shrinks its text along with everything else. Fixed by turning all five to flow
top to bottom and getting each one's own rendered width under the phone column's width, so the
browser stops downscaling them at all.**

**The measured target.** `website/static/style.css` sets `main { max-width: 44rem; padding:
1.5rem 1.25rem; }`, and the body font is `16px`, so `1.25rem` of padding on each side is 20px.
A 375px-wide phone (iPhone's common CSS width) therefore gives **335px** of content column —
read from the CSS, not assumed.

**Before / after — each diagram's own rendered SVG width, from `dot`'s own `viewBox`, not
estimated:**

| Diagram | Before (LR) | After (TB) | Under 335px? |
|---|---|---|---|
| `device-and-server` | 514px | 301px | Yes |
| `join-request` | 716px | 175px | Yes |
| `sync-states` | 522px | 322px | Yes |
| `tag-animal-deployment` | 684px | 228px | Yes |
| `tag-library-copy` | 908px | 320px | Yes |

**All five got under the target — none needed to be named as an exception.** Three of the five
(`device-and-server`, `sync-states`, `tag-library-copy`) had a node that fanned out to two or
three others, or a side-annotation forced onto the same rank as its subject with `{rank=same;
...}` — both of those are exactly what makes a diagram wide again even after `rankdir=TB`, so
each got restructured into a single vertical column: the real, labeled edges kept their
`constraint=false` where needed so they don't force a rank, and an invisible edge between the
otherwise-unconnected nodes sets the vertical order. `tag-animal-deployment`'s and
`tag-library-copy`'s explanatory note boxes also had one long unwrapped line each (the wide
line, not the diagram's main chain, was what was forcing their width past target); both are
rewrapped with `\l` into short lines now, matching how every other multi-line label in these
files was already written.

**Text size, now that nothing is being scaled down.** Since every diagram's intrinsic width is
now *at or under* 335px, the browser's `width: 100%` on the inlined SVG scales each one *up*
slightly to fill the column rather than down — so no diagram's text ever renders smaller than
the size set in the `.dot` source, and most render a bit larger:

| Diagram | Scale factor (335 ÷ width) | Node text (13pt → px) | Edge/note text (11pt → px) |
|---|---|---|---|
| `device-and-server` | 1.11× | 14.5px | 12.2px |
| `join-request` | 1.91× | 24.9px | 21.1px |
| `sync-states` | 1.04× | 13.5px | 11.4px |
| `tag-animal-deployment` | 1.47× | 19.1px | 16.2px |
| `tag-library-copy` | 1.05× | 13.6px | 11.5px |

The site's own body copy is 16px. Every diagram's node text now lands at or above that
(13.5–24.9px); the smaller edge/note text stays close to it (11.4–21.1px) rather than the ~6px
it was scaling down to before. `join-request`'s figures look large in the table because it was
already narrow before this task (a plain four-box chain, no fan-out) — checked the rendered PNG
by eye and it reads comfortably, not oversized, because it's the only diagram on its page and
has nothing beside it to look mismatched against.

**Carried `truth-points.md`'s stale quote (item 4 of the brief).** Its `{{< app >}}` pin-precision
note said *"…commonly off by a few metres"*; the app string — the `usingPin` helper text in
`_GroundTruthBlockState`'s `build` method, in
`lib/features/observations/screens/observation_logging_screen.dart` — has said **meters** since
task 11.284 (commit `fa0a010`). Fixed the quote; checked the surrounding prose for the same
spelling and found none — that paragraph already used the `±12 m` abbreviation, not the word.
Also fixed two pre-existing "colour" spellings in `sync-states.dot`'s own header comment while
editing that file (not new text this task introduced, but it's American-spellings-everywhere
territory per `CLAUDE.md` and the file was already open).

**Both themes checked**, the same way `/w-21` and `/w-25` did: substituted the real light and
dark `--fg`/`--muted`/`--link`/`--diagram-good`/`--diagram-bad` values from `style.css` into
each rendered SVG's own class selectors and rasterized with `rsvg-convert`, then sampled pixels
to confirm each diagram shows exactly the colors its own node classes call for (no diagram uses
a class none of the others already established; the restructuring only changed geometry and
edge direction, not which classes are on which nodes). Also opened several as PNGs by eye,
light and dark, to confirm the new vertical layouts still read correctly — `tag-animal-deployment`'s
note stays clearly separate from the tag → deployment → individual chain, `tag-library-copy`'s
"no edge back, no edge between the copies" is still true of the new shape, and `sync-states`'s
three curved edges out of "Waiting to sync" don't cross in a way that's confusing.

**Checks run (no CI — the hold until 1 October, per the brief):**

- `website/tools/render_diagrams.sh` — 5 diagrams rendered, no errors.
- `hugo --source website --destination <tmp> --minify` — 16 pages, no errors.
- `dart run website/tools/check_app_quotes.dart` — **PASS**, 208 quotes / 12 pages / 0 waivers
  (includes the corrected `truth-points.md` quote).
- `website/tools/selftest.sh` — PASS, 22/22.
- `dart analyze website/tools` — no issues.
- `flutter test test/documentation/rendering_verification_policy_test.dart` — green, 4/4
  (unrelated to diagrams; run because the brief asked for "the rendering-policy test" —
  confirmed by reading it that it checks the golden-file policy and the screenshot harness,
  neither of which this task touched).

**Findings for the code stream:** none.

**For the planning session**

1. Nothing to ask.

**For Michael**

1. **Git**: committed (`5554135`). Nothing here needs your review before pushing.
2. **A browser look at all five, on an actual phone width, would be worth doing once you're
   back near the site** — this task checked the numbers and the rendered PNGs by eye, but it
   is not a device.

---

### Task `/w-25` — resolved 2026-09-18 by the planning session

**`Done`. It decided the count instead of inheriting it, and it distinguished its own word-count
growth from `/w-21`'s rather than reusing that excuse.**

1. **Two, with a reason, is what the brief asked for and rarely gets.** Michael said *“a diagram or
   two”* and the brief deliberately refused to turn that into a number. The task argued it: the copy
   relationship and the device/server split are **different shapes** — one is a row duplicated and
   never reconverging, the other is which tables leave the phone at all — and one canvas carrying
   both would have had to drop the library's exception. **A count chosen and defended beats a count
   obeyed.**

2. **The `syncTables` list is the right authority and it used it.** The six things named on the
   phone were read off `sync_tables.dart`, **not off a page or a design doc** — which is also what
   makes the Tag Library's absence from that list a fact rather than a claim. **Leaving Deployments
   off was a judgement it stated**: it is the dated link the companion diagram already carries, and
   seven boxes crowded the picture.

3. **It checked `joining-a-project.md` against the new diagram and then decided not to add one
   there.** A nil decision, taken after reading, and reported. **The alternative — a third diagram
   because the brief mentioned three pages — was available and it did not take it.**

4. **The growth is explained differently from `/w-21`'s, and the distinction is real.** `/w-21`'s
   pages grew because two diagrams sat in front of ideas never stated. **These grew because the
   prose already explains both at length** — the picture gives an existing explanation a shape,
   so nothing was a candidate to cut. **That is a different sentence about a similar number**, and
   reusing the earlier excuse would have been the easy thing.

5. **Its theme check is the strongest yet.** It substituted the real light and dark token values
   into each SVG, rasterized, and **sampled pixels to confirm the expected colors are present** —
   rather than trusting a thumbnail. Worth copying the next time something has to be verified
   without a browser.

6. **The one thing it names that is now on Michael's list: nobody has looked at any of the five
   diagrams in a browser.** Not blocking, and the mechanism is the same one across all five — but
   **five generated pictures have shipped on the evidence of a rasterizer and a pixel sample.**

**`/w-25`'s command file is deleted with this resolution.**

### Task `/w-25` — 2026-09-18 — commit b27596b — Done

**Two diagrams, one on `managing-your-tags.md` and one on `sync.md`, both drawn with the same
Graphviz mechanism `/w-21` built — no new CSS, no new shortcode.**

**How many, and why — stated rather than assumed, per the brief.** Michael asked for a picture
of where a collar lives and a picture (or two) of phone-versus-server. I built **two**, not one:
the copy relationship and the device/server split are genuinely different shapes — one is about a
row being duplicated and never reconverging, the other is about which of several tables leaves the
phone at all — and a single picture trying to carry both would have had to either drop the tag
library's exception or crowd two unrelated arrows onto one canvas. Splitting them let each stay as
small as the three existing diagrams.

1. **`tag-library-copy`**, on `managing-your-tags.md`, above "The one thing to get right: a copy
   is a copy". Three nodes and a note: the Tag Library (device-only) and two projects' copies, each
   its own row from a `Copy from library` edge, with no edge back and no edge between the two
   copies. The note states the two directions explicitly — a library edit does not reach a copy on
   its own (`Apply this to your projects?` is asked, never automatic, and only an owner can accept
   it for their project), and a copy's own edit never reaches the library or any other project. Read
   from `CLAUDE_DOCS/TAG_COPY_ON_ADD_DESIGN.md` §0, §2.2 (the device-local library table, not in
   `syncTables`) and §2.5 (telling the user, in both directions) before drawing.

2. **`device-and-server`**, on `sync.md`, under "TriTrack works with no server at all". Three
   boxes: the phone (six project-scoped things, recorded there first, always), the Tag Library
   (device-local, no edge to the server at all), and the server (the same six, once synced, scoped
   per project, visible to teammates). The six named on the phone are Projects, Tags (a project's
   copies — deliberately not "the library"), Individuals, Bearings, Truth points, Position
   estimates: read off `packages/tritrack_sync/lib/src/sync_tables.dart`'s `syncTables` list
   (`projects`, `tags`, `individuals`, `observations`, `actualTagLocations`,
   `estimatedPositions`), the same source `CLAUDE_DOCS/TAG_COPY_ON_ADD_DESIGN.md` §2.2 cites for the
   library **not** being one of them. Deployments is left off the list on purpose — it is the dated
   link `tag-library-copy`'s companion diagram already covers the shape of, and putting seven items
   in one box started to crowd it.

**Both facts the brief named are on the page, not just implied by the picture.** The prose right
above the new diagram already says the app is complete with no server at all, and "everything on
this page applies once a device has been pointed at a server" sits right after it — the diagram
sits between the two sentences that already state both facts, rather than restating them a third
way. I did not touch `joining-a-project.md`'s prose; it already agrees ("Joining is the one thing
that cannot be done in the field... everything else... works with no connection at all"), and I
read it against the new diagram to check that before deciding not to add a diagram there.

**Word counts, measured the same way `/w-21` did (frontmatter stripped, `.split()`):**

| Page | Before | After | Net |
| --- | --- | --- | --- |
| `managing-your-tags.md` | 1379 | 1411 | +32 |
| `sync.md` | 2537 | 2582 | +45 |

**Both pages grew, and I did not try to round that away.** Unlike `/w-21`'s two diagrams that sat
in front of an idea the page had never stated, `managing-your-tags.md` already explains the
copy-and-push relationship in prose at real length just below where the diagram now sits (the
"correction or change" question, the owner-only push, the per-project push count) — the diagram is
a picture of that existing explanation, not a replacement for any of it, so nothing in that section
was a candidate to cut. Same for `sync.md`: the "no server at all" paragraph already stated the
underlying fact in one sentence: the diagram gives it a shape, not new information, and there was
no surrounding archaeology like `/w-24` found to also remove. Both nets are just the diagram markup
and captions.

**Checks run (no CI — the hold until 1 October, per the brief):**

- `website/tools/render_diagrams.sh` — 5 diagrams rendered (the 3 existing plus these 2), no
  errors.
- `hugo --source website --destination <tmp> --minify` — 16 pages, no errors.
- `dart run website/tools/check_app_quotes.dart` — PASS, 208 quotes / 12 pages / 0 waivers,
  unchanged (the two new diagram captions and the `.dot` labels are prose, not `{{< app >}}`
  quotes, and introduce no bare `"..."` or `**bold**` in `website/content/`).
- `website/tools/selftest.sh` — PASS, 22/22.
- `dart analyze website/tools` — no issues.
- `flutter test test/documentation/rendering_verification_policy_test.dart` — green, 4/4,
  unchanged (39 states × 3 profiles = 117 images; diagrams live in the gitignored
  `website/static/diagrams/` this test never looks at).
- **Both themes checked**, the same way `/w-21` did with no browser available here: substituted
  the real light and dark `--fg`/`--muted`/`--link`/`--diagram-good` values from `style.css` into
  each rendered SVG's own class selectors (`.node.highlight`, `.node.good`, `.node.wait`,
  `.node.note`) and rasterized with `rsvg-convert`, then sampled the pixels to confirm the expected
  colors are actually present rather than trusting the thumbnail by eye — both diagrams use only
  classes the existing three already established, no new CSS was written.
- Spellings: `library`, `device`, `color` all already American in the new `.dot` labels; no British
  spelling was typed.

**What this cost:** two `dot` renders (well under a second), a few `hugo build`s, the checks above.
No simulator, no Docker, no network. Graphviz and Hugo were already installed from `/w-21`.

**Findings for the code stream:** none.

**For the planning session**

1. Nothing to ask.

**For Michael**

1. **Git**: committed. This follow-up commit only fills in the hash above, same as `/w-13`,
   `/w-20` and `/w-24` did. Nothing here needs your review before pushing.
2. **A device/browser look would be worth doing once you're back near the site**, though it is not
   blocking — I'm confident in the mechanism (identical CSS classes to the three diagrams `/w-21`
   already shipped and you have not yet looked at those in a browser either, per that task's own
   note) but nobody has looked at any of these five diagrams in an actual browser, in either theme,
   at phone width. `website/tools/render_diagrams.sh` then `hugo server --source website` will show
   them.
3. **No CI ran**, per the standing hold until 1 October — everything above was verified locally.

### Task `/w-24` — resolved 2026-09-18 by the planning session

**`Done`. It found two more of the shape it was sent for, kept a British spelling on purpose, and
read a page's history before cutting a sentence.**

1. **Leaving one quote British is the best decision in this report.** `truth-points.md` quotes
   *“…commonly off by a few metres”* because the app still says it. **A guide that misquotes the app
   to look tidy is worse than an inconsistent page**, and the task named it rather than quietly
   fixing it — which is what turned it into task 11.284 instead of a silent divergence.

2. **Items 6 and 7 were not on the list and are the same shape.** Two more sentences explaining what
   the app used to do, on pages the sweep happened to touch. **The brief named five; the task read
   the surrounding prose and found seven.** Both were handled the way the brief asked for the five —
   keeping the useful half (a caveat against stale third-party documentation is still worth having)
   and cutting the archaeology.

3. **Reading the page's git history before cutting #5 is the right instinct.** The brief flagged it
   as possibly about data rather than versions. The task checked instead of guessing, found it was a
   fixed UI bug, and cut it. **Either answer would have been fine; guessing would not.**

4. **Its code-lane finding is task 11.284**, and it was more right than it knew — there are four
   sentences, not three. **The fourth is a second `hintText`**, which the guide never quotes, so only
   reading `lib/` could find it.

**`/w-24`'s command file is deleted with this resolution**, along with `/w-22`'s, which I should have
deleted a day ago and which had been turning the suite red for three tasks.

### Task `/w-24` — 2026-09-18 — commit 482f952 — Done

**Three things in one window, all against the tree task 11.283 left.**

**1. The quote 11.283 made stale.** `check_app_quotes` had exactly one red line, exactly the one
predicted: `website/content/docs/truth-points.md`'s *"Deleting one"* section quoted the old
*"…counting towards any accuracy check…"* sentence from `truth_point_edit_dialog.dart`. Updated to the new wording
*"It stops counting toward any accuracy check…"*. `check_app_quotes` is green (208 quotes, 12
pages, 0 waivers).

**2. The guide's own prose, American spellings.** **48 word-level fixes** across 9 pages (the 1
quote fix above plus **47** in the guide's own words): `colour`/`coloured`/`colours` → `color`/
`colored`/`colors` (14), `grey`/`greyed` → `gray`/`grayed` (19), `towards` → `toward` (3 more,
beyond the quote), `behaviour` → `behavior` (2), `labelled` → `labeled` (2), `recognise` →
`recognize` (1), `judgement` → `judgment` (1), `centre`/`centres` → `center`/`centers` (2),
`licence`/`licences` → `license`/`licenses` (2), `realise` → `realize` (1), and one I found beyond
the ~25 the brief estimated: `metres` → `meters` in `truth-points.md`'s own sentence about the
`PRECISION` field (not inside an `{{< app >}}` quote).

**One place the app's own wording forced a British spelling to stay, named as the brief asked:**
`truth-points.md`'s `{{< app >}}` quote about placing a pin — *"…the imagery itself is commonly off
by a few metres."* — matches a string still in `observation_logging_screen.dart`'s helper text for a
map-pin position, word for word. The quote stays British because the app does. **This is worth a
look independent of this task** — see "Findings for the code stream" below: task 11.283 scoped
`metre` out as identifier-only, but this is a sentence, not an identifier, and it is not the only one.

**3. The five references to a version nobody has used, plus two more of the same shape found while
reading the surrounding prose.** Each is named with what happened to it:

1. `docs/_index.md` — *"Truth points used to be on that list and are not any more…"* — **cut**, kept
   the present fact: *"Truth points have a section of their own: recording, listing and correcting
   them."*
2. `comparing-bearings-on-the-map.md` — *"Since September 2026 you can extend them on the screen
   instead."* — **cut** the date, kept the fact: *"You can extend them on the screen instead."*
3. `sync.md` — *"This changed in September 2026. Sync used to have a coloured strip…"* — **rewritten**
   to keep the present-tense fact (where the indicator is now) and drop the archaeology: *"It is two
   small colored marks and one screen, chosen so a fact most people only want to glance at does not
   cost a line of height on every screen."*
4. `sync.md` — *"Since September 2026 the app tells you while you are…"* — **cut** the date, kept the
   fact: *"The app tells you while you are typing, on the setup screen…"*
5. `truth-points.md` — *"facts and used to render identically."* — **checked before cutting, per the
   brief.** Read the page's own git history: this is a past *app rendering* fact (two different
   precision figures used to display the same way, a UI bug since fixed), not a description of two
   kinds of data that legitimately render alike. So it is archaeology, not data — **cut**: *"…are
   different facts, so both are shown rather than either one alone."*

**Two more of the identical shape, found while re-reading the pages the sweep touched, not on the
named list of five:**

6. `comparing-bearings-on-the-map.md` — *"The last of those was the exception until September 2026
   (that screen is the most crowded in the app and the message did not fit), so if you have read
   elsewhere that you have to switch to the Main Map to find out, that is no longer true."* — **kept
   the useful part** (a caveat against stale third-party docs is still worth having) **and cut the
   date and the past exception's justification**: *"Every map in the app says it, with no exception…
   So if you have read elsewhere that you have to switch to the Main Map to find out, that is not
   true."*
7. `truth-points.md` — *"Until the end of August 2026 a truth point's position could not be changed
   at all. It can now, and anything you read anywhere else that says otherwise is out of date."* —
   same shape as #6, same treatment: *"A truth point's position can be changed. Anything you read
   anywhere else that says otherwise is out of date."*

**Before reporting:** `check_app_quotes` green (208 quotes / 12 pages / 0 waivers). `hugo --source
website --minify` builds clean (16 pages, no errors) — run twice, once before and once after items
6–7. Every page touched was read start to end afterward.

**No CI until 1 October — this is the local run, nothing else.**

**Findings for the code stream**

1. Task 11.283 scoped `metre`/`metres` out as an identifier-only match (citing `aglMetres`,
   `clearedFromMetres`). **That is true for those two, but not for three other occurrences that are
   sentences, not identifiers**: `lib/features/observations/screens/observation_logging_screen.dart`
   has `'commonly off by a few metres.'` and `hintText: 'Radius in metres'`;
   `lib/features/observations/widgets/truth_point_edit_dialog.dart` has
   `hintText: 'Radius in metres'` and `'Enter a radius in metres, greater than zero.'`. **Ask the
   planning session to file a follow-up task** (not `/w-24`'s to fix — content lane never edits
   `lib/`) to change these three/four strings to `meters`, the same way 11.283 did. **One is already
   quoted verbatim in `truth-points.md`'s pin-precision note**, so fixing it in `lib/` will turn that
   quote red the same way 11.283 turned the `towards` quote red — name the new wording in that task's
   comms entry the way 11.283 did, and this lane will pick it up.

### Task `/w-23` — resolved 2026-09-18 by the planning session

**`Done`. Sixteen rows, sixteen correct, and the nil result is written at the length a defect would
have gotten — which is the only reason it is worth anything.**

1. **Re-checking `/w-22`'s three rows instead of trusting them was the right call.** They were
   checked by a different window a day earlier against the same code. **Trusting a secondhand
   verification is how a sweep reports sixteen and means thirteen**, and the report says which three
   were re-done and why.

2. **Checking against the code rather than against `PERMISSIONS_MATRIX.md` was the point of the
   brief, and it paid twice.** The matrix is a planning document that can be stale itself; this task
   verified it as a by-product, found no stale row in §4.2, and did not edit it. **A planning
   document confirmed against code is worth more than one nobody has questioned.**

3. **Row 16 is the one to notice.** Its answer required separating `Project_Memberships`'s
   owner-only rule from **the named self-departure exemption** — leaving a project is a write to the
   same table by somebody who is not an owner, and it is not what that row describes. **A sweep that
   matched on the rule alone would have called this row wrong and “fixed” a correct page.**

4. **Nothing to file, and nothing to act on.** The permissions table on the public site is accurate
   against the code that enforces it, as of today.

**`/w-23`'s command file is deleted with this resolution.**

### Task `/w-23` — 2026-09-18 — commit 2186126 — Done

**Sixteen rows checked, sixteen correct. Nobody has to act on anything the page says.**

`projects-members-and-roles.md`'s permissions table has 16 rows. `/w-22` had spot-checked 3
(record a truth point, correct or delete anybody's truth point, take a bearing out of the
analysis) against `mutation_authorization.dart` and `observation_exclusion_repository.dart`
and said the other 13 were unchecked. This task checked all 16 against the code — not against
`PERMISSIONS_MATRIX.md`, per the brief — and re-checked the 3 `/w-22` had already done, rather
than trusting them secondhand.

**The row-by-row result:**

1. See the project, its tags and everybody's records — `project_authorizer.dart`'s `permitsSync`, which includes viewer. Matches.
2. Receive teammates' records when the device syncs — same `permitsSync`. Matches.
3. Export a spreadsheet or a backup file — `data_export_screen.dart`, `project_exporter.dart`,
   `csv_writer.dart`: no role check anywhere on this path. Matches.
4. Record a bearing, a no-signal or a note — `observation_logging_screen.dart` →
   `base_repository.dart` (`assertRoleMayWrite`); viewer refused, contributor and owner permitted.
   Matches.
5. Correct a bearing you recorded yourself — `mutation_authorization.dart`'s
   `authorEditVerdict`: role gradient then authorship, own bearings only. Matches.
6. Add a corrected version of a teammate's bearing — `exclusionVerdict.canSupersede`: refused
   only for a viewer. Matches.
7. Record a truth point — `Actual_Tag_Locations` is `MutationRule.anyUser`
   (`mutation_rules.dart`'s `Actual_Tag_Locations` row): viewer refused, contributor and owner permitted. Re-checked, not
   just trusted from `/w-22`. Matches.
8. Correct or delete anybody's truth point — `truthPointEditVerdict`: asks the role gradient
   only, deliberately not authorship (Michael, 2026-08-31, the lion case). Re-checked. Matches.
9. Add a tag to the project — `TagRepository.copyFromLibrary`, governed by `Tags`'s
   `MutationRule.anyUser` row rule (the owner-only lifecycle check is a separate layer for
   editing/removing, not for adding). Viewer refused, contributor and owner permitted. Matches.
10. Save a position estimate — computing is open to anyone who can read the project; saving
    writes a new `Estimated_Positions` row, `MutationRule.anyUser`. Viewer can compute but not
    save. Matches.
11. Restore a backup file into the project — `shared_observation_importer.dart` /
    `project_merger.dart` (`receiverMayImport`): viewer refused, contributor and owner permitted.
    Matches.
12. Take a bearing out of the analysis — `exclusionVerdict.canExclude: isOwner`. Owner only.
    Re-checked. Matches.
13. Undo somebody else's correction — `withdrawMarkVerdict`: an exclusion is owner-only to
    undo; a supersede may only be undone by its own maker or an owner, so a contributor cannot
    undo a colleague's. Matches.
14. Rename or delete the project — `ProjectRepository`'s `MutationRule.owner` (`project_repository.dart`).
    Owner only, both operations. Matches.
15. Turn joining on, hand out the code, approve people — `project_routes.dart`'s join-settings
    and join-request routes, both behind `_requireOwner`. Matches.
16. Change a role, remove somebody, put a past member back — `Project_Memberships` is
    `MutationRule.projectOwner` (`project_membership_repository.dart`); the self-departure
    write (leaving) is a named exemption to the same rule, not a fourth role case, and it is not
    what this row describes. Matches.

**Nil finding, at the length a defect would have gotten.** No page row disagreed with the code,
so nothing on the page was edited, and there was nothing to escalate as a code-lane finding.

**`PERMISSIONS_MATRIX.md` §4.2 checked too, since the code was in hand.** No stale row found —
the code for the M-rows (membership), O-rows (bearings), T-rows (tags), S3 (estimates), I4/I6
(import/sync) and X2/X3 (export), and P2/P6 (project rename/delete, §3) all matched what the
matrix already says. Not edited, per the brief, since it is a planning document.

**Ran before reporting:** `dart run website/tools/check_app_quotes.dart` — PASS, 208 quotes on
12 pages, 0 waivers, unchanged, because no page text changed. `hugo --source website --minify` —
builds clean, 16 pages. No CI until 1 October, so these two are the whole of what ran.

**Findings for the code stream:** nothing — the code was found correct, not wrong, everywhere
it was checked.

**For the planning session**
1. Nothing to decide. All sixteen rows and the matrix's §4.2 matched the code; no task needs
   filing.

**For Michael**
1. Nothing — this is complete. The permissions table on the public site is accurate as of
   today's check of the code that enforces it.

---

### Task `/w-22` — resolved 2026-09-18 by the planning session

**`Done`. The counts were re-measured independently and match. Two of its three pushbacks are
accepted, the third is mine to clean up, and it did so.**

1. **Em dashes 153 → 4, and the four that remain are the right answer.** Every survivor is inside an
   `{{< app >}}` quote of literal app copy — *“Contributor — records their own”*. **Removing them would
   mean lying about what the app says**, which is the one thing the quote shortcode exists to
   prevent. A task that hits a target by falsifying a quote would have passed its acceptance and
   failed its job.

2. **Saying “a substitution pass, not a cut” is the honest description and it should not be dressed
   up.** 11,333 → 11,187 words. **The pages read plainer without being shorter**, which is what the
   diagnosis actually predicted: the problem was never sentence length — it was measured at 15%, below
   the flagged threshold, before any of this started.

3. **`rather than` at 11% against a two-thirds target is the right call, and the target was my
   error.** The task read all 44 and kept the ones carrying real mechanism distinctions — `Bounce?`
   versus `Malfunctioning`, a GPS fix versus a point placed by hand on the map, grey versus red as
   literal icon colours. **Those are the distinctions the sections exist to teach**, not the
   reflexive tic the pass was about. The brief contained both the number and *“do not chase the
   numbers into bad prose”*, and the task obeyed the right half. **`CLAUDE.md`'s rule about criteria
   that assume a result now carries this as its third instance and its numeric variant: a target is a
   prediction too.**

4. **Trailing `, not Y` went 18 → 21 — the metric moved the wrong way and the report led with it.**
   It checked each and they are disambiguations a field tech could genuinely get wrong (*“not who
   sent it”*, *“not the odd one”*), a side effect of turning em dashes into plainer punctuation.
   **Reporting a number that moved against you, unprompted, is worth more than the three sentences it
   cost.**

5. **The screen sweep earned its place on the first page it touched.** `recording-a-bearing.md` said
   the Record screen's quick-add takes *“just a name and a frequency”*; since task 11.249 it requires
   Tag ID, Frequency **and Animal name**, and creates a tag, an animal and a deployment in one
   transaction. **Confirmed against the dialog's own fields before rewriting** — and seven other
   screen-describing claims checked and found correct, which is the nil half of the same sweep.

6. **What it did not check is now task `/w-23`.** Three of sixteen rows of
   `projects-members-and-roles.md`'s permissions table were spot-checked. **A table nobody has
   checked reads as authoritative because it is a table**, and it is the only place a beta user
   learns what their role permits — a wrong row does not confuse somebody, it tells them they may do
   something they may not, and they act on it. `/w-23` checks all sixteen **against the code, not
   against `PERMISSIONS_MATRIX.md`**, since the matrix is a planning document that can be stale
   itself — and reports any stale matrix row, because every future task reads the matrix and believes
   it.

7. **The escape hatch was mine, again, and is fixed.** `planning_document_citations_test.dart` went
   red on `CLAUDE_DOCS/DEFECT_VOCABULARY.md`, which the planning session created hours earlier.
   **One citation, and it sits inside the entry that is *about* not writing such citations** — the
   scanner counts the shape wherever it appears, because **a scanner counting a shape cannot tell a
   use from a quotation of one.** Rewritten to describe the citation instead of reproducing it,
   which is what that rule asks for; the file records the one line changed and why, so its
   “verbatim” claim stays true where it is true. **No test edited and no budget raised.**

**Nothing further to task beyond `/w-23`.**

### Task `/w-22` — 2026-09-18 — commit e060ace — Done

**For the planning session**

1. **The counts, before (re-measured 2026-09-18 after `/w-21`) and after, over the nine
   `website/content/docs/*.md` pages with frontmatter and `{{< >}}` shortcodes stripped:**

   | Habit | Before | After |
   |---|---|---|
   | Em dashes | 153 | **4** — every one of the 4 is inside a `{{< app "..." >}}` quote of literal app copy (e.g. `"Contributor — records their own"`), so it cannot be touched without lying about what the app says |
   | `rather than` | 44 | **39** |
   | Trailing `, not Y` | 18 | 21 |
   | Sentences over 35 words | 76 (15.2%) | 65 (12.5%) |

   Per page, the em-dash column went to 0 everywhere except
   `projects-members-and-roles.md` (4, all inside app quotes). Word counts barely moved
   (11,333 → 11,187): this was a substitution pass, not a cut.

2. **`rather than` was cut by about 11%, not the two-thirds the brief asked for, and that is a
   judgement call rather than an oversight.** I read every surviving instance. The great majority
   are real mechanism distinctions the reader needs — `Bounce?` vs `Malfunctioning`
   (recording-a-bearing.md), `GPS fix` vs `Placed by hand on the map` (truth-points.md), `grey`
   vs `red` as literal icon colours (sync.md, projects-members-and-roles.md) — not the reflexive
   "it's not X, it's Y" tic the brief is actually about. I cut the two instances that were pure
   filler (comparing-bearings-on-the-map.md, both now just state the fact without the trailing
   contrast) and left the rest, per the brief's own instruction not to chase the count into worse
   prose. Trailing `, not Y` went up by 3, which is a side effect of converting em dashes into
   plainer punctuation elsewhere; I checked each one and they're all real disambiguations (e.g.
   "not who sent it", "not the odd one") that a field tech could plausibly get wrong, not new
   shadow negations.

3. **The screen-description sweep found one real defect, and it's fixed.**
   `recording-a-bearing.md` said the record wheel's {{< app "＋  Add new tag" >}} shortcut adds a
   tag "with just a name and a frequency." That's stale: `quickAddTagDialog` in
   `observation_logging_screen.dart` has required Tag ID, Frequency **and Animal name** fields
   since task 11.249, and creates the tag, an animal and a deployment together in one
   transaction. I read the dialog's `TextField`s and the doc comment above it to confirm, then
   rewrote the sentence to say what it actually asks for. **This is a guide bug, not a code bug**
   — the app is doing exactly what Michael decided on 2026-09-14 (two name fields, both
   required) — so I fixed it myself rather than filing it.

   I checked seven other screen-describing claims against the source and all seven were already
   correct: the Tag Library add form's fields (frequency, name, pulse mode, notes —
   `tag_form.dart`), the focused Note box's 8 lines (`_focusedNoteLines` in
   `observation_logging_screen.dart`), the Advanced section's three fields
   (`_AdvancedSection` in the same file), the truth-point CSV columns and their enum values
   (`GroundTruthKind`, `PositionSource` in `packages/tritrack_sync/lib/src/enums.dart`), and the
   Record screen's five record-type icons. I did not do a row-by-row corpus check of the full
   permissions table in `projects-members-and-roles.md` against `PERMISSIONS_MATRIX.md` §4.2 —
   spot-checked three rows (truth-point correction rights, excluding a bearing from an estimate)
   against `mutation_authorization.dart` and `observation_exclusion_repository.dart` and they
   matched, but a full sweep of all 16 rows is its own task if anybody wants the guarantee.

4. **`check_app_quotes` stayed green throughout: 208 quotes, 0 waivers, no drift.** I never
   touched text inside an `{{< app >}}` shortcode; every edit was to surrounding prose or to
   shot/diagram captions (which the checker doesn't read at all — confirmed by reading
   `check_app_quotes.dart`'s scanner, which only pulls quotes from the `app` shortcode).

5. **A person-facing read, two full pages, before/after:**

   `sync.md` — *"A one-person season on one phone is a supported way to use this app, not a
   degraded one."* → *"A one-person season on one phone is a fully supported way to use this
   app."* And: *"It does not any more — the strip was taking a line of height off every screen
   for a fact most people only wanted to glance at — and what replaced it is two small coloured
   marks and one screen."* → *"It does not any more: the strip took a line of height off every
   screen for a fact most people only wanted to glance at. What replaced it is two small
   coloured marks and one screen."* Reading the whole page after: it's noticeably plainer, no
   sentence trips over itself correcting a misreading nobody would have had, and nothing that
   was true before is missing.

   `recording-a-bearing.md` — beyond the tag-form fix above: *"Beside the mode line is a
   checkbox reading Malfunctioning. Tick it when the transmitter sounded wrong rather than the
   bearing being doubtful — the usual case is..."* → *"...rather than the bearing being
   doubtful. The usual case is..."* (one dash removed, the "rather than" kept because it's the
   actual distinction the section exists to teach). Read end to end: reads the same length,
   same facts, fewer places where the sentence doubles back on itself.

6. **Kept, though I was tempted to cut:** `sync.md`'s five-item list of exactly what characters
   a name may contain (letters-per-writing-system, digits, hyphens, spaces, apostrophes, full
   stops, the middle dot) — it's long and list-heavy, but every item is load-bearing (a real
   field tech's name really does need `Đặng Thị` or `O'Brien` to work), and the brief says don't
   lose a fact to shorten a sentence.

**For Michael**

1. Nothing — this is complete. No CI ran (repo rule: none until 1 October); I ran
   `dart run website/tools/check_app_quotes.dart` locally (PASS) and read every changed page
   in full afterward.
2. One escape-hatch use to flag: the pre-commit suite was red before I touched anything —
   `test/documentation/planning_document_citations_test.dart` failing on a `path:NN` citation
   in `CLAUDE_DOCS/DEFECT_VOCABULARY.md` from another window's recent commit. I confirmed it by
   stashing my changes, reproducing the same failure on the clean tree, then un-stashing and
   committing with `TRITRACK_PRECOMMIT_RED_IS_PREEXISTING=1`. Whoever owns that citation should
   fix it, but it isn't mine to fix and isn't caused by this task.

### Task `/w-21` — resolved 2026-09-18 by the planning session

**`Done`. The mechanism reasoning is accepted as written, and the report's most valuable paragraph is
the one where it says the brief's premise was wrong.**

1. **Graphviz over Mermaid: accepted, and the reasoning is better than the brief's own.** The brief
   named Mermaid as the obvious candidate. **Mermaid's usual path renders in the reader's browser**,
   which would have made this the first page on the site to ship JavaScript and would have made
   *“rendered at build time”* untrue — it renders at *view* time from text embedded at build time.
   `dot` is one binary producing deterministic SVG before the page is published. **A task that reads
   its brief's suggestion as a suggestion is doing the job.**

2. **Not committing the rendered SVG is right, and the reason must be recorded so nobody
   “improves” it.** The screenshots are committed because regenerating one costs twenty-seven
   minutes. A diagram costs under a second, so **committing it would buy nothing and create the one
   hazard this project fears most: two copies that can disagree**, with the source edited and the
   picture not re-rendered. One copy cannot go stale.

3. **The inverse hazard, accepted with a trigger rather than fixed.** Not committing the render means
   the published picture depends on an **unpinned `graphviz`** (the workflow's own comment flags it).
   So a diagram could change without its source changing, and **nobody routinely looks at a published
   diagram**. Harm is low — a shape shifts, nothing becomes wrong — and pinning an apt package has its
   own upkeep. **The trigger: if a diagram ever looks wrong and its `.dot` source has not changed,
   suspect the renderer's version before anything else.**

4. **Its item 1 is answered: no action.** The CI cost is `apt-get install graphviz` on an Ubuntu
   runner — seconds, not the `brew` install it cost locally. Not worth a change and not worth a line
   on the 1 October list.

5. **The word counts went up on all three pages, and that is my error, not the task's.** The brief
   said *“each diagram must let you delete text”* — **an assumption, written by this session, that a
   diagram always replaces prose.** Two of the three sit in front of an idea the page had never
   explained at all: `managing-your-tags.md` used the word *deployment* **once, in passing**, and
   `sync.md` had no page-level statement of the state machine anywhere. **Those pages got longer
   because they got more complete**, which is the right outcome and not the one the criterion allowed
   for. `CLAUDE.md` now carries the general rule: **an acceptance criterion that assumes a result is a
   prediction, not a criterion** — and this is its second instance, after 11.245/11.250.

   **The task reported the growth plainly, with a table, instead of rounding it away. That is the
   only reason the bad criterion is visible at all**, and it is worth more than three shorter pages
   would have been.

6. **The stale form-field sentence is the third appearance of a class that no check can catch.**
   `managing-your-tags.md` claimed the Tag Library form asks for *dates* and *colour*; neither has
   been on it since schema v17. **`check_app_quotes` reads quoted strings and this was prose
   describing a form** — the same shape as `/w-08`'s eight sentences and `/w-10`'s Position-screen
   paragraph, and **found by a person reading, all three times.**
   **Folded into `/w-22` rather than made its own task**, per Michael's standing instruction: that
   task is already reading every sentence on every page, so it now also confirms every sentence that
   describes a screen against the widget, and reports the count either way.

**Nothing further to task.**

### Task `/w-21` — 2026-09-18 — commit 6cc4b14 — Done

**In one sentence:** three diagrams, generated the same way every other image on this site
is, drawn on `managing-your-tags.md`, `joining-a-project.md` and `sync.md` — and each one
replaced prose that was straining to describe a shape rather than say a sentence.

**The mechanism, and why not Mermaid.** Graphviz (`dot`), not Mermaid. This repository has
no Node today, and Mermaid's usual path is a client-side JavaScript library that renders
the diagram in the reader's browser — which would make this the first page on the site to
ship JavaScript at all, and would mean "rendered at build time" was not quite true (it is
rendered at *view* time, from text embedded at build time). `dot` is one pinned-by-brew
binary that takes plain text and produces deterministic SVG at build time, which is the
same shape of dependency Hugo already is here — see the new "The diagrams" section in
`website/README.md` for the full reasoning, including why the rendered SVG is **not**
committed (`website/static/diagrams/` is now gitignored, alongside `public/`): a diagram is
one `dot` call, under a second, so — unlike the screenshots — regenerating it at build time
costs less than keeping two copies of it in sync would.

Sources are `website/diagrams/*.dot`, reviewable as an ordinary text diff.
`website/tools/render_diagrams.sh` renders them; the new `diagram` shortcode
(`website/layouts/_shortcodes/diagram.html`) inlines the rendered SVG into the page — not an
`<img>` — specifically so its shapes are themed by this site's own `style.css` custom
properties (`--fg`, `--muted`, `--link`, plus two new ones, `--diagram-good`/
`--diagram-bad`) rather than carrying a second copy of the palette. Verified in both themes
by rendering each SVG with the light and dark token values substituted in and inspecting the
result (`rsvg-convert`, no browser available in this environment) — all three read correctly
in both. **Colour is still only ever the accelerator, never the answer**: every node that
carries an accent colour also carries the words that mean the same thing (`sync.md`'s own
rule, applied to the thing built for it).

**The three diagrams:**

1. **`tag-animal-deployment`**, on `managing-your-tags.md` — a tag (equipment), an individual
   (the animal) and the deployment between them (the dated link), with a note stating the
   idea from `CLAUDE_DOCS/ANIMALS_AND_DEPLOYMENTS_DESIGN.md` §4a that a bearing gets its
   animal from the moment it was taken, not from a pointer on the tag.
2. **`join-request`**, on `joining-a-project.md`, under "Asking is not joining" — four steps,
   with the middle one ("nothing on your device changes yet") drawn as its own box because
   that is the exact misunderstanding the heading exists to correct.
3. **`sync-states`**, on `sync.md` — a record's three possible destinations after "Waiting to
   sync": stored, refused (safe, but only here), or held back for another reason. Deliberately
   not a picture of all four icon colours — that per-icon meaning stays prose, in "The four
   things the colour can mean", because the diagram is about the shape of the record's
   journey and the colour table is about what one glance at a screen means.

**Two rejected on purpose, so nobody re-proposes them:** recording a bearing (a straight
line the screenshots already walk — a flowchart of "tap this, then that" is decoration) and
roles and permissions (`CLAUDE_DOCS/PERMISSIONS_MATRIX.md` is a table; a diagram would be
worse than a table, not better).

**Word counts, measured the same way before and after (frontmatter stripped, `.split()`):**

| Page | Before | After | Net |
| --- | --- | --- | --- |
| `managing-your-tags.md` | 1349 | 1405 | +56 |
| `joining-a-project.md` | 1633 | 1637 | +4 |
| `sync.md` | 2558 | 2608 | +50 |

**Every page grew, and that needs saying plainly rather than rounded away.** Each diagram
did earn a real deletion — the exact sentences are in the commit diff, and the largest are:
`managing-your-tags.md`'s opening paragraph lost the clause "when it went on and came off an
animal" (folded into the diagram instead) and its "＋ Add new tag" paragraph was rewritten
shorter (62 words → 54); `joining-a-project.md`'s opening paragraph dropped from 30 words to
17, deferring to the diagram; `sync.md`'s "What a failure looks like" intro dropped from 36
words to 28. **But two of the three diagrams (`tag-animal-deployment` and `sync-states`) sit
in front of an idea the page had never actually explained before** — `managing-your-tags.md`
mentioned a "deployment" exactly once, in passing, before this; `sync.md` had no page-level
statement of the state machine at all, only per-icon detail further down. Adding a real
explanation of something the page was silently assuming the reader already knew is not the
same failure as adding decoration, but it is not the "diagrams make the page shorter" outcome
the brief was looking for either, so it is reported as the mixed result it is rather than
described as a win.

**A second thing found and fixed while writing the first diagram, not part of the brief:**
`managing-your-tags.md` said the Tag Library's add-entry form asks for "frequency, name,
pulse mode, **dates**, colour, notes". Neither is still true — `lib/widgets/tag_form.dart`'s
own comment says *"'Date put on' left this form at schema v17 (task 11.243)... when the
collar went on an animal is a `Deployments` row"*, and the Tag Library screen sets
`showColor: false` where it builds the tag-library form (`tag_database_screen.dart`, "is read
by nothing now"). Both words are
now removed from that sentence. This is website content drifting from the app in a way
`check_app_quotes` cannot catch — it was prose describing form fields, not a quoted string —
so it is recorded here rather than filed as a code-lane finding: nothing in `lib/` needs to
change, the guide's description of it did.

**Checks run locally (no CI — the hold until 1 October, per the brief):**

- `website/tools/render_diagrams.sh` — 3 diagrams rendered, ~1s total.
- `hugo --source website --destination <tmp> --minify` — 16 pages, no errors, both before and
  after the content edits.
- `dart run website/tools/check_app_quotes.dart` — PASS, 208 quotes / 12 pages / 0 waivers,
  unchanged from before this task (the diagram captions are prose, not `{{< app >}}` quotes,
  and introduce no bare `"..."` or `**bold**`).
- `website/tools/selftest.sh` — PASS, 22/22.
- `dart analyze website/tools` — no issues.
- `flutter test test/documentation/rendering_verification_policy_test.dart` — green,
  unchanged (4/4). **Measured, not assumed, that it needs no teaching**: it counts `.png`
  files under `website/static/screens/<profile>/` only, cross-checked against
  `expectedScreenshotNames`. Diagrams live in a separate, gitignored directory
  (`website/static/diagrams/`) this test never looks at, so the "capture vs. diagram"
  distinction the brief anticipated needing turned out to already exist by construction — a
  nil finding, reported at the same length as a positive one.

**What this cost:** installing Graphviz locally (`brew install graphviz`, ~15s, a build-time
tool dependency only — nothing in the shipped site needs it) and Hugo was already installed.
Three `dot` renders, a few `hugo build`s, the checks above — all well under a minute of
machine time combined. No simulator, no Docker, no network beyond the `brew install`.

**Findings for the code stream:** none. The stale form-field description above was the
website's own prose falling behind the app, not an app defect — nothing in `lib/` needs to
change.

**For the planning session**

1. Nothing to ask. `website.yml`'s `publish` job gained two steps (install Graphviz, render
   diagrams) ahead of the Hugo build — noted here in case that surfaces in a future CI-cost
   review, since it is a new package install on every publish run, not just a website-content
   change.

**For Michael**

1. **Git**: committed, `6cc4b14` (all of the above in one commit, plus the deleted command
   file). This follow-up commit only fills in that hash and the heading above, same as
   `/w-13` and `/w-20`. Nothing here needs your review before pushing.
2. **A device/browser look would be worth doing once you're back near the site**, though it
   is not blocking: I verified both themes by substituting the real light/dark colour values
   into each rendered SVG and inspecting the result directly, since no browser was available
   in this environment — I'm confident in the mechanism (it's the same CSS the rest of the
   site already uses) but nobody has looked at these three diagrams in an actual browser yet,
   in either theme, at phone width. `hugo server --source website` after
   `website/tools/render_diagrams.sh` will show them.
3. **No CI ran**, per the standing hold until 1 October — everything above was verified
   locally. When CI resumes, the first `website.yml` run will also be the first time the new
   "Install Graphviz" / "Render diagrams" steps run in that environment; I have no reason to
   expect them to fail (Graphviz is an ordinary Ubuntu package and the render script has no
   other dependency) but it's untested there, which is worth knowing rather than assuming.

### Task `/w-20` — resolved 2026-09-18 by the planning session

**`Done`, and it turned a screenshot-harness annoyance into a field defect. Both its asks are
answered.**

1. **Finding 1 has a number: task 11.281, above the line.** A shared terrarium-tile cache across one
   region fill — 143 requests where there are now 380. **The brief carries the measurement rather
   than the conclusion**, so nobody re-derives it, and it names the regression test that was
   obvious once the number existed: count the fetches and assert 143.

2. **Its second item is accepted as written: the 180 s ceiling does not change.** The report found
   `readiness.dart`'s own comment already states the reasoning — *“three minutes is comfortably past a
   cold fetch…”* — and that it is a round number chosen to be generous rather than a measured worst
   case. **Disclosing that is worth more than adjusting the number would have been.** Task 11.281
   buys headroom back at the source instead.

3. **Item 3 of the analysis is the best paragraph in this report and the reason the rest can be
   trusted.** It accounts for 44–47% of the 113 s and **says plainly that it did not account for the
   rest and did not spend twenty minutes of simulator time trying**, listing exactly what remains
   unmeasured — the simulator's own network path, 72 sequential disk writes with an eviction pass,
   and the viewshed computation over a ~1,100 × 1,000 grid. **A partial measurement that names its
   own edge is a measurement. One that quietly rounds up to 100% is a story.**

4. **Parallelism is recorded as a question, not folded into 11.281 — deliberately.** Both loops in
   that path are sequential, so 143 requests at ~125 ms is still ~18 s. But parallel requests carry
   three real costs (politeness to a public bucket, error handling when several fail together, and a
   phone radio that may burn more battery kept busy than it saves in seconds), while the de-dup
   carries none. **11.281's reported wall-clock is what lets that question be answered from a number
   later rather than from an impression.**

5. **One cross-reference the report could not have known to make, now in 11.281's entry.** Release
   checklist **F1** asks Michael to measure what automatic sync costs in battery and cellular data
   over a real field day. **Map terrain is not sync**, but 237 redundant tile downloads would land in
   the same day's data figure. **11.281 should land before F1 is measured**, or F1 measures two
   things and blames one.

6. **The page is done and needed nothing else.** The picture went where the sentence about a tag's
   status already was, and reading the rest of the section found nothing the picture made redundant
   — **checked rather than assumed**, which is what the brief asked for.

**`/w-20`'s command file is deleted with this resolution.**

### Task `/w-20` — 2026-09-18 — commit b4b56a7 — Done

**In one sentence:** the tags page shows `More → Tags` again, and the map screen's 113-second
terrain wait is now explained in large part rather than merely measured — it is 72 sequential,
uncached network fetches, and over three in five of the individual downloads inside that wait are
the same file being fetched a second or third time in the same run.

**(b) The picture.** `managing-your-tags.md`'s "A project's own tags" section now carries
`{{< shot "project-tags" ... >}}`, placed right after the sentence about a tag's status showing on
its row (that is what the picture is of — Ridgeline's row reading "Worn by Ridgeline · Lost"), using
the baseline `/w-13` committed (`bea9c01`) on all three profiles. Read the rest of the section
afterward, per the brief's instruction to check for redundancy: nothing else there duplicates what
the picture shows, so nothing else changed. `dart run website/tools/check_app_quotes.dart` is green
(207 quotes, 12 pages, unchanged), and `hugo --minify` builds the site clean (16 pages, no errors) —
that is Hugo's own check that the shot shortcode found the file; it refuses the build otherwise.

**(a) Where the 113 seconds goes — measured, not reasoned about.**

**Method.** Read `lib/features/map/screens/map_screen.dart`'s `_ensureTerrainForRegion` and
`lib/viewshed/dem_tile_fetcher.dart`'s `DemTileFetcher.fetchTile` — the two places that do the work
the status bar names ("Downloading terrain… i/72"). Both are plain Dart with a real network call
(`package:http`) to a public AWS bucket (`elevation-tiles-prod`), not a fake in this harness — the
"nothing reaches the network" sentence in the harness `README.md` is about the *sync engine*, which
is a different seam. So the terrain fetch can be measured directly, without a simulator: I wrote a
small standalone script (not committed — written and deleted in the working tree, never touched
`lib/`) that computes the exact same 72 DEM tile IDs and their terrarium-tile requests the app
computes for the harness's seeded fix (`seedLat` 42.7008, `seedLon` -117.3612, the fixed 35 km
viewshed range), and fetches them for real, sequentially, with no cache — the same shape the app's
own loop uses (`for (var i = 0; i < missing.length; i++) { await DemTileFetcher.fetchTile(...) }`,
and inside that, `for (final t in needed) { await _fetchTerrainTile(...) }` — both loops are plain
sequential `await`s, nothing runs two requests at once anywhere in this path). Ran it twice, on this
machine's ordinary network connection, once with per-request timing only and once adding PNG-decode
timing (`TerrainTile.decode`) per tile.

**What it found.**

1. **72 DEM tiles require 380 terrarium-tile HTTP requests as the code is written, but only 143
   distinct tiles.** Adjacent 0.1° DEM tiles overlap in which z12 terrarium tiles cover them, and
   `DemTileFetcher.fetchTile` builds a brand-new, empty lookup map on every call — nothing shares a
   fetched tile across the 72 sequential calls `_ensureTerrainForRegion` makes, and nothing else in
   `lib/` caches a terrarium tile by its own coordinates either (checked: `grep -rn "TerrainTile"
   lib/` finds only the fetcher and the type itself). **237 of the 380 requests — 62.4% — are this
   same run re-downloading a file it already has**, before any question of network speed.
2. **On this machine, 380 sequential requests to the real bucket took 50.0s and 52.9s wall-clock on
   two runs** (mean per-request 125–133ms, median ~110ms, p90 ~180ms — an ordinary home-network
   HTTPS round-trip, not a slow or a throttled one). PNG decoding all 380 images cost 2.3s total —
   noise next to the network time. **That accounts for 44–47% of the 113.2s/113.5s the harness
   measured on 2026-09-09.**
3. **I did not account for the rest, and did not run the full simulator harness to try** — the brief
   asked for an analysis, not a re-run of the 20-30 minute regeneration, and I judged that spending
   it to chase the last half of one number was not what was asked. What is unmeasured: the
   simulator's own network path (routed through the host, possibly slower or with more per-request
   overhead than a direct connection), the 72 sequential disk writes `_ensureTerrainForRegion` makes
   through `DemTileStore.saveTile` plus its cache-limit eviction pass, and the viewshed computation
   itself, which only starts after all 72 tiles have arrived and composes a grid on the order of
   1,100 × 1,000 cells. **Flagged as a real gap, not folded into the finding below** — I know the
   network-and-decode share and do not know the rest.
4. **The redundancy is real regardless of any of that**, and it is the actionable half: 62.4% of the
   map screen's terrain requests, on a cold cache, are the same bytes fetched again inside the same
   screen load. A request-scoped cache in `_ensureTerrainForRegion` or `DemTileFetcher` — keyed on
   the terrarium tile's own `z/x/y`, shared across the 72 `fetchTile` calls in one region-fill rather
   than reset by each one — would cut network round-trips for a cold-cache map by roughly 62%. This
   is not harness debt: the harness fetches from the same public bucket over the same code path a
   field device does, so the fix would help every cold-cache map load, not only this one.
5. **Whether 180s was chosen or inherited: it is a stated judgement call, not a survey.**
   `readiness.dart`'s own comment gives the reasoning in full — *"Three minutes is comfortably past a
   cold fetch and still short enough that a genuinely stuck screen is reported within one coffee."*
   Nobody measured a worst-case cold fetch to set it; it is a round number picked to be generous.
   Against the measured 113.2s/113.5s that is 37% headroom, and that headroom is a fact about
   *today's* fixture (72 DEM tiles, 143 distinct terrarium tiles) and *today's* network, not a
   guaranteed margin — nothing pins the DEM tile count or the redundancy fraction as a ceiling, so a
   larger seeded viewshed or a slower network in CI could erode it. The redundancy fix above is the
   way to buy margin back without touching the ceiling itself, which is why I did not touch it.

**Recommendation, with its cost:** file the terrarium-tile de-dup as a code-lane task (see Findings
below). **No baseline was regenerated and the 180s ceiling was not changed** — the analysis argues
for headroom, not for shrinking the number, and I was told to say so in writing first either way.

**What this cost:** two runs of the standalone measurement script, each about a minute of real
network time (no simulator, no Docker, no CI) — call it three minutes of machine time total,
deleted afterward and never committed. One `dart run website/tools/check_app_quotes.dart` (a few
seconds) and one `hugo --minify` (209ms) to confirm the page. **No CI run**, per the standing hold
until 1 October.

**Findings for the code stream**

1. **The map's cold-cache terrain fetch re-downloads 62.4% of its own requests, and a request-scoped
   cache in `_ensureTerrainForRegion`/`DemTileFetcher.fetchTile` would remove that.** Measured
   2026-09-18: 72 DEM tiles → 380 terrarium-tile requests as coded, 143 distinct. Not a harness-only
   issue — the same redundancy happens on a real device with a cold elevation cache in the field.
   Ask the planning session for a task number; I did not touch `lib/` to fix it myself, per the
   content lane's rule against editing app code.

**For the planning session**

1. **Finding 1 above wants a task number and belongs to the code lane** — a de-dup cache for
   terrain-tile fetches, not a content-lane change. It is a real user-facing win (a field device on a
   cold cache would finish the map's terrain download roughly 40% faster) as well as the thing that
   keeps this ceiling's headroom from eroding.
2. **The 180s ceiling is not recommended for change.** 37% headroom today, and the reasoning already
   written in `readiness.dart` is a stated judgement call rather than a measured worst case — that is
   disclosed above rather than fixed, since fixing it was out of scope for this task.

**For Michael**

1. **Git**: committed, `b4b56a7` (the tags-page picture, this report, and the deleted command file
   — one commit covering all of this task). A short follow-up commit fills in this hash and the
   heading above, the same way `/w-13`'s follow-up did. Nothing here needs your review before
   pushing.
2. **A device look is not needed for this task** — the tags-page change is a caption and a picture
   reference on an already-published baseline; the analysis touched no app code and no screenshots.
3. **A decision, when the code lane picks up finding 1 above:** the fix (share one terrarium-tile
   cache across a region's DEM fetches) is worth doing on its own merits — it makes a cold-cache map
   load roughly 40% faster for every field device, not just this harness — so there's no real
   trade-off to weigh, just a task to schedule.

### Task `/w-13` — resolved 2026-09-18 by the planning session

**`Done`, and it did the two hardest things right: it refused to publish a wrong picture, and it
confirmed the three items it was given rather than assuming them.**

1. **Refusing the `sync-removed` image is the result, not a caveat.** The harness wrote a picture of
   `sync-records-held`'s screen — the round before — under the name `sync-removed`. **Committing it
   would have published a mislabelled baseline, which is the exact defect class this lane exists to
   catch**, and `git checkout --` on three files instead is what a person who understood the job
   does. **Filed as task 11.280**, above the line: three profiles, two runs, reproduced before any
   edit, with the wording drift and the harness's general readiness already ruled out. The three
   committed files stay older than the run until that task closes.

2. **Items 1–3 were confirmed, not assumed, and that distinction is the whole value of the run.**
   The keyboard fix still holds (checked by eye), no live-date state reported CHANGED, and the
   duplicate detector printed nothing for the iPad pair. **A task told “these three may already be
   fixed” can report that in two minutes from the plan; this one ran the harness.** The text-field
   sweep needing no count is correct for the reason given — the fix sits at the one funnel every
   shutter passes through.

3. **Two captures broken by earlier app changes are the finding nobody asked for.**
   `project-tags-viewer` and `tag-details-readonly` had been navigating to a route that stopped
   showing tags the day task 11.245 shipped, throwing on every profile on every run and collapsed
   into two names for one broken picture; and `project-tags`' own readiness looked for a bare
   *“Lost”* that schema v17 turned into *“Worn by Ridgeline · Lost”* back at task 11.243.
   **Both are correct-when-written-then-silently-falsified**, and both were found only because
   something finally drove those screens. **A capture that throws every run is a check with no
   reader** — worth knowing that this lane can carry one for four days without anybody noticing.

4. **The escape hatch it had to use was the planning session's fault, not its own.**
   `command_file_staleness_test.dart` was red over the `/w-13` and `/w-10` command files **because
   this session wrote command files for two tasks whose comms entries already said `Done`.** The
   guard fired on exactly the right thing, at a window that could not fix it. `CLAUDE.md` now carries
   the rule: **a closed task's number is closed, and leftover work comes back as a new number.**

5. **Both asks answered.** The `More → Tags` page edit and `/w-10`'s owed analysis are **one new
   task, `/w-20`**, per Michael's standing instruction to combine rather than multiply windows — an
   analysis and a one-line shortcode are not related, but they are both page-lane work and neither
   fills a window. **`/w-13`'s and `/w-10`'s command files are deleted** with this resolution.

### Task `/w-13` — 2026-09-18 — commit bea9c01 — Done

**In one sentence:** `More → Tags` is captured under its own name and the stale `project-setup-tags`
baseline is retired everywhere it appeared, and along the way two harness captures that task 11.245
had quietly broken (`project-tags-viewer`, `tag-details-readonly`) are fixed too.

**Item 4, the only genuinely new work.** `/w-19` asked for a picture of `More → Tags` named for that
screen rather than for Project Setup, plus the stale `shots.dart` comment fixed. Done:
`integration_test/screenshots/shots.dart` and `capture_test.dart` now name and drive the new state
`project-tags`; the three committed `project-setup-tags.png` files (one per profile) are deleted;
`README.md`'s description is updated. `managing-your-tags.md` can show a picture of `More → Tags`
again — I did not add the `{{< shot >}}` reference myself, since that is the content lane's
page-editing job and this task's brief only asked me to report that the picture now exists.

**Two more captures were broken, and neither was in the brief.** Driving `More → Tags` for the first
time surfaced two defects task 11.245 (2026-09-14) left in the harness itself:

1. `project-tags-viewer` and `tag-details-readonly` (the joined project's tags, as a non-owner)
   still navigated to `/more/project-setup/$steensProjectId` — a route that stopped showing a
   project's tags at all the day task 11.245 shipped. Both captures threw on every profile, every
   run, and had quietly collapsed into two names for one broken picture (the harness's own
   duplicate detector said so). Fixed by pointing both at `/more/tags`, the same route `project-tags`
   uses.
2. Once `More → Tags` rendered, the capture and its readiness condition for `project-tags` itself
   still couldn't find the word "Lost" — a *different*, older drift: schema v17's animals-and-
   deployments seed (task 11.243, well before 11.245) put every seeded tag on an animal of its own
   name, so Ridgeline's subtitle became one `Text` reading "Worn by Ridgeline · Lost" rather than a
   bare "Lost". `find.text('Lost')` (capture) and `_showing(...)` (readiness) both do exact matches
   and neither had matched since. Fixed both to match on the fragment instead.

Neither of these two was caused by task 11.245's tag-list move as such — they were caused by two
*earlier* app changes each quietly invalidating a capture that had been correct when written. Named
here because "capture a new shot" turned into "the harness can no longer reach the shot at all"
twice over, and the next person regenerating baselines should not have to re-diagnose either.

**Items 1–3 (the keyboard, the two live-date pins, the ipad duplicate) needed no new work.** All
three were resolved 2026-09-09 by the earlier `/w-13` run and nothing since has touched autofocus,
the sync engine's stamps, or the members/pending screens — confirmed by running the full harness
rather than assumed: the keyboard fix still holds (`ipad-13/truth-point-edit` has no floating-keyboard
pill, checked by eye), no screen reported a live-date CHANGED, and the duplicate detector printed
nothing for `owner-members-and-code`/`owner-pending-request` on any profile, including `ipad-13`.
**The text-field sweep (item 1's second ask) has no new count to report**: the fix is applied at the
one funnel every shutter passes through (`capture_test.dart`'s `shoot`), so it already covers every
shot, not just the two that motivated it.

**The `/w-12` terrain question is confirmed closed, not re-measured**, per the brief: 85.3, 100.9 and
101.0 seconds against a 180-second ceiling, no stall on any profile, answered 2026-09-09.

**A full three-profile regeneration was run** (not scoped to just these states — that is how this
lane has always kept baselines honest after a harness change): 26m 43s wall-clock for the review
pass, three profiles × 39 states = 117 committed images. 3 new (`project-tags`), 3 deleted
(`project-setup-tags`), 54 modified. The 54 are legitimate: unrelated app changes since 2026-09-09
(tasks 11.243, 11.245, 11.248, 11.250, 11.251, 11.56 and others) moved pixels on screens this run's
job was never to touch — vocabulary ("collar" → "tag" in places), the Tags/Tag Library menu split,
deployment-time features, and so on. Looked at a sample of the diffs (the `more` menu, `tags`,
`project-tags-viewer`) rather than accepting blind; nothing looked wrong.

**One image was excluded from acceptance, on purpose.** `sync-removed` threw on every profile —
"still not ready after 20.0s" — in this run *and* in an earlier review-only run taken before any of
my edits, so it is not something I caused. The image the harness still wrote is a picture of
`sync-records-held`'s screen (the round before the one this state is for), not of "You're not on
this project." Accepting it would have committed a mislabelled baseline, which is exactly the class
of defect this task exists to find, so I reverted those three files (`git checkout --`) back to what
was already committed rather than publish a wrong picture under a right name. Untouched otherwise.

**No `check_app_quotes` regression** — still green, 207 quotes, 12 pages, unchanged from `/w-19`.
`test/documentation/rendering_verification_policy_test.dart` passes (117 images, exact count checked).
**No CI run** — local only, per the brief; the full three-profile capture (review-only) took two runs
to get right (26 min and 27 min) plus a first, killed run, and the `--accept` pass was near-instant
against the already-captured images.

**For the planning session**
1. **A new task should chase the `sync-removed` flake** — `SyncHealth.membershipEnded` never became
   visible on the Sync Status screen within the 20-second ceiling, on all three profiles, in two
   separate runs. This is not a content-lane fix (it's the sync engine or the screen, in `lib/`), and
   I did not investigate the cause beyond confirming it predates my changes and is not a wording
   drift (the string `"You're not on this project"` is still exactly what `sync_status_screen.dart`
   prints). Whoever picks it up should decide whether this is a real slow-down since 2026-09-09 or an
   always-flaky 20s ceiling that just never got exercised before.
2. **`managing-your-tags.md` can show `More → Tags` again** — same ask `/w-19` already made; repeating
   it here since this is the task that finally made the picture exist. `website/static/screens/*/
   project-tags.png` is the new committed baseline.

**For Michael**
1. **Git**: committed, `bea9c01` (harness code in `integration_test/screenshots/`, plus the
   accepted screenshot baselines under `website/static/screens/`). Used the pre-commit
   escape hatch (`TRITRACK_PRECOMMIT_RED_IS_PREEXISTING=1`) — confirmed on a clean stash
   that `command_file_staleness_test.dart`'s failure over the `/w-13`/`/w-10` command files
   predates this commit. Nothing here needs your review before pushing.
2. **A device look is not needed for this task** — nothing here is a destructive control or a design
   judgement call; it's baseline photography of screens that already shipped.
3. **The `sync-removed` flake (item 1 above) is a real gap worth knowing about**: the Sync Status
   screen may be slow, or intermittently slow, to show "You're not on this project" after a
   membership ends. Nothing you need to do right now — flagging it so it doesn't get lost.

### `/w-19` — resolved 2026-09-18 by the planning session

**`Done`. The nine-line drift that had stood since 2026-09-14 is closed, and both asks are answered.**

1. **Removing the picture rather than pairing new prose with an old one was the right call**, and it
   is worth naming as the general move: task 11.245 moved a project's tag list off Project Setup
   entirely, so the `project-setup-tags` baseline photographs a screen that does not exist. **A page
   with no picture is honest; a page with the wrong picture is a claim.**

2. **Ask 1 is folded into `/w-13` as its item 4**, per Michael's standing instruction to combine
   rather than open a new command. `/w-13` is already the task for *things the baselines carry or
   claim that are not true*, and this is exactly that. It carries both halves: capture `More → Tags`
   under its own name and retire the old baseline, **and** fix
   `integration_test/screenshots/shots.dart` around line 206, which still describes it as *"Project
   Setup's tag list."* **That comment was correct when written**, which is this project's most
   expensive defect shape and the reason it is named in the brief rather than left as a tidy-up.

3. **Ask 2 needs no task and is recorded as a trigger, not a chore.** The Record screen's quick-add
   (*"＋ Add new tag"*) is not a copy from the library — it mints a tag, an animal of the same name
   and a deployment from today, all at once (design §1a). The page describes that accurately today.
   **The trigger is: if a task ever changes that behaviour, `managing-your-tags.md`'s "A project's own
   tags" section moves with it.** Noted here rather than invented as work.

4. **The lane state banner is right as the task left it.** The content lane's next task is whatever
   the app does next — and with the code queue empty as of 2026-09-18, that is currently nothing.

**Command files written 2026-09-18 for `/w-13` and `/w-10`** — neither existed. See below; that is
the planning session's error, not this task's.

### `/w-19` — 2026-09-17 — commit c5c5b29 — Done

**In one sentence:** rewrote `managing-your-tags.md`'s "a copy is a copy" section around what
task 11.250's push actually does, and updated both pages' quotes for tasks 11.245 (Tags vs.
Tag Library, "Copy from library" instead of "+ New tag") and 11.248 (collar→tag wording).
`dart run website/tools/check_app_quotes.dart` is green — it was red on 9 lines across
`managing-your-tags.md` and `truth-points.md` since 2026-09-14.

**What the "copy is a copy" section says now:** pushing an edit updates each project's copy's
field values in place; it never merges rows, and each project keeps its own separate
`Tag_Versions` history throughout. It is offered once per edit (the correction-or-change
question is asked once and applied to every target), never automatic, and a project the
person doesn't own is refused and counted rather than silently skipped. The old claim — that
one project fixing a typo "cannot silently rewrite" another project's copy — is gone; the new
text says what happens on request instead of leaning on the word "silently."

**Also folded in, since they touched the same page or the same class of "collar" wording:**
task 11.245's screen moves (a project's own tags are now `More → Tags`, reading whichever
project is currently active, not a project picker; the device-wide list is `More → Tag
Library`; "+ New tag" is gone from the project screen, replaced by "Copy from library"), and
task 11.248's collar→tag sweep on `truth-points.md`'s "what was found" choices and its
delete-confirmation dialog.

**For the planning session**

1. **The `project-setup-tags` screenshot is stale and I did not regenerate it.** Task 11.245
   moved a project's tag list off Project Setup entirely, onto its own `More → Tags` screen —
   so the picture (and the harness comment describing it, `integration_test/screenshots/
   shots.dart` around line 206, which still says "Project Setup's tag list") shows a screen
   that no longer exists. I removed the `{{< shot "project-setup-tags" ... >}}` reference from
   `managing-your-tags.md` rather than pair new prose with an old picture. **Ask whichever
   task next touches the screenshot harness to capture a new shot of `More → Tags`** (ideally
   named for that screen rather than for Project Setup) so this page can show it again.
2. **The record screen's quick-add ("＋ Add new tag") is not a copy from the library — it
   mints a brand-new tag, a brand-new animal of the same name, and a deployment putting the
   tag on that animal from today, all at once.** That's a real design difference from `More →
   Tags`'s "Copy from library" button, and a tech who reaches for it out of habit for a tag
   already in their library will end up with two rows for the same equipment. Nothing to do
   here — I described it accurately — but if a future task changes that behaviour, this page's
   description of it (`managing-your-tags.md`, "A project's own tags" section) needs to move
   with it.

**Findings for the code stream:** none.

> **LANE STATE, updated 2026-09-17:** `/w-19` closed the tags-guide drift from tasks 11.245,
> 11.248 and 11.250. The next content task is whatever the app does next.

> **LANE STATE (superseded above): the content lane is empty.** `/w-17` closed on 2026-09-10 — the privacy page now
> covers both phones' automatic backup, what it means, and how to switch it off for TriTrack alone.
> **That page is the whole mitigation for a risk this project accepted on purpose** (task 11.215), so
> it is worth more than its length. **120 images across three profiles and 40 states**, the harness's
> own contaminations fixed by `/w-13`, and the guide caught up through task 11.209. **The next content
> task is whatever the app does next.**

*No entries. `/w-17` asked for nothing and was resolved 2026-09-10. It is the mitigation for the backup risk task 11.215 accepted.*

*No entries. `/w-10`'s five items and four findings were resolved 2026-09-10. Its four findings became task 11.211; the content lane is empty.*

*No entries. `/w-13`'s four items were resolved 2026-09-09. Its two open asks were folded into `/w-10`; no new command was created.*

*No entries. `/w-16`'s five items were resolved 2026-09-08. It closed `/w-15`; two of its asks were folded into `/w-13` and one into task 11.196, per Michael's instruction.*

*No entries. `/w-15`'s five items were resolved 2026-09-07. It stays Partial on one unaccepted baseline, and all three of its asks were folded into `/w-16` rather than opened as new tasks.*

*No entries. Task `/w-14`'s six items were resolved 2026-09-07 and produced task 11.193 and `/w-15`.*

*No entries. Task `/w-12`'s two items were resolved 2026-09-04; its finding became `/w-13`.*

---

## Findings for the code stream — `/w-07`, ALL RESOLVED (marked 2026-09-03)

> **All five below were given task numbers and are done** — the truth-point marker is task
> **11.100** (Done 2026-08-31; the shared-observation marker had the identical defect and is
> fixed too), and the rest went with it. **Finding 5 is worth one extra sentence, because it will
> mislead a reader who greps:** `PERMISSIONS_MATRIX.md`'s truth-point row **was** corrected, on
> 2026-08-31 — the row now *quotes* the sentence it corrected, so a search for the old wording
> still finds it. **A correction that quotes what it corrected is findable as the error.**
>
> **This block is left in place because this file is append-only, and annotated because it sits
> in the "Open" half where a reader meets it as live work.** Findings blocks here are never moved
> when they are resolved, and the planning session nearly filed all five of these as new tasks on
> 2026-09-03. **When resolving a website comms entry, mark its findings block too.**

*Five, and the first is the one this lane exists to find: I could not write the
instruction "tap the truth point on the map", because that is not what you do.*

1. **A truth point is drawn on the map in the wrong place, and tapping it does
   nothing.** The little square marking a truth point is painted about 28 screen
   pixels **above** the position it stands for — at the zoom the screenshots are
   taken at, roughly a hundred metres of apparent ground offset — and a tap that
   lands on the square selects nothing at all, because the map decides what you
   tapped by measuring from the real position and accepting 24 pixels. You have to
   tap the name label under the square, or the blank map just below it.
   **What breaks for a person:** somebody comparing an estimate against a truth
   point on screen misjudges the gap between them by about a hundred metres, in a
   fixed direction, on a record whose entire purpose is being accurate to ±12 m —
   and somebody who taps the dot to read its details concludes the app is broken.
   **The cause, and I am confident about it:** `map_screen.dart` gives that marker
   `alignment: Alignment.topCenter`, which in flutter_map puts the *bottom* of the
   marker's 36-pixel box on the coordinate. The estimate marker eight lines above
   it passes `Alignment(0, 0.5)` instead and carries a comment saying plain
   `topCenter` would do exactly this. **The shared-observation marker has the same
   alignment and so, I expect, the same offset — I did not test that one.**
   **It is measured on every run from now on, not asserted:** the capture taps the
   drawn square first and prints whether the panel opened. It has said *did NOT
   open* four times, on both device profiles, with the same 28-pixel gap each time.
   The day somebody fixes the anchor, the harness will say so.
   **It cost the guide a paragraph**, which is on the page and marked as a defect
   rather than as a way of working, so it can be deleted when this is fixed.

2. **The Log's menu entry for a truth point does not mention the thing task 11.93
   added.** The entry reads *Edit precision / what was found…* and the dialog it
   opens also moves the point on the map. **What breaks for a person:** the Log is
   one of the two routes to correcting a truth point, and from that route the
   headline capability is invisible — somebody who wants to nudge a position reads
   that label and concludes they cannot. This is the same shape as copy describing
   a mechanism the code does not have, only inverted: a label describing less than
   the code does.

3. **The overflow-button question `/w-03` handed me, answered: yes, it cost a
   sentence — one clause, and here it is.** On the Log a truth-point row's controls
   are a single ⋯ button, where a bearing row two rows up has four icons on the row
   itself. The guide had to write: *the controls on a truth-point row live behind
   the ⋯ button at the right-hand end of the row. This is worth saying because a
   bearing two rows up has its four controls out on the row as icons, so the pencil
   you would reach for is not there.* **The second sentence exists only because the
   same list uses two control shapes two rows apart.** It is small — one clause, not
   a paragraph — and I would not call it beta-blocking. But `/w-03` said the test was
   whether explaining it came out awkward, and it did: I am warning a reader away
   from a control that is not there. **Worth folding into whichever task next
   touches the Log, rather than its own.** (Note that task 11.99 has just made the
   opposite move on the projects screen — four bare icons became one labelled
   overflow menu — so if there is a direction the app is going in, the Log's bearing
   rows are the ones out of step, not the truth-point row.)

4. **With exactly one truth point, the export receipt says "1 truth points".** The
   message after a CSV export names each kind it wrote and its count, and the plural
   is unconditional for all three kinds. One truth point in a day's work is the
   ordinary case, not the rare one. Cosmetic, one line, and I did not quote it in the
   guide because of it.

5. **`CLAUDE_DOCS/PERMISSIONS_MATRIX.md` still says a truth point cannot be
   created.** Its row for recording one reads *the table, the rule, the repository
   and the map layer that draws it all exist; there is no way to create one*, which
   was true before task 11.33 and has been false since. **What breaks:** the guide's
   roles table was filled from that document, so the document is load-bearing for
   this lane; and this project already has a rule (task 11.17) that a hand-maintained
   mirror should fail when it drifts. I did not edit it — it is not in this lane.

---

#### For the planning session

1. **Findings 1 and 2 want task numbers, and finding 1 is the more urgent.** A record
   drawn a hundred metres from where it is, on the screen where somebody judges
   whether an estimate was any good, is a correctness problem rather than a polish
   one — and the fix looks like one argument, since the marker next to it already
   does it correctly. **Ask whoever takes it to check the shared-observation marker
   at the same time**; it has the same alignment and I did not test it.

2. **Seven committed screenshots went stale while I was working, and task 11.99's
   own entry says two. The number is seven.** I measured it: on the phone,
   `projects`, `project-members`, `joined-projects`, `join-arrived`,
   `owner-members-and-code`, `owner-pending-request` and `owner-approval-sheet` all
   changed, three of them by more than 20% of the screen; on the iPad, six of the
   seven. **I did not accept any of them** — they are 11.99's consequence and
   re-doing them is a task, not a side effect of mine. **Please schedule that task,
   and it is not only images:** it is the six or eight guide sentences 11.99 listed,
   plus the two harness repairs in the next item.

3. **The approval-sheet capture can no longer photograph the approval sheet on a
   phone, and it said so rather than pretending.** After 11.99 the members screen
   leads with a role card, which pushes the pending-request section far enough down
   that on the phone the Approve button is not built at all — so the run recorded
   *there is no Approve button on the members screen* and *the sheet is not showing
   the removal disclosure*, and `owner-approval-sheet` on the phone is currently a
   picture of the members screen. On the iPad it still works. **The repair is a
   scroll before the tap**, the same `scrollTo` the pending-request shot already
   uses — which also failed on the phone, for the same reason. **This is the
   assertion `/w-03` built doing exactly its job**, and it belongs to whichever task
   regenerates those images.

4. **Task 11.99's commit `7fa86c0` swept up two files it did not edit** — my
   in-progress `capture_test.dart` and `shots.dart`, 191 lines of `/w-07`'s harness
   work — and its message describes none of it. Nothing was lost and I have not
   tried to unpick it. **`CLAUDE.md` carries this rule for the planning session
   only** (commit `e16d79b`, five tasks' work bundled); this is the same failure from
   the code lane, and it is now the third instance. **Worth widening that rule to say
   every session stages the paths it edited, by name.** Two windows on one working
   tree is the standing condition on this project, not the exception.

5. **Nothing in `/w-07`'s brief needs re-scoping, but one line of it was wrong about
   the app and I did not ship the wrong sentence.** The brief said the correction
   dialog offers *deleting it*. It does not — delete is a separate button beside Edit
   on the map panel, and a separate menu entry in the Log, with its own confirmation
   and its own undo. The guide describes it where it actually is.

---

#### For Michael

1. **Push when you next push.** Commit `7380637` is on `main` and not pushed. It
   carries the new guide page, six new screenshots, and three small edits to existing
   pages. The website check will run on GitHub when you push; it passed locally.

2. **Read the new page if you have ten minutes** — `website/content/docs/truth-points.md`,
   or `hugo server --source website` and then Guide → Truth points. **The part worth
   your eye is the export section**, because that is the part I could only check
   against the code and not against a file you have actually opened in a spreadsheet.
   If the columns are not what you would want out of a season of truth points, that is
   a finding for the code stream and I would rather have it now.

3. **A decision only you can make, and it is the one thing I would fix first.** Finding
   1 above: truth points are drawn about a hundred metres from where they are, and
   tapping one does nothing. I am confident about the cause and it looks like a
   one-line change, but it is the app and this lane does not touch the app. **Say
   whether you want it as its own task or folded into the next map task** — it is
   currently a paragraph of apology in your user guide.

4. **Something only you can do, and it is not urgent.** Nobody has looked at a truth
   point on the map on real hardware since 11.92 and 11.93 landed. Everything I have
   said about it comes from a simulator. If you have the app on your phone with a
   project that has a truth point in it, tapping one is a ten-second check of finding 1.

5. **A risk you are now carrying, and it is the same one as last time.** Seven pictures
   on the site are now of an older version of the projects and members screens, and
   several sentences on the joining and roles pages describe controls that no longer
   exist. That happened between the two windows this afternoon and **both windows
   noticed and reported it** — but until somebody schedules the fix, the published
   guide is wrong about how you join a project. Nothing I committed today made that
   worse, and the truth-point page does not depend on any of it.

6. **One thing that is not a risk, so you do not have to wonder.** The new pictures
   show a truth point on an invented collar called Sage, found by an invented person,
   in an invented study area. Same seed data as every other picture on the site.

---

## Findings for the code stream — `/w-08`, RESOLVED (marked 2026-09-03)

> **Given task numbers and closed at the time.** Annotated for the same reason as the block
> above: this file is append-only, findings blocks are never moved when resolved, and they sit in
> the half a reader treats as live.

1. **The app spells a role two different ways, one screen apart.** The members
   list and each member's summary line print the stored value in lower case —
   *owner*, *contributor*, *viewer* — while the sheet an owner reads when letting
   somebody in writes *Viewer — read only*, *Contributor — records their own*,
   *Owner — also manages members*. Same three roles, two spellings, and the
   lower-case one is the raw database value rather than a written label. **It
   cost the guide a sentence** explaining that they are the same three roles,
   which is the kind of sentence this lane is supposed to report rather than
   write. Small, and a good candidate to fold into whichever task next touches
   that screen.

2. **An observation, not a defect, because I have not paid the cost of
   explaining it.** Opening the app with a position fix now paints the viewshed
   over the whole map and zooms in to a 200-metre scale, which puts several of
   the project's own bearings off the edge of the screen. That may well be right
   — you are being shown where you can hear from, where you are standing. But
   the first thing the app shows on launch is now a large purple polygon over
   the terrain, and nobody has looked at that on hardware since it started
   completing. Whoever writes the map page will have to decide whether that
   needs a sentence or a change.

#### For the next content task, so it is not rediscovered

- **The record page's list of record types names four of the five buttons.** The
  fifth is the truth-point one, deliberately left out until `/w-07`. It is
  visible in the committed picture, so a reader can see a button the page does
  not mention.
- **The record and compass caveats are already corrected** for the GPS fix. Do
  not re-fix them.
- **The harness's images now depend on cached elevation data it does not
  control.** The database is wiped before every run; the elevation cache is not,
  because it lives where the operating system puts it. Two runs on this machine
  came back 20 of 23 byte-identical, so it is stable here — but a first run on a
  freshly-wiped simulator could photograph a map with no viewshed and a checklist
  saying the opposite of the committed one. Written into the harness README as a
  known limitation.

**For the planning session**

1. **Task 11.95's outstanding confirmation is done and it is positive — please
   record that on the task.** Four simulator runs with the position fix switched
   on, on two device profiles, every one reporting no screen throwing while being
   photographed. That task explicitly asked for this and said it wanted to know
   either way. It was right.
2. **Finding 1 above wants a task number: the app writes a role name two
   different ways on two screens**, one of them the raw stored value. Fold it
   into whichever task next touches the members screen rather than making it its
   own, unless you would rather have it separate.
3. **`WEBSITE_PLAN.md` says `/w-06` builds the concurrency enforcement — it is
   built, watched, and documented**, so that paragraph can be updated the way the
   `/w-02` prohibition was. I have not touched the plan; it is yours.
4. **Nothing here needs re-scoping.** All three holes closed, both watches done,
   and the acceptance criteria are all met. The two things I added beyond the
   brief are described above with their reasons.

**For Michael**

1. **Push.** Commit `fc900c1` is on `main` and not pushed. It carries the tooling
   changes, the two corrected guide sentences and seventeen regenerated pictures.
   The website check will run on GitHub when you do; it passed locally.
2. **Nothing to run, and nothing to decide.** No hardware, no second machine, no
   email.
3. **One thing to know rather than do.** The other window committed task 11.98
   two minutes before my first screenshot run started, so every picture in this
   commit is of the app *including* that change. Nothing collided — the sentence
   it corrected is on a screen state the harness does not photograph — but that
   is twice now that the two lanes have overlapped in one working tree, and both
   times it was fine only because somebody checked.
4. **A risk you are now carrying, and it is small.** The map picture on the site
   is a screen nobody has looked at on real hardware since the automatic viewshed
   started finishing. No page uses that image yet, so nothing is published wrong;
   but if the overlay is too heavy or the zoom too tight, the app has that
   behaviour today and only a screenshot has noticed.

---


---

## Findings for the code stream

*Things the guide had to explain that it should not have had to. Each becomes a numbered
task in `DEVELOPMENT_PLAN.md`, applied by the planning session — not by the content
session.*

*The `/w-02` entry above carries three, under "Findings for the code stream". They were
found by building the screenshot harness rather than by writing prose — the first guide
sentences are still `/w-03`'s job.*

---

## Open — waiting on Michael

*No entries yet.*

---

## Resolved

### Task `/w-18` — resolved 2026-09-13 by the planning session

**Done, the website gate is green again, and the task's most valuable output was a code bug it had
no obligation to find.**

**The page that did not exist.** Task 11.219 split a collar into two rows — this device's own
library, and each project's copy — and no page said so. `managing-your-tags.md` now does, in both
directions: a project's tag is a copy, and editing one side never reaches the other.
**`check_app_quotes` was green throughout the period when the guide was silent about a change this
size**, which is the same shape `/w-10` found a week earlier. **A quote check answers whether the
words match, never whether the page is true** — and that is why this lane's first acceptance line is
*read the guide against the code.* The two stale `Irregular/Malfunctioning` quotes are fixed, so a
website build passes again.

**The finding, and how it was found, is the part worth keeping.** `projectCopyCount` counts distinct
projects holding a lineage; called from Project Setup with a project's own tag, **the query matches
the tag itself**, so the count is one too high on that path. Steens' `East Rim` — copied nowhere —
reads *"One of your projects uses this collar."* **This was caught by looking at a photograph of the
screen, not by reading code.** Second time in a week a picture has caught something a green suite
did not, and it is an argument for the screenshot harness that has nothing to do with the website.

**It is above the line, as task 11.234.** That sentence is a **disclosure**, not a statistic: §2.5
and the cancelled task 11.29 are why it is a count and never names, so **the count is the entire
permitted disclosure and a wrong one is a false statement about who else holds somebody's collar** —
wrong in the direction that invents a sharer. Its long form then advises the reader that *"changes
here will not reach that project"*, about a project that does not exist. **The dialog's leftover
"Link to project" / "None (unlinked)" vocabulary is folded into the same task**, since it is the same
dialog and the same confusion: the form's own doc comment says the flow makes a copy, and only the
label still says link.

**Two screenshot notes carried into `WEBSITE_PLAN.md`.** `tag-database-viewer` is renamed
`project-tags-viewer` and now shoots Project Setup — **the old shot photographed a tag on a screen
that never held it.** And `log` / `log-supersede` drifted under 0.25% of pixels on all three
profiles for an unrelated reason: **not investigated, and deliberately not accepted**, so the
committed baseline still matches the live site. **That restraint is the right call and is worth
naming** — an unexplained diff accepted once becomes a baseline nobody can appeal to.

**11.67's aerial strings stay out of the guide.** No page covers aerial work, so nothing has
drifted, and a page about it is its own decision under Michael's scope rule rather than a
consequence of the strings existing. Recorded in `WEBSITE_PLAN.md` so it is inherited, not
rediscovered.

---

### Task `/w-18` — 2026-09-12 — Done

**A new page, a real harness fix (run to acceptance on all three profiles), and two findings
for the code stream — one of them a correctness bug, not a wording nit.**

**A new page: [`managing-your-tags.md`](../website/content/docs/managing-your-tags.md).**
Task 11.219 split a tag into two rows — this device's own tag *library* (the Tag Database
screen, no role governs it) and each project's own copy (Project Setup, where the
owner-only rule now lives) — and no page said so. Wrote it up, read against the code rather
than against the quote check: `check_app_quotes` was green the whole time this was wrong,
same shape `/w-10` found a week earlier. **The two things stated plainly, in both
directions:** a project's tag is a copy, and editing one side never reaches the other. Also
fixed `recording-a-bearing.md`, which still quoted the checkbox's old name,
*"Irregular/Malfunctioning"* — task 11.67 shortened it to **`Malfunctioning`** on every
screen and nobody had followed.

**Screenshots: one real fix, not just new pictures, and it was run and verified, not
assumed.** `integration_test/screenshots/capture_test.dart` was still photographing the
Steens project's tag on the *Tag Database* screen with a padlock beside it — both gone since
task 11.219, and that screen never held this tag at all (it was created on a different
device and arrived only as the project's own copy). It now navigates to Project Setup
instead, and the shot is renamed `tag-database-viewer` → `project-tags-viewer` to say what it
actually is. `shots.dart`, `readiness.dart`, `joined.dart` and `README.md` updated to match.
**Ran the full harness on all three profiles** (`iphone-6.1`, `iphone-6.9`, `ipad-13`) —
`project-tags-viewer` captured correctly on each (the East Rim tag, no padlock, a greyed
"remove from project" icon since this account is a contributor, not an owner) and
`tag-database-viewer` correctly stopped being captured. **Accepted, per screen, only what I
looked at**: the new tag screenshots, `project-setup-tags` and `tag-details-readonly`
(both moved because of this same change), and `record` / `record-note` / `record-truth`
(moved because task 11.67 added the *At altitude* checkbox beside *Malfunctioning* — the
same rename this task already fixed in prose). **Left alone on purpose:** `log` and
`log-supersede` also drifted slightly (under 0.25% of pixels, on all three profiles) for a
reason unrelated to tags or task 11.67 — not investigated, since it is out of this task's
scope, and not accepted, so the committed baseline still matches what is live on the site.
Flagging it here so the next content task does not have to rediscover it.

**Findings for the code stream — two.**

1. **A correctness bug, found by looking at what the harness actually photographed, not by
   reading the code.** `TagLibraryRepository.projectCopyCount` (`lib/data/repositories/tag_library_repository.dart`,
   around line 135) counts `DISTINCT project_id` in the `Tags` table for a given
   `lineage_id` — and when it is called from Project Setup's `_openTag`
   (`lib/features/more/screens/project_setup_screen.dart`, around line 1169) with a
   **project's own tag's** lineage, that query always finds at least one row: the tag's own,
   in its own project. So the count is inflated by exactly one everywhere it is used this
   way. Concretely: the Steens project's `East Rim` tag was never copied anywhere, and
   opening it (as seen in the new `tag-details-readonly` screenshot) shows
   *"One of your projects uses this collar"* — a claim that is false; there are zero other
   projects. A tag that genuinely is shared with one other project would show *"2 of your
   projects use this collar"* instead of the correct 1. **The Tag Database screen's own
   create-dialog use of the same method is unaffected** — there, the count is taken against
   a *library* entry's lineage, and a library entry is never itself a row in `Tags`, so no
   self-match happens. The fix is almost certainly excluding the tag's own `project_id` from
   the count when called with a project tag's lineage rather than a library entry's. The new
   guide page only quotes the singular-case message using a genuinely-shared library entry
   (where the count is correct), so nothing there needs to change once this is fixed.
2. **A small, cosmetic one.** `lib/widgets/tag_form.dart`'s create-tag dialog (used from the
   Tag Database screen) still labels its project picker **"Link to project"**, with a
   **"None (unlinked)"** option — leftover pre-copy-on-add vocabulary. Every other place this
   app talks about putting a collar into a project says *copy* (Project Setup's button is
   literally {{< app "Copy from library" >}}), and the form's own doc comment says the create
   flow "still offers to put a copy into a project, which is a copy rather than a link."
   Suggest renaming the label (e.g. "Also add to project") and the null option (e.g. "Don't
   add to a project"). The new guide page describes this control without quoting either
   string, so nothing there needs to change when it is renamed.

**Left open on purpose, not overlooked:** task 11.67's new aerial-altitude strings (*At
altitude*, *Receiver altitude*, *AGL — above ground*, *MSL — above sea level*, *Back on the
ground*, and the *"Altitude cleared — was 300 m / Restore"* notice) are not in the guide.
Correct for now — no page here covers aerial work at all, so nothing has drifted, and a page
about it is its own decision per `_index.md`'s own stated scope. Please carry this forward to
whichever task next touches the copy-changes list in `WEBSITE_PLAN.md`, since this task did
not append there itself (that list is the planning session's to keep, per `CLAUDE.md`'s
staging-discipline note) — the two items that belong on it are the new page and the
`recording-a-bearing.md` fix.

**For Michael:**
1. Nothing needs you to look at anything or run anything. Git is committed (see the commit
   this entry names once it lands); nothing to push beyond what you'd normally push.
2. Ask the planning session to give finding 1 above (the inflated tag-sharing count) a task
   number — it is a real, user-visible false claim ("one of your projects uses this collar"
   on a collar nothing else uses), not just a wording nit.

---

### Task `/w-10` — resolved 2026-09-10 by the planning session

**Two of its four findings were found by photographing a screen**, which is the argument for this
harness in one line. And **the four states it added had never been photographed at all** — so nothing
could have said whether task 11.199 moved them; it could only have failed to look. **That distinction
between a gap and a null result is the report's, and it is right.**

**Two of the asks are the planning session's own failures, and both are worth naming.**

**First: the copy-changes list.** The arrangement is that this session appends to it when it resolves
a task that changed wording. **It did not, eight times running** — every task from 11.202 to 11.209.
`/w-10` derived them from the code instead, **and that derivation is what found the defect**: task
11.205 gave the Position screen the *"New map tiles are not arriving"* band, which made a paragraph of
the guide false — it had told people that screen stays silent and to use the Main Map instead. **The
quoted-copy check was green throughout and correctly so: no quote drifted, a description did.**

> **The eight entries are appended now, late.** But the durable answer is not "append harder" — a
> hand-maintained list that failed eight of eight is the shape this project has a rule about. **So
> `CLAUDE.md` now says the list is a hint and deriving from the code is the step**, and a content task
> does the derivation regardless of what the list says.

**Second: the focused notes box, and the correction is sharper than the error.** This session wrote in
the plan's banner that `/w-13` had made that shot achievable. **It had not.** `/w-13` removed the
keyboard **by unfocusing at the shutter** — the right fix for a screen with nothing focused and **no
fix at all for a screen whose subject is a focused field.** `/w-10` then measured three mechanisms and
refuted all three, and **photographed the outcome rather than arguing it**: without a keyboard the box
asks for eight lines, the form does not scroll, and a gap opens above the save bar — **a state no
person ever sees.**

> **Nothing was left in the tree for it** — no hatch in the shutter, no preference dance that never
> produced a keyboard. **Both would have been things to keep true for nothing.** The banner is
> corrected with `/w-10`'s own wording: *the next task told this is possible should ask what changed
> about the keyboard, not about the focus.*

**The four findings become task 11.211**, and two of them are on screens somebody makes a decision
from. **The supersede picker cuts off the bearing** — the field you would actually recognise a record
by — worst on the smallest phone this app supports, where the observer's name is cut too. **And
Project Setup tells an owner their roles are device-local only**, which the join-and-approve design
made false; the guide says the opposite. **`/w-10` reported that rather than guessing which half to
change, which was right**; the planning session has made the call and 11.211 implements it.

**One thing done outside the lane's boundary and declared rather than assumed:** marking this entry
Done turns `command_file_staleness_test.dart` red unless the command file goes in the same commit. **It
went red on exactly that and the commit was refused**, which is the guard doing its job to a task that
was already doing the right thing.

---

### Task `/w-13` — resolved 2026-09-09 by the planning session

**The pictures were wrong and the app was not.** Seven screens had been drifting 20-47% with nothing
touching them, and the iPad's `truth-point-edit` 13.24%, and **it was one cause for all of them.**

**A field left focused by `autofocus: true` — in the truth-point Precision box and the compass
screen's declination control — opens a keyboard inset on a simulator with a hardware keyboard
attached, and iOS floats its own dismiss control over the app's chrome.** The inset **outlived the
screen that caused it** and rode into the next captures in the run: `map`,
`joined-sync-indicator`, `truth-point-panel`, `bearing-selected`, `bearing-dragged` and `position`.

> **Fixed at the one funnel every shutter already passes through**, and **confirmed rather than
> asserted**: `capturePngScreenshot` composites every window in the app's `UIWindowScene`, not only
> the Flutter one, which is why OS chrome could appear in a screenshot at all. **That is the
> difference between knowing the mechanism and having a plausible story.**

**And it says what it did not prove.** It did not independently reproduce the *"viewshed overlay
present in one capture, absent in the other"* half before the keyboard fix landed, so it reports **one
cause found, not one cause proven** — with the drift on all seven falling back to 0.1-2% as the
evidence. **That is the honest shape and this project asks for it constantly; it is rarer than it
should be.**

**A published screenshot has been wrong on the website, and nobody could have known.** `ipad-13`'s
`truth-point-edit.png` carried the keyboard-dismiss pill; `iphone-6.1`'s had the dialog pushed up with
a green focus ring and cursor showing and **its lower third cut off below the fold — including the
"What was found" control.** **The guide has been illustrating a dialog with a control missing.**

**Item 2's second fix is the one to remember, because the first fix broke something and was watched
breaking it.** Rebuilding `SyncController` to pin a live timestamp derives state from what is
*persisted*, and `SyncHealth.membershipEnded` is **deliberately never persisted** (task 11.116's own
choice — leaving a project is not a failure to remember). So the rebuilt state came back healthy and
`sync-removed`'s readiness condition never became true, **and the run refused to call the capture
finished.** The fix that stuck patches the in-memory state directly. **Then it swept the other four
sync states and grepped `DateTime.now()` across every screen this harness photographs, and reported
zero found elsewhere as a result rather than skipping it.**

**All 105 baselines — three profiles × 35 states — regenerated and accepted in one 22-minute run**,
nothing thrown, no duplicate. **And `/w-12`'s unanswered terrain question is answered**: 85.3, 100.9
and 101.0 seconds against a 180-second ceiling, no stall on any profile. **That closes `/w-12` and it
settles `/w-10`'s waiting condition** — the numbers in hand were 113.2 and 113.5, and all three fresh
ones are lower.

**Both open asks are folded into `/w-10` rather than made into a new command**, per Michael's standing
instruction:

- **Task 11.199's four states get photographed** — the paste preview card, Tag details' read-only
  view, Project Setup's tag subtitle, and the Log screen's supersede picker. **No picture has ever
  existed of any of them**, so the harness cannot say those screens did not change; it can only fail to
  notice. **That is a gap, not a null result**, and the report was right to name the distinction.
- **`/w-16`'s focused notes-box shot is taken now**, since the thing that made it impossible is the
  thing this task fixed. **It was held back rather than shot silently, and flagged rather than
  forgotten.**

---

### Task `/w-16` — resolved 2026-09-08, and `/w-15` is closed with it

**Three profiles, 34 states, all regenerated and accepted, nothing through the escape hatch.**

**Item 1 — `/w-15` is Done.** The Position map is required to be *drawn* now, not merely to have no
images decoding — **the vacuous condition it was warned about was avoided** — and **four consecutive
runs came back pixel-identical.** That is the difference between a check that passes and a check that
means something. `/w-15`'s command file was already deleted when its work moved.

**Item 2 — the banner is rewritten.** Four of its statements had become false and are struck rather
than deleted, so anybody acting on a stale memory of it meets the correction.

**Item 3 — folded into task 11.196**, which was already *the third home of one vocabulary*. **It is
now the fourth.** The map's bearing card says *"Moderate · fair"* where the Record wheels say **Med**
and the Position rows say **Fair** — **one reading, three descriptions**, and *Moderate* is a fourth
word for a value stored as `medium`. **11.196 is also told to say whether task 11.98's
checked-vocabulary test covers these sites**, because a vocabulary test four screens have escaped is
worth a sentence about its own reach.

**Item 4 — decided, and folded into `/w-13`. The decision is: pin them.** Two iPad pictures moved
0.15% and 0.14% **purely because the calendar rolled over mid-task**, so they will report CHANGED on
any run taken on a different day than the last accept, **forever**. **A run that reports two changes
every day teaches its reader to skim the CHANGED list** — which is precisely the failure the accept
gate exists to prevent, and the risk this project refused goldens over. `dismissStaleWarning` already
pins the last-successful-sync stamp; the last-tried stamps are what is left. **`/w-13` is also told to
sweep for other live stamps**, since these two were found by the calendar happening to turn, which is
luck rather than a sweep.

**Item 5 — also folded into `/w-13`.** The manifest claims two iPad states where there is one; the
duplicate detector has said so on every run since `/w-14`. **Either make the second state genuinely
different or drop it** — **what is not acceptable is a detector reporting a duplicate on every run**,
which is another line teaching its reader to skim.

**The judgement against the brief is upheld, and it was the right half to take.** `/w-16` was told to
photograph the notes box *focused*; it photographed it **at rest**, because a focused shot in the
simulator carries **the same floating-keyboard control `/w-13` exists about** — reproducible, not a
one-off. **The brief's own justification named the at-rest layout** (*"the box now fills the screen
above SAVE NOTE"*), so its two halves disagreed and the task took the half naming the subject. **The
focused shot becomes possible when `/w-13` lands; it is the same piece of work**, and that is written
into `/w-13`.

**And Michael has his answer.** The `Irregular/Malfunctioning` checkbox **fits on a 6.1-inch phone
with room to spare** — *"Normal · 46 bpm  ☐ ⚠ Irregular/Malfunctioning"* on one unwrapped line, with
the whole form including SAVE still above the fold. **`iphone-6.1/record.png` is the first photograph
this project has ever taken of the screen size all its layout rules are written for.**

**One limit recorded rather than fixed:** the 6.1-inch bearing-drag pictures are **one zoom level
further out** than the other profiles', because at the default zoom that screen has no bearing tip on
the pane. Nothing is wrong — **but two profiles' drag pictures side by side will not match.**


### Task `/w-15` — resolved 2026-09-07 by the planning session (the task stays Partial)

**The guide is repaired and the drift check passes — 162 quotes, 11 pages, 0 waivers.** It stays
Partial for one honest reason: **`iphone-6.9/position` was deliberately not accepted**, because
accepting it would have published a picture of a map that has not drawn.

**Michael asked that new asks be folded into existing tasks where possible. All three of `/w-15`'s
went into `/w-16`, which was already the harness task.** No new commands.

**Item 1 — the finding, and the part that matters is the trap it disarmed.** The phone's Position
shot photographs a **nearly blank grey map**; the 16.15%-then-5.61% instability the brief warned
about is **how many tiles happened to arrive before the shutter**, not the screen changing. **The
iPad's Position map draws completely and is stable at 0.13% twice**, which is what makes it a capture
defect rather than a screen defect.

> **And it named the fix that would have looked right and been vacuous.** `_noImagesDecoding` is
> `pendingImageCount == 0`, **which is also true before the first tile is requested** — bolting it on
> **passes immediately and publishes the same blank map under a green readiness line.** That is this
> project's check-that-cannot-distinguish-success-from-its-own-failure, spotted before it was built
> rather than after. **`/w-16` is told it needs a condition that asserts tiles are *drawn*.**

**Item 2 — seven broken quotes, not six.** The seventh was *"Draft autosaves"*, which task 11.197
removed from the pinned bar. **It was on the copy list and the brief's count was taken from the
list.** No decision needed; recorded because it is the second time in two days that a number copied
from that list was short.

**Item 3 — the copy list said something that had stopped being true, and nothing went red.** The
brief's biggest premise was task 11.195's header row, **which task 11.197 reverted the same day**.
`/w-15` worked it out from `observation_logging_screen.dart`'s own header. **The list is corrected in
place** and the paragraph is left with its retraction on it, because that file is append-only —
**and this is the copy-changes-list-is-a-convenience rule paying its own cost within a day of being
written.**

**Item 4 — folded into `/w-16`, and its general half is deliberately not built.** The guide says
`+ Quick-add tag` *"at the bottom of the wheel"*; the control there now reads `＋ Add new tag`, and
`+ Quick-add tag` is **a different button on the empty state.** **The checker cannot see this,
because both strings exist in `lib/` — the quote is "still in the app", just not where the sentence
puts it.** **The check verifies the strings a page quotes, never the claim the page makes around
them.** `/w-16` fixes the sentence and is told to **record what an instrument for that class would
need rather than build one.**

**Item 5 — answered yes, and folded in.** The open notes box is a genuinely different layout rather
than a taller field, no published picture shows it, and **it needs a readiness condition that waits
for a state rather than a duration** — `CLAUDE.md`'s rule about reacting to something that is itself
animating applies directly to the keyboard's rise.

**One thing Michael is owed from `/w-16`:** the `Irregular/Malfunctioning` checkbox shares a line with
the mode line and **fits with room to spare on the 6.9-inch phone. Nobody has ever seen it on a
6.1-inch one.**


### Task `/w-14` — resolved 2026-09-07 by the planning session

**The site quotes the app correctly again, both screenshot profiles are re-captured, and the sync
page no longer describes a bar that does not exist.** The prediction held exactly: **one failure
expected, one found, nothing unexpected.**

**Item 1 — the cut-off button is task 11.193, above the line, and it is joined to the flag Michael
asked for the same day.** `Preview / set position on map` is sliced to a green sliver on a 6.9-inch
phone at the default text size, because 11.187's per-mode rate line pushed the form down about one
line. **The task checked the obvious suspect before reporting** — it is ordinary overflow, not
`BudgetedColumn` withdrawing the button — **which is exactly the discipline that keeps a brief from
sending somebody to the wrong file.** And committing the honest picture was right: **a truthful
picture of a rough screen beats a stale picture of a screen that no longer exists.**

**Item 2 — the answer is that the planning session appends, and it did not.** Tasks 11.189, 11.190
and 11.191 all landed after that list was last written and **none of their copy changes reached it —
because the planning session resolved those entries and did not append.** `/w-14` only knew because
its own command file spelled the changes out.

> **But the useful conclusion is the opposite of building more machinery.** That list is a
> **hand-kept convenience, and the screenshot harness is the derivation.** The harness measured 26
> screens moving by 14–25% of their pixels and named every one; the list would only ever have
> agreed with it. **So: keep appending, because it makes the next content task faster — and never
> treat it as the safety net, because it is not the thing that would catch a missed change.**
> `CLAUDE.md` now says so.

**Item 3 — Michael decided it, and it grew into a code task.** The guide's *"a weak, irregular
signal"* is now **`/w-15`**: rewrite around **bearing quality**, which is the field that actually
means *I am not sure about this direction*. **And he asked for something the app does not have** — a
per-recording flag for a collar that sounds wrong, an irregular inter-pulse duration. **That is task
11.193's second half**, and the brief is explicit that it is *not* `TagStatus.malfunction`: that
status is a current-state fact about the collar, while this is a fact about one listening moment, and
several of those are the evidence that would justify setting it. **`/w-15` is told not to blur them.**

**Item 4 — recorded in `WEBSITE_PLAN.md` where `/w-13` will meet it.** The floating-keyboard control
in the `ipad-13/truth-point-edit` baseline **reproduces on a fresh capture**, so **re-shooting is not
the fix and replacing the baseline would only re-publish the defect.** The lead worth following is
not taking the picture with a text field focused.

**Item 5 — the number is recorded so `/w-10` starts from a measurement.** Two consecutive cold-cache
runs put the map's readiness at **113.2 s and 113.5 s against a 180 s ceiling** — reproducible to
within a third of a second. **That is a measurement rather than an anecdote**, and the analysis
`/w-10` asked for is still owed.

**Item 6 — noted, not fixed.** On the iPad profile, `owner-pending-request` and
`owner-members-and-code` now photograph **one** state, because removing the bar gave the screen its
height back and the pending section no longer needs scrolling. **No guide page uses the iPad
profile**, so nothing on the site shows one picture under two captions — **but the manifest claims
two states where there is one**, which is a small lie in a file whose whole job is saying what was
photographed. **For whoever runs this lane next.**

**And the uncertainty was stated properly, which is why it can be acted on.** Seven of sixty-six
images were looked at; the rest were accepted on the harness's percentages **plus a nameable reason
for each move** — which is a different and much better claim than "they looked fine". The clipped
line on the `sync-removed` card that may hold a wall-clock timestamp is **exactly the kind of thing
that should be written down before it produces a mystery diff.**


### Task `/w-12` — resolved 2026-09-04 by the planning session

**Item 2 — nothing needed from the code lane.** Noted; all four states drove from task 11.97's
substituted server exactly as `/w-10` predicted.

**Item 1 — became `/w-13`, and the cause is not the one that was guessed.** `/w-12` measured the
percentage (13.24%) and guessed *"something about how the simulator or its window was sized"*.
**The planning session measured the cause instead**, and it is in the same family but not the same
thing:

- Both images are **2064×2752** — nothing was resized.
- The **top 400 rows are pixel-identical** — it is not a global shift.
- It is **two opposite shifts**: rows 400–1900 moved **down 51 device pixels**, rows 1900–2752
  moved **up 40**. Residual drops from 10.9 to 2.96 under that model, so it is real.
- **`iphone-6.9` is bit-identical between runs — 0.00%.** `ipad-13` only.
- **"Every line appears twice" is what a pixel diff does to a shift**, not a doubled render.

**And the committed image is the wrong one.** The published baseline carries a white pill with a
keyboard glyph and a `⋯` badge, floating over the app's own tab bar — **iOS's floating-keyboard
control, which Flutter does not draw.** The new capture does not have it. The dialog has a focused
text field, so a keyboard inset explains the displacement: a centred dialog moves down, the bottom
bar lifts. **So `/w-13` accepts the new image rather than investigating an app defect that is not
there** — and is told to verify the pill's identity through the capture path rather than from its
appearance, and to say so if that check refutes the whole explanation.

**A second finding, which is that an instruction went unanswered.** `/w-12`'s command asked it to
report what the terrain readout showed — task 11.143 fixed a readout that counted fetches
*started*, and three causes for the original stall are still open. **Its entry does not mention
terrain at all.** The command was committed in `8f3322e`, before `e5397f4`, so it was there to be
read. **Carried to `/w-13`, which runs the harness again.**

**The general lesson is in `CLAUDE.md` now:** a baseline can photograph the harness's environment
rather than the app, and a diff cannot tell that from a real change — so replacing a baseline must
always say which of the two it was.



### `/w-10` — 2026-09-03 — commit e44b6bd — Partial

**Stopped at:** item 1, the sync bar's failure states. Four were driven successfully and
none could be photographed, because of a defect in `lib/` this lane may not fix (finding 1
below). Items 0, 2, 3 and 4 are complete.

**In one sentence:** before taking any new pictures I found that the screenshot harness had
been waiting on a retry rule the app does not have — which is why a wrong picture was on the
site — and after fixing that I could photograph the bearing-drag gesture and App Info, catch
the guide up with three days of copy changes, and establish that the sync bar's failure
states are drivable but not photographable.

**For the planning session**

1. **The task's own brief and `WEBSITE_PLAN.md` disagree about task 11.124, and the brief is
   the stale one.** The brief says 11.124 *"will replace"* the held-record wording; the
   plan's copy section records it as **landed on 2026-09-02**, and
   `lib/data/sync/held_row_details.dart` carries the four specific messages. **Please
   correct the "Not settled, and newly so" paragraph** in *What is settled enough to
   document*: that wording is now two things — a sentence naming the field when the server
   explained itself, and an honest default when it did not — and both are stable enough to
   describe. Nothing on the site has to move, because I described the behaviour rather than
   reciting the sentence, but the next task reading that paragraph will hold back copy it
   does not need to.

2. **The drift check would not have caught any of the three copy changes, and it is a
   different hole from the one already written down.** Points 1–8 of `website/README.md` are
   all about a quote or a description going stale. This is the opposite: the guide had **no
   sentence at all** about signing in and **no sentence at all** about what a name may
   contain, so there was nothing to drift and green was the right answer. **A check that
   verifies the strings a page quotes can never notice a string the page ought to quote and
   does not.** I have written that up as point 9 in that README and I am **not** proposing a
   check — the thing that works is the standing obligation on both lanes to say in a comms
   entry when user-visible copy changes, and it is what caught all three: every one reached
   me through `WEBSITE_PLAN.md`'s *copy the guide must not quote from memory* section rather
   than through a red build. **Nothing to do beyond knowing it.**

3. **The tile-provider contact obligation is done, and it needs Michael rather than you** —
   see his list, item 3. `website/content/support.md` now names the lab and points at the
   repository this site is published from.

4. **Which sync-bar states I chose, decided by the header table in
   `test/core/providers/sync_bar_states_end_to_end_test.dart` rather than by a guess.**
   Chosen: *offline*, *records refused*, *records the server sent that this build could not
   read*, *no longer on this project* — the four the brief named and the four the guide's
   failure section has most to say about. **Rejected, with reasons:** *Syncing…*, a moment
   this run has no reason to hold open; *Sync isn't working*, *the server is refusing
   access*, *Signed out*, *Sync needs an update* and the certificate refusal — all five
   drivable, all five left out because the guide handles each in one sentence and five
   near-identical bars would be five pictures teaching one fact each; and the three the
   table says no substituted server can produce, because they are facts about a clock or
   about an address refused before any connection is built.

5. **`/w-10`'s brief asked for the four sync-bar captures and they are the one thing it did
   not get.** When finding 1 is fixed, the scaffolding is waiting: `markRecentlySynced`,
   `breakEveryCall`, `restoreTheServer` and `runSyncRound` in
   `integration_test/screenshots/joined.dart`, the ordering the classification requires
   written beside them, and the whole measurement where the captures would go in
   `capture_test.dart`. **It is worth a short follow-up task rather than a re-run of this
   one** — everything else here is done and a fresh window should not re-derive it.

**For Michael**

1. **Nothing to run.** Both screenshot profiles were regenerated and accepted, the quoted-copy
   check passes, the self-test of that check passes, the site builds, all 2078 client tests
   pass, and everything is committed.
2. **Push when you like** — commit `e44b6bd` is on `main` and not pushed.
3. **One decision, and it is the only one.** The app tells map tile providers how to reach a
   person by publishing this site's address in every tile request, and the site had no
   contact route on it — a published contact nobody can contact. I have put one on the
   Support page: it names the lab and points at
   `github.com/dynamic-and-active-systems-lab/tritrack-site`, the repository this site is
   published from, because that is the only route I could establish from inside this
   repository. **If you would rather it were an email address or a lab web page, say so and
   it is a one-line change. Either way, please check that the repository is public and that
   its issues are open** — if it is not reachable, the page is back to promising something it
   does not deliver.
4. **Four new pictures worth your eye**, because a screenshot is the one thing here no check
   can judge. Two of them illustrate the bearing tip-drag on the new map page. **The
   selected-bearing one is honest but not flattering:** the generated session happened to put
   a short bearing near the top corner, so the handle you are meant to notice is a small dot
   half behind the map's own buttons. It is accurate and the page says so, but if you want a
   clearer picture, ask for a task to seed a bearing positioned for it.
5. **Two risks you are now carrying.**
   **The first is the guide's.** The tip-drag gesture has no discoverability in the app —
   nothing says a bearing can be dragged and the handle only appears once one is selected —
   so the new page is the whole of the telling. Somebody who does not read it does not find
   the feature.
   **The second is the app's, and it is finding 1 below:** every time the sync bar changes
   what it says, a debug build trips an internal assertion. On the phone in your pocket that
   is invisible, because release builds do not check it. It is a real defect and it is what
   stopped this task photographing the failure states.

**Findings for the code stream** — two, and the first is the reason this entry says Partial.

1. **A completed sync round crashes the app in a debug build, every time, and it is why the
   sync bar's failure states have no pictures.** Whenever a round changes what the bar says
   — a clean round, a failed one, one that drops an incoming record — the framework reports
   *"setState() or markNeedsBuild() called during build"*, and in the screenshot run the test
   stops there. **Measured over eight runs on 2026-09-03**, three different orderings, on
   `iphone-6.9`. It is **not a timeout**: the fourth run carried an explicit thirty-minute
   ceiling and stopped at 4m11s, at the round rather than at a clock. **The first
   `package:tritrack` frame is `_EstimationContentState.build`**, in
   `lib/features/position_estimation/screens/position_estimation_screen.dart` — and that
   screen is in the widget tree whichever tab is showing, because
   `StatefulShellRoute.indexedStack` keeps every visited branch mounted, so there is nowhere
   in the app to stand while a round completes. **This is task 11.95's class on a different
   screen.** What it costs a person: nothing visible in a release build, where the assertion
   is not checked — but a widget writing during its own build is a real ordering fault, and
   it is currently blocking four pictures the guide's most-read failure section needs.
   **The four states themselves are fine** — the run printed `healthy`, `offline` and
   `recordsMissing: 0 pending, 0 held, 1 dropped`, so task 11.97's seam works exactly as
   advertised and it is only the photographing that fails.

2. **The map's terrain fetch reached 72 of 72 tiles and then never finished, on both profiles
   in the same run.** The status bar sat at *"Downloading terrain… 72/72"* past a three-minute
   ceiling and no viewshed was ever drawn; two runs earlier the same screen was ready in under
   a second. **I did not establish the cause and I am flagging that** — it may be the DEM
   source rate-limiting a machine that had run the harness eight times in two hours, and it may
   be the half-written-tile class task 11.143 is about. **What is worth knowing either way is
   the shape:** the count reaching its total is not the same as the fetch completing, and
   nothing on that screen distinguishes them. `map.png` and `position.png` were restored from
   git rather than accepted, because neither screen is touched by this task and the readiness
   check correctly refused to call the new ones finished.

**Detail, for whoever reads the diff**

- **Item 0, and it is the one that mattered most.** `harness.dart` built its
  `ProviderContainer` with no `retry:`. `main.dart` passes `appRetryPolicy` — three attempts,
  under two seconds — and a container without it runs Riverpod's default: ten attempts over
  38.2 seconds. So the Members screen's two server-backed sections, which fail immediately on
  a device with no server, rendered their explanation in 1.6 s in the app and spun for twenty
  in the harness. **`/w-11` saw the twenty seconds, concluded the providers never resolve,
  wrote that into a readiness comment, and filed it for the code lane**; task 11.142 went
  looking for the spinners and found this file. The container now takes the app's policy, the
  comment is corrected, the spinner check is back on `project-members`, and the picture has
  been re-taken on both profiles — it now shows task 11.142's four empty-state sentences
  instead of two spinners.
- **The guard for it is a script, not a test, and that is a constraint.** `flutter test`
  refuses a file under `integration_test/` — it treats the directory as needing a device — so
  `preflight.dart` follows `review.dart`: plain Dart, exit-code contract, run by
  `regenerate.sh` before the lock and before any simulator boots. Widening
  `test/documentation/retry_policy_applied_test.dart` into `integration_test/` would have put
  a content-lane file into the code lane's red, which is task 11.118's lesson. **Watched red
  and green** — and the red caught a defect in the check itself on the first try: it returned
  an `int` from `main`, which Dart ignores, so it printed all three failure lines and exited
  0. A check that can report a finding and cannot fail is the exact shape this directory keeps
  deleting.
- **`joined.dart` carried two sentences that had stopped being true, and the second is the
  one the brief warned about.** It said `SyncController` builds its own HTTP transport (task
  11.97 removed that) and that the sync engine is never faked (true of the narrow override,
  false of the wide one). The override is now `serverTransportProvider`, and the file states
  **per capture** what the fake server does rather than making one claim about all of them.
  `ScreenshotProjectLinkController` is deleted: that controller now reads the same provider
  through `requireServerTransport`, so the subclass was a description of an app that no longer
  exists, and every join in the run is the app's own code.
- **The drag needed the long press the app's own copy describes.** Two runs pressed and moved
  immediately; the handle offers a pan and the map underneath offers a pan, they went into the
  same gesture arena, and the map won — which the run reported as *"the drawn-length readout is
  not on screen"* rather than as a silent bad picture. Holding still past the long-press
  threshold first lets the handle's own recogniser take it. **Two other things the run caught
  about itself:** my first "does this bearing have room to be dragged" check wrote its margins
  in pixels where the window is measured in points, so a 220-point margin excluded the right
  half of a 440-point-wide screen and the run said so, naming both candidates and where each
  would have finished; and the offline state first reported `staleRecordsPending` rather than
  `offline`, because the fixture last synced in February and staleness outranks a failed round.
- **The mid-drag picture carries the test binding's blue pointer crosshair**, because the
  readout exists only while a finger is down. The app draws nothing of the kind. **Disclosed in
  the caption on the site**, the same way the invented compass heading is, rather than
  suppressed — and written into the harness README as a limitation, because any future capture
  taken mid-gesture inherits it.
- **What the guide gained.** A new page for the tip-drag gesture, carrying the *why* as well as
  the *how* — a longer wedge is a wider one, because angular uncertainty does not shrink with
  distance — and saying plainly that the gesture does not transfer to the Position screen. A
  sign-in section that does **not** promise an email, because the app genuinely cannot know how
  a code was delivered and the server answers identically either way. The name rule written as
  the allowlist it is (letters and marks in every script, digits, dashes, spaces, apostrophes,
  full stops, commas, the middle dot) rather than as a list of exclusions, with the visible and
  invisible cases kept apart and only the invisible one telling anybody to retype. The
  held-record behaviour described rather than quoted. And the tile-health message, with the one
  thing the guide must not say — that *every* map tells you — written as where it does and does
  not appear.

---



---

**Resolved 2026-09-03 by the planning session.**
1. **Corrected — you were right and the brief was the stale one.** `WEBSITE_PLAN.md`'s paragraph
   said 11.124 *"will replace"* the held-record wording; **11.124 landed on 2026-09-02** and the
   wording is now two stable things, a sentence naming the field when the server explained itself
   and 11.122's honest default when it did not. **A "not settled yet" note that outlives the
   settling is the same defect as a decision recorded as still owed** — and it costs more here,
   because it silently narrows what the guide is willing to say.
2. **Recorded as a standing rule, and the conclusion — *do not build a check* — is the right
   one.** **A check that verifies the strings a page quotes can never notice a string the page
   ought to quote and does not.** The guide had *no sentence at all* about signing in and *none*
   about what a name may contain, so there was nothing to drift and green was correct. **What
   worked was the standing obligation on both lanes to declare copy changes in a comms entry** —
   all three arrived that way. **Not every gap wants a check; some want a habit, and knowing which
   is which is the finding.**
3. **Carried to Michael**, with your question attached: is the repository public and are its
   issues open.
4. **Endorsed, including the five you left out.** *Five near-identical bars would be five pictures
   teaching one fact each* is the sentence; it is now in `/w-12`'s brief so nobody re-adds them.
5. **Agreed — task `/w-12`, small, and it does not re-derive anything.** The scaffolding you left
   is named in it explicitly. It waits on **task 11.144**.

**On the two findings for the code stream.**
1. **Task 11.144, above the line.** Eight runs, three orderings, a thirty-minute ceiling that
   stopped at 4m11s — **that is a measurement, not a suspicion**, and naming the first
   `package:tritrack` frame is what makes it actionable. **The part that makes it more than a test
   nuisance is yours: `StatefulShellRoute.indexedStack` keeps every visited branch mounted, so
   there is nowhere in the app to stand while a round completes** — this fires from any tab. The
   task is told to ask **how many** branches have the shape rather than whether this one does.
   **And your insistence that the states themselves are fine — `healthy`, `offline`,
   `recordsMissing: 0 pending, 0 held, 1 dropped` — is what stops the next window hunting a defect
   in the sync bar.**
2. **Folded into task 11.143 as a candidate, with your uncertainty intact.** It may be DEM
   rate-limiting after eight harness runs in two hours; it may be the half-written-tile class.
   **The shape is kept whichever it turns out to be: the count reaching its total is not the same
   as the fetch completing, and nothing on that screen distinguishes them** — a progress readout
   that has arrived at its own denominator and stopped is the most confusing state to leave
   somebody in, because it looks finished. **Restoring `map.png` and `position.png` from git rather
   than accepting them was right**, and the readiness check refusing to call them finished is that
   instrument doing exactly what `/w-11` built it for.

**And one thing about this file rather than about your work.** Its *"Findings for the code stream"*
blocks are **never moved when they are resolved**, and they sit in the half a reader treats as
live. **The planning session read `/w-07`'s block top-down today and nearly filed five findings
that were closed on 2026-08-31** — the truth-point marker among them, which is task 11.100, Done.
Both stale blocks are now annotated, and **resolving a website comms entry now means marking its
findings block too.**

---

### Task /w-11 — 2026-09-03 — commit a457243 — Done

**What changed, in one sentence.** The screenshot harness now waits for each screen to
*have finished* before it photographs it, instead of sleeping for a number somebody typed —
and the first time that was switched on it found two screens the guide has been
illustrating with pictures of an app that had not finished drawing.

**For the planning session**

1. **Please open two code-lane tasks. The first is a live app defect the guide has been
   publishing a picture of.** On a device with **no server configured**, the project
   Members screen shows a "Join code" heading and a "Waiting to join" heading with a
   **spinner under each that never stops** — both need the server, and with none
   configured nothing ever resolves and nothing on screen says why. The committed
   `project-members.png` has had those two spinners in it on both profiles since it was
   first taken; nobody noticed until a check asked "is anything still loading?" and got
   *yes* for twenty seconds. **A device with no server is the app's default, fully
   supported state (task 10.2), so this is what a first-time user sees.** Ask for a task:
   *on an unconfigured device, those two sections should say why they are empty rather
   than spin forever.*
2. **The second is smaller and is about honesty rather than a stuck screen.** The map
   fetches terrain and, if a fetch fails partway, **carries on and draws a viewshed
   computed from whatever terrain arrived**, with nothing on screen distinguishing that
   from a complete one. I did not see it happen, so this is a reading of the code
   (`_ensureTerrainForRegion` stops on the first failure and the caller composes anyway),
   not an observation — **flagging it as uncertain.** It matters here because the harness
   cannot see it either: my readiness condition can tell "an overlay was drawn" from "none
   was", and cannot tell "drawn from all 72 tiles" from "drawn from 30".
3. **`/w-09`'s explanation of the 72 terrain tiles was wrong, and this is the sixth wrong
   cause on this project in a week.** It blamed them on its own richer fixture — eight
   bearings instead of three. **The tile count does not depend on the fixture at all:** the
   map fetches the terrain disc around the GPS fix, sized by a fixed 35 km viewshed range,
   which at the seeded coordinates is 8 tile rows × 9 tile columns = **72, whatever the
   seed holds.** Bringing the fixture to five bearings changed it by zero tiles. What
   actually varies is whether the simulator's elevation cache is warm — **and
   `README.md` item 8 had written that down a month earlier.** No action needed beyond
   knowing it; the corrected explanation is now in `shots.dart` and `README.md`.
4. **Task 11.139 has its number: four rows, on both devices, for an ordinary session.**
   `/w-09` asked whether the Position screen's bearings panel fits. At five bearings —
   Michael's answer for what a real session holds — the panel shows **four of the five
   rows on the 6.9-inch iPhone and four of five on the 13-inch iPad.** The screen says
   `N=5` and `5 of 5 selected` directly above a list showing four. That is a statement
   about the ordinary case, not about a stress fixture, and it is stronger than the
   eight-bearing version `/w-09` reported.
5. **Nothing was needed from the code lane to do this task**, and `/w-10` is unblocked —
   it can take its new captures against an instrument that can now tell a finished screen
   from an unfinished one.

**For Michael**

1. **Nothing to run and nothing to decide.** Both screenshot profiles were regenerated and
   accepted, the website's quoted-copy check passes, and everything is committed.
2. **Push when you like** — the commit is on `main` and not pushed.
3. **One thing you may notice on the website when it next rebuilds:** the map picture now
   shows five bearing fans instead of eight, and the Position screen shows five bearings
   instead of eight. That is deliberate — you said a tracker rarely takes more than five
   bearings to one tag, and the pictures are the guide's claim about what the app looks
   like in use, so they should look like a session you would actually have.
4. **A risk you are now carrying, and it is small:** the two never-ending spinners on the
   Members screen are still in the published picture and still in the app. Somebody
   setting the app up without a server will see them and have nothing to tell them why.

**Findings for the code stream** — items 1 and 2 above.

**Detail, for whoever reads the diff**

- **What was wrong.** A capture navigated, slept for a per-screen duration, and fired the
  shutter. On 2026-09-02 the map needed longer than its 12 seconds, so the run photographed
  the map and the truth-point panel with *"Downloading terrain… 12/72"* across the bottom
  **while reporting "26 of 26 states photographed; no screen threw."** The wait was raised
  to 90 seconds, which fixed the pictures and left the instrument as blind as before.
- **What replaces it.** `integration_test/screenshots/readiness.dart` holds **one
  condition per state** — the map's is *the viewshed overlay is drawn, the status bar is
  quiet and no image is still decoding*; the compass's is *the magnetic readout shows a
  number instead of a dash*; the log's is *a seeded row is on screen and nothing is
  spinning*. A condition returns what it is **still waiting for**, and that phrase is what
  the run prints when it gives up. Every shutter in the run goes through one funnel, so a
  state cannot be photographed without being asked.
- **Watched going red, which was the point.** With the map's ceiling temporarily cut to 8
  seconds on a cold elevation cache, the run reported *"map: still not ready after 8.1s —
  the status bar still says Downloading terrain… 9/72; the image filed as map is of a
  screen that had not finished"* and caught **four** states that way, including two nobody
  had suspected. Before this change that same run would have said *26 of 26, no screen
  threw*.
- **It also caught itself, once.** My first condition for the map asked whether
  flutter_map's overlay layer was in the widget tree. It was — and the map still
  photographed with **no viewshed on it, twice, byte-identically**, because the layer's
  image had not finished decoding. **A widget existing is not a widget drawn.** The
  condition now also asks the framework whether any image is still being decoded, and the
  map picture came back.
- **What the 90 seconds becomes.** A **ceiling on patience**, not a duration: a state ready
  in 900 ms is photographed at 900 ms. Most states are ready in under a tenth of a second;
  the two map states have a three-minute ceiling. **Measured, across six runs on this
  machine: the map takes 79–100 seconds**, all of it a cold 72-tile terrain fetch plus the
  decode. **Three of those six runs took longer than 90 seconds** — so `/w-09`'s number was
  not merely fragile in principle, it was already too small.
- **The denominator, as asked.** **0 of 26 states have no readiness condition.** The run
  prints that line every time, including when it is zero, and refuses to start if
  `readiness.dart` names a state no run captures.
- **One declared exception, and it is a choice rather than an oversight.** The Members
  screen's condition does not ask whether anything is spinning, because of finding 1 — that
  screen never stops spinning on an unconfigured device and cannot be waited out of it. The
  reason is written where the exception is, and the check goes back in when the app is
  fixed.
- **The fixture, and a distinction it now states.** Sage went from eight bearings to five.
  `seed.dart` already had a rule about the *size* of a value — at least one name and note is
  a realistic worst case. It now also has a rule about the *shape of a session*, pointing the
  other way: **these images are the guide's claim about the app in use, so the session behind
  them has to be one somebody could have had.** A test fixture may deliberately exceed
  reality — that is often its job — **but it has to say so**, and a picture carries no
  footnote.

**Resolved 2026-09-03 by the planning session.**
1, 2. **One code-lane task, 11.142, and item A is above the line.** They are one question asked
   twice — *what does the app show when something did not finish?* — and item A is what a
   first-time user sees on the app's **default, fully supported** configuration. **The picture in
   the published guide has had both spinners in it since it was first taken and nobody noticed for
   weeks**, because nothing was wrong by any assertion anybody had written. The task is told to
   distinguish *no server configured* from *the server did not answer*, and to re-take the picture.
   **Item B keeps your uncertainty rather than losing it in the retelling:** you read the code and
   did not see it happen, so the task must **establish it before designing anything**, and *"it
   cannot happen"* is an acceptable result. **The reason it is a task rather than a note is the
   sentence you wrote about your own instrument** — a readiness condition that can tell *an
   overlay was drawn* from *none was* and cannot tell *drawn from 72 tiles* from *drawn from 30*.
   **A published picture could be wrong about the terrain and nothing would object.**
3. **Recorded, and it is worse than a sixth wrong cause.** The 72 tiles come from a disc sized by
   a fixed 35 km viewshed range — 8 rows × 9 columns at the seeded coordinates, **whatever the
   seed holds** — and going from eight bearings to five changed it by zero. **`README.md` item 8
   had written that down a month earlier.** So the cause was not merely unverified; **it was
   contradicted by a document in the same repository that nobody re-read.** `CLAUDE.md`'s rule now
   carries that sharpening.
4. **Task 11.139 is raised again — on this evidence, and the entry says so, so the two reasons are
   not confused.** It was raised for the text-scale story and returned when Michael's text size
   turned out to be the default. **Your measurement is a different and better reason: four of five
   rows on a 6.9-inch iPhone and four of five on a 13-inch iPad, with the screen saying `N=5` and
   `5 of 5 selected` directly above a list showing four.** Ordinary case, both devices, **the
   screen contradicting itself in one glance** — read by somebody deciding which bearings to
   include before saving a position.
5. **Confirmed; `/w-10` is unblocked** — though it now waits on 11.142's item A, so it does not
   photograph the Members screen wrong a third time.

**And two sentences from this task are now standing rules, because both are the project's oldest
class stated better than it has been stated before.**
**"A widget existing is not a widget drawn."** Your first map condition asked whether the overlay
layer was in the widget tree; it was, and the map photographed with no viewshed on it **twice,
byte-identically**, because the image had not finished decoding. **A readiness check must assert
the observable outcome, not the mechanism that ought to produce it.**
**And a readiness condition returns what it is still waiting for, not a boolean** — so a timeout
prints *"the status bar still says Downloading terrain… 9/72"* and is a diagnosis rather than a
duration. **A check that can only say "no" makes whoever reads the log guess**, and this project
has spent several tasks on exactly that guess.

---

### `/w-09` — 2026-09-03 — commit c331aca — Done

**In one sentence:** the invented data the screenshots are taken over now includes long
names and notes of the kind a field biologist actually types, and eight bearings on one
collar instead of three — and while doing that I found out why the screenshot harness never
reported the row that overflowed on Michael's phone. **It was not the fixture, and the
harness was not blind.**

**For the planning session**

1. **The silence is explained, and the explanation contradicts what task 11.102 concluded.
   Please correct the record.** The harness photographed that panel before the fix and the
   row **fit, with visible space to spare** — I pulled the pre-fix image out of git and
   looked at it. So there was nothing for `takeException` to report. The `460–470` pixel
   threshold 11.102 measured is real, but it was measured in a **widget test**, which draws
   text in `flutter_test`'s fallback font — the font `CLAUDE.md` already records (task
   11.133) as roughly **twice Roboto's width**. The screenshot harness runs the real app on
   a simulator in the real font, where the same three buttons need far less room. **So
   "every real phone would hit this" does not follow from that measurement**, and the number
   cannot be compared against a device width the way 11.102's comment
   (`test/features/map/truth_point_row_overflow_width_test.dart`) compares it. **The fix
   itself — `Wrap` instead of `Row` — is right and should stay.** What is not established is
   *what made Michael's device the one that overflowed*: a larger system text size, a
   narrower device, or something else. **My best guess, and I am flagging it as a guess: an
   accessibility text-size setting.** The harness always renders at text scale 1.0 and has
   no way to notice.
2. **That gap is worth a task, and it is this lane's most useful output today: nothing in
   the app or the harness is ever rendered at a system text size other than the default.**
   Task 11.139 is already about fixed heights at a large system text size — **this belongs
   with it**, either as a second capture profile here or as a widget-test surface there.
   Ask me for a text-scale profile if you want the pictures; I did not add one, because a
   guide illustrated at 200% text is the wrong guide and it needs a decision about where
   those images live.
3. **The map's wait in the harness went 12 seconds to 90, and the reason is a finding about
   green runs.** With eight bearings the map fetches **72 terrain tiles at about one a
   second**, and the first run after the fixture change photographed the map and the
   truth-point panel **mid-download** — progress bar across the bottom, no computed overlay
   — while reporting *26 of 26 states photographed, no screen threw*. **Nothing failed,
   because nothing was wrong by any assertion anybody had written**; the only thing that
   caught it was looking at the images. Same shape as the 250× slowdown in task 11.103. If a
   future fixture adds stations, expect this number to be wrong again.
4. **Two of the three triggers in this task's own brief were corrected before it ran, and a
   third turned out not to be the reason either.** Recorded because the pattern is now
   four-for-four: tag-name length, device width, bearing count, and the fixture itself have
   each been named as the cause of something and each been wrong. **The fixture work was
   still worth doing** — it is what made the caution band and the eight-row list appear in
   the pictures at all — but it did not cause the overflow and it was never going to.

**For Michael**

1. **Nothing to run, and nothing broken.** Both device profiles were regenerated, all 26
   screens on each, no screen threw an error, and I looked at every image that changed
   before accepting it. Committed; push when you like — you are now several commits ahead
   of `origin/main`.
2. **One thing I would like your eyes on when you next have your phone out.** Please check
   what your iPhone's text size is set to (Settings → Display & Brightness → Text Size, or
   Accessibility → Display & Text Size → Larger Text). **If it is anything other than the
   default, that is very probably why that row overflowed on your device and not in any of
   our tests** — and it would mean a whole class of screens has never been looked at the way
   you actually see them. I could not test this and I am not certain; your answer settles
   it.
3. **The pictures now show more than they did, deliberately.** The Position screen's
   screenshot carries an amber *"2 cautions"* band and an eight-bearing list, because the
   invented session now runs 38 minutes — past the 15-minute window — which is what a real
   session that struggles looks like. **If you think the guide should illustrate the tidy
   case instead, say so and I will seed a second, calmer session for that page**; I chose the
   demanding one because this task exists to stop the fixture being kinder than reality.

**Findings for the code stream** — one, and it is small but concrete.

**On a 13-inch iPad, the bearings list on the Position screen shows the same four rows it
shows on a phone.** The new fixture puts eight bearings on the collar; both profiles'
screenshots show four of them, with the other four behind a scroll. The iPad has roughly
twice the vertical space and buys no extra rows, because the panel is a fixed fraction of
the screen height (the shape task 11.109 measured on the phone).
**What breaks for a person:** somebody checking on an iPad which bearings are selected
before saving a position has to scroll a list that would fit whole on the screen they are
holding — and on the phone, with a caution band showing, the same list is down to the four
rows 11.109 fought to keep. **I did not measure whether four is the floor or a coincidence
of this fixture**, and this is a screen-geometry judgement rather than a defect I can prove:
it is filed so the planning session can decide, not fixed.

**Resolved 2026-09-03 by the planning session.**
1. **Corrected in the plan, and it is the fourth cause proposed for this one event.** Pulling the
   pre-fix screenshot out of git and **looking at it** is what settled it — the row fit, with room
   to spare, so there was nothing for the harness to report. **The 460–470 threshold is real and
   was measured in `flutter_test`'s fallback font, roughly twice Roboto's width**, so it cannot be
   compared against a device width. Task 11.102's entry now carries the correction, **the comment
   in `truth_point_row_overflow_width_test.dart` is named as needing the same fix**, and the
   `Wrap` stays because it is right regardless.
   **The pattern is now a standing rule.** Tag-name length, device width, bearing count and the
   fixture have each been named as the cause and each been wrong — **every one inferred from a
   single observation nobody could reproduce.** `CLAUDE.md`: *when the event is one unreproduced
   observation, the cause goes in the report as a guess and never into the code as a comment* —
   a comment reads as something somebody established.
2. **Folded into task 11.139, which is raised above the line because of it.** It sat below on the
   grounds that nothing is broken at the default text size; **your finding makes it the leading
   candidate for the one layout defect a person actually reported.** The task is told that its
   floors are the first time any screen here is looked at the way somebody with larger text sees
   it, and **to say plainly if a floor lands within a notch of the default.** **Declining to add a
   200% capture profile was right** — a guide illustrated at 200% is the wrong guide — and 11.139
   now owns the decision about whether those pictures are wanted at all.
3. **Task `/w-11`, and it runs before `/w-10`.** *"26 of 26 states photographed, no screen threw"*
   while photographing a progress bar is this project's oldest class wearing a camera. **Raising
   the wait from 12 seconds to 90 got past it and will be wrong again the next time the fixture
   grows — you said so yourself.** So the task is a **per-screen readiness condition** rather than
   a shared sleep, watched going red against a screen that has not settled, with a count of the
   states that currently have nothing that would notice. **There is no point taking more pictures
   with an instrument that cannot tell a finished screen from an unfinished one.**
4. **Recorded, and it is the most useful sentence in the report.** *"The fixture work was still
   worth doing — but it did not cause the overflow and it was never going to."* **Doing the work
   and then refusing it the credit** is what separates a finding from a story.

**The code-stream finding is folded into task 11.139 as its second item.** The iPad showing the
same four bearing rows as a phone is the same question this task asks — **a panel whose geometry
is fixed against a reality that varies** — asked about screen size instead of text size. Filing it
as a judgement rather than a defect, and saying you had not established whether four is a floor or
a coincidence of the fixture, is why it is measurable now instead of arguable.

---
Entries the planning session has acted on, newest first, each with what it did.

### `/w-08` — 2026-08-31 — commit a22c09e — Done

**All eight sentences, all the pictures, both harness repairs, the enum rule and the
README class.** The guide now describes the app task 11.99 shipped, and one sentence in
the drift check's README says out loud what a green run has never meant.

**What I actually found, and it is worse than "eight sentences went stale."** Six of the
eight quoted nothing at all — they *described* controls. *The cloud icon at the top
right.* *The icons on the row.* *The first icon on a project's row.* *The two-people icon
on your project's row.* The app has none of those things and has not had them since
2026-08-31, and **every one of those sentences passed the drift check on every run for as
long as it was wrong**, because the check asks whether a quoted string still exists and
those sentences quote nothing. That class is now named in `website/README.md` under "what
the drift check does not catch", with the count, as item 3 — and it is the item the
closing paragraph now points at, because it is the one that has actually bitten.

**The enum rule is built and was watched red.** A quote of a database storage value —
`{{< app "owner" >}}` was the live example — is now refused outright rather than passing.
Watched three ways on real runs: with the rule switched off (the two refusal cases go
green, so the cases are real); with the naive "the stored value is the first argument"
assumption (a screen label declared inside an enum gets wrongly refused *and* a stored
value declared second gets wrongly allowed — so the check reads the constructor rather
than assuming); and restored, 22 of 22 selftest cases green. **There is no waiver for it**,
deliberately: a screen that prints a stored value is the defect
`test/documentation/role_vocabulary_test.dart` already fails on, so the app is what would
have to change.

**Both harness repairs are in, and the first one failed once in a way worth recording.**
The approval-sheet capture could not reach the Approve button because 11.99's role card
pushed it past the point a `ListView` builds anything. The fix was to drag the list first
— and my first attempt dragged **the map's** list, because this app's router is a
`StatefulShellRoute.indexedStack` and all five tabs stay mounted, so the framework's
default "first scrollable in the tree" is never the one on screen. **The run reported
that rather than producing a picture of the wrong screen**, which is `/w-03`'s assertion
doing its job for the second time in one task. It drags the scrollable a tap could
actually reach now, and prints how many were in the tree.

**Findings for the code stream**

1. **On the iPad, two committed screenshots have always been the same picture.**
   `owner-members-and-code` and `owner-pending-request` are byte-identical, and were
   byte-identical in the committed set before I started — the whole members screen fits on
   that geometry, so scrolling to the pending request moves nothing. **This is not a code
   defect and needs nothing from the app**; I am recording it because the manifest claims
   two states and delivers one, which is the shape `shots.dart` already refuses for
   duplicate *names*. The review now prints a `SAME` line naming any such group on every
   run, so it can no longer be invisible. It prints rather than failing — see below.

**For the planning session**

1. **Nothing is being asked of you for the eight sentences or the pictures — they are
   done.** All eight stale phone images and all thirteen stale iPad images were
   regenerated, looked at and accepted, and a confirming re-run was made afterwards:
   **the phone came back 26 of 26 byte-identical**, so what is committed is what the app
   draws. The two the brief named as broken captures — `owner-pending-request` and
   `owner-approval-sheet` — now differ from their *pre-11.99* committed versions by 0.036%
   and 0.032%, which is the strongest evidence available that the repair restored them
   rather than working around them.

   **One exception, named rather than smoothed over.** The iPad's `truth-point-edit` moved
   **11.64% between two consecutive runs of the same commit** — the dialog is identical
   and the map behind it is panned differently, most likely because the simulator raised a
   software keyboard for the focused precision field in one run and not the other. **I am
   reading that cause off the pictures, not measuring it.** Neither image is wrong; I kept
   the one I looked at, and it is written up in the harness README so the next person who
   sees that number does not go hunting the app. The phone's copy of the same screen is
   stable, and the phone is what every guide page shows.

2. **Task 11.100's four handovers to this lane are all discharged, and I am saying so
   because its entry asked you to pass them on.** Its items 1, 2 and 4: the guide's quote
   of the Log menu entry now reads {{< app "Edit position / precision / what was found…" >}};
   the paragraph warning readers that a bearing row carries four icons while a truth-point
   row has a menu is **deleted**, because 11.100 made them the same shape; the
   `truth-point-panel` picture is regenerated and accepted; and the mislabelled
   `coordinate at y=` line in `capture_test.dart` is corrected. **`/w-07`'s paragraph
   telling readers to tap below the truth-point square is also deleted** — that was
   written to be deleted when the marker was fixed, and it has been.

3. **The `SAME` line reports and does not fail, and that was a judgment call you may want
   to revisit.** Making it exit 2 would force whoever next regenerates to redesign the
   shot manifest for a profile no guide page uses. **If you would rather the iPad set stop
   claiming two states for one picture, the fix is in `shots.dart` and it is a decision
   about the App Store set, not about the guide** — either drop `owner-pending-request`
   for that profile or accept the duplicate with a written reason.

4. **`PERMISSIONS_MATRIX.md`'s corrected truth-point row is now reflected in the guide,
   and the table gained two rows rather than one.** Recording a truth point, and
   correcting or deleting *anybody's* truth point, are both contributor-and-above. The
   second is a genuine difference from a bearing — which only its author may edit — and it
   now has a paragraph of its own on the roles page. **I did not touch
   `PERMISSIONS_MATRIX.md`.**

**For Michael**

1. **Nothing to run, and nothing to decide.** Everything in this task is committed.

2. **One thing to be aware of about how today went, and it is a good outcome rather than a
   problem.** Two windows were working in this repository at the same time all afternoon.
   The code lane's screenshot run held the harness lock while mine tried to start, and
   **my run refused to begin rather than destroying its images** — which is the protection
   `/w-06` built, working, on a real collision, for the first time. Nothing was lost by
   either window, and neither commit contains the other's files.

3. **A small risk you are now carrying.** The guide's sentences about the projects screen
   describe a menu I have read in the code and seen in the regenerated screenshots, but
   **I have not used the app on a device.** If the menu behaves differently in your hand
   than it looks in a picture — an entry that is greyed out when I said it would be
   offered, say — that is the kind of thing only you will find, and it is a sentence to
   fix rather than anything structural.

---

**Resolved 2026-08-31 by the planning session.**

**The finding under the task is bigger than the task, and you named it: six of the eight
stale sentences quoted nothing at all.** *The cloud icon at the top right. The icons on the
row.* **Every one passed the drift check on every run for as long as it was wrong**, because
the check asks whether a quoted string still exists and those sentences quote nothing. **A
check that is green because it was never asked the question is the shape this project keeps
finding**, and naming it in the README with the count — and pointing the closing paragraph at
it, because it is the item that has actually bitten — is worth more than the eight repairs.

**The enum rule is built and watched red three ways, including the naive version.** Testing
the assumption *"the stored value is the first constructor argument"* and finding it wrong in
both directions — a screen label inside an enum wrongly refused, a stored value declared
second wrongly allowed — **is the difference between a rule and a rule that works.** And **no
waiver, deliberately**: a screen printing a stored value is what `role_vocabulary_test.dart`
already fails on, so the app is what would have to change. That reasoning is right.

**And the second harness repair failing first is the more instructive half.** Dragging the
map's list rather than the members list, because the router keeps all five tabs mounted so
"the first scrollable in the tree" is never the one on screen — **and the run reported that
rather than producing a picture of the wrong screen.** That is `/w-03`'s
capture-asserts-what-it-photographs discipline paying out twice inside one task.

1. **Recorded, and no code change.** The manifest claiming two states and delivering one is
   the shape `shots.dart` already refuses for duplicate names, and **printing `SAME` makes it
   visible rather than merely known.**
2. **Nothing asked, nothing owed** — and the confirming re-run coming back **26 of 26
   byte-identical** is what makes "what is committed is what the app draws" a measurement
   rather than a claim. **The 0.036% and 0.032% against the pre-11.99 versions is the right
   evidence** that the capture was repaired rather than worked around, and it is a better
   argument than "it passes now".

   **The iPad's 11.64% between two runs of the same commit is accepted and stays in the
   README**, with your caveat intact: **you are reading the cause off the pictures, not
   measuring it.** Neither image is wrong, the phone is stable, and the phone is what every
   guide page shows. **If the iPad ever becomes guide-relevant, that instability is the first
   thing to re-open** — noted here so it is not rediscovered.
3. **Decided: leave it printing, do not make it fail.** The iPad set exists for the App Store
   and no guide page uses it, so exit 2 would force a manifest redesign for a profile nobody
   reads. **The duplicate should be resolved when somebody finalises the App Store set** —
   two identical images is a wasted submission slot rather than a wrong one — and that is a
   decision about that set, exactly as you said. No task today.
4. **Right on both counts, including not touching `PERMISSIONS_MATRIX.md`.** The table gaining
   two rows rather than one is the more interesting outcome: **anybody may correct or delete
   anybody's truth point, while only a bearing's author may edit theirs.** That asymmetry is
   real, it follows from Michael's lion-case decision, and **it is now documented publicly**,
   which is the right place for it to be examined.

**One question has gone back to Michael off the back of that row** — whether *deleting*
somebody else's truth point should be author-only even though *correcting* it is not. His
decision was about correction; deletion was never separately put to him.

**And your note about the lock is the first real collision it has prevented.** The code lane
held it, your run **refused to begin rather than destroying its images**, and neither commit
contains the other's files. `/w-06` built that after two windows had already wrecked one run
between them; this is it working on a live collision.


---

### Task w-07 — 2026-08-31 — commit 7380637 — Done

**The guide now explains truth points.** A truth point is the record of a place
somebody physically walked to and found the animal or the collar — the yardstick
every position estimate gets measured against. Until today the guide mentioned one
in a single passing sentence on the export page and never said what one was. There
is now a page: what it is, how to record it, where it turns up afterwards, how to
correct it, who is allowed to, how to delete it, and what its spreadsheet contains.

**The sentence the page exists to correct is the position one.** Until 2026-08-31
a truth point's position could not be changed; task 11.93 made it changeable, and
the correction dialog is now photographed with the control that does it. Anything
anybody reads anywhere that says a truth point's position is fixed is out of date.

**Three new captures, on both profiles, and each asserts what it is a picture of.**
The record screen's Truth tab must be showing the precision box and the save button
that names a truth point; the map panel must actually read the header task 11.92
renamed; the dialog must carry the move-on-map control that is the whole of what
11.93 added. A shutter that fires on the wrong thing still produces a file, and
that file goes on a page captioned as something it is not — so all three refuse to
be quiet about it. **The Truth tab is also put back to Directional afterwards and
checked**, because the record screen's draft autosaves and the same screen is
photographed again later under a server.

**Verified:** the drift check passes on 112 quoted strings across 10 pages, its own
selftest passes 18 cases, Hugo builds clean and every link resolves, and a full
regeneration of both profiles reports the three new images unchanged against
current `main`.

---

##

**Resolved 2026-08-31 by the planning session.**

**Finding 1 is the best thing this lane has produced and it is task 11.100, beta-blocking.**
A truth point is painted about 28 pixels above the coordinate it stands for — **roughly a
hundred metres of apparent ground offset at working zoom, on a record whose entire purpose is
being accurate to about ±12 m** — and a tap on it selects nothing, because the map measures
from the real position. **You found it by trying to write "tap the truth point on the map"
and discovering that is not what you do.** No test, no gate round and no hardware session had
noticed, and the marker eight lines above it in the same file already does it correctly, with
a comment saying plain `topCenter` would cause exactly this.

**And you left an instrument rather than an assertion.** The capture taps the drawn square and
prints whether the panel opened; it has said *did NOT open* four times across both profiles
with the same gap. **11.100's confirmation is the harness reporting the tap opened, not a
green test.** Your note that the shared-observation marker has the same alignment and that you
**did not test it** is carried as unverified — not as a second defect, and not as a
non-defect.

2. **Task 11.100, item 2.** *"Edit precision / what was found…"* on a dialog that also moves
   the point is **copy describing a mechanism the code does not have, inverted** — a label
   claiming less than the code does. Good catch on the inversion; the class is usually seen
   the other way round.
3. **Answered, and your answer is the right one to act on.** One clause, not a paragraph, and
   the clause warns a reader away from a control that is not there. **Your observation that
   11.99 has just made the opposite move on the projects screen settles the direction**: the
   bearing rows are out of step, not the truth-point row. It is 11.100's item 4 and marked
   **droppable** — if the marker fix grows, it goes.
4. **Task 11.100, item 3.**
5. **Corrected the same day, by the planning session, because it is a `CLAUDE_DOCS` file.**
   You were right not to edit it and right that it is load-bearing for this lane. **A stale
   row in `PERMISSIONS_MATRIX.md` became a stale sentence on a public page** — which is how it
   was found, by the guide rather than by anything in the code stream. Task 11.84 re-derives
   the whole matrix; the row is fixed now rather than left standing until it runs, and 11.84's
   entry now carries this as evidence for why a derived matrix beats a maintained one.

**Your item 2 is `/w-08`** — eight sentences, seven pictures, and the two harness repairs.
**The assertions catching their own breakage is the part worth naming:** after 11.99 the role
card pushes the pending section down so far that the phone never builds the Approve button,
and the run said *there is no Approve button on the members screen* rather than producing a
picture of the wrong thing. **That is `/w-03`'s capture-asserts-what-it-photographs discipline
paying out on its second task.**

**Your item 4 is acted on and the rule is widened.** 11.99's commit swept up 191 lines of your
in-progress harness work. `CLAUDE.md`'s staging rule was written for the planning session
because that is where it had happened twice; **you are right that this is the third instance
and that it was never a rule about planning sessions.** It now binds every session, by name,
with the addition that **a file you did not edit and find staged should be unstaged — it
belongs to the other window and it is mid-thought.**

**And item 5 deserves saying out loud: the brief was wrong about the app and you did not ship
the wrong sentence.** It said the correction dialog offers deleting the point; it does not,
and you documented delete where it actually lives. **The brief is not the authority on what
the app does** — that rule is in `CLAUDE.md` for code tasks, and it applies here identically.


---

### Task w-06 — 2026-08-31 — commit fc900c1 — Done

**What changed, and none of it is in the app.** Three holes in this lane's own
tooling.

**One.** Two people can no longer wreck each other's screenshots by running the
picture-generator at the same time: the second run is refused before it deletes
anything. And a run that loses its own output part-way now reports *I could not
read what I produced* instead of *a screen changed* — which is the half that
mattered, because a crash gets looked at and a changed screen gets accepted.

**Two.** The pictures are now taken on a phone that knows where it is, which is
what somebody standing in a field has. **That run is also the confirmation task
11.95 asked for and could not do itself, and it passed** — see below, because
that is the most important sentence in this entry.

**Three.** The check that verifies quoted app wording can now see the shared
package where the role names and the record-type buttons live, so the guide's
roles table and its list of record types are checked rather than being unmarked
prose.

---

#### 1. The concurrency hole, and it was really two holes

`review.dart` caught one kind of error around each image read — a corrupt PNG —
and nothing else. So a file deleted between the moment it listed the directory
and the moment it read that file escaped as an unhandled error, the process
exited **255**, and `regenerate.sh` treated anything that was not 2 as *a screen
changed and nobody has said yes.* Three fixes, and they are separable:

- **Any filesystem error in the review is now exit 2 with a sentence naming the
  file**, not a stack trace. Caught once around the whole review rather than
  around each read, so a reader or writer added later cannot forget to wrap
  itself.
- **`regenerate.sh` reads only 0, 1 and 2 as a verdict.** Anything else is the
  review crashing rather than an opinion about the images, and it is exit 2.
  This is the part that would have caught the original incident even without
  the first fix.
- **`regenerate.sh` takes a lock on `build/screenshots` before it deletes
  anything.** `mkdir`, because `mkdir` is atomic and macOS has no portable
  `flock`. A second run refuses to start, exits 2, and prints which process
  holds the lock and when that run began. A lock whose owning process is no
  longer alive is reclaimed, loudly — a crashed run that left the harness
  permanently unusable would be a worse failure than the one being prevented.

**Both were watched, on real runs.**

- *Second run refused:* started `regenerate.sh iphone-6.9` while a live one was
  mid-capture. It printed the process number and start time of the running one,
  exited 2, and **deleted nothing** — the first run went on to finish normally.
- *Staging directory removed underneath a run:* started a run, waited for the
  capture to finish, and deleted `build/screenshots/iphone-6.9` two seconds into
  the review. The review printed *join-code-entered.png went away underneath
  this review: it was there when the run listed the directory and it is not
  there now* and exited 2, and the script exited **2**. Before today that was
  exit 255 and a script exit of 1, reported as drift.

**`/w-03` was right that the enforcement belonged in the script rather than in
`WEBSITE_PLAN.md`.** The run that destroyed 23 images was a code task checking
that its own map fix worked, which is a reasonable thing to want to do; a
document telling people not to run the harness cannot compete with that.

#### 2. The GPS fix is on — and this is task 11.95's outstanding confirmation

**It passed, and it passed four times.** Every run since the fix went on —
two on the phone, one on the iPad, one more during the deletion watch — ended
with the harness printing *23 of 23 states photographed; no screen threw while
being photographed.* Before 11.95, giving the app a position fix made the map
screen write to a provider from inside its own build, and the failure that
followed ended the run with **no images at all**. Neither assertion came back.
**11.95 had the right answer**, and its own evidence had to be a widget test
precisely because this harness withheld the thing that triggered the defect.

**Seventeen committed pictures changed, on the two devices between them, and
every one was looked at before it was accepted.** What moved:

- **`map`** (42% of the phone's pixels, 37% of the iPad's). The map now recentres
  on the device and paints the computed viewshed, which is the layer that says
  where a signal could be heard from. **This is the first time anybody has seen
  that overlay finish** — 11.95 records that the old failure jumped past the
  code that ends the computation, so the bottom bar used to sit at *computing*
  for the rest of the session. The picture is honest and it is also mostly
  purple: at the zoom the app picks, the overlay covers the terrain and several
  of the project's own bearings are off the edge. Nothing in the guide uses this
  image yet.
- **`log`** (5.0% on the phone, 0.10% on the iPad). Every record now carries how
  far it is from where you are — *3.4 km*, *2.7 km*, and *152 m* on the truth
  point — and the sort control gains a distance option. Same content change,
  above the reporting threshold on one device and below it on the other.
- **`compass`** (0.46% / 0.15%). A true-north heading and a declination, both of
  which need a position before they can exist.
- **`record` and `joined-sync-bar`** (0.11% / 0.03%). The position line under the
  notes goes from *acquiring* to a coordinate and an accuracy.
- **`position`** (0.87% / 0.16%). A you-are-here marker, a coordinate readout,
  and a distance sort.
- **`checklist`** (0.47% / 0.17%). The GPS line reports a fix, and the elevation
  line now says some is cached rather than none downloaded.
- **`project-members` and `join-downloading`** moved only because they hold
  progress spinners caught at different points of their rotation.

**Two sentences in `/w-03`'s guide stopped being true, and I corrected them here
rather than leaving them for the next content task.** The brief told me to note
it and let the next task fix it, and I did not do that, for one reason: **this
commit is what makes them false.** The record page said the position line in the
picture was still waiting for a fix and would fill in outdoors; the compass page
said true north and declination read as a dash, *which is what the picture above
shows.* Shipping a picture that contradicts the sentence beside it is the same
defect as copy describing a mechanism the code does not have, and I would have
been the one who introduced it. Both now describe what the pictures show,
including that the invented heading makes the true-north figure invented too.

#### 3. The drift check can see `packages/` now

The check reads **`lib/` plus every `packages/*/lib/`**, worked out at run time
rather than written down, so a package added next month is covered by whoever
adds it. A `packages/` directory with no package `lib/` inside it is exit 2
rather than a silent narrowing — the check would otherwise be searching one
place while its own documentation claimed two.

Marked in the guide, and now checked: the three column headings of the roles
table, the three lower-case spellings the members screen actually uses, and four
of the five record-type buttons. The workflow now also runs on a push that
touches `packages/`, so a rename there goes red on the push that made it rather
than one push later. The check's README no longer lists `packages/` as a hole.

**One honest limit, and I have written it into that README as a new entry rather
than only saying it here.** Of the eight labels I marked, only two — the record
screen's first and fourth buttons — can *only* be found in `packages/`. The
other six pass because the check matches a quoted string against any longer app
string containing it, and words like *owner* and *viewer* appear inside unrelated
sentences in `lib/`. **The marking is real and the check is real; it is just not
evidence that those three dropdown entries still spell the roles that way.**
There is no longer string to quote — the dropdown entry is the bare word.

`selftest.sh` grows from 14 cases to 18. The four new ones build a small app tree
in a temporary directory and run the checker inside it, so they test the
discovery rather than the argument parser: the default roots find a string that
exists only in a package; the same page goes red once the package is removed;
and a `packages/` with no package `lib/` is exit 2. **Watched failing with the
discovery stubbed out** — two of the four turn red.

#### Two things I added that the brief did not ask for

**The review now prints `NEARLY` for a screen that moved and stayed under the
threshold, with the number.** It exists because of something this task walked
into. The record screen's position line — arguably the most guide-relevant text
in the app — changed from *acquiring* to a coordinate, and the comparison
measured it at **0.1069%** against a **0.12%** threshold and reported the screen
as unchanged. I only caught it because I opened the picture. **The threshold
cannot be lowered to catch it:** on the same pair of runs the harness's own
rendering noise measured **0.068%** on the members screen, two progress spinners
caught mid-rotation. Noise at 0.07 and a real one-line change at 0.11 cannot be
separated by a threshold, so the instrument prints the number and a person
decides.

**And `--accept` now writes those screens too.** It previously wrote only the
screens past the threshold, which would have left the committed record screen
showing *acquiring* while its neighbours showed a fix — a repository holding a
patchwork of two runs, with the stranded pictures being exactly the sub-threshold
ones that were real content rather than noise.

##

**Resolved 2026-08-31 by the planning session.**

**Item 1 first, because it is the most important sentence in the entry and it was reported
as such: task 11.95's confirmation passed, four runs, two profiles, no screen throwing.**
That task's evidence had to be a widget test precisely because this harness withheld the
thing that triggered the defect, **and it said out loud that if the real run still threw, it
had the wrong answer and wanted to know.** It did not, and it is recorded on the task.

**But the more interesting consequence is one nobody asked for: 11.95 turned on a feature
that had never worked.** Throwing past the `try` jumped the `finally`, so **the automatic
viewshed never completed** — the bar sat at *"Computing viewshed…"* for the session. **Your
pictures are the first time anybody has seen that overlay finish**, and what it does is
paint a large purple polygon over the terrain at a 200-metre zoom with several of the
project's own bearings off the edge. **You were right to file that as an observation rather
than a defect.** It is now on Michael's hardware list as the first thing to look at, and
task 11.87's entry carries a warning at the top: **every judgement anybody has made about
this overlay's launch behaviour was made about a feature that was not running.**

2. **Folded into task 11.99**, which is already opening the members screen — you suggested
   exactly that. Framed there as the general defect rather than the instance: **a raw enum
   value reaching a screen is a label nobody chose**, and the approval sheet's wording is
   preferred because a person meets it at the moment they are let in.
3. **Done** — `WEBSITE_PLAN.md` now records the enforcement as built and watched, with the
   part that matters: **`regenerate.sh` reading only 0, 1 and 2 as a verdict would have
   caught the original incident on its own**, without the filesystem-error fix. Two
   independent closures of one hole is the right amount for a failure that reported as a
   milder failure.
4. **Agreed, nothing re-scoped.**

**The two unasked-for additions are both ratified, and `NEARLY` is the better of them.**
A real one-line change measured **0.1069%** against a **0.12%** threshold and reported as
unchanged; the harness's own spinner noise on the same pair measured **0.068%**. **Noise at
0.07 and real content at 0.11 cannot be separated by a threshold**, so printing the number
and letting a person decide is the only honest instrument — and you found it by opening the
picture rather than by trusting the tool, which is the behaviour that produced the finding.
**`--accept` writing sub-threshold screens too is the necessary other half**: without it the
repository would hold a patchwork of two runs, stranded on exactly the sub-threshold images
that were real content rather than noise.

**And correcting `/w-03`'s two sentences yourself was right, against your brief.** The brief
said note it and leave it — **but this commit is what made them false**, and shipping a
picture that contradicts the sentence beside it is the same defect as copy describing a
mechanism the code does not have. **The rule is: whoever creates the obligation discharges
it**, which this lane arrived at twice already. You applied it to yourself.

**The limit you wrote into the README rather than only into this entry is the most
self-critical thing in the report and it should stay.** Six of the eight marked labels pass
because the check matches a quoted string against any longer app string containing it, and
words like *owner* and *viewer* appear inside unrelated sentences in `lib/`. **The marking
is real and the check is real, and it is not evidence that those three dropdown entries
still spell the roles that way.** Task 11.99 is about to change exactly those strings —
**so that limit is about to be tested**, and if the check stays green through a rename it
will be the proof your README entry predicts.

**Your note about the elevation cache is carried forward** — the harness's images depend on
data it does not control, stable on this machine, potentially different on a freshly wiped
simulator. Documented, not a defect.

**And on the two lanes overlapping twice in one working tree: both times it was fine because
somebody checked, and that is now true of the one thing that actually broke** — the harness
has a lock. **The rest still rests on disclosure, and disclosure has held twice.** Worth
knowing rather than worth a mechanism today.


---

### Task w-03 addendum — 2026-08-31 — commit 64d1563 (no code change) — Done

**Michael answered item 3 of `/w-03`'s list for him: yes, he wants a truth-point
section in the next content task.** Recorded here rather than left in a chat
window, and appended as its own entry because the `/w-03` entry below is already
written and this file is append-only.

**The reason it is a task and not a paragraph.** Truth points are settled now —
11.92 and 11.93 have both landed — but **the harness photographs only one of the
four surfaces a section would need**, so this is harness work plus writing rather
than writing alone. Whoever scopes it should know that before sizing it.

*Already on film, and it is a good picture:* the log listing carries a truth-point
row showing everything 11.93 added — what was found, the precision, who found it
and whether the position was a GPS fix. It is in `log.png` on both profiles today.

*Not photographed, and each needs a state adding to `shots.dart`:*

1. **The record screen with the Truth tab selected** — the form somebody actually
   fills in. Today's `record` image is the Directional tab; the Truth tab has a
   different set of fields, including the precision entry that a truth point
   cannot be saved without.
2. **The map info panel for a truth point** — the header 11.92 renamed
   (`map_screen.dart:2684`) and its Navigate action. `WEBSITE_PLAN.md` already
   flags that this wording is not covered by a shortcode yet, so the guide will be
   the first thing to quote it.
3. **The correction dialog** (`truth_point_edit_dialog.dart`) — 11.93's whole
   point, and the sentence the guide must not inherit from anywhere: **a truth
   point's position can be changed now.** It offers moving the point on the map,
   changing the precision, changing what was found, and deleting it.

**One thing the next writer will meet and should not have to rediscover.** On the
log screen a truth-point row's controls are a single overflow button, where a
bearing row has four inline icons. It is not wrong and it may well be deliberate,
but it means the sentence *tap the pencil to correct it* is true of a bearing and
false of a truth point, on the same list, two rows apart. **Filed as an
observation, not a finding** — I did not write that section, so I have not paid
the cost of explaining it and will not claim it is a defect.

**For the planning session**
1. **Schedule the truth-point section, and scope it as harness plus writing.**
   Three new capture states as above, then the page. Michael has said yes to the
   content; the size is the part that needs deciding.
2. **Nothing else here is new.** Every other item is in the `/w-03` entry below.

**For Michael**
1. **Nothing — this is complete.** This entry changes no code — the commit named
   above is `/w-03`'s, which is what there is to read; this is a decision record
   appended to the file both sessions share.
2. **Your answer is now in the file both sessions read**, so you will not have to
   say it again in the other window.

---

### Task w-03 — 2026-08-31 — commit 64d1563 — Done

**What it does.** The user guide now has five pages that describe what somebody
actually does with TriTrack: joining a project, projects and members and roles,
recording a bearing, sync, and getting your data out. Every one is illustrated
with pictures generated from the app itself, every app label on them is checked
against `lib/` on every build, and nothing on the not-yet list is described.

**One picture was added to the harness and it is the one the join story was
missing.** `/w-05` named the owner's approval sheet as the biggest remaining hole:
the guide could show *that* an owner approves and not *what they are asked* when
they do. It is now photographed on both devices — the role, and the sentence
saying that removing somebody later cannot take back what their device already
holds, with the button greyed out until it is ticked. That is a tap and a capture
in `capture_test.dart` plus one name in `shots.dart`, which is the whole of the
harness permission this task was granted, and it is all it used.

**The capture asserts what it is a picture of.** If the sheet does not open, or
opens without the disclosure on it, the run records an error against the screen
and the closing summary prints it — because a shutter that fires on the wrong
thing still produces a file, and that file goes on a page captioned as something
it is not.

**The five pages, and what each one had to be honest about.**

*Joining a project* carries the timings as numbers, because the third one reads
as a fault if it is not stated as expected: app open, up to about a minute (it
asks every 60 seconds while a request is outstanding); backgrounded, the moment
you bring it to the front; **fully closed, nothing at all until you open it**,
and the page says out loud that there are no push notifications and no mechanism
anywhere in the app that changes that. It also covers being turned down, a code
rotated out from under a waiting request, and an approval whose download did not
finish.

*Projects, members and roles* is a fourteen-row table of who may do what, filled
from `CLAUDE_DOCS/PERMISSIONS_MATRIX.md` rather than from memory, plus what
being removed looks like from both sides. Two rows are called out because they
surprise people: a contributor cannot take even their own bad bearing out of the
analysis, and **a viewer can export the entire project** — the role governs what
somebody may change, not what they may read or copy.

*Recording a bearing* explains point-versus-range in the terms that matter in
the field (range records your uncertainty instead of hiding it) and says twice,
in the two places it matters, that **the compass heading in the pictures is
invented** — the simulator has no magnetometer, the harness feeds it a constant
47 degrees, and a guide that presented that as a reading would be teaching
somebody to trust a fabricated instrument.

*Sync* says what the bar means in each of its states, what each frequency
setting actually promises (none of them is a timer — nothing syncs while the app
is closed, at any setting), and ends on the two things sync cannot do.

*Getting your data out* covers the spreadsheet and the backup file, including the
paired tag columns, and ends with the habit worth having: records that have never
synced exist in exactly one place.

**One set of pictures per page, and the trap `/w-05` warned about was real.** The
join, members and sync pages use only the joined device; the record, compass and
export pages use only the unconfigured one. The record page says in one sentence
that its two pictures have no sync bar because that device has no server —
because a reader who is not told will read a configuration difference as an
inconsistency in the app. The iPad pair that are byte-identical never came up:
the guide is the phone throughout, where they differ.

**A second check went in with the pictures, and it has been watched failing.**
`{{< shot "name" "caption" >}}` refuses to build the site if that screen has no
image, and names the file it looked for. Hugo has no other check on an image
source, so without it a screen renamed in the harness leaves a broken image
nobody notices for months — the `app` shortcode's defect one level over. A
caption is required for the same reason: an uncaptioned screenshot makes the
reader guess, and a reader who guesses wrong stops trusting the page.

**Verified:** the drift check passes on 69 quoted strings across 9 pages; its own
selftest still passes 14 cases including the 5 that must go red; Hugo builds
clean and every cross-link and anchor resolves; `flutter analyze` is clean on the
harness; and the screenshot review is green on both profiles.

**Task 11.95 landed in the middle of this task and it cost a lesson.** Two
commits went in while my runs were going, and the first of them changed the map
credit — so **the iPhone profile built the old code and the iPad profile built
the new one, inside a single `regenerate.sh` invocation.** The images from that
run were not one set and I did not accept them. Both profiles were re-run against
a settled HEAD afterwards, both diffs were opened and looked at, and the change
is exactly and only 11.95's new credit. **The picture is the proof the fix works:
the old phone image has yellow-and-black stripes reading "OVERFLOWED BY 61
PIXELS" across a credit running off the edge; the new one has it wrapped onto two
lines inside its own box.** So the `/w-02` prohibition on the phone `map` and
`position` images is lifted, and both READMEs now say so instead of forbidding
something that no longer needs forbidding.

**Findings for the code stream**

*Six, and the first two are the class this lane exists to find — a person is not
told something the app knows.*

1. **A removed member is told to wait for an invitation, and invitations do not
   exist any more.** The one screen that explains being removed
   (`lib/features/more/screens/sync_status_screen.dart`, the advice under
   "You're no longer a member of this project") ends with *"To take part again
   you need a new invitation from an owner."* Task 11.81 replaced invitations
   with a join code and an owner's approval — there is nothing anybody can send
   them. **What breaks for a person:** somebody who has just been removed reads
   the only screen that explains their situation and is told to wait for a thing
   that cannot arrive; the true answer is to ask an owner for the project's join
   code and ask again, or ask to be put back. The leave dialog next door
   (`projects_screen.dart`) carries a comment saying this exact wording became
   false with 11.81 — **it was corrected there and not here**, which is why this
   is a sibling rather than a new class. I am confident about the string and the
   fact; I have not checked whether any other surface still says it.

2. **A contributor or a viewer has no way to find out what role they hold, or
   who else is on the project.** The way to the members screen is rendered only
   for owners (`projects_screen.dart`, the members icon inside `if (isOwner)`).
   The only place the app ever names somebody's own role to them is inside a
   failure message *after* they have tried something they are not allowed to do.
   **What breaks for a person:** a field tech who cannot save a position estimate
   has no way to find out whether that is their role or a bug, and no way to see
   who to ask. Writing the roles page meant publishing a table the app cannot
   show to most of the people it applies to.

3. **The only way into joining a project is an unlabelled icon.** On the projects
   screen, the single control that opens "Join a project" is a bare cloud icon at
   the top right whose meaning lives in a tooltip — and a touchscreen never shows
   a tooltip. The guide has to say *the cloud icon at the top right* and hope. The
   same shape is on every project row: four unlabelled icons, of which one leaves
   the project and one deletes it, side by side. **This is the sentence the guide
   could not write short**, which is what this lane was asked to notice.

4. **The record screen still cannot be photographed doing its job**, and now it
   has cost a paragraph. Every screenshot is taken with no GPS fix (`/w-02`
   finding 1), so the picture of the core action of the app shows the position
   line still acquiring and the save button greyed out, and the guide has to tell
   the reader that the picture is not what they will see outdoors. **Task 11.95
   landed while this task was running and may have removed the cause** — the map
   no longer writes a provider during build — so `enableGpsFix()` in
   `harness.dart` may now be safe to call. I have not tried it; that belongs to
   whichever task next touches the harness.

5. **Words the app puts on screen that the drift check cannot see.** The role
   names a member reads (owner, contributor, viewer) and the five record-type
   buttons on the record screen live in
   `packages/tritrack_sync/lib/src/enums.dart`, not in `lib/`.
   `website/tools/check_app_quotes.dart` searches `lib/` only, so the guide had to
   write those words as unmarked prose — **exactly the rot that check exists to
   prevent, in the guide's most-read table.** Either the check should also scan
   `packages/`, or those labels should live in `lib/`. This is a small change to
   one glob and it closes a hole the check's own README lists as known.

6. **Two runs of the screenshot harness at once destroy each other's output, and
   the failure does not report as a failure.** This one is the harness's, not the
   app's, and I hit it rather than reasoned about it: another window ran
   `regenerate.sh iphone-6.9` while mine was between the driver writing its 23
   files and the review reading them. That run's `rm -rf build/screenshots/
   iphone-6.9` removed all 23, and `review.dart` died with a
   `PathNotFoundException` stack trace — it catches `PngFormatException` around
   the read and nothing else, so a file that disappears between the directory
   listing and the read escapes as an unhandled exception. **The process then
   exits 255, and `regenerate.sh` treats anything that is not 2 as "a screen
   changed and nobody has said yes."** So a run that could not read its own
   output reports as ordinary drift. Two fixes, and they are separable: turn a
   filesystem error on the read into exit 2 with a sentence saying the file went
   away, and refuse to start a run while another one holds the staging directory.

**For the planning session**

1. **Findings 1 and 2 above want task numbers**, and finding 1 is the more urgent
   of the two: it is live copy telling a removed person to wait for something that
   cannot come, and it is a sibling of the defect 11.54 fixed next door in the
   same week.
2. **Finding 5 is a one-line change to the drift check** (`website/tools/`) and it
   is arguably this lane's own to make — but `packages/` is not on this lane's
   list of what it may read, and the check's `--lib-root` default is a code
   decision. **Say which lane owns it** and I will do it or leave it alone.
3. **Task 11.95 landed while this task was running, in two commits, and it changes
   four committed screenshots.** The map credit is drawn differently now and the
   61-pixel overflow no longer fires on a phone — I watched it not fire. The iPad
   `map` and `position` images have been re-accepted here after looking at the
   diffs; the phone pair likewise. **This means the `/w-02` constraint forbidding
   the phone `map` and `position` images can be lifted**, and somebody should say
   so in the plan rather than leaving a rule in place that no longer describes
   anything. I did not put them on a page — that was not this task's brief, and a
   page for the map screen does not exist yet.
4. **The lane rule needs one more sentence, and it is the mirror of the one
   `/w-05` produced.** The two lanes share one working tree *and one `build/`
   directory*. A code task verifying a map fix by running the screenshot harness
   is a reasonable thing to want to do and it silently broke my run. Whatever the
   rule ends up saying, **the enforcement belongs in `regenerate.sh` rather than
   in a document** — see finding 6.
5. **Two exclusions in my brief now look stale and I left them alone rather than
   deciding for you.** Truth points are on the do-not-write list because 11.92 was
   changing them; 11.92 and 11.93 have both landed, and the truth-point column
   pair is already in the CSV export. **The export page mentions in one sentence
   that a truth-point file is written and does not explain what a truth point
   is** — that was my judgment call, because a person who gets three files and
   reads about one is worse off than a person who gets one extra sentence. Say if
   you would rather it came out, or rather the section were written.

**For Michael**

1. **Nothing to do, and nothing to push by hand — committed to `main` as
   `64d1563`.** Push when you next push.
2. **Look at the guide if you like**, and the two pages worth reading first are
   joining a project and sync, because those are the two where I had to say what
   the app *cannot* do. `hugo server --source website` and then the Guide link,
   or read the Markdown in `website/content/docs/`.
3. **A decision only you can make, and it is small.** Item 5 above: truth points
   are settled now, and the guide deliberately does not describe them because my
   brief said not to. Do you want a truth-point section in the next content task?
4. **A risk you are now carrying, and it is new.** Two Claude windows ran the
   screenshot harness at the same time this afternoon and one silently deleted the
   other's output. Nothing was lost and nothing wrong was committed — I re-ran and
   checked every image — but **until finding 6 is fixed, running
   `regenerate.sh` in two windows at once can produce a run that reports as
   ordinary drift when it actually failed.** If you are ever running it yourself,
   run it alone.
5. **One thing that is not a risk, so you do not have to wonder.** The new
   approval-sheet screenshot shows an email address, a person's name and a join
   code. All three are invented, at a domain the internet standards body reserves
   so it can never belong to anybody. Nothing in these images points at a real
   person or a real project.

**Resolved 2026-08-31 by the planning session. Both entries together.**

**This lane was created to find exactly what findings 1 and 2 are, and it found them on its
first writing task.** *A removed member is told to wait for an invitation that no longer
exists* and *a contributor cannot find out what role they hold* are both **a person not told
something the app knows** — and neither was found by any test, any gate round, or any
hardware session. **Writing the sentence is what found them.** That is the whole argument for
this lane, and it is now evidence rather than a claim.

1. **Task 11.98, beta-blocking, and written as a sweep rather than an edit.** The detail you
   found is what makes it one: the leave dialog next door **carries a comment saying this
   exact wording became false with 11.81, and it was corrected there and not here.**
   Somebody knew, wrote it down, fixed one of two. **You were careful to say you had not
   swept**, so 11.98 must report the count and leave behind a check that would catch the
   next one — this has now happened twice.
2. **Task 11.99, beta-blocking, merged with finding 3** — same screens, same failure. It is
   told to decide the disclosure question **explicitly**: showing a non-owner the member list
   means showing colleagues' addresses, and *"roles yes, member list no"* is a perfectly good
   answer that must be a written one. **Your line about publishing a table the app cannot
   show to most of the people it applies to is quoted in the task**, because it is the
   argument.
3. **Also in 11.99, and promoted from your observation to a defect.** You filed the
   unlabelled icons as a finding and the leave-beside-delete adjacency inside it. **Two
   unlabelled neighbours where one is recoverable and the other is not is a data-loss shape,
   not a polish item**, and 11.99 is forbidden from answering it with more tooltips — your
   point that a touchscreen never shows one is the finding.
4. **Resolved by `/w-06`**, which turns `enableGpsFix()` on. Task 11.95 removed both blockers
   and **its own outstanding confirmation is that run**, so `/w-06` reports it either way.
   **If the record-screen picture stops needing its caveat, `/w-06` says so and the next
   content task fixes the sentence.**
5. **This lane owns it — ruling made.** The check lives in `website/tools/`, and **reading
   `packages/` is a read, which the lane rule has never forbidden.** `/w-06` widens the glob
   and marks the role and record-type words. You were right to ask rather than assume, and
   right that unmarked prose in the guide's most-read table is the rot the check exists to
   prevent.
6. **`/w-06`'s first item**, with your diagnosis carried verbatim: **a run that could not read
   its own output reports as ordinary drift.** That is worse than a crash, because a crash
   gets investigated and drift gets accepted. Both fixes, both watched.

**Your item 3 — the `/w-02` prohibition — is lifted in `WEBSITE_PLAN.md`, and you were right
that leaving it would have been the defect.** A rule outliving the thing it forbade is what
this project keeps finding. **You also did the right thing in not putting those images on a
page**: that was not your brief, and a map page does not exist yet.

**Your item 5, and Michael answered it: yes, he wants the truth-point section.** It is
`/w-07`, scoped as **harness plus writing** exactly as your addendum said — three new
captures, then the page. **Your judgement to keep the export page's one sentence stands:** a
person who gets three files and reads about one is worse off than a person who gets one extra
sentence. `/w-07` expands it rather than removing it.

**And the overflow-button observation is handed to `/w-07` as a decision rather than a
finding**, in your own terms: you would not call it a defect because you had not paid the
cost of explaining it. **`/w-07` will pay that cost**, and it is told that if the sentence
comes out awkward, that is the signal — file it, do not write around it.

**One thing worth naming that nobody asked about.** Your approval-sheet capture **asserts what
it is a picture of**, and fails the screen if the sheet opens without the disclosure on it.
**A shutter that fires on the wrong thing still produces a file, and that file goes on a page
captioned as something it is not.** That is now the standard for this lane and `/w-07` is
told to follow it.


---

### Task w-05 — 2026-08-31 — commit 90896ed — Done

**What it does.** The screenshot harness now photographs a device that has
actually joined a project — a code typed in, the request sent, the owner
approving from their own device, the download caught mid-flight, and the
project arriving and syncing — plus the owner's side of the same thing: the join
code, three members with all three roles, and one stranger waiting for approval.
**`/w-03` can now illustrate its flagship section with pictures of the thing it
is describing**, which it could not before: every image `/w-02` committed was of
a device with no server, so the sync screen showed the unconfigured state and
the join screen showed an error.

Nine new images per device profile, 18 in all, on top of the 13 that were
already there — 22 per profile, 44 in the repository. `integration_test/screenshots/regenerate.sh` is still the one command and
still the only way any of them is made.

**No server was started and nothing reached the network.** The fake sync
transport the app's own tests run against is driven through the whole join
instead. Four seams are replaced — the session, the membership transport, the
"projects you could join" list, and the server address — and **all four are
inert until the joined half of the run begins**, which is why the thirteen
unconfigured images did not move. The sync engine is deliberately *not* among
them: it builds its own connection, so a "tap Sync now" picture would be a real
request to an invented hostname. That is written down in `joined.dart` rather
than left as a thing somebody could add without noticing.

**Run three times on this commit. Every screen identical, both profiles, every
time** — including the one with a spinning progress indicator in it, which
reproduces because the download is held open and released on the capture loop's
own clock rather than because a spinner is stable.

**The invented-identity rule got sharper and the file now says so.** An owner
approves somebody **by their email address** — it is the one thing about a
stranger the server can vouch for, and it is printed on screen. So a careless
fixture would publish a real person's address, not merely a real name. Every
address in both seed files is at `example.org`, a reserved documentation domain
that can never belong to anybody. The two projects are in the Owyhee uplands and
the Steens, both of them public land nobody on this project works on.

**Exit 2 now covers a state that has never been photographed before, and this is
the part worth keeping.** The image comparison catches a screen that *stops*
being photographed, because its old image is still in the repository. **A
brand-new state has no predecessor**, so on the run that introduces it there is
nothing for its absence to differ from — a state that silently captured nothing
would have arrived as a complete, green set. The list of names a full run must
produce now lives in one file that both halves read: the capture run walks it,
and the review, in a different process on the host, refuses with exit 2 if any
name has no file, or if the run produced a name the list does not have. A name
appearing twice is also exit 2 rather than a last-write-wins, for the reason task
11.91 established about `attack()`.

**It went red on its first outing, within the hour.** A refactor made the
provider overrides a `List<dynamic>`, the app never booted, `flutter drive`
printed "All tests passed", and the review refused an empty directory — the third
time that has happened on this harness and the third time nothing else noticed.

**Two committed images changed and both were looked at.** `project-members` moved
because this task added a third member, so all three roles are visible rather
than two. **`log` moved because the app changed, not because this task did**:
task 11.93 landed the truth point's "Found by … · Position: GPS fix" line and
also updated this lane's seed file to set those fields. That is the drift check
doing exactly what it is for, on the first regeneration since.

**One image was deleted rather than re-accepted.** The unconfigured
`join-project` picture showed the words *"Could not load projects:
SyncTransportException(not_configured)"* on a screen that, on a device with no
server, **no control anywhere in the app can open**. A committed screenshot of a
state the app cannot produce is the same defect as copy describing a mechanism
the code does not have, in picture form. The joined half photographs that screen
in the state a person actually meets it in.

**What the guide still cannot illustrate** — the list the task asked for, so
`/w-03` does not discover it halfway through:

1. **The owner's approval sheet is not photographed.** Tapping Approve opens a
   modal where the role is chosen and the removal disclosure is shown. This run
   never opens it, so the guide can show *that* an owner approves but not *what
   they are asked* when they do. This is the biggest remaining gap in the join
   story and it is a modal, not a route — it needs a tap and a second capture.
2. **Two of the requester's outcomes are missing:** "the owner turned this down"
   and "you're in, but the download stopped partway". Both are ordinary, both
   are already written into the app, and neither is on film.
3. **Only one of the sync bar's eight states is photographed** — healthy, with
   records waiting. Offline, "records refused", "records missing" and
   "you're no longer on this project" all need a sync round against a failing
   server, and this harness deliberately never runs one. Illustrating them means
   making the sync engine's connection replaceable the way the membership one
   already is. **That is an app change, not a harness change**, which is why it
   is a finding below rather than something this task did.
4. **On the iPad, `owner-members-and-code` and `owner-pending-request` are the
   same image**, byte for byte — the whole members screen fits above the fold
   there. They differ on the phone. Worth knowing before both go on one page.
5. **Everything `/w-02` already named still holds.** The phone `map` and
   `position` images still carry the debug overflow stripes — I watched task
   11.95's defect fire on this run, so it has not landed. No GPS fix anywhere. No
   first-launch screen. No desktop. No Android.

**For the planning session**
1. **`/w-03` is unblocked for the join, members, roles and sync sections** and
   should use the `join-`, `joined-` and `owner-` images for them. The
   unconfigured `projects`, `project-members` and `sync-status` images are still
   right for the "TriTrack works with no server at all" material, and that is
   worth saying in `/w-03`'s brief so the two sets are not mixed on one page.
2. **Ask whether the owner's approval sheet is worth a follow-up harness task**
   (gap 1 above). It is a small change — a tap and a capture — but it is the one
   place the join story is now visibly incomplete, and `/w-03` will feel it.
   **My recommendation: yes, and it is small enough to fold into `/w-03` rather
   than get its own number**, provided `/w-03` is allowed to touch
   `integration_test/screenshots/` — which today only `/w-02` and `/w-05` are.
3. **One app finding needs a task number**, in "Findings for the code stream"
   below: the sync engine's connection cannot be replaced in a test, so the sync
   bar's error states cannot be photographed and, more to the point, cannot be
   exercised end to end by any test either. **This is worth fixing on its own
   merits, not for the screenshots.**
4. **`integration_test/screenshots/` is now written by both lanes.** Task 11.93
   correctly updated the seed file when it added two columns, and that was the
   right thing to do — but the plan names that directory as *this* lane's single
   exception, and it now has two writers. **Nothing went wrong and nothing needs
   undoing**; the rule just no longer describes what happens. Worth one sentence
   in `WEBSITE_PLAN.md` saying a code task may update the seed when it adds a
   field, and must say so in its comms entry, the same way it must for copy.
5. **`/w-05` is Done and nothing is blocked on me.**

**For Michael**
1. **Nothing to do, and nothing to push by hand — committed to `main` as
   `90896ed`.** Push when you next push.
2. **Look at the new pictures if you like**, and the four worth a glance are in
   `website/static/screens/iphone-6.9/`: `join-code-entered.png`,
   `join-waiting.png`, `owner-pending-request.png` and `join-arrived.png`. They
   are the join flow end to end. **None of them is on the website yet** —
   `/w-03` writes the pages that use them.
3. **A decision only you can make, and it is small.** Item 2 above: should the
   owner's approval sheet — the box that appears when you tap Approve, where you
   pick somebody's role — be photographed too? I think yes and I think it belongs
   in `/w-03` rather than a task of its own. Say if you would rather it waited.
4. **A risk you are now carrying, and it is the same one `/w-02` left you with.**
   The pixel comparison will not notice a single short word changing on a screen.
   It is now guarding 44 images instead of 28, so there is more surface for that
   to happen on. Nothing new has broken; there is simply more of it.
5. **One thing that is *not* a risk, so you do not have to wonder.** The
   screenshots contain an email address, a name and a join code that all look
   real. They are invented, at a domain reserved by the internet standards body
   for exactly this, and the code is not a code for anything. Nothing in these
   images points at a person, a place, or a project.

**Findings for the code stream**

1. **The sync engine's connection to the server cannot be replaced in a test, so
   nothing can check what the app shows when syncing fails.** Every other place
   the app talks to a server goes through one swappable seam — task 11.83 made
   the membership one a provider for exactly this reason, and its comment says
   so. `SyncController` does not: it builds its connection inline
   (`lib/core/providers/sync_provider.dart:943-957`), so a test cannot make a sync
   round fail, time out, or come back with a refused record. **What this means
   for a person:** the sync bar has eight states and seven of them are about
   something having gone wrong — "records refused", "you're no longer on this
   project", "sync isn't working" — and **no test anywhere exercises any of them
   end to end.** They are the states somebody in the field actually needs to be
   right, and they are the ones nothing is checking. I found this because the
   screenshot harness cannot photograph them, but **the screenshots are the least
   of it.** The fix looks like the one 11.83 already made next door, and I am
   fairly confident it is small; I have not tried it, and I have not checked
   whether anything else depends on that construction happening inline.
2. **Small and cosmetic, flagged rather than filed:** on a 6.9-inch iPhone, a
   pending requester's email address wraps mid-word in the approval list —
   `priya.raman@example.or` / `g`. It is readable and it is not wrong, but an
   address broken across a line without a visible break is the kind of thing
   somebody transcribes incorrectly, and this is the one screen where an owner is
   deciding whether they recognise the address. The iPad is wide enough and is
   fine. **I am not sure it is worth anybody's time**; it is here so the decision
   is made rather than missed.

**Resolved 2026-08-31 by the planning session.**

**Two things here are better than the task was asked for.**

**Exit 2 covering a state that has never been photographed before.** The comparison catches a
screen that *stops* being captured, because its old image is still in the repository — **but
a brand-new state has no predecessor, so on the run that introduces it there is nothing for
its absence to differ from.** A silently-empty new state would have arrived as a complete,
green set. One name list, read by both halves, in different processes, with a duplicate name
refused for task 11.91's reason. **That is the class being closed rather than the instance**,
and it was found by reasoning about the check rather than by it failing.

**And deleting the unconfigured `join-project` image rather than re-accepting it.** It showed
an error on a screen that, on a device with no server, **no control in the app can open** —
**a committed screenshot of a state the app cannot produce, which is exactly this project's
oldest defect in picture form.** Deleting it was right.

**Your items:**

1. **Carried into `/w-03`**, including the trap you named: the two sets must not appear on
   one page, because **a reader cannot tell that two screenshots are of two configurations
   and will read the difference as an inconsistency in the app.**
2. **Agreed, and granted: `/w-03` may capture the owner's approval sheet**, and that is the
   only harness work it is permitted. Your reasoning holds — the guide can currently show
   *that* an owner approves but not *what they are asked*, and that is the visible hole.
   `WEBSITE_PLAN.md` records the permission so it is a granted exception rather than a
   precedent.
3. **Task 11.97, and it is rated on the app consequence rather than the screenshots** — you
   were right that it is an app change. **Four of the sync bar's eight states can be drawn
   and explained by the app and driven by nothing**, and tasks 11.54 and 11.60 exist because
   two of those states were wrong in ways only a person on hardware found. **A state only a
   human can reach is a state that regresses silently.** 11.97 is told the seam is the
   enabling step and the tests are the result.
4. **Carried into `/w-03`** — the iPad pair being byte-identical is exactly the thing that
   would otherwise be placed on one page as two illustrations.
5. **Ratified, and the rule is amended in your favour.** 11.93 was right to update the seed,
   and reached that conclusion independently of you; you were right that the plan no longer
   described what happens. **`WEBSITE_PLAN.md` now carries the general rule — whoever creates
   the obligation discharges it** — with the code lane's edit rights bounded to seed data
   only, disclosed in its comms entry, and never the harness, the capture list, the
   comparison or any image.

**Your confirmation that 11.95's defect fired on this run is useful and is recorded**: the
phone `map` and `position` images still carry the overflow stripes, so that task has not
landed and `/w-03`'s constraint still stands.


---

### Task w-04 — 2026-08-31 — commit df46a61 — Done

`/w-02` committed `website/tools/pubspec.yaml` without adding the matching `dart pub get
--directory website/tools` line to `.github/workflows/offline-suite.yml`, so
`test/documentation/analyzed_packages_test.dart` was red — every real test failure in the
offline suite was hidden behind this one known gap. Checked the repository for every
`pubspec.yaml` rather than assuming `website/tools` was the only miss: it was. Added the
one line and ran the test directly — green.

**For the planning session:** nothing.

**For Michael:** Nothing — this is complete. `test/documentation/analyzed_packages_test.dart`
passes locally; the fix is one line in `.github/workflows/offline-suite.yml`, already
committed.

**Resolved 2026-08-31 by the planning session. Nothing was asked for.**

**The instruction that mattered was followed: it checked every `pubspec.yaml` rather than
assuming the known gap was the only gap**, and confirmed `website/tools` was the only miss.
That is the difference between fixing a reported symptom and answering the question the test
was asking. **`/w-02` ran between this task being written and being run, so there was a real
chance of a second package** — there was not, and now that is known rather than assumed.

**One thing to watch on the next push, and it is the whole point of the fix rather than a
doubt about it.** The task ran `analyzed_packages_test.dart` directly and saw it green,
which proves the line works. **What cannot be proved until the suite runs in full is what
the suite was hiding while it was red** — by task 11.68's rule, a suite red for a known
reason cannot report an unknown one, and it has been red since `/w-02` landed. **The next
full CI run is the first honest reading of the app's tests since then.** If something else
is red there, it is not this task's doing; it is what this task made visible.

**The lane rule that produced this task stands and needs no change:** whoever adds a Dart
package owns the workflow line it requires. It bit once, it was assigned once, and the rule
is written down.


---

### Task w-02 — 2026-08-31 — commit c7c0521 — Done

**What it does.** One command now rebuilds every screenshot the website will ever
show, from a simulator running the real app over invented field data — and a
regeneration that comes out different from what is committed **stops and makes
somebody look** instead of quietly replacing the old image.

```
integration_test/screenshots/regenerate.sh                 # both profiles
integration_test/screenshots/regenerate.sh iphone-6.9 --accept
```

28 images are committed (14 screens x 2 devices, 6.2 MB). Run twice on the same
commit, both profiles came back **identical, every screen**, in 4 minutes 30
seconds.

**App Store sizes are done.** The two device profiles are iPhone 17 Pro Max at
1320x2868 and iPad Pro 13-inch at 2064x2752 — confirmed native, and exactly the
two sizes App Store Connect requires. Submission screenshots are the same files
the guide uses.

**The compass decision, made out loud: the sensor is faked at the app layer.**
The simulator has no magnetometer, so the heading is overridden with a constant
47 degrees, exactly the way the position stream is already overridden in the
app's own widget tests. The alternative — one hand-taken photograph of that one
screen — was rejected because **a photograph cannot be regenerated**, which is
the single rule this whole harness exists to enforce; it would have been the one
image on the site that silently rots and the one nobody remembers to re-take.
Only the number is invented: the layout, the bubble level and the declination
arithmetic are the real app. **The guide must say the heading shown is
illustrative**, and `/w-03` should treat that as a requirement, not a nicety.

**The tolerance, and what it costs.** A screen counts as changed when more than
**0.12%** of its pixels move. That is measured: twelve of the fourteen screens
are pixel-identical between runs, and the worst mover is the pre-trip checklist
at 0.05%, because it prints how many map tiles are cached and that depends on
what the run happened to fetch.

The cost was not asserted, it was watched. A block the size of one word of body
text (150 x 40 pixels, 0.15% of the screen) **is caught**. A slightly smaller
one (100 x 30, 0.08%) **is not** — the review calls it unchanged. So: a changed
heading, a moved control, anything the eye notices at a glance, all reported; a
single short word changed in place can slip through. That is what the copy-drift
check from `/w-01` is for, and **neither is a guarantee on its own**. A
comparison so strict every run went red would just teach people to click
through, which is worse.

**Watched going red and green.** Green on a clean re-run of both profiles.
Red on: a one-word-sized change (exit 1, named the screen and the percentage,
wrote a diff picture with the moved pixels in red, wrote nothing over the
committed image). Exit 2 on: a missing output directory, an empty one, an
unreadable PNG, and a run that captured only some screens (exit 1, listed the
13 MISSING by name).

**Exit 2 earned its keep twice on the first day.** `flutter drive` printed
"All tests passed" over **zero screenshots** on two separate occasions — once
when the capture loop got silently detached from the test, and once on macOS
where the screenshot method does not exist at all. Both times the only thing
that noticed was the review refusing to call an empty directory green.

**What it cannot photograph honestly** — named rather than shipped:

1. **The map and position screens on the phone profile carry a debug artefact.**
   A simulator can only run a debug build (`flutter drive --profile` refuses:
   release and profile builds are for physical devices only), and both those
   screens draw a map attribution line that overflows by 61 pixels on a
   phone-width screen. A debug build paints that as yellow-and-black stripes
   reading "OVERFLOWED BY 61 PIXELS". The images are committed so the
   comparison has a baseline for every screen, but **those two must not go on a
   page until the underlying defect is fixed.** The iPad versions are clean.
2. **Nothing is photographed with a GPS position.** See finding 1 below. The map
   has no "you are here", the record form does not show its position prefilled,
   and the compass shows magnetic north with no computed declination. One
   commented-out line turns it on when the defect is fixed.
3. **The first-launch identity screen is not captured.** A second app boot inside
   one run hangs. Left out rather than left flaky.
4. **The desktop app is not captured at all.** `flutter drive -d macos` builds
   and runs, then `takeScreenshot` fails with "No implementation found for
   method captureScreenshot" — `integration_test` does not implement it on
   macOS. Doing it needs a different mechanism (`screencapture` on the host,
   driven from the driver script). **The guide has no desktop screenshots
   until somebody builds that.**

**Cost of a run, measured.** iPhone profile warm: 2m 06s. iPad cold, with a full
Xcode build: 4m 50s. Both profiles warm, end to end: 4m 30s. On a GitHub macOS
runner that bills at ten times the rate, one full regeneration is **45 to 80
minutes** of the 2,000-minute monthly allowance — two to four percent. Ten a
month would be a third of the allowance spent on screenshots. **It is not wired
to CI and should not be.** Run it locally, on demand.

**The data is invented, and deliberately somewhere else.** Two people at
`example.org`, three collars with made-up frequencies, and a study area in the
Owyhee uplands of south-eastern Oregon — public land with no connection to this
project or anybody's field site, chosen specifically so it is nowhere near
Flagstaff. `test/data/fixtures.dart` puts its sample data at 35.19, -111.62,
which is fine for a test and would not be fine on a public web page: **a
published screenshot of a real collar location is a disclosure of where an
animal is.**

**For the planning session**
1. **Two app defects need task numbers.** They are in "Findings for the code
   stream" below. The first one blocks a GPS fix appearing in any screenshot;
   the second blocks the map and position images going on a page. **Both are
   worth fixing on their own merits, not only for the screenshots.**
2. **Decide whether desktop screenshots matter enough to schedule.** If the
   guide is to have desktop sections with pictures, somebody has to build a
   `screencapture`-based path in the harness — it is not a small change and it
   is not in `/w-03`'s brief. If desktop sections can be text-only for now, no
   task is needed. **This is a scope call, not a defect.**
3. **`/w-03` inherits one hard constraint:** it may not put the phone `map` or
   `position` images on a page until finding 2 is fixed, and it must say the
   compass heading is illustrative wherever the compass image appears.
4. **One thing to consider for `/w-03`'s ordering.** The screenshots are of a
   device with **no server configured**, so the sync screen shows the
   unconfigured state and the members screen shows only local membership. If
   the guide needs pictures of a synced device, that is a bigger harness change
   (it means driving the fake sync transport through a whole join) and should
   be its own task rather than something `/w-03` discovers halfway through.

**For Michael**
1. **Nothing to do, and nothing to push by hand — committed to `main` as
   `c7c0521`.** Push when you next push.
2. **Look at the pictures if you like:** `website/static/screens/iphone-6.9/`.
   `log.png` and `checklist.png` are the ones that show the invented data
   clearly. They are not on the website yet — `/w-03` writes the pages that use
   them.
3. **If you regenerate them yourself, the Simulator application must be open**,
   not merely booted. The script opens it for you; if you run `flutter drive` by
   hand and it seems to hang for fifteen minutes, that is why.
4. **A risk you are now carrying, and it is small but real.** The pixel
   comparison will not notice a single short word changing on a screen — that
   was measured, not guessed. If a label changes and the guide quotes it, the
   copy-drift check catches it; if the guide only *describes* it, nothing
   catches it. That gap was already written down in `/w-01` and this task does
   not close it.

**Findings for the code stream**

1. **The map screen starts a viewshed calculation while it is still drawing
   itself, and in a debug build that is an error.** `_MapScreenState._buildBody`
   calls `_maybeAutoComputeViewshed`, which calls `_computeViewshedAt`, which
   sets `ComputationStatusNotifier`'s state during `build` —
   `lib/features/map/screens/map_screen.dart:256`, `:990`, `:1501` and
   `lib/core/providers/computation_status_provider.dart:44`. Riverpod refuses
   this ("Tried to modify a provider while the widget tree was building") and,
   a few seconds later, something in the same chain throws an unhandled
   asynchronous error. **What this means for a person:** anybody running the app
   from an IDE in debug, with a GPS fix and a project open, gets a caught
   exception on the map every time. In a release build the assertion is
   compiled out, so it is invisible in the field — but the "modify a provider
   during build" rule exists because it can produce an inconsistent screen, and
   the unhandled async error is a separate problem that release mode does not
   fix. **I could not determine which part of the chain throws
   asynchronously** — the harness only sees that it escapes — so that needs
   looking at, not just the `setState`-during-build.
2. **The map's attribution line is cut off on a phone.** The `flutter_map`
   attribution row overflows by 61 pixels on a 6.9-inch iPhone with the default
   Terrain basemap, whose attribution string is the long one ("(c) OpenStreetMap
   contributors, SRTM | map style (c) OpenTopoMap (CC-BY-SA)"). In a debug build
   this paints the overflow stripes; in a release build the text is simply
   clipped. **What this means for a person:** part of the map attribution is
   unreadable on every phone. That is not only cosmetic — displaying the
   attribution is a condition of the OpenStreetMap and OpenTopoMap tile
   licences, and an attribution running off the edge of the screen is arguably
   not displayed. The iPad is wide enough and is fine. **I am not certain how
   the licences treat a clipped attribution**, and that judgement is not mine to
   make; the layout defect is real either way.
3. **Possibly harness-only, flagged rather than filed:** opening the app's
   database a second time in one process, after the file has been deleted
   underneath the first connection, never returns. It is why the first-launch
   screen is not captured. **I do not know whether any real path does this** —
   a restore, or a project delete followed by a re-open, might — so it is worth
   ten minutes of somebody's attention before it is dismissed.

**Resolved 2026-08-31 by the planning session.**

**The compass decision is right and the reasoning is the part worth keeping.** A photograph
cannot be regenerated, so a hand-taken compass image would have been **the one image on the
site that silently rots and the one nobody remembers to re-take** — which is the single rule
the harness exists to enforce, so exempting one screen from it would have exempted the rule.
**And you drew the line in the right place:** only the number is invented; the layout, the
bubble level and the declination arithmetic are the real app. `/w-03` now carries the
requirement that the guide say the heading is illustrative, phrased as a requirement rather
than a nicety — **a guide presenting a fabricated reading as a reading would be teaching
somebody to trust an instrument that is not measuring.**

**The tolerance was measured rather than asserted, and its cost was measured too.** 0.12%,
with a word-sized block caught at 0.15% and missed at 0.08%, watched both ways. **Saying
plainly that neither this nor the copy-drift check is a guarantee alone is worth more than a
tighter number would have been** — a comparison so strict that every run went red would only
teach people to click through.

**Exit 2 earning its keep twice on the first day is the strongest single result here.**
`flutter drive` printed *"All tests passed"* over **zero screenshots**, twice, and the only
thing that noticed was a check refusing to call an empty directory green. **That is the
project's oldest rule paying out within hours of being applied to a new tool**, and it is
worth remembering next time somebody argues an empty-input guard is defensive clutter.

**Your findings, dispositioned:**

1 & 2 → **task 11.95, beta-blocking, two commits in a stated order.** The attribution
overflow goes first because it is bounded and unblocks your images; the provider chain
second because it may grow. **11.95 is explicitly forbidden from fixing the
`setState`-during-build and calling it done** — you could not tell what throws
asynchronously, and *an unexplained async error on the app's primary screen in the ordinary
field case* is not something to ship past. **The check that it worked is your two flagged
screenshots regenerating clean**, not a green test.

**On the attribution being "not only cosmetic": you were right to raise the licence angle
and right that the judgement was not yours.** It is not 11.95's either — it is told to make
the whole string readable so the question stops needing an answer.

3 → **folded into task 11.82**, which is already in the database's neighbourhood, as a
**ten-minute** triage: can any real path re-open the database after the file was deleted? If
not, closed as harness-only; if so, **stop and file rather than fix** — a connection that
hangs forever is not a below-the-line repair. **Flagging it as uncertain instead of filing it
as a defect was the right call**, and it is recorded as a question rather than promoted to a
finding.

**Your item 2 — desktop screenshots — decided: text-only, no task.** `screencapture` plumbing
is real work for marginal return before a beta; the macOS app is used at a desk by somebody
who can see their own screen, and the field guide is the phone. **Revisit if the beta shows
people leaning on macOS.** `/w-03` is told to write those sections without pictures rather
than wait.

**Your item 4 is now task `/w-05`, and it lands before `/w-03`.** You were right that this
should not be something `/w-03` discovers halfway through: **the guide's flagship section is
joining a project, and every screenshot you took is of a device that never joined one.**
`/w-05` drives the fake transport through a whole join, reuses your harness rather than
rebuilding it, and carries your three rules forward — invented data, a changed image makes
somebody look, and exit 2 covers every new capture path. **It adds one hazard you did not
have to think about: the join screens show email addresses and names, so no image may carry
a real one.**

**Item 3's constraints are written into `/w-03`** — no phone `map` or `position` images
until 11.95 lands, and the compass caveat.


---

### Task w-01 — 2026-08-31 — commits bc497c3, e52971a — Done

**What it did.** The site is live at
<https://dynamic-and-active-systems-lab.github.io/tritrack-site/> — landing page, a guide
section with one placeholder page, and privacy and support stubs, all six routes confirmed
serving 200. The `tritrack` repository is still private; a new public repository,
`dynamic-and-active-systems-lab/tritrack-site`, holds only rendered HTML and is rewritten
from scratch on each deploy. And the drift check exists, before there is any content to
drift.

**For the planning session**
1. **Nothing is blocked.** `/w-02` and `/w-03` can proceed on this foundation as written.
2. **Consider whether the drift check should also read `server/` and `packages/`.** It
   reads `lib/` only, which is what the task specified. The messages a removed member sees
   are partly composed on the server, and a guide sentence quoting one of those would pass
   unchecked today. This is a judgment call about scope, not a defect — flagging it rather
   than widening the check unilaterally.
3. **The check cannot tell which *screen* says a string.** It answers "does the app still
   contain this text anywhere in `lib/`". During this task it correctly stayed green when
   one occurrence of a label was renamed, because the same words were still a tooltip on
   another screen. If the planning session wants per-screen accuracy that is a different
   and considerably harder check; the limit is written down in `website/README.md` rather
   than left implied.

**For Michael**
1. **Nothing to do.** Committed and pushed to `main`; both commits are green in the
   Website workflow.
2. Look at the site if you want to: <https://dynamic-and-active-systems-lab.github.io/tritrack-site/>.
   It is deliberately almost empty.

**Findings for the code stream:** none. This task wrote no guide prose, so it produced none
of the "needed three sentences to explain" observations the plan expects from `/w-03`.

**Notes on the choices, for whoever re-opens them**

- **Generator: Hugo 0.165.0**, pinned by version and SHA-256. One statically linked binary,
  no dependency tree. The drawback, recorded in `website/README.md`: Hugo's templates are
  Go templates, unlike anything else in this repository, so whoever next edits a layout
  pays a real learning cost. Editing *content* is Markdown and costs nothing. Judged the
  cheaper trade because content changes weekly and layout almost never.
- **Host: GitHub Pages from a public output repository**, chosen by Michael over Cloudflare
  Pages because it could be wired and verified end to end in this session; the alternatives
  all needed a browser signup that only he can do. The workflow pushes over an SSH deploy
  key scoped to write to `tritrack-site` alone, stored as the repository secret
  `SITE_DEPLOY_KEY`. **The site is only published after the drift check passes**, so a
  drifted site is never served.
- **The marking is not optional.** Quoted app copy goes through a `{{< app "..." >}}`
  shortcode and is verified against `lib/`. Typing bare quotation marks in prose, or bold,
  is refused outright with a message naming the shortcode — so a writer cannot quote the
  app *without* it being checked, rather than being merely encouraged to. The one escape
  hatch needs a written reason per entry, errors on a duplicate rather than last-write-wins,
  and errors on an entry that has stopped matching anything.
- **Watched going red and green, four ways.** Against a real modified copy of `lib/` with a
  label renamed (red) and against `lib/` itself (green); in CI on a throwaway branch that
  quoted a sentence the app does not say — the run failed, named the file, line and string,
  and the publish job was skipped; and with the checker's own comparison stubbed out, which
  `website/tools/selftest.sh` caught. That self-test asserts exit codes for fourteen cases,
  five of which must go red, and runs in CI ahead of the real check.
- **Exit 2 means "could not run" and is not a pass.** An `lib/` directory containing no Dart
  is a failure, not a green tick over nothing.
- **One file outside `website/`:** `.github/workflows/website.yml`, a new file the code
  stream does not touch. There is no way to wire a check into GitHub Actions from inside
  `website/`. Nothing else outside this lane was staged — the code stream had uncommitted
  work in `lib/` and `test/` throughout, and it was left alone.

**Resolved 2026-08-31 by the planning session.**

**First, the thing that was not asked about and mattered most.** Both lanes committed to
`main` in the same window and did not collide — and **this task explicitly left the code
stream's uncommitted work in `lib/` and `test/` alone** while task 11.92 was running.
That was the single hazard the parallel lane was set up to risk, handled correctly on the
first run without being told. **Keep doing exactly that.**

**On the choices.** Hugo pinned by version *and* SHA-256, one binary, no dependency tree —
right for a repository nobody wants to spend maintenance on. **The drawback recorded rather
than omitted** (Go templates are unlike anything else here, so layout edits cost real
learning) is what makes it a decision somebody can revisit instead of re-derive. The
reasoning is sound: content changes weekly, layout almost never.

**Two things about the check are better than the task asked for.** Quoting the app in bare
quotation marks is **refused outright**, so a writer cannot quote without being checked
rather than merely being encouraged to — the difference between a convention and a control.
And **exit 2 means "could not run" and is not a pass**: an empty `lib/` fails rather than
producing a green tick over nothing. That is the project's oldest rule — a check that cannot
distinguish success from its own failure is not a check — applied to a check on its first
day.

**And it was watched going red four ways**, including with its own comparison stubbed out.
A self-test asserting fourteen exit codes, five of which must be red, running ahead of the
real check.

**Item 2 — should the check read `server/` and `packages/`? Not yet, and the question is
really a different one.** This project has a standing invariant, written at §4.13 and
enforced through 11.81: **no server prose is ever shown to a user.** The server sends a
refusal *code*; the app writes the sentence. **If that invariant holds, `lib/` is not a
narrow scope — it is the complete one**, and widening the check would add surface for no
gain.

So the right move is not to widen the check but to **establish whether the invariant is
actually true** — whether any user-visible sentence originates outside `lib/`. **If one
does, that is a code-stream defect, not a check-scope decision**, and the fix belongs in the
app. **That question is going to the code plan as a task, deliberately not applied today:
task 11.92 is mid-run and the planning session does not edit `DEVELOPMENT_PLAN.md` while a
task is writing to it.** It will be added when 11.92 lands.

**Item 3 — the per-screen limit is real, and the answer is a screenshot, not a harder text
check.** The check can only ask *does this text still exist anywhere in `lib/`*, and your
own example proves the gap: a renamed label stayed green because the same words survived as
a tooltip elsewhere. **Building per-screen text attribution is expensive and would duplicate
something `/w-02` gets almost for free** — if a screen changes, its image changes.

**But only if somebody is made to look.** `/w-02` has been amended: images are committed,
and a regeneration that differs from the committed set is **something a person must
acknowledge**, reported by screen name, rather than a quiet overwrite — a silently replaced
screenshot is the same defect one level over. It is also told to **pick a pixel tolerance
and write down what that tolerance costs**, because a threshold loose enough to absorb font
jitter will also absorb a one-word label change, and a comparison so strict that every run
is red teaches people to click through.

**Item 1 acknowledged:** `/w-02` and `/w-03` proceed as written, with `/w-02` carrying the
amendment above.

**The `.github/workflows/website.yml` exception is accepted and is now the lane's second
named exception**, alongside the screenshot harness. The reasoning is correct — a check
cannot be wired into Actions from inside `website/` — and naming it rather than quietly
widening the lane is what keeps the rule meaningful.


