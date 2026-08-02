# Cadenza

A native macOS client for **Apple Music Classical**, which Apple never shipped for the Mac.

Built in the spirit of [Cider](https://cider.sh): the web layer is used only as a
playback engine, and everything the user sees is native.

## Why

Apple Music Classical exists on iOS, iPadOS, Android and the web — but not as a Mac
app. Sideloading the iPad IPA gives you a window locked to portrait that cannot be
resized. The official web player works, but it is a browser tab pretending to be an app.

## How it works

Playback of full tracks requires FairPlay, and FairPlay decryption cannot leave
WebKit — there is no supported path to raw audio. So Cadenza does what Cider does:

- **Engine** — a `WKWebView` hosting Apple's player handles FairPlay decode and
  playback. It is driven over a JS bridge and is not the user interface.
- **Data** — a native Swift client calls the classical catalog API directly
  (`classical.music.apple.com/api/classical/v10/query/*`), using the developer token
  the page already ships with. No paid Apple Developer account is required.
- **UI** — SwiftUI, built around how classical music is actually organised:
  work, movement, recording, composer, performer.

### Verified

- FairPlay EME is granted inside `WKWebView`; full-length tracks decrypt and play.
  (Widevine is refused, which is expected — WebKit has never implemented it.)
- The developer token is served by Apple's own page.

## Status

Early. The current build is the instrumented shell used to prove the above and to
map the API surface.

## Caveats

The `v10` endpoints are private and undocumented. They carry no compatibility
guarantee and will break when Apple changes them; the data layer is kept isolated so
that breakage stays cheap to repair. This is a personal-use client.

## Build

No Xcode required — Command Line Tools are enough.

```bash
./build.sh
open build/Cadenza.app
```
