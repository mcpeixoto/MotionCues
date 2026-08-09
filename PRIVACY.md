# Privacy

MotionCues reads motion sensors, which is about as personal as data gets. Here
is exactly what happens to it.

## What the app collects

**On the Mac**

- Head motion from AirPods, if you choose the Mac sensor source
  (`CMHeadphoneMotionManager`). Requires the Motion & Fitness permission.
- Motion samples sent by your own iPhone over the local network.

**On the iPhone companion**

- `CMDeviceMotion` — attitude, gravity-removed acceleration, rotation rate,
  gravity — at 100 Hz. Requires the Motion permission.
- Ground speed from `CLLocation`, **only if you switch "Use GPS speed" on**. It
  is off by default. It is used for one thing: compensating for body roll in
  corners, where lateral acceleration ≈ speed × yaw rate.

## Where it goes

To your Mac, directly, over your local network or over peer-to-peer Wi-Fi
(AWDL). That is the entire journey. Both apps are built with no HTTP client, no
SDK, and no server to talk to.

## What is *not* in this app

- No analytics, telemetry, metrics or usage reporting.
- No crash reporting.
- No accounts, sign-in or identifiers.
- No cloud storage or sync.
- No advertising or tracking of any kind.
- No update checks — the app never makes an outbound Internet connection.
- No third-party dependencies at all. Apple frameworks only.

## What is written to disk

Only your settings, in `UserDefaults`:

- appearance (dot count, size, opacity, edge distance, placement, contrast)
- intensity, smoothing, sensitivity, responsiveness
- chosen sensor source, start-on-launch, hide-from-capture
- the calibration angle — a single number, the yaw of the car's forward axis
  relative to the sensor

**Motion samples are never written to disk.** They live in memory for as long
as it takes to filter them and move a dot, and are then overwritten by the next
sample. There is no log, no buffer and no recording.

Location is never stored. The speed value is used in the moment and discarded;
it is never persisted, never transmitted anywhere except to your own Mac as a
single number inside a motion packet, and no coordinates ever leave the phone.

## Permissions and why

| Permission | Where | Why | Optional? |
|---|---|---|---|
| Motion & Fitness | Mac | AirPods head motion, the fallback sensor | Yes — only if you use the Mac source |
| Local Network | Mac + iPhone | Bonjour discovery and the UDP link between your own devices | No, if you use the iPhone source |
| Motion | iPhone | The accelerometer and gyroscope data the app exists to read | No |
| Location (When In Use) | iPhone | Speed, for roll compensation in corners | **Yes — off by default** |

The app asks for **no** Screen Recording and **no** Accessibility permission.
It cannot see what is on your screen. That is also why dot colour follows the
system appearance rather than the pixels behind the overlay — reading those
would require Screen Recording, and it is not worth it.

## Sandbox

The macOS app runs in the App Sandbox with exactly two network entitlements:

- `com.apple.security.network.server` — to receive datagrams from your phone
- `com.apple.security.network.client` — to advertise over Bonjour and answer
  the heartbeat

There is no file access entitlement, no camera, no microphone, no address book.

## Verifying any of this

Everything above is checkable. The whole source is here, it has no
dependencies, and the network code is one file per side:
`MotionCues/Networking/MotionReceiver.swift` and
`MotionCuesIOS/Networking/MotionSender.swift`. If you want to watch the traffic,
the wire format is documented in `Shared/MotionCuesProtocol.swift` — 76 bytes,
little-endian, no encryption because it never leaves your local link.

## Questions

Open an issue at https://github.com/mcpeixoto/MotionCues/issues.
