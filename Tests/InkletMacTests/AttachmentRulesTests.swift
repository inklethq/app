import Foundation
import Testing
@testable import InkletMac

// The composer refuses what the Content contract would: more than 50 Assets,
// a binary over 10 MiB or empty, or a type outside the backend's allow-list.

@Test func theLimitsAreTheContracts() {
    #expect(AttachmentRules.maxBytes == 10_485_760)
    // The note is the 50th Asset.
    #expect(AttachmentRules.maxAttachments == 49)
}

@Test func contractTypesWithinTheLimitPass() {
    for type in ["image/png", "image/jpeg", "image/gif", "image/webp", "image/svg+xml",
                 "application/pdf", "text/plain", "text/markdown", "application/json"] {
        #expect(AttachmentRules.problem(filename: "f", contentType: type, byteCount: 1) == nil, "\(type)")
    }
    #expect(AttachmentRules.problem(filename: "f.png", contentType: "image/png", byteCount: AttachmentRules.maxBytes) == nil)
}

@Test func eachRefusalNamesTheFile() {
    let heic = AttachmentRules.problem(filename: "IMG_0001.heic", contentType: "image/heic", byteCount: 1)
    #expect(heic?.hasPrefix("IMG_0001.heic can't be sent") == true)
    let large = AttachmentRules.problem(filename: "scan.pdf", contentType: "application/pdf", byteCount: AttachmentRules.maxBytes + 1)
    #expect(large?.hasPrefix("scan.pdf is larger than 10 MB") == true)
    #expect(AttachmentRules.problem(filename: "note.txt", contentType: "text/plain", byteCount: 0) == "note.txt is empty.")
}

@Test func typesComeFromTheExtension() {
    #expect(AttachmentRules.contentType(for: URL(fileURLWithPath: "/tmp/a.md")) == "text/markdown")
    #expect(AttachmentRules.contentType(for: URL(fileURLWithPath: "/tmp/a.JPG")) == "image/jpeg")
    #expect(AttachmentRules.contentType(for: URL(fileURLWithPath: "/tmp/a.unknownext")) == "application/octet-stream")
}

@Test func loadingChecksBeforeReading() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let small = root.appendingPathComponent("small.png")
    try Data([0x89, 0x50, 0x4E, 0x47]).write(to: small)
    guard case .file(let filename, let contentType, let data) = await AttachmentRules.load(small) else {
        Issue.record("Expected small.png to load")
        return
    }
    #expect(filename == "small.png")
    #expect(contentType == "image/png")
    #expect(data.count == 4)

    // Sparse: 10 MiB and a byte on disk without writing them.
    let large = root.appendingPathComponent("large.pdf")
    FileManager.default.createFile(atPath: large.path, contents: nil)
    let handle = try FileHandle(forWritingTo: large)
    try handle.truncate(atOffset: UInt64(AttachmentRules.maxBytes + 1))
    try handle.close()
    guard case .refused(let tooLarge) = await AttachmentRules.load(large) else {
        Issue.record("Expected large.pdf to be refused")
        return
    }
    #expect(tooLarge.hasPrefix("large.pdf is larger than 10 MB"))

    let archive = root.appendingPathComponent("bundle.zip")
    try Data([1]).write(to: archive)
    guard case .refused(let wrongType) = await AttachmentRules.load(archive) else {
        Issue.record("Expected bundle.zip to be refused")
        return
    }
    #expect(wrongType.hasPrefix("bundle.zip can't be sent"))

    guard case .refused(let missing) = await AttachmentRules.load(root.appendingPathComponent("gone.txt")) else {
        Issue.record("Expected a missing file to be refused")
        return
    }
    #expect(missing == "Couldn't read gone.txt")
}
