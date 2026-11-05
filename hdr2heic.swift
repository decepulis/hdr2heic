// hdr2heic: image (TIFF/AVIF/EXR...) -> HEIC. HDR inputs get an SDR base + ISO 21496-1 gain map;
// inputs with nothing above SDR white become a plain SDR HEIC.
// usage: hdr2heic <file-or-folder>... [--quality 0.6] [--gainmap-scale 0.5] [--jobs 6] [--force]
// Writes <name>.heic next to each input. Folders: converts every .tif/.tiff inside. Skips existing .heic unless --force.
import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

setvbuf(stdout, nil, _IOLBF, 0)  // progress shows up even when piped
var args = Array(CommandLine.arguments.dropFirst())
func opt(_ name: String, _ def: Double) -> Double {
    if let i = args.firstIndex(of: name) { let v = Double(args[i + 1])!; args.removeSubrange(i...i + 1); return v }
    return def
}
let quality = opt("--quality", 0.6), gmScale = opt("--gainmap-scale", 0.5), jobs = Int(opt("--jobs", 6))
let force = args.contains("--force"); args.removeAll { $0 == "--force" }
let worker = args.contains("--worker"); args.removeAll { $0 == "--worker" }  // internal: convert one file

guard !args.isEmpty else { print("usage: hdr2heic <file-or-folder>... [--quality 0.6] [--gainmap-scale 0.5] [--jobs 6] [--force]"); exit(1) }

let ctx = CIContext(options: [.cacheIntermediates: false])  // keeps memory flat across a batch
@Sendable func toneMapped(_ i: CIImage) -> CIImage { i.applyingFilter("CIToneMapHeadroom", parameters: ["inputTargetHeadroom": 1.0]) }
@Sendable func downscale(_ i: CIImage, _ s: Double) -> CIImage {
    let w = (i.extent.width * s).rounded(), h = (i.extent.height * s).rounded()
    return i.transformed(by: CGAffineTransform(scaleX: w / i.extent.width, y: h / i.extent.height))
        .cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
}
let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
func convert(_ inURL: URL, _ outURL: URL) throws -> String {
    guard let src = CGImageSourceCreateWithURL(inURL as CFURL, nil) else { throw Fail("cannot read \(inURL.path)") }
    let hdr: CIImage
    if CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, kCGImageAuxiliaryDataTypeISOGainMap) != nil
        || CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, kCGImageAuxiliaryDataTypeHDRGainMap) != nil {
        // Input already has a gain map: let Core Image apply it.
        guard let i = CIImage(contentsOf: inURL, options: [.expandToHDR: true]) else { throw Fail("cannot read \(inURL.path)") }
        hdr = i
    } else {
        // Decode once up front; letting Core Image pull lazily from the file is roughly 2x slower.
        guard let cg = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { throw Fail("cannot decode \(inURL.path)") }
        hdr = CIImage(cgImage: cg, options: [.expandToHDR: true])
    }
    let sdr = toneMapped(hdr)

    // 1. Let Core Image compute the gain map at its final size (temp file), then pull it out.
    //    Computing it on a downscaled copy is much faster than computing full-size and shrinking it.
    let small = gmScale < 1.0 ? downscale(hdr, gmScale) : hdr
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".heic")
    defer { try? FileManager.default.removeItem(at: tmp) }
    try ctx.writeHEIFRepresentation(of: toneMapped(small), to: tmp, format: .RGBA8, colorSpace: p3,
        options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 1.0, .hdrImage: small])
    let tmpSrc = CGImageSourceCreateWithURL(tmp as CFURL, nil)!
    // No gain map means no content above SDR white: write a plain SDR HEIC.
    let gm = CGImageSourceCopyAuxiliaryDataInfoAtIndex(tmpSrc, 0, kCGImageAuxiliaryDataTypeISOGainMap) as? [String: Any]

    // 2. Encode the SDR base exactly once, with original metadata, plus the gain map if any.
    let cg = ctx.createCGImage(sdr, from: sdr.extent, format: .RGBA8, colorSpace: p3)!
    let dest = CGImageDestinationCreateWithURL(outURL as CFURL, UTType.heic.identifier as CFString, 1, nil)!
    var props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] ?? [:]
    props[kCGImagePropertyOrientation as String] = nil  // pixels are already upright
    props[kCGImageDestinationLossyCompressionQuality as String] = quality
    CGImageDestinationAddImage(dest, cg, props as CFDictionary)
    if let gm { CGImageDestinationAddAuxiliaryDataInfo(dest, kCGImageAuxiliaryDataTypeISOGainMap, gm as CFDictionary) }
    guard CGImageDestinationFinalize(dest) else { throw Fail("write failed") }
    let size = (try FileManager.default.attributesOfItem(atPath: outURL.path)[.size] as! Int)
    let kind = gm != nil ? "HDR, gain map scale \(gmScale)" : "SDR, no HDR content"
    return "\(outURL.lastPathComponent): \(size / 1000) KB (quality \(quality), \(kind))"
}

struct Fail: Error { let msg: String; init(_ m: String) { msg = m } }
var inputs: [URL] = []
for a in args {
    let u = URL(fileURLWithPath: a); var isDir: ObjCBool = false
    FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir)
    if isDir.boolValue {
        let items = (try? FileManager.default.contentsOfDirectory(at: u, includingPropertiesForKeys: nil)) ?? []
        inputs += items.filter { ["tif", "tiff"].contains($0.pathExtension.lowercased()) }.sorted { $0.path < $1.path }
    } else { inputs.append(u) }
}
// Convert several photos at once. Core Image's gain map step runs one at a time per process,
// so parallelism comes from running worker copies of this tool, one photo each.
let todo = worker ? inputs : inputs.filter { u in
    let exists = FileManager.default.fileExists(atPath: u.deletingPathExtension().appendingPathExtension("heic").path)
    if exists && !force { print("skip (exists) \(u.deletingPathExtension().lastPathComponent).heic") }
    return force || !exists
}
func runOne(_ u: URL) -> String {
    let out = u.deletingPathExtension().appendingPathExtension("heic")
    do { return try autoreleasepool { try convert(u, out) } } catch { return "FAILED \(u.lastPathComponent): \(error)" }
}
func runWorker(_ u: URL) -> String {
    let p = Process(), pipe = Pipe()
    p.executableURL = Bundle.main.executableURL  // this binary, however it was invoked
    p.arguments = ["--worker", u.path, "--quality", "\(quality)", "--gainmap-scale", "\(gmScale)"]
    p.standardOutput = pipe; p.standardError = pipe
    do { try p.run() } catch { return "FAILED \(u.lastPathComponent): \(error)" }
    let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    p.waitUntilExit()
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}
if worker { print(runOne(todo[0])); exit(0) }

let lock = NSLock()
var done = 0, failed = 0
let queue = OperationQueue()
queue.maxConcurrentOperationCount = max(1, jobs)
for u in todo {
    queue.addOperation {
        let line = (jobs > 1 && todo.count > 1) ? runWorker(u) : runOne(u)
        lock.lock(); done += 1; if line.hasPrefix("FAILED") || line.isEmpty { failed += 1 }
        print("[\(done)/\(todo.count)] \(line.isEmpty ? "FAILED \(u.lastPathComponent): worker crashed" : line)"); lock.unlock()
    }
}
queue.waitUntilAllOperationsAreFinished()
exit(failed > 0 ? 1 : 0)
