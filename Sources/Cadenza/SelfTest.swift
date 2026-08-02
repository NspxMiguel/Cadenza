import AVFoundation
import Foundation

/// Exercises the parts of the app that have no interface of their own.
///
/// Score matching and local import are both easy to believe are working and
/// hard to check by looking: a wrong score renders just as convincingly as a
/// right one, and a file that failed to import simply is not there. Run with
/// `CADENZA_SELFTEST=1` the app reports what it actually found and exits.
enum SelfTest {
    static func run() async {
        var out = ""
        func say(_ line: String) {
            out += line + "\n"
            FileHandle.standardError.write(Data((line + "\n").utf8))
        }

        say("=== índice de partituras ===")
        let count = await ScoreService.shared.rebuildIndex()
        say("movimentos indexados: \(count)")

        say("")
        say("=== busca de partitura ===")
        // Real recording titles, in the shape Apple actually writes them. The
        // last three must fail: no public-domain engraving of them exists, and
        // answering anything at all would be answering wrongly.
        let cases: [(String, String)] = [
            ("Piano Sonata No. 14 in C-Sharp Minor, Op. 27 No. 2 \"Moonlight\": I. Adagio sostenuto", "Beethoven"),
            ("Piano Sonata No. 8 in C Minor, Op. 13 \"Pathétique\": II. Adagio cantabile", "Beethoven"),
            ("Piano Sonata No. 11 in A Major, K. 331: III. Rondo alla turca", "Mozart"),
            ("Mazurka in F-Sharp Minor, Op. 6 No. 1", "Chopin"),
            ("Prelude in E Minor, Op. 28 No. 4", "Chopin"),
            ("Keyboard Sonata in D Major, K. 514", "Scarlatti"),
            ("Erlkönig, D. 328", "Schubert"),
            ("Die Forelle, D. 550", "Schubert"),
            ("String Quartet No. 14 in C-Sharp Minor, Op. 131: I. Adagio ma non troppo", "Beethoven"),
            ("Maple Leaf Rag", "Scott Joplin"),
            ("Zelda's Lullaby (From Ocarina of Time)", "Aaron Grubb"),
            ("Skyloft (From Skyward Sword)", "Aaron Grubb"),
            ("Symphony No. 40 in G Minor, K. 550: I. Molto allegro", "Mozart"),
        ]

        for (title, artist) in cases {
            let match = await ScoreService.shared.score(
                forTrack: title, artist: artist, work: nil)
            let short = title.count > 58 ? String(title.prefix(58)) + "…" : title
            if let match {
                say("  ✓ \(short)")
                say("      → \(match.composer) — \(match.title) [\(match.format.rawValue)]")
            } else {
                say("  ✗ \(short)")
            }
        }

        // One score is fetched end to end, because an index entry pointing at a
        // dead URL looks identical to a working one until something downloads it.
        say("")
        say("=== download de uma gravura ===")
        if let match = await ScoreService.shared.score(
            forTrack: "Piano Sonata No. 14 in C-Sharp Minor, Op. 27 No. 2: I. Adagio sostenuto",
            artist: "Beethoven", work: nil),
           let contents = await ScoreService.shared.contents(for: match) {
            let kind = contents.hasPrefix("**kern") || contents.contains("**kern")
                ? "humdrum" : "musicxml"
            say("  \(match.title): \(contents.count) bytes, parece \(kind)")
        } else {
            say("  falhou")
        }

        // The whole Humdrum expansion rests on one assumption — that Verovio
        // reads `**kern` as happily as MusicXML. Believing it is not the same
        // as knowing it, so a real score is put through the real renderer and
        // asked how long it turned out to be.
        say("")
        say("=== renderização ===")
        for (title, artist) in [
            ("Piano Sonata No. 14 in C-Sharp Minor, Op. 27 No. 2: I. Adagio sostenuto", "Beethoven"),
            ("Erlkönig, D. 328", "Schubert"),
        ] {
            guard let match = await ScoreService.shared.score(
                    forTrack: title, artist: artist, work: nil),
                  let contents = await ScoreService.shared.contents(for: match) else {
                say("  não encontrei a partitura de \(title)")
                continue
            }
            let label = match.format.rawValue
            let result = await ScoreRenderProbe.render(
                contents, humdrum: match.format == .humdrum)
            say("  \(label): \(result)")
        }

        say("")
        say("=== importação local ===")
        let folder = ProcessInfo.processInfo.environment["CADENZA_SELFTEST_AUDIO"]
        if let folder {
            let library = await LocalLibrary.shared
            await library.importItems([URL(fileURLWithPath: folder)])
            let tracks = await library.tracks
            say("faixas importadas: \(tracks.count)")
            for track in tracks {
                let url = await library.url(for: track)
                let playable = url.flatMap { try? AVAudioPlayer(contentsOf: $0) } != nil
                say(String(format: "  %-22@ %6.1fs  tocável=%@",
                           (track.title as NSString),
                           track.duration,
                           playable ? "sim" : "NÃO"))
            }
            if let notice = await library.notice { say("aviso: \(notice)") }

            let grupos = await library.albums()
            say("álbuns locais: \(grupos.count)")
            for g in grupos {
                say("  \(g.name) — \(g.tracks.count) faixa(s)")
            }
        } else {
            say("  (defina CADENZA_SELFTEST_AUDIO para testar)")
        }

        say("")
        say("=== navegação ===")
        for line in await navigationCheck() { say(line) }

        say("")
        say("=== fim ===")
        try? out.write(toFile: NSTemporaryDirectory() + "cadenza-selftest.txt",
                       atomically: true, encoding: .utf8)
    }

    /// Walks the sidebar the way a click does.
    ///
    /// Selecting a row and having the page not change is invisible to every
    /// other test here: the model is fine in isolation and the screen is fine
    /// in isolation, and only the sequence shows the fault.
    @MainActor
    private static func navigationCheck() async -> [String] {
        var lines: [String] = []
        let model = AppModel()
        await model.start()
        lines.append("destinos na biblioteca: "
            + model.library.map(\.name).joined(separator: ", "))

        guard let local = model.library.first(where: { $0.path == LocalRoute.path }),
              let favourites = model.library.first(
                where: { $0.path == LibraryRoute.favouriteSongs }) else {
            lines.append("FALHA: destinos esperados não existem")
            return lines
        }

        await model.select(favourites)
        lines.append("favoritas → tela: \(model.screen?.screenType ?? "nil") "
            + "“\(model.screen?.title ?? "nil")”")

        await model.select(local)
        lines.append("locais    → tela: \(model.screen?.screenType ?? "nil") "
            + "“\(model.screen?.title ?? "nil")”")

        if model.screen?.screenType != LocalRoute.screenType {
            lines.append("FALHA: selecionar Músicas locais não trocou a tela")
        }

        // The race that produced the report: a screen that needs the network
        // is asked for, and before it lands the user picks one that needs
        // none. The slow answer must not overwrite the fast one.
        await model.select(local)
        Task { await model.select(favourites) }
        try? await Task.sleep(for: .milliseconds(20))
        await model.select(local)
        try? await Task.sleep(for: .seconds(5))
        lines.append("depois da corrida → tela: \(model.screen?.screenType ?? "nil") "
            + "“\(model.screen?.title ?? "nil")”, "
            + "barra lateral em “\(model.current?.name ?? "nil")”")
        if model.screen?.screenType != LocalRoute.screenType {
            lines.append("FALHA: a requisição lenta sobrescreveu a tela atual")
        }
        return lines
    }
}
