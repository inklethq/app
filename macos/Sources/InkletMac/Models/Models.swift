import Foundation

// View-facing models. Each one is built from the matching wire type in Wire.swift
// so the UI never deals with optional strings, snake_case, or RFC3339 parsing.

struct Device: Identifiable, Hashable {
    let id: String
    var hwId: String
    var nickname: String?
    var firmware: String?
    var battery: Int?
    var charging: Bool
    var online: Bool
    var lastSeenAt: Date?
    var latestPushID: String?
    var latestPushAt: Date?

    /// Nickname when set, hardware id otherwise — same rule as the iOS client.
    var displayName: String {
        if let nickname, !nickname.isEmpty { return nickname }
        return hwId
    }

    init(dto: DeviceDTO) {
        id = dto.id
        hwId = dto.hwId
        nickname = dto.nickname
        firmware = dto.firmware
        battery = dto.battery
        charging = dto.charging ?? false
        online = dto.online ?? false
        lastSeenAt = InkletTime.parse(dto.lastSeenAt)
        latestPushID = dto.latestPushId
        latestPushAt = InkletTime.parse(dto.latestPushAt)
    }
}

struct Push: Identifiable, Hashable {
    /// Backend status vocabulary (internal/iot/service.go), with the display
    /// wording the other clients use.
    enum Status: String, CaseIterable {
        case preparing = "PREPARE"
        case queued = "QUEUE"
        case published = "PUBLISHED"
        case confirmed = "CONFIRMED"
        case expired = "EXPIRED"

        var label: String {
            switch self {
            case .preparing: "Preparing"
            case .queued: "Queued"
            case .published: "Published"
            case .confirmed: "Confirmed"
            case .expired: "Expired"
            }
        }

        var isTerminal: Bool { self == .confirmed || self == .expired }
    }

    let id: String
    var title: String
    var summary: String?
    var status: Status
    var createdAt: Date

    init(dto: PushItemDTO) {
        id = dto.pushId
        let rawTitle = dto.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        title = rawTitle.isEmpty ? "Untitled" : rawTitle
        let rawSummary = dto.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        summary = rawSummary.isEmpty ? nil : rawSummary
        status = Status(rawValue: dto.status ?? "") ?? .published
        createdAt = InkletTime.parse(dto.createdAt) ?? .now
    }
}

struct KnowledgeItem: Identifiable, Hashable {
    enum Kind: String, CaseIterable {
        case text = "Text"
        case link = "Link"
        case image = "Image"
        case file = "File"
        case bundle = "Bundle"

        var symbol: String {
            switch self {
            case .text: "text.alignleft"
            case .link: "link"
            case .image: "photo"
            case .file: "doc"
            case .bundle: "square.stack"
            }
        }
    }

    enum ProcessStatus: String {
        case raw = "RAW"
        case ingested = "INGESTED"
        case ready = "READY"
        case failed = "FAILED"

        var label: String {
            switch self {
            case .raw: "Queued"
            case .ingested: "Processing"
            case .ready: "Organized"
            case .failed: "Failed"
            }
        }
    }

    let id: String
    var processStatus: ProcessStatus
    var blockCount: Int
    var createdAt: Date
    /// Filled in by a follow-up detail fetch — the list endpoint doesn't return
    /// item content, so a fresh row starts out with no title to show.
    var title: String?
    var detail: String?
    var kind: Kind?

    init(dto: RawItemDTO) {
        id = dto.id
        processStatus = ProcessStatus(rawValue: dto.processStatus ?? "") ?? .raw
        blockCount = dto.blockCount ?? 0
        createdAt = InkletTime.parse(dto.createdAt) ?? .now
    }

    /// Derives the row's title, subtitle and icon from an item's bundle content.
    mutating func apply(content: BundleContentDTO) {
        let attachments = content.attach ?? []
        let text = (content.main_text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let links = attachments.filter { $0.type == "link" }
        let images = attachments.filter { $0.type == "image" }
        let docs = attachments.filter { $0.type == "doc" }

        if !text.isEmpty {
            title = text.split(separator: "\n").first.map(String.init) ?? text
            kind = links.isEmpty ? .text : .link
        } else if let link = links.first?.url {
            title = link
            kind = .link
        } else if !images.isEmpty {
            title = images.count == 1 ? "Image" : "\(images.count) images"
            kind = .image
        } else if !docs.isEmpty {
            title = docs.count == 1 ? "Document" : "\(docs.count) documents"
            kind = .file
        } else {
            title = "Empty item"
            kind = .bundle
        }

        var parts: [String] = []
        if !links.isEmpty { parts.append("\(links.count) link\(links.count == 1 ? "" : "s")") }
        if !images.isEmpty { parts.append("\(images.count) image\(images.count == 1 ? "" : "s")") }
        if !docs.isEmpty { parts.append("\(docs.count) file\(docs.count == 1 ? "" : "s")") }
        detail = parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

struct Account: Hashable {
    var username: String
    var email: String
    var plan: String

    init(username: String, email: String, plan: String) {
        self.username = username
        self.email = email
        self.plan = plan
    }

    init(dto: UserDTO) {
        username = dto.username
        email = dto.email
        plan = dto.plan
    }
}
