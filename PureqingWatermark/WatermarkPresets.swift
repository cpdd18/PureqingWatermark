import Foundation
import UIKit

// MARK: - Watermark assets and compositing mode
// 水印素材自动适配整张原图；每张素材单独选择正常混合或叠加混合。
struct PWMStudioWatermarkAsset: Identifiable, Equatable, @unchecked Sendable {
    let id: UUID
    var name: String
    var image: UIImage
    var mode: PWMWatermarkMode

    init(id: UUID = UUID(), name: String, image: UIImage, mode: PWMWatermarkMode = .standard) {
        self.id = id
        self.name = name
        self.image = image
        self.mode = mode
    }

    static func == (lhs: PWMStudioWatermarkAsset, rhs: PWMStudioWatermarkAsset) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.mode == rhs.mode
    }
}

actor PWMWatermarkPresetStore {
    static let shared = PWMWatermarkPresetStore()
    struct Entry: Codable {
        let id: UUID
        let name: String
        let mode: String
        let image: Data
    }
    struct Archive: Codable {
        let entries: [Entry]
        let selected: Set<UUID>
    }
    private var latestRevision: UInt64 = 0
    private var encodedImages: [UUID: Data] = [:]
    private func fileURL() throws -> URL {
        let directory = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("WatermarkPresets", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("presets.json")
    }
    func load() throws -> ([PWMStudioWatermarkAsset], Set<UUID>) {
        let url = try fileURL()
        guard FileManager.default.fileExists(atPath: url.path)
            || FileManager.default.fileExists(atPath: url.appendingPathExtension("backup").path)
        else { return ([], []) }
        let archive: Archive
        do {
            archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: url))
        } catch {
            archive = try JSONDecoder().decode(Archive.self,
                from: Data(contentsOf: url.appendingPathExtension("backup")))
        }
        let assets = try archive.entries.prefix(3).map { entry -> PWMStudioWatermarkAsset in
            guard let image = UIImage(data: entry.image) else { throw CocoaError(.fileReadCorruptFile) }
            return PWMStudioWatermarkAsset(id: entry.id, name: entry.name, image: image,
                mode: PWMWatermarkMode(rawValue: entry.mode) ?? .standard)
        }
        encodedImages = Dictionary(uniqueKeysWithValues: archive.entries.prefix(3).map { ($0.id, $0.image) })
        return (assets, archive.selected.intersection(Set(assets.map(\.id))))
    }
    func save(_ assets: [PWMStudioWatermarkAsset], selected: Set<UUID>, revision: UInt64) throws {
        guard revision > latestRevision else { return }
        let entries = try assets.prefix(3).map { asset -> Entry in
            guard let data = encodedImages[asset.id] ?? asset.image.pngData() else { throw CocoaError(.fileWriteUnknown) }
            return Entry(id: asset.id, name: asset.name, mode: asset.mode.rawValue, image: data)
        }
        let data = try JSONEncoder().encode(Archive(entries: entries, selected: selected))
        let url = try fileURL()
        let backup = url.appendingPathExtension("backup")
        if let previous = try? Data(contentsOf: url),
           (try? JSONDecoder().decode(Archive.self, from: previous)) != nil {
            try previous.write(to: backup, options: .atomic)
        }
        try data.write(to: url, options: .atomic)
        encodedImages = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.image) })
        latestRevision = revision
    }
}

enum PWMWatermarkMode: String, CaseIterable, Identifiable, Sendable {
    case standard = "标准"
    case overlay = "叠加"
    var id: String { rawValue }
}


actor PWMFramePresetStore {
    static let shared = PWMFramePresetStore()
    struct Frame: Codable { let id: UUID; let name: String; let png: Data }
    struct Archive: Codable {
        let frames: [Frame]
        let selected: UUID?
        let showsFrame: Bool
        let strip: Data?
        let stripID: UUID
        let stripEnabled: Bool
        let transform: [Double]
    }
    private var revision: UInt64 = 0
    private var images: [UUID: Data] = [:]
    private func url() throws -> URL {
        let folder = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true).appendingPathComponent("FramePresets", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("presets.json")
    }
    func load() throws -> Archive? {
        let file = try url()
        guard FileManager.default.fileExists(atPath: file.path) || FileManager.default.fileExists(atPath: file.appendingPathExtension("backup").path) else { return nil }
        let archive: Archive
        do { archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: file)) }
        catch { archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: file.appendingPathExtension("backup"))) }
        images = Dictionary(archive.frames.map { ($0.id, $0.png) }, uniquingKeysWith: { _, last in last })
        if let strip = archive.strip { images[archive.stripID] = strip }
        return archive
    }
    func save(frames: [PWMFrameAsset], selected: UUID?, shows: Bool, strip: UIImage?, stripID: UUID,
              enabled: Bool, transform: [Double], revision next: UInt64) throws {
        guard next > revision else { return }
        func encode(_ image: UIImage, id: UUID) throws -> Data {
            guard let data = images[id] ?? image.pngData() else { throw CocoaError(.fileWriteUnknown) }
            return data
        }
        let entries = try frames.map { Frame(id: $0.id, name: $0.name, png: try encode($0.image, id: $0.id)) }
        let stripData = try strip.map { try encode($0, id: stripID) }
        let archive = Archive(frames: entries, selected: selected, showsFrame: shows, strip: stripData,
                              stripID: stripID, stripEnabled: enabled, transform: transform)
        let file = try url()
        if let old = try? Data(contentsOf: file), (try? JSONDecoder().decode(Archive.self, from: old)) != nil {
            try old.write(to: file.appendingPathExtension("backup"), options: .atomic)
        }
        try JSONEncoder().encode(archive).write(to: file, options: .atomic)
        images = Dictionary(entries.map { ($0.id, $0.png) }, uniquingKeysWith: { _, last in last })
        if let stripData { images[stripID] = stripData }
        revision = next
    }
}
