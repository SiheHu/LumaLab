import LumaDomain
import Foundation

/// Embeds private edit parameters in the standard TIFF XMP tag (700), without re-encoding RAW.
/// The original RAW/Exif payload is untouched. Existing XMP directory entries are updated
/// in place; files without XMP receive a new standard first directory.
enum DNGMetadataStore {
    static let namespace = "https://lumalab.app/ns/edit/1.0/"
    private static let begin = "<!-- LumaLab state begin -->"
    private static let end = "<!-- LumaLab state end -->"
    private static let maximumXMP = 64 * 1024 * 1024
    private struct Envelope: Codable {
        var version = 1
        var originalLength: Int
        var originalIFD: UInt64
        var originalSHA256: String
        var originalDirectory: Data?
        var document: SidecarDocument
    }
    enum Failure: LocalizedError {
        case invalidTIFF, invalidXMP, unsupported, changed, tooLarge
        var errorDescription: String? {
            switch self {
            case .invalidTIFF: return "DNG 的 TIFF 目录损坏，未写入任何内容。"
            case .invalidXMP: return "DNG 的 XMP 元数据无法安全合并，未写入任何内容。"
            case .unsupported: return "DNG 内嵌参数版本暂不支持，未写入任何内容。"
            case .changed: return "DNG 原始内容已改变，未应用或覆盖旧参数。"
            case .tooLarge: return "DNG 内嵌参数超出安全大小限制，未写入任何内容。"
            }
        }
    }

    static func isDNG(data: Data) -> Bool { (try? TIFF(data)) != nil }

    static func read(data: Data) throws -> SidecarDocument? {
        let file = try TIFF(data)
        guard let packet = try file.xmp(), let envelope = try decode(packet) else { return nil }
        _ = try original(data, file: file, envelope: envelope)
        guard envelope.document.version == 2 else { throw Failure.unsupported }
        guard envelope.document.sourceSHA256 == envelope.originalSHA256 else { throw Failure.changed }
        return envelope.document
    }

    /// Stable across this writer's metadata updates; original photographic bytes are hashed verbatim.
    static func identity(data: Data) throws -> String {
        let file = try TIFF(data)
        if let packet = try file.xmp(), let envelope = try decode(packet) {
            _ = try original(data, file: file, envelope: envelope)
            return envelope.originalSHA256
        }
        return WorkflowStore.digest(data)
    }

    static func embed(document: SidecarDocument, in data: Data) throws -> Data {
        let current = try TIFF(data)
        let packet = try current.xmp()
        let existing = try packet.flatMap { try decode($0) }
        let base = try existing.map { try original(data, file: current, envelope: $0) } ?? data
        let sourceHash = WorkflowStore.digest(base)
        guard document.sourceSHA256 == sourceHash || document.sourceSHA256 == WorkflowStore.digest(data) else { throw Failure.changed }
        guard document.version == 2 else { throw Failure.unsupported }
        let originalFile = try TIFF(base)
        var stored = document
        stored.sourceSHA256 = sourceHash
        let hasExistingEntry = originalFile.entries.contains { $0.tag == 700 }
        let backup = hasExistingEntry ? base.subdata(in: originalFile.directoryRange) : nil
        let envelope = Envelope(originalLength: base.count, originalIFD: originalFile.rootOffset,
                                originalSHA256: sourceHash, originalDirectory: backup, document: stored)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(envelope).base64EncodedString()
        let xmp = try merge(packet: packet, state: encoded)
        guard xmp.count <= UInt64(maximumXMP) else { throw Failure.tooLarge }
        var result = base
        if result.count % 2 != 0 { result.append(0) }
        let xmpOffset = UInt64(result.count)
        result.append(xmp)
        if result.count % 2 != 0 { result.append(0) }
        let directoryOffset = UInt64(result.count)
        var entries = originalFile.entries.filter { $0.tag != 700 }
        var xmpEntry = Data()
        originalFile.append(700, width: 2, to: &xmpEntry)
        originalFile.append(1, width: 2, to: &xmpEntry) // BYTE, per XMP storage specification.
        originalFile.append(UInt64(xmp.count), width: originalFile.big ? 8 : 4, to: &xmpEntry)
        originalFile.append(xmpOffset, width: originalFile.offsetWidth, to: &xmpEntry)
        entries.append(TIFF.Entry(tag: 700, bytes: xmpEntry))
        entries.sort { $0.tag < $1.tag }
        guard (originalFile.big || entries.count <= Int(UInt16.max)),
              originalFile.big || UInt64(result.count + entries.count * 12 + 6) <= UInt64(UInt32.max) else { throw Failure.tooLarge }
        var directory = Data()
        originalFile.append(UInt64(entries.count), width: originalFile.big ? 8 : 2, to: &directory)
        for entry in entries { directory.append(entry.bytes) }
        originalFile.append(originalFile.nextIFD, width: originalFile.offsetWidth, to: &directory)
        if hasExistingEntry {
            // Keep IFD0 at its original location: macOS's type sniffer otherwise calls
            // some valid DNGs TIFF and silently selects their thumbnail as the RAW.
            result.replaceSubrange(originalFile.directoryRange, with: directory)
        } else {
            result.append(directory)
            originalFile.replace(directoryOffset, at: originalFile.headerOffset, width: originalFile.offsetWidth, in: &result)
        }
        // Verify our complete result before the caller performs an atomic replacement.
        guard try read(data: result)?.sourceSHA256 == sourceHash else { throw Failure.invalidXMP }
        return result
    }

