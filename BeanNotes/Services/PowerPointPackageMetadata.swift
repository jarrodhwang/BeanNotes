import Foundation
import zlib

/// Reads only bounded XML parts of an OOXML package. Media stays with the system
/// Office renderer; no archive entries are extracted into the filesystem.
nonisolated struct PowerPointPackageMetadata: Sendable {
    struct TextRotation: Sendable {
        var text: String
        var degrees: Double
        var x: Double
        var y: Double
        var width: Double
        var height: Double
    }

    var width: Double
    var height: Double
    var slides: [[TextRotation]]

    static func read(_ url: URL) throws -> Self {
        let archive = try OfficeZIPReader(url)
        let rootRelationships = try OfficeXMLNode.parse(archive.read("_rels/.rels"))
        let officeTarget = try required(rootRelationships.children.first {
            $0.attributes["Type"]?.hasSuffix("/officeDocument") == true && $0.attributes["TargetMode"] != "External"
        }?.attributes["Target"])
        let presentationPath = try resolve(officeTarget, relativeTo: "")
        let presentation = try OfficeXMLNode.parse(archive.read(presentationPath))
        let size = try required(presentation.child("sldSz"))
        let width = try number(size.attributes["cx"]), height = try number(size.attributes["cy"])
        guard width > 0, height > 0, width / 12_700 <= 14_400, height / 12_700 <= 14_400 else { throw invalid }
        let ids = try required(presentation.child("sldIdLst")).children.filter { $0.name == "sldId" }
        guard !ids.isEmpty, ids.count <= 2_000 else { throw invalid }
        let directory = (presentationPath as NSString).deletingLastPathComponent
        let file = (presentationPath as NSString).lastPathComponent
        let relationshipPath = [directory, "_rels", "\(file).rels"].filter { !$0.isEmpty }.joined(separator: "/")
        let relationships = try OfficeXMLNode.parse(archive.read(relationshipPath))
        var slides: [[TextRotation]] = []
        var totalXMLBytes = 0
        for id in ids {
            try Task.checkCancellation()
            let relationshipID = try required(id.attributes.first { $0.key.hasSuffix(":id") }?.value)
            let relationship = try required(relationships.children.first { $0.attributes["Id"] == relationshipID })
            guard relationship.attributes["TargetMode"] != "External",
                  relationship.attributes["Type"]?.hasSuffix("/slide") == true else { throw invalid }
            let path = try resolve(try required(relationship.attributes["Target"]), relativeTo: presentationPath)
            let data = try archive.read(path)
            totalXMLBytes += data.count
            guard totalXMLBytes <= 128 * 1_024 * 1_024 else { throw invalid }
            let slide = try OfficeXMLNode.parse(data)
            var rotations: [TextRotation] = []
            for shape in slide.descendants("sp") {
                guard let transform = shape.child("spPr")?.child("xfrm"),
                      let rotation = Double(transform.attributes["rot"] ?? "0"), rotation != 0,
                      let body = shape.child("txBody"), let offset = transform.child("off"),
                      let extent = transform.child("ext") else { continue }
                let text = body.children.filter { $0.name == "p" }.map { paragraph in
                    paragraph.descendants("t").map(\.text).joined()
                }.joined(separator: "\n")
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                rotations.append(TextRotation(
                    text: text, degrees: rotation / 60_000,
                    x: try number(offset.attributes["x"]) / width,
                    y: try number(offset.attributes["y"]) / height,
                    width: try number(extent.attributes["cx"]) / width,
                    height: try number(extent.attributes["cy"]) / height
                ))
            }
            slides.append(rotations)
        }
        return Self(width: width / 12_700, height: height / 12_700, slides: slides)
    }

    private static var invalid: ImportExportError { .presentationConversionFailed }
    private static func required<T>(_ value: T?) throws -> T {
        guard let value else { throw invalid }
        return value
    }
    private static func number(_ value: String?) throws -> Double {
        guard let value, let number = Double(value), number.isFinite else { throw invalid }
        return number
    }
    private static func resolve(_ target: String, relativeTo part: String) throws -> String {
        guard let decoded = target.removingPercentEncoding,
              !decoded.contains("\\"), !decoded.contains(":"), !decoded.contains("\0") else { throw invalid }
        var components = decoded.hasPrefix("/") ? [] : part.split(separator: "/").dropLast().map(String.init)
        for component in decoded.split(separator: "/") {
            if component == "." { continue }
            if component == ".." {
                guard !components.isEmpty else { throw invalid }
                components.removeLast()
            } else {
                components.append(String(component))
            }
        }
        guard !components.isEmpty else { throw invalid }
        return components.joined(separator: "/")
    }
}

