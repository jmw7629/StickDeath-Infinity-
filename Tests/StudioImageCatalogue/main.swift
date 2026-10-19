import Foundation
import Darwin

struct TestFailure: Error { let message: String }
func require(_ condition: @autoclosure () throws -> Bool,_ message: String) throws { if try !condition() { throw TestFailure(message:message) } }
@main @MainActor struct ImageCatalogueTests {
 static func main() async throws {
  let fm=FileManager.default,source=URL(fileURLWithPath:CommandLine.arguments[1])
  let original=try Data(contentsOf:source.appendingPathComponent("catalogue.json"))
  let root=fm.temporaryDirectory.appendingPathComponent("sdi-image-catalogue-"+UUID().uuidString)
  try fm.createDirectory(at:root,withIntermediateDirectories:false);defer { try? fm.removeItem(at:root) }
  let copy=root.appendingPathComponent("copy");try fm.copyItem(at:source,to:copy)
  var groups=0
  func pass(_ name:String) { groups+=1;print("PASS "+name) }
  let catalogue=try StudioImageCatalogue(directory:source)
  try require(catalogue.images.count==207 && catalogue.licenses.count==3,"Wrong real catalogue count")
  for image in catalogue.images { let data=try catalogue.checkedPNG(image);try require(data.count==image.byteCount,"Wrong pinned bytes") }
  pass("all 207 curated PNGs license provenance encoded and decoded pixel hashes verify")
  let loaded=try await StudioImageCatalogue.load(directory:source)
  try require(loaded.images==catalogue.images,"Background load changed entries")
  let cancelled=Task { try await StudioImageCatalogue.load(directory:root.appendingPathComponent("missing")) };cancelled.cancel()
  do { _=try await cancelled.value;throw TestFailure(message:"Cancelled load returned") } catch is CancellationError { }
  pass("asynchronous load preserves entries and cancellation precedes file access")
  let matches=catalogue.search("cloud hand",category:.scenery)
  try require(matches.count==2 && catalogue.search("NO-ASSET-MATCH").isEmpty,"Search returned wrong actual items")
  try require(catalogue.search("",category:.effects).count==6,"Category filter")
  let safe=catalogue.search("",includeCartoonWeapons:false)
  try require(safe.count==178 && safe.allSatisfy{$0.contentAdvisory == .none},"Advisory filter")
  pass("multi-term local search category and cartoon-weapon filter use curated metadata")
  try require(catalogue.search("dragon top down",category:.props).map(\.id)==["kenney.scribble-dungeons.dragon"],"Dungeon tags lost")
  try require(catalogue.search("smoke side view",category:.effects).map(\.id)==["kenney.scribble-platformer-expansion.smoke"],"Expansion tags lost")
  try require(catalogue.search("sword",includeCartoonWeapons:false).isEmpty,"A new sword bypassed advisory filter")
  try require(catalogue.images.filter{$0.licenseID=="kenney.scribble-platformer-expansion.cc0"}.count==59 &&
              catalogue.images.filter{$0.licenseID=="kenney.scribble-dungeons.cc0"}.count==76,"Pack counts include excluded aliases")
  pass("new packs retain specific search perspective tags weapon filtering and 135 unique curated originals")
  let manifest=copy.appendingPathComponent("catalogue.json")
  func reject(_ name:String,_ mutation:(inout [String:Any])->Void) throws {
   var obj=try JSONSerialization.jsonObject(with:original) as! [String:Any];mutation(&obj)
   try JSONSerialization.data(withJSONObject:obj).write(to:manifest,options:.atomic)
   do { _=try StudioImageCatalogue(directory:copy);throw TestFailure(message:"Accepted "+name) }
   catch is StudioImageCatalogue.CatalogueError { }
   catch is DecodingError { }
  }
  try reject("missing license") { $0["licenses"]=[] }
  try reject("unknown license") { var rows=$0["licenses"] as! [[String:Any]];rows[0]["license"]="unknown";$0["licenses"]=rows }
  try reject("wrong source") { var rows=$0["licenses"] as! [[String:Any]];rows[0]["sourceURL"]="https://example.invalid/assets/pack";$0["licenses"]=rows }
  try reject("unknown reference") { var rows=$0["images"] as! [[String:Any]];rows[0]["licenseID"]="missing";$0["images"]=rows }
  pass("missing conflicting unknown and untrusted license provenance fails closed")
  try reject("duplicate ID") { var rows=$0["images"] as! [[String:Any]];rows[1]["id"]=rows[0]["id"];$0["images"]=rows }
  try reject("duplicate digest") { var rows=$0["images"] as! [[String:Any]];rows[1]["sha256"]=rows[0]["sha256"];$0["images"]=rows }
  try reject("duplicate visual image") { var rows=$0["images"] as! [[String:Any]];for k in ["pixelSHA256","width","height"] { rows[1][k]=rows[0][k] };$0["images"]=rows }
  pass("duplicate stable IDs encoded files and identical decoded images are rejected")
  try reject("escaping file") { var rows=$0["images"] as! [[String:Any]];rows[0]["filename"]="../foreign.png";$0["images"]=rows }
  try reject("oversize decode") { var rows=$0["images"] as! [[String:Any]];rows[0]["width"]=Int.max;$0["images"]=rows }
  try reject("missing safety metadata") { var rows=$0["images"] as! [[String:Any]];rows[0].removeValue(forKey:"contentAdvisory");$0["images"]=rows }
  pass("unsafe paths dimensions and missing advisory metadata fail before decode")
  try original.write(to:manifest,options:.atomic)
  let copied=try StudioImageCatalogue(directory:copy),item=copied.images[0],file=copy.appendingPathComponent(item.filename)
  let bytes=try Data(contentsOf:file);var corrupted=bytes;corrupted[0]^=1;try corrupted.write(to:file)
  do { _=try copied.checkedPNG(item);throw TestFailure(message:"Corrupt image accepted") } catch is StudioImageCatalogue.CatalogueError { }
  try fm.removeItem(at:file);try fm.createSymbolicLink(at:file,withDestinationURL:source.appendingPathComponent(item.filename))
  do { _=try copied.checkedPNG(item);throw TestFailure(message:"Symbolic image accepted") } catch is StudioImageCatalogue.CatalogueError { }
  try fm.removeItem(at:file);guard mkfifo(file.path,mode_t(0o600))==0 else { throw TestFailure(message:"FIFO setup") }
  do { _=try copied.checkedPNG(item);throw TestFailure(message:"FIFO accepted") } catch is StudioImageCatalogue.CatalogueError { }
  try fm.removeItem(at:file);try bytes.write(to:file)
  pass("corrupt symlink and FIFO resources fail without modifying originals or blocking")
  try fm.removeItem(at:manifest);try fm.createSymbolicLink(at:manifest,withDestinationURL:source.appendingPathComponent("catalogue.json"))
  do { _=try StudioImageCatalogue(directory:copy);throw TestFailure(message:"Symlink manifest accepted") } catch is StudioImageCatalogue.CatalogueError { }
  try fm.removeItem(at:manifest);try original.write(to:manifest)
  let license=copy.appendingPathComponent(copied.licenses[0].licenseFilename)
  try Data("Unverified rights".utf8).write(to:license)
  do { _=try StudioImageCatalogue(directory:copy);throw TestFailure(message:"Missing license evidence accepted") } catch is StudioImageCatalogue.CatalogueError { }
  try require(try Data(contentsOf:source.appendingPathComponent(item.filename))==bytes,"Original asset changed")
  try require(try Data(contentsOf:source.appendingPathComponent("catalogue.json"))==original,"Original manifest changed")
  pass("symlink manifest and corrupt license text fail with original source intact")
  let policy = try StudioImageCatalogue.ReleasePolicy(revision: 1, quarantined: [])
  let governed = try StudioImageCatalogue(directory: source, releasePolicy: policy)
  let selected = governed.images[0]
  try require(governed.catalogueRevision == 1, "Legacy catalogue revision changed")
  let quarantine = StudioImageCatalogue.ReleasePolicy.Quarantine(assetID: selected.id, sha256: selected.sha256, reason: "Isolated test rights review")
  try policy.advance(revision: 2, quarantined: [quarantine])
  try require(governed.images == catalogue.images && governed.availableImages.count == 206, "Policy mutated inventory or failed to hide asset")
  try require(!governed.search("").contains(selected), "Quarantine search bypass")
  do { _ = try governed.checkedPNG(selected); throw TestFailure(message: "Quarantine bytes bypass") } catch StudioImageCatalogue.CatalogueError.quarantined { }
  do { _ = try governed.sourceURL(for: selected); throw TestFailure(message: "Quarantine URL bypass") } catch StudioImageCatalogue.CatalogueError.quarantined { }
  do { _ = try governed.attribution(for: selected); throw TestFailure(message: "Quarantine provenance bypass") } catch StudioImageCatalogue.CatalogueError.quarantined { }
  do { try policy.advance(revision: 1, quarantined: []); throw TestFailure(message: "Policy rollback") } catch StudioImageCatalogue.CatalogueError.invalid { }
  do { _ = try StudioImageCatalogue.ReleasePolicy(revision: 3, quarantined: [quarantine, quarantine]); throw TestFailure(message: "Duplicate policy") } catch StudioImageCatalogue.CatalogueError.invalid { }
  // The previous corruption case deliberately damaged this copied license.
  // Restore its verified source bytes before testing manifest revision semantics.
  try Data(contentsOf: source.appendingPathComponent(copied.licenses[0].licenseFilename)).write(to: license)
  do { _ = try StudioImageCatalogue.ReleasePolicy(revision: 0, quarantined: []); throw TestFailure(message: "Zero policy revision accepted") } catch StudioImageCatalogue.CatalogueError.invalid { }
  do { _ = try StudioImageCatalogue.ReleasePolicy(revision: 3, quarantined: [.init(assetID: selected.id, sha256: "not-a-digest", reason: "Isolated test")]); throw TestFailure(message: "Invalid policy digest accepted") } catch StudioImageCatalogue.CatalogueError.invalid { }
  var revisionManifest = try JSONSerialization.jsonObject(with: original) as! [String: Any]
  revisionManifest["catalogueRevision"] = 2
  try JSONSerialization.data(withJSONObject: revisionManifest).write(to: manifest)
  let revised = try StudioImageCatalogue(directory: copy, releasePolicy: policy)
  try require(revised.catalogueRevision == 2 && revised.images == governed.images && revised.availableImages.count == 206, "New manifest overrode policy or IDs")
  revisionManifest["catalogueRevision"] = 0
  try JSONSerialization.data(withJSONObject: revisionManifest).write(to: manifest)
  do { _ = try StudioImageCatalogue(directory: copy); throw TestFailure(message: "Invalid revision accepted") } catch StudioImageCatalogue.CatalogueError.invalid { }
  try original.write(to: manifest)
  try policy.advance(revision: 3, quarantined: [])
  try require(try governed.checkedPNG(selected) == catalogue.checkedPNG(selected), "Explicit new release failed to restore verified bytes")
  pass("legacy and new catalogue revisions preserve IDs; trusted quarantine blocks direct use and stale manifests")
  // #198: versioned manifest revisions quarantine, remove and correct metadata
  // offline, without changing stable IDs, verified bytes or a project's copy.
  typealias Policy = StudioImageCatalogue.ReleasePolicy
  let versioned = try Policy(Policy.Revision(revision: 1))
  let live = try StudioImageCatalogue(directory: source, releasePolicy: versioned)
  let held = live.images[1], dropped = live.images[2]
  guard let corrected = live.images.first(where: { $0.contentAdvisory == .none && $0.id != held.id && $0.id != dropped.id }) else { throw TestFailure(message: "No unflagged fixture") }
  let projectCopy = try live.checkedPNG(held), correctedBytes = try live.checkedPNG(corrected)
  let revision2 = Policy.Revision(revision: 2,
    quarantined: [.init(assetID: held.id, sha256: held.sha256, reason: "Isolated test rights review")],
    removed: [.init(assetID: dropped.id, sha256: dropped.sha256, reason: "Isolated test withdrawal")],
    metadata: [.init(assetID: corrected.id, sha256: corrected.sha256, title: "Revised test title", tags: ["revisedtesttag"], contentAdvisory: .cartoonWeapons)])
  try versioned.advance(to: revision2)
  try require(versioned.currentRevision == 2 && live.images == catalogue.images && live.availableImages.count == 205, "Revision changed inventory or availability count")
  try require(live.removedImages == [dropped], "Removal not reported")
  guard let shown = live.availableImages.first(where: { $0.id == corrected.id }) else { throw TestFailure(message: "Corrected asset hidden") }
  try require(shown.title == "Revised test title" && shown.tags == ["revisedtesttag"] && shown.contentAdvisory == .cartoonWeapons
              && shown.sha256 == corrected.sha256 && shown.byteCount == corrected.byteCount && shown.licenseID == corrected.licenseID, "Metadata correction changed identity or bytes")
  try require(live.search("revisedtesttag").map(\.id) == [corrected.id] && live.search("revisedtesttag", includeCartoonWeapons: false).isEmpty, "Search ignored corrected tags or advisory")
  try require(try live.checkedPNG(shown) == correctedBytes && live.attribution(for: shown)["assetID"] == corrected.id && live.contains(shown), "Displayed record not accepted by importer path")
  let forged = StudioImageCatalogue.Image(id: shown.id, title: shown.title, category: shown.category, tags: shown.tags, contentAdvisory: shown.contentAdvisory,
    licenseID: shown.licenseID, originalSHA256: shown.originalSHA256, sha256: shown.sha256, pixelSHA256: shown.pixelSHA256,
    filename: shown.filename, byteCount: shown.byteCount + 1, width: shown.width, height: shown.height)
  try require(!live.contains(forged), "Forged byte count accepted")
  do { _ = try live.checkedPNG(forged); throw TestFailure(message: "Forged record decoded") } catch StudioImageCatalogue.CatalogueError.invalid { }
  for asset in [held, dropped] {
   do { _ = try live.checkedPNG(asset); throw TestFailure(message: "Withdrawn asset usable") } catch StudioImageCatalogue.CatalogueError.quarantined { }
  }
  try require(projectCopy == (try Data(contentsOf: source.appendingPathComponent(held.filename))), "Revision changed an original")
  for stale in [Policy.Revision(revision: 2), Policy.Revision(revision: 1)] {
   do { try versioned.advance(to: stale); throw TestFailure(message: "Stale revision \(stale.revision) accepted") } catch StudioImageCatalogue.CatalogueError.invalid { }
  }
  try require(versioned.current == revision2, "Refused revision changed state")
  let invalidRevisions = [
   Policy.Revision(revision: 3, removed: [.init(assetID: dropped.id, sha256: dropped.sha256, reason: "a"), .init(assetID: dropped.id, sha256: dropped.sha256, reason: "b")]),
   Policy.Revision(revision: 3, metadata: [.init(assetID: corrected.id, sha256: corrected.sha256)]),
   Policy.Revision(revision: 3, metadata: [.init(assetID: corrected.id, sha256: corrected.sha256, tags: ["dup", "dup"])]),
   Policy.Revision(revision: 3, metadata: [.init(assetID: "../escape", sha256: corrected.sha256, title: "x")]),
   Policy.Revision(revision: 3, removed: [.init(assetID: dropped.id, sha256: "not-a-digest", reason: "x")])]
  for invalid in invalidRevisions {
   do { try versioned.advance(to: invalid); throw TestFailure(message: "Invalid revision accepted") } catch StudioImageCatalogue.CatalogueError.invalid { }
  }
  try require(versioned.currentRevision == 2, "Invalid revision advanced policy")
  pass("versioned manifest revision quarantines removes and corrects metadata with stable IDs and refuses stale or malformed revisions")
  // A removed asset's library file may be absent offline; nothing else breaks.
  let offline = root.appendingPathComponent("offline"); try fm.copyItem(at: source, to: offline)
  try fm.removeItem(at: offline.appendingPathComponent(dropped.filename))
  let offlineCatalogue = try StudioImageCatalogue(directory: offline, releasePolicy: versioned)
  try require(offlineCatalogue.images.count == 207 && offlineCatalogue.availableImages.count == 205, "Missing removed file broke offline load")
  do { _ = try offlineCatalogue.checkedPNG(dropped); throw TestFailure(message: "Missing removed asset reported available") } catch StudioImageCatalogue.CatalogueError.quarantined { }
  try require(try offlineCatalogue.checkedPNG(shown) == correctedBytes, "Other assets failed after removal")
  try versioned.advance(to: Policy.Revision(revision: 3))
  try require(try live.checkedPNG(held) == projectCopy && live.availableImages.first(where: { $0.id == corrected.id }) == corrected, "Newer release did not restore manifest metadata or availability")
  do { _ = try offlineCatalogue.checkedPNG(dropped); throw TestFailure(message: "Deleted file decoded") } catch StudioImageCatalogue.CatalogueError.invalid { }
  try require(try Data(contentsOf: source.appendingPathComponent(dropped.filename)).count == dropped.byteCount, "Source asset changed by removal")
  pass("offline removal of a withdrawn cached file leaves other assets and every original intact; later revisions apply in order")
  print("STUDIO_IMAGE_CATALOGUE_TESTS=PASS \(groups)/\(groups), 207 original PNGs")
 }
}
