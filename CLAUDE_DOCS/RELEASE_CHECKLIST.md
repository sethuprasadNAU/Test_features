# Before a release: what a machine has checked, and what a person still must

**Task 11.40, 2026-08-29.** This project had no continuous integration at all
until this task: nothing ran on a commit. It now has four workflows, and this
file is the other half of them — **what they deliberately do not cover, and
therefore what a person has to do before a release.**

**Read the division before trusting a green tick.** A badge that omits the
class of defect task 11.38 found would be worse than no badge, because it
would be read as coverage. This project's own most-repeated finding is that *a
check which cannot fail for the reason you care about is not a check*.

---

## Part 1 — what CI covers

Five workflows in `.github/workflows/`. See that directory's `README.md` for
the table.

| Runs on every commit | Runs on change, nightly (off until 1 October 2026 — task 11.221), or on demand |
| --- | --- |
| **The offline suite** — ~1,536 tests, verified with the server stack down | **The eighteen gate instruments** — the whole committed security-instrument set, against a stack the run brings up itself |
| **The server suite** — ~724 tests against a real Postgres in Docker | **The instrument self-test** — forces a stale schema major and requires every wire-speaking instrument to *abort*, proving they can still fail |
| **The Android build** (task 11.76) — `flutter build apk --debug` actually compiles and packages, plus the merged manifest is checked against `CAPABILITY_MATRIX.md` | **The broken-control check** — breaks the server on purpose and requires the round-8 instrument to notice; fires only when the sync envelope or the auth routes change |
| | **The iOS + macOS build** (task 11.76) — on demand only; see item **B1** below |

**Measured on 2026-08-29, not assumed:** all eighteen gate instruments pass and
`gate_smoke_test.sh` exits 0, and the whole suite runs from a **fresh clone
with a three-line `.env`** — the instruments generate their own `age` and
`minisign` keys and their own TLS certificate. That is what makes an unattended
run possible at all, and it was checked by doing it rather than by reading the
scripts.

**Everything in `.github/workflows/` is unverified until its first run on
GitHub.** No workflow can be executed from a developer's machine. What *was*
executed locally is every script each workflow invokes, in the shape the
workflow invokes it. **The first push is the first real test, and if a
workflow is broken it will be broken loudly rather than silently green** —
that is the direction that matters.

## Part 2 — what CI deliberately does not cover

### The hardware tests cannot be automated, and configuring something that
### implies they are covered would be worse than leaving them out

`integration_test/` holds two tests that run as the **real, signed app
bundle**. Neither can run on a GitHub-hosted runner:

- There is no signing identity in CI, and `session_store_keychain_test.dart`
  **fails by design on an ad-hoc-signed build** — macOS refuses the
  data-protection keychain to an app with no team, with error `-34018`. A CI
  run of it would fail for the wrong reason. The temptation would then be to
  configure it until it stopped failing, which is how a green badge comes to
  mean nothing.
- `ats_transport_security_test.dart` needs a real device or simulator with a
  real App Transport Security stack.

**Automating these needs a self-hosted, signed macOS runner.** That is a real
option and not a large one, but it is a machine somebody maintains, holding a
signing certificate, and it is not this task's to stand up. Until then they are
items H6 and H7 below.

### The end-to-end suite is not in CI yet, and this is a dated decision

It *can* run unattended — `scripts/run_e2e_tests.sh` is one command and the
suite was 60/60 green on 2026-08-29. It is out because of a known intermittent
failure whose diagnosis is not finished: twice on 2026-08-29 a run failed
claiming the per-address rate limit had refused a request, with addresses that
could not possibly have been limited. **Task 11.40 fixed the instrument** —
the reader now asks the server's own audit log and never asserts a limiter it
cannot observe — but the underlying slowness that made it time out has not
been reproduced or explained. Adding a job that goes red for a reason nobody
can explain trains people to ignore the red.

**Revisit after the next ten green runs, or on the next unexplained failure,
whichever comes first.**

---

## Part 3 — the human checklist

### B — before a release, press this button

