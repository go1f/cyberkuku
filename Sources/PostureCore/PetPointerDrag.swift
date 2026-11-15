import Foundation
import CoreGraphics

/// The grab offset is captured once. Event coalescing and intermediate window
/// corrections never accumulate into the next position.
public struct PetPointerDrag {
    public let offset: CGPoint
    public init(pointer: CGPoint, origin: CGPoint) { offset = CGPoint(x:pointer.x-origin.x,y:pointer.y-origin.y) }
    public func origin(at pointer: CGPoint) -> CGPoint { CGPoint(x:pointer.x-offset.x,y:pointer.y-offset.y) }
}
