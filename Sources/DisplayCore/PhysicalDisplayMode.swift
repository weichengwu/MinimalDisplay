import Foundation
import CoreGraphics

/// Keep logical dimensions and framebuffer pixels separately to preserve Retina scaling.
public struct SavedDisplayMode: Codable, Equatable {
    public let width: Int
    public let height: Int
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let refreshRate: Double
    public let ioFlags: UInt32
    public let id: Int32

    public init(width: Int, height: Int, pixelWidth: Int, pixelHeight: Int,
                refreshRate: Double, ioFlags: UInt32, id: Int32) {
        self.width = width; self.height = height
        self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
        self.refreshRate = refreshRate; self.ioFlags = ioFlags; self.id = id
    }

    init(_ mode: CGDisplayMode) {
        self.init(width: mode.width, height: mode.height, pixelWidth: mode.pixelWidth,
                  pixelHeight: mode.pixelHeight, refreshRate: mode.refreshRate,
                  ioFlags: mode.ioFlags, id: mode.ioDisplayModeID)
    }

    func matches(_ other: SavedDisplayMode) -> Bool {
        // IOGraphicsTypes.h: interlaced=0x40, stretched=0x800. Other flags
        // describe availability and may change after reconnecting a display.
        let presentationFlags: UInt32 = 0x40 | 0x800
        return width == other.width && height == other.height &&
            pixelWidth == other.pixelWidth && pixelHeight == other.pixelHeight &&
            (refreshRate == 0 || abs(refreshRate - other.refreshRate) < 0.1) &&
            (ioFlags & presentationFlags) == (other.ioFlags & presentationFlags)
    }

    func select(from available: [SavedDisplayMode]) -> SavedDisplayMode? {
        let compatible = available.filter { matches($0) }
        // A mode ID alone is insufficient: it can refer to a different mode after reconnect.
        return compatible.first { $0.id == id } ??
            compatible.first { $0.ioFlags == ioFlags } ?? compatible.first
    }
}