    private static func original(_ data: Data, file: TIFF, envelope: Envelope) throws -> Data {
        guard envelope.version == 1 else { throw Failure.unsupported }
        guard envelope.originalLength >= (file.big ? 16 : 8), envelope.originalLength <= data.count,
              envelope.originalIFD < UInt64(envelope.originalLength) else { throw Failure.changed }
        var base = Data(data.prefix(envelope.originalLength))
        file.replace(envelope.originalIFD, at: file.headerOffset, width: file.offsetWidth, in: &base)
        if let directory = envelope.originalDirectory {
            guard envelope.originalIFD <= UInt64(base.count), directory.count <= base.count - Int(envelope.originalIFD) else { throw Failure.changed }
            base.replaceSubrange(Int(envelope.originalIFD)..<(Int(envelope.originalIFD) + directory.count), with: directory)
        }
        guard WorkflowStore.digest(base) == envelope.originalSHA256 else { throw Failure.changed }
        let originalFile = try TIFF(base)
        // A relocated directory must still refer to exactly the original RAW/Exif graph.
        let a = originalFile.entries.filter { $0.tag != 700 }.map(\.bytes)
        let b = file.entries.filter { $0.tag != 700 }.map(\.bytes)
        guard a == b, originalFile.nextIFD == file.nextIFD else { throw Failure.changed }
        return base
    }

    private static func decode(_ data: Data) throws -> Envelope? {
        guard data.count <= UInt64(maximumXMP) else { throw Failure.tooLarge }
        let reader = XMPReader()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        guard parser.parse(), !reader.invalid, reader.rdfName != nil else { throw Failure.invalidXMP }
        guard let value = reader.state else { return nil }
        guard let decoded = Data(base64Encoded: value, options: .ignoreUnknownCharacters), decoded.count <= UInt64(maximumXMP) else { throw Failure.invalidXMP }
        do { return try JSONDecoder().decode(Envelope.self, from: decoded) }
        catch { throw Failure.invalidXMP }
    }

