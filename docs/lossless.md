# Lossless and Spatial Audio

Cadenza plays at 256 kbps AAC by default, and says so next to the track. That is
not a choice — it is the ceiling of the engine a freely distributable build can
use.

## Why the default build is capped

Full-quality playback requires native MusicKit, which requires the MusicKit
entitlement, which requires a provisioning profile, which requires a paid Apple
Developer membership.

This was tested rather than assumed. With a **free** personal team:

```
Communication with Apple failed: Your team has no devices from which to
generate a provisioning profile.
No profiles for 'com.miguel.mkprobe' were found.
```

A free account cannot register a Mac as a device at all, so it never obtains a
macOS development profile, so no entitlement is honoured — MusicKit included.
Without the entitlement, catalog requests fail with `developerTokenRequestFailed`.

The WebKit engine sidesteps all of this by driving Apple's own already-authorised
player, but Apple's web playback is capped at 256 kbps AAC. Lossless and Spatial
Audio are native-app only.

## Building with lossless

If you have an Apple Developer Program membership (US$99/year), build with your
team and the app switches engines on its own:

```bash
CADENZA_TEAM=YOURTEAMID ./build.sh
```

The script then writes an entitlements file containing
`com.apple.developer.musickit` and signs with your Development identity instead
of ad-hoc.

At launch, `Playback` probes native MusicKit with a real catalog request. If it
succeeds, playback routes through `MusicKitEngine` and the badge next to the
track changes accordingly. If it fails, the app falls back to WebKit and
Settings explains why. Nothing above the `Player` protocol is aware of which
engine is running.

You can force either engine in **Settings ▸ Motor de áudio**.

## What "lossless" means here

`MusicKitEngine` reports a ceiling of Lossless + Spatial, but what actually comes
out depends on the user's Apple Music quality settings and the recording itself.
The catalog marks each album with `audioTraits`, and Cadenza shows a Lossless
badge on album headers when the recording offers it — separately from what the
current engine can deliver. Those are two different claims and the app keeps them
apart on purpose.
