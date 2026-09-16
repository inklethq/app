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
