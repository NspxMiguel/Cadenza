# The classical catalog API

Notes on `classical.music.apple.com/api/classical/v10/query/*`, recovered by
recording what the official web player does. Private and undocumented — nothing
here carries a compatibility guarantee.

## Credentials

Two are needed, and they come from different places:

| Credential | Where it lives | How to read it |
|---|---|---|
| Developer token | `devToken` query param on the page URL / commerce iframe | injected script |
| Music-User-Token | `media-user-token` cookie, **HttpOnly** | native `WKHTTPCookieStore` |

The developer token is Apple's own and ships with the page, so no paid Apple
Developer account is involved. The user token is only present once signed in.

Because the cookie is HttpOnly, JavaScript cannot see it — reading it from the
page will always fail, and it has to be pulled from the cookie store natively.

## Request shape

```
GET /api/classical/v10/query/view/{storefront}/{screen}
Authorization: Bearer {developerToken}
Music-User-Token: {musicUserToken}
Origin: https://classical.music.apple.com
```

Storefront comes from the `itua` cookie (e.g. `br`).

## Known endpoints

| Path | Purpose |
|---|---|
| `view/{sf}/listen-now` | home feed |
| `view/{sf}//recently-added` | library, recently added (note the doubled slash) |
| `view/{sf}/favorites/playlists` | saved playlists |
| `tracksMetadata/{sf}` | track detail |
| `tracksMetadata/{sf}/track/{id}/menu` | context menu for a track |
| `playAction/{sf}` | resolve what to play |
| `context-menu/{sf}` | context menu payloads |
| `user-components/{sf}` | per-user UI fragments |

Albums and the account also go through the standard Apple Music API at
`amp-api.music.apple.com/v1/catalog/{sf}/albums` and `/v1/me/account`.

## Response shape

Server-driven UI. A screen is a tree:

```
{ screenType, type, title, header, sections: [
    { priority, type, components: [
        { type: "shelf", itemType, items: [
            { type, title, addition, image: { url },
              action: { type, screenType, url } } ] } ] } ] }
```

Observed section types: `contentful-shelf`, `recommended-shelf`, `featured-shelf`,
`recently-played-shelf`, `subscriptionBanner`.

Navigation is data: `action.url` is the next `/query/view/...` path to fetch. A
native client can render the tree and follow actions without hardcoding screens.

## Recording more

`PerformanceObserver` on `resource` entries is the only reliable way to observe
this traffic. Wrapping `fetch`/`XMLHttpRequest` in the page misses nearly
everything, because the player routes calls through a
`includes/commerce/fetch-proxy.html` iframe.

## Audio quality

Album screens carry an `audioTraits` array, e.g. `["lossless", "lossy-stereo"]`,
alongside an `appleDigitalMasters` badge item. So the catalog knows which
recordings are lossless and a client can surface that.

Delivering it is another matter. Apple's **web player is capped at 256 kbps AAC** —
lossless, Hi-Res and Spatial Audio are native-app only. The manifest observed
during playback (`mzaf_*.cphq.aac.wa.m3u8`) is consistent with that cap.

This is a hard ceiling on any WebKit-hosted engine, Cider included. Classical
tracks are ordinary Apple Music catalog tracks, so the way past it is to browse
with `v10` and play with native MusicKit (`ApplicationMusicPlayer`), which
requires the MusicKit capability and therefore a paid developer account.

## Routes found in the iOS binary

Not reachable by crawling, but present in `ClassicalCore`/`ClassicalApi`:

`query/view/browse`, `query/view/browse-search`, `query/view/favorites`,
`query/default-playable/`, `query/promo-config`, `query/appIntegrityChallenge`.

That last one is an attestation endpoint. It is not currently enforced on the
endpoints used here — they answer 200 without it — but it is a standing risk.
