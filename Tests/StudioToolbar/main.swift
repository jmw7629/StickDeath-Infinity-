import Foundation
import CoreGraphics

@main struct StudioToolbarTests {
    static var groups = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) { if !value() { fatalError(message) } }
    static func test(_ name: String, _ action: () -> Void) { action(); groups += 1; print("PASS \(name)") }
    static func contained(_ inner: CGRect, _ outer: CGRect) -> Bool {
        inner.minX >= outer.minX - 0.001 && inner.minY >= outer.minY - 0.001 && inner.maxX <= outer.maxX + 0.001 && inner.maxY <= outer.maxY + 0.001
    }
    static func main() {
        test("portrait default retains horizontal white-rail footprint") {
            let p = StudioToolbarLayout().placement(in: CGRect(x: 0, y: 0, width: 390, height: 600), compactHeight: false)
            check(!p.vertical && p.frame == CGRect(x: 8, y: 8, width: 374, height: 72), "portrait placement")
        }
        test("compact landscape default keeps tall tool list scrollable") {
            let b = CGRect(x: 0, y: 0, width: 844, height: 221)
            let p = StudioToolbarLayout().placement(in: b, compactHeight: true)
            check(p.vertical && p.dock == .leading && p.frame == CGRect(x: 8, y: 8, width: 76, height: 205), "compact placement")
        }
        test("actual release finger snaps both sides even with full-width rail") {
            let b=CGRect(x: 0, y: 0, width: 390, height: 600);var l=StudioToolbarLayout()
            l.finishDrag(release: CGPoint(x: 370, y: 230), proposedCenter: CGPoint(x: 380, y: 230), in:b)
            check(l.placement(in:b,compactHeight:false).dock == .trailing,"right snap")
            l.finishDrag(release: CGPoint(x: 20, y: 180), proposedCenter: CGPoint(x: 20, y: 180), in:b)
            check(l.placement(in:b,compactHeight:false).dock == .leading,"left snap")
        }
        test("undock into center restores horizontal orientation at chosen height") {
            let b=CGRect(x: 0, y: 0, width: 800, height: 600);var l=StudioToolbarLayout()
            l.choose(.trailing,in:b);l.finishDrag(release:CGPoint(x:400,y:300),proposedCenter:CGPoint(x:400,y:300),in:b)
            let p=l.placement(in:b,compactHeight:true)
            check(!p.vertical && p.dock == .floating && abs(p.frame.midY-300)<0.001,"undock position")
        }
        test("accessible docking changes layout without needing a drag") {
            let b=CGRect(x: 0, y: 0, width: 390, height: 600);var l=StudioToolbarLayout()
            for dock in [StudioToolbarLayout.Dock.leading,.trailing,.floating] {
                l.choose(dock,in:b); check(l.placement(in:b,compactHeight:false).dock == dock,"dock action")
            }
        }
        test("rotation preserves chosen edge and clamps toolbar without shrinking canvas bounds") {
            var l=StudioToolbarLayout(); let portrait=CGRect(x: 0,y: 0,width: 390,height: 600)
            l.choose(.trailing,in:portrait)
            for b in [portrait,CGRect(x:0,y:0,width:844,height:221),CGRect(x:0,y:0,width:1024,height:700)] {
                let p=l.placement(in:b,compactHeight:false)
                check(p.vertical && contained(p.frame,b) && abs(p.frame.maxX-(b.maxX-8))<0.001,"rotation clamp")
            }
        }
        test("transient drag does not commit placement; cancellation reuses prior state") {
            let b=CGRect(x: 0,y: 0,width: 390,height: 600), l=StudioToolbarLayout();let old=l
            let p=l.placement(in:b,compactHeight:false)
            let moved=l.draggingFrame(from:p.frame,translation:CGSize(width:400,height:1000),in:b)
            check(contained(moved,b) && l==old && moved != p.frame,"transient drag mutation")
            check(l.placement(in:b,compactHeight:false)==p,"cancelled state")
        }
        test("rotation during a drag clamps the previous drag frame immediately") {
            let l=StudioToolbarLayout(),large=CGRect(x:0,y:0,width:1024,height:900),small=CGRect(x:0,y:0,width:320,height:180)
            let initial=l.placement(in:large,compactHeight:false).frame
            check(contained(l.draggingFrame(from:initial,translation:.zero,in:small),small),"resize during drag")
        }
        test("default canvas clears the top rail and both snapped rails") {
            for size in [CGSize(width:390,height:600),CGSize(width:844,height:221),CGSize(width:1024,height:900)] {
                let b=CGRect(origin:.zero,size:size)
                for dock in [StudioToolbarLayout.Dock.automatic,.leading,.trailing] {
                    var l=StudioToolbarLayout();l.choose(dock,in:b)
                    let p=l.placement(in:b,compactHeight:size.height<500),c=StudioToolbarLayout.canvasFrame(in:b,toolbar:p)
                    check(contained(c,b) && !c.intersects(p.frame),"canvas covered by default or snapped chrome")
                    check(c.width > 80 && c.height > 80,"canvas collapsed")
                }
            }
        }
        test("one settings popup clears the rail and follows its placement") {
            for size in [CGSize(width:320,height:180),CGSize(width:390,height:600),CGSize(width:844,height:221),CGSize(width:1024,height:900)] {
                let b=CGRect(origin:.zero,size:size)
                for dock in [StudioToolbarLayout.Dock.leading,.trailing,.floating] {
                    var l=StudioToolbarLayout();l.choose(dock,in:b)
                    for y in [CGFloat(0),0.5,1] {
                        if dock == .floating { l.finishDrag(release:CGPoint(x:b.midX,y:b.height*y),proposedCenter:CGPoint(x:b.midX,y:b.height*y),in:b) }
                        let p=l.placement(in:b,compactHeight:false),d=StudioToolbarLayout.settingsFrame(in:b,toolbar:p)
                        check(contained(d,b),"popup bounds")
                        check(d.height >= 44,"reachable dismissal")
                        check(!d.intersects(p.frame),"popup overlaps rail")
                        if !p.vertical && p.frame.minY == b.minY + 8 { check(d.minY > p.frame.maxY,"popup should open below the top rail") }
                    }
                }
            }
        }
        test("HIDE recovery area is excluded from toolbar placements") {
            let b=CGRect(x:0,y:44,width:390,height:540);var l=StudioToolbarLayout()
            for dock in [StudioToolbarLayout.Dock.leading,.trailing,.floating] {
                l.choose(dock,in:b);check(l.placement(in:b,compactHeight:false).frame.minY>=52,"restore button collision")
            }
        }
        test("invalid releases cannot poison state and tiny stages stay finite") {
            var l=StudioToolbarLayout();let initial=l,b=CGRect(x:0,y:0,width:390,height:600)
            l.finishDrag(release:CGPoint(x:CGFloat.nan,y:2),proposedCenter:.zero,in:b);check(l==initial,"NaN state")
            l.finishDrag(release:.zero,proposedCenter:CGPoint(x:2,y:CGFloat.infinity),in:b);check(l==initial,"infinite state")
            for side in [CGFloat(0),1,10,44,90] {
                let tiny=CGRect(x:0,y:0,width:side,height:side),p=l.placement(in:tiny,compactHeight:true)
                check(p.frame.width.isFinite && p.frame.height.isFinite && contained(p.frame,tiny),"tiny geometry")
            }
        }
        test("bounded sweep keeps all dock orientations and drag offsets in the stage") {
            var count=0
            for width in stride(from:320,through:1400,by:120) {
                for height in stride(from:160,through:1040,by:80) {
                    let b=CGRect(x:0,y:0,width:width,height:height)
                    for dock in [StudioToolbarLayout.Dock.automatic,.leading,.trailing,.floating] {
                        var l=StudioToolbarLayout();l.choose(dock,in:b);let p=l.placement(in:b,compactHeight:height<500)
                        check(contained(p.frame,b),"placement sweep")
                        for delta in [CGSize(width:-5000,height:-5000),.zero,CGSize(width:5000,height:5000)] {
                            check(contained(l.draggingFrame(from:p.frame,translation:delta,in:b),b),"drag sweep");count+=1
                        }
                    }
                }
            }
            check(count==1440,"sweep coverage")
        }
        print("STUDIO_TOOLBAR_TESTS=PASS \(groups)/\(groups)")
    }
}