nonisolated private final class OfficeZIPReader {
    private struct Entry {
        var offset: Int
        var compressed: Int
        var uncompressed: Int
        var method: Int
        var crc: UInt32
    }
    private let file: FileHandle
    private let length: Int
    private var entries: [String: Entry] = [:]

    init(_ url: URL) throws {
        file = try FileHandle(forReadingFrom: url)
        length = Int(try file.seekToEnd())
        do {
            let tailOffset = max(0, length - 65_557)
            let tail = try readBytes(at: tailOffset, count: length - tailOffset)
            guard tail.count >= 22,
                  let end = stride(from: tail.count - 22, through: 0, by: -1).first(where: {
                      tail.uint32($0) == 0x06054b50 && $0 + 22 + tail.uint16($0 + 20) == tail.count
                  }), tail.uint16(end + 4) == 0, tail.uint16(end + 6) == 0 else { throw invalid }
            let count = tail.uint16(end + 10), size = Int(tail.uint32(end + 12)), offset = Int(tail.uint32(end + 16))
            guard count > 0, count < 65_535, tail.uint16(end + 8) == count,
                  size <= 20 * 1_024 * 1_024, offset + size <= tailOffset + end else { throw invalid }
            let directory = try readBytes(at: offset, count: size)
            var cursor = 0
            for _ in 0..<count {
                try Task.checkCancellation()
                guard cursor + 46 <= directory.count, directory.uint32(cursor) == 0x02014b50,
                      directory.uint16(cursor + 8) & 1 == 0, directory.uint16(cursor + 34) == 0 else { throw invalid }
                let nameLength = directory.uint16(cursor + 28)
                let next = cursor + 46 + nameLength + directory.uint16(cursor + 30) + directory.uint16(cursor + 32)
                guard next <= directory.count,
                      let name = String(data: directory.subdata(in: cursor + 46..<cursor + 46 + nameLength), encoding: .utf8),
                      entries[name] == nil else { throw invalid }
                entries[name] = Entry(offset: Int(directory.uint32(cursor + 42)), compressed: Int(directory.uint32(cursor + 20)),
                                      uncompressed: Int(directory.uint32(cursor + 24)), method: directory.uint16(cursor + 10),
                                      crc: directory.uint32(cursor + 16))
                cursor = next
            }
        } catch {
            try? file.close()
            throw error
        }
    }

    deinit { try? file.close() }

    func read(_ name: String) throws -> Data {
        try Task.checkCancellation()
        guard let entry = entries[name], entry.uncompressed > 0,
              entry.uncompressed <= 16 * 1_024 * 1_024, entry.compressed <= 16 * 1_024 * 1_024 else { throw invalid }
        let header = try readBytes(at: entry.offset, count: 30)
        guard header.uint32(0) == 0x04034b50, header.uint16(6) & 1 == 0,
              header.uint16(8) == entry.method else { throw invalid }
        let offset = entry.offset + 30 + header.uint16(26) + header.uint16(28)
        let compressed = try readBytes(at: offset, count: entry.compressed)
        var result: Data
        switch entry.method {
        case 0:
            guard entry.compressed == entry.uncompressed else { throw invalid }
            result = compressed
        case 8:
            result = Data(count: entry.uncompressed)
            var stream = z_stream()
            guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw invalid }
            defer { inflateEnd(&stream) }
            let status = result.withUnsafeMutableBytes { output in
                compressed.withUnsafeBytes { input in
                    stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
                    stream.avail_in = uInt(input.count)
                    stream.next_out = output.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(output.count)
                    return inflate(&stream, Z_FINISH)
                }
            }
            guard status == Z_STREAM_END, stream.total_out == entry.uncompressed, stream.avail_in == 0 else { throw invalid }
        default:
            throw invalid
        }
        let checksum = result.withUnsafeBytes { crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count)) }
        guard UInt32(checksum) == entry.crc else { throw invalid }
        return result
    }

    private var invalid: ImportExportError { .presentationConversionFailed }
    private func readBytes(at offset: Int, count: Int) throws -> Data {
        guard offset >= 0, count >= 0, offset <= length, count <= length - offset else { throw invalid }
        try file.seek(toOffset: UInt64(offset))
        let data = try file.read(upToCount: count) ?? Data()
        guard data.count == count else { throw invalid }
        return data
    }
}

nonisolated private extension Data {
    func uint16(_ offset: Int) -> Int { Int(self[offset]) | (Int(self[offset + 1]) << 8) }
    func uint32(_ offset: Int) -> UInt32 {
        UInt32(self[offset]) | (UInt32(self[offset + 1]) << 8) | (UInt32(self[offset + 2]) << 16) | (UInt32(self[offset + 3]) << 24)
    }
}

nonisolated private final class OfficeXMLNode: NSObject, XMLParserDelegate {
    let name: String
    let attributes: [String: String]
    var children: [OfficeXMLNode] = []
    var text = ""
    private var stack: [OfficeXMLNode] = []
    private var nodeCount = 0

    init(name: String = "", attributes: [String: String] = [:]) {
        self.name = name
        self.attributes = attributes
    }
    func child(_ name: String) -> OfficeXMLNode? { children.first { $0.name == name } }
    func descendants(_ name: String) -> [OfficeXMLNode] {
        children.flatMap { ($0.name == name ? [$0] : []) + $0.descendants(name) }
    }
    static func parse(_ data: Data) throws -> OfficeXMLNode {
        let delegate = OfficeXMLNode()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        parser.delegate = delegate
        guard parser.parse(), let root = delegate.children.first else { throw ImportExportError.presentationConversionFailed }
        return root
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        nodeCount += 1
        guard stack.count < 64, nodeCount <= 100_000, !Task.isCancelled else { parser.abortParsing(); return }
        let node = OfficeXMLNode(name: name, attributes: attributes)
        (stack.last ?? self).children.append(node)
        stack.append(node)
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) { _ = stack.popLast() }
    func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }
}
