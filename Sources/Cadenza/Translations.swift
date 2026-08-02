import Foundation
import Observation

/// Holds translated lyric lines.
///
/// It exists as a reference type so the translation closure can capture it
/// without capturing the view. Capturing the view makes the closure
/// main-actor-isolated, and the translation session is then sent across an
/// isolation boundary it is not built to cross — which the compiler rejects.
@MainActor
@Observable
final class Translations {
    private(set) var byLine: [UUID: String] = [:]

    func reset() { byLine = [:] }

    /// Applied in one go. Touching the main actor between translations would
    /// make the enclosing closure hop isolation mid-loop, which is precisely
    /// what the session cannot survive.
    func apply(_ pairs: [(UUID, String)]) {
        for (id, text) in pairs { byLine[id] = text }
    }

    subscript(id: UUID) -> String? { byLine[id] }
}