| # | Do this | Why it is here |
| --- | --- | --- |
| **B0** | **Restore GitHub's checks first, then run them.** **GitHub's checks are paused** since 2026-10-02 (task 11.325): every workflow in `.github/workflows/` starts only when somebody presses *Run workflow*, because the code changes many times a day and the checks run as one batch on Michael's own machines (`scripts/nightly_check.sh`). **Restore the triggers before a release, or when development slows:** each paused workflow has a dated `# PAUSED` notice and a comment holding the triggers it had, so restoring is a copy (the notice says exactly how; `gate-instruments.yml` also has the self-test step's `if:` to put back). Then delete the notice, and this row. `test/documentation/ci_pause_test.dart` goes red if a notice and a workflow's real triggers disagree, or if this row stays after nothing is paused. | A release is the moment a check that has not run on the branch is most expensive to learn about, and a paused check is silent by construction: nothing goes red when it stops. |
| **B1** | **Run the "iOS + macOS (on demand)" job in `build-check.yml`** (Actions → Platform build check → Run workflow, on the branch you are about to release). It bills at macOS's 10x Actions-minutes rate — the run's own summary states exactly how much it cost — which is why it is not on every push or a schedule. | Proves the app still compiles and packages for iOS and macOS. Task 11.30 removed platform-channel references from both projects and nothing caught that the apps no longer built until Michael built them by hand. Android's half of this already runs on every push; a trigger nobody is told to pull is not a trigger, so it is written down here. |

| **B2** | **Run `integration_test/screenshots/regenerate.sh iphone-6.9`, then read what it says moved.** It boots the real app on a real iOS simulator at App Store device geometry, photographs **33 states across two device profiles**, and compares each against the committed image — naming every screen that changed and writing a diff picture. **It stops there. Nothing is overwritten until a person types `--accept`.** Takes several minutes; do not run it while a website task is running, since the content lane uses the same harness. *(Added 2026-09-07 from task 11.186.)* | **This is the only thing in the project that can say "this screen did not change", and nothing was running it.** The 66 committed images moved only when a website task happened to regenerate them, so a screen could drift between content tasks with nothing to notice. **It is here rather than in CI on purpose, and the reason is the point:** its value comes entirely from the accept step being a person who looked. Put it on a runner and it either fails constantly until somebody disables it, or it auto-accepts — **which is the re-blessing failure that made this project decide against goldens under `test/` in the first place.** A macOS runner also bills at 10x. **One limit to know while reading it: every image is at the default text size.** The accessibility sizes — the axis nearly every open rendering question in this project sits on — are not photographed by anything. |

### H — hardware, one platform at a time

Each of these is a capability the operating system grants, which **no
`flutter test` run can see** — `flutter test` ships no `Info.plist`, no
entitlements, no signature and no platform channels. See
`CLAUDE_DOCS/CAPABILITY_MATRIX.md` for the full enumeration and where each is
declared.

