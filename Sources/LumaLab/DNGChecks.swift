import LumaDomain
import Foundation
import CoreImage
import ImageIO

/// Runs entirely on generated data or temporary copies; never writes installed DNG fixtures.
enum DNGChecks {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { "DNG check failed: \(message)" }
    }
    static func run() throws -> String {
        var assertions = 0
        func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
            guard try condition() else { throw Failure(message: message) }; assertions += 1
        }
        func rejects(_ action: () throws -> Void, _ message: String) throws {
            var rejected = false
            do { try action() } catch { rejected = true }
            try check(rejected, message)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LumaLab-DNGChecks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let foreignXMP = "<?xpacket begin=\"\u{feff}\"?><x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><r:RDF xmlns:r=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\"><r:Description xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:crs=\"http://ns.adobe.com/camera-raw-settings/1.0/\" crs:Exposure2012=\"0.75\"><dc:description><r:Alt><r:li xml:lang=\"x-default\">Original &amp; unchanged</r:li></r:Alt></dc:description></r:Description></r:RDF></x:xmpmeta><?xpacket end=\"w\"?>"
        var originalLength = 0, embeddedLength = 0
        for big in [false, true] {
            for little in [false, true] {
                for xmp in [nil, foreignXMP, "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\" /></x:xmpmeta>"] as [String?] {
                    let source = synthetic(little: little, big: big, xmp: xmp)
                    try check(try DNGMetadataStore.read(data: source) == nil, "unmodified file has no private settings")
                    var doc = SidecarDocument(sourceSHA256: WorkflowStore.digest(source), sourceFilename: "test.dng", edits: .init())
                    doc.edits.adjustments.exposure = 1.25
                    let first = try DNGMetadataStore.embed(document: doc, in: source)
                    let recovered = try DNGMetadataStore.read(data: first)
                    try check(recovered?.edits.adjustments.exposure == 1.25, "TIFF endian/layout settings round trip")
                    try check(try DNGMetadataStore.identity(data: first) == WorkflowStore.digest(source), "stable photographic identity")
                    let pointerRange = big ? 8..<16 : 4..<8
                    var original = source, prefix = Data(first.prefix(source.count))
                    original.replaceSubrange(pointerRange, with: [UInt8](repeating: 0, count: pointerRange.count))
                    prefix.replaceSubrange(pointerRange, with: [UInt8](repeating: 0, count: pointerRange.count))
                    if xmp != nil {
                        let entryStart = (big ? 16 : 8) + (big ? 8 : 2)
                        let entrySize = big ? 20 : 12
                        original.replaceSubrange(entryStart..<(entryStart+entrySize), with: [UInt8](repeating: 0, count: entrySize))
                        prefix.replaceSubrange(entryStart..<(entryStart+entrySize), with: [UInt8](repeating: 0, count: entrySize))
                    }
                    try check(prefix == original, "every original payload and Exif byte preserved")
                    if xmp == foreignXMP {
                        let text = String(decoding: first, as: UTF8.self)
                        try check(text.components(separatedBy: "crs:Exposure2012=\"0.75\"").count == 3, "foreign XMP unchanged in original and active packet")
                    }
                    doc.sourceSHA256 = WorkflowStore.digest(first)
                    doc.edits.adjustments.exposure = -2
                    let second = try DNGMetadataStore.embed(document: doc, in: first)
                    try check(try DNGMetadataStore.read(data: second)?.edits.adjustments.exposure == -2, "second save restores new parameters")
                    try check(abs(second.count - first.count) < 128, "repeated save replaces own tail instead of growing")
                    try check(try DNGMetadataStore.identity(data: second) == WorkflowStore.digest(source), "identity unchanged after repeated save")
                    var changed = second; changed[source.count - 1] ^= 1
                    try rejects({ _ = try DNGMetadataStore.read(data: changed) }, "changed original RAW bytes rejected")
                    var wrong = doc; wrong.sourceSHA256 = String(repeating: "0", count: 64)
                    try rejects({ _ = try DNGMetadataStore.embed(document: wrong, in: second) }, "stale source rejected before writing")
                    let destination = directory.appendingPathComponent("test-\(big)-\(little).dng")
                    try source.write(to: destination)
                    _ = try DNGMetadataStore.embed(document: SidecarDocument(sourceSHA256: WorkflowStore.digest(source), sourceFilename: "test.dng", edits: .init()), in: source)
                    try check(try Data(contentsOf: destination) == source, "pure preparation does not write before Done")
                    try first.write(to: destination, options: .atomic)
                    try check(try Data(contentsOf: destination) == first, "atomic byte replacement is exact")
                    originalLength += source.count; embeddedLength += first.count
                }
            }
        }
        try rejects({ _ = try DNGMetadataStore.read(data: Data("not TIFF".utf8)) }, "invalid header rejected")
        try rejects({ _ = try DNGMetadataStore.read(data: synthetic(little: true, big: false, xmp: "<broken>")) }, "invalid existing XMP preserved by refusing merge")
        // Standard XMP serializers may turn a simple element into an RDF attribute.
        let externalBase = synthetic(little: true, big: false, xmp: foreignXMP)
        let externalDoc = SidecarDocument(sourceSHA256: WorkflowStore.digest(externalBase), sourceFilename: "external.dng", edits: .init())
        let externalEmbedded = try DNGMetadataStore.embed(document: externalDoc, in: externalBase)
        let active = try activeXMP(externalEmbedded)
        var activeText = String(decoding: active, as: UTF8.self)
        let expression = try NSRegularExpression(pattern: "<luma:State xmlns:luma=\"[^\"]+\">([^<]+)</luma:State>")
        guard let match = expression.firstMatch(in: activeText, range: NSRange(activeText.startIndex..., in: activeText)),
              let stateRange = Range(match.range(at: 1), in: activeText), let fullRange = Range(match.range, in: activeText) else { throw Failure(message: "private XMP fixture") }
        let state = String(activeText[stateRange])
        activeText.replaceSubrange(fullRange, with: "")
        activeText = activeText.replacingOccurrences(of: "<!-- LumaLab state begin -->", with: "").replacingOccurrences(of: "<!-- LumaLab state end -->", with: "")
        activeText = activeText.replacingOccurrences(of: "<rdf:Description xmlns:rdf=", with: "<rdf:Description xmlns:luma=\"\(DNGMetadataStore.namespace)\" luma:State=\"\(state)\" xmlns:rdf=")
        activeText = activeText.replacingOccurrences(of: "Original &amp; unchanged", with: "Foreign newer metadata")
        let externallyRewritten = try replacingActiveXMP(externalEmbedded, with: Data(activeText.utf8))
        try check(try DNGMetadataStore.read(data: externallyRewritten) != nil, "external XMP attribute serialization restored")
        var externalUpdated = externalDoc; externalUpdated.sourceSHA256 = WorkflowStore.digest(externallyRewritten)
        externalUpdated.edits.adjustments.exposure = 2
        let reembedded = try DNGMetadataStore.embed(document: externalUpdated, in: externallyRewritten)
        try check(String(decoding: try activeXMP(reembedded), as: UTF8.self).contains("Foreign newer metadata"), "external foreign XMP changes survive subsequent save")
        try check(try DNGMetadataStore.read(data: reembedded)?.edits.adjustments.exposure == 2, "external serializer does not duplicate private state")
        let noXMP = synthetic(little: true, big: false, xmp: nil)
        var unsupported = SidecarDocument(sourceSHA256: WorkflowStore.digest(noXMP), sourceFilename: "test.dng", edits: .init()); unsupported.version = 99
        try rejects({ _ = try DNGMetadataStore.embed(document: unsupported, in: noXMP) }, "unsupported parameters do not replace DNG")
        for count in [0, 2, 7, 9, 11] {
            try rejects({ _ = try DNGMetadataStore.read(data: Data(noXMP.prefix(count))) }, "truncated TIFF fails safely")
        }
        let fixture = ProcessInfo.processInfo.environment["LUMALAB_DNG_FIXTURE"].map {URL(fileURLWithPath:$0)}
        var detail = ""
        if let fixture,FileManager.default.fileExists(atPath: fixture.path) {
            let source = try Data(contentsOf: fixture)
            let originalHash = WorkflowStore.digest(source)
            var doc = SidecarDocument(sourceSHA256: originalHash, sourceFilename: "masking.dng", edits: .init())
            doc.edits.adjustments.exposure = 0.5
            let started = Date()
            let embedded = try DNGMetadataStore.embed(document: doc, in: source)
            let elapsed = Date().timeIntervalSince(started)
            let target = directory.appendingPathComponent("real-copy.dng")
            try embedded.write(to: target, options: .atomic)
            try check(try DNGMetadataStore.read(data: Data(contentsOf: target))?.edits.adjustments.exposure == 0.5, "real DNG embedded read from disk")
            try check(try DNGMetadataStore.identity(data: embedded) == originalHash, "real DNG stable original identity")
            let before = try PhotoIO.decode(data: source, fileExtension: "dng")
            let after = try PhotoIO.decode(data: embedded, fileExtension: "dng")
            try check(before.image.extent == after.image.extent && before.image.extent.width > 500, "real RAW full decoded dimensions unchanged")
            let context = CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false])
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
            func pixels(_ image: CIImage, maximum: CGFloat = 256) throws -> Data {
                let size = image.extent.size
                let scale = min(1, maximum / max(size.width, size.height))
                let reduced = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                guard let result = context.createCGImage(reduced, from: reduced.extent.integral, format: .RGBA8, colorSpace: colorSpace),
                      let bytes = result.dataProvider?.data else { throw Failure(message: "real RAW comparison render") }
                return bytes as Data
            }
            try check(try pixels(before.image) == pixels(after.image), "real RAW decoded preview pixels bit-identical")
            try check(try pixels(before.image, maximum: 4096) == pixels(after.image, maximum: 4096), "real RAW full-resolution pixels bit-identical")
            let originalMetadata: NSDictionary? = CGImageSourceCreateWithData(source as CFData, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) }
            let updatedMetadata: NSDictionary? = CGImageSourceCreateWithData(embedded as CFData, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) }
            try check(originalMetadata?[kCGImagePropertyExifDictionary] as? NSDictionary == updatedMetadata?[kCGImagePropertyExifDictionary] as? NSDictionary, "real DNG Exif unchanged")
            let stripped = try removingXMP(source)
            try check(try DNGMetadataStore.read(data: stripped) == nil, "real DNG without prior XMP has no parameters")
            var noPacketDoc = doc; noPacketDoc.sourceSHA256 = WorkflowStore.digest(stripped)
            let relocated = try DNGMetadataStore.embed(document: noPacketDoc, in: stripped)
            let relocatedPhoto = try PhotoIO.decode(data: relocated, fileExtension: "dng")
            try check(relocatedPhoto.image.extent == before.image.extent, "real DNG without XMP decodes full RAW after directory relocation")
            try check(try pixels(relocatedPhoto.image) == pixels(before.image), "relocated first directory preserves RAW pixels")
            try check(try Data(contentsOf: fixture) == source, "installed DNG fixture never changed")
            detail = String(format: "; real DNG embedding %.1f ms, RAW pixels unchanged", elapsed * 1000)
        }
        return "DNG checks passed: \(assertions) assertions\(detail)."
    }

    private struct Layout {
        let little: Bool, big: Bool, root: Int, count: Int, countWidth: Int, entryWidth: Int, offsetWidth: Int
        func integer(_ data: Data, _ offset: Int, _ width: Int) -> UInt64 {
            var result: UInt64 = 0
            for i in 0..<width { result |= UInt64(data[offset+i]) << ((little ? i : width-i-1)*8) }
            return result
        }
        func bytes(_ value: UInt64, _ width: Int) -> Data { Data((0..<width).map { UInt8(truncatingIfNeeded: value >> ((little ? $0 : width-$0-1)*8)) }) }
        var entries: [Int] { (0..<count).map { root + countWidth + $0 * entryWidth } }
        func xmpEntry(_ data: Data) throws -> Int {
            guard let offset = entries.first(where: { integer(data,$0,2) == 700 }) else { throw Failure(message:"XMP directory fixture") }; return offset
        }
    }
    private static func layout(_ data: Data) -> Layout {
        let little = data[0] == 73
        func number(_ offset:Int,_ width:Int)->UInt64 {var n:UInt64=0;for i in 0..<width {n |= UInt64(data[offset+i]) << ((little ? i:width-i-1)*8)};return n}
        let big = number(2,2) == 43
        let root = Int(number(big ? 8:4,big ? 8:4)), cw = big ? 8:2
        return Layout(little:little,big:big,root:root,count:Int(number(root,cw)),countWidth:cw,entryWidth:big ? 20:12,offsetWidth:big ? 8:4)
    }
    private static func activeXMP(_ data: Data) throws -> Data {
        let l = layout(data), e = try l.xmpEntry(data), n = Int(l.integer(data,e+4,l.big ? 8:4))
        let offset = Int(l.integer(data,e+(l.big ? 12:8),l.offsetWidth))
        return data.subdata(in:offset..<(offset+n))
    }
    private static func replacingActiveXMP(_ data: Data, with packet: Data) throws -> Data {
        let l = layout(data), e = try l.xmpEntry(data)
        var result = data
        let offset = result.count
        result.append(packet)
        result.replaceSubrange((e+4)..<(e+4+(l.big ? 8:4)),with:l.bytes(UInt64(packet.count),l.big ? 8:4))
        let slot=e+(l.big ? 12:8)
        result.replaceSubrange(slot..<(slot+l.offsetWidth),with:l.bytes(UInt64(offset),l.offsetWidth))
        return result
    }
    private static func removingXMP(_ data: Data) throws -> Data {
        let l = layout(data), removed = try l.xmpEntry(data)
        var directory = l.bytes(UInt64(l.count-1),l.countWidth)
        for entry in l.entries where entry != removed {directory.append(data.subdata(in:entry..<(entry+l.entryWidth)))}
        let next=l.root+l.countWidth+l.count*l.entryWidth
        directory.append(data.subdata(in:next..<(next+l.offsetWidth)))
        var result=data;result.replaceSubrange(l.root..<(l.root+directory.count),with:directory);return result
    }
    private static func synthetic(little: Bool, big: Bool, xmp: String?) -> Data {
        var data = Data(little ? [73, 73] : [77, 77])
        func append(_ number: UInt64, width: Int, to bytes: inout Data) {
            for i in 0..<width { bytes.append(UInt8(truncatingIfNeeded: number >> ((little ? i : width-i-1) * 8))) }
        }
        append(big ? 43 : 42, width: 2, to: &data)
        if big { append(8, width: 2, to: &data); append(0, width: 2, to: &data) }
        let root = big ? 16 : 8
        append(UInt64(root), width: big ? 8 : 4, to: &data)
        let count = xmp == nil ? 2 : 3
        let payload = root + (big ? 8 : 2) + count * (big ? 20 : 12) + (big ? 8 : 4)
        append(UInt64(count), width: big ? 8 : 2, to: &data)
        func entry(_ tag: UInt64, type: UInt64, count: UInt64, value: UInt64) {
            append(tag, width: 2, to: &data); append(type, width: 2, to: &data)
            append(count, width: big ? 8 : 4, to: &data); append(value, width: big ? 8 : 4, to: &data)
        }
        if let xmp = xmp { entry(700, type: 1, count: UInt64(xmp.utf8.count), value: UInt64(payload)) }
        entry(50706, type: 1, count: 4, value: little ? 0x00000401 : (big ? 0x0104000000000000 : 0x01040000))
        entry(65000, type: 4, count: 1, value: 12345)
        append(0, width: big ? 8 : 4, to: &data)
        if let xmp = xmp { data.append(Data(xmp.utf8)) }
        data.append(contentsOf: [201, 23, 42, 99, 121, 231])
        return data
    }
}