    private static func merge(packet: Data?, state: String) throws -> Data {
        var text: String
        if let packet = packet {
            guard let decoded = String(data: packet, encoding: .utf8), !decoded.localizedCaseInsensitiveContains("<!DOCTYPE") else { throw Failure.invalidXMP }
            text = decoded.trimmingCharacters(in: .init(charactersIn: "\0"))
            // Our own appended block can be removed without touching any existing XMP byte.
            if let start = text.range(of: begin), let finish = text.range(of: end, range: start.upperBound..<text.endIndex) {
                text.removeSubrange(start.lowerBound..<finish.upperBound)
            } else {
                // An external XMP writer may have reformatted the private property.
                // Preserve every foreign property semantically through Foundation's XML parser.
                let xml = try XMLDocument(xmlString: text, options: [.nodePreserveAll])
                let nodes = matchingNodes(in: xml, uri: namespace, localName: "State")
                for node in nodes { node.detach() }
                if !nodes.isEmpty { text = xml.xmlString(options: [.nodePreserveAll]) }
            }
        } else {
            text = "<?xpacket begin=\"\u{feff}\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?><x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\"></rdf:RDF></x:xmpmeta><?xpacket end=\"w\"?>"
        }
        let reader = XMPReader()
        let parser = XMLParser(data: Data(text.utf8)); parser.shouldProcessNamespaces = true; parser.shouldReportNamespacePrefixes = true
        parser.shouldResolveExternalEntities = false; parser.delegate = reader
        guard parser.parse(), let rdfName = reader.rdfName, !reader.invalid else { throw Failure.invalidXMP }
        let block = begin + "<rdf:Description xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\" rdf:about=\"\"><luma:State xmlns:luma=\"\(namespace)\">\(state)</luma:State></rdf:Description>" + end
        if let closing = text.range(of: "</" + rdfName + ">", options: .backwards) {
            text.insert(contentsOf: block, at: closing.lowerBound)
        } else {
            // Empty RDF can use the self-closing form; let XML handle arbitrary attributes.
            let xml = try XMLDocument(xmlString: text, options: [.nodePreserveAll])
            guard let rdf = matchingNodes(in: xml, uri: "http://www.w3.org/1999/02/22-rdf-syntax-ns#", localName: "RDF").first as? XMLElement else { throw Failure.invalidXMP }
            let description = try XMLElement(xmlString: "<rdf:Description xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\" rdf:about=\"\"><luma:State xmlns:luma=\"\(namespace)\">\(state)</luma:State></rdf:Description>")
            rdf.addChild(XMLNode.comment(withStringValue: " LumaLab state begin ") as! XMLNode)
            rdf.addChild(description)
            rdf.addChild(XMLNode.comment(withStringValue: " LumaLab state end ") as! XMLNode)
            text = xml.xmlString(options: [.nodePreserveAll])
        }
        return Data(text.utf8)
    }

    private static func matchingNodes(in node: XMLNode, uri: String, localName: String) -> [XMLNode] {
        var matches: [XMLNode] = node.uri == uri && node.localName == localName ? [node] : []
        if let element = node as? XMLElement {
            for attribute in element.attributes ?? [] where attribute.uri == uri && attribute.localName == localName { matches.append(attribute) }
        }
        for child in node.children ?? [] { matches += matchingNodes(in: child, uri: uri, localName: localName) }
        return matches
    }