| # | Do this | Why it is here |
| --- | --- | --- |
| **H1** | **On an iPhone, on Wi-Fi, point the app at a LAN server and sync.** Watch for the iOS local-network permission prompt and note whether refusing it produces any message at all. Then try a `.local` hostname as well as a bare IP. | `NSLocalNetworkUsageDescription` has never been exercised. Refusing that prompt makes the server unreachable in a way the app cannot tell apart from the server being down. Task 11.51 asked specifically whether a `.local` name works from iOS and nobody knows. |
| **H2** | **DONE on an emulator 2026-08-31 (task 11.66); still open on a real phone.** On an Android device, record a bearing; confirm a location permission dialog actually appears. **What was measured:** the dialog appears with the Precise/Approximate choice, granting it yields a fix the record screen, compass declination and DEM elevation all consume, and the saved CSV carries the whole provenance chain. **What an emulator could not answer:** a real magnetometer, real GPS acquisition and drift, and a device without Google Play services. See `README.md`, "Walking the whole app on Android". | **Android declared no location permission at all until this task.** `Geolocator.requestPermission()` was denied without a dialog, and the app showed its own tidy "location was denied" message — so a person saw a screen saying they had refused, having never been asked. The declaration is now there and **task 11.66 ran it** — see the left column for exactly how far that goes. |
| **H3** | **On macOS, export a CSV, import a tag CSV, and save and restore a backup.** | **The macOS entitlement for user-selected files was missing from all four entitlement files until this task**, while the sandbox was on in all four. The panel opens either way; without the entitlement the app has no permission to read or write what you picked, so an export appears to work and produces nothing. |
| **H4** | **OBSOLETE — do not run this (task 11.66, 2026-08-31).** Cloud backup was retired by task 11.31. There is no `lib/core/platform/` directory, no `edu.nau.tritrack/cloud_backup` method channel, and `MainActivity.kt` is the bare five-line `class MainActivity : FlutterActivity()` — **the app registers no custom platform channel on any platform.** The security-scoped bookmark this item was written about no longer exists to go stale. | Kept as a row rather than deleted, because "we checked and it is gone" and "nobody looked" are indistinguishable a year later. |
| **H5** | **On a Mac, confirm the compass-unavailable state appears; on a phone, confirm a live compass reading tracks reality.** | Task 5.2 built a capability-based unavailable state against a fake stream. Whether the real sensor behaves as it expects has only ever been checked by hand. |
| **H6** | **Run `./scripts/verify_session_store_keychain.sh`** on a Mac with signing configured. | Sign-in on macOS never worked in any build until task 11.38. This is the test that would have caught it, and it cannot run in CI. |
| **H7** | **Run `./scripts/verify_ats_transport_security.sh`** on real hardware. | Proves App Transport Security refuses cleartext to a public host, rather than the app's own URL check refusing it first. |
| **H8** | **On a real Android phone — the half an emulator cannot answer (task 11.66, 2026-08-31).** Hold it and take a bearing outdoors: does the compass track reality, does a GPS fix arrive and settle, and what does an hour of automatic sync cost in battery? Then check the two device classes nobody has: **a phone with no Google Play services** (geolocator falls back from the fused provider to `LocationManager`, and that fallback has never run) and **a phone that is not a Pixel** (manufacturer permission and battery-optimisation layers are where Android apps actually break). | The whole walk in `README.md` was done on an emulator. Everything the *operating system* decides was covered there — permissions, files, database, network, Keystore, layout. Everything the *hardware* decides was not. |

### F — things only a person in the field can measure

| # | Do this | Why |
| --- | --- | --- |
| **F1** | **Measure what automatic sync costs in battery and cellular data — a real phone, a real day in the field, a real server.** | Nobody has ever measured it. The fifteen-minute default ships on task 10.8's reasoning, and the confirmation after task 11.59 shipped was *"seems to work"* — an observation, not a measurement. If it costs more than it is worth, the remedy is already on the screen. **Added 2026-09-18: the map's terrain download is not sync, and it will be in the same day's data figure.** Task 11.281 cut it from 380 requests to 143 for a cold-cache fill, so it is much smaller than it was — but it is not zero, and a day that included opening the map in new country will carry it. **Note whether you opened the map somewhere new, or the number measures two things and blames sync for both.** |
| **F5** | **Run `scripts/backup_restore_drill.sh` once before any beta build goes out, and read step 5b.** It should say *"names schema major 4"*. **Added 2026-09-13.** Task 11.242 fixed three backup scripts that had labeled archives with the wrong major for three days — including **the signed comment `restore.sh` trusts** — and made a server-suite group check them against the constant. **The scripts are tested; the drill they describe has not been run since.** A restore nobody has exercised is a backup nobody has. |
| **F4** | **At the next live gate run, re-read Security Model §4.13's H-3 sentence against what the sweep now probes.** Task 11.240 added a table, so the sweep covers **thirteen**; the sentence was written for fewer. **Added 2026-09-13, deliberately not edited** — it is a measurement nobody has taken, and correcting a security count from a guess is how the last four count errors on this project happened. |
| **F3** | **Ask each beta crew, once, whether any collar appears twice in one project — same frequency, same name, two rows.** If one does, that device **cannot import an older backup of that project**: task 11.239 refuses it, correctly, and there is no merge in the app to get out of it (Phase 12). **Added 2026-09-13. Michael's own phone was counted and is clean**; this is here because a stranger's phone has not been. **A refusal with no way forward is a trap when the person holding it is not the person who can fix it.** |
| **F2** | **On every beta device, open the "Records that did not arrive" section, and ask every beta user to report one if they ever see it.** | That section is the only signal that a teammate's record was refused and **will never arrive on its own**. It is the written trigger for deferred task 11.50, and a trigger nobody is looking for is not a trigger. |
| **F6** | **Turn on *Settings → Accessibility → Larger Text → Larger Accessibility Sizes* once, on a real phone, and walk the app.** **Added 2026-09-15, task 11.257.** | The app mentions this setting nowhere, so nobody has ever met it on purpose. `test/features/clipped_text_sweep_test.dart` found four screens with a problem in that range, none of it reachable on the ordinary Dynamic Type slider (`xxxLarge`, the bar this sweep fails on): the compass screen's declination row overflows at AX5; the "Manage on map" button (offline maps) and "New selection" button (offline data map) silently lose part of their label at AX5; and the Viewer/Contributor/Owner role labels on the project members screen silently lose part of theirs from AX3 up. The first beta user with this switch on will not report "clipped text" — they will just struggle, so this is the only way anyone finds out how it actually feels. |

