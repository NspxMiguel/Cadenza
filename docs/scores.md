# Scores

Cadenza can show an engraved score and follow the recording through it. Nothing
like it exists in the official app on any platform.

## Why following works at all

Score following normally aligns the audio signal against the score. That route
is closed here: FairPlay never hands over the samples, by design.

The symbolic route is open. A MusicXML score carries its own timeline, and
Verovio renders it to SVG while returning a **timemap** — every note with its
onset in the score's milliseconds. Scaling that timeline onto the track's real
duration gives a follow that never touches the audio.

The assumption is that the performance keeps the score's proportions. That
holds in steady tempo and drifts under rubato, so the panel offers a manual
offset rather than pretending to be exact.

## Where the scores come from

[OpenScore](https://github.com/OpenScore), released CC0 — the Lieder corpus
(1462 scores across 127 composers) and the string quartets.

Coverage is narrow, and deliberately so for now. It also lands where it is most
useful: **in art song the MusicXML carries the sung text as `<lyric>` elements**,
so the words are engraved under the notes, from the same file, already aligned.
That is a better answer than fetching lyrics separately and hoping the two agree.

IMSLP has vastly more music — 230k works — but as page scans. An image does not
know where bar 47 is, so it can be displayed and paged by hand, never followed.
That is the second tier, still to be built.

## Matching

A score is chosen from composer surname plus movement or work title, and the
matcher is intentionally conservative: showing the wrong score would look like
following while displaying different music, which is worse than showing none.

Movement folders are prefixed with their order — `13_Die_Post` — and that number
never appears in a track title, so it is stripped before comparison. Missing
that is why the first matching pass found nothing at all.
