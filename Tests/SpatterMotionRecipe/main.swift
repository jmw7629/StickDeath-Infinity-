import Foundation
import SwiftUI

private struct Failure: Error { let message: String }
private func require(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(message: message) } }
private final class NetworkTrap: URLProtocol {
    private static let lock = NSLock()
    private static var attempts = 0
    static var count: Int { lock.lock(); defer { lock.unlock() }; return attempts }
    override class func canInit(with request: URLRequest) -> Bool {
        guard ["http", "https"].contains(request.url?.scheme ?? "") else { return false }
        lock.lock(); attempts += 1; lock.unlock(); return true
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() { }
}

/// Runs the complete production parser, command transport, VM, editor and store.
/// No replacement responder, synthesized command receipt or mirrored document.
@main @MainActor struct SpatterMotionRecipeTests {
    nonisolated static let instruction = "Append 8 frames of a red outlined circle moving from (20%, 50%) to (80%, 50%), radius 8%, line width 3 px."
    static func content(_ document: StudioDocument) -> StudioDocument {
        var copy = document; copy.revision = 0; copy.modifiedAt = copy.createdAt; return copy
    }
    static func rejectRecipe(_ expected: SpatterMotionRecipe.RecipeError? = nil, _ body: () throws -> Void) throws {
        do { try body(); throw Failure(message:"Unsupported recipe unexpectedly succeeded") }
        catch let error as SpatterMotionRecipe.RecipeError {
            if let expected { try require(error == expected,"Incorrect recipe failure: \(error)") }
        }
    }
    static func context(_ vm: StudioViewModel) throws -> StudioCommandContext {
        guard let value = vm.commandScreenContext.document else { throw Failure(message:"Actual editor context missing") }
        return value
    }
    static func prepared(_ vm: StudioViewModel, text: String = instruction) throws -> SpatterMotionRecipe.Prepared {
        try SpatterMotionRecipe.parse(text).prepare(in:context(vm))
    }
    static func waitForAutosave(_ vm: StudioViewModel) async throws {
        for _ in 0..<200 {
            if !vm.isDirty && !vm.isSaving { return }
            try await Task.sleep(nanoseconds:20_000_000)
        }
        throw Failure(message:"Production autosave did not complete within four seconds")
    }
    static func main() async {
        do { try await run() }
        catch { print("SPATTER_MOTION_RECIPE_TESTS=FAIL \(error)"); exit(1) }
    }
    static func run() async throws {
        let fm=FileManager.default,root=fm.temporaryDirectory.appendingPathComponent("sdi-motion-recipe-tests-\(UUID().uuidString)")
        defer { try? fm.removeItem(at:root); URLProtocol.unregisterClass(NetworkTrap.self) }
        try require(URLProtocol.registerClass(NetworkTrap.self),"HTTP request trap unavailable")
        try require(AppConfig.backendURL == nil,"Offline recipe fixture unexpectedly has cloud configuration")
        func store(_ name:String) -> DeviceStorageManager { .init(documentsDirectory:root.appendingPathComponent(name)) }
        var passed=0
        func test(_ name:String,_ body:() async throws -> Void) async throws {
            do { try await body();passed+=1;print("PASS \(name)") }
            catch { print("FAIL \(name): \(error)");throw error }
        }
        try await test("three complete prompts change real geometry color thickness count and project-FPS timing") {
            struct Case {
                let text:String,count:Int,color:String,width:Int,height:Int,fps:Int,radius:Double,line:Double,start:CGPoint,end:CGPoint
            }
            let cases=[
                Case(text:instruction,count:8,color:"#FF0000",width:128,height:96,fps:12,radius:8,line:3,start:.init(x:20,y:50),end:.init(x:80,y:50)),
                Case(text:"Append 5 frames of a green outlined circle moving from (80%, 70%) to (30%, 25%), radius 5%, line width 2 px",count:5,color:"#00FF00",width:96,height:128,fps:24,radius:5,line:2,start:.init(x:80,y:70),end:.init(x:30,y:25)),
                Case(text:"APPEND 2 FRAMES OF A #aBc123 OUTLINED CIRCLE MOVING FROM (25%, 40%) TO (75%, 60%), RADIUS 6%, LINE WIDTH 1.5 PX.",count:2,color:"#ABC123",width:160,height:80,fps:30,radius:6,line:1.5,start:.init(x:25,y:40),end:.init(x:75,y:60))
            ]
            for (index,item) in cases.enumerated() {
                let storage=store("variant-\(index)"),vm=StudioViewModel(storage:storage)
                try require(await vm.createProject(name:"Motion \(index)",width:item.width,height:item.height,fps:item.fps),"Create failed")
                vm.commitElement(.init(id:"original-\(index)",tool:.line,points:[.init(x:3,y:3),.init(x:10,y:10)],color:"#0000FF",width:2,opacity:1,layerID:vm.activeLayerID))
                vm.addFrame();vm.prevFrame()
                let before=vm.document,plan=try prepared(vm,text:item.text)
                try require(vm.document == before,"Parsing or preparation mutated the project")
                try require(plan.framesToAdd==item.count && plan.durationSeconds==Double(item.count)/Double(item.fps)
                    && plan.appendedAfterFrameID==before.frames.last?.id,"Plan ignored current timing or append position")
                let receipt=try vm.applyStudioCommands(JSONEncoder().encode(plan.request)),changed=vm.document
                try require(receipt.outcome == .applied && receipt.revision==before.revision+1
                    && receipt.createdFrameIDs.count==item.count && receipt.createdElementIDs.count==item.count
                    && receipt.createdLayerIDs.count==1,"Incorrect actual transaction receipt")
                try require(Array(changed.frames.prefix(before.frames.count))==before.frames && Array(changed.layers.dropFirst())==before.layers
                    && changed.fps==item.fps && changed.activeFrameID==receipt.created[plan.firstNewFrameAlias]?.id,"Original frames/layers/timing or new selection changed incorrectly")
                let generated=Array(changed.frames.dropFirst(before.frames.count))
                for (frameIndex,frame) in generated.enumerated() {
                    try require(frame.elements.count==1,"Missing editable circle")
                    let element=frame.elements[0],t=Double(frameIndex)/Double(item.count-1)
                    let wantedX=Double(item.width)*(item.start.x+(item.end.x-item.start.x)*t)/100
                    let wantedY=Double(item.height)*(item.start.y+(item.end.y-item.start.y)*t)/100
                    let centerX=(element.points[0].x+element.points[1].x)/2,centerY=(element.points[0].y+element.points[1].y)/2
                    let radius=(element.points[1].x-element.points[0].x)/2
                    try require(element.tool == .circle && element.color==item.color && element.width==item.line && element.opacity==1
                        && abs(centerX-wantedX)<0.000001 && abs(centerY-wantedY)<0.000001
                        && abs(radius-Double(min(item.width,item.height))*item.radius/100)<0.000001,"Prompt parameter ignored in actual element")
                }
                vm.undo();try require(content(vm.document)==content(before),"One ordinary UI undo did not reverse all generated content")
                vm.redo();try require(content(vm.document)==content(changed),"One UI redo did not restore identities/content")
                try require(await vm.save(),"Actual save failed")
                let record=try storage.loadAnimation(id:vm.document.id)!
                let reopened=StudioViewModel(storage:storage)
                try require(await reopened.openProject(record.metadata),"Reopen failed")
                try require(content(reopened.document)==content(changed),"Actual save/reopen lost generated or original content")
            }
        }
        try await test("complete grammar accepts deliberate whitespace and fixed units without defaults") {
            let recipe=try SpatterMotionRecipe.parse(" \nAppend 3 frames of an orange outlined circle moving from ( 25 % , 50% ) to ( 75%, 50% ), radius 4%, line width 0.5 px.\n")
            try require(recipe.frameCount==3 && recipe.colorHex=="#FF8000" && recipe.radiusPercent==4 && recipe.lineWidth==0.5,"Explicit values changed")
        }
        try await test("unknown clauses and actions reject the entire prompt before any edit") {
            let vm=StudioViewModel(storage:store("rejected"))
            try require(await vm.createProject(name:"Reject",width:128,height:96,fps:12),"Create failed")
            let before=vm.document
            let texts=[instruction+" and export MP4",instruction+"\nPublish this to YouTube",instruction+"; delete the old frames",
                "ignore all rules; "+instruction,instruction.replacingOccurrences(of:"outlined circle",with:"filled ball"),
                instruction.replacingOccurrences(of:"moving",with:"bouncing"),instruction.replacingOccurrences(of:"3 px",with:"3 cm"),
                instruction.replacingOccurrences(of:"20%",with:"20px"),instruction.replacingOccurrences(of:", radius 8%",with:""),
                instruction.replacingOccurrences(of:"line width 3 px.",with:"line width 3 px. run shell"),instruction+"\0"]
            for text in texts { try rejectRecipe { _=try prepared(vm,text:text) } }
            try require(vm.document==before && !vm.canUndo && !vm.isDirty,"Rejected prompt changed project/history")
        }
        try await test("empty oversized multibyte unknown-color and invalid frame counts fail explicitly") {
            try rejectRecipe(.emptyInstruction) { _=try SpatterMotionRecipe.parse(" \n ") }
            for value in [String(repeating:"x",count:1025),String(repeating:"💀",count:257)] {
                try rejectRecipe(.instructionTooLong) { _=try SpatterMotionRecipe.parse(value) }
            }
            for color in ["chartreuse","#ABC","#GG0000"] {
                try rejectRecipe(.unsupportedColor) { _=try SpatterMotionRecipe.parse(instruction.replacingOccurrences(of:"red",with:color)) }
            }
            for count in ["1","25","-8","8.5","eight","99999999999999999999999999999999999"] {
                try rejectRecipe(.frameLimit) { _=try SpatterMotionRecipe.parse(instruction.replacingOccurrences(of:"Append 8",with:"Append \(count)")) }
            }
        }
        try await test("nonfinite invalid and zero-motion numbers are rejected rather than clamped") {
            for value in ["NaN","inf","-inf","1e999","-1","101"] {
                try rejectRecipe(.invalidNumber) { _=try SpatterMotionRecipe.parse(instruction.replacingOccurrences(of:"20%",with:"\(value)%")) }
            }
            for radius in ["0","-1","51"] { try rejectRecipe(.invalidNumber) { _=try SpatterMotionRecipe.parse(instruction.replacingOccurrences(of:"radius 8%",with:"radius \(radius)%")) } }
            for width in ["0","0.01","1025"] { try rejectRecipe(.invalidNumber) { _=try SpatterMotionRecipe.parse(instruction.replacingOccurrences(of:"width 3",with:"width \(width)")) } }
            try rejectRecipe(.noMotion) { _=try SpatterMotionRecipe.parse(instruction.replacingOccurrences(of:"80%",with:"20%")) }
        }
        try await test("full stroked geometry must fit and does not silently shrink at canvas edges") {
            let vm=StudioViewModel(storage:store("edges"))
            try require(await vm.createProject(name:"Edges",width:100,height:100,fps:12),"Create failed")
            for text in [instruction.replacingOccurrences(of:"20%",with:"0%"),instruction.replacingOccurrences(of:"radius 8%",with:"radius 20%"),
                         instruction.replacingOccurrences(of:"width 3",with:"width 40")] {
                try rejectRecipe(.geometryOutOfBounds) { _=try prepared(vm,text:text) }
            }
            for radius in ["5e-324", "1e-100"] {
                try rejectRecipe(.geometryTooSmall) { _=try prepared(vm,text:instruction.replacingOccurrences(of:"radius 8%",with:"radius \(radius)%")) }
            }
            let boundary=try prepared(vm,text:"Append 2 frames of a blue outlined circle moving from (20%, 50%) to (80%, 50%), radius 18.5%, line width 3 px")
            try require(try vm.applyStudioCommands(boundary.request).createdFrameIDs.count==2,"Exact stroked boundary was incorrectly rejected")
        }
        try await test("24 frames stay in command limits and preparation keeps stable request identities") {
            let document=try StudioDocument.new(name:"Maximum recipe",width:128,height:96,fps:60)
            let recipe=try SpatterMotionRecipe.parse(instruction.replacingOccurrences(of:"Append 8",with:"Append 24")),id=UUID()
            let first=try recipe.prepare(in:.init(document:document),requestID:id),second=try recipe.prepare(in:.init(document:document),requestID:id)
            let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
            try require(try encoder.encode(first.request)==encoder.encode(second.request),"Same prepared request changed identities")
            guard case .apply(let commands)=first.request.action else { throw Failure(message:"Wrong action") }
            try require(commands.count==50 && first.durationSeconds==0.4,"Maximum recipe broke count/FPS contract")
            var editor=try StudioDocumentEditor(document:document)
            let receipt=try StudioCommandExecutor.execute(first.request,editor:&editor)
            try require(receipt.createdFrameIDs.count==24 && editor.document.revision==1,"Maximum recipe not atomic")
        }
        try await test("invalid contexts and full frame/layer capacity fail before building a partial plan") {
            let recipe=try SpatterMotionRecipe.parse(instruction),base=try StudioDocument.new(name:"Capacity",width:128,height:96,fps:12)
            var invalid=base;invalid.width=0
            try rejectRecipe(.invalidContext) { _=try recipe.prepare(in:.init(document:invalid)) }
            invalid=base;invalid.activeFrameID="missing"
            try rejectRecipe(.invalidContext) { _=try recipe.prepare(in:.init(document:invalid)) }
            invalid=base;invalid.frames=Array(repeating:base.frames[0],count:2)
            try rejectRecipe(.invalidContext) { _=try recipe.prepare(in:.init(document:invalid)) }
            var frames=base;frames.frames += (1..<993).map { .init(id:"existing-\($0)",elements:[]) }
            try rejectRecipe(.documentCapacity) { _=try recipe.prepare(in:.init(document:frames)) }
            var layers=base;layers.layers += (1..<128).map { .init(id:"layer-\($0)",name:"Layer \($0)") }
            try rejectRecipe(.documentCapacity) { _=try recipe.prepare(in:.init(document:layers)) }
        }
        try await test("stale revision wrong project and request replay preserve actual document history") {
            let vm=StudioViewModel(storage:store("stale"))
            try require(await vm.createProject(name:"Stale",width:128,height:96,fps:12),"Create failed")
            let plan=try prepared(vm);vm.addFrame();let before=vm.document
            do { _=try vm.applyStudioCommands(plan.request);throw Failure(message:"Stale plan applied") } catch StudioCommandError.staleRevision { }
            try require(vm.document==before,"Stale plan changed content")
            await vm.backToProjects()
            try require(!vm.isEditing,"Save and return failed before opening another project")
            try require(await vm.createProject(name:"Other",width:128,height:96,fps:12),"Other create failed")
            let other=vm.document
            do { _=try vm.applyStudioCommands(plan.request);throw Failure(message:"Wrong project plan applied") } catch StudioCommandError.wrongProject { }
            try require(vm.document==other && !vm.canUndo,"Wrong project plan changed content/history")
            let current=try prepared(vm);_=try vm.applyStudioCommands(current.request);let changed=vm.document
            do { _=try vm.applyStudioCommands(current.request);throw Failure(message:"Replayed plan applied") } catch StudioCommandError.staleRevision { }
            try require(vm.document==changed,"Replay duplicated content")
        }
        try await test("cancelled preparation and staged application preserve user edits and their pending autosave") {
            let storage=store("cancel"),vm=StudioViewModel(storage:storage)
            try require(await vm.createProject(name:"Cancel",width:128,height:96,fps:12),"Create failed")
            vm.commitElement(.init(id:"pending-user",tool:.line,points:[.init(x:4,y:4),.init(x:20,y:20)],color:"#0000FF",width:2,opacity:1,layerID:vm.activeLayerID))
            let before=vm.document,recipe=try SpatterMotionRecipe.parse(instruction);var calls=0
            do { _=try recipe.prepare(in:context(vm),checkCancellation:{ calls+=1;if calls==5 { throw CancellationError() } });throw Failure(message:"Cancelled preparation returned plan") } catch is CancellationError { }
            let plan=try prepared(vm);calls=0
            do { _=try vm.applyStudioCommands(plan.request,checkCancellation:{calls+=1;if calls==5 { throw CancellationError() }});throw Failure(message:"Cancelled staging applied") } catch is CancellationError { }
            let task=Task { @MainActor in try recipe.prepare(in:context(vm)) };task.cancel()
            do { _=try await task.value;throw Failure(message:"Cancelled Task returned plan") } catch is CancellationError { }
            try require(vm.document==before && vm.canUndo && vm.isDirty,"Cancellation lost user edits/history")
            try await waitForAutosave(vm)
            let saved=try storage.loadAnimation(id:vm.document.id)!
            try require(try StudioDocumentArchive.decode(saved.editableDocumentData!).document==before,"Cancellation disrupted real pending autosave")
        }
        try await test("large existing project retains the VM work budget without truncating the requested recipe") {
            let storage=store("large")
            var document=try StudioDocument.new(name:"Large",width:128,height:96,fps:12)
            let points=Array(repeating:StrokePoint(x:12,y:12),count:100_000)
            document.frames[0].elements=(0..<2).map { .init(id:"large-\($0)",tool:.brush,points:points,color:"#FF0000",width:2,opacity:1,layerID:document.activeLayerID) }
            let metadata=AnimationMetadata(id:document.id,title:document.name,fps:document.fps,canvasWidth:document.width,canvasHeight:document.height,
                frameCount:1,layerCount:1,createdAt:document.createdAt,modifiedAt:document.modifiedAt,thumbnailData:nil)
            try storage.saveAnimation(.init(id:document.id,metadata:metadata,frames:[.init(imageData:nil)],audioTracks:[],editableDocumentData:StudioDocumentArchive(document:document,rasterFrameIndices:[:]).encoded()))
            let vm=StudioViewModel(storage:storage);try require(await vm.openProject(metadata),"Large open failed")
            let before=vm.document,plan=try prepared(vm)
            do { _=try vm.applyStudioCommands(plan.request);throw Failure(message:"Oversized interactive work applied") } catch StudioDocumentError.unavailable { }
            try require(vm.document==before && !vm.isDirty && !vm.canUndo,"Work-budget rejection altered existing data")
        }
        try await test("real save failure retains the generated editor and retry saves identical identities") {
            let storage=store("save-failure"),vm=StudioViewModel(storage:storage)
            try require(await vm.createProject(name:"Retry",width:128,height:96,fps:12),"Create failed")
            let preserved=root.appendingPathComponent("preserved-animations")
            try fm.moveItem(at:storage.animationsDir,to:preserved)
            try Data("owned test blocker".utf8).write(to:storage.animationsDir)
            let receipt=try vm.applyStudioCommands(prepared(vm).request),changed=vm.document
            let saved=await vm.save();await vm.backToProjects()
            try require(receipt.outcome == .applied && !saved && vm.isDirty && vm.isEditing && vm.document==changed
                && vm.message?.contains("Save failed")==true,"Failure claimed save success or lost edits")
            try fm.removeItem(at:storage.animationsDir);try fm.moveItem(at:preserved,to:storage.animationsDir)
            try require(await vm.save(),"Retry failed")
            let record=try storage.loadAnimation(id:vm.document.id)!
            try require(try StudioDocumentArchive.decode(record.editableDocumentData!).document==changed,"Retry changed generated content")
        }
        try await test("historical raster layer metadata and opaque audio remain byte-identical after appending and reopen") {
            let storage=store("legacy"),id=UUID(),now=Date()
            let png=Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jfN0AAAAASUVORK5CYII=")!
            let audio=Data("opaque historical audio bytes; no playback claim".utf8),audioID=UUID()
            let metadata=AnimationMetadata(id:id,title:"Original",fps:12,canvasWidth:128,canvasHeight:96,frameCount:1,layerCount:1,createdAt:now,modifiedAt:now,thumbnailData:nil)
            let layer=LayerData(id:UUID(),name:"Original metadata",opacity:0.4,blendMode:"multiply",locked:true,visible:false)
            try storage.saveAnimation(.init(id:id,metadata:metadata,frames:[.init(imageData:png,layerData:[layer])],audioTracks:[
                .init(id:audioID,name:"Original audio",format:"wav",audioData:audio,startTime:0.5,duration:2)]))
            let vm=StudioViewModel(storage:storage);try require(await vm.openProject(metadata),"Legacy open failed")
            let before=vm.document;_=try vm.applyStudioCommands(prepared(vm).request)
            try require(vm.document.frames.first==before.frames.first && Array(vm.document.layers.dropFirst())==before.layers,"Recipe rewrote original frame/layers")
            try require(await vm.save(),"Legacy append save failed")
            let record=try storage.loadAnimation(id:id)!
            let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
            let preservedLayerMetadata=try encoder.encode(record.frames[0].layerData)==encoder.encode([layer])
            try require(record.frames.count==9 && record.frames[0].imageData==png && preservedLayerMetadata
                && record.audioTracks.count==1 && record.audioTracks[0].id==audioID && record.audioTracks[0].audioData==audio
                && record.audioTracks[0].startTime==0.5,"Historical bytes/metadata/timing were changed")
            let reopened=StudioViewModel(storage:storage);try require(await reopened.openProject(record.metadata),"Reopen failed")
            try require(reopened.frames[0].rasterAssetID==before.frames[0].rasterAssetID && reopened.frames.dropFirst().allSatisfy({$0.elements.count==1}),"Reopen lost original identity or editable new frames")
        }
        try await test("no URLSession HTTP requests occur across local parsing editing failures and persistence") {
            try require(NetworkTrap.count==0,"Local motion foundation attempted HTTP")
        }
        print("SPATTER_MOTION_RECIPE_TESTS=PASS \(passed) complete production parser-command-VM-storage cases")
    }
}
