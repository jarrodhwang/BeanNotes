//
//  DrawingStorageService.swift
//  BeanNote
//

import Foundation
import PencilKit

struct DrawingStorageService {
    var storage = LocalStorageService()

    func drawingURL(for page: NotePage) throws -> URL {
        try storage.directoryURL(for: .drawings)
            .appendingPathComponent(page.drawingFileName)
    }

    func loadDrawing(for page: NotePage) -> PKDrawing {
        do {
            let url = try drawingURL(for: page)
            guard storage.fileManager.fileExists(atPath: url.path) else {
                return PKDrawing()
            }

            let data = try Data(contentsOf: url)
            return try PKDrawing(data: data)
        } catch {
            return PKDrawing()
        }
    }

    func save(_ drawing: PKDrawing, for page: NotePage) throws {
        let url = try drawingURL(for: page)
        let data = drawing.dataRepresentation()
        try data.write(to: url, options: [.atomic])
        page.touch()
    }
}