| **F7** | **The disclaimer is in the app, and somebody accountable at NAU has read it where it renders — not in a document.** **Added 2026-09-18, task 11.285.** | **The app ships today with no disclaimer, no warranty language and no limitation of liability anywhere** — measured, not assumed. NAU's AVP for Research and Innovation has sent text, but it is written for a two-party patent license (*Licensor*, *Licensee*, *amounts paid under this Agreement*) and **a biologist who installs this has signed nothing and paid nothing**. The wording has to be settled with NAU before it ships, and the thing that must not happen is a beta going out while everyone assumes somebody else handled it. **And the sentence this app actually needs is not in the received text at all:** a position estimate is an estimate, and somebody may make a navigation decision from it in the backcountry. |

### D — the deployment, before anyone else's data is on it

| # | Do this | Why |
| --- | --- | --- |
| **D1** | **Run `./scripts/verify_source_identity.sh --assisted` on the actual beta host, from two real off-host devices, and read the verdict yourself.** Only `PRESERVED` licenses `TRITRACK_TRUSTED_PROXIES=peer-verified` or `TRITRACK_PROXY_SOURCE_IDENTITY=probe-verified`. | It licenses **that host**, not the platform. A different beta host means measuring again. This is deliberately not automatable: the value is *you* asserting what you saw, and a tool that wrote it would be making a claim about your network on your behalf. |
| **D2** | **Run `scripts/backup_restore_drill.sh`, and restore a backup into a scratch database by hand at least once.** | A backup nobody has restored is a hope. |
| **D4** | **The beta host is changing, so D1 and D3 are owed again on the new one.** **Added 2026-09-14:** Michael met NAU ITS and the plan is a real NAU Linux application server rather than the Parallels VM everything so far was measured on. | **D1 licenses one machine, and this is a different machine** — the `--assisted` run, from two off-host devices, has to happen on the NAU host. D3 stops being a formality at the same moment: the VM was the LAN prototype the cleartext exemption is scoped to, and a NAU host is not. `SERVER_DEPLOYMENT_PRIMER.md` and `TriTrack-server-architecture.html` both describe the old host and will need a pass. **Updated 2026-09-21:** the PDF this row used to name was deleted by task 11.295 — the HTML page is the diagram, and it prints to letter paper from a browser if a PDF is wanted. |
| **D3** | **Confirm `TRITRACK_ENV=production` and real TLS**, not the loopback prototype. | The whole cleartext exemption is scoped to a LAN prototype. |
| **D5** | **On the NAU host, confirm containers keep their outbound network for a day, not a moment.** **Added 2026-09-24.** On Michael's Ubuntu VM, containers silently lost all outbound network twice in one day (2026-09-23) while the host itself was fine; `sudo systemctl restart docker` fixed it both times. **A third time, 2026-09-28, it was measured: `docker0` had lost its IPv4 address** while Docker's own rules were intact, and UFW logged nothing; what removes the address is unknown, and the measurements count against UFW, the earlier suspect. On the VM it only broke builds. **On a production host it would break sign-in**: the server container reaches the mail relay outbound, so every link would be `NOT DELIVERED` — visible in the audit log since task 11.293, and to nobody signing in. | Before anyone else's data is on it: on the NAU host, run `docker run --rm debian:bookworm-slim getent hosts deb.debian.org` and `ip -4 addr show docker0` (it must print an `inet` line) on the day it goes up and **again a day later**; ask ITS whether anything on the host manages network interfaces or the `FORWARD` chain alongside Docker. **One passing check proves the network was up once.** |
| **D6** | **Before restoring or rebuilding a server real devices have synced against, the server and every device must be on a build with task 11.58 and have synced once.** **Added 2026-09-29.** Task 11.58 gave the server a database name so a device notices a replaced database and starts its sync over, instead of silently missing records. A device with no stored name adopts whatever answers, so **a server restored before its devices have updated and synced once is still invisible to them** (pinned by the `LIMIT, pinned` test). **A whole-disk restore defeats it too:** rolling the server's virtual machine back to a snapshot brings the old name back with everything else. | Before any restore or rebuild: check every device has synced on a build with 11.58. **After any VM snapshot rollback or host-level volume restore, rotate the name by hand:** `DELETE FROM server_database_identity;`, then restart the server. **Ask ITS whether the NAU host is snapshotted or restored at the disk level**, and if it is, write this step into the recovery procedure they will follow. |

