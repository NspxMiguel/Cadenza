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

## Where the scores come from

| Acervo | Formato | Cobre |
|---|---|---|
| OpenScore Lieder | MusicXML (CC0) | Lied alemão — e traz o texto cantado como `<lyric>` |
| OpenScore String Quartets | MusicXML (CC0) | Quartetos de cordas |
| craigsapp/beethoven-piano-sonatas | Humdrum `**kern` | As 32 sonatas, com títulos reais em `index.hmd` |
| craigsapp/mozart-piano-sonatas | Humdrum | Sonatas para piano |
| craigsapp/haydn-piano-sonatas | Humdrum | Sonatas para piano |
| craigsapp/beethoven-string-quartets | Humdrum | Quartetos |
| craigsapp/chopin-mazurkas | Humdrum | Mazurcas, títulos em `kern/.ref` |
| craigsapp/chopin-preludes | Humdrum | Op. 28 |
| craigsapp/scarlatti-keyboard-sonatas | Humdrum | Sonatas, nomeadas por número Kirkpatrick |
| craigsapp/joplin | Humdrum | Rags |

1922 movimentos no índice, contra cerca de 400 quando só havia OpenScore.

### O build do Verovio importa

O toolkit padrão — `verovio-toolkit-wasm.js` — é compilado **sem** o
importador de Humdrum. Ele não avisa: `loadData` devolve falso, a página fica
em branco e nada chega ao Swift, o que é indistinguível de um arquivo corrompido.
`verovio-toolkit-hum.js` tem o importador, e é 4 MB maior, então o app carrega
um ou outro conforme o formato da partitura.

Auto-detecção também não basta: estes arquivos começam com registros
`!!!COM:` em vez da linha `**kern`, então o formato é declarado explicitamente
com `inputFrom: 'humdrum'`.

Medido no renderizador de verdade: a *Sonata ao Luar* dá 1182 notas em 6
páginas; *Erlkönig* dá 2893 notas, **638 sílabas de letra** e 16 páginas.

### Como o casamento decide

Regra central: **compositor ou número de catálogo têm de bater**. Marcação de
andamento e tonalidade não identificam nada — são compartilhadas por milhares
de peças, e confiar nelas foi o que deu uma sonata de Beethoven para a Sinfonia
n.º 40 de Mozart (ambas "in … Minor", ambas com um movimento *Allegro*).

- Catálogos conhecidos dos dois lados que não se cruzam são **rejeição**, não
  nota baixa. K. 550 nunca recebe Op. 2 n.º 1.
- Um opus sozinho é fraco: Op. 28 é o caderno de prelúdios de Chopin e também
  dois Lieder de Josephine Lang. Só vale sem o compositor se a chave for
  específica — `op28no4`, ou uma letra de catálogo como K., D., BWV.
- Uma obra conhecida só por número ("Piano Sonata No. 11") precisa bater no
  número **e** na palavra que diz o que ela é.
- Movimento errado dentro da obra certa é penalizado: acompanha de forma
  convincente e é a música errada.

Treze títulos reais no autoteste (`CADENZA_SELFTEST=1`): dez acertam, e os três
que não têm gravura de domínio público continuam sem resposta — que é o
resultado certo.

## Reading scans with AI (beta)

Settings offers optical music recognition, run locally with `oemer` — open
source, ONNX-based, installed on demand because it pulls in large dependencies
that most users will never want.

It is worth being exact about what this does. It does **not** transcribe the
recording: transcription needs the audio samples, and FairPlay never releases
them, so a model given no audio would not be reading the music but inventing it.
What it does is read an *engraving* — an image of a printed score — and turn it
into MusicXML the app can follow. That is a different problem and a solvable one.

The caveats are shown in the interface rather than buried here: processing is
local and CPU-heavy, and recognition quality follows scan quality, so a poor
scan yields a wrong score.

Sourcing the scan automatically is not wired. IMSLP holds the scans, but its
files sit behind a download gateway, and the page images its API exposes are
cover thumbnails rather than score pages. Until that is solved the file is
chosen by hand, which is honest about what works rather than offering a button
that quietly fails.

### What the engine needs to actually run

Two things had to be true before recognition worked once, and neither is
obvious from the outside:

- **The console script, not the module.** `python3 -m oemer` fails immediately —
  the package ships no `__main__`. Every attempt died here, before any
  recognition began, which is why enabling the feature appeared to do nothing.
  The right entry point is `venv/bin/oemer`.
- **NumPy below 1.24.** The newest oemer requires `onnxruntime-gpu`, which has
  no macOS build, so pip silently resolves back to 0.1.5 — and 0.1.5 calls
  `np.int`, removed in NumPy 1.24. Installed unpinned, the engine runs its full
  inference and *then* dies on an `AttributeError`. Roughly three and a half
  minutes of CPU to reach a crash.

Measured on this machine, a 1681×1740 photograph of two piano staves:
**3 min 51 s**, producing 28 measures and 360 notes of valid MusicXML. Pitch
accuracy is imperfect — which is what beta means here — but the file is real and
Verovio renders it.

Because that cost is real, a score read for a recording is cached under
`Caches/Cadenza/scores-ai/{trackID}.musicxml` and reused. Reading the same
engraving twice would be the app spending the user's machine on work it already
did.

### Coverage, stated plainly

The open corpus is Lieder and string quartets. Film and game soundtracks are not
in it and will not be: they are not public domain, so no CC0 engraving exists to
find. For a recording like the Zelda arrangements in the classical catalog,
there is no score to fetch — only a scan the listener already has, read by the
engine above.
