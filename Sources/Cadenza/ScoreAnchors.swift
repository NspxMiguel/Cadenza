import Foundation
import Observation

/// Calibration points tying a moment in the recording to a moment in the score.
///
/// Following by proportion alone assumes the performance keeps the score's own
/// pacing. Real performances do not: rubato, a held fermata, a repeat taken or
/// dropped, or simply a different edition all push the two timelines apart, and
/// the drift accumulates.
///
/// Aligning audio to score automatically is out of reach here — FairPlay never
/// releases the samples — so the correction comes from the listener. Clicking a
/// note when it sounds records one pair, and between pairs the mapping is
/// linear. Two or three well-placed clicks are usually enough for a whole
/// movement, and they are remembered per recording.
@MainActor
@Observable
final class ScoreAnchors {
    static let shared = ScoreAnchors()

    struct Anchor: Codable, Equatable {
        /// Seconds into the recording.
        let real: TimeInterval
        /// Milliseconds into the score's own timeline, as Verovio reports it.
        let score: Double
    }

    private(set) var anchors: [Anchor] = []
    private var trackID: String?

    // MARK: Lifecycle

    func load(for trackID: String) {
        guard trackID != self.trackID else { return }
        self.trackID = trackID
        anchors = Self.stored(for: trackID)
    }

    func add(real: TimeInterval, score: Double) {
        guard let trackID else { return }
        // One anchor per moment: clicking again near the same place corrects it
        // rather than piling up contradictory pairs.
        anchors.removeAll { abs($0.real - real) < 1.5 }
        anchors.append(Anchor(real: real, score: score))
        anchors.sort { $0.real < $1.real }
        Self.store(anchors, for: trackID)
    }

    func clear() {
        anchors = []
        if let trackID { Self.store([], for: trackID) }
    }

    // MARK: Mapping

    /// Where in the score the recording currently is.
    ///
    /// With no anchors this is the plain proportional mapping. Each anchor
    /// pins the curve to a known point, and the segments between them are
    /// interpolated; beyond the outermost anchors the surrounding slope is
    /// extended rather than snapping back to proportion.
    func scorePosition(forReal real: TimeInterval,
                       duration: TimeInterval,
                       scoreEnd: Double) -> Double {
        guard duration > 0, scoreEnd > 0 else { return 0 }
        let proportional = (real / duration) * scoreEnd
        guard !anchors.isEmpty else { return proportional }

        if anchors.count == 1, let only = anchors.first {
            // A single point shifts the whole mapping without changing its pace.
            return max(0, proportional + (only.score - (only.real / duration) * scoreEnd))
        }

        if let first = anchors.first, real <= first.real {
            let next = anchors[1]
            return interpolate(real, from: first, to: next)
        }
        if let last = anchors.last, real >= last.real {
            let previous = anchors[anchors.count - 2]
            return interpolate(real, from: previous, to: last)
        }
        for index in 0..<(anchors.count - 1) where
            real >= anchors[index].real && real <= anchors[index + 1].real {
            return interpolate(real, from: anchors[index], to: anchors[index + 1])
        }
        return proportional
    }

    private func interpolate(_ real: TimeInterval, from a: Anchor, to b: Anchor) -> Double {
        let span = b.real - a.real
        guard span > 0.001 else { return a.score }
        let ratio = (real - a.real) / span
        return max(0, a.score + ratio * (b.score - a.score))
    }

    // MARK: Storage

    private static func key(_ trackID: String) -> String { "cadenza.anchors." + trackID }

    private static func stored(for trackID: String) -> [Anchor] {
        guard let data = UserDefaults.standard.data(forKey: key(trackID)),
              let decoded = try? JSONDecoder().decode([Anchor].self, from: data)
        else { return [] }
        return decoded
    }

    private static func store(_ anchors: [Anchor], for trackID: String) {
        guard let data = try? JSONEncoder().encode(anchors) else { return }
        UserDefaults.standard.set(data, forKey: key(trackID))
    }
}
