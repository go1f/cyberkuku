import Foundation
import CoreGraphics
import PostureCore

struct PetChecks {
    func placement() {
        for petSize in [CGSize(width:104,height:174),PetPlacement.companionSize] {
        for area in [CGRect(x:0,y:0,width:1440,height:850), CGRect(x:-1920,y:50,width:1920,height:1030)] {
            for anchor in [CGPoint(x:area.minX,y:area.minY),CGPoint(x:area.maxX-petSize.width,y:area.maxY-petSize.height),CGPoint(x:area.midX,y:area.midY)] {
                let cat = CGRect(origin:anchor,size:petSize)
                let sizes = Array(repeating:CGSize(width:110,height:76),count:4)
                for seed in 0..<24 {
                    let frames = PetPlacement.bubbles(around:cat,sizes:sizes,in:area,seed:seed)
                    expectTrue(frames == PetPlacement.bubbles(around:cat,sizes:sizes,in:area,seed:seed))
                    expectTrue(frames.count == 4)
                    for frame in frames {
                        expectTrue(area.contains(frame))
                        expectTrue(frame.intersection(cat).isNull || frame.intersection(cat).width*frame.intersection(cat).height < 1)
                    }
                    for i in frames.indices { for j in frames.indices where i < j {
                        expectTrue(!frames[i].intersects(frames[j]))
                    } }
                }
            }
        }
        }
        let box = CGRect(x:0,y:0,width:1200,height:800)
        let cat = CGRect(x:400,y:300,width:104,height:174)
        let sizes = Array(repeating:CGSize(width:110,height:76),count:3)
        let first = PetPlacement.bubbles(around:cat,sizes:sizes,in:box,seed:4)
        let next = PetPlacement.bubbles(around:cat,sizes:Array(sizes.dropFirst()),in:box,seed:4,preferred:Array(first.dropFirst()).map { Optional($0) })
        expectTrue(next == Array(first.dropFirst()))
        let small = CGRect(origin:CGPoint(x:500,y:250),size:PetPlacement.companionSize)
        for seed in 0..<24 {
            let first = PetPlacement.bubbles(around:small,sizes:[CGSize(width:110,height:76)],in:box,seed:seed)[0]
            expectTrue(first.minY >= small.maxY)
            expectTrue(abs(first.midX-small.midX) < 40)
        }
        // Two simultaneous messages stay around the head rather than stacking far above it.
        for x in [box.minX+8,box.midX,box.maxX-PetPlacement.companionSize.width-8] {
            let pet = CGRect(origin:CGPoint(x:x,y:250),size:PetPlacement.companionSize)
            for seed in 0..<24 {
                let frames = PetPlacement.bubbles(around:pet,sizes:Array(repeating:CGSize(width:110,height:76),count:2),in:box,seed:seed)
                let head = PetPlacement.headCenter(in:pet)
                for frame in frames { expectTrue(hypot(frame.midX-head.x,frame.midY-head.y) < 145) }
                expectFalse(frames[0].intersects(frames[1]))
            }
        }
        let bounds = CGRect(x:0,y:0,width:110,height:76)
        let body = bounds.insetBy(dx:12,dy:12)
        for step in 0..<72 {
            let angle = Double(step)*Double.pi/36
            let target = CGPoint(x:bounds.midX+500*cos(angle),y:bounds.midY+500*sin(angle))
            let tip = PetPlacement.tailTip(body:body,bounds:bounds,target:target)
            let dx = tip.x-body.midX, dy = tip.y-body.midY
            expectTrue(bounds.contains(tip))
            expectTrue(abs(dx*sin(angle)-dy*cos(angle)) < 0.001)
            expectTrue(dx*cos(angle)+dy*sin(angle) > 0)
        }
        expectTrue(abs(PetPlacement.companionSize.width/104-0.6)<0.0001 && abs(PetPlacement.companionSize.height/174-0.6)<0.0001)
        let area = CGRect(x:0,y:0,width:800,height:600)
        expectTrue(area.contains(PetPlacement.clamp(CGRect(x:-200,y:800,width:104,height:174),to:area)))
    }
}
