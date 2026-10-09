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
    static func input(_ vm: StudioViewModel, end: Double = 42.5) throws -> StudioSharpenInput {
        guard let context = StudioSharpenContext.current(vm) else { throw SessionFailure.failed("Context unavailable") }
        let layout = StudioSharpenInput.Layout(viewport: CGSize(width: context.width, height: context.height), scale: 1, offset: .zero)
        var input = StudioSharpenInput(context: context, layout: layout)
        try input.append(CGPoint(x:20.5,y:16.5),current:context,layout:layout,foreground:true)
        try input.append(CGPoint(x:end,y:16.5),current:context,layout:layout,foreground:true)
        return input
    }
    static func main() async throws {
        setbuf(stdout,nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sdi-sharpen-session-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let storage = DeviceStorageManager(documentsDirectory:root.appendingPathComponent("Documents"),cachesDirectory:root.appendingPathComponent("Caches"))
        let vm = StudioViewModel(storage:storage)
        let created = await vm.createProject(name:"Gesture session",width:64,height:32,fps:12)
        try require(created,"Real project create failed")
        let base = DrawnElement(id:"base",tool:.rectangle,points:[.init(x:0,y:0),.init(x:64,y:32)],
            color:"#9C9C9C",width:1,opacity:1,layerID:vm.activeLayerID,shape:.init(fillColor:"#9C9C9C"))
        try require(vm.commitElement(base),"Opaque source commit failed")
        let red = DrawnElement(id:"edge",tool:.rectangle,points:[.init(x:0,y:0),.init(x:31,y:32)],
            color:"#646464",width:1,opacity:1,layerID:vm.activeLayerID,shape:.init(fillColor:"#646464"))
        try require(vm.commitElement(red),"Real source draw failed")
        vm.selectedTool = .sharpen;vm.strokeWidth = 16;vm.strokeOpacity = 1
        vm.strokeColor = .blue
        let original = vm.document, before = try pixels(vm), drag = try input(vm)
        let session = StudioSharpenSession()
        let applied = await session.apply(vm,input:drag)
        try require(applied && !session.isApplying && vm.activeStrokeID == nil,"Atomic session failed or ownership leaked")
        try require(vm.currentFrame.elements.count == 3 && vm.currentFrame.elements[0] == base && vm.currentFrame.elements[1] == red && vm.currentFrame.elements[2].sharpen != nil,
            "Session flattened original or did not save canonical descriptor")
        let after = try pixels(vm)
        let expected = try StudioSharpen.apply(to:.init(width:before.width,height:before.height,rgba:before.rgba),path:drag.points,settings:drag.context.settings)
        try require(zip(after.rgba,expected.rgba).allSatisfy { abs(Int($0)-Int($1)) <= 1 },"Committed output differs from actual sharpen")
        try require(after.rgba[(16*64+30)*4] < before.rgba[(16*64+30)*4] &&
                    after.rgba[(16*64+32)*4] > before.rgba[(16*64+32)*4],"Sharpen did not increase real edge contrast")
        for offset in stride(from:0,to:after.rgba.count,by:4) {
            try require(after.rgba[offset] == after.rgba[offset+1] && after.rgba[offset] == after.rgba[offset+2] &&
                        after.rgba[offset+3] == before.rgba[offset+3],"Sharpen painted foreground blue or changed alpha")
        }
        print("PASS asynchronous session commits editable sharpen through real production view model")
        let autosaveDeadline = Date().addingTimeInterval(4)
        while vm.isDirty && Date() < autosaveDeadline { try await Task.sleep(nanoseconds: 50_000_000) }
        try require(!vm.isDirty, "Actual Sharpen autosave stayed dirty: " + (vm.message ?? "no message"))
        let autoOpened = StudioViewModel(storage: storage)
        await autoOpened.loadProjects()
        guard let autoProject = autoOpened.savedProjects.first(where: { $0.id == vm.document.id }) else { throw SessionFailure.failed("Autosaved project missing") }
        let autoResult = await autoOpened.openProject(autoProject)
        try require(autoResult && autoOpened.document == vm.document, "Autosave did not persist exact editable Sharpen document")
        print("PASS real autosave persists Sharpen without cancelling its own validation task")

        vm.undo();try require(vm.document.frames == original.frames && (try pixels(vm)) == before,"Undo did not restore original")
        vm.redo();try require((try pixels(vm)) == after,"Redo lost output")
        let snapshot = vm.document
        let saved = await vm.save();try require(saved,"Actual storage save failed")
        await vm.backToProjects()
        let reopened = StudioViewModel(storage:storage)
        let opened = await reopened.openProject(vm.savedProjects[0]);try require(opened,"Reopen failed")
        try require(reopened.document == snapshot && (try pixels(reopened)) == after,"Cold reopen lost editable operation")
        print("PASS actual Undo Redo save and cold reopen preserve committed gesture and pixels")
        reopened.selectedTool = .sharpen;reopened.strokeWidth = 16;reopened.strokeOpacity = 1
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
        var bounded = StudioSharpenInput(context:pending.context,layout:pending.layout)
        for n in 0..<StudioBlur.maximumPoints {
            try bounded.append(.init(x:n % 2 + 20,y:16),current:bounded.context,layout:bounded.layout,foreground:true)
        }
        try rejected { try bounded.append(.init(x:22,y:16),current:bounded.context,layout:bounded.layout,foreground:true) }
        try require(bounded.isCancelled && bounded.points.count == StudioBlur.maximumPoints,"Input allocation was not bounded")
        reopened.strokeOpacity = 0
        let zeroContext = StudioSharpenContext.current(reopened)!
        var single = StudioSharpenInput(context:zeroContext,layout:pending.layout)
        try single.append(.init(x:20,y:16),current:single.context,layout:single.layout,foreground:true)
        let noChange = await session.apply(reopened,input:single)
        try require(!noChange && reopened.document == unchanged && reopened.activeStrokeID == nil &&
                    reopened.message == "This drag did not change the layer.","Zero-strength operation created history or skipped real no-op processing")
        reopened.strokeOpacity = 1
        print("PASS sample budget and no-op stroke preserve history and release edit ownership")
        let large = StudioViewModel(storage:storage)
        let largeCreated = await large.createProject(name:"Cancellation",width:1024,height:512,fps:12)
        try require(largeCreated,"Large real project create failed")
        let block = DrawnElement(id:"block",tool:.rectangle,points:[.init(x:2,y:2),.init(x:512,y:510)],
            color:"#FF0000",width:1,opacity:1,layerID:large.activeLayerID,shape:.init(fillColor:"#FF0000"))
        try require(large.commitElement(block),"Large source commit failed")
        large.selectedTool = .sharpen;large.strokeWidth = 128;large.strokeOpacity = 1;large.sharpenRadius = 32
        let context = StudioSharpenContext.current(large)!
        let largeLayout = StudioSharpenInput.Layout(viewport:.init(width:1024,height:512),scale:1,offset:.zero)
        var longDrag = StudioSharpenInput(context:context,layout:largeLayout)
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
        large.sharpenRadius = 16
        let staleWorkerResult = await staleTask.value
        try require(!staleWorkerResult && large.document == largeBefore && large.activeStrokeID == nil,
            "Settings changed during actual work but stale result committed")
        large.selectedTool = .brush
        try require(StudioSharpenContext.current(large) == nil,"Non-Sharpen tool acquired edit context")
        print("PASS settings changed during real pixel work reject stale results before canonical commit")

        let suite = "sdi-sharpen-preferences-" + UUID().uuidString
        let defaults = UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        let preferences = StudioViewModel(storage:storage,toolDefaults:defaults)
        let preferenceDocument = preferences.document
        preferences.selectedTool = .sharpen
        try require(preferences.strokeWidth == 32 && preferences.strokeOpacity == 1 &&
                    preferences.sharpenRadius == 2 && preferences.sharpenHardness == 0.5,"Incorrect separate Sharpen defaults")
        preferences.strokeWidth = 48;preferences.strokeOpacity = 0.7
        preferences.sharpenRadius = 7;preferences.sharpenHardness = 0.2;preferences.sharpenAmount = 1.5;preferences.sharpenThreshold = 0.3
        preferences.selectedTool = .pencil
        try require(preferences.strokeWidth == 2 && preferences.sharpenRadius == 2,"Sharpen settings leaked to Pencil")
        preferences.selectedTool = .sharpen
        try require(preferences.strokeWidth == 48 && preferences.strokeOpacity == 0.7 &&
                    preferences.sharpenRadius == 7 && preferences.sharpenHardness == 0.2 && preferences.sharpenAmount == 1.5 && preferences.sharpenThreshold == 0.3,"Switching tools lost Sharpen settings")
        let fresh = StudioViewModel(storage:storage,toolDefaults:defaults);fresh.selectedTool = .sharpen
        try require(fresh.strokeWidth == 48 && fresh.strokeOpacity == 0.7 && fresh.sharpenRadius == 7 && fresh.sharpenHardness == 0.2 && fresh.sharpenAmount == 1.5 && fresh.sharpenThreshold == 0.3,
                    "Actual UserDefaults reopen lost independent settings")
        preferences.resetCurrentDrawingToolPreferences()
        try require(preferences.strokeWidth == 32 && preferences.strokeOpacity == 1 &&
                    preferences.sharpenRadius == 2 && preferences.sharpenHardness == 0.5 && preferences.sharpenAmount == 0.5 && preferences.sharpenThreshold == 0.02 && preferences.document == preferenceDocument,
                    "Reset changed the document or failed to restore defaults")
        let stored = defaults.data(forKey:StudioViewModel.toolPreferencesKey)!
        preferences.sharpenRadius = .nan
        try require(defaults.data(forKey:StudioViewModel.toolPreferencesKey) == stored,"Invalid radius poisoned preferences")
        var historical = try JSONSerialization.jsonObject(with:stored) as! [String:Any]
        var entries = historical["values"] as! [String:[String:Any]]
        for key in Array(entries.keys) { entries[key]!.removeValue(forKey:"sharpenRadius");entries[key]!.removeValue(forKey:"sharpenHardness");entries[key]!.removeValue(forKey:"sharpenAmount");entries[key]!.removeValue(forKey:"sharpenThreshold") }
        historical["values"] = entries
        defaults.set(try JSONSerialization.data(withJSONObject:historical),forKey:StudioViewModel.toolPreferencesKey)
        let restored = StudioViewModel(storage:storage,toolDefaults:defaults);restored.selectedTool = .sharpen
        try require(restored.toolPreferencesWarning == nil && restored.sharpenRadius == 2 && restored.sharpenHardness == 0.5 && restored.sharpenAmount == 0.5 && restored.sharpenThreshold == 0.02,
                    "Historical preference data without Sharpen fields did not migrate")
        let contextBefore = StudioSharpenContext.current(reopened)!
        reopened.sharpenAmount = 1.4
        try require(StudioSharpenContext.current(reopened) != contextBefore,"Amount not captured")
        reopened.sharpenAmount = contextBefore.settings.amount
        reopened.sharpenThreshold = 0.4
        try require(StudioSharpenContext.current(reopened) != contextBefore,"Threshold not captured")
        reopened.sharpenThreshold = contextBefore.settings.threshold
        reopened.sharpenHardness = 0.1
        try require(StudioSharpenContext.current(reopened) != contextBefore,"Hardness not captured")
        print("PASS independent persisted Sharpen preferences defaults reset invalid-value protection and historical decoding")
    }
}
