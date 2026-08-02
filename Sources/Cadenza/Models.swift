import Foundation

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
    let sections: [Section]

    enum CodingKeys: String, CodingKey { case screenType, title, publicUrl, sections }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        screenType = try c.decodeIfPresent(String.self, forKey: .screenType)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        publicUrl = try c.decodeIfPresent(String.self, forKey: .publicUrl)
        sections = (try? c.decodeIfPresent([Section].self, forKey: .sections)) as? [Section] ?? []
    }

    /// Every item on the screen, flattened — most views want this, not the
    /// section/component nesting the server happens to use for layout.
    var allItems: [Item] { sections.flatMap { $0.components.flatMap(\.items) } }
}

struct Section: Decodable {
    let type: String?
    let priority: String?
    let components: [Component]

    enum CodingKeys: String, CodingKey { case type, priority, components }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decodeIfPresent(String.self, forKey: .type)
        priority = try c.decodeIfPresent(String.self, forKey: .priority)
        components = (try? c.decodeIfPresent([Component].self, forKey: .components)) as? [Component] ?? []
    }
}

struct Component: Decodable {
    let type: String?
    let itemType: String?
    let title: String?
    let items: [Item]

    enum CodingKeys: String, CodingKey { case type, itemType, title, items }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decodeIfPresent(String.self, forKey: .type)
        itemType = try c.decodeIfPresent(String.self, forKey: .itemType)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        items = (try? c.decodeIfPresent([Item].self, forKey: .items)) as? [Item] ?? []
    }
}

struct Item: Decodable, Identifiable {
    let id = UUID()
    let type: String?
    let title: String?
    /// Secondary line — the API calls it `addition`.
    let addition: String?
    let image: Artwork?
    let action: Action?

    enum CodingKeys: String, CodingKey { case type, title, addition, image, action }
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
