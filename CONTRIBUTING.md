# Contributing

## Getting set up

Xcode 16 or later, macOS 14+, iOS 17+.

The `.xcodeproj` is **generated, not committed** — `project.yml` is the source
of truth. A fresh clone therefore needs one extra step:

```bash
brew install xcodegen
git clone https://github.com/mcpeixoto/MotionCues.git
cd MotionCues
xcodegen generate
open MotionCues.xcodeproj
```

If you change targets, build settings or file layout, edit `project.yml` and
re-run `xcodegen generate`. Never commit the `.xcodeproj`.

## Tests must stay green

```bash
xcodebuild -project MotionCues.xcodeproj -scheme MotionCues \
           -destination 'platform=macOS' test
```

CI runs exactly this on every push and pull request, plus an iOS build.

## Changing the filters or the motion maths

This is the part of the codebase where a change can look fine and be wrong, so
there is one rule: **a filter change needs a numeric test, not an opinion.**

"Feels smoother" is not reviewable. The existing tests in
`Tests/MotionCuesTests.swift` show the shape to follow — residual noise on a
parked car, time to 90 % of a 0.3 g braking step, amplitude retention on a
0.25 Hz manoeuvre, calibration error in degrees under several driving regimes.
If you retune `OneEuroFilter`, move those numbers and say which trade you made.

`Tests/SyntheticDrive.swift` generates a drive with known ground truth and an
arbitrary phone orientation. Use it rather than inventing a new fixture.

## Changing the visual mapping

The dots follow the pseudo-force `f = −a`, so they move the way a loose object
on the dashboard moves. Getting a sign backwards would make the app actively
worse than nothing for the people it is meant to help. `DotLayoutTests` pins
all four directions; do not weaken them.

## Things that will be pushed back on

- New Apple APIs used without checking availability. The whole project exists
  because `CMMotionManager` is `API_UNAVAILABLE(macos)`. Check the SDK headers,
  and put the annotation in a comment where it matters.
- Anything that phones home. No analytics, no crash reporting, no update
  checks, no accounts. See `PRIVACY.md`.
- SwiftUI in the render path. The overlay is driven by a `CADisplayLink`
  writing `CALayer` geometry directly, deliberately.
- Claiming an overlay limitation is solved when it is not. If full-screen
  behaviour changes, verify it and say how you verified it.

## Verifying the UI

Some things cannot be unit tested. There is an env-gated self-check:

```bash
MC_PROBE=1 /path/to/MotionCues.app/Contents/MacOS/MotionCues
```

It prints the app's own window list — status item, overlay frame and level, and
whether the settings window opens on request. Ask the app, not the WindowServer:
`CGWindowListCopyWindowInfo` does not report SwiftUI `MenuBarExtra` status items
and disagrees with the overlay's real frame.

## Commits and pull requests

Small, focused commits with a message that says *why*. Open an issue first for
anything large so we do not both build it.
