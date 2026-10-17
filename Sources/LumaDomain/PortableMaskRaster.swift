import Foundation

/// Backend-independent scalar coverage. Rows run from top to bottom; each pixel
/// is linear coverage (0 = outside, 255 = fully selected), never photograph RGB.
/// This is the saved result of inference, so reopening needs no model or GPU.
public struct PortableMaskRaster: Codable, Equatable {
    public let width: Int
    public let height: Int
    public let pixels: Data
    public let modelID: String

    public static let maximumPixels = 16_777_216
    public var isValid: Bool {
        width > 0 && height > 0 && width <= 4096 && height <= 4096 &&
        width <= Self.maximumPixels / height && pixels.count == width * height
    }
    public init(width: Int, height: Int, pixels: Data, modelID: String) throws {
        self.width = width; self.height = height; self.pixels = pixels; self.modelID = modelID
        guard isValid else { throw RasterError.invalidDimensions }
    }
    public enum RasterError: Error { case invalidDimensions, invalidEncoding }
    private enum CodingKeys: String, CodingKey { case version, width, height, encoding, pixels, modelID }
    public func encode(to encoder: Encoder) throws {
        guard isValid else { throw RasterError.invalidDimensions }
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(1, forKey: .version)
        try values.encode(width, forKey: .width); try values.encode(height, forKey: .height)
        try values.encode(modelID, forKey: .modelID)
        let packed = Self.pack(pixels)
        let useRLE = packed.count < pixels.count
        try values.encode(useRLE ? "rle8-le32" : "gray8", forKey: .encoding)
        try values.encode(useRLE ? packed : pixels, forKey: .pixels)
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(Int.self, forKey: .version) == 1 else { throw RasterError.invalidEncoding }
        let width = try values.decode(Int.self, forKey: .width), height = try values.decode(Int.self, forKey: .height)
        guard width > 0 && height > 0 && width <= 4096 && height <= 4096 && width <= Self.maximumPixels / height else { throw RasterError.invalidDimensions }
        let encoding = try values.decode(String.self, forKey: .encoding)
        let data = try values.decode(Data.self, forKey: .pixels)
        let pixels: Data
        switch encoding {
        case "gray8": pixels = data
        case "rle8-le32": pixels = try Self.unpack(data, count: width * height)
        default: throw RasterError.invalidEncoding
        }
        try self.init(width: width, height: height, pixels: pixels, modelID: values.decode(String.self, forKey: .modelID))
    }
    private static func pack(_ pixels: Data) -> Data {
        var result = Data(); result.reserveCapacity(min(pixels.count, 65536))
        let bytes = [UInt8](pixels)
        var index = 0
        while index < bytes.count {
            let value = bytes[index]; var end = index + 1
            while end < bytes.count && bytes[end] == value { end += 1 }
            let count = UInt32(end-index)
            result.append(value)
            result.append(UInt8(count & 255)); result.append(UInt8((count >> 8) & 255))
            result.append(UInt8((count >> 16) & 255)); result.append(UInt8(count >> 24))
            // A noisy matte compresses poorly. Stop early without allocating a
            // several-times-larger intermediate buffer; encoder will use gray8.
            if result.count >= pixels.count { return pixels }
            index = end
        }
        return result
    }
    private static func unpack(_ data: Data, count: Int) throws -> Data {
        guard data.count % 5 == 0, data.count <= count * 5 else { throw RasterError.invalidEncoding }
        let bytes = [UInt8](data); var result = Data(); result.reserveCapacity(count)
        for index in stride(from: 0, to: bytes.count, by: 5) {
            let length = Int(UInt32(bytes[index+1]) | UInt32(bytes[index+2]) << 8 | UInt32(bytes[index+3]) << 16 | UInt32(bytes[index+4]) << 24)
            guard length > 0 && length <= count-result.count else { throw RasterError.invalidEncoding }
            result.append(contentsOf: repeatElement(bytes[index], count: length))
        }
        guard result.count == count else { throw RasterError.invalidEncoding }
        return result
    }
}