---

## Part 3a — what is owed when CI comes back on 1 October

**Closed 2026-10-02 by task 11.318.** C1, C3 and C4 are done; C2's question is answered (the round-8
`sanitiser` variant flips 9 of 9 on a CI run). **The September reds were a GitHub billing refusal,
not code:** every Offline-suite run from 2026-09-11 to 2026-09-30 was refused before it started. The
Offline suite's two real reds found on 1 October are task 11.325. The table below is kept as the record.

**Written 2026-09-22 because this list did not exist.** CI has been off since 2026-09-10 to save
Actions minutes (task 11.221). Since then, roughly thirty tasks have each ended with the sentence
*"no CI until 1 October"* — and what each of them was **deferring** has been recorded in its own
comms entry, in a workflow comment, or in a chat message. **Three of those places are not read on a
schedule and one of them does not survive a closed window.** So: one list, here, where the person
who turns CI back on will be standing.

| # | Owed | Where it came from |
| --- | --- | --- |
| C1 | **Re-enable the `gate-instruments.yml` nightly schedule** — the `schedule:` block is commented out with a dated note | Task 11.221's decision, taken to save minutes |
| C2 | **Runnable locally, but not safely as shipped — see task 11.310 item 6 before trying.** The drill's first phase attacks **whatever is on `localhost:8080`** without checking what it is; on a machine that also serves TriTrack, that is the real server. Measured 2026-09-23; deferred until 11.310 and 11.311 land, because two of the four drills demand a clean healthy run that their instruments cannot give today. **Read the first `broken-control-check.yml` run specifically for the re-authored round-8 `sanitiser` variant.** Task 11.287 rewrote it because a refactor deleted the line it patched, and **said plainly it did not run the twenty-minute drill** — so *"the re-authored variant flips its probes"* is a claim that run makes or refuses | Task 11.287, 2026-09-20 |
| C3 | **Add a CI copy of `scripts/check_generated_files_current.sh`.** Task 11.309 gated it into the pre-commit hook, which protects **this machine's commits only**; a guard that lives only in a hook is a guard the next contributor does not have | Task 11.309, 2026-09-22 |
| C4 | **Decide whether the gate gains an image allowance**, which is what `scripts/verify_smtp_delivery.sh` is waiting on — it runs in six seconds with a broken control and is `gate-instrument: none` only because it pulls `axllent/mailpit` | Task 11.287, item 6 |

**And the thing that is owed that is not a line item.** Every task from roughly 11.280 onward has
been verified by local runs alone. **The first CI run after 1 October is therefore checking several
weeks of work at once, and a failure in it will not name which task caused it.** That is the cost of
the pause, accepted knowingly; the mitigation is to run the workflows **before** the next change
lands, so the first red is attributable to the backlog rather than to whatever was committed that
morning.

