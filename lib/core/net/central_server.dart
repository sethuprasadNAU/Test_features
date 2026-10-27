/// **The central TriTrack server's address — the one place it is written**
/// (task 11.324, item 4).
///
/// Michael, 2026-10-02 (`CLAUDE.md`, standing decision 3): *"We are moving to
/// a central server not a project specific server deployment."* So the app
/// ships with this address filled in on More → Server Connection, and a person
/// can still change it there (for testing). `ServerConfigNotifier` uses it
/// whenever this device has never saved an address of its own; see
/// `centralServerAddressProvider` for how a test substitutes it.
///
/// **Empty, deliberately, as of 2026-10-08: the central server's address is
/// not known yet.** With it empty, a new install starts unconfigured — exactly
/// as before this task — and the screen offers no "Use the TriTrack server"
/// button. Filling it in is a one-line change here; it must be an `https://`
/// address, because a release build refuses plain `http://` (§4.1).
///
/// What would make this comment false: a second copy of the address anywhere
/// in `lib/` (`central_server_default_test.dart` checks there is one
/// declaration), or a build that sets the address some other way.
const String centralServerBaseUrl = '';
