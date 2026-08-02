import Foundation

/// One timed line of a lyric.
struct LyricLine: Identifiable {
    let id = UUID()
    let start: TimeInterval
    let end: TimeInterval
    let text: String

    func contains(_ time: TimeInterval) -> Bool { time >= start && time < end }
}

/// Fetches and parses Apple's timed lyrics.
///
/// The endpoint answers with TTML carrying per-line and often per-word timings.
/// It is reachable with the credentials we already hold — verified against a
/// pop track — but most of the classical catalog simply has no lyrics, and
/// answers 404. That is a gap in Apple's data, not a failure to handle.
actor LyricsService {
    static let shared = LyricsService()

    private var cache: [String: [LyricLine]] = [:]

    func lyrics(forTrack id: String) async -> [LyricLine] {
        if let cached = cache[id] { return cached }
        guard let creds = TokenStore.shared.credentials else { return [] }

        let path = "https://amp-api.music.apple.com/v1/catalog/"
            + "\(creds.storefront)/songs/\(id)/lyrics"
        guard let url = URL(string: path) else { return [] }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(creds.developerToken)", forHTTPHeaderField: "Authorization")
        request.setValue(creds.musicUserToken, forHTTPHeaderField: "Music-User-Token")
        request.setValue("https://music.apple.com", forHTTPHeaderField: "Origin")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let payload = try? JSONDecoder().decode(LyricsResponse.self, from: data),
              let ttml = payload.data.first?.attributes.ttml
        else {
            cache[id] = []
            return []
        }

        let lines = TTMLParser.parse(ttml)
        cache[id] = lines
        return lines
    }
}

private struct LyricsResponse: Decodable {
    struct Entry: Decodable {
        struct Attributes: Decodable { let ttml: String? }
        let attributes: Attributes
    }
    let data: [Entry]
}

/// Pulls timed lines out of Apple's TTML.
enum TTMLParser {
    static func parse(_ ttml: String) -> [LyricLine] {
        let delegate = Delegate()
        let parser = XMLParser(data: Data(ttml.utf8))
        parser.delegate = delegate
        parser.parse()
        return delegate.lines.filter { !$0.text.isEmpty }
    }

    /// `begin`/`end` appear either as seconds (`12.345s`) or as a clock value
    /// (`00:01:23.456`), so both are accepted.
    static func seconds(_ value: String?) -> TimeInterval {
        guard let value, !value.isEmpty else { return 0 }
        let trimmed = value.hasSuffix("s") ? String(value.dropLast()) : value
        if !trimmed.contains(":") { return TimeInterval(trimmed) ?? 0 }

        return trimmed.split(separator: ":")
            .compactMap { TimeInterval($0) }
            .reduce(0) { $0 * 60 + $1 }
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var lines: [LyricLine] = []
        private var start: TimeInterval = 0
        private var end: TimeInterval = 0
        private var buffer = ""
        private var depth = 0

        func parser(_ parser: XMLParser, didStartElement element: String,
                    namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            guard element == "p" else { return }
            depth += 1
            start = TTMLParser.seconds(attributes["begin"])
            end = TTMLParser.seconds(attributes["end"])
            buffer = ""
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard depth > 0 else { return }
            buffer += string
        }

        func parser(_ parser: XMLParser, didEndElement element: String,
                    namespaceURI: String?, qualifiedName: String?) {
            guard element == "p", depth > 0 else { return }
            depth -= 1
            let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            lines.append(LyricLine(start: start, end: end > start ? end : start + 4, text: text))
            buffer = ""
        }
    }
}
