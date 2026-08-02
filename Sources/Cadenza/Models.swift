import Foundation

// MARK: - Decoding helpers

/// Arrays decode leniently so one unrecognised entry cannot empty a whole
/// screen — but a failure that vanishes silently is how an empty list gets
/// mistaken for "the server sent nothing". This reports what it swallowed.
func lenientArray<T: Decodable, K: CodingKey>(
    _ type: T.Type, from container: KeyedDecodingContainer<K>,
    forKey key: K, context: String
) -> [T] {
    do {
        return try container.decodeIfPresent([T].self, forKey: key) ?? []
    } catch {
        FileHandle.standardError.write(
            Data("[Cadenza] \(context): falha ao decodificar [\(T.self)] — \(error)\n".utf8))
        return []
    }
}

// MARK: - Domain
//
// Split out so the decoder can be exercised against real payloads without
// dragging in credentials or the network.

/// The API returns a server-driven UI tree rather than plain resources, so the
/// model mirrors that shape. It is deliberately permissive: this is a private
/// API, and a decoder that rejects an unrecognised `type` would turn any change
/// Apple makes into a crash instead of a gap.
struct Screen: Decodable {
    let screenType: String?
    let title: String?
    let publicUrl: String?
    let sections: [ScreenSection]
    let firstPage: Page?

    enum CodingKeys: String, CodingKey { case screenType, title, publicUrl, sections, firstPage }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        screenType = try c.decodeIfPresent(String.self, forKey: .screenType)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        publicUrl = try c.decodeIfPresent(String.self, forKey: .publicUrl)
        sections = lenientArray(ScreenSection.self, from: c, forKey: .sections, context: "Screen.sections")
        firstPage = try? c.decodeIfPresent(Page.self, forKey: .firstPage)
    }

    /// Every item on the screen, flattened — most views want this, not the
    /// section/component nesting the server happens to use for layout.
    var allItems: [Item] { sections.flatMap { $0.components.flatMap(\.items) } }
}

/// List screens — playlists, albums, library views — answer with `firstPage`
/// instead of `sections`. The same field carries both a populated list and an
/// empty state, distinguished by whether `items` has anything in it.
struct Page: Decodable {
    let type: String?
    let heading: String?
    let description: String?
    let icon: String?
    let items: [Item]
    /// Row titles arrive first; durations and performer credits need a second
    /// request to this path.
    let tracksMetadataUrl: String?

    enum CodingKeys: String, CodingKey {
        case type, heading, description, icon, items, tracksMetadataUrl
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decodeIfPresent(String.self, forKey: .type)
        heading = try c.decodeIfPresent(String.self, forKey: .heading)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        items = lenientArray(Item.self, from: c, forKey: .items, context: "items")
        tracksMetadataUrl = try c.decodeIfPresent(String.self, forKey: .tracksMetadataUrl)
    }

    var isEmptyState: Bool { items.isEmpty }
}

struct ScreenSection: Decodable {
    let type: String?
    let priority: String?
    let components: [Component]

    enum CodingKeys: String, CodingKey { case type, priority, components }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decodeIfPresent(String.self, forKey: .type)
        priority = try c.decodeIfPresent(String.self, forKey: .priority)
        components = lenientArray(Component.self, from: c, forKey: .components, context: "Section.components")
    }
}

struct Component: Decodable {
    let type: String?
    let itemType: String?
    /// Shelves label themselves with `heading`, not `title`.
    let heading: String?
    let displayStyle: String?
    let emphasize: Bool?
    let items: [Item]

    enum CodingKeys: String, CodingKey {
        case type, itemType, heading, displayStyle, emphasize, items
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decodeIfPresent(String.self, forKey: .type)
        itemType = try c.decodeIfPresent(String.self, forKey: .itemType)
        heading = try c.decodeIfPresent(String.self, forKey: .heading)
        displayStyle = try c.decodeIfPresent(String.self, forKey: .displayStyle)
        emphasize = try c.decodeIfPresent(Bool.self, forKey: .emphasize)
        items = lenientArray(Item.self, from: c, forKey: .items, context: "items")
    }
}

struct Item: Decodable, Identifiable {
    /// Local identity for SwiftUI. The catalog's own identifier is `catalogID`,
    /// which is absent on editorial and heading rows.
    let id = UUID()
    let catalogID: String?

    /// `track`, `subheading`, `album`, `playlist`, `work`, `artist`, `recording`…
    /// A `subheading` is a work title standing above the movements that follow,
    /// not a playable row.
    let type: String?
    let title: String?
    /// Secondary line on shelf tiles.
    let addition: String?
    /// Secondary line on track rows — usually the performers.
    let subtitle: String?
    /// An object, not a string: the work this track belongs to, repeated on
    /// every movement so a row knows its parent without walking the list.
    let workSubheading: WorkRef?
    let durationMs: Int?
    let inLibrary: Bool?
    let inFavorites: Bool?
    let image: Artwork?
    let action: Action?

    enum CodingKeys: String, CodingKey {
        case catalogID = "id"
        case type, title, addition, subtitle, workSubheading
        case durationMs, inLibrary, inFavorites, image, action
    }

    var isTrack: Bool { type == "track" }
    var isHeading: Bool { type == "subheading" }

    var duration: String? {
        guard let ms = durationMs, ms > 0 else { return nil }
        let total = ms / 1000
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// The work a track belongs to.
struct WorkRef: Decodable {
    let type: String?
    let title: String?
    let action: Action?
}

struct Artwork: Decodable {
    let url: String?

    /// Artwork URLs are templates with `{w}`, `{h}` and `{f}` placeholders.
    func url(size: Int) -> URL? {
        guard let url else { return nil }
        return URL(string: url
            .replacingOccurrences(of: "{w}", with: String(size))
            .replacingOccurrences(of: "{h}", with: String(size))
            .replacingOccurrences(of: "{f}", with: "jpg")
            .replacingOccurrences(of: "{c}", with: "bb"))
    }
}

/// Navigation is data: an action carries the path of the screen it leads to.
struct Action: Decodable {
    let type: String?
    let screenType: String?
    let url: String?
}
