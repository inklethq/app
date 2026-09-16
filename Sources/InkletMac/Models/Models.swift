import Foundation
import InkletPresentationKit

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

/// One Presentation in a Display's history, built from the shared
/// Presentation DTO (`GET /api/app/v1/presentations?displayId=`).
struct Push: Identifiable, Hashable {
    /// The panel vocabulary of `Presentation.state`.
    enum Status: String, CaseIterable {
        case preparing
        case queued
        case published
        case confirmed
        case expired
        case failed

        var label: String {
            switch self {
            case .preparing: "Preparing"
            case .queued: "Queued"
            case .published: "Published"
            case .confirmed: "Confirmed"
            case .expired: "Expired"
            case .failed: "Failed"
            }
        }

        var isTerminal: Bool { self == .confirmed || self == .expired || self == .failed }
    }

    let id: String
    var title: String
    var summary: String?
    var status: Status
    var createdAt: Date
    var imageURL: URL?
    /// `direct` means the picture went up untouched; `ai` means inklet laid it out.
    var mode: String

    /// `POST /displays/{id}/current` accepts a rendered Presentation of this
    /// panel, including an expired one; the current one is already on screen.
    var canShowAgain: Bool {
        status == .expired || status == .queued
    }

    init(dto: GeneratedPresentationDTO) {
        id = dto.id
        let rawTitle = dto.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        title = rawTitle.isEmpty ? "Untitled" : rawTitle
        summary = dto.failure?.message
        status = Status(rawValue: dto.state) ?? .published
        createdAt = InkletTime.parse(dto.createdAt) ?? .now
        imageURL = dto.image.flatMap { URL(string: $0.url) }
        mode = dto.mode
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

    /// Where a Content is, seen from the user: its Assets are still arriving,
    /// it is saved and waiting, an Analysis has used it, or it failed.
    enum ProcessStatus: String {
        case uploading
        case saved
        case ready
        case failed

        var label: String {
            switch self {
            case .uploading: "Uploading"
            case .saved: "Saved"
            case .ready: "Organized"
            case .failed: "Failed"
            }
        }
    }

    let id: String
    var processStatus: ProcessStatus
    var assetCount: Int
    var analysisCount: Int
    var createdAt: Date
    var title: String?
    var detail: String?
    var kind: Kind?

    init(dto: ContentDTO) {
        id = dto.id
        assetCount = dto.assets.count
        analysisCount = dto.analysisIds?.count ?? 0
        createdAt = InkletTime.parse(dto.createdAt) ?? .now
        switch dto.state {
        case "pending": processStatus = .uploading
        case "failed": processStatus = .failed
        default: processStatus = analysisCount > 0 ? .ready : .saved
        }

        let texts = dto.assets.filter { $0.type == "text" }
        let links = dto.assets.filter { $0.type == "link" }
        let images = dto.assets.filter { $0.type == "image" }
        let files = dto.assets.filter { $0.type == "file" }
        let firstLine = texts.first?.text?
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }

        if let named = dto.title, !named.isEmpty {
            title = named
        } else if let firstLine {
            title = firstLine
        } else if let link = links.first?.url {
            title = link
        } else if !images.isEmpty {
            title = images.count == 1 ? (images.first?.filename ?? "Image") : "\(images.count) images"
        } else if !files.isEmpty {
            title = files.count == 1 ? (files.first?.filename ?? "Document") : "\(files.count) documents"
        } else {
            title = "Empty item"
        }

        if !texts.isEmpty { kind = links.isEmpty ? .text : .link }
        else if !links.isEmpty { kind = .link }
        else if !images.isEmpty { kind = .image }
        else if !files.isEmpty { kind = .file }
        else { kind = .bundle }

        var parts: [String] = []
        if !links.isEmpty { parts.append("\(links.count) link\(links.count == 1 ? "" : "s")") }
        if !images.isEmpty { parts.append("\(images.count) image\(images.count == 1 ? "" : "s")") }
        if !files.isEmpty { parts.append("\(files.count) file\(files.count == 1 ? "" : "s")") }
        if let failure = dto.failure, processStatus == .failed { parts.append(failure.message) }
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
