# Security

## Reporting a vulnerability

Use GitHub's private reporting:
https://github.com/mcpeixoto/MotionCues/security/advisories/new

Please do not open a public issue for anything exploitable. This is a personal
project, so expect a reply in days rather than hours.

## Attack surface, honestly

MotionCues is small, and most of it is not reachable by anyone but you. The
parts that are worth thinking about:

**The UDP listener.** The Mac opens an `NWListener` on UDP and advertises
`_mcues._udp` over Bonjour while the app is running. Anything on your local
network — or in Wi-Fi range, since peer-to-peer/AWDL is enabled — can send it
datagrams.

What that gets an attacker: they can move dots on your screen. The packet
parser is fixed-length, has no allocation driven by packet contents, no length
fields, no strings, and no branches on attacker-controlled data beyond a magic
number, a version and a kind byte. It decodes 76 bytes into fixed-size numeric
fields and rejects everything else. `Tests/LinkTests.swift` fires garbage,
truncated data and wrong-kind packets at the real receiver over a real socket.

What it does not get them: there is no authentication precisely because there
is nothing behind it worth authenticating. The stream is one-way sensor data
into an animation. It cannot read files, run code, or reach anything else in
the app.

**The link is unencrypted.** Deliberately. It carries acceleration numbers
between two of your own devices on a local link. If you are in a threat model
where someone in Wi-Fi range learning that your car is braking matters, do not
run this.

**No spoofing protection.** If two phones send, the last one to connect wins.
Again: the consequence is wrong dots.

## What the app deliberately does not have

- No privileged helper tool, no `launchd` daemon, no `setuid` anything.
- No auto-update mechanism and no outbound Internet connection at all, so
  there is no update channel to hijack.
- No third-party dependencies. Apple frameworks only, so there is no supply
  chain beyond Xcode itself.
- No Accessibility or Screen Recording permission, so it cannot observe your
  screen or input even if compromised.
- No file-access entitlement.

The macOS app runs in the App Sandbox with hardened runtime, holding only
`com.apple.security.network.server` and `com.apple.security.network.client`.

## Builds

There are no signed or notarised binary releases. Build from source. If you
ever see a "MotionCues.app" download offered somewhere, it did not come from
this repository.

## Scope

Reports about the local UDP listener, the packet parser, the sandbox
configuration or the entitlements are in scope. Reports that amount to "an
attacker on your local network can make the dots move" are accurate but are
documented above rather than treated as vulnerabilities.
