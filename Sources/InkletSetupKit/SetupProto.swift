import Foundation

// Just enough protobuf for Espressif's provisioning messages (protocomm
// session + network_provisioning config/scan): varint and length-delimited
// fields and nested messages. Field numbers are taken from the .proto files in
// esp-idf/components/protocomm/proto and
// idf-extra-components/network_provisioning/proto.

struct ProtoWriter {
    private(set) var data = Data()

    mutating func varint(_ field: Int, _ value: UInt64) {
        tag(field, wireType: 0)
        appendVarint(value)
    }

    mutating func bool(_ field: Int, _ value: Bool) {
        varint(field, value ? 1 : 0)
    }

    mutating func bytes(_ field: Int, _ value: Data) {
        tag(field, wireType: 2)
        appendVarint(UInt64(value.count))
        data.append(value)
    }

    /// A nested message. Always emitted, even when empty: an empty message is
    /// how a protobuf `oneof` says which command this is.
    mutating func message(_ field: Int, _ build: (inout ProtoWriter) -> Void = { _ in }) {
        var inner = ProtoWriter()
        build(&inner)
        bytes(field, inner.data)
    }

    private mutating func tag(_ field: Int, wireType: UInt64) {
        appendVarint(UInt64(field) << 3 | wireType)
    }

    private mutating func appendVarint(_ value: UInt64) {
        var v = value
        while v >= 0x80 {
            data.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        data.append(UInt8(v))
    }
}

struct ProtoMessage {
    private var varints: [Int: [UInt64]] = [:]
    private var blobs: [Int: [Data]] = [:]

    init(_ input: Data) throws {
        let bytes = [UInt8](input)
        var i = 0

        func readVarint() throws -> UInt64 {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while true {
                guard i < bytes.count, shift < 64 else { throw InkletSetupError.protocolViolation("truncated varint") }
                let b = bytes[i]
                i += 1
                result |= UInt64(b & 0x7F) << shift
                if b & 0x80 == 0 { return result }
                shift += 7
            }
        }

        while i < bytes.count {
            let key = try readVarint()
            let field = Int(key >> 3)
            switch key & 7 {
            case 0:
                varints[field, default: []].append(try readVarint())
            case 1:
                guard bytes.count - i >= 8 else { throw InkletSetupError.protocolViolation("truncated fixed64") }
                i += 8
            case 2:
                let length = try readVarint()
                guard length <= UInt64(bytes.count - i) else { throw InkletSetupError.protocolViolation("truncated field") }
                let end = i + Int(length)
                blobs[field, default: []].append(Data(bytes[i..<end]))
                i = end
            case 5:
                guard bytes.count - i >= 4 else { throw InkletSetupError.protocolViolation("truncated fixed32") }
                i += 4
            default:
                throw InkletSetupError.protocolViolation("unknown wire type")
            }
        }
    }

    /// proto3 leaves zero values off the wire, so a missing scalar reads as 0.
    func varint(_ field: Int) -> UInt64 { varints[field]?.last ?? 0 }
    func int32(_ field: Int) -> Int32 { Int32(truncatingIfNeeded: Int64(bitPattern: varint(field))) }
    func bool(_ field: Int) -> Bool { varint(field) != 0 }
    func bytes(_ field: Int) -> Data? { blobs[field]?.last }
    func has(_ field: Int) -> Bool { blobs[field] != nil || varints[field] != nil }

    func message(_ field: Int) throws -> ProtoMessage? {
        try bytes(field).map { try ProtoMessage($0) }
    }

    func messages(_ field: Int) throws -> [ProtoMessage] {
        try (blobs[field] ?? []).map { try ProtoMessage($0) }
    }
}
