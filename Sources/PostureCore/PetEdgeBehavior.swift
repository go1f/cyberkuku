import Foundation
import CoreGraphics

public enum PetEdge: String, Codable, Sendable { case left, right }
public enum PetEdgePose: Int, CaseIterable, Sendable { case hand, face, ears }

/// Appearance state only. It has no access to monitoring or dismissal timers.
public struct PetEdgeBehavior {
    public private(set) var edge: PetEdge?
    public private(set) var pose: PetEdgePose = .hand
    public private(set) var nextChange: Double?
    public private(set) var mirrored = false
    private var bag: [PetEdgePose] = []
    private var previous: PetEdgePose?
    private var paused = true
    public init() {}
    public mutating func nextPose<R: RandomNumberGenerator>(using rng: inout R) -> PetEdgePose {
        if bag.isEmpty {
            bag = PetEdgePose.allCases.shuffled(using: &rng)
            if bag.last == previous, let i = bag.firstIndex(where: { $0 != previous }) { bag.swapAt(i, bag.count-1) }
        }
        let value = bag.removeLast(); previous = value; return value
    }
    public mutating func fold<R: RandomNumberGenerator>(_ side: PetEdge, using rng: inout R) {
        edge = side; pose = nextPose(using: &rng); nextChange = nil; paused = true
    }
    public mutating func unfold() { edge = nil; nextChange = nil; paused = true }
    public mutating func setPaused(_ value: Bool, at now: Double, delay: Double) {
        let value = value || edge == nil
        guard value != paused else { return }
        paused = value; nextChange = value ? nil : now + delay
    }
    public mutating func rotate<R: RandomNumberGenerator>(at now: Double, delay: Double, using rng: inout R) -> Bool {
        guard !paused, let nextChange, now >= nextChange else { return false }
        pose = nextPose(using: &rng); self.nextChange = now + delay; return true
    }
    /// A six-point hysteresis band keeps slow drags from repeatedly turning the cat.
    @discardableResult public mutating func updateFacing(centerX: Double, screen: CGRect) -> Bool {
        let boundary = screen.minX + screen.width*2/3
        if !mirrored && centerX > boundary+3 { mirrored = true }
        else if mirrored && centerX < boundary-3 { mirrored = false }
        return mirrored
    }
    public static func nearestEdge(_ frame: CGRect,area: CGRect) -> PetEdge {
        frame.midX-area.minX <= area.maxX-frame.midX ? .left : .right
    }
    public static func nearEdge(_ frame: CGRect, area: CGRect, threshold: Double = 14) -> PetEdge? {
        if frame.minX <= area.minX+threshold { return .left }
        if frame.maxX >= area.maxX-threshold { return .right }
        return nil
    }
    public static func foldedFrame(side: PetEdge, centerY: Double, area: CGRect) -> CGRect {
        CGRect(x: side == .left ? area.minX : area.maxX-44,
               y: min(max(centerY-22,area.minY+8),area.maxY-52),width:44,height:44)
    }
    /// Full-display coverage is checked independently for each display, including its notch.
    public static func coversDisplay(window: CGRect, screen: CGRect, safeTop: Double) -> Bool {
        abs(window.minX-screen.minX)<=2 && abs(window.maxX-screen.maxX)<=2 && abs(window.minY-screen.minY)<=2
            && window.maxY >= screen.maxY-safeTop-2 && window.maxY <= screen.maxY+2
    }
}
