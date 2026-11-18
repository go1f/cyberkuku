import Foundation
import CoreGraphics
import PostureCore

struct PetEdgeChecks {
    private struct Generator: RandomNumberGenerator {
        var value: UInt64
        mutating func next() -> UInt64 { value = value &* 6364136223846793005 &+ 1442695040888963407; return value }
    }
    func run() {
        for origin in [CGPoint(x:100,y:200),CGPoint(x:-1750,y:-220)] {
            let press = CGPoint(x:origin.x+17.3,y:origin.y+72.5)
            let drag = PetPointerDrag(pointer:press,origin:origin)
            for i in 0..<2000 {
                let p = CGPoint(x:press.x+Double(i%2 == 0 ? i : -i),y:press.y+Double(i%7)*41)
                let o = drag.origin(at:p)
                expectTrue(abs(p.x-o.x-17.3)<0.00001 && abs(p.y-o.y-72.5)<0.00001)
            }
        }
        for seed in 1...30 {
            var rng = Generator(value:UInt64(seed)), state = PetEdgeBehavior()
            state.fold(.right,using:&rng); state.setPaused(false,at:0,delay:30)
            var poses = [state.pose]
            for _ in 0..<299 {
                expectTrue(state.rotate(at:state.nextChange!,delay:45,using:&rng)); poses.append(state.pose)
            }
            for i in stride(from:0,to:300,by:3) { expectTrue(Set(poses[i..<i+3].map(\.rawValue)).count == 3) }
            for i in 1..<poses.count { expectTrue(poses[i] != poses[i-1]) }
            state.setPaused(true,at:20000,delay:30)
            expectTrue(state.nextChange == nil); expectFalse(state.rotate(at:50000,delay:40,using:&rng))
            state.setPaused(false,at:50000,delay:40); expectTrue(state.nextChange == 50040)
            expectTrue(state.rotate(at:90000,delay:50,using:&rng)); expectTrue(state.nextChange == 90050)
            expectFalse(state.rotate(at:90000,delay:50,using:&rng))
            state.unfold(); expectTrue(state.edge == nil && state.nextChange == nil)
        }
        for screen in [CGRect(x:0,y:0,width:1440,height:900),CGRect(x:-1920,y:-300,width:1920,height:1080)] {
            var state = PetEdgeBehavior()
            expectTrue(PetEdgeBehavior.nearestEdge(CGRect(x:screen.minX+10,y:screen.midY,width:62,height:104),area:screen) == .left)
            expectTrue(PetEdgeBehavior.nearestEdge(CGRect(x:screen.maxX-80,y:screen.midY,width:62,height:104),area:screen) == .right)
            let boundary = screen.minX+screen.width*2/3
            expectFalse(state.updateFacing(centerX:boundary,screen:screen))
            expectTrue(state.updateFacing(centerX:boundary+4,screen:screen))
            for n in [-2,0,2,-1,1] { expectTrue(state.updateFacing(centerX:boundary+Double(n),screen:screen)) }
            expectFalse(state.updateFacing(centerX:boundary-4,screen:screen))
            for side in [PetEdge.left,.right] {
                for y in [screen.minY-100,screen.midY,screen.maxY+200] {
                    let frame = PetEdgeBehavior.foldedFrame(side:side,centerY:y,area:screen)
                    expectTrue(screen.contains(frame) && frame.size == PetEdgeBehavior.foldedSize)
                    expectTrue(side == .left ? frame.minX == screen.minX : frame.maxX == screen.maxX)
                }
            }
            expectTrue(PetEdgeBehavior.coversDisplay(window:screen,screen:screen,safeTop:0))
            expectFalse(PetEdgeBehavior.coversDisplay(window:screen.insetBy(dx:0,dy:27),screen:screen,safeTop:0))
            let notched = CGRect(x:screen.minX,y:screen.minY,width:screen.width,height:screen.height-32)
            expectTrue(PetEdgeBehavior.coversDisplay(window:notched,screen:screen,safeTop:32))
            let other = screen.offsetBy(dx:screen.width,dy:0)
            expectFalse(PetEdgeBehavior.coversDisplay(window:other,screen:screen,safeTop:0))
            let near = CGRect(x:screen.minX+10,y:screen.midY,width:62.4,height:104.4)
            expectTrue(PetEdgeBehavior.nearEdge(near,area:screen) == .left)
            expectTrue(PetEdgeBehavior.nearEdge(near.offsetBy(dx:200,dy:0),area:screen) == nil)
        }
    }
}
