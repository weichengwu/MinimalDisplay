import Foundation

public struct DisplayProfile: Codable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    /// User-facing logical resolution. HiDPI doubles framebuffer pixels automatically.
    public var width: Int
    public var height: Int
    public var hiDPI: Bool

    public init(id: UUID = UUID(), name: String, width: Int, height: Int, hiDPI: Bool = false) {
        self.id = id; self.name = name; self.width = width; self.height = height; self.hiDPI = hiDPI
    }

    public var pixelWidth: Int { width * (hiDPI ? 2 : 1) }
    public var pixelHeight: Int { height * (hiDPI ? 2 : 1) }
    public var label: String { "\(width) × \(height)\(hiDPI ? " 高清" : "")" }

    private enum CodingKeys: String, CodingKey { case id, name, width, height, hiDPI, resolutionVersion }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        width = try values.decode(Int.self, forKey: .width)
        height = try values.decode(Int.self, forKey: .height)
        hiDPI = try values.decode(Bool.self, forKey: .hiDPI)
        let version = try values.decodeIfPresent(Int.self, forKey: .resolutionVersion) ?? 1
        switch version {
        case 1:
            // 1.0.0 stored actual pixels. Validate before division to avoid silently rounding corrupt data.
            guard (320...8192).contains(width), (320...8192).contains(height),
                  !hiDPI || (width.isMultiple(of: 2) && height.isMultiple(of: 2)) else {
                throw DisplayFailure("旧版分辨率配置无效，原文件已保留，请检查 profiles.json。")
            }
            if hiDPI { width /= 2; height /= 2 }
        case 2: break
        default: throw DisplayFailure("无法读取更新版本的分辨率配置，请升级 App。")
        }
        self = try validated()
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(width, forKey: .width)
        try values.encode(height, forKey: .height)
        try values.encode(hiDPI, forKey: .hiDPI)
        try values.encode(2, forKey: .resolutionVersion)
    }

    public func validated() throws -> DisplayProfile {
        var value = self
        value.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.name.isEmpty, value.name.count <= 80,
              !value.name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw DisplayFailure("名称需为 1–80 个字符，且不能含换行或控制字符。")
        }
        let range = hiDPI ? 160...4096 : 320...8192
        guard range.contains(width), range.contains(height) else {
            throw DisplayFailure(hiDPI ? "高清显示的宽和高需为 160–4096 的整数，实际像素会自动乘以 2。" : "宽和高需为 320–8192 的整数。")
        }
        return value
    }
}

public struct DisplayFailure: LocalizedError {
    public var message: String
    public var configurationStalled: Bool
    public init(_ message: String, stalled: Bool = false) {
        self.message = message; self.configurationStalled = stalled
    }
    public var errorDescription: String? { message }
}

public final class ProfileStore {
    public let url: URL
    public init(directory: URL = StateFiles.defaultDirectory) {
        url = directory.appendingPathComponent("profiles.json")
    }
    public func load() throws -> [DisplayProfile] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let profiles = try JSONDecoder().decode([DisplayProfile].self, from: Data(contentsOf: url))
        guard Set(profiles.map(\.id)).count == profiles.count else { throw DisplayFailure("配置中存在重复 ID，请检查 profiles.json。") }
        return try profiles.map { try $0.validated() }
    }
    public func save(_ profiles: [DisplayProfile]) throws {
        let values = try profiles.map { try $0.validated() }
        guard Set(values.map(\.id)).count == values.count else { throw DisplayFailure("不能保存重复的虚拟屏 ID。") }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(values).write(to: url, options: .atomic)
    }
}
