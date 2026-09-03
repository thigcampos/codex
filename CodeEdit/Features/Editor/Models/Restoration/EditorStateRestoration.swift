//
//  EditorStateRestoration.swift
//  CodeEdit
//
//  Created by Khan Winter on 6/20/25.
//

import Foundation
import CodeEditSourceEditor
import OSLog

/// CodeEdit attempts to store and retrieve editor state for open tabs to restore the user's scroll position and
/// cursor positions between sessions. This class manages the storage mechanism to facilitate that feature.
///
/// This stores a JSON file in the application support directory named `editor-restoration.json`, mapping a file's
/// absolute path to its saved restoration state.
///
/// To ensure we can query this quickly, this class is shared globally and all reads/writes are synchronized on a
/// private serial queue.
final class EditorStateRestoration {
    /// Optional here so we can gracefully catch errors.
    /// The nice thing is this feature is optional in that if we don't have it available the user's experience is
    /// degraded but not catastrophic.
    static let shared: EditorStateRestoration? = try? EditorStateRestoration()

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "",
        category: "EditorStateRestoration"
    )

    struct StateRestorationData: Codable, Equatable {
        // Cursor positions as range values (not row/column!)
        let cursorPositions: [Range<Int>]
        let scrollPositionX: Double
        let scrollPositionY: Double

        var scrollPosition: CGPoint {
            CGPoint(x: scrollPositionX, y: scrollPositionY)
        }

        var editorCursorPositions: [CursorPosition] {
            cursorPositions.map { CursorPosition(range: NSRange(start: $0.lowerBound, end: $0.upperBound)) }
        }

        init(cursorPositions: [CursorPosition], scrollPosition: CGPoint) {
            self.cursorPositions = cursorPositions
                .compactMap { $0.range }
                .map { $0.location..<($0.location + $0.length) }
            self.scrollPositionX = scrollPosition.x
            self.scrollPositionY = scrollPosition.y
        }
    }

    private let queue = DispatchQueue(label: "app.codeedit.EditorStateRestoration")
    private var storage: [String: StateRestorationData]
    private let fileURL: URL

    /// Create a new editor restoration object. Will read from or create a JSON store.
    /// - Parameter fileURL: The file URL to use. Must point to a file, not a directory. If left `nil`, will
    ///                       create a new file named `editor-restoration.json` in the application support
    ///                       directory.
    init(_ fileURL: URL? = nil) throws {
        self.fileURL = fileURL ?? FileManager.default
            .homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/CodeEdit", directoryHint: .isDirectory)
            .appending(path: "editor-restoration.json", directoryHint: .notDirectory)
        do {
            self.storage = try Self.loadStorage(from: self.fileURL)
        } catch {
            // Corrupted file, might fix by starting fresh.
            try? FileManager.default.removeItem(at: self.fileURL)
            self.storage = [:]
        }
        try persist()
    }

    private static func loadStorage(from fileURL: URL) throws -> [String: StateRestorationData] {
        guard FileManager.default.fileExists(atPath: fileURL.absolutePath) else {
            return [:]
        }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([String: StateRestorationData].self, from: data)
    }

    /// Write the in-memory storage to disk.
    private func persist() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(storage)
        try data.write(to: fileURL, options: .atomic)
    }

    /// Update saved restoration state of a document.
    /// - Parameters:
    ///   - documentUrl: The URL of the document.
    ///   - data: The data to store for the file, retrieved using ``restorationState(for:)``.
    func updateRestorationState(for documentUrl: URL, data: StateRestorationData) {
        queue.sync {
            storage[documentUrl.absolutePath] = data
            do {
                try persist()
            } catch {
                Self.logger.error("Failed to save editor state: \(error)")
            }
        }
    }

    /// Find the restoration state for a document.
    /// - Parameter documentUrl: The URL of the document.
    /// - Returns: Any data saved for this file.
    func restorationState(for documentUrl: URL) -> StateRestorationData? {
        queue.sync {
            storage[documentUrl.absolutePath]
        }
    }
}
