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
  print("STUDIO_IMAGE_CATALOGUE_TESTS=PASS \(groups)/\(groups), 207 original PNGs")
 }
}
