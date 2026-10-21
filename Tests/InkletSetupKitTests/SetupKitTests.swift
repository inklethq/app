import Foundation
import Testing
@testable import InkletSetupKit

private func hex(_ s: String) -> Data {
    var data = Data()
    var i = s.startIndex
    while i < s.endIndex {
        let j = s.index(i, offsetBy: 2)
        data.append(UInt8(s[i..<j], radix: 16)!)
        i = j
    }
    return data
}

// The set-Wi-Fi command as the display's protobuf-c decoder expects it.
@Test func setWiFiCommandRoundTrips() throws {
    var w = ProtoWriter()
    w.varint(1, 2)
    w.message(12) { cmd in
        cmd.bytes(1, Data("wifi_clck".utf8))
        cmd.bytes(2, Data("hunter22".utf8))
    }
    let decoded = try ProtoMessage(w.data)
    #expect(decoded.varint(1) == 2)
    let cmd = try #require(try decoded.message(12))
    #expect(cmd.bytes(1) == Data("wifi_clck".utf8))
    #expect(cmd.bytes(2) == Data("hunter22".utf8))
}

// An empty command still has to be on the wire: it is what selects the oneof.
@Test func emptyMessagesAreEmitted() throws {
    var w = ProtoWriter()
    w.varint(1, 0)
    w.message(10)
    #expect(w.data == Data([0x08, 0x00, 0x52, 0x00]))
    #expect(try ProtoMessage(w.data).has(10))
}

@Test func negativeRSSIDecodes() throws {
    var w = ProtoWriter()
    w.varint(3, UInt64(bitPattern: Int64(-57)))
    #expect(try ProtoMessage(w.data).int32(3) == -57)
}

@Test func truncatedInputIsRejected() {
    #expect(throws: InkletSetupError.self) { try ProtoMessage(Data([0x0A, 0x05, 0x01])) }
}

// NIST SP 800-38A F.5.5 (CTR-AES256), whose counter carries across a byte
// boundary between the two blocks — the case a little-endian counter gets wrong.
@Test func ctrMatchesNISTVector() throws {
    let sec = SetupSecurity1()
    try sec.installCipher(key: hex("603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4"),
                          iv: hex("f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff"))
    // Fed in uneven pieces: the keystream must continue across calls.
    let a = try sec.apply(hex("6bc1bee22e409f96e93d7e11"))
    let b = try sec.apply(hex("7393172aae2d8a571e03ac9c9eb76fac45af8e51"))
    #expect(a + b == hex("601ec313775789a5b7a7f504bbf3d228f443e3ca4d62b59aca84e990cacaf5c5"))
}

// Both ends of a session derive the same key from each other's public keys
// and the same code, so one end decrypts what the other encrypts.
@Test func bothEndsAgreeOnTheKey() throws {
    let client = SetupSecurity1()
    let device = SetupSecurity1()
    let random = Data((0..<16).map { UInt8($0) })
    try client.start(devicePublicKey: device.clientPublicKey, deviceRandom: random, proofOfPossession: "Q4VV4MA5")
    try device.start(devicePublicKey: client.clientPublicKey, deviceRandom: random, proofOfPossession: "Q4VV4MA5")
    let message = Data("{\"hwId\":\"8d1d\"}".utf8)
    #expect(try device.apply(client.apply(message)) == message)

}

// A client holding the wrong code derives a different key: the display can't
// read it, which is how the handshake rejects a mistyped code.
@Test func aWrongCodeYieldsADifferentKey() throws {
    let client = SetupSecurity1()
    let device = SetupSecurity1()
    let random = Data(repeating: 7, count: 16)
    try client.start(devicePublicKey: device.clientPublicKey, deviceRandom: random, proofOfPossession: "AAAAAAAA")
    try device.start(devicePublicKey: client.clientPublicKey, deviceRandom: random, proofOfPossession: "Q4VV4MA5")
    let message = Data(repeating: 0x42, count: 32)
    #expect(try device.apply(client.apply(message)) != message)
}

@Test func setupQRParses() {
    let qr = InkletSetupQR(#"{"ver":"v1","name":"INKLET-2078","pop":"Q4VV4MA5","transport":"ble"}"#)
    #expect(qr?.name == "INKLET-2078")
    #expect(qr?.code == "Q4VV4MA5")
    #expect(InkletSetupQR("inklet://bind?v=2") == nil)
    #expect(InkletSetupQR(#"{"name":"INKLET-2078","pop":"X","transport":"softap"}"#) == nil)
}
