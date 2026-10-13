import Foundation
import SwiftUI
import AppKit
import AVFoundation
import ImageIO

typealias UIImage = NSImage
extension Image { init(uiImage: NSImage) { self.init(nsImage: uiImage) } }
enum SessionFailure: Error { case failed(String) }
@main @MainActor struct SessionTests {
    static func require(_ value: @autoclosure () throws -> Bool, _ text: String) throws {
        if try !value() { throw SessionFailure.failed(text) }
    }
    static func rejected(_ operation: () throws -> Void) throws {
        do { try operation() } catch { return }
        throw SessionFailure.failed("Rejected input accepted")
    }
    static func pixels(_ vm: StudioViewModel) throws -> StudioSmudge.Pixels {
        try StudioSmudgeReplay.pixels(StudioExportService().render(vm.currentFrame, document: vm.document,
            background: .transparent, raster: nil))
    }
    static func input(_ vm: StudioViewModel, end: Double = 42.5) throws -> StudioSmudgeInput {
        guard let context = StudioSmudgeContext.current(vm) else { throw SessionFailure.failed("Context unavailable") }
        let layout = StudioSmudgeInput.Layout(viewport: CGSize(width: context.width, height: context.height), scale: 1, offset: .zero)
        var input = StudioSmudgeInput(context: context, layout: layout)
        try input.append(CGPoint(x:20.5,y:16.5),current:context,layout:layout,foreground:true)
        try input.append(CGPoint(x:end,y:16.5),current:context,layout:layout,foreground:true)
        return input
    }
    static func main() async throws {
        setbuf(stdout,nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sdi-smudge-session-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let storage = DeviceStorageManager(documentsDirectory:root.appendingPathComponent("Documents"),cachesDirectory:root.appendingPathComponent("Caches"))
        let vm = StudioViewModel(storage:storage)
        let created = await vm.createProject(name:"Gesture session",width:64,height:32,fps:12)
        try require(created,"Real project create failed")
        let red = DrawnElement(id:"red",tool:.rectangle,points:[.init(x:4,y:4),.init(x:24,y:28)],
            color:"#FF0000",width:1,opacity:1,layerID:vm.activeLayerID,shape:.init(fillColor:"#FF0000"))
        try require(vm.commitElement(red),"Real source draw failed")
        vm.selectedTool = .smudge;vm.strokeWidth = 16;vm.strokeOpacity = 1
        vm.strokeColor = .blue
        let original = vm.document, before = try pixels(vm), drag = try input(vm)
        let session = StudioSmudgeSession()
        let applied = await session.apply(vm,input:drag)
        try require(applied && !session.isApplying && vm.activeStrokeID == nil,"Atomic session failed or ownership leaked")
        try require(vm.currentFrame.elements.count == 2 && vm.currentFrame.elements[0] == red && vm.currentFrame.elements[1].smudge != nil,
            "Session flattened original or did not save canonical descriptor")
        let after = try pixels(vm)
        let expected = try StudioSmudge.apply(to:before,path:drag.points,settings:drag.context.settings)
        try require(zip(after.rgba,expected.rgba).allSatisfy { abs(Int($0)-Int($1)) <= 1 },"Committed output differs from actual color drag")
        try require(after.rgba[(16*64+26)*4] > 0 && after.rgba[(16*64+26)*4+2] == 0,"Smudge failed to pull red or painted blue")
        print("PASS asynchronous session commits editable color dragging through real production view model")
        let autosaveDeadline = Date().addingTimeInterval(4)
        while vm.isDirty && Date() < autosaveDeadline { try await Task.sleep(nanoseconds: 50_000_000) }
        try require(!vm.isDirty, "Actual Smudge autosave stayed dirty: " + (vm.message ?? "no message"))
        let autoOpened = StudioViewModel(storage: storage)
        await autoOpened.loadProjects()
        guard let autoProject = autoOpened.savedProjects.first(where: { $0.id == vm.document.id }) else { throw SessionFailure.failed("Autosaved project missing") }
        let autoResult = await autoOpened.openProject(autoProject)
        try require(autoResult && autoOpened.document == vm.document, "Autosave did not persist exact editable Smudge document")
        print("PASS real autosave persists Smudge without cancelling its own validation task")

        vm.undo();try require(vm.document.frames == original.frames && (try pixels(vm)) == before,"Undo did not restore original")
        vm.redo();try require((try pixels(vm)) == after,"Redo lost output")
        let snapshot = vm.document
        let saved = await vm.save();try require(saved,"Actual storage save failed")
        await vm.backToProjects()
        let reopened = StudioViewModel(storage:storage)
        let opened = await reopened.openProject(vm.savedProjects[0]);try require(opened,"Reopen failed")
        try require(reopened.document == snapshot && (try pixels(reopened)) == after,"Cold reopen lost editable operation")
        print("PASS actual Undo Redo save and cold reopen preserve committed gesture and pixels")
        reopened.selectedTool = .smudge;reopened.strokeWidth = 16;reopened.strokeOpacity = 1
        let unchanged = reopened.document
        let stale = try input(reopened)
        reopened.strokeWidth = 20
        let staleResult = await session.apply(reopened,input:stale)
        try require(!staleResult && reopened.document == unchanged && reopened.activeStrokeID == nil,"Stale settings committed or leaked ownership")
        reopened.strokeWidth = 16
        var cancelled = try input(reopened);cancelled.cancel()
        let cancelledResult = await session.apply(reopened,input:cancelled)
        try require(!cancelledResult && reopened.document == unchanged,"Cancelled input committed")
        let pending = try input(reopened)
        let parent = Task { @MainActor in await session.apply(reopened,input:pending) };parent.cancel()
        let parentResult = await parent.value
        try require(!parentResult && reopened.document == unchanged && !session.isApplying,"Parent cancellation committed")
        print("PASS stale settings latched input cancellation and cancelled parent task preserve document")
        var moved = try input(reopened)
        let layout = moved.layout
        try rejected { try moved.append(.init(x:40,y:16),current:moved.context,
            layout:.init(viewport:layout.viewport,scale:2,offset:.zero),foreground:true) }
        try rejected { try moved.append(.init(x:40,y:16),current:moved.context,layout:layout,foreground:true) }
        var background = try input(reopened)
        try rejected { try background.append(.init(x:40,y:16),current:background.context,layout:layout,foreground:false) }
        var outside = try input(reopened)
        try rejected { try outside.append(.init(x:65,y:16),current:outside.context,layout:layout,foreground:true) }
        print("PASS viewport background and out-of-bounds changes cancel rather than revive or clamp a drag")
        var bounded = StudioSmudgeInput(context:pending.context,layout:pending.layout)
        for n in 0..<StudioSmudge.maximumPoints {
            try bounded.append(.init(x:n % 2 + 20,y:16),current:bounded.context,layout:bounded.layout,foreground:true)
        }
        try rejected { try bounded.append(.init(x:22,y:16),current:bounded.context,layout:bounded.layout,foreground:true) }
        try require(bounded.isCancelled && bounded.points.count == StudioSmudge.maximumPoints,"Input allocation was not bounded")
        var single = StudioSmudgeInput(context:pending.context,layout:pending.layout)
        try single.append(.init(x:20,y:16),current:single.context,layout:single.layout,foreground:true)
        let noChange = await session.apply(reopened,input:single)
        try require(!noChange && reopened.document == unchanged && reopened.activeStrokeID == nil,"No-op tap created history or ownership leaked")
        print("PASS sample budget and no-op stroke preserve history and release edit ownership")
        let large = StudioViewModel(storage:storage)
        let largeCreated = await large.createProject(name:"Cancellation",width:1024,height:512,fps:12)
        try require(largeCreated,"Large real project create failed")
        let block = DrawnElement(id:"block",tool:.rectangle,points:[.init(x:2,y:2),.init(x:512,y:510)],
            color:"#FF0000",width:1,opacity:1,layerID:large.activeLayerID,shape:.init(fillColor:"#FF0000"))
        try require(large.commitElement(block),"Large source commit failed")
        large.selectedTool = .smudge;large.strokeWidth = 128;large.strokeOpacity = 1
        let context = StudioSmudgeContext.current(large)!
        let largeLayout = StudioSmudgeInput.Layout(viewport:.init(width:1024,height:512),scale:1,offset:.zero)
        var longDrag = StudioSmudgeInput(context:context,layout:largeLayout)
        for n in 0..<9 { try longDrag.append(.init(x:n % 2 == 0 ? 20 : 900,y:256),current:context,layout:largeLayout,foreground:true) }
        let largeBefore = large.document
        var finished = false
        let task = Task { @MainActor in
            let result = await session.apply(large,input:longDrag);finished = true;return result
        }
        for _ in 0..<10000 {
            if session.isApplying || finished { break };await Task.yield()
        }
        try require(session.isApplying && !finished,"Could not observe real in-flight pixel operation")
        let overlapping = await session.apply(large,input:longDrag)
        try require(!overlapping && large.activeStrokeID != nil,"Overlapping session stole active ownership")
        session.cancel()
        let appliedCancelled = await task.value
        try require(!appliedCancelled && !session.isApplying && large.activeStrokeID == nil && large.document == largeBefore,
            "In-flight cancellation committed partial pixels or leaked edit ownership")
        print("PASS real in-flight worker cancellation and overlapping-call rejection preserve document and ownership")
        finished = false
        let staleTask = Task { @MainActor in
            let result = await session.apply(large,input:longDrag);finished = true;return result
        }
        for _ in 0..<10000 {
            if session.isApplying || finished { break };await Task.yield()
        }
        try require(session.isApplying && !finished,"Could not observe second real in-flight operation")
        large.strokeWidth = 64
        let staleWorkerResult = await staleTask.value
        try require(!staleWorkerResult && large.document == largeBefore && large.activeStrokeID == nil,
            "Settings changed during actual work but stale result committed")
        large.selectedTool = .brush
        try require(StudioSmudgeContext.current(large) == nil,"Non-Smudge tool acquired edit context")
        print("PASS settings changed during real pixel work reject stale results before canonical commit")
    }
}
