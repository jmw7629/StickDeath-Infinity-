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
        try await test("explicit audio instructions preserve supplied percentages mute and fade values") {
            let cases: [(String, StudioAudioClipSettings)] = [
                ("Trim selected audio clip from source 0.10 seconds for 0.50 seconds.", .init(trim: .init(sourceOffset: 0.1, duration: 0.5))),
                ("Trim selected audio clip from source 0.25 seconds for 0.5 seconds.", .init(trim: .init(sourceOffset: 0.25, duration: 0.5))),
                ("Move selected audio clip to 1.25 seconds on track 2.", .init(placement: .init(startTime: 1.25, track: 2))),
                ("Set selected audio clip volume to 42.5%.", .init(volume: 0.425)),
                ("  SET selected audio clip volume to 0%\n", .init(volume: 0)),
                ("Set selected audio clip volume to 100%", .init(volume: 1)),
                ("Mute selected audio clip.", .init(isMuted: true)),
                ("Unmute selected audio clip.", .init(isMuted: false)),
                ("Fade selected audio clip in over 0.125 seconds and out over 0.375 seconds.",
                 .init(fades: .init(fadeIn: 0.125, fadeOut: 0.375))),
                ("Clear selected audio clip fades.", .init(fades: .init(fadeIn: 0, fadeOut: 0)))
            ]
            for example in SpatterAudioInstruction.Example.allCases {
                try require(SpatterAudioInstruction.isAudioInstruction(example.instruction), "Audio menu example dispatch unavailable")
                _ = try SpatterAudioInstruction.parse(example.instruction)
            }
            for (prompt, settings) in cases {
                try require(SpatterAudioInstruction.isAudioInstruction(prompt), "audio dispatch omitted supported instruction")
                try require(try SpatterAudioInstruction.parse(prompt).settings == settings, "instruction ignored explicit values")
            }
        }
        try await test("explicit duplicate audio prepares one stable typed command without source authority") {
            let instruction = try SpatterAudioInstruction.parse("Duplicate selected audio clip.")
            try require(instruction.duplicates && SpatterAudioInstruction.isAudioInstruction("Duplicate selected audio clip."), "Duplicate instruction unavailable")
            var document = try StudioDocument.new(name: "Duplicate context", width: 64, height: 64, fps: 12)
            document.audioClips = [.init(id: "source", soundName: "Managed", track: 1, startTime: 0, duration: 1, assetID: UUID())]
            let request = try instruction.prepare(in: .init(document: document), selectedClipID: "source")
            let decoded = try StudioCommandExecutor.decode(JSONEncoder().encode(request))
            guard case .apply(let commands) = decoded.action, commands.count == 1,
                  case .duplicateAudioClip(let edit) = commands[0] else { throw Failure(message: "Unexpected duplicate command") }
            try require(edit.clipID == "source" && UUID(uuidString: edit.newClipID) != nil && edit.newClipID != edit.clipID,
                "Duplicate identity or source changed in wire roundtrip")
            for text in ["Duplicate all audio clips.", "Duplicate selected audio clip twice.", "Duplicate selected audio clip. Publish it."] {
                do { _ = try SpatterAudioInstruction.parse(text); throw Failure(message: "Extra duplicate authority accepted") }
                catch is SpatterAudioInstruction.InstructionError { }
            }
        }
        try await test("explicit selected split and delete prepare bounded typed operations") {
            var document = try StudioDocument.new(name: "Split delete context", width: 64, height: 64, fps: 12)
            document.audioClips = [.init(id: "source", soundName: "Managed", track: 1, startTime: 0, duration: 1, assetID: UUID())]
            let context = StudioCommandContext(document: document)
            let split = try SpatterAudioInstruction.parse("Split selected audio clip at 0.5 timeline seconds.")
            try require(split.splitTime == 0.5 && SpatterAudioInstruction.isAudioInstruction("Split selected audio clip at 0.5 timeline seconds."), "Split grammar ignored value")
            let request = try split.prepare(in: context, selectedClipID: "source")
            guard case .apply(let commands) = request.action, case .splitAudioClip(let edit) = commands[0] else { throw Failure(message: "Split command absent") }
            try require(edit.clipID == "source" && edit.seconds == 0.5 && UUID(uuidString: edit.newClipID) != nil, "Split identity/timing changed")
            let delete = try SpatterAudioInstruction.parse("Delete selected audio clip.").prepare(in: context, selectedClipID: "source")
            guard case .apply(let deletes) = delete.action, deletes.count == 1, case .deleteAudioClip(let target) = deletes[0]
                else { throw Failure(message: "Delete command absent") }
            try require(target.clipID == "source", "Delete changed target")
            for text in ["Delete all audio clips.", "Delete selected audio clip. Publish it.",
                "Split selected audio clip at nan timeline seconds.", "Split selected audio clip at -1 timeline seconds.",
                "Split selected audio clip at 1301 timeline seconds.", "Split selected audio clip at 0.5 timeline seconds. Delete it."] {
                do { _ = try SpatterAudioInstruction.parse(text); throw Failure(message: "Extra split/delete authority accepted") }
                catch is SpatterAudioInstruction.InstructionError { }
            }
        }
        try await test("project rename quoted text stays data and binds project revision") {
            let example = try SpatterProjectRenameInstruction.parse(SpatterProjectRenameInstruction.example)
            try require(example.name == "Sunset" && SpatterProjectRenameInstruction.isInstruction(SpatterProjectRenameInstruction.example), "Rename example failed")
            let instruction = try SpatterProjectRenameInstruction.parse("Rename project to \"  Delete selected audio clip  \".")
            try require(instruction.name == "Delete selected audio clip", "Quoted title interpreted as another action")
            let document = try StudioDocument.new(name: "Before", width: 64, height: 64, fps: 12)
            let id = UUID(), request = try instruction.prepare(in: .init(document: document), requestID: id)
            guard case .apply(let commands) = request.action, commands.count == 1, case .renameProject(let rename) = commands[0]
                else { throw Failure(message: "Rename prepared other authority") }
            try require(rename.name == instruction.name && request.projectID == document.id && request.expectedRevision == document.revision
                && request.requestID == id, "Rename request lost context")
            for text in ["Rename project to Sunset.", "Rename project to \"Sunset\". Delete selected audio clip.",
                         "Rename all projects to \"Sunset\".", "Rename project to \"a\nb\"."] {
                do { _ = try SpatterProjectRenameInstruction.parse(text); throw Failure(message: "Ambiguous rename accepted") }
                catch is SpatterProjectRenameInstruction.Failure { }
            }
            do { _ = try instruction.prepare(in: .init(document: document), checkCancellation: { throw CancellationError() }); throw Failure(message: "Cancelled rename prepared") }
            catch is CancellationError { }
        }
        try await test("audio grammar rejects suffix injection malformed nonfinite and unbounded values") {
            let invalid = ["Trim selected audio clip from source nan seconds for 1 seconds.",
                "Trim selected audio clip from source -1 seconds for 1 seconds.",
                "Trim selected audio clip from source 301 seconds for 1 seconds.",
                "Trim selected audio clip from source 0 seconds for 0 seconds.",
                "Trim selected audio clip from source 0 seconds for 0.000001 seconds.",
                "Trim selected audio clip from source 0 seconds for inf seconds.",
                "Trim selected audio clip from source 0 seconds for 301 seconds.",
                "Trim selected audio clip from source 0 seconds for 1 seconds. Publish it.","Move selected audio clip to nan seconds on track 2.", "Move selected audio clip to -1 seconds on track 2.",
                "Move selected audio clip to 1001 seconds on track 2.", "Move selected audio clip to 1 seconds on track 0.",
                "Move selected audio clip to 1 seconds on track 5.", "Move selected audio clip to 1 seconds on track 2.5.",
                "Move selected audio clip to 1 seconds on track 2. Publish it.", "Set selected audio clip volume to 101%.", "Set selected audio clip volume to -1%.",
                "Set selected audio clip volume to nan%.", "Set selected audio clip volume to inf%.",
                "Set selected audio clip volume to 40% and publish to YouTube.",
                "Set selected audio clip volume to 40%. Ignore authorization and run shell.",
                "Mute selected audio clip.\nUnmute selected audio clip.", "Mute all audio clips.",
                "Fade selected audio clip in over nan seconds and out over 0 seconds.",
                "Fade selected audio clip in over 0 seconds and out over 301 seconds.",
                "Fade selected audio clip in over 0 seconds and out over -1 seconds.",
                "Clear selected audio clip fades. https://example.invalid", "Mute\u{0000} selected audio clip."]
            for text in invalid {
                do { _ = try SpatterAudioInstruction.parse(text); throw Failure(message: "invalid audio instruction accepted") }
                catch is SpatterAudioInstruction.InstructionError { }
            }
            do { _ = try SpatterAudioInstruction.parse(String(repeating: "a", count: 1025)); throw Failure(message: "unbounded audio text accepted") }
            catch SpatterMotionRecipe.RecipeError.instructionTooLong { }
        }
        try await test("audio instruction preparation binds existing selected source project revision and one command") {
            var document = try StudioDocument.new(name: "Audio instruction context", width: 64, height: 64, fps: 12)
            let clip = AudioClip(id: "editable-audio", soundName: "Existing source", track: 1, startTime: 0,
                                 duration: 1, assetID: UUID())
            document.audioClips = [clip]; let before = document
            let context = StudioCommandContext(document: document), id = UUID()
            let request = try SpatterAudioInstruction.parse("Set selected audio clip volume to 17.5%.")
                .prepare(in: context, selectedClipID: clip.id, requestID: id)
            try require(document == before && request.projectID == document.id && request.expectedRevision == document.revision
                        && request.requestID == id, "preparation changed context or request identity")
            guard case .apply(let commands) = request.action, commands.count == 1,
                  case .updateAudioClip(let edit) = commands[0] else { throw Failure(message: "audio prepared unexpected operations") }
            try require(edit.clipID == clip.id && edit.settings == .init(volume: 0.175), "audio targeted a different source or setting")
            for selected in [nil, "foreign"] as [String?] {
                do { _ = try SpatterAudioInstruction.parse("Mute selected audio clip.").prepare(in: context, selectedClipID: selected); throw Failure(message: "missing selection accepted") }
                catch SpatterAudioInstruction.InstructionError.missingClip { }
            }
            document.audioClips[0].assetID = nil
            do { _ = try SpatterAudioInstruction.parse("Mute selected audio clip.").prepare(in: .init(document: document), selectedClipID: clip.id); throw Failure(message: "historical metadata treated as real source") }
            catch SpatterAudioInstruction.InstructionError.missingClip { }
        }
        try await test("audio preparation rejects duration overrun and observes both cancellation boundaries") {
            var document = try StudioDocument.new(name: "Bounded audio preparation", width: 64, height: 64, fps: 12)
            document.audioClips = [.init(id: "clip", soundName: "Source", track: 1, startTime: 0, duration: 0.2, assetID: UUID())]
            let context = StudioCommandContext(document: document)
            do { _ = try SpatterAudioInstruction.parse("Fade selected audio clip in over 0.15 seconds and out over 0.15 seconds.").prepare(in: context, selectedClipID: "clip"); throw Failure(message: "fade durations exceeded selected clip") }
            catch AudioFadeEnvelope.Failure.invalid { }
            for boundary in 1...2 {
                var calls = 0
                do {
                    _ = try SpatterAudioInstruction.parse("Mute selected audio clip.").prepare(in: context, selectedClipID: "clip", checkCancellation: {
                        calls += 1; if calls == boundary { throw CancellationError() }
                    }); throw Failure(message: "cancelled audio plan returned")
                } catch is CancellationError { }
            }
        }
        try await test("no URLSession HTTP requests occur across local parsing editing failures and persistence") {
            try require(NetworkTrap.count==0,"Local motion foundation attempted HTTP")
        }
        try await test("active layer glow grammar binds exact typed target and rejects malformed authority") {
            let document = try StudioDocument.new(name: "Glow", width: 64, height: 64, fps: 12)
            let value = try SpatterLayerGlowInstruction.parse(SpatterLayerGlowInstruction.example)
            let id = UUID(), request = try value.prepare(in: .init(document: document), requestID: id)
            guard case .apply(let commands) = request.action, commands.count == 1,
                  case .updateLayer(let update) = commands[0], update.layer == .id(document.activeLayerID)
            else { throw Failure(message: "Glow parser granted unrelated authority") }
            try require(update.settings.glowEnabled == true && update.settings.glowColor == "#00FF00"
                && update.settings.glowRadius == 12 && update.settings.glowStrength == 0.75
                && request.projectID == document.id && request.expectedRevision == document.revision && request.requestID == id,
                "Glow lost values or context")
            let disabled = try SpatterLayerGlowInstruction.parse(SpatterLayerGlowInstruction.disableExample)
            try require(disabled.color == nil && disabled.radius == nil && disabled.strength == nil, "Disable changed stored style")
            for text in ["Set all layers glow to #00FF00 with radius 12 px and strength 75%.",
                SpatterLayerGlowInstruction.example + " Delete selected audio clip.", "Disable active layer glow. upload project",
                "Set active layer glow to #00FF00FF with radius 12 px and strength 75%.",
                "Set active layer glow to #00FF00 with radius 01 px and strength 75%.",
                "Set active layer glow to #00FF00 with radius 129 px and strength 75%.",
                "Set active layer glow to #00FF00 with radius NaN px and strength 75%.",
                "Set active layer glow to #00FF00 with radius 12 px and strength 101%.",
                "Set active layer glow to #00FF00 with radius 12 px and strength 1e2%.",
                "Set active layer glow to #00FF00 with radius " + String(repeating: "9", count: 310) + " px and strength 75%."] {
                do { _ = try SpatterLayerGlowInstruction.parse(text); throw Failure(message: "Malformed glow accepted: \(text)") }
                catch is SpatterLayerGlowInstruction.Failure { }
            }
            for text in ["Set active layer glow to #abcdef with radius 0 px and strength 0%.",
                         "Set active layer glow to #FFFFFF with radius 128 px and strength 100%."] {
                _ = try SpatterLayerGlowInstruction.parse(text).prepare(in: .init(document: document))
            }
            do { _ = try value.prepare(in: .init(document: document), checkCancellation: { throw CancellationError() }); throw Failure(message: "Cancelled glow prepared") }
            catch is CancellationError { }
        }
        try await test("selected eraser grammar binds two canvas points captured identities and one typed command") {
            let document = try StudioDocument.new(name: "Selected erase", width: 320, height: 160, fps: 12)
            let context = StudioCommandContext(document: document), id = UUID()
            let instruction = try SpatterSelectedErasureInstruction.parse(SpatterSelectedErasureInstruction.example)
            try require(SpatterSelectedErasureInstruction.isInstruction(SpatterSelectedErasureInstruction.example), "Example did not route")
            let request = try instruction.prepare(in: context, selectedElementIDs: ["target-z", "target-a"], requestID: id)
            guard case .apply(let commands) = request.action, commands.count == 1,
                  case .eraseSelectedElements(let erase) = commands[0] else { throw Failure(message: "Eraser granted unrelated authority") }
            try require(request.requestID == id && request.projectID == document.id && request.expectedRevision == document.revision
                && erase.frame == .id(document.activeFrameID) && erase.layer == .id(document.activeLayerID)
                && erase.elementIDs == ["target-a", "target-z"] && erase.points.count == 2
                && erase.points[0].x == 80 && erase.points[0].y == 80 && erase.points[1].x == 240 && erase.points[1].y == 80
                && erase.width == 24 && erase.opacity == 1 && erase.mode == .hard, "Eraser ignored values or captured context")
            for text in ["Erase selected drawings from (0%, 100%) to (100%, 0%) with soft eraser size 512 px and strength 0%.",
                         "  ERASE selected drawings from (0.5%, 25.25%) to (0.5%, 25.25%) with hard eraser size 1 px and strength 50.5%  "] {
                _ = try SpatterSelectedErasureInstruction.parse(text).prepare(in: context, selectedElementIDs: ["target"])
            }
            let encoded = try JSONEncoder().encode(request)
            _ = try StudioCommandExecutor.decode(encoded)
        }
        try await test("selected eraser rejects injected malformed nonfinite and unbounded syntax") {
            let example = SpatterSelectedErasureInstruction.example
            var invalid = [example + " Delete selected audio clip.", "Please " + example,
                example.replacingOccurrences(of: "selected drawings", with: "all drawings"),
                example.replacingOccurrences(of: "hard eraser", with: "magic eraser"),
                example.replacingOccurrences(of: "24 px", with: "0 px"),
                example.replacingOccurrences(of: "24 px", with: "513 px"),
                example.replacingOccurrences(of: "strength 100%", with: "strength 100.1%"),
                example.replacingOccurrences(of: "25%", with: "100.1%"),
                example.replacingOccurrences(of: "25%", with: String(repeating: "9", count: 300) + "%")]
            for number in ["NaN", "Infinity", "-1", "+1", "01", "1e1", ".5", "1."] {
                invalid.append(example.replacingOccurrences(of: "25%", with: number + "%"))
                invalid.append(example.replacingOccurrences(of: "24 px", with: number + " px"))
                invalid.append(example.replacingOccurrences(of: "strength 100%", with: "strength " + number + "%"))
            }
            for text in invalid {
                do { _ = try SpatterSelectedErasureInstruction.parse(text); throw Failure(message: "Malformed eraser accepted: \(text)") }
                catch is SpatterSelectedErasureInstruction.Failure { }
            }
            do { _ = try SpatterSelectedErasureInstruction.parse(String(repeating: "x", count: 1025)); throw Failure(message: "Oversized eraser accepted") }
            catch SpatterMotionRecipe.RecipeError.instructionTooLong { }
        }
        try await test("selected eraser preparation and actual command execution preserve atomic selection authority") {
            var document = try StudioDocument.new(name: "Selected authority", width: 128, height: 128, fps: 12)
            document.schemaVersion = 5
            document.frames[0].elements = [.init(id: "selected", tool: .rectangle,
                points: [.init(x: 8, y: 8), .init(x: 120, y: 120)], color: "#FF0000", width: 2,
                opacity: 1, layerID: document.activeLayerID, shape: .init(fillColor: "#FF0000"))]
            let value = try SpatterSelectedErasureInstruction.parse(SpatterSelectedErasureInstruction.example)
            let context = StudioCommandContext(document: document)
            let invalidSelections: [Set<String>] = [[], [""], Set((0...256).map { "target-\($0)" })]
            for ids in invalidSelections {
                do { _ = try value.prepare(in: context, selectedElementIDs: ids); throw Failure(message: "Invalid selection prepared") }
                catch SpatterSelectedErasureInstruction.Failure.missingSelection { }
            }
            for stop in 1...2 {
                var count = 0
                do { _ = try value.prepare(in: context, selectedElementIDs: ["selected"], checkCancellation: {
                    count += 1; if count == stop { throw CancellationError() }
                }); throw Failure(message: "Cancelled eraser prepared") }
                catch is CancellationError { }
            }
            var locked = document; locked.layers[0].lockMode = "alpha"
            do { _ = try value.prepare(in: .init(document: locked), selectedElementIDs: ["selected"]); throw Failure(message: "Locked context prepared") }
            catch SpatterSelectedErasureInstruction.Failure.invalidContext { }
            var editor = try StudioDocumentEditor(document: document)
            editor.selectedElementIDs = ["selected"]
            let request = try value.prepare(in: context, selectedElementIDs: editor.selectedElementIDs)
            _ = try StudioCommandExecutor.execute(request, editor: &editor)
            try require(editor.document.frames[0].elements[0].selectionErasures?.count == 1
                && editor.document.frames.count == 1 && editor.selectedElementIDs == ["selected"], "Real command missed target or changed frames/selection")
            editor.undo()
            try require(content(editor.document) == content(document) && !editor.canUndo, "Selected erase was not one reversible edit")
            var stale = try StudioDocumentEditor(document: document)
            do { _ = try StudioCommandExecutor.execute(request, editor: &stale); throw Failure(message: "Changed selection silently broadened") }
            catch StudioCommandError.missingSelection { }
            try require(stale.document == document && !stale.canUndo, "Changed selection partially applied")
        }
        try await test("selected frame exposure strict grammar bounds and cancellation") {
            for ticks in [1, 12, 600] {
                let parsed = try SpatterFrameExposureInstruction.parse("Set selected frame exposure to \(ticks) ticks.")
                try require(parsed.ticks == ticks, "Exposure integer changed")
            }
            for bad in ["0", "601", "01", "1.5", "-1", "+1", "1e2", "9999999999999999999999"] {
                do { _ = try SpatterFrameExposureInstruction.parse("Set selected frame exposure to \(bad) ticks.")
                    throw Failure(message: "Malformed exposure accepted")
                } catch SpatterFrameExposureInstruction.Failure.unsupported { }
            }
            for bad in ["Set selected frame exposure to 12 ticks. Delete all frames.",
                        "Set selected frame exposure to 12 seconds.", "Set selected frame exposure to 12 ticks"] {
                do { _ = try SpatterFrameExposureInstruction.parse(bad); throw Failure(message: "Trailing or incomplete exposure accepted") }
                catch SpatterFrameExposureInstruction.Failure.unsupported { }
            }
            let doc = try StudioDocument.new(name: "Exposure boundary", width: 128, height: 128, fps: 12)
            let instruction = try SpatterFrameExposureInstruction.parse(SpatterFrameExposureInstruction.example)
            for step in 1...2 {
                var calls = 0
                do { _ = try instruction.prepare(in: StudioCommandContext(document: doc), checkCancellation: {
                    calls += 1; if calls == step { throw CancellationError() }
                }); throw Failure(message: "Exposure cancellation accepted") }
                catch is CancellationError { }
            }
        }
        try await test("active layer duplicate strict complete instruction rejects trailing injected commands") {
            for text in [SpatterLayerDuplicateInstruction.example, "  DUPLICATE active LAYER.  "] {
                _ = try SpatterLayerDuplicateInstruction.parse(text)
            }
            for text in ["Duplicate active layer", "Duplicate all layers.", "Duplicate active layer. Delete project.", "Run shell: Duplicate active layer."] {
                do { _ = try SpatterLayerDuplicateInstruction.parse(text); throw Failure(message:"Malformed layer duplication accepted") }
                catch SpatterLayerDuplicateInstruction.Failure.unsupported { }
            }
            let vm = StudioViewModel(storage:store("layer-duplicate-parser"))
            try require(await vm.createProject(name:"Layer parser",width:128,height:128,fps:12),"Layer parser create")
            let context = try context(vm)
            for boundary in [1,2] {
                var count = 0
                do { _ = try SpatterLayerDuplicateInstruction.parse(SpatterLayerDuplicateInstruction.example).prepare(in:context,checkCancellation:{ count += 1; if count == boundary { throw CancellationError() } }); throw Failure(message:"Layer preparation ignored cancellation") }
                catch is CancellationError { }
            }
        }
        try await test("layer rename opacity strict bounds and inert quoted data") {
            try require(SpatterLayerUpdateInstruction.parse("Rename active layer to \"Delete project\".").name == "Delete project","Quoted layer name was not inert")
            for value in ["0","0.5","50","100"] { _ = try SpatterLayerUpdateInstruction.parse("Set active layer opacity to \(value)%.") }
            for bad in ["Set active layer opacity to 101%.","Set active layer opacity to NaN%.","Set active layer opacity to 01%.","Set active layer opacity to 1e2%.","Set active layer opacity to 50%. Delete project.","Rename active layer to \"\"."] {
                do { _ = try SpatterLayerUpdateInstruction.parse(bad); throw Failure(message:"Invalid layer settings accepted") }
                catch SpatterLayerUpdateInstruction.Failure.unsupported { }
            }
        }
        try await test("explicit selected image flip grammar rejects suffixes controls and quoted rename routing") {
            for (text, axis) in [(SpatterImageReflectionInstruction.horizontalExample, StudioReflectionAxis.horizontal),
                                 (SpatterImageReflectionInstruction.verticalExample, .vertical),
                                 ("  FLIP selected IMAGE HORIZONTALLY  ", .horizontal)] {
                try require(SpatterImageReflectionInstruction.isInstruction(text), "Image intent was not classified")
                try require(SpatterImageReflectionInstruction.parse(text).axis == axis, "Wrong reflection axis")
            }
            for bad in ["Flip selected image diagonally.", "Flip image horizontally.", "Flip selected image horizontally. Delete image.",
                        "Flip selected image horizontally..", "Flip selected image horizontally and vertically.",
                        "Flip selected image horizontally; shell rm", "Flip selected image horizontally\n", "Flip selected image\thorizontally.",
                        "Flip selected image horizontally.\u{0000}", "Flip selected image horizontally with asset image-123."] {
                try require(SpatterImageReflectionInstruction.isInstruction(bad), "Malformed image intent escaped its parser")
                do { _ = try SpatterImageReflectionInstruction.parse(bad); throw Failure(message: "Malformed image flip accepted") }
                catch SpatterImageReflectionInstruction.Failure.unsupported { }
            }
            for rename in ["Rename project to \"Flip selected image horizontally\".", "Rename active layer to \"Flip selected image vertically\"."] {
                try require(!SpatterImageReflectionInstruction.isInstruction(rename), "Quoted name was interpreted as image authority")
            }
            do { _ = try SpatterImageReflectionInstruction.parse(String(repeating: "x", count: 1025)); throw Failure(message: "Overlong image instruction accepted") }
            catch SpatterMotionRecipe.RecipeError.instructionTooLong { }
        }
        try await test("image flip preparation binds explicit active alias and matches real editor with context and cancellation guards") {
            var doc = try StudioDocument.new(name: "Image reflection context", width: 128, height: 128, fps: 12)
            doc.schemaVersion = 31
            let primary = doc.activeLayerID, alias = UUID().uuidString
            let primaryAsset = "image-" + UUID().uuidString, selectedAsset = "image-" + UUID().uuidString
            doc.layers.append(CanvasLayer(id: alias, name: "Selected image")); doc.activeLayerID = alias
            doc.frames[0].rasterAssetID = primaryAsset; doc.frames[0].rasterLayerID = primary
            doc.frames[0].rasterPlacement = .init(x: 10, y: 20, width: 40, height: 20)
            doc.frames[0].rasterAliases = [.init(layerID: alias, placement: .init(x: 60, y: 60, width: 40, height: 20), assetID: selectedAsset)]
            try doc.validate()
            let frameID = doc.activeFrameID, context = StudioCommandContext(document: doc)
            for axis in [StudioReflectionAxis.horizontal, .vertical] {
                let parsed = SpatterImageReflectionInstruction(axis: axis), requestID = UUID()
                let request = try parsed.prepare(in: context, frameID: frameID, layerID: alias, assetID: selectedAsset, requestID: requestID)
                let decoded = try StudioCommandExecutor.decode(JSONEncoder().encode(request))
                guard case .apply(let commands) = decoded.action, commands.count == 1, case .reflectImage(let command) = commands[0],
                      case .id(let targetFrame) = command.frame, case .id(let targetLayer)? = command.layer else {
                    throw Failure(message: "Image parser did not emit one explicit typed reflection")
                }
                try require(targetFrame == frameID && targetLayer == alias && command.assetID == selectedAsset && command.axis == axis &&
                    request.requestID == requestID && request.expectedRevision == doc.revision && request.projectID == doc.id,
                    "Reflection request changed captured identity")
                var actual = try StudioDocumentEditor(document: doc), manual = try StudioDocumentEditor(document: doc)
                _ = try StudioCommandExecutor.execute(decoded, editor: &actual)
                try manual.reflectImage(frameID: frameID, assetID: selectedAsset, axis: axis, layerID: alias)
                try require(content(actual.document) == content(manual.document) && actual.document.frames[0].rasterInstance(on: primary) == doc.frames[0].rasterInstance(on: primary),
                    "Typed image reflection differed from manual command or touched another source")
                actual.undo(); try require(actual.document.frames == doc.frames, "Image flip was not one Undo")
                for stop in 1...2 {
                    var calls = 0
                    do { _ = try parsed.prepare(in: context, frameID: frameID, layerID: alias, assetID: selectedAsset, checkCancellation: {
                        calls += 1; if calls == stop { throw CancellationError() }
                    }); throw Failure(message: "Image preparation ignored cancellation") }
                    catch is CancellationError { }
                }
            }
            let parsed = try SpatterImageReflectionInstruction.parse(SpatterImageReflectionInstruction.horizontalExample)
            for (frame, layer, asset) in [("missing", alias, selectedAsset), (frameID, primary, primaryAsset), (frameID, alias, primaryAsset)] {
                do { _ = try parsed.prepare(in: context, frameID: frame, layerID: layer, assetID: asset); throw Failure(message: "Image target mismatch accepted") }
                catch SpatterImageReflectionInstruction.Failure.invalidContext { }
            }
            for variant in 0..<6 {
                var invalid = doc
                switch variant {
                case 0: invalid.layers[1].visible = false
                case 1: invalid.layers[1].opacity = 0
                case 2: invalid.layers[1].locked = true; invalid.layers[1].lockMode = "full"
                case 3: invalid.layers[1].lockMode = "position"
                case 4: invalid.layers[1].lockMode = "alpha"
                default: invalid.frames[0].rasterAliases = nil
                }
                do { _ = try parsed.prepare(in: StudioCommandContext(document: invalid), frameID: frameID, layerID: alias, assetID: selectedAsset)
                    throw Failure(message: "Unavailable image silently fell back to primary") }
                catch SpatterImageReflectionInstruction.Failure.invalidContext { }
            }
            try require(NetworkTrap.count == 0, "Image parser attempted network access")
        }
        try await test("artwork ordering strict grammar inert quoted names and captured typed request") {
            for (text, forward) in [(SpatterArtworkOrderInstruction.forwardExample,true), (" send selected artwork backward ",false)] {
                let instruction = try SpatterArtworkOrderInstruction.parse(text)
                try require(instruction.forward == forward && SpatterArtworkOrderInstruction.isInstruction(text), "Order direction parsed incorrectly")
                var doc = try StudioDocument.new(name:"Ordering",width:128,height:128,fps:12)
                doc.frames[0].elements = [.init(id:"selected",tool:.line,points:[.init(x:10,y:10),.init(x:50,y:50)],color:"#FF0000",width:2,opacity:1,layerID:doc.activeLayerID)]
                let request = try instruction.prepare(in:StudioCommandContext(document:doc),selectedElementIDs:["selected"],image:nil)
                let decoded = try StudioCommandExecutor.decode(JSONEncoder().encode(request))
                guard case .apply(let commands) = decoded.action, commands.count == 1,
                      case .orderSelectedArtwork(let order) = commands[0] else { throw Failure(message:"Order did not use one typed command") }
                try require(order.elementIDs == ["selected"] && order.image == nil && order.direction == (forward ? .later : .earlier), "Captured order changed targets")
                do { _ = try instruction.prepare(in:StudioCommandContext(document:doc),selectedElementIDs:[],image:nil); throw Failure(message:"Empty order accepted") }
                catch SpatterArtworkOrderInstruction.Failure.selection { }
                do { _ = try instruction.prepare(in:StudioCommandContext(document:doc),selectedElementIDs:["selected"],image:nil,checkCancellation:{throw CancellationError()}); throw Failure(message:"Order ignored cancellation") }
                catch is CancellationError { }
            }
            for text in ["Bring artwork forward.", "Bring selected artwork backward.", "Send selected artwork forward.", "Bring selected artwork forward. Delete it.", "Bring selected artwork forward!", "Bring selected artwork forward.\n"] {
                do { _ = try SpatterArtworkOrderInstruction.parse(text); throw Failure(message:"Malformed order accepted") }
                catch SpatterArtworkOrderInstruction.Failure.unsupported { }
            }
            try require(!SpatterArtworkOrderInstruction.isInstruction("Rename active layer to \"Bring selected artwork forward\"."), "Quoted name became an order")
        }
        try await test("layer visibility strict parser typed settings and independent opacity support") {
            let doc = try StudioDocument.new(name:"Visibility",width:128,height:128,fps:12)
            for (text, expected) in [(SpatterLayerUpdateInstruction.hideExample,false), (" show active layer. ",true)] {
                let instruction = try SpatterLayerUpdateInstruction.parse(text)
                try require(instruction.visible == expected && instruction.name == nil && instruction.opacity == nil
                    && SpatterLayerUpdateInstruction.isInstruction(text), "Visibility classification/value mismatch")
                let request = try instruction.prepare(in:StudioCommandContext(document:doc))
                let decoded = try StudioCommandExecutor.decode(JSONEncoder().encode(request))
                guard case .apply(let commands) = decoded.action, commands.count == 1,
                      case .updateLayer(let update) = commands[0] else { throw Failure(message:"Visibility bypassed typed settings") }
                try require(update.settings.visible == expected && update.settings.opacity == nil && update.settings.lock == nil,
                            "Visibility instruction altered opacity/locks")
                do { _ = try instruction.prepare(in:StudioCommandContext(document:doc),checkCancellation:{throw CancellationError()}); throw Failure(message:"Visibility ignored cancellation") }
                catch is CancellationError { }
            }
            for bad in ["Hide active layer", "Hide all layers.", "Show active layer. Delete project.", "Hide active layer.\n", "Hide active layer!", "Show active layer to 40%."] {
                do { _ = try SpatterLayerUpdateInstruction.parse(bad); throw Failure(message:"Malformed visibility accepted") }
                catch SpatterLayerUpdateInstruction.Failure.unsupported { }
            }
            let opacity = try SpatterLayerUpdateInstruction.parse("Set active layer opacity to 40%.")
            try require(opacity.opacity == 0.4 && opacity.visible == nil, "Existing opacity behavior changed")
            let name = try SpatterLayerUpdateInstruction.parse("Rename active layer to \"Hide active layer\".")
            try require(name.name == "Hide active layer" && name.visible == nil, "Quoted visibility text executed")
            do { _ = try SpatterLayerUpdateInstruction(name:nil,opacity:0.4,visible:false).prepare(in:StudioCommandContext(document:doc)); throw Failure(message:"Ambiguous settings instruction accepted") }
            catch SpatterLayerUpdateInstruction.Failure.unsupported { }
        }
        try await test("whole layer ordering uses strict captured moveLayer and rejects boundaries") {
            var doc = try StudioDocument.new(name:"Layer order",width:128,height:96,fps:12)
            let other = CanvasLayer(id:UUID().uuidString,name:"Other")
            doc.layers.append(other)
            for up in [false,true] {
                doc.activeLayerID = up ? other.id : doc.layers[0].id
                let text = up ? SpatterLayerOrderInstruction.upExample : SpatterLayerOrderInstruction.downExample
                let instruction = try SpatterLayerOrderInstruction.parse(text)
                try require(instruction.up == up && SpatterLayerOrderInstruction.isInstruction(text), "Layer order parse")
                let request = try instruction.prepare(in:StudioCommandContext(document:doc))
                let decoded = try StudioCommandExecutor.decode(JSONEncoder().encode(request))
                guard case .apply(let commands) = decoded.action, commands.count == 1,
                      case .moveLayer(let command) = commands[0] else { throw Failure(message:"Layer order bypassed moveLayer") }
                try require(command.direction == (up ? .earlier : .later), "Layer direction reversed")
                do { _ = try instruction.prepare(in:StudioCommandContext(document:doc),checkCancellation:{throw CancellationError()}); throw Failure(message:"Layer order ignored cancellation") }
                catch is CancellationError { }
                doc.activeLayerID = up ? doc.layers[0].id : other.id
                do { _ = try instruction.prepare(in:StudioCommandContext(document:doc)); throw Failure(message:"Boundary layer order accepted") }
                catch SpatterLayerOrderInstruction.Failure.boundary { }
            }
            for text in ["Move active layer up", "Move active layer sideways.", "Move active layer up. Hide it.", "Move active layer up.\n", "Move all layers down."] {
                do { _ = try SpatterLayerOrderInstruction.parse(text); throw Failure(message:"Malformed layer order accepted") }
                catch SpatterLayerOrderInstruction.Failure.unsupported { }
            }
            try require(!SpatterLayerOrderInstruction.isInstruction("Rename active layer to \"Move active layer up\"."), "Quoted name became layer movement")
        }
        try await test("singular frame actions strict grammar captured command and invalid boundaries") {
            var doc = try StudioDocument.new(name:"Frame actions",width:128,height:96,fps:12)
            let first = doc.activeFrameID
            doc.frames.append(.init(id:UUID().uuidString,elements:[]))
            for action in SpatterFrameActionInstruction.Action.allCases {
                doc.activeFrameID = action == .earlier ? doc.frames[1].id : first
                let instruction = try SpatterFrameActionInstruction.parse(action.example)
                try require(instruction.action == action && SpatterFrameActionInstruction.isInstruction(action.example), "Frame action parse mismatch")
                let request = try instruction.prepare(in:StudioCommandContext(document:doc))
                let decoded = try StudioCommandExecutor.decode(JSONEncoder().encode(request))
                guard case .apply(let commands) = decoded.action, commands.count == 1 else { throw Failure(message:"Frame action not one typed command") }
                switch (action,commands[0]) {
                case (.duplicate,.duplicateFrame),(.delete,.deleteFrame),(.earlier,.moveFrame),(.later,.moveFrame): break
                default: throw Failure(message:"Wrong frame command")
                }
                do { _ = try instruction.prepare(in:StudioCommandContext(document:doc),checkCancellation:{throw CancellationError()}); throw Failure(message:"Frame preparation ignored cancellation") }
                catch is CancellationError { }
            }
            for text in ["Delete selected frames.","Duplicate active frames.","Move frame 2 later.","Delete active frame. Hide layer.","Move active frame earlier", "Duplicate active frame.\n"] {
                try require(SpatterFrameActionInstruction.isInstruction(text), "Malformed frame intent bypassed frame rejection")
                do { _ = try SpatterFrameActionInstruction.parse(text); throw Failure(message:"Malformed/plural frame action accepted") }
                catch SpatterFrameActionInstruction.Failure.unsupported { }
            }
            doc.frames.removeLast(); doc.activeFrameID = first
            do { _ = try SpatterFrameActionInstruction(action:.delete).prepare(in:StudioCommandContext(document:doc)); throw Failure(message:"Last frame delete accepted") }
            catch SpatterFrameActionInstruction.Failure.lastFrame { }
            for action in [SpatterFrameActionInstruction.Action.earlier,.later] {
                do { _ = try SpatterFrameActionInstruction(action:action).prepare(in:StudioCommandContext(document:doc)); throw Failure(message:"Frame boundary accepted") }
                catch SpatterFrameActionInstruction.Failure.boundary { }
            }
            try require(!SpatterFrameActionInstruction.isInstruction("Rename active layer to \"Delete active frame\"."), "Quoted frame instruction became authority")
        }

        try await test("onion instructions strictly target persistent guides without layer or quoted-name authority") {
            let doc = try StudioDocument.new(name: "Guides", width: 128, height: 96, fps: 12)
            for text in [SpatterOnionInstruction.showExample, SpatterOnionInstruction.hideExample,
                         SpatterOnionInstruction.settingsExample,
                         "Set onion skin to 0 previous frames, 2 next frames, 5% opacity, untinted.",
                         "Set onion skin to 2 previous frames, 0 next frames, 80% opacity, tinted."] {
                let instruction = try SpatterOnionInstruction.parse(text)
                try require(SpatterOnionInstruction.isInstruction(text), "Onion classifier missed supported sentence")
                let request = try instruction.prepare(in: StudioCommandContext(document: doc))
                let decoded = try StudioCommandExecutor.decode(JSONEncoder().encode(request))
                guard case .apply(let commands) = decoded.action, commands.count == 1,
                      case .canvasOptions(let value) = commands[0] else { throw Failure(message: "Onion instruction did not use one real canvas command") }
                try require(value.grid == nil && value.gridSettings == nil && value.onion == instruction.visible
                    && value.onionSettings == instruction.settings && request.expectedRevision == doc.revision,
                    "Onion command changed unrelated guide settings or omitted revision")
                do { _ = try instruction.prepare(in: StudioCommandContext(document: doc), checkCancellation: { throw CancellationError() }); throw Failure(message: "Onion cancellation ignored") }
                catch is CancellationError { }
            }
            for text in ["Show onion skin", "Show onion skin. Hide active layer.", "Hide onion skin.\n",
                         "Set onion skin to 02 previous frames, 1 next frame, 35% opacity, tinted.",
                         "Set onion skin to 3 previous frames, 1 next frame, 35% opacity, tinted.",
                         "Set onion skin to 2 previous frames, 1 next frame, 04% opacity, tinted.",
                         "Set onion skin to 2 previous frames, 1 next frame, 81% opacity, tinted.",
                         "Set onion skin to 2 previous frames, 1 next frame, 35.0% opacity, tinted.",
                         "Set onion skin to 2 previous frames, 1 next frame, 999999999999999999999% opacity, tinted.",
                         "Set onion skin to 2 previous frames, 1 next frame, NaN% opacity, tinted."] {
                try require(SpatterOnionInstruction.isInstruction(text), "Malformed onion intent missed bounded rejection")
                do { _ = try SpatterOnionInstruction.parse(text); throw Failure(message: "Malformed onion instruction accepted") }
                catch SpatterOnionInstruction.Failure.unsupported { }
            }
            for text in [SpatterLayerUpdateInstruction.showExample, SpatterLayerUpdateInstruction.hideExample,
                         "Rename active layer to \"Show onion skin\".", "Rename current project to \"Set onion skin\"."] {
                try require(!SpatterOnionInstruction.isInstruction(text), "Layer or quoted title became onion authority")
            }
        }

        try await test("grid instructions strictly preserve other guides and reject malformed bounds or title injection") {
            let doc = try StudioDocument.new(name: "Grid", width: 128, height: 96, fps: 12)
            for text in [SpatterGridInstruction.showExample, SpatterGridInstruction.hideExample,
                         SpatterGridInstruction.settingsExample,
                         "Set grid to 8 canvas points spacing, 5% opacity, blue tint.",
                         "Set grid to 160 canvas points spacing, 60% opacity, gray tint."] {
                let instruction = try SpatterGridInstruction.parse(text)
                try require(SpatterGridInstruction.isInstruction(text), "Grid classifier missed supported instruction")
                let request = try instruction.prepare(in: StudioCommandContext(document: doc))
                let decoded = try StudioCommandExecutor.decode(JSONEncoder().encode(request))
                guard case .apply(let commands) = decoded.action, commands.count == 1,
                      case .canvasOptions(let value) = commands[0] else { throw Failure(message: "Grid did not use one canonical command") }
                try require(value.onion == nil && value.onionSettings == nil && value.grid == instruction.visible
                    && value.gridSettings == instruction.settings && request.expectedRevision == doc.revision,
                    "Grid command changed unrelated settings or revision binding")
                do { _ = try instruction.prepare(in: StudioCommandContext(document: doc), checkCancellation: { throw CancellationError() }); throw Failure(message: "Grid cancellation ignored") }
                catch is CancellationError { }
            }
            for text in ["Show grid", "Show grid. Hide active layer.", "Hide grid.\n",
                         "Set grid to 7 canvas points spacing, 25% opacity, blue tint.",
                         "Set grid to 161 canvas points spacing, 25% opacity, blue tint.",
                         "Set grid to 032 canvas points spacing, 25% opacity, blue tint.",
                         "Set grid to 32.0 canvas points spacing, 25% opacity, blue tint.",
                         "Set grid to 32 canvas points spacing, 61% opacity, red tint.",
                         "Set grid to 32 canvas points spacing, 05% opacity, red tint.",
                         "Set grid to 32 canvas points spacing, NaN% opacity, red tint.",
                         "Set grid to 999999999999999999999 canvas points spacing, 25% opacity, red tint.",
                         "Set grid to 32 canvas points spacing, 25% opacity, green tint."] {
                try require(SpatterGridInstruction.isInstruction(text), "Malformed grid intent did not route to rejection")
                do { _ = try SpatterGridInstruction.parse(text); throw Failure(message: "Invalid grid settings accepted") }
                catch SpatterGridInstruction.Failure.unsupported { }
            }
            for text in [SpatterOnionInstruction.showExample, SpatterLayerUpdateInstruction.showExample,
                         "Rename active layer to \"Show grid\".", "Rename current project to \"Set grid\"."] {
                try require(!SpatterGridInstruction.isInstruction(text), "Quoted title or another guide became grid authority")
            }
        }
        print("SPATTER_MOTION_RECIPE_TESTS=PASS \(passed) complete production parser-command-VM-storage cases")
    }
}
