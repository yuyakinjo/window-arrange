import Foundation

public enum TrackpadEdge: String, CaseIterable, Sendable {
    case left, right
}

/// One notch of change produced by an edge slide. Positive means up / louder / brighter.
public struct TrackpadEdgeStep: Equatable, Sendable {
    public let edge: TrackpadEdge
    public let direction: Int

    public init(edge: TrackpadEdge, direction: Int) {
        self.edge = edge
        self.direction = direction
    }
}

/// A single contact of the trackpad, in the device's normalized coordinates.
/// `x` grows to the right and `y` grows toward the far edge, both in 0...1.
public struct TrackpadContact: Equatable, Sendable {
    public let identifier: Int
    public let x: Double
    public let y: Double

    public init(identifier: Int, x: Double, y: Double) {
        self.identifier = identifier
        self.x = x
        self.y = y
    }
}

/// A one-finger slide that starts inside a narrow strip along the left or right edge.
///
/// The finger has to land inside the strip, stay the only contact and travel a short
/// distance before the first notch, so resting a thumb or an ordinary swipe never fires.
public struct TrackpadEdgeSlide {
    public enum Phase: Equatable { case idle, waitingForLift, armed, sliding }

    /// Width of the active strip, as a fraction of the trackpad width.
    public var zoneWidth: Double = 0.09
    /// Travel needed before the first notch, as a fraction of the trackpad height.
    public var activationDistance: Double = 0.035
    /// Travel per notch after the gesture started.
    public var stepDistance: Double = 0.045
    /// How far outside the strip the finger may drift before the gesture is cancelled.
    public var releaseMargin: Double = 0.07
    /// A longer gap between frames means the stream was interrupted.
    public var maximumSampleGap: TimeInterval = 0.25
    public var enabledEdges: Set<TrackpadEdge> = [.left, .right]

    public private(set) var phase: Phase = .idle
    public private(set) var activeEdge: TrackpadEdge?

    private var identifier: Int?
    private var anchor: Double = 0
    private var activated = false
    private var previousTime: TimeInterval?

    public init() {}

    public mutating func reset() {
        phase = .idle
        activeEdge = nil
        identifier = nil
        activated = false
        previousTime = nil
    }

    /// Feeds one frame of contacts and returns the notches it produced.
    public mutating func update(contacts: [TrackpadContact], time: TimeInterval) -> [TrackpadEdgeStep] {
        guard time.isFinite else { reset(); return [] }
        if let previousTime, time < previousTime || time - previousTime > maximumSampleGap { reset() }
        previousTime = time

        guard !contacts.isEmpty else {
            // Every finger is up: a cancelled gesture may start again.
            phase = .idle
            activeEdge = nil
            identifier = nil
            activated = false
            return []
        }
        // More than one finger means scrolling, zooming or a resting palm. Never guess.
        guard contacts.count == 1 else {
            phase = .waitingForLift
            activeEdge = nil
            identifier = nil
            activated = false
            return []
        }
        guard phase != .waitingForLift else { return [] }
        let contact = contacts[0]
        guard contact.x.isFinite, contact.y.isFinite else { reset(); return [] }

        guard let identifier, identifier == contact.identifier, let edge = activeEdge else {
            return start(contact)
        }
        guard contact.x >= lowerBound(edge) - releaseMargin, contact.x <= upperBound(edge) + releaseMargin else {
            // The finger left the strip: cancel until it lifts, so it cannot re-arm mid-swipe.
            phase = .waitingForLift
            activeEdge = nil
            self.identifier = nil
            activated = false
            return []
        }
        let travel = contact.y - anchor
        if !activated {
            guard abs(travel) >= activationDistance else { return [] }
            activated = true
            phase = .sliding
            anchor = contact.y
            return [TrackpadEdgeStep(edge: edge, direction: travel > 0 ? 1 : -1)]
        }
        guard abs(travel) >= stepDistance else { return [] }
        let count = Int(abs(travel) / stepDistance)
        let direction = travel > 0 ? 1 : -1
        anchor += Double(count) * stepDistance * Double(direction)
        return Array(repeating: TrackpadEdgeStep(edge: edge, direction: direction), count: count)
    }

    private mutating func start(_ contact: TrackpadContact) -> [TrackpadEdgeStep] {
        activated = false
        activeEdge = nil
        identifier = nil
        phase = .idle
        for edge in TrackpadEdge.allCases where enabledEdges.contains(edge) {
            guard contact.x >= lowerBound(edge), contact.x <= upperBound(edge) else { continue }
            activeEdge = edge
            identifier = contact.identifier
            anchor = contact.y
            phase = .armed
            return []
        }
        // Landing outside the strip disables the gesture until the finger lifts,
        // so an ordinary swipe cannot arm it by drifting into the edge.
        phase = .waitingForLift
        return []
    }

    private func lowerBound(_ edge: TrackpadEdge) -> Double { edge == .left ? 0 : 1 - zoneWidth }
    private func upperBound(_ edge: TrackpadEdge) -> Double { edge == .left ? zoneWidth : 1 }
}
