# XNook Review Fixes Design

## Scope

Fix the confirmed review findings without changing the visual design or introducing new service layers:

- Select the actively playing Music or Spotify source.
- Keep lyrics fetching synchronized with both the track and the privacy setting.
- Request the correct macOS 14 calendar permission and query the selected day/calendars.
- Preserve calendar scroller selection and highlighting during programmatic scrolling.
- Resolve and access security-scoped bookmarks correctly.
- Document the app-bundle build path and add focused regression tests.

## Design

### Media and Lyrics

`ScriptingBridgeHelper` will query only running supported players and select a source by playback state. A playing source wins; when neither source is playing, Music remains the deterministic fallback.

`MediaManager` will treat a lyrics preference change like a track change. Disabling lyrics clears cached lyrics; enabling lyrics fetches the current track on the next polling cycle. `LyricsManager` retains its preference guard as defense in depth.

### Calendar

`CalendarManager` will retain the displayed date and build an EventKit predicate for that day. The predicate receives the currently selected calendars, initialized to all available calendars. Event creation, deletion, and calendar toggles reload the same displayed day.

`CalendarWidgetView` will reload events when its selected date changes. Programmatic scrolling will update cell highlighting immediately and suppress only intermediate scroll callbacks, then restore a stable selected date after the animation.

The app bundle will declare `NSCalendarsFullAccessUsageDescription`, matching `requestFullAccessToEvents()`.

### File Tray

Bookmarks created with `.withSecurityScope` will also be resolved with `.withSecurityScope`. Each operation will start access before touching the resource and stop access afterward. Stale bookmark refresh will run while access is active.

### Tests and Verification

Add a SwiftPM test target. Tests cover media-source precedence, lyrics preference transitions, LRC parsing, and day-boundary calculation. Verification consists of `swift test`, `swift build`, `git diff --check`, and a final review of the changed files.

## Non-goals

- UI redesign.
- Replacing EventKit, ScriptingBridge, or MediaRemote.
- Introducing protocol-based dependency injection.
- Changing distribution, signing, or sandbox entitlements.
