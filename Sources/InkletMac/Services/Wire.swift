import Foundation
import InkletPresentationKit

// Wire types for the inklet backend. Field names and optionality follow the Go
// handlers exactly (internal/iot/api.go, internal/item/handler.go,
// internal/auth/handler.go). Anything the server marks `omitempty` or as a
// pointer is optional here, so a sparsely-populated row can never fail decoding
// and blank the whole screen.

// MARK: - Auth

struct SubscriptionDTO: Codable, Sendable {
    var id: String?
    var plan: String?
    var billingInterval: String?
    var currentPeriodEnd: String?
    var cancelAtPeriodEnd: Bool?
}

struct UserDTO: Codable, Sendable {
    var id: String
    var email: String
    var username: String
    var hasPassword: Bool?
    var subscription: SubscriptionDTO?

    var plan: String { subscription?.plan ?? "free" }
}

struct LoginResponseDTO: Codable, Sendable {
    var accessToken: String
    var refreshToken: String
    var user: UserDTO
}

// MARK: - Devices

struct DeviceDTO: Codable, Sendable {
    var id: String
    var hwId: String
    var thingName: String?
    var nickname: String?
    var firmware: String?
    var battery: Int?
    var charging: Bool?
    var online: Bool?
    var lastSeenAt: String?
    var boundAt: String?
    var state: String?
    var stateUpdatedAt: String?
    var latestPushId: String?
    var latestPushAt: String?
}

/// `GET /api/devices/{id}/push[/{pushId}]` — a presigned image URL plus the push
/// it belongs to.
struct PushImageDTO: Codable, Sendable {
    var url: String
    var pushId: String?
    var status: String?
    var changed: Bool?
}

struct PushItemDTO: Codable, Sendable {
    var pushId: String
    var title: String?
    var summary: String?
    var status: String?
    var priority: Int?
    var createdAt: String?
}

struct PushPageDTO: Codable, Sendable {
    var items: [PushItemDTO]
    var nextCursor: String?
    var hasMore: Bool?
}

// MARK: - Raw items (knowledge)

struct RawItemDTO: Codable, Sendable {
    var id: String
    var type: String?
    var format: String?
    var status: String?
    var processStatus: String?
    var blockCount: Int?
    var blockDoneCount: Int?
    var createdAt: String?
    var updatedAt: String?
    /// Only `GET /api/raw-items/{id}` fills this in — the list endpoint selects
    /// columns explicitly and leaves content out.
    var content: String?
}

struct RawItemsPageDTO: Codable, Sendable {
    var items: [RawItemDTO]
    var total: Int?
    var page: Int?
    var limit: Int?
}

/// The bundle body stored in `RawItemDTO.content`, snake_cased by the Go struct
/// tags in internal/item/service.go.
struct BundleContentDTO: Codable, Sendable {
    var type: String?
    var format: String?
    var upload_at: String?
    var main_text: String?
    var attach: [BundleAttachmentDTO]?
}

struct BundleAttachmentDTO: Codable, Sendable {
    var type: String?        // "link" | "image" | "doc"
    var mime: String?
    var file_id: String?
    var url: String?
}

// MARK: - Upload

struct UploadTicketDTO: Codable, Sendable {
    var index: Int
    var url: String
    var fields: [String: String]
}

struct UploadResponseDTO: Codable, Sendable {
    var itemId: String
    var attachments: [UploadTicketDTO]?
    var expiresAt: String?
}

struct ConfirmResponseDTO: Codable, Sendable {
    var itemId: String?
    var status: String?
    var failed: [Int]?
}

// MARK: - Targetless Presentations (/api/app/v1)

struct PresentationUploadTicketDTO: Codable, Sendable {
    var assetIndex: Int
    var url: String
    var fields: [String: String]
    var expiresAt: String
}

struct PresentationContentUploadDTO: Codable, Sendable {
    var status: String
    var failedAssetIndexes: [Int]
}

struct PresentationContentProcessingDTO: Codable, Sendable {
    var stage: String?
    var warnings: [PresentationProblemDTO]
    var error: PresentationProblemDTO?
}

struct PresentationContentDTO: Codable, Sendable {
    var id: String
    var state: String
    var upload: PresentationContentUploadDTO
    var processing: PresentationContentProcessingDTO
    var presentationIds: [String]
}

struct CreatePresentationContentResponseDTO: Codable, Sendable {
    var content: PresentationContentDTO
    var uploadTickets: [PresentationUploadTicketDTO]
}

/// `POST /api/devices/{id}/custom-push/upload` — the file service's own ticket
/// shape, which carries a fileId instead of an index.
struct CustomPushTicketDTO: Codable, Sendable {
    var fileId: String
    var url: String
    var fields: [String: String]
    var expiresAt: String?
}

struct CustomPushConfirmDTO: Codable, Sendable {
    var pushId: String
}

// MARK: - Time

enum InkletTime {
    // Go's RFC3339 marshalling drops trailing zeros, so the same field arrives
    // with and without fractional seconds depending on the value. Both shapes
    // get a formatter; parsing tries the fractional one first.
    //
    // `nonisolated(unsafe)` because Foundation formatters are documented as
    // thread-safe for formatting and parsing as long as their configuration
    // isn't mutated after setup, which it isn't here.
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parse(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        return fractional.date(from: raw) ?? plain.date(from: raw)
    }

    static func rfc3339(_ date: Date) -> String { plain.string(from: date) }
}
