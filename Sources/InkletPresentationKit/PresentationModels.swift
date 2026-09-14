import Foundation

public let inkletPresentationWidgetKind = "InkletPresentationWidget"
public let inkletPresentationAppGroup = Bundle.main.object(forInfoDictionaryKey: "InkletAppGroupIdentifier") as? String
    ?? "group.com.iminklet.portal"

nonisolated public enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value") }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

nonisolated public struct PresentationViewportDTO: Codable, Sendable, Equatable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

nonisolated public struct PresentationOutputDTO: Codable, Sendable, Equatable {
    public var formats: [String]
    public var preset: String?
    public var viewport: PresentationViewportDTO
    public var colorMode: String
}

nonisolated public struct SceneFrameDTO: Codable, Sendable, Equatable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int
}

nonisolated public struct SceneElementDTO: Codable, Sendable, Equatable {
    public var id: String
    public var type: String
    public var frame: SceneFrameDTO
    public var properties: [String: JSONValue]
}

nonisolated public struct InkletSceneDTO: Codable, Sendable, Equatable {
    public var version: Int
    public var viewport: PresentationViewportDTO
    public var background: String
    public var elements: [SceneElementDTO]
}

nonisolated public struct PresentationSceneDTO: Codable, Sendable, Equatable {
    public var mediaType: String
    public var version: Int
    public var data: InkletSceneDTO
}

nonisolated public struct PresentationRenditionDTO: Codable, Sendable, Equatable {
    public var id: String
    public var mediaType: String
    public var format: String
    public var width: Int
    public var height: Int
    public var url: String?
    public var expiresAt: String?
    public var state: String?
    public var colorMode: String?
    public var failure: PresentationProblemDTO?
    public var isReady: Bool { format == "png" && (state == "ready" || state == nil) && url != nil }
    public var updatedAt: String
}

nonisolated public struct PresentationProblemDTO: Codable, Sendable, Equatable {
    public var code: String
    public var message: String
    public var stage: String?
    public var retryable: Bool
    public var assetIndex: Int?
}

nonisolated public struct GeneratedPresentationDTO: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var displayId: String?
    public var contentIds: [String]
    public var mode: String
    public var state: String
    public var output: PresentationOutputDTO?
    public var scene: PresentationSceneDTO?
    public var renditions: [PresentationRenditionDTO]
    public var failure: PresentationProblemDTO?
    public var createdAt: String
    public var updatedAt: String
}

nonisolated public struct CachedPresentationDTO: Codable, Sendable, Equatable {
    public var presentation: GeneratedPresentationDTO
    public var imageFilename: String?
    public var cachedAt: Date

    public init(presentation: GeneratedPresentationDTO, imageFilename: String?, cachedAt: Date = Date()) {
        self.presentation = presentation
        self.imageFilename = imageFilename
        self.cachedAt = cachedAt
    }
}
