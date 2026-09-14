import Foundation

public struct CachedPresentationSnapshot: Codable, Sendable {
    public var metadata: CachedPresentationDTO
    public var imageData: Data?

    public init(metadata: CachedPresentationDTO, imageData: Data?) {
        self.metadata = metadata
        self.imageData = imageData
    }
}

/// Durable handoff between the authenticated host app and WidgetKit.
///
/// The Widget never receives an access token or follows an expiring rendition
/// URL. The host downloads the PNG and stores it alongside the Scene JSON in
/// the shared App Group container.
public struct PresentationCache: Sendable {
    private let rootURL: URL
    private let metadataURL: URL

    public init(rootURL: URL? = nil) {
        let resolvedRoot: URL
        if let rootURL {
            resolvedRoot = rootURL
        } else if let group = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: inkletPresentationAppGroup
        ) {
            resolvedRoot = group.appending(path: "PresentationWidget", directoryHint: .isDirectory)
        } else {
            // Keeps SwiftPM development usable before the signed App Group
            // entitlement is attached. A production Widget requires the group.
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.temporaryDirectory
            resolvedRoot = support
                .appending(path: "inklet", directoryHint: .isDirectory)
                .appending(path: "PresentationWidget", directoryHint: .isDirectory)
        }
        self.rootURL = resolvedRoot
        self.metadataURL = resolvedRoot.appending(path: "latest.json")
    }

    @discardableResult
    public func store(
        presentation: GeneratedPresentationDTO,
        imageData: Data?
    ) throws -> CachedPresentationSnapshot {
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )

        let imageFilename = imageData == nil ? nil : "latest.png"
        if let imageData, let imageFilename {
            try imageData.write(
                to: rootURL.appending(path: imageFilename),
                options: .atomic
            )
        } else {
            try? FileManager.default.removeItem(
                at: rootURL.appending(path: "latest.png")
            )
        }

        let metadata = CachedPresentationDTO(
            presentation: presentation,
            imageFilename: imageFilename
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(metadata).write(to: metadataURL, options: .atomic)
        return CachedPresentationSnapshot(metadata: metadata, imageData: imageData)
    }

    public func load() throws -> CachedPresentationSnapshot? {
        guard FileManager.default.fileExists(atPath: metadataURL.path) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let metadata = try decoder.decode(
            CachedPresentationDTO.self,
            from: Data(contentsOf: metadataURL)
        )
        let imageData = try metadata.imageFilename.map {
            try Data(contentsOf: rootURL.appending(path: $0))
        }
        return CachedPresentationSnapshot(metadata: metadata, imageData: imageData)
    }

    public func clear() throws {
        guard FileManager.default.fileExists(atPath: rootURL.path) else { return }
        try FileManager.default.removeItem(at: rootURL)
    }
}
