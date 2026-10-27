# TriTrack website and user guides — the content stream

> ## THE HARNESS IS IN GOOD ORDER — `/w-14`, `/w-15` and `/w-16` are all done (2026-09-08)
>
> **Three profiles, 34 states, all regenerated and accepted.** `check_app_quotes` is green — 162
> quotes, 11 pages, 0 waivers — and the tree is green without the pre-commit escape hatch.
>
> **Four things this banner used to say are now false and are struck here so nobody acts on them:**
> ~~the Position diff is unstable~~ (the map is required to be *drawn* now, and four consecutive runs
> came back pixel-identical); ~~the harness has two profiles~~ (**three** — `iphone-6.1` is
> permanent, at exactly `phoneGeometry`); ~~it cannot see the notes box open~~ (`record-note` is
> published); ~~`/w-16` is next~~.
>
> **The first photograph this project has ever taken of the screen size all its layout rules are
> written for is `website/static/screens/iphone-6.1/record.png`.**
>
> **`/w-26` — the diagrams are wide and a phone cannot read them. The next content task.**
> **Michael looked at all five in a browser on 2026-09-18, the first time anybody had:** *“they are
> all currently left to right but it shrinks to so small when applied to a phone screen width. The
> text size in those diagrams is really small.”* **Confirmed: every one is `rankdir=LR`.** Scaling an
> SVG shrinks its text with it, so a 900px picture in a ~335px column renders 13pt type at about 6px.
> **Raising `fontsize` makes it worse** — a wider diagram scales down further. The fix is the aspect
> ratio. **The measurable target: each rendered SVG's intrinsic width at or under the measured
> content column, so nothing is scaled at all.** It also carries task 11.284's one stale quote on
> `truth-points.md`.
>
> ### `/w-38` — publish the two theory pages, and put the support email on the Support page (added 2026-10-09)
>
> **Michael, 2026-10-09:** *"go ahead and publish the theory drafts with the recent wedge updates. my email is
> michael.shafer@nau.edu."* Small; **run now, before `/w-35`.**
>
> 1. **Publish both pages together:** remove `draft: true` from `how-the-estimate-is-calculated.md` and
>    `the-mathematics-of-the-estimate.md` (with the step 1 wedge figure of `63922fb`), and remove each page's own note that it
>    is a draft. **Apply every `PUBLISH-WITH-THEORY` comment** (`how-it-works.md`, `estimating-a-position.md`, and the theory
>    page's own list): put in the link or sentence each one holds, then delete the comment. Afterwards a search for
>    `PUBLISH-WITH-THEORY` finds nothing.
> 2. **The Support page's *Getting in touch*** gives **michael.shafer@nau.edu** as the way to reach TriTrack support, as a
>    `mailto:` link, with one line on what to include (the version from App Info, the phone, what happened). Keep the site
>    repository link for site problems. The rest of the page (its "not written yet" line and the other sections) is `/w-35`
>    item 26's.
> 3. **Checks:** `hugo` (plain, not `-D`) now builds both pages, and the menu or guide index lists them where the other docs
>    pages are; every internal link resolves, including `#how-often-does-the-95-ellipse-contain-the-animal`;
>    `theory_figures.dart --check` and `check_app_quotes` (the same 8 known reds only, `/w-35`'s); no raw TeX on either page.
>    A fresh PDF of each page into `Claude outputs/`.
> 4. **The site publishes when Michael pushes** (`website.yml` runs on a push that changes `website/**`); say so at the end of
>    the report.
>
> ### `/w-37` — split the theory page: the method in pictures, and the mathematics on its own page (added 2026-10-08)
>
> **Michael, 2026-10-08:** split it (the page grew from about 2,700 to 5,100 words with `/w-36`; his standing view is that
> efficient clarity beats length). **Run before `/w-35`**, which links to it.
>
> 1. **`how-the-estimate-is-calculated.md` keeps** the plain explanation, `/w-36`'s seven pictures with their colored equations
>    (the short form each picture explains), *How often does the 95% ellipse contain the animal?* with its advice first, *What
>    TriTrack does not do (yet)*, the methods sentence and the references. **Aim for well under the old 2,700 words of prose**;
>    say the count.
> 2. **A new page, *The mathematics of the estimate*** (title to taste), holds the full derivations and equations: Lenth's
>    likelihood and iteration, κ and Fisher's approximation, the covariance and the ellipse's axes, *Where TriTrack differs from
>    the paper*, and the worked example's numbers. Same colors, same numbered references (its own list, or a shared one).
> 3. **Each links to the other** in its first lines, so a reader picks a depth. Keep the anchor
>    `#how-often-does-the-95-ellipse-contain-the-animal` on the first page (task 11.338 names it). No equation or citation is lost:
>    list where each moved.
> 4. **Both stay drafts.** `theory_figures.dart --check`, `check_app_quotes` and `hugo` (with drafts) green; internal links resolve;
>    a fresh PDF of each into `Claude outputs/` for Michael.
>
> ### `/w-36` — the theory page says what the 95% ellipse is, how far to trust it, and shows why (added 2026-10-06, re-scoped 2026-10-07)
>
> **Run after task 11.336.** Michael, 2026-10-06: a section *"with your simulation with figures showing some of the
> simulations"*, citing the LOAS manual; and 2026-10-07: **standard, citable methods only** (`CLAUDE.md` standing decision 5).
> The app's ellipse does not change. The page is `website/content/docs/how-the-estimate-is-calculated.md` (still a draft).
> The sources are in `CLAUDE_DOCS/` for reading (git-ignored, copyrighted: quote briefly, never copy pages).
>
> 1. **Say what the ellipse is, with its sources:** Lenth's (1981) covariance; the 95% region from the chi-square
>    distribution with 2 degrees of freedom, as White & Garrott (1990, pp. 62–63) construct it; κ estimated from the fix's
>    own bearings (Lenth's method; TriTrack uses Fisher's approximation, as the page already says). Move "the 95% chi-square
>    ellipse" out of *Where TriTrack differs from the paper*: it is the textbook's construction, not TriTrack's invention.
> 2. **A section, "How often does the 95% ellipse contain the animal?"**: chi-square assumes κ is known; estimated from a
>    few bearings it makes the ellipse too small. Cite the LOAS manual (Ecological Software Solutions, 1/1/2005, p. 11 [corrected from 10 by `/w-36`]: "a true
>    accuracy of about 45–85%"), White & Garrott's field result (Table 4.1, p. 70: maximum-likelihood ellipses covered the true
>    location about 41% of the time where signals bounced), and TriTrack's own simulation from 11.336's data. **Figure:
>    coverage against number of bearings** (one line per bearing spread, the 95% line drawn, and the true-κ reference);
>    **figures: worked examples**, one where the ellipse contains the animal and one where it misses. Plain words first: take
>    more bearings; the app cautions at five or fewer.
> 2a. **The method explained in pictures, before any equation** (Michael, 2026-10-07: *"The LOAS manual, the White &
>    Garrott, and the Lenth paper are all equation heavy and light on intuitive graphics … color coding on linking graphs and
>    equations … ecologists/biologists should be able to understand the methods without taking advanced mathematics in
>    college. Graphics and animations help a lot."*). **This is the heart of the task, not decoration.** For each step below:
>    plain words, then a picture or animation, then the equation **with its symbols colored to match the picture**, then one
>    line on what it means in the field. In order:
>    1. **One bearing is a probability, not a line**: the von Mises distribution drawn as a fan of likely directions around
>       the observed bearing; how κ narrows or widens it (a few values side by side, or an animation sweeping κ).
>    2. **Each bearing makes a ridge of likely places on the map; the bearings together multiply into one hill**: a heat map
>       of the likelihood, built up as bearings are added one at a time (animation), its peak marked as the estimate.
>    3. **Finding the top of the hill**: the solver's steps climbing to the peak (from 11.336's iteration path for a worked
>       example), including a step that is shortened because it would have gone downhill.
>    4. **How spread out the bearings are (κ)**: the leftover angles between each bearing and the estimate, and how their
>       average becomes κ; why with few bearings those leftovers look smaller than the real error (the fit uses some up).
>    5. **From the hill's shape to the ellipse**: a steep, narrow peak gives a small ellipse and a broad one a large ellipse;
>       the 1-standard-deviation ellipse, then scaled to 95% by the chi-square value 5.991, with each axis labeled.
>    6. **Geometry matters**: the same bearing error from well-spread stations and from nearly parallel ones, and the long
>       thin ellipse the second gives.
>    7. **Does the 95% ellipse contain the animal?**: an animation of many simulated fixes, each true point marked inside or
>       outside its ellipse, building up the coverage figure in item 2.
>
>    **How the graphics are made and shown:**
>    - **Faithful to the app.** Every picture is drawn by a script kept in the repository, from 11.336's data or from a
>      re-computation that is **checked against that data** (the script's estimate, κ and ellipse must match the app's for
>      the worked examples, to a stated tolerance; the script fails otherwise). No hand-drawn approximation of the method.
>    - **One color per quantity across the whole page** (for example the bearing, κ, the estimate, the ellipse), the same
>      color in every figure and in the equations (KaTeX `\color{}` renders to MathML `mathcolor`; check it in the built page).
>      A colorblind-safe palette that **reads on both the light and dark themes**; color is never the only cue (labels too).
>    - **The site loads no script and nothing from elsewhere** (`layouts/_markup/render-passthrough.html` says why). So
>      animations are self-hosted files (short looping video with controls and a poster frame, or animated SVG), small,
>      not autoplaying with sound, and **each has a still storyboard** (small multiples) that stands in for it in print and
>      the PDF. A shortcode for them if the existing `diagram`/`shot` shortcodes do not fit.
>    - Legible at phone width (the w-29 lesson); alt text and a one-sentence caption saying what to notice.
>
> 3. **"What TriTrack does not do (yet)"**, short: system testing for a measured bearing precision and bias (White & Garrott ch.
>    5), their goodness-of-fit check for bounce, a maximum ellipse size, the Andrews estimator, and F-based ellipses (LOAS).
>    Each one sentence with its source; say that exported bearings let a person apply them now.
> 4. **Citations, exact:** White, G. C., and R. A. Garrott. 1990. *Analysis of Wildlife Radio-Tracking Data.* Academic Press,
>    San Diego; the LOAS manual with its URL; Lenth (1981). Nothing unread.
> 5. **Figures drawn from the committed data by a script kept in the repository**; legible at phone width; alt text. Fold in
>    11.336's copy list: the new caution *"Few bearings — the 95% ellipse usually understates the uncertainty. Add bearings if
>    you can."* (shown for 3–5 bearings, on the Position screen's cautions, the Map's estimate card and Past estimates) goes into
>    `estimating-a-position.md`'s list of cautions, with a sentence pointing to this page. **11.336's data and its README are in
>    `test/localization/ellipse_coverage_data/`** (`coverage_chi_square.csv`, `worked_examples.json` with each example's solver
>    path, κ inputs, covariance and both ellipses); read them, do not recompute what they hold. The page stays a draft; a fresh PDF into `Claude outputs/` for Michael. If his Word file of theory edits
>    now has changes, list them and do not apply them without asking.
>
> ### `/w-35` — the video, the theory page, a project-setup page, and two checks the site lacks (added 2026-10-01)
>
> **From the overnight batch's comms entries and Michael's answers (2026-10-01).**
>
> 1. **The *Take on map* video goes on the site.** Michael approved the 4× clip
>    (`Claude outputs/take-on-map.mp4`; `record_video.sh` regenerates it). Commit it, add a `video`
>    shortcode (muted, looping, the `take-on-map` picture as its poster, a caption, refusing a file
>    that does not exist, like `shot`), and place it on *Recording a bearing*.
> 2. **Done elsewhere (2026-10-10):** `/w-38` published the theory pages and applied every `PUBLISH-WITH-THEORY`
>    comment, including fixing `how-it-works.md`'s link. Nothing to do here.
> 3. **Two checks on the built site**, run locally and in `website.yml`: **every internal link
>    resolves** (five were broken for two days), and **no raw TeX appears outside a formula**
>    (Michael caught one by reading). Watch each red first on a deliberately broken copy.
> 4. **A short "Setting up a project" page** for the gaps the quick start exposed (`/w-34`): creating
>    a project (the **+**, *New Project*, the extent, *SAVE PROJECT*), the Pre-Trip Checklist, and
>    **publishing before the crew can join**. Offline maps already have steps on the map page; link
>    them. Point the quick start's steps 1, 4 and 5 here. **Two pictures:** the *New Project* form,
>    and the Offline Data Map with a selection drawn (new harness states). Short; task 11.320's and
>    `/w-33`'s rules apply.
> 5. The copy-changes list's 11.241 entry should name `deployments.csv` (`/w-33` finding 4).
>
> **Added 2026-10-02: Michael's comments on the printed guide** (`Claude outputs/TriTrack-website-review.docx`).
> **Run after tasks 11.324 and 11.331** (11.331, added 2026-10-06, puts a time-zone line on the New Project
> form, which item 4's setup page shows). 11.324 renames the deletion actions, adds the "finish setting up" sheet,
> changes how an existing Tag ID is handled, and points people to TriTrack support; describe those
> as 11.324 leaves them, read from the widgets.
>
> 6. **"Signal" is ambiguous** (`how-it-works.md`, "none of it needs a signal", and everywhere
>    else). In this app *signal* is the tag's radio signal. Wherever the site means phone coverage,
>    say **cell or wifi coverage** (or "no connection"). Search every page.
> 7. **Quick start, step 1:** mention choosing the project's **extent**, and why it matters (it is
>    the area offline maps and the checklist's map items cover), and the new "finish setting up" sheet.
> 8. **`joining-a-project.md`, "When it does not work":** say what "it" is (asking to join), and
>    reword **"Turned down:"** so it plainly means *the owner rejected your request*.
> 9. **Remove every "On a Mac" section.** Instead, one sentence on the guide's index: the Mac app is
>    the same, except that a Mac has no compass or GPS.
> 10. **`projects-members-and-roles.md`, roles table: "Take a bearing out of the analysis"** is
>     unclear. Say what it is: excluding a bearing from **position estimates**.
> 11. **Deleting a project: add one or two flow diagrams** of where the data lives (the owner's
>     phone, members' phones, the server) and what each action does: *Move to Trash* by an owner,
>     by a member, *Restore*, and *Delete permanently*. Arrows for where data is written; green
>     checks and red crosses for kept and removed. Same Graphviz approach as the site's other
>     diagrams, checked against the code, not the guide.
> 12. **Say why a deletion from the server waits 30 days** instead of happening at once: it gives
>     the owner, and every member, time to change their mind and to export.
> 13. **`device-and-server` diagram on the Sync page:** the "also on this device — never syncs"
>     label reads as if it belongs to both lines. Attach it unambiguously to one.
> 14. **Sync settings, *Only when I ask*:** the reason to choose it is **battery**, not data. Project
>     data is small; automatic sync keeps trying in the field with no coverage, which costs battery.
>     (Keep the line that there is no wifi-only setting.)
> 15. **The central server** (`CLAUDE.md` standing decision 3): every "whoever runs your server" on
>     the site becomes a pointer to TriTrack support (the Support page).
> 16. **Privacy page: data on the server.** Add how long the server keeps records (read every
>     window from the code and its configuration: deleted records, the audit log, a scheduled
>     project deletion and its backups) and that **backups of the server are planned but not in
>     place yet**. Say nothing the code does not do.
> 17. **Tags page:** with 11.324, say what happens when a Tag ID already exists in the project, and
>     that two phones offline can still create the same one (resolved later by merging).
> 18. **Caption fix, already made by Michael:** remove "The compass heading is scripted, because a
>     simulator has no compass." from the *Take on map* caption.
>
> **Added 2026-10-06: task 11.323's copy list** (its `TASK_COMMS.md` entry has the exact new strings).
>
> 19. **`estimating-a-position.md` (lines 72–73)** says nothing explains a missing ellipse and that a
>     two-bearing save lists 0×0 m. Both are now false: the caution says why, and the save stores "no
>     ellipse" (Map card "No error ellipse", Past estimates "no ellipse").
> 20. **`getting-your-data-out.md` (line 31):** add `position_estimates.csv` to the export's files, with a
>     sentence on what a row is; the receipt now counts estimates.
> 21. **Theory page (`how-the-estimate-is-calculated.md`, still a draft):** line 354's "no ellipse and no
>     caution" for two bearings is now wrong (there is a caution); and say the solver shortens a step that
>     would make the fit worse, a departure from Lenth's plain iteration (his worked example is unchanged).
>     **The ellipse's size and the coverage section are `/w-36`'s**; if `/w-36` has run, only check these two
>     points survived it.
> **Items 19 and 21 were done by `/w-36` (2026-10-08): only check they survived.**
>
> **The theory is two pages, published by `/w-38`** (Michael, 2026-10-09). This task only checks their links.
>
> 22. **The `position-cautions` screenshot** shows Sage's "Solver did not fully converge", which no longer
>     happens. Regenerate it with a caution that still occurs, and fix its caption.
>
> **Added 2026-10-08: task 11.324's copy list** (its `TASK_COMMS.md` entry has the exact strings).
>
> 23. **The 8 lines `check_app_quotes` reports red** on `projects-members-and-roles.md` (7) and `sync.md` (1): *Delete project* →
>     *Move to Trash*; *Delete from server…* → *Delete permanently…*; *Deleted from your devices, still on the server* → *Trash*;
>     the two owner-only refusals; and "tell whoever runs your project server" → "tell TriTrack support (More → App Info)". Also
>     the guide's own "with signal" / "when there is signal" phrasing → cell or wifi coverage.
> 24. **Describe the new screens** where the guide covers them: the *Finish setting up* sheet (in item 4's setup page), the two new
>     Pre-Trip Checklist rows, the *Tag ID X is already on this project* dialog (item 17), App Info's *TriTrack support*.
> 25. **Re-shoot** App Info, Projects' Trash section and its row menus, and the setup sheet.
> 27. **The few-bearings caution gained a sentence** (task 11.338): *… Add bearings if you can. See "How the estimate is calculated"
>     in the TriTrack guide.* Quote the full line on `estimating-a-position.md`; the two theory pages may keep quoting the first part.
> 26. **The Support page is now where the app sends people**, and it still says it is mostly unwritten. Make it ready: how to get
>     help (**Michael: by email, michael.shafer@nau.edu**, put on the page by `/w-38`), what to include in a report, and links to the guide's
>     troubleshooting pages. No promise the code does not keep.
>
> ### `/w-34` — a quick-start guide for getting a project into the field (added 2026-10-01)
>
> **Michael, 2026-10-01:** *"like a quick start guide with links to the other pages for more details but
> still cover all the major steps."* Today the steps are scattered across five guide pages. **Run
> after `/w-32`**, whose new pictures it uses, and before `/w-33`.
>
> **One page, the first in the guide, linked from the front page.** In the order a person does it:
>
> 1. **Create the project.**
> 2. **Add the animals and their tags with Quick add** (the date the tags went on; pasting a list).
> 3. **Download offline maps** for the study area.
> 4. **Run the pre-trip checklist.**
> 5. **Invite the crew** (the join code).
> 6. **Take the first bearing.**
>
> **Each step: one or two sentences, one picture where it helps, and a link to the full page.** It
> should read in about two minutes. No step explains what its linked page explains. Read every
> quoted string from the widgets; `check_app_quotes` and `hugo` green.
>
> ### `/w-33` — the whole site says too much, in too many words (added 2026-09-30)
>
> **Michael, 2026-09-30:** most of the site was written by an earlier model and *"needs review.
> Longer isn't better. Efficient clarity is better. Longer is only better if it is clearer. More
> screenshots reduce word count and are more efficient than long prose."* **Run after `/w-32`**, so
> the new pictures exist to lean on, and after task 11.320, whose broken guide quotes this task fixes.
>
> **Every page, including the front page and How it works; not the draft theory page from `/w-31`**,
> which Michael is reviewing. For each page:
> - **Lead with what the reader needs to do.** Cut history, internal reasons, repeated warnings and
>   anything the app itself already says on screen.
> - **Where a picture shows it, let the picture carry it** and cut the sentences it replaces.
>   Capturing a new picture is allowed; list each one in the report.
> - **Keep every fact a reader acts on.** Shorter must not become vaguer.
> - **Fix every quote task 11.320 broke**, reading the new wording from the widgets.
>   `check_app_quotes` lists 13 (task 11.320's comms entry names each one). **That is not the whole
>   list:** the guide also *describes* screens whose wording changed without quoting it: the Sync
>   Status held-record cards, the delete and leave dialogs on Projects, the Server Connection
>   sign-out dialogs, and the tag-copy (i). Read each against the app.
> - **Tasks 11.321 and 11.322 changed how tags reach a project and an animal.** `managing-your-tags.md`
>   and `recording-a-bearing.md` should describe the grouped Tag Library and its search, dragging a
>   tag onto a project, the one-step *Link a tag* (with its date), and Quick add. The copy lists are in
>   their `TASK_COMMS.md` entries.
>
> **Report a before/after word count per page**, and the three passages you cut most, so Michael can
> judge the style from a sample. `check_app_quotes` and `hugo` must end green.
>
> ### `/w-32` — the pictures the overnight tasks asked for, and a first short video (added 2026-09-30)
>
> **Michael, 2026-09-30: take them all**, plus *Take on map*, which he singled out after reading the
> built site. **Run after tasks 11.319 and 11.320**, because both change what these screens look like
> and say.
>
> **Nobody needs to run a server or sign in.** The harness drives the app against its own in-memory
> fake server (`joined.dart`, `FakeSyncTransport`), with a signed-in session supplied the same way.
> **If the fake cannot yet produce a state** (a scheduled deletion, the countdown, *Project deleted*,
> the deleted-projects section, or a restore), **the planning session grants a narrow exception**:
> add only what that state needs to the fake under `test/`, run the full `flutter test` afterwards,
> and say exactly what changed. If that is more than a small addition, stop and report instead.
>
> **The list, from the `/w-27`, `/w-28` and `/w-29` comms entries:**
> - **Take on map:** the Record screen with the map button; the map before a sweep, with earlier
>   bearings; after release, with Cancel/Retake/Confirm. **A simulator has no compass**, and the
>   button hides without one, so override the compass providers in the harness with a fixed heading
>   and a scripted sweep.
> - **Deleting a project:** the first *Delete from server…* dialog; a Projects row mid-countdown;
>   *Project deleted* on Sync Status; the *Deleted from your devices, still on the server* section with
>   Restore.
> - **Members on the More screen**, beside Animals.
> - **Existing pictures to place:** `checklist` and `joined-sync-indicator` on the front-page and
>   how-it-works pages, where they back a claim.
>
> Add each to its page, and remove `/w-29`'s "no picture of it in this guide yet" sentence.
>
> **From task 11.319 (2026-09-30):**
> - The map labels now begin *Estimate ·* and *Truth ·*, and Position Estimation lost its white card
>   behind the map-type switch, so those pictures change. `truth-points.md` says a truth point is
>   drawn "with the collar's name and frequency beside it"; say the label starts with *Truth*.
> - **Harness:** after the Map tab opens with a GPS fix, the first frame is drawn at the opening
>   zoom and the camera then moves, so wait for the camera to settle before tapping a marker. The
>   `truth-point-panel` readiness check finds the card by its title as text; make it find the card
>   itself, so a marker label can never satisfy it.
> - **The map-type switch is not to be changed** (`CLAUDE.md`, "Michael's standing design
>   decisions").
> - **Print "picture N of M" as the capture run goes**, so Michael can see how far it has got.
> - **From task 11.320:** pictures of screens whose text changed are stale too; re-shoot any picture
>   on the list that shows changed wording.
> - **From tasks 11.321 and 11.322:** the `tags` and `project-tags` pictures changed (project
>   headings, drag handles, a search box), Animals gained *Quick add*, and *Link a tag* gained a
>   picker. **Add a picture of Quick add's table and of the link picker.** Run after 11.322.
>   11.322 added the Tag Library's search box and a "Tag went on" date card to the link
>   confirmation; include the card in the link picture.
>
> **A first short video, as a pilot.** Record one clip, 10–20 seconds, of a *Take on map* sweep
> (`xcrun simctl io <device> recordVideo` while the harness drives the scripted sweep). Muted, looping,
> with a still first frame for readers who do not play it, under 2 MB, and captioned like a picture.
> **Say how it would be regenerated when the screen changes**, since a video nobody can regenerate
> rots like a hand-taken screenshot. **Ask Michael before committing it**; the pictures do not wait
> for that answer.
>
> ### `/w-31` — the guide never explains the Position screen, or how its estimate is calculated (added 2026-09-30)
>
> **Michael, 2026-09-29:** a theory section on the position estimation method, *"with the
> mathematics and the associated citation"*. The guide has **no page on the Position screen at
> all**; `how-it-works.md` (from `/w-28`) mentions the estimate in two sentences. **Run after task
> 11.319.**
>
> **Two pages in `website/content/docs/`, linked from each other and from `how-it-works.md`:**
>
> 1. **Estimating a position (how-to).** Choosing and unticking bearings; what each caution means
>    (read every caution string from the code); reading the ellipse; *SAVE POSITION*; the
>    intersections layer, if it is user-visible.
> 2. **How the estimate is calculated (theory).** **Michael's rulings: full equations, plain
>    English first.** Each idea in words, then its equation, with every symbol defined. The method
>    is **Lenth, R. V. (1981). On finding the source of a signal. *Technometrics* 23(2): 149–154.**
>    Cover:
>    - the model and its assumptions (a stationary animal, independent unbiased errors, von Mises
>      bearing error, a small area treated as flat, as `coordinate_projection.dart` does);
>    - the maximum-likelihood estimate and its iterative solution (Eq. 2.6);
>    - the concentration estimate;
>    - the covariance and the confidence ellipse (Eqs. 2.7–2.9), including the confidence level the
>      app scales the ellipse to;
>    - why not the mean of the intersections (Lenth §1; `bearing_intersections.dart`);
>    - when it fails (near-parallel bearings, the high-GDOP flag, time spread);
>    - a ready-to-use sentence for a methods section, with the citation;
>    - **a validation section** (Michael, 2026-10-01). `test/localization/lenth_mle_test.dart` reproduces
>      Lenth's own worked example: the seven clean bearings of Tables 1 and 2 (the published MLE
>      (7.23, 1.98), its standard errors and correlation, and the iteration count), and the same data
>      with the westerly reflection added, which pulls the estimate to (5.87, 1.13). **A short table:
>      the published value, TriTrack's value, and the difference, with TriTrack's numbers read from
>      what the test computes, not from the paper.** Use the reflected-bearing case to show why a
>      doubtful bearing is worth unticking. Say that the test runs on every code change.
>
> **The rule that matters most: every equation describes what the code computes**, read from
> `lib/localization/lenth_mle.dart` and its neighbors, **not copied from the paper.** Where the app
> departs from Lenth, say so. For example, the code notes that it inverts the von Mises function
> for κ directly where the paper approximates (Eq. 2.10). Every number on the page (confidence
> level, thresholds) is read from the code, with the file named in a comment in the page source.
>
> **Math on the page:** find out whether the site can render equations. If it cannot, add the
> smallest thing that works, **self-hosted, not from a third-party CDN**, and say what it costs.
>
> **Michael reviews the theory page before it is published.** Build it, run `hugo` and
> `check_app_quotes`, commit it **as a draft** (Hugo's `draft: true`), and close `Partial`, held at
> his review. **Stop there.**
>
> **Two small things folded in:** the one sentence in `sync.md` about *Project deleted* being red
> (task 11.319 item 3 makes it gray; read the widget), and `hugo.toml`'s comment that still says
> "six-page site".
>
> ### `/w-30` — the map pictures hide the bearings they are meant to show (added 2026-09-29)
>
> **Michael, reading the guide:** some of the bearings on the map pictures *"weren't really visible.
> They were behind some of the map display buttons."* **The planning session looked at the iPhone
> 6.1 shots and agrees.** Three things, seen in the committed pictures:
>
> 1. **The camera is framed on the person's own position, at about 200 m, and the day's bearings
>    are somewhere else.** So in `map`, `truth-point-panel` and `joined-sync-indicator` the bearings
>    appear only as fragments at the edges: one under the layers and ruler buttons at top right,
>    one under the **+** button at bottom right. In `bearing-selected` the other bearings are cut off
>    at the left edge and under the panel.
> 2. **The purple "visible from here" overlay (the viewshed) covers most of the map** and competes
>    with the bearings in every one of those shots.
> 3. **Two identical *"Sage · 150.284 MHz"* labels overlap** just below the position dot (a square
>    marker and a round one). Say what the two markers are; if the app draws them that way, report it
>    for the programming lane rather than hiding it in the picture.
>
> **The fix is framing, measured, not a guess.** Frame each map shot so the day's bearings and
> their crossing sit in the clear middle: fit the camera to the seeded bearings with padding taken
> from the on-screen controls' measured positions (the map-type switch at top, the button column at
> right, the **+**, attribution and any panel at bottom), the way the app itself measures its bottom
> edge (task 11.126). **Decide per shot whether the viewshed belongs in it**: keep it where the
> viewshed is the subject, and leave it out where bearings are. **Find every Map-tab shot from the
> routes in `integration_test/screenshots/shots.dart`**, not from the names above, which are the ones
> the planning session happened to open. Re-shoot at all three device sizes, **look at every new
> picture before committing it**, and update any caption that describes what is in the frame.
> **Ask before starting the capture run**; it needs the simulators and takes a while.
>
> ### `/w-29` — the guide has never heard of *Take on map* (added 2026-09-29)
>
> **Tasks 11.315 and 11.317 added a way to take a range bearing on a map**, watching the wedge cross
> the day's earlier bearings on the same collar while sweeping. It is the feature Michael built
> after a day on a trail, and the Record screen's guide page does not mention it. **Run after task
> 11.317**, which changes the screen's top line and adds the map type. Write it on the Record page,
> beside RANGE: what it is for (seeing the crossing before you commit), the two orientations,
> Confirm/Retake/Cancel, and that Confirm fills the form and Save still saves. Read every string
> from the widgets; the copy lists are under 11.315 and 11.317 in `TASK_COMMS.md`. **Ask before any
> screenshot.** **11.317 is done (2026-09-29):** the "Bright… Faint…" card is gone (do not describe
> it), the map-type switch is on the screen, and it shares its setting with the Map tab.
>
> ### `/w-28` — the front page still says "under construction", and it is the only page most people will read (added 2026-09-21)
>
> **Michael, 2026-09-21, asked for the audience in his own words:** *"The site is for wildlife
> professional to show them why they'd want to use it and how."* **That is the brief. Everything
> below serves it.**
>
> **This is not a new site.** `content/_index.md` currently says *"This site is under
> construction"*, so the placeholder for this work is already in the tree, and the layouts, the
> menu, the screenshot harness, the `{{< app >}}` quote checker, the diagram pipeline and the
> publish workflow all exist. **Use every one of them.** A marketing page that bypasses
> `check_app_quotes` is a page that can claim things the app does not do, which is the failure this
> lane has an instrument for.
>
> **The hard constraint, and it outranks everything else on this page: there is nothing to
> download.** The app is not distributed, there is no App Store listing, no TestFlight link, no
> APK. **A page that implies somebody can go and get it today is lying to the exact reader it is
> written for**, and it is the easiest lie to write by accident — every convention of this kind of
> page ends in a download button. **Decide what the page asks the reader to do instead**, and make
> it something that is actually true on 2026-09-21. "Get in touch" is honest. "Download" is not.
>
> **The second constraint: do not invent an organization.** This is one person and a lab. No "our
> team", no "we built", no testimonials, no user counts, no logos. **Nothing that would be a
> fabricated endorsement** if a reader took it at face value.
>
> **Where the content comes from, and the warning attached to it.** The planning session drafted
> five pain points on 2026-09-21 (bearings transcribed from paper; no fix until you are back at the
> truck; no cell service; several people producing several datasets; which collar is on which animal
> at which frequency). **They are a starting point and one of them is not verified** — the claim
> that the app computes a position estimate *in the field, on the spot* was flagged as needing a
> check against the code at the time it was written. **Check all five against `lib/` before any of
> them reaches a page**, and drop or rewrite whatever does not hold. **A pain-point list is a claim
> about the app wearing a claim about the reader's life.**
>
> **How many pages is the task's call.** The obvious shape is a front page that answers *why*, and
> one page that answers *how* by walking the field workflow, with the guide behind them for detail.
> **Do not build a page per feature** — this is a six-page site by design (`hugo.toml` says so about
> taxonomies) and a feature grid is furniture.
>
> **Screenshots: the harness already photographs real screens at three phone sizes.** Use them.
> **Do not mock anything up** — a drawn screen that does not match the app is the same defect as a
> stale quote, with no checker behind it.
>
> **Remember the site is public and built from a private repository.** `hugo.toml` says nothing here
> should render a path, a hostname or a name not intended to be public. A page written to persuade
> is a page more likely to reach for a detail that should stay in.
>
> ### `/w-27` — a project can now be destroyed on the server, and the guide has never said so (added 2026-09-21)
>
> **Task 11.290 landed 2026-09-20 and it is the largest user-visible change since the guide was
> written.** An owner can schedule a project's destruction on the server, every member watches the
> countdown and can export before it arrives, and a phone that was offline across it keeps every
> record and is told why. **None of that is in the guide.**
>
> **Two pages, and they are different jobs.** `projects-members-and-roles.md` gains the **act**: who
> may do it, that it destroys every member's records and not only the owner's, the grace period,
> cancel, and *Delete immediately*. `sync.md` gains the **state on the other side**: what a phone
> shows when a project it still holds was destroyed while it was away, that nothing local is lost,
> and that export is the way out.
>
> **The one sentence to get exactly right, because the app is careful about it and one word in the
> guide can undo that care:** the second dialog says the records go *“out of the server's backups
> within 30 days”*, and **a test asserts the word “permanent” does not appear anywhere in it.** The
> guide must not supply it. **Nothing here is permanent on a human timescale**, and writing that it
> is makes a promise about backups nobody has checked.
>
> **The copy list is in `TASK_COMMS.md` under task 11.290** — the row sentences, both dialogs, the
> `project_destroyed` sentence, the “Deleted here, not yet on the server” section and the join
> screen's row menu. **All of it is new and nothing the guide already quotes moved.** The renamed
> buttons from Michael's device look — ***Schedule delete*** and ***Delete immediately…*** — are the
> final wording; the *Delete now* in the task's first report is stale.
>
> **Run `check_app_quotes` before you start and expect it to be green.** These pages are additions,
> so **a green run proves nothing about whether the new text quotes the app correctly** — that is
> `/w-10`'s finding for the fourth time in this lane. **Read the strings out of the widgets.**
>
> **Screenshots: ask before building any.** These states need a published project and a running
> server, which this harness has never needed. **A described screen is better than a wrong
> picture**, and a shot has cost twenty-seven minutes here before.
>
> #### An eighth item: a server that was restored or rebuilt (added 2026-09-29)
>
> **Task 11.58 gave the sync status screen a sentence** for a device that finds the server's
> records were replaced (restored from a backup, or rebuilt): the device starts its sync over, and
> nothing is lost. **One short paragraph on `sync.md`**, so a person who sees that sentence can
> find what it means. Read it from the widget; the copy is under task 11.58 in `TASK_COMMS.md`.
>
> #### A seventh item: restoring a deleted project (added 2026-09-27)
>
> **Task 11.302 lets the owner who deleted a project bring it back**, for every member, and cancels
> any scheduled deletion from the server. Write it beside destruction on the Projects page. **Run
> this task after task 11.313**, which moves the restore section from "Join a project" to the
> Projects screen and adds a sentence a member sees when a project is deleted. Read every string
> from the widgets; the copy lists are under tasks 11.302 and 11.313 in `TASK_COMMS.md`.
> **11.313 is done (2026-09-27).** It also put **Members on the More screen**, beside Animals; the
> Projects page should say so. The deleted section is now at the **bottom of Projects**.
>
> #### A second, unrelated item folded in rather than given its own number (added 2026-09-21)
>
> **Task 11.298 added a refusal a person can actually meet while signing in**, and the sign-in
> guidance says nothing about it. A server will not send a code to an address containing accented or
> non-Latin characters, quotes or brackets; it now answers with a sentence saying so, where before it
> claimed the code had been sent and then never sent one.
>
> **One sentence on the sign-in guidance in `joining-a-project.md`** — this server sends only to
> addresses made of plain unaccented letters, digits and ordinary punctuation, and what to do if
> yours is not one.
>
> #### A sixth item: what an old server looks like (added 2026-09-22)
>
> **Task 11.307 gave the app a sentence for "the server does not offer what this app asked for".**
> If the guide ever describes what the join screen shows against an older server, the answer is no
> longer *nothing* — it is **a heading and a sentence with no rows under it**, deliberately, because
> a control the server cannot act on must not appear.
>
> **The sentence names two causes and picks neither**: the server is running an older build, **or**
> something between the phone and the server — a proxy or load balancer — answered in its place.
> **The app genuinely cannot tell**, which 11.307 established from the handshake rather than
> assumed: the only version fact a server sends is a schema pair, and **that pair does not move when
> a route is added.** Do not write the page as though "old server" is the answer.
>
> **Read it out of `sync_transport.dart`'s remedy table**, not from here.
>
> #### A fifth item, and this one has its wording already (added 2026-09-22)
>
> **`sync.md`'s amber paragraph is stale, and it is stale in the exact way task 11.306 just fixed in
> the app.** It currently says amber is *"usually the same thing as above, but this device cannot
> confirm it… If you expected to still be on the project, ask an owner"* — **which is the guessing
> wording the app no longer uses.** A person on a shared phone reading that page is told their
> colleague's project is probably theirs to ask about.
>
> **The app's finished sentence, which the page should agree with:** the server is refusing this
> device access to this project; that happens when an owner has removed you from it, **and it also
> happens if this device is signed in to an account that was never on this project** — either way
> the update that would tell them apart is the thing being refused; if you expected to still be on
> it, ask an owner; **if it is not your project, open one of your own**; nothing on the device has
> been changed or lost.
>
> **Read it out of `sync_status_screen.dart`'s `_advice` rather than out of this plan**, which is a
> copy and will go stale the way the page did.
>
> #### A third item, from task 11.292 (added 2026-09-21)
>
> **The join screen gained a section** — *Deleted from your devices, still on the server* — listing
> projects the owner deleted in the app that the server still holds, with the same *Delete from
> server…* dialogs. The Projects page should cover it while it is writing up destruction: **a reader
> meeting "deleted" in two senses on two screens is the confusion worth heading off.** The copy
> list is in `TASK_COMMS.md` under task 11.292; all of it is new.
>
> **The sentence to get right:** deleting a project in the app and deleting it from the server are
> two different acts, and **the first no longer means the second**. Somebody who has only done the
> first still has every record sitting on the server, hidden from everybody. That is the whole
> reason the section exists.
>
> **Two things not to get wrong.** The app's sentence is new copy in `server_config_screen.dart`
> (`serverAnsweredWithErrorMessage`) — **read it from the widget, not from the comms entry.** And
> **do not write that the address is invalid**: it is a perfectly valid address that *this server's
> mail path* will not carry. That is a different claim, it is the true one, and it is the one that
> does not insult somebody about their own name.
>
> ### What is left in this lane
>
> **`/w-13` — Done 2026-09-18** (commit `bea9c01`). `More → Tags` has its own baseline
> (`project-tags`), the stale `project-setup-tags` is retired on all three profiles, and two captures
> task 11.245 had quietly broken are fixed. Its three original items needed no new work and were
> **confirmed by running the harness rather than assumed**. It found one thing outside its scope:
> **task 11.280**, the Sync Status screen taking over twenty seconds to say *“you're not on this
> project”* — three profiles, two runs, reproduced before any edit.
>
> **`/w-20` — Done 2026-09-18** (commit `b4b56a7`). The tags page shows `More → Tags` again, and the
> map's 113-second terrain wait is **explained rather than merely measured**: 72 DEM tiles become
> **380 terrarium-tile requests of which only 143 are distinct** — 62.4% of a cold-cache map load is
> the same run re-downloading files it already has, which is **44–47% of the 113 s** and is paid by
> every field device, not just this harness. **Filed as task 11.281.** The 180 s ceiling stays: it is
> a stated judgement call in `readiness.dart`, disclosed rather than adjusted.
>
> **`/w-21` — Done 2026-09-18** (commit `6cc4b14`). Three diagrams, **Graphviz `.dot` source in
> `website/diagrams/`, rendered at build time, the SVG deliberately not committed** — one copy cannot
> go stale, and a `dot` call costs under a second where a screenshot costs twenty-seven minutes.
> Mermaid was rejected because it renders in the reader's browser. **All three pages got longer**, and
> the task said so with a table: two of the diagrams explain something the pages had never explained
> at all. **That is the right outcome and my acceptance criterion was wrong** — see `CLAUDE.md` on
> criteria that assume a result. It also found the Tag Library form description naming two fields
> removed at schema v17; that sweep is folded into `/w-22`.
>
> **`/w-22` — Done 2026-09-18** (commit `e060ace`). **Em dashes 153 → 4**, and all four survivors are
> inside `{{< app >}}` quotes of literal app copy, so removing them would mean lying about what the
> app says. Sentences over 35 words 76 → 65. **Word count barely moved (11,333 → 11,187): it was a
> substitution pass, not a cut**, which is the honest description of it. `rather than` came in at 11%
> against a two-thirds target — **the task read all 44 and kept the ones that are real mechanism
> distinctions**, which the brief's own “do not chase the numbers into bad prose” told it to do. Its
> screen-description sweep found and fixed one stale claim (the Record screen's quick-add asks for an
> animal name too, since task 11.249) and confirmed seven others against the widgets.
>
> **`/w-23` — Done 2026-09-18** (commit `2186126`). **Sixteen rows checked against the code,
> sixteen correct**, including a re-check of the three `/w-22` had done rather than trusting them
> secondhand. `PERMISSIONS_MATRIX.md` §4.2 verified as a by-product and found clean. Nothing filed.
>
> **`/w-24` — Done 2026-09-18.** `check_app_quotes` green (the one line 11.283 made stale, fixed).
> **48 word-level American-spelling fixes** across 9 pages, including one beyond the ~25 estimate
> (`metres` → `meters` in the guide's own prose) and a code-stream finding that `metres` survives as
> a literal sentence — not just an identifier — in three more places in `lib/`. The five dated
> "used to be" sentences are gone, each rewritten to keep its present-tense fact where it had one;
> two more of the same shape were found and fixed while reading the touched pages. Site builds.
> Full report in `WEBSITE_COMMS.md`.
>
> **`/w-25` — where a collar lives, and what is on the phone versus the server.** Michael asked for
> these 2026-09-18. The first is **the idea that has cost this project the most**: the Tag Library is
> device-wide, adding a tag to a project makes a *copy*, and editing the library entry does not reach
> that copy without a deliberate push. **The picture has to make the copy visible as a copy.** The
> second carries the two facts people get wrong: the app is complete with no server at all, and
> everything is recorded on the device first. **How many diagrams it needs is the task's call, not
> the brief's.**
>
> **Why a new number rather than re-running `/w-10`.** Re-opening a closed task under its old number
> is what made `command_file_staleness_test.dart` go red on 2026-09-18 and forced `/w-13` to commit
> through the pre-commit escape hatch. **A closed website task's number is closed.** Work it was
> owed comes back as a new number carrying that history — see `CLAUDE.md`.
>
> ### Two things to know rather than fix
>
> **The 6.1-inch bearing-drag pictures are one zoom level further out** than the other two profiles',
> because at the default zoom that screen has no bearing tip on the pane. **Nothing is wrong** — but
> **if the guide ever shows two profiles' drag pictures side by side they will not match.**
>
> **The focused notes box cannot be photographed on this harness, and the planning session was wrong
> to say otherwise.** It wrote on 2026-09-09 that `/w-13`'s fix had made the shot achievable. It had
> not: **`/w-13` removed the keyboard by unfocusing at the shutter, which is the right fix for a
> screen with nothing focused and no fix at all for a screen whose subject is a focused field.**
> `/w-10` then measured three separate mechanisms and refuted all three — keeping focus while hiding
> the keyboard drops the focus; writing off the simulator's hardware keyboard yields inset 0; so does
> a cold boot. **And the picture without a keyboard is not the picture anyway** — the box asks for
> eight lines, which is shorter than a screen with no keyboard, so the form does not scroll and a gap
> opens above the save bar: **a state no person ever sees.**
>
> **The correction to carry forward, and it is `/w-10`'s wording:** the next task told this is
> possible **should ask what changed about the keyboard, not about the focus.** The measurements are
> in `shots.dart` and item 11 of the harness README; the guide describes the layout in a sentence and
> says why there is no picture.
>
> ### `/w-17` — the switch the phone already has (added 2026-09-10)
>
> **One page, and it is the whole mitigation for a risk this project has now accepted on purpose.**
> TriTrack's records are in the phone's automatic cloud backup on both platforms, deliberately (task
> 11.215), because a phone lost in the field costs a team more than a cloud account does. **But a
> project working with a species that cannot afford a location leak has to be told two things nothing
> currently tells them:** that the records are in that backup and that Apple — and probably Google —
> can read it, and **that they can switch it off for TriTrack alone in the phone's own settings.**
>
> **Michael confirmed the iPhone switch on his own phone.** **Android's began rolling out in June
> 2026 and has not reached every handset** — seen on Pixel, not on Samsung — **and the page must say
> so**, or somebody who cannot find it will think they did it wrong.
>
> **The page informs a decision; it does not make one.** Most projects should leave backup on, and the
> page says what turning it off costs: records that have not reached the server are then on that phone
> and nowhere else.

> ### `/w-18` — the tag library, and a dialog that is gone (added 2026-09-10)
>
> **Task 11.219 changed what a tag *is*.** A project's tags are now that project's own copies; the Tag
> Database screen is a **library** belonging to the device rather than to any project; **"Link existing
> tag" no longer exists**; and Project Setup gained *"Copy from library"*, *"+ New tag"* and an empty
> state. The tag form now says how many of your projects hold a collar — **never which ones.**
>
> **The quoted-copy check passed and that proves nothing here.** No quote drifted; **a description can
> go false while every quote stays green**, which is exactly what `/w-10` found a week earlier. **Read
> the guide against the code.**
>
> **The two things to get right:** say plainly that a project's tag is a **copy, in both directions** —
> the confusion that will happen is somebody editing their library and expecting the project to follow
> — and **do not promise that editing one project's collar updates another.** It does not, on purpose.

> ### `/w-19` — the tags guide says a copy is a copy, and that is no longer the whole truth (added 2026-09-14)

>
> **One page: `website/content/docs/managing-your-tags.md`. Four of its quotes are red and that is
> the small half of this.**
>
> **The big half is a claim the checker cannot see.** The section headed *"The one thing to get
> right: a copy is a copy"* argues that *"one project correcting a typo in a collar's frequency
> cannot silently rewrite what another project's bearings were taken against"* — **and task 11.250
> built the route that does exactly that, on request.** The word that saves the sentence is
> *silently*, which is doing more work than a reader will give it. **This is `/w-10`'s and `/w-18`'s
> finding for the third time: a description can go false while every quote stays green.** Read the
> page against the code; do not swap the four tokens and call it done.
>
> **What actually changed, on 2026-09-14, across three code tasks:**
>
> - **A library edit can now reach every project that holds a copy — offered, never automatic**
>   (task 11.250). Saving an edit to a library entry some project copied offers *"Apply this to your
>   projects?"*; accepting asks the correction-or-change question **once** and applies the answer to
>   every copy. **Each project still keeps its own history**, which is the sentence the page's whole
>   argument should now rest on: the copies exist so histories stay separate, **not so a typo has to
>   be fixed once per project.**
> - **A project the person does not own is refused and counted, not skipped.** The page should say
>   that a push can update some projects and refuse others, and that it tells you which.
> - **A project's tags are not on Project Setup any more** (task 11.245). They are their own screen,
>   `More → Tags` — a flat list, tag ID with the animal's name beneath it where there is one. **The
>   page currently sends the reader to "Edit project", which is now settings only.**
> - **`"+ New tag"` is gone from that screen.** A tag is created in the library and copied in with
>   **`"Copy from library"`**. The guide's paragraph about creating one straight into a project
>   describes a control that no longer exists.
> - **`"Tag Database Management"` on the More menu is `"Tag Library"`**, and the menu now carries
>   **both** *Tags* and *Tag Library*. **That pair is the thing most worth one clear sentence on this
>   page** — they are two different sets and the names are one word apart.
> - **The always-visible provenance line states the consequence now** — *"Changes here won't reach
>   the N project(s) using this collar"* — instead of the bare fact it used to whisper behind the
>   information icon. **The guide quotes the whisper.**
>
> **Derive every string from `lib/`, not from this list.** The list is a hint and this project has
> been burned by treating one as a set — see the note below on the accumulating-copy list.
>
> **One thing not to write.** Do not describe the push as making the copies "the same" or as
> "syncing" them. It applies one edit on request; the rows stay separate rows, the histories stay
> separate chains, and a teammate's device sees the project's change the ordinary way, by sync.
>
> **WIDENED 2026-09-15 — a second page, and it is a vocabulary change rather than a mechanism
> one.** Task 11.248 swept *"collar"* to *"tag"* across the screens, on Michael's point that **not
> every tag is a collar**, and five more quotes went stale. Four are in `truth-points.md`'s
> *"Recording one"* section — the *"WHAT WAS FOUND"* choices **"Animal + collar"** and **"Collar
> only"**, the explanation *"A collar on its own may have been shed"*, and the delete confirmation's
> *"the animal or collar was actually found"* — and the fifth is the bulk-import sentence on
> `managing-your-tags.md`, where *"a collar you already have"* is now *"a tag you already have"*.
>
> **This is not a find-and-replace, and the guide is allowed to say "collar".** The app now says
> *tag* where it means **the equipment**, because a tag may be a collar, an ear tag or an implant.
> **Where the guide is describing an animal wearing something around its neck, "collar" is still
> the right English word.** Change the quotes, then read the surrounding prose and decide each one;
> a page that says "tag" nine times where it means a physical collar on a kiwi reads like a manual
> written by somebody who has never held one.
>
> **Nine red lines across two pages in total**, four from tasks 11.245 and 11.250 and five from
> 11.248. **They are one task because they are one page-and-a-half of prose**, not because the
> changes are related.

> ### Deployments gained a time, and the guide has never described any of it (added 2026-09-15)
>
> **No quote drifts — every string below is new, so `check_app_quotes` is silent on all of it**,
> which is `/w-10`'s finding yet again and the reason this is written down rather than left for a
> sweep to notice. **This is not `/w-19`'s page**; it belongs with whatever covers animals and
> collars, and the content lane should decide whether it is a section or its own page.
>
> **What a reader now needs to know.** A collar is on an animal **for the whole of the day it comes
> off** — a bearing taken that morning still belongs to that animal. And when a collar moves from one
> animal to another **on the same day**, the app offers a **time**, prefilled with now, so the
> morning's bearings stay with the old animal and the afternoon's go to the new one. **Accepting the
> offered time is the normal thing to do**; it is one tap.
>
> **And the honest part, which is the bit worth writing well:** if the app cannot tell which animal a
> bearing belongs to — a swap where nobody gave a time, dates typed in by hand — **it says so rather
> than guessing.** The Map draws that bearing in a neutral color and the legend reads
> *"Contested: Alpha or Bravo"*; the Log lists it under **both** animals. **A person should be told
> that this is the app declining to invent an answer, not a bug.**
>
> **The new strings**, from task 11.251, all to be re-derived from the code rather than copied from
> here: the link confirmation's *"attached 2026-09-15 14:32"* on a swap (date alone otherwise), its
> **Change time** button, the time picker's heading *"When was the tag swapped?"*, the removal
> picker's *"When did the tag come off? (Cancel for the day only)"*, the legend's *"Contested: …"*
> row, and a deployment row on the animal's screen showing *"2026-09-15 14:32"* when its end has a
> time.

> ### A season starts from the last one — a whole screen the guide has never described (added 2026-09-16)
>
> **Nothing drifts and `check_app_quotes` is silent, because every string is new** — the fourth time
> that has been the reason for an entry here. **Task 11.56 and its addendum.**
>
> **What it is, in the words a biologist would use:** a project's ⋮ menu gains **Start next season**,
> which makes a *new* project carrying last season's **animals, collars, which collar was on which
> animal, the study area and the settings** — and **none of last season's bearings, notes, no-signal
> records, estimates or truth points.** Ponui 2025 and Ponui 2026 are then recorded as one study, so
> an export can say so.
>
> **The two switches, both shown only when there is something to switch:**
> - **the dead animals** — *"Include the N animals recorded as dead"*, and the screen tells you N;
> - **Bring over last known positions**, on by default — each copied animal's **most recent position
>   estimate and most recent truth point**, so the crew knows where to start looking.
>
> **Three things the guide should say plainly, because a person will otherwise meet them as bugs:**
> - **Nobody is on the new season until they join it by its code.** The screen says *"Only you, as
>   owner"*. That is not an oversight; joining is how membership works now.
> - **A carried-over estimate's "N bearings used" counts bearings that live in last season's
>   project**, so tapping it highlights nothing. **This may be changed — check the code before
>   writing the sentence.**
> - **A collar that was on nobody when an estimate was computed carries nothing across.**
>
> **New strings, to be re-derived from the code rather than copied from here:** the menu item
> *Start next season*; the screen title *New season*; the headings *What carries over*, *What stays
> in "…"*, *Who is on it*; the button *Start the season*; and the switch *Bring over last known
> positions* with its count line.

> ### Copy changes accumulating — this is the list to append to
>
> **Tasks 11.202-11.209, all resolved 2026-09-09 — appended 2026-09-10, late, by the planning
> session.** **The arrangement is that the planning session appends here when it resolves a task. It
> did not, eight times running**, and `/w-10` had to derive them from the code instead — which is how
> it found that task 11.205 had made a paragraph of the guide false. **Read this list as a hint and
> derive anyway; `CLAUDE.md` says it is a convenience and this is what leaning on it looks like.**
>
> - **11.202 — the measure tool is gone from the Position screen.** One fewer button on that map. No
>   copy.
> - **11.203 — every segmented control's corner ink is no longer covered by its fill**, on nine
>   controls across six screens; and **the Position map's map-type selector moved behind a layers
>   square**, with the selector now on a card. No copy.
> - **11.204 — the Position screen's bearings panel can be dragged shut** to a gray handle that keeps
>   a caution glyph when there is a caution. Its semantics label changes when collapsed.
> - **11.205 — three colors and one row.** The Position map now draws every ray, marker and ellipse
>   **in the tag's own color** rather than a fixed blue; the tag bar reads in ordinary text with its
>   color dot restored; **the header row's `N=… · Ellipse:… · Span:…` summary is gone entirely**; and
>   **the Position map gained the *"New map tiles are not arriving"* band** it was the only live map
>   in the app to lack. **That last one falsified a guide paragraph and `/w-10` fixed it.**
> - **11.206 — the Main Map's estimate card lost its wedge-suppression sentence** and **the legend
>   card gained a footnote it had never had.**
> - **11.207 — total climb and descent on the elevation profile**, and **the navigation banner is
>   replaced by that panel**. New sentences: *"No elevation data downloaded for this area."*
>   (replacing *"No elevation data for this project."*), *"Waiting for a position fix."*, and *"Part
>   of this line has no elevation data, so the climb and descent are only for the parts that do."*
>   The collapsed bar reads *To &lt;name&gt; · distance · bearing · ↑climb ↓descent*.
> - **11.208 — the climb threshold is 5 m rather than 10 m.** No copy; the numbers a person reads
>   change.
> - **11.209 — a share icon on the map's selection card**, offering *Copy coordinates*, *Copy for
>   TriTrack*, *Share…* (share sheet, text and a GPX file) and *Open in Maps*. **New menu strings and
>   new shared text.** A bearing's map pin is the observer's position and is labeled as such.
>
> **Task 11.201, 2026-09-08 — eight more screens, color only.** Position, Record, Sync Status, the
> Main Map (failed-estimate banner and the Layers & Filters drag handle), Server settings, Profile,
> Tag database, and the More screen's cloud-backup notice. **No copy changed** — `check_app_quotes`
> passes with 163 quotes intact. **Baseline refresh, not a guide edit.**
>
> > **Task 11.200, 2026-09-08 — no words changed, and every screen's appearance did.** The theme never
> passed `onSurfaceVariant`, so **81 call sites across 20 files that asked for a muted color were
> getting full-strength body text.** Defining it moved secondary text, labels, hints and dimmed
> states **everywhere at once**. **Nothing to quote — every baseline on every profile is stale.**
> **Nothing was accepted**; the harness ran without `--accept`.
>
> **Task 11.199, 2026-09-08 — four screens print words where they printed database tokens.**
> **Nothing about what is stored, exported or synced changed** — only what is printed. **The guide
> quotes none of these** (`check_app_quotes` passes), **but four baselines will move and nobody has
> photographed them yet**, because that window could not run the harness.
> - **Paste (shared observation) preview card:** `Type: directional` → **`Type: Bearing`** (also
>   `Omni`, `Note`). `Signal: regular_pulse · medium · ✓ Good` → **`Signal: medium · ✓ Good`** — the
>   mode token is off that line entirely. **And a new line appears only when the payload carries no
>   mode name:** *"The record's older signal field says Normal."*
> - **Tag details, read-only view, and the status wheel:** `Recovered` / `Lost` / `Malfunction` /
>   `Active` instead of the lower-cased stored token.
> - **Project Setup**, tag list subtitle: `· lost` → **`· Lost`**.
> - **Log screen**, supersede picker rows: `omnidirectional` → **`Omni`**.
> - **Point at `lib/core/format/`; do not copy the words.**
>
> **Task 11.197 and its follow-ups, 2026-09-07 — ten changes, and this is the big one.**
> **Quote the files, not this list** — `lib/features/observations/screens/observation_logging_screen.dart`
> and `lib/widgets/segmented_toggle.dart`.
> - **Three headings gone from the Record screen:** *RECORD TYPE*, *TAG*, *BEARING*. **Still spoken
>   by a screen reader.**
> - **Three wheel headings shortened:** *BEARING QUALITY* → *QUALITY*, *PULSE MODE* → *MODE*,
>   *SIGNAL STRENGTH* → *STRENGTH*. Full names still spoken.
> - ***Advanced: bearing method, antenna type, receiver gain*** (and its omnidirectional form) → **▸
>   Advanced**. The list survives as a screen-reader label.
> - ***Preview / set position on map*** and ***Adjust position on map*** → one label, **`Preview/Set`**,
>   on the same line as the coordinate.
> - ***Attach to triangulation session*** **no longer exists anywhere in the app.** **Any guide page
>   mentioning triangulation sessions is describing a feature that is gone.**
> - The Irregular/Malfunctioning control is a **checkbox**, not a chip. **The words are unchanged** —
>   a sentence quoting them is still right; a sentence describing *a chip you tap* is not.
> - The record-type picker is **icons**; only the selected type shows its word. **The five words are
>   unchanged in `RecordType.label` and are still what a CSV export holds.**
> - **The record type shown as *Directional* now reads *Bearing*.** The stored value is unchanged, so
>   a sentence about the *data* is still right and one quoting the *button* is not.
> - On a **Note**, the notes box fills the screen above SAVE NOTE. Its hint is unchanged.
> - **The pinned bar's *"Draft autosaves"* line is removed.** The behavior is unchanged; only the
>   sentence is gone. **A page telling somebody the screen says their draft is saved is now wrong.**
>
> **Task 11.195, 2026-09-07 — REVERTED THE SAME DAY. Ignore this paragraph's content.** It said the
> record type and the tag had moved behind a tap. **Michael tested it, rejected it, and task 11.197
> reverted it** — the five-way picker and the tag wheel are back where the guide always said they
> were. **Left in place because this list is append-only**, and corrected here because `/w-15` read
> the live version and had to work out for itself that the premise was gone. *(This is the
> copy-changes-list-is-a-convenience rule paying its own cost: the list said something that had
> stopped being true and nothing went red. Corrected by the planning session 2026-09-07.)*
> - **The screenshot debt it recorded is settled**: `/w-15` accepted 15 of 16 changed images.
>   **`iphone-6.9/position` is the exception** and is `/w-16`'s — see the warning above.

> **Task 11.194, 2026-09-07 — the final strings, superseding 11.193's provisional ones.**
> - The flag reads **"Irregular/Malfunctioning"** everywhere: the Record chip and its screen-reader
>   label, the Position row's warning-triangle label, the paste screen's sentence (*"The sender
>   flagged this signal as Irregular/Malfunctioning — they thought the tag might be faulty."*), and
>   **a new line on the Log row.** `signal_irregular` is unchanged as the column name.
> - The strongest signal strength is **"V. strong"** on the Record wheel and **"very strong"** on the
>   Position and Log rows. **"Extreme" is gone** — it did not match what the CSV export holds.
> - **The Log tab AND the Team tab** both show the flag line; they share one row widget.
> - **Point at `lib/core/format/observation_quality_display.dart`.**
>
> **Tasks 11.193 and the Position-row work, 2026-09-07 — a new control, and a list that stopped
> printing database tokens.**
> - **Record screen:** a chip reading **"Sounded irregular"** with a warning triangle *(renamed to
>   **"Irregular/Malfunctioning"** by `/11-194` — use that)*, sharing a line with the mode line.
> - **CSV export:** a new column **`signal_irregular`**, whose cells are `yes`, `no`, or **empty —
>   and empty is not `no`.** Empty means nobody was asked: every bearing before schema v13, and every
>   note, truth point and no-signal sweep.
> - **Paste screen:** one line, shown only when the payload carries an answer — *"The sender heard
>   this signal as irregular…"* or *"The sender heard nothing wrong with the signal itself."*
> - **Position screen bearing rows:** `good` → **`✓ Good`** (green), `fair` → **`Fair`** (amber),
>   `suspected_bounce` → **`Bounce?`** (red). **Those were raw database tokens on screen, underscore
>   and all, until 2026-09-07.** `very_strong` → `very strong`; the separator is now `·` not `—`; a
>   flagged bearing gains a red warning triangle.
> - **Point at `lib/core/format/observation_quality_display.dart`; do not copy the words.**
> - **Nothing on the site quotes any of these today** — checked for `suspected_bounce`, `very_strong`
>   and `bounce`, all absent — **but the guide's Position page shows a screenshot of exactly this
>   list.**
>
> **Everything above the line here was consumed by `/w-14` on 2026-09-07** and is kept only so a
> reader can see what the repair covered. **New entries go at the top.**
>
> **Task 11.187, 2026-09-07 — the tag's pulse modes, and this was the largest of them.** The Record
> screen's roller heading is **PULSE MODE** where it said *PULSE TYPE* (**this was the failing
> quote, now fixed**), and the word **Regular** has left the app entirely — an old record now reads
> **Normal**. The tag form's *"Pulse rate (bpm, optional)"* field is gone, replaced by a **Pulse
> modes** section with per-mode name and rate fields, an **Add mode** button, a per-mode remove
> button, and a sentence about the storage unit. The paste screen gained a **Pulse mode:** line.
> **Point at `tag_database_screen.dart` and `observation_logging_screen.dart`; do not copy the
> words.** *Captures re-taken.*
>
> **Task 11.188, 2026-09-07 — no words changed, but two pictures did.** The Record screen's
> bearing-quality and signal-strength rollers now put the best answer at the top. *Captures
> re-taken; the drift check could never have seen this.*
>
> **Task 11.184, 2026-09-07 — one new sentence in the Projects screen's row menu.** A non-owner's
> *Publish to server* entry used to be **absent**; it is now shown grayed with a reason beneath it.
> **Point at `lib/features/more/screens/projects_screen.dart`.** *No guide page photographs that
> menu, so nothing was re-taken.*
>
> **Task 11.120, 2026-09-04 — one new sentence on the Offline Data screen (More › Offline Data).**
> It appears on an elevation area's row **only when some of its files cannot be read**, and it names
> an action that needs a connection. **The literal lives in `damagedElevationSentence` in
> `lib/features/more/screens/manage_offline_maps_screen.dart` — point at that function, do not copy
> the words**, per the rule task 11.89 established about a summary becoming the memory.
>
> **The Tag Database screen, 2026-09-06 — three changes, from task 11.178 and two ad hoc notes.**
> The row is now one line, led by whichever field the list is sorted by; everything that used to sit
> on a second line moved to the details page. **The dialog reached from a row is titled "Tag
> details", not "Edit tag".** The row no longer carries the date put on, and no longer prints
> `active`. **A new sort control sits in the app bar.** **Point at
> `lib/features/more/screens/tag_database_screen.dart`; do not copy the words.** *Capture re-taken;
> no guide page uses it today.*
>
> **Task 11.178's sibling, 2026-09-06 — one refusal sentence gained a clause.** A non-owner tapping
> a tag they may not edit now reaches the details page read-only, and the refusal at the top gained
> *"You can still read everything about it below."*
>
> **Task 11.136, 2026-09-04 — four new refusal sentences and their remedies**, in
> `lib/data/sync/held_row_details.dart`: three for a number outside its column's range or not a real
> number, one for a color the app does not recognize. **None of them quotes a limit's number,
> deliberately.** **Point at the file; do not copy the words.**


**Created 2026-08-31.** This is a **second, parallel lane** of work: the public website and
the user documentation. It has its own plan (this file), its own comms file
(`CLAUDE_DOCS/WEBSITE_COMMS.md`), and its own commands (`/w-01`, `/w-02`, …), so that it
can run in a **separate Claude Code window at the same time as the code stream** without
the two colliding.

---

## Why this can run in parallel when nothing else can

The planning session argued against parallel execution for the code queue, and the
argument was: the queue is a dependency chain (each task was discovered by the one before
it), Michael is the single-threaded verifier, and every task writes to the same three
documents.

**The website breaks all three objections at once.** It has no discovery relationship with
the code stream, it needs no hardware test from Michael, and under the rules below it
shares no files. **It is the only genuinely disjoint workstream on this project.**

## The rules that keep it disjoint — these are not guidelines

1. **A content task touches only `website/`.** Never `lib/`, never `server/`, never
   `packages/`, never `scripts/`, never `CLAUDE_DOCS/` — with exactly one exception, the
   screenshot harness under `integration_test/screenshots/`, which is named in `/w-02` and
   nowhere else.
2. **A content task writes its report to `CLAUDE_DOCS/WEBSITE_COMMS.md`**, never to
   `TASK_COMMS.md`.
3. **A content task makes no edits to `DEVELOPMENT_PLAN.md`.** If it finds something the
   app should change, it **writes the finding into its comms entry** and the planning
   session turns it into a numbered code task. **It does not fix the app.**
4. **Every content task writes an entry, including one with nothing to ask.** Same rule as
   the code stream: a missing entry is indistinguishable from a task that had nothing to
   say.

## Named exceptions to rule 1, and how a new one gets made

**Three files outside `website/` belong to this lane. There are no others.**

1. **`integration_test/screenshots/`** — the screenshot harness (`/w-02`).
2. **`.github/workflows/website.yml`** — a check cannot be wired into GitHub Actions from
   inside `website/`.
3. **`.github/workflows/offline-suite.yml`**, for the one line that registers a Dart package
   this lane added (`/w-04`).

**The general rule, arrived at twice in one day from opposite directions:
whoever creates the obligation discharges it.** Both incidents resolved to the same
sentence, so it is written once here rather than patched case by case:

- A content task added a Dart package and did not register it in the code lane's workflow.
  **Both lanes saw the red, both correctly declined to edit across the boundary, and each
  assumed the other owned it.**
- A code task (11.93) added two columns that made **this lane's seed fixture wrong**, and
  updated the six lines of `integration_test/screenshots/seed.dart` that fixed it — while
  `/w-05` was working in that directory. **It disclosed the edit in its comms entry and
  nothing collided.**

**The second one was the right call and the rule is amended to say so, rather than the task
being told off for it.** Had 11.93 not touched the seed, the harness would have gone on
photographing a truth point reading *"not recorded"* — **an image of a state the app no
longer produces**, which is copy-describing-a-mechanism-the-code-does-not-have in picture
form. **The lane boundary is about ownership of consequences, not about directories.**

> **So: a code task may update `integration_test/screenshots/`'s seed data when it adds or
> changes a field the fixture sets, and must say so in its comms entry — the same
> obligation it already has for user-visible copy. It may not change the harness, the
> capture list, the comparison, or any image.**

**And the narrower rule that produced the first incident still stands: a content task that
adds a Dart package owns the workflow line that package requires.** `analyzed_packages_test.dart`
requires every non-root package to appear in the offline suite's workflow. This lane
committed `website/tools/pubspec.yaml`, did not add the line, and **the entire offline suite
went red** — which by task 11.68's rule means it could no longer report any real failure.

**What actually went wrong is worth more than the fix.** Both lanes saw the red, both
correctly declined to edit across the boundary, and **each assumed the other owned it.** A
rule that leaves ownership unstated does not produce caution; it produces a gap that looks
like caution from both sides. **So: whoever creates the thing owns its registration**, and a
new exception is made the same way this one was — named here, with the reason, before it is
used.

## Two rules that turned out to be about the shared working tree, not the lanes

**The `/w-02` prohibition on the phone `map` and `position` images is LIFTED, 2026-08-31.**
Task 11.95 fixed the 61-pixel credit overflow; `/w-03` regenerated both, looked at the
diffs, and accepted them. **The old phone image carried yellow-and-black stripes reading
"OVERFLOWED BY 61 PIXELS"; the new one has the credit wrapped onto two lines inside its own
box.** A rule left standing after the thing it forbade stopped existing is the same defect
this project keeps finding, so it is retired here rather than left to be obeyed out of
habit.

**And the two lanes share one `build/` directory, which no rule anticipated.** A code task
verifying a map fix by running the screenshot harness is a **reasonable** thing to want to
do, and it silently destroyed a content run's output. **The enforcement belongs in
`regenerate.sh`, not here** — a rule telling people not to run a script cannot compete with
a good reason to run it.

**BUILT AND WATCHED, 2026-08-31 (`/w-06`).** `regenerate.sh` takes an atomic `mkdir` lock
before it deletes anything; a second run refuses, names the process holding the lock and when
that run began, and **deletes nothing**. A lock whose owner is no longer alive is reclaimed
loudly, because a crashed run leaving the harness permanently unusable would be a worse
failure than the one being prevented. **And the exit-code confusion that made the original
incident invisible is closed twice over:** any filesystem error in the review is exit 2 with
a sentence naming the file, and `regenerate.sh` now reads **only 0, 1 and 2 as a verdict** —
anything else is the review crashing rather than an opinion about the images. **That second
fix would have caught the original incident on its own.** Both watched on real runs.

## User-visible copy the guide must not quote from memory

> **A standing rule for this section, learned by it on 2026-09-02, one day after it was
> written.** Task 11.122 added a summary here of the three new identity-screen errors,
> **quoting one of them.** Task 11.89 split that message in two the next day, and the quote
> went stale. **A section that exists to stop the guide quoting copy from memory must not
> itself become the memory.** So: entries here name **which file holds the copy and what
> shape it has**, and the content lane reads the file. Where a quote is unavoidable, it is
> marked as an example and dated.

**Added 2026-09-13 by task 11.240 — the app now tracks animals, and the export has a second file.**
**This is a change to what the guide is *about*, not a string swap.** A collar is now a transmitter
worn by an animal; the animal is the thing being tracked, and it survives a re-collaring. The export
writes **`tags.csv` and `individuals.csv`**, and the receipt reads *"… N tags and N animals"*.

> **Do not write the animals page from this paragraph.** Task 11.241 builds the screens a person
> actually meets — the animals list, the "these collars are the same animal" merge, the filters —
> and **those words do not exist yet.** Wait for it, then read the screens.
>
> **One sentence the guide may already carry that is now wrong:** anything calling a color the
> *collar's*. **It is the animal's** — change it once and every one of its collars changes with it.

**Added 2026-09-13 by task 11.241 — the animals screens exist now; this is what the guide is about
after 11.240's note above.** Every string below is named by file and shape; open the file.

- **Project Setup's tags section is a list of animals** (`project_setup_screen.dart`,
  `_ProjectTagsSection` / `_AnimalHeaderRow` / `_GroupLabelRow`). An animal row reads name, then
  *status · N collars*; its collars sit under it. Collars that name no animal sit last under a heading
  (one string, `_GroupLabelRow`'s argument) with an **Assign** button, whose picker asks which animal
  wears the collar and offers a new animal named after it. **The old "Tag Database" screen is the
  device's library and has no animals** — do not send readers there for animals.
- **The animal dialog** (`widgets/individual_form.dart`, `IndividualEditDialog`): Name, Status, Sex
  (with a "not recorded" option distinct from "unknown"), Species, Notes, Color, and one sentence
  under the Color heading saying every collar the animal has worn shows it. Read-only for a viewer.
  Status and sex words are `tag_status_labels.dart`'s `individualStatusLabel` / `individualSexLabel`.
- **The merge** (`individual_form.dart`, `mergeConfirmationText`; the dialogs in
  `project_setup_screen.dart`'s `_AnimalHeaderRow._merge`): the button reads *Same animal as…*; a
  picker titled *"<name> is the same animal as…"*; a confirmation titled *"Merge A into B?"* whose body
  is `mergeConfirmationText` — it says what moves, what stays, and what cannot be undone; a snackbar
  after. **The guide should say the direction plainly: you open the duplicate and pick the animal it
  really is; the one you pick survives.** Owner-only, and the two disabled reasons are in
  `_AnimalHeaderRow._mergeDisabledReason`.
- **New tag dialog** gained an *Animal* dropdown (default: a new animal named after the tag) — only
  when the project already has animals.
- **Log filter**: the chip still reads *Tag: All*; the picker is titled *Filter by animal or tag*, with
  ANIMALS then TAGS sections; an animal filter's chip reads *Animal: <name>* (`_SubjectFilter`).
- **Map, Layers & Filters**: the TAGS section groups collars under a per-animal checkbox (tristate);
  collars with no animal follow under *COLLARS WITH NO ANIMAL* (only shown when there are animals too).
- **Record screen**: unchanged unless a collar's animal has a different name, in which case the wheel
  line ends *· <collar> (<animal>)* (`_animalClause`). The guide need not mention it.
- **Data Export**: *Export CSV* now saves **one `.zip`**, named `<project>_csv_<date>.zip`, containing
  `observations.csv`, `non_detections.csv`, `truth_points.csv`, `tags.csv`, `individuals.csv` and
  `deployments.csv` (the optional ones only when there is something in them). *(`deployments.csv` added
  to this line by `/w-35` item 5, from `/w-33`'s finding 4; since then task 11.323 added
  `position_estimates.csv` and task 11.331 added `deployments.csv`'s `time_zone`, `attached_day` and
  `removed_day`.)* **Any sentence in the guide about being asked
  where to save more than one file, or about the CSVs' filenames carrying a date, is now wrong.** The
  receipt snackbar is unchanged. File: `data_export_screen.dart`, `_exportCsv`; the format is
  `data/csv/csv_export_archive.dart`.
- **The library swatch on the Tag Database screen is a seed color** — what the animal will start in
  when the collar is copied into a project — not any project's color (`TagLibraryEntry.colorHex`).

`check_app_quotes` is green.

**Added 2026-09-14 by task 11.244 — Animals is a screen on the More menu now, and linking a collar
is a confirmed, dated act. This supersedes two bullets above.** Every string is named by file and
shape; open the file.

- **More → Animals** (`features/more/screens/animals_screen.dart`). A menu entry between *Project
  Setup / Extent* and *Pre-Trip Checklist*, titled **Animals**. The screen lists the active
  project's animals — swatch, name, *status · N collars* — with an **Add animal** button above.
  **An animal with no collar is an ordinary row**, and the empty state says to add the animals
  first and link a collar to each. A viewer sees the grayed button with the reason under it.
- **An animal's own screen** (`animal_detail_screen.dart`). The fields the dialog already had
  (they are one widget now — `IndividualFields` in `widgets/individual_form.dart`), then a
  **Collars** section listing every collar the animal has worn with its dates, then **Link a tag**,
  **Same animal as…** and **Delete animal**. A collar row reads *On since <date>*, *<date> to
  <date>*, or — for a link nobody dated — *No attached date — this collar is on no bearings*, in
  the error color. Per collar: **Set removed date** and **Remove record**.
- **Linking a collar is confirmed before it is written, and the sentence names a second record**
  (`data/repositories/deployment_linking.dart`, `linkConfirmationText`). The date defaults to
  today, and if the animal is already wearing a collar **that collar is recorded as removed the
  same day**. The confirmation says both, and ends *"That is a change to a record you did not
  open."* **The guide should say why that sentence exists**: silently amending a second record is
  how a field note becomes wrong with nobody making a mistake.
- **The refusal a person will meet** (`deployment_repository.dart`, `OverlappingDeployment.message`):
  *"This animal would be wearing two collars at once…"* / *"This collar would be on two animals at
  once…"*, each ending *"Fix the attached and removed dates so the two deployments do not overlap
  by more than a day."* **It does not fire on the ordinary recapture** — the app closes the old
  collar on the same day, which overlaps by nothing.
- **Remove record is not the same as taking a collar off**, and the confirmation says so. The guide
  should carry that distinction: a **removed date** records that the collar was worn and came off;
  **Remove record** says it was never on this animal. Bearings do not move either way.
- **Delete animal exists now.** Task 11.241 recorded that it deliberately did not; that is
  withdrawn. Its confirmation says the collars go back to being on nobody, that **no bearing
  moves**, and that the animal's own record cannot be recovered.

**Two bullets above are now out of date:**

- ~~*"New tag dialog gained an Animal dropdown"*~~ — **removed by task 11.243.** The new-tag dialog
  creates a collar and says nothing about an animal; linking is its own act on the animal's screen.
- ~~*"The library swatch on the Tag Database screen is a seed color"*~~ — **the swatch is gone**
  (task 11.244), and so is the Color section on that screen's form. A library entry's color was
  the seed for an animal that a copy-into-a-project no longer creates, so nothing read it. **Color
  is chosen on a project's tag, or on the animal**, and it is the animal's either way.

> ~~**The Record screen is unchanged and the guide should not say otherwise.** Michael, 2026-09-14:
> *"It should be the same as it is today."*~~ **Struck the same day — see the next block.** 11.244
> did not change it; **task 11.249 did**, later that afternoon. The fold is still measured at 186
> logical pixels by `record_screen_space_budget_test.dart`.

`check_app_quotes` is green.

**Added 2026-09-14 by task 11.249 — the Record screen's tag wheel changed three times in one
afternoon, and three sentences in the guide are now false.** `check_app_quotes` is green **and that
is the point**: no quoted string moved, so the check could not see this. Every string below is named
by file and shape; open the file.

**What the guide says today and must stop saying:**

- ~~the wheel lists collars *"by frequency, pulse rate and name"*~~ — **pulse rate is off the wheel.**
  Michael: *"Don't need bpm."* It lives on the tag's details, not in a list read while holding an
  antenna.
- ~~the wheel lists *"the tags in this project"*~~ — **it lists the collars that are on an animal
  today**, and only those. A collar with no deployment, or one whose deployment has ended, is not
  offered. The same rule governs the no-signal checklist beside it.
- ~~quick-add adds a tag *"with just a name and a frequency"*~~ — **it asks for three things and
  creates three records.**

**What it should say instead:**

- **The wheel's line is the frequency and the animal's name, in the order of the sort.** By
  frequency it reads `150.325 MHz · Marie`; by animal, `Marie · 150.325 MHz`. **The collar's own
  ID is not on the wheel** — that lives in the Tag Database. The no-signal checklist reads the same
  line, frequency first.
- **A two-icon switch beside the wheel chooses the order** — the Tag Database icon for frequency,
  the Animals icon for animal — and the choice persists across restarts.
- **Only collars on an animal today are offered**, counting the day a collar comes off. **On a
  handover day both collars show, and that is correct**: the old one came off this morning and a
  bearing was taken on it an hour earlier.
- **Quick-add on the Record screen asks for Tag ID, Frequency (MHz) and Animal name, all three
  required**, and its line reads *"Adds the tag to the Tag Database and the animal under Animals,
  wearing it from today."* **This is the one place in the app that creates an animal for you**, and
  the guide should say why: the person is about to record a bearing on that collar, which is already
  a claim that something is wearing it.

**Three other screens still list every active tag and that is deliberate** — the Position screen's
picker, Data Export's filter and the pre-trip checklist. None asks *"what can I hear right now"*;
the checklist counts equipment. **Do not describe them as following the Record screen's rule.**

**Added 2026-09-13 by task 11.239 — one import-report line and two refusals.** The import report
gains *"Tags matched to a collar this project already had: N"* — it appears when an older backup's
collar is recognized as one the project already holds under a different id, which is a **normal,
successful** outcome and should not be described as a problem. The two refusals live in
`project_merger.dart` as `forkedTagArchiveRefusal` and `forkedTagDeviceRefusal`; **open the file, and
note they are refusals of an import, not of a collar.** `check_app_quotes` is green.

> **One string is reachable only in theory and is developer wording**: a backup whose data format
> predates anything the app can read now shows *"Backup schema major v1 predates this app…"* under
> "Invalid backup". **Nobody can hit it today** — every backup ever written is readable — so it is
> left alone. **If that floor is ever raised, this becomes a copy task**, and the sentence a person
> would see is not one written for them.

**Added 2026-09-13 by task 10.87 — the import consent dialog's body is new, and so is how
overwrites are listed.** The dialog now leads with a headline and per-table lines — *"Bearings · 1000
records, 1000 values replaced, 12 records removed: latitude, longitude"* — instead of listing the
first forty and saying *"and 960 more"*, and points at *"Sync Status → Overwritten edits"*. That
screen's description gained *"grouped by the sync or import that did it"*, and it now shows **one
card per import or sync rather than one per record.** New strings: *"N records overwritten"*,
*"Showing the first 10 of N"*, *"Got it — all N"*, *"Showing the first 20 of N records, most recently
refused first."*, *"Show all N"*. `check_app_quotes` is green — nothing the guide quotes went away.

> **One sentence of this is a claim about a first-time import and it is worth reading before quoting
> anything nearby:** *"This project is not on this device yet, so none of its records can be
> overwritten. But the file would change 1 detail this device already holds about 1 person."*
> **People are global; a project's records are not.** A guide sentence that says a first-time import
> changes nothing would be wrong.

**Added 2026-09-13 by task 11.237 — three new sentences and one changed one, and they describe a
behavior the guide has never covered.** Both constants live in
`lib/data/repositories/project_standing.dart`; **open that file rather than quoting from here.** The
projects list now carries *"A copy of someone else's project — read-only on this device until you
join it."*; every attempt to change anything in such a project is refused with one shared sentence
beginning *"You are not on this project, so it cannot be changed on this device."*, which goes on to
name the join-code path; and the Members screen's "Your role" card reads *"Not on this project"* for
a snapshot. **The card's old *"nothing here stops you recording"* still exists** but now appears only
for a project the device genuinely cannot answer for — **so a guide sentence describing when a
reader sees it would be wrong today and was right last week.**

> **The guide has no page about importing somebody else's project**, and this is the first behavior
> that makes one worth considering — a person who receives an archive and finds it read-only will
> look for an explanation, and the app's one sentence is all there is. **Not a decision for the
> content lane alone**: raise it, do not write it.
>
> **One wording trap, recorded because the plan entry says otherwise.** The plan's phrase *"Changes
> here stay on this device"* **was never shipped** — Michael chose to refuse the edit, so no change
> stays anywhere. **If that phrase is quoted anywhere, it is wrong.**

**Added 2026-09-13 by task 11.235 — one new sentence, and it is a fallback rather than a message.**
`kTagFormCouldNotOpenMessage` in `tag_database_screen.dart` is shown as a snackbar when the tag form
cannot be opened. **It deliberately asserts no cause** — it exists so that a tap which fails says
*something* instead of nothing, which is what the + button did until this task. `check_app_quotes` is
green and the guide does not quote it. **If a guide page ever describes it, describe it as the
fallback it is**; a sentence that names a cause it did not measure would be the defect it was written
to end.

**Added 2026-09-13 by the planning session, on `/w-18`'s behalf — what that task changed, since a
content task does not keep this list.** A new page, `managing-your-tags.md`, covering the split task
11.219 made: **this device's own tag library** (the Tag Database screen, which no role governs) and
**each project's own copy** (Project Setup, where the owner-only rule lives). It states, in both
directions, that a project's tag is a copy and that editing one side never reaches the other.
`recording-a-bearing.md`'s two `Irregular/Malfunctioning` quotes are corrected to `Malfunctioning`.
**`check_app_quotes` was green for the entire time the tag split was undocumented** — the same shape
`/w-10` found a week earlier, and the reason that task's first acceptance line is *read the guide
against the code, not against the quote check.*

**Two screenshot notes carried forward.** `tag-database-viewer` is renamed `project-tags-viewer` and
now shoots Project Setup, because the old shot photographed a tag on a screen **that never held it**
— it existed only as the project's copy. And **`log` / `log-supersede` drifted under 0.25% of pixels
on all three profiles for a reason unrelated to tags**; `/w-18` did not investigate and **did not
accept them**, so the committed baseline still matches the live site. **The next content task inherits
that, and should find the cause before accepting** — an unexplained diff accepted once is a baseline
nobody can appeal to afterwards.

**Added 2026-09-12 by task 11.230 — the offline-data screens gained a lot of copy, and none of it
is red.** There is **no offline-data page in the guide today**, so nothing drifted and
`check_app_quotes` is unaffected. Listed so the next content task inherits it: the download sheet's
*Name* field and *Name this area* dialog; the map's area sheet (*Rename*, *Update*, *Delete*, and
*Which area?* when a tap lands in two overlapping areas); the delete confirmation *Delete "X"?* with
its *Frees … on this device / Another … is also covered by "Y" and stays / getting it back means
downloading it again, which needs a connection* sentence and its *Frees nothing on this device*
form; *Updating "X" — fetches whatever is missing and deletes nothing.*; *"X" is already
downloading.*; the list row's *shared with "Y"* line; the STORAGE note beginning *Everything on this
device, including tiles kept from panning the map…*; and download cards now reading *Map tiles ·
Area 1: downloading…*. **Gone:** *Delete this tile area?* and *Frees the storage it uses; it can be
re-downloaded later.* — **the second of those was the sentence that did not mention the neighbor it
was about to damage**, so a guide page quoting it would have been repeating a defect.

> **When an offline-data page is written, open the files.** These strings are assembled from parts
> (an area's name, a size, another area's name), so **quoting one from this list would be quoting a
> template, not a string a person sees.**

**Added 2026-09-12 by task 11.67 — one rename that breaks the guide, and a set of new aerial
strings that do not.**

**THE RENAME IS BLOCKING.** *Irregular/Malfunctioning* is now **Malfunctioning**, on the Record,
Log and Position screens and on the paste screen's sentence about what the sender flagged. It went
through **one constant — open it, do not trust this paragraph**, which is this section's own rule.
`website/content/docs/recording-a-bearing.md` quotes the old wording **twice**, so
`check_app_quotes` is red and **a website build fails until it is fixed**. It is assigned to
`/w-18`. **Re-read the sentences rather than swapping the token:** one of them turns on the
difference between a transmitter misbehaving and a bearing being untrustworthy, and a shorter label
may change how it should read.

**The aerial strings are new, not renamed, and the guide has no page that mentions them** — so
nothing has drifted and nothing is red on their account. They are the *At altitude* checkbox and its
sheet (*Receiver altitude*, *AGL — above ground*, *MSL — above sea level*, *Back on the ground*,
*Set*, four refusal sentences) plus the *"Altitude cleared — was 300 m / Restore"* notice, in
`receiver_altitude_sheet.dart` and the record form. **Gone:** the old *Receiver altitude 300 m above
ground* line and the gauge icon's *Receiver altitude* tooltip — **the icon itself no longer exists**,
so a baseline screenshot showing it is a picture of something removed.

> **Do not write an aerial page to use these.** Michael's standing scope rule is that aerial
> tracking is rare and must not drive the design; a page about it is its own decision, not a
> consequence of the strings existing. **Listed here so the next content task inherits them rather
> than rediscovering them.**

**One export column changed with it:** CSV exports carry `altitude_agl_m` again (task 11.30 had
removed it because nothing could set it). **Zero now means on the ground**, not *nobody could say*.
If the guide describes export columns anywhere, that sentence is now true and was not before.

**Added 2026-09-02 by task 11.124 — four new refusal messages on the sync status screen.**
`held_row_details.dart` gained four messages naming *which* part of a record the server refused.
**The two constants the guide may already quote — `HeldRowDetails.rejectedWithoutADetail` and
`rejectedRemedy` — are unchanged and still reachable**, which was an explicit acceptance
criterion, so a quote of either is still true. **Named, not repeated: open the file.**

**A NEW OBLIGATION ON THIS LANE, added 2026-09-02 — the site is now a compliance surface, not
only a guide.** Task 11.134 set the tile `User-Agent` to
`TriTrack (edu.nau.tritrack; +https://dynamic-and-active-systems-lab.github.io/tritrack-site/)`,
because OpenStreetMap's tile usage policy asks for **a way to reach somebody** and an email
address would go out in the clear on every tile request to three companies. **Michael confirms
the site is live but bare bones.**

> **So the URL resolves, and that is not the same as satisfying the policy.** The page it
> resolves to has to carry **a contact route** — an address, a form, a repository link, anything a
> tile operator with a question can use. **Until it does, the app is publishing a contact that
> cannot be contacted**, which is this project's own class: a remedy nobody has followed, and a
> control nobody has exercised.

**This is the smallest item in the content lane and the only one with a license behind it. Do it
in whichever `/w-` task lands first.**

**Added 2026-09-03 by task 11.142 — the Members screen's four empty-state sentences, and one
caveat on the map.** The "Join code" and "Waiting to join" sections now say why they are empty
instead of showing nothing, and there are **four sentences rather than one** because *no server
configured* reads differently from *the server did not answer*. They live in `noServerSectionText`
in `lib/features/more/screens/project_members_screen.dart`. The map gained `kPartialTerrainCaveat`
in `map_screen.dart`, shown on a snackbar and on the Viewshed switch, when a viewshed was computed
over terrain with gaps — and the legend row then reads *"Viewshed (partial terrain)"*. **Name the
functions and open the files; do not quote them from here.**

**Added 2026-09-02 by task 11.135 — the Offline Data Map's download lines.** The completed
line gained a count of what did not arrive, and a new sentence appears under a download that lost
tiles. The words live in `lib/features/map/services/tile_fetch_health.dart` and `_JobProgressCard`
in `lib/features/more/screens/offline_data_map_screen.dart`. **Named, not quoted — open the
files.** **And one thing the guide must not say:** the Position Estimation screen is now the only
map in the app that stays silent when tiles stop arriving, deliberately and for a measured reason.
**Do not write "every map tells you" anywhere.**

**Added 2026-09-02 by task 11.134 — two new Main Map strings and one line in App Info.** The
map gained a message shown when tiles stop arriving, and the paragraph behind it; **"Powered by
Esri" now appears in App Info and in the map credit's bottom sheet.** Named, not quoted — open
`lib/features/map/screens/map_screen.dart` and the App Info screen. **If the guide shows App
Info, it is a line longer than it was**, so any capture of that screen is stale.

**Added 2026-09-02 by task 11.131 — three new strings on the Main Map, and a gesture the guide
now has to carry alone.** `lib/features/map/screens/map_screen.dart` gained a *Layers & Filters*
action that resets bearing lengths (with a subtitle) and a live readout shown while a bearing's
tip is being dragged. **Named, not quoted, per the rule at the top of this section — open the
file.**

> **The part that matters more than the strings: there is no other way to discover this
> gesture.** Nothing on the map says a bearing can be dragged; **the handle drawn at the tip is
> the whole of the discoverability, and it only appears once a bearing is selected.** That is a
> deliberate choice — the map's space budget forbids permanent onboarding copy — **so the guide
> is carrying more weight here than anywhere else in the app.** A reader who never learns the
> gesture never finds it. Capture the handle, and capture a wedge mid-drag with the readout
> showing.

**Changed 2026-09-01 by Michael's decision on task 11.119's largest finding — the sign-in
screen, three strings.** `EMAIL ME A SIGN-IN CODE` is now `REQUEST A SIGN-IN CODE`; the
check-your-email line and the paste-from-the-email helper both dropped the promise of an email;
and a new sentence after a request explains that delivery depends on how the server is set up.
**Nothing in `website/` quoted any of the three, so the drift check is unaffected — but the
sign-in flow is guide material and the guide must not describe an email arriving.** The reason
is worth carrying into whatever the guide says: **the app cannot know how a code reaches
somebody**, because the server answers identically whether it emailed it, wrote it to a file or
dropped it. **Do not write "check your email" in the guide either.** Guarded by
`test/documentation/sign_in_delivery_vocabulary_test.dart`, which covers `lib/` only — the
guide is this lane's to keep true.

**Added by task 11.122 (2026-09-01) and reshaped by task 11.89 (2026-09-02) — the identity
screens.** Both places a name is typed — identity setup and profile — now show inline errors
for required, too long, and **a refused character**. The refused-character message is **two
messages, not one**, and the split matters to the guide: when the character is **invisible**
the message names its code point and the remedy is to retype rather than paste; when it is
**visible** — a bracket, an at-sign, an emoji — the message **quotes the character and
deliberately does not say "retype it"**, because retyping a bracket somebody typed on purpose
produces the same rejection again. **Read `lib/features/identity/identity_validation.dart`
rather than this paragraph**, per the rule above.

**And the rule behind those errors got stricter on 2026-09-02 (task 11.89), which is guide
content in its own right.** A name is now stated as what it **may** contain — letters, marks,
digits, dashes, spaces, apostrophes, full stops and commas, in every script — rather than as
a list of what it may not. **Brackets, at-signs and emoji are refused**, and Michael accepted
that. If the guide says anything about what a name may be, it should say the allowlist rather
than enumerate exclusions.

**Rewritten by task 11.122, 2026-09-01 — the sync status screen's held-record text for a
rejected record**: it used to say the refusal was *"a fault in
the app or a version mismatch, not something wrong with what you recorded"* and that *"nothing
you can do in the app will change the answer"* — **both false for a refused name**, and both
gone. It now says only what the device knows: the server refused the record, it did not say
which part, here is what to look at, here is how to report it if it stays.

> **Claude Code did not look at `website/` — that is this lane's.** Two things to check rather
> than assume: whether the guide quotes the old rejected-record wording anywhere, and whether
> it describes what happens when a name is refused. **The second is the dangerous one**, because
> a guide can be wrong about that without quoting a single string — the describes-without-quoting
> class again.
>
> **And it will change once more.** Task 11.124 replaces the honest shrug with the specific
> sentence when the server can say which field was refused. **Do not write the guide around
> today's wording as though it were final** — describe the behavior, quote through
> `{{< app "..." >}}`, and 11.124 will move the quote rather than the prose.


**Added by task 11.103, 2026-09-01 — one new sentence on the Main Map**, shown only when there
is no fix, nothing recorded and no project extent: *"TriTrack does not know where you are, and
this project has no recordings or map extent yet. Pan to your study area, or set the project
extent under More › Project."*

> **One thing to check rather than quote: it names "More › Project" as where the extent is
> set.** If the guide calls that path something else, **one of the two is wrong** and the check
> cannot tell you which — this is the describes-without-quoting class the README already names.


**Changed by task 11.110, 2026-08-31 — and this is a moved control, not just moved words.** The
*"tap a ray to include/exclude"* hint **no longer sits permanently on the Position screen's
map**; it is now a footnote inside the legend card, reached from the legend button, reading
*"Tap a ray on the map to include or exclude that bearing."* Also on that screen the basemap
toggle, north arrow, measure and legend buttons are **one row across the top** rather than three
clusters, and **the north arrow appears only when the map is rotated**. On the Record screen the
viewer message moved down beside Save. **11.110 checked `website/` and found nothing quoting the
old wording — but it asked the content lane to confirm rather than take its word**, which is the
right instinct given that a moved control makes prose wrong without making quotes wrong.


**Changed by task 11.109, 2026-08-31, on the Position screen — the controls moved, not just
the words.** "Select all" and "Clear" are now **"All"** and **"None"**; the three sort chips
became a **sort menu button**, and the tooltip *"No GPS fix — distance sort unavailable"* is now
a visible menu entry **"Distance — no GPS fix"**; the amber cautions banner became a
**"⚠ N cautions" button** opening a sheet headed **"Cautions"**. 11.109 grepped `website/` and
**none of these strings is quoted there**, so the drift check should stay green — **but the
screen's controls moved, which is the kind of change that makes a guide's *prose* wrong without
making its quotes wrong.** That is the class `/w-08` named in the README.


**Changed by task 11.92, 2026-08-31.** The map info panel's header for these records is now
**"Truth point · <tag>"** (was "Actual tag location · <tag>"); its Navigate label says
"Truth point"; and the CSV export confirmation names every file written. **None is covered
by a shortcode yet** — 11.92 checked. Quote them through `{{< app "..." >}}` when the guide
reaches them, like everything else.

## The interface between the streams, and it runs the direction you would not expect

**Writing the user guide is the cheapest usability test this project has.** Every place the
guide has to say *"open More, then Join a project, then paste the code, then wait"* is a
place the app is awkward. This project has already produced two findings — 11.60 and 11.83
— that were both *the person is not told what happened to them*, and **a guide-writing pass
would have found 11.83 before Michael's iPhone did.**

So the content stream's most valuable output is not the document. **It is the list of
things that needed three sentences to explain and should not have.** Those go in the comms
file under a heading of their own, and they become code tasks.

---

## Where it lives, and why not a separate repository

**In this repository, under `website/`.** Two reasons, both specific to this project:

1. **Screenshots are claims about what the app looks like**, and a screenshot that has
   drifted from the app is exactly the defect class this project spends its time
   eliminating — copy describing a mechanism the code does not have. In the same
   repository, a check can regenerate them from the app and fail when they drift. Across
   repositories that check is impractical.
2. **The guide will quote strings that live in the Dart source.** Same repository means a
   check can verify a quoted sentence still exists in `lib/`. Different repository means it
   rots silently, and this project has already found four separate cases of user-visible
   copy describing something the code stopped doing.

**The repository stays private and the site is still public.** The site is *built* from the
private repository and deployed to a public host — Cloudflare Pages, Netlify and Vercel all
build from a private repository without exposing it; with GitHub Pages, a workflow pushes
only the built output to a public repository. **Source private, site public, no split
needed.**

## One thing that makes this scheduled rather than optional

**App Store submission requires a privacy policy URL and a support URL.** A live site is a
precondition for submitting, whenever that happens. The marketing pages can be thin; those
two URLs cannot be missing.

---

## The screenshot problem, and the answer

**Michael's constraint, stated 2026-08-31: he does not want to produce screenshots by
hand.** That constraint is right for a better reason than effort — **a hand-taken
screenshot cannot be regenerated, so it rots the moment the UI changes, and no check can
tell.** Generated screenshots are the only kind the drift rule above can actually enforce.

**The answer: `integration_test` driving the iOS Simulator, over a seeded database, with a
faked location.** Concretely:

- **The harness already has a home.** `integration_test/` exists and is wired into
  `pubspec.yaml`. `IntegrationTestWidgetsFlutterBinding.takeScreenshot()` is the standard
  mechanism and it works on the simulator.
- **The injection points already exist too.** The app's test suite already has a fake sync
  transport and a fake position stream — 11.33's own GPS prefill is tested against one.
  **The screenshot harness reuses the fakes rather than inventing a second set**, which is
  what keeps it from becoming a parallel implementation of the app's own startup.
- **`xcrun simctl location set`** puts the simulator somewhere real, so map screens render
  actual tiles over an actual position rather than a null island.
- **Seed the database.** This matters more than it sounds: **a user guide illustrated with
  empty screens is useless.** The seed gives every screenshot the same plausible field
  data — a project, a few tags, bearings, a truth point — and it must be **invented data,
  never Michael's**, so nothing personal or real ever ships in a public image.
- **One script regenerates all of them.** That is the whole point: when a screen changes,
  the images are rebuilt rather than re-photographed.

**What the simulator cannot do, stated rather than discovered later.** There is no
magnetometer, so the **Compass** screen is the one surface a simulator cannot honestly
show. Two options and `/w-02` must pick one and say so: fake the sensor stream at the app
layer for screenshot runs, as the position stream already is, or accept a single
hand-taken photograph for that one screen. **There is no third option where the simulator
quietly produces a compass image that means anything.**

**macOS** builds cover the desktop sections of the guide directly and need no simulator.
**Android** screenshots wait for task 11.66 — there is no point illustrating a platform
nobody has run.

**A second payoff worth naming:** App Store submission needs screenshots at specific device
sizes. The same harness produces them, so that requirement is met by work already done
rather than by an afternoon of manual capture.

**One cost, named honestly:** this runs on a macOS machine, and on GitHub Actions macOS
minutes bill at ten times the rate. **Regenerate on demand, not on every push.**

---

## Order of work, and the reasoning

**Structure before content, and the drift check before there is anything to drift.**

0. **`/w-04` — one line, run at the first opportunity.** The offline suite is red because a
   package this lane added is not registered in its workflow. Two minutes, and until it is
   done every real test failure in the app is hidden behind it. **Corrected 2026-08-31: this
   originally said "before anything else", which was already impossible — `/w-02` was
   running when it was written.** It runs as soon as a window is free, and **it must also
   register any package `/w-02` itself added**, not only `website/tools`.
**Decided 2026-08-31: desktop sections of the guide are text-only, and no task is
scheduled for desktop screenshots.** `integration_test` has no `takeScreenshot`
implementation on macOS, so capturing the desktop app needs a different mechanism
(`screencapture` driven from the host). That is real work for marginal return before a
beta: the macOS app is used at a desk by people who can see the screen in front of them,
and the field guide is the phone. **Revisit if the beta shows people leaning on macOS**;
until then a desktop section without pictures is honest, and a scheduled task nobody gets
to is not.

1. **`/w-01` — structure, deployment, and the drift check.** Pick the generator, get an
   empty site deploying to a real URL, and build the check that compares quoted app copy
   against `lib/` **before** any page quotes anything. A check added after the content is
   a check that starts life with a backlog of failures and gets muted.
2. **`/w-02` — the screenshot harness.** Seeded, scripted, regenerable, with the compass
   decision made explicitly.
2b. **`/w-05` — the joined-and-synced states.** `/w-02` photographed a device with no
   server configured, and the guide's flagship section is joining a project. **A guide
   showing "how to join" illustrated by a device that never joined is worse than one with
   no pictures.** Must land before `/w-03`.
4. **`/w-06` — the lane's tooling, three holes**, found by two windows on one afternoon:
   a harness run that loses its staging directory **reports as ordinary drift**, the GPS fix
   is still switched off although task 11.95 removed both reasons for it, and the drift check
   cannot see `packages/` so the guide's most-read table is unmarked prose. **Run before
   `/w-07`** — it protects every later run.
5. **`/w-07` — the truth-point section.** Michael asked for it directly. Three new captures,
   then the page.
7. **`/w-09` — a fixture more forgiving than reality.** Michael's device overflowed a row
   the harness photographs, watches for errors on, and honestly saw nothing wrong with —
   because **the invented tag name is shorter than a real one.** A fixture that cannot fail on
   the cases that actually happen is an instrument, not a test set.
6. **`/w-08` — the guide catches up with task 11.99**, which falsified eight sentences and
   seven pictures. **The drift check was green through all of it**, which is the finding
   underneath the task: a check that verifies quoted strings says nothing about prose that
   describes the interface, and six of the eight stale sentences are that shape. Michael asked for it directly. Three new captures,
   then the page.
7b. **`/w-11` — the harness photographs whatever is there, and the fixture overshot. Run before
   `/w-10`.**

   **Michael's answer, 2026-09-03: a tracker rarely takes more than five bearings to one tag.**
   `/w-09` seeded **eight** in order to stop the fixture being kinder than reality, and overshot in
   the other direction. **Bring it to five, and draw the distinction while you are there: the
   fixture the guide is photographed over should be what a real session looks like; a test fixture
   may deliberately exceed reality, but has to say that it is doing so.** The pictures are the
   guide's claim about what the app looks like in use.
   **Two things follow, and both are results rather than chores.** The 72-tile fetch that caused
   the 12-to-90-second wait shrinks — **but do not let that stand in for the readiness work below;
   a smaller fixture hides this defect, it does not fix it.** And `/w-09`'s iPad finding gets
   sharper rather than weaker: if the panel shows four rows, then **a realistic five-bearing
   session still does not fit on any device**, which is a stronger statement than the eight-bearing
   version and is task 11.139's second item to measure.
 `/w-09`'s first
   run after enriching the fixture **photographed the map and the truth-point panel mid-download**
   — progress bar visible, no computed overlay — **while reporting *26 of 26 states photographed,
   no screen threw*.** Nothing failed because nothing was wrong by any assertion anybody had
   written; **a person looking at the images is what caught it.** The wait was raised from 12
   seconds to 90 to get past it, **and a number raised until the pictures look right will be wrong
   again the next time the fixture grows.** So: **each captured state asserts a readiness
   condition of its own** — tiles resolved, overlay computed, list populated — rather than sharing
   a tuned sleep; the harness is **watched going red** against a screen that has not settled; and
   the count of states with nothing that would notice is reported. **There is no point taking more
   pictures with an instrument that cannot tell a finished screen from an unfinished one.**

10. **`/w-13` — one published picture has the simulator in it. Run when convenient; nothing
   depends on it.** `/w-12` found `ipad-13/truth-point-edit` drifted 13.24% and guessed at
   simulator sizing. **Measured instead: same dimensions, top 400 rows identical, rows 400–1900
   down 51 device pixels and rows 1900–2752 up 40, and `iphone-6.9` bit-identical.** The
   *committed* image carries **iOS's floating-keyboard pill over the app's own tab bar**, which
   Flutter does not draw — the dialog's Precision field is focused, and the keyboard inset moves a
   centered dialog down and lifts the bottom bar. **The new capture is the clean one.** So this task
   replaces the baseline, sweeps the other text-field shots for the same contamination, and makes
   the keyboard state either deterministic or detectable. **It also carries the terrain-readout
   question `/w-12` was asked and did not answer.**

9. **`/w-12` — four pictures that were waiting. Unblocked 2026-09-04; task 11.144 is Done.**
   `/w-10` drove all four sync-bar failure states successfully and **could photograph none of
   them**, because every completed round tripped a framework assertion in the debug build the
   harness runs — a code-lane defect, task **11.144**, fixed in commit `09723c8`. **With the fix
   the capture run reached 29 of 29 states with no screen throwing.**
   **Two files in this lane still say the four states cannot be photographed and `/w-12` owns
   removing both:** `capture_test.dart`'s comment block, and `shots.dart`'s deliberately-empty
   `syncFailureShotNames`. **They were correct when written**, which is exactly why they will be
   believed. **And the prediction in both this entry and `/w-10`'s report — that this was task
   11.95's class, a side effect called from `build` — was wrong**; the fault was a provider
   deriving from a provider. The mechanism does not matter for taking pictures; **not repeating
   the wrong sentence into the guide does.**
   **The scaffolding is in place and must not be re-derived:**
   `markRecentlySynced`, `breakEveryCall`, `restoreTheServer` and `runSyncRound` in
   `joined.dart`, with the ordering the classification requires written beside them, and the
   measurement in `capture_test.dart` where the captures go. **Four states — offline, records
   refused, records the server sent that this build could not read, no longer on this project —
   chosen from the header table in `sync_bar_states_end_to_end_test.dart` rather than guessed, and
   the five rejected ones stay rejected: the guide handles each in a sentence, and five
   near-identical bars would be five pictures teaching one fact each.**

8. **`/w-10` — the seam exists, and the copy moved. Run after `/w-09` and `/w-11`.** Three items in one
   window, all of them the code lane handing this one something. **(a)** Task 11.97 built the
   seam `/w-05` was waiting for: the app now builds its server connection in one place, so the
   sync bar's failure states can be photographed instead of being found on a hillside. **The
   override is `serverTransportProvider`** (replaces the connection everywhere, sync engine
   included); `membershipTransportProvider` still works and still covers membership only. The
   header table in `test/core/providers/sync_bar_states_end_to_end_test.dart` names all
   fourteen states and which eleven a substituted server can drive — **that table decides what
   is photographable, not a guess.** **(b)** `integration_test/screenshots/joined.dart`'s
   comment about `SyncController` building its own transport is now false, and the sentence
   beside it — that the sync engine is never faked — **stops being true for any capture that
   overrides `serverTransportProvider`**, so each capture must say which override it uses.
   **(c)** The guide catches up with tasks 11.122 and 11.89: the identity screens' refused-
   character message, which is **two messages** split on visible versus invisible, and the new
   name allowlist. **The name rule is settled and safe to write; the held-record wording is
   not** — task 11.124 replaces it, so describe the behavior and quote through the shortcode.

3. **`/w-03` — the guide, for settled flows only.** **It may touch
   `integration_test/screenshots/` for one purpose only** (granted 2026-08-31): capturing the
   owner's approval sheet, which is the biggest remaining hole in the join story and is a tap
   and a capture rather than a harness change. Joining a project, taking a bearing,
   syncing, members and roles. **Deliberately excluding** truth points until 11.92 lands
   and anything Android-specific until 11.66 does. **A guide that documents an unfinished
   feature is worse than one that omits it**, because a reader cannot tell which sentences
   to trust.
4. **Marketing pages last, and weighted lightest.** A marketing page for an app nobody can
   download is a placeholder, a brand marker, and the host for the privacy policy. It is
   the least valuable page on the site until there is a download link on it.

---

## What is settled enough to document, as of 2026-08-31

**Settled — safe to write:** joining a project by code and being approved; the projects
list and members; roles; recording a bearing; sync and what the sync bar means; leaving and
being removed; export of observations. **Added 2026-09-02: what a person's name may contain**
— task 11.89 made it an allowlist and Michael accepted the consequence (brackets, at-signs and
emoji are refused) on the same day, with a written reopen trigger. Write it as the allowlist,
not as a list of exclusions.

**Newly photographable, added 2026-09-02:** the sync bar's failure states. Task 11.97 gave the
app one place where its server connection is built, so eleven of the bar's fourteen
presentations can be driven from a substituted server. **This is the thing `/w-05` deferred.**

**Settled 2026-09-02, corrected here 2026-09-03 — this paragraph used to say "not settled, and
newly so".** Task 11.124 **landed**; it did not stay pending. The sync status screen's held-record
wording is now **two things and both are stable**: a sentence naming the field when the server
explained itself, and task 11.122's honest default when it did not. `held_row_details.dart` carries
the four messages. **Both are describable.** `/w-10` found this paragraph holding copy back that
did not need holding — **a "not settled yet" note that outlives the settling is the same defect as
a decision recorded as still owed**, and it costs more here because it silently narrows what the
guide is willing to say.

**Not settled — do not write yet:** truth points (11.92 is changing what you can do with
them); anything Android (11.66 has not been run); the viewshed boundary's appearance
(11.87); what a refused join request shows over time (11.79 adds a frozen name and an
expiry).

**The join flow is the strongest reason to start now rather than a week ago.** It is the
largest user-facing surface in the app, it changed completely on 2026-08-31, and it has now
been walked end to end on hardware. A guide written before that would have been entirely
wrong.
