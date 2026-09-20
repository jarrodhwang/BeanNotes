import Foundation
import Testing
@testable import BeanNotes

private final class PowerPointMetadataFixtureBundle: NSObject {}

struct PowerPointPackageMetadataTests {
    @Test(arguments: ["ThreePages", "WidescreenFidelity", "PortraitFidelity", "LongFidelity"])
    func packageReadsSlideOrderSizeAndTextRotation(name: String) throws {
        let url = try #require(Bundle(for: PowerPointMetadataFixtureBundle.self).url(forResource: name, withExtension: "pptx"))
        let metadata = try PowerPointPackageMetadata.read(url)
        #expect(metadata.slides.count == (name == "LongFidelity" ? 24 : 3))
        let aspect = name == "PortraitFidelity" ? 0.75 : name == "ThreePages" ? 4.0 / 3.0 : 16.0 / 9.0
        #expect(abs(metadata.width / metadata.height - aspect) < 0.00001)
        if name == "ThreePages" {
            #expect(metadata.slides.allSatisfy { $0.isEmpty })
        } else {
            #expect(metadata.slides.allSatisfy { $0.count == 1 })
            let rotation = try #require(metadata.slides.last?.first)
            #expect(rotation.text == "Rotated label")
            #expect(rotation.degrees == 15)
            #expect(abs(rotation.x - 0.3) < 0.00001)
            #expect(abs(rotation.y - 0.67) < 0.00001)
        }
    }

    @Test func malformedAndCorruptedPackagesFailValidation() throws {
        let source = try #require(Bundle(for: PowerPointMetadataFixtureBundle.self).url(forResource: "WidescreenFidelity", withExtension: "pptx"))
        let original = try Data(contentsOf: source)
        var corrupted = original
        // The final filename occurrence is in the central directory. Damage the
        // XML part's checksum, rather than an unused thumbnail or image record.
        let name = Data("ppt/presentation.xml".utf8)
        var searchRange = original.startIndex..<original.endIndex
        var lastName: Range<Data.Index>?
        while let range = original.range(of: name, in: searchRange) {
            lastName = range
            searchRange = range.upperBound..<original.endIndex
        }
        let offset = try #require(lastName).lowerBound - 46
        corrupted[offset + 16] ^= 0xff
        let invalidInputs = [Data(original.dropLast(22)), Data("This is not an Office package".utf8), corrupted]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (index, data) in invalidInputs.enumerated() {
            let url = root.appendingPathComponent("Invalid-\(index).pptx")
            try data.write(to: url)
            #expect(throws: ImportExportError.self) { try PowerPointPackageMetadata.read(url) }
        }
    }
}