    private final class XMPReader: NSObject, XMLParserDelegate {
        var rdfName: String?
        var state: String?
        var invalid = false
        private var reading = false
        private var mappings: [String: [String]] = [:]
        func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI namespaceURI: String) { mappings[prefix, default: []].append(namespaceURI) }
        func parser(_ parser: XMLParser, didEndMappingPrefix prefix: String) { _ = mappings[prefix]?.popLast() }
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
            for (name, value) in attributes {
                let components = name.split(separator: ":", maxSplits: 1)
                if components.count == 2, components[1] == "State", mappings[String(components[0])]?.last == DNGMetadataStore.namespace {
                    if state != nil { invalid = true }; state = value
                }
            }
            if namespaceURI == "http://www.w3.org/1999/02/22-rdf-syntax-ns#" && elementName == "RDF" {
                if rdfName != nil { invalid = true }; rdfName = qName ?? elementName
            }
            if namespaceURI == DNGMetadataStore.namespace && elementName == "State" {
                if state != nil { invalid = true }; state = ""; reading = true
            } else if reading { invalid = true }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { if reading { state? += string } }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            if namespaceURI == DNGMetadataStore.namespace && elementName == "State" { reading = false }
        }
        func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { invalid = true }
        func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { invalid = true }
    }

    /// Bounds-checked classic TIFF and BigTIFF first-directory reader. All offsets are absolute.
    private struct TIFF {
        struct Entry { var tag: UInt64; var bytes: Data }
        let data: Data
        let little: Bool
        let big: Bool
        let rootOffset: UInt64
        let entries: [Entry]
        let nextIFD: UInt64
        var directoryRange: Range<Int> { let start = Int(rootOffset); return start..<(start + (big ? 8 : 2) + entries.count * (big ? 20 : 12) + (big ? 8 : 4)) }
        var offsetWidth: Int { big ? 8 : 4 }
        var headerOffset: Int { big ? 8 : 4 }
        init(_ value: Data) throws {
            data = value
            guard value.count >= 8, (value[0] == 73 && value[1] == 73) || (value[0] == 77 && value[1] == 77) else { throw Failure.invalidTIFF }
            little = value[0] == 73
            let isLittle = value[0] == 73
            func integer(_ at: Int, _ width: Int) throws -> UInt64 {
                guard at >= 0, width <= value.count, at <= value.count - width else { throw Failure.invalidTIFF }
                var result: UInt64 = 0
                for i in 0..<width { result |= UInt64(value[at+i]) << ((isLittle ? i : width-i-1) * 8) }
                return result
            }
            let magic = try integer(2, 2)
            guard magic == 42 || magic == 43 else { throw Failure.invalidTIFF }
            big = magic == 43
            if big { guard try integer(4, 2) == 8, try integer(6, 2) == 0 else { throw Failure.invalidTIFF } }
            let width = big ? 8 : 4, countWidth = big ? 8 : 2, entryWidth = big ? 20 : 12
            rootOffset = try integer(big ? 8 : 4, width)
            guard rootOffset <= UInt64(Int.max) else { throw Failure.invalidTIFF }
            let start = Int(rootOffset)
            let count = try integer(start, countWidth)
            guard count <= 65535, start <= value.count - countWidth,
                  count <= UInt64((value.count - start - countWidth) / entryWidth),
                  start + countWidth + Int(count) * entryWidth <= value.count - width else { throw Failure.invalidTIFF }
            var parsed: [Entry] = []; var previous: UInt64?
            for index in 0..<Int(count) {
                let offset = start + countWidth + index * entryWidth
                let tag = try integer(offset, 2)
                guard previous == nil || tag > previous! else { throw Failure.invalidTIFF }
                previous = tag
                parsed.append(Entry(tag: tag, bytes: value.subdata(in: offset..<(offset+entryWidth))))
            }
            entries = parsed
            nextIFD = try integer(start + countWidth + Int(count) * entryWidth, width)
            guard entries.contains(where: { $0.tag == 50706 }) else { throw Failure.invalidTIFF }
        }
        func value(_ bytes: Data, at: Int, width: Int) -> UInt64 {
            var result: UInt64 = 0
            for i in 0..<width { result |= UInt64(bytes[at+i]) << ((little ? i : width-i-1) * 8) }
            return result
        }
        func xmp() throws -> Data? {
            guard let entry = entries.first(where: { $0.tag == 700 }) else { return nil }
            let type = value(entry.bytes, at: 2, width: 2)
            guard type == 1 || type == 7 else { throw Failure.invalidXMP }
            let count = value(entry.bytes, at: 4, width: big ? 8 : 4)
            guard count > 0, count <= UInt64(maximumXMP) else { throw Failure.invalidXMP }
            let slot = big ? 12 : 8
            if count <= offsetWidth { return entry.bytes.subdata(in: slot..<(slot+Int(count))) }
            let offset = value(entry.bytes, at: slot, width: offsetWidth)
            guard offset <= UInt64(data.count), count <= UInt64(data.count) - offset else { throw Failure.invalidXMP }
            return data.subdata(in: Int(offset)..<(Int(offset)+Int(count)))
        }
        func append(_ number: UInt64, width: Int, to result: inout Data) {
            for i in 0..<width { result.append(UInt8(truncatingIfNeeded: number >> ((little ? i : width-i-1) * 8))) }
        }
        func replace(_ number: UInt64, at offset: Int, width: Int, in result: inout Data) {
            var bytes = Data(); append(number, width: width, to: &bytes)
            result.replaceSubrange(offset..<(offset+width), with: bytes)
        }
    }
}