## Part 4 — the contradiction this checklist was asked to settle

`SESSION_HANDOFF.md` §8 calls three unscheduled Phase 10 tasks
**beta-blocking**. Each of those plan entries says **"Not blocking."** And
`SECURITY_SCOPE_AND_EXIT.md` records **Gate D as passing**, whose stated
question is *"may the app ship to a beta team?"* Both cannot be the operative
answer, and the risk is somebody reading "Gate D passes" as clear-to-ship.

**The disagreement is real, and two of the three resolve cleanly. The third is
Michael's, and it is not a security question.**

### Task 10.84 — archive encryption and client key custody

**Verdict: it must close before a beta ships, or its acceptance must be
re-decided in writing. Neither document is wrong; the word "blocking" is doing
two jobs.**

The plan's "Not blocking" is **gate-scoped**: 10.84 does not block Gate C or
Gate D, and §15.6 says so. The handoff's "beta-blocking" is about a **time
bound**: §4.15.1 accepts the cloud-backup archive shipping unencrypted *only
until* "archive encryption with a client key-custody design lands, **required
before the beta field season**." 10.84's own entry states the consequence in so
many words: **"A Gate D pass does not extend §4.15.1's acceptance past its own
date."**

So both sentences are true and they are answers to different questions. What
must not happen is the acceptance lapsing in silence. **Either encryption lands
before the field season, or the acceptance is re-decided with a new stated
bound and a fresh disclosure to whoever's data is on the device.** Checklist
item: **before a beta ships, check §4.15.1's date has not passed unanswered.**

### Task 10.99 — the unbounded archive envelope

**Verdict: accepted for the beta. `SESSION_HANDOFF.md` §8 is the document that
is wrong.**

§15.4 of the security model registers this finding and says in so many words:
**"None of them blocks either gate."** The reasoning is on the record and it
holds — no existing row is lost or altered, mass fabrication is pure insertion,
and the post-import report states the true count. It earns a task because the
*pre*-import dialog shows numbers the attacker chose, which is a real defect
and a scheduled one.

**Reaching it requires somebody handing you a malicious backup file.** In a
beta that is a colleague's `.zip`, not a stranger's.

### Task 10.107 — what a third-party tile server can put in the field record

**Verdict: accepted for the beta as a security matter — `SESSION_HANDOFF.md`
§8 is wrong on that. But there is a second question the security bar was never
asked, and it is Michael's.**

The security half is settled: §15.4 registers it below the bar because reaching
it adversarially means defeating TLS, and records that decision. Fine.

**The other half has no attacker in it at all.** Elevation pixels fetched from
a third-party tile server become a `NOT NULL` column in the field record and
are **preferred over the device's own GPS altitude by explicit design** — then
flow out through CSV export and the sync push to every teammate. Nothing
clamps the parsed value, nothing times out, and the cache writes bytes before
proving them decodable and never revalidates, **so a single bad `200` — a
captive portal, a mis-serving mirror — persists on that device forever.**

That is not a security finding. It is *"a corrupt tile silently becomes
authoritative surveyed ground elevation in a wildlife dataset."* **Whether that
is acceptable in a beta whose whole purpose is collecting real field data is a
science-quality judgement, not a security one, and the gate never asked it.**

**This one goes to Michael**, stated plainly, in Part 5.

---

## Part 5 — the decisions that are Michael's, not this document's

1. **Does task 10.107 block the beta on data-quality grounds?** The security
   answer is no and it is well-reasoned. The question nobody has asked is
   whether you are willing to collect a field season of elevations that could
   be silently wrong, in a dataset you will analyze later. Options: (a) accept
   it for the beta and schedule 10.107 after; (b) do the two smallest parts
   now — clamp the parsed elevation to a plausible range, and stop caching
   bytes before proving they decode — which are hours, not days; (c) block the
   beta on the whole task.
2. **Does §4.15.1's acceptance get renewed, or does 10.84 land?** A date is
   about to pass. Not deciding is itself a decision, and the wrong one.
3. **Is a self-hosted signed macOS runner worth standing up?** It is what would
   put H6 and H7 into CI. Until then two real defect classes are checked only
   when somebody remembers.
