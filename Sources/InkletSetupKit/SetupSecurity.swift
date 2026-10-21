import CommonCrypto
import CryptoKit
import Foundation

/// Espressif protocomm "Security 1" (sec1.proto): an X25519 key agreement whose
/// shared secret is XORed with SHA-256 of the proof of possession (the code
/// printed on the display), then a single AES-256-CTR keystream — IV = the
/// device's random — consumed in order by every byte sent *and* received for
/// the rest of the session. Both ends advance the same stream, so requests and
/// responses must be processed strictly in turn.
final class SetupSecurity1 {
    private let privateKey = Curve25519.KeyAgreement.PrivateKey()
    private var cryptor: CCCryptorRef?

    var clientPublicKey: Data { privateKey.publicKey.rawRepresentation }

    deinit {
        if let cryptor { CCCryptorRelease(cryptor) }
    }

    func start(devicePublicKey: Data, deviceRandom: Data, proofOfPossession: String) throws {
        guard devicePublicKey.count == 32, deviceRandom.count == 16 else {
            throw InkletSetupError.protocolViolation("bad session parameters")
        }
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: devicePublicKey)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        var key = shared.withUnsafeBytes { Data($0) }
        if !proofOfPossession.isEmpty {
            let digest = SHA256.hash(data: Data(proofOfPossession.utf8))
            key = Data(zip(key, digest).map { $0 ^ $1 })
        }
        try installCipher(key: key, iv: deviceRandom)
    }

    /// AES-256-CTR with a big-endian 128-bit counter starting at `iv`.
    func installCipher(key: Data, iv deviceRandom: Data) throws {
        var ref: CCCryptorRef?
        let status = key.withUnsafeBytes { k in
            deviceRandom.withUnsafeBytes { iv in
                CCCryptorCreateWithMode(
                    CCOperation(kCCEncrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES),
                    CCPadding(ccNoPadding), iv.baseAddress, k.baseAddress, key.count,
                    nil, 0, 0, CCModeOptions(kCCModeOptionCTR_BE), &ref)
            }
        }
        guard status == kCCSuccess, let ref else {
            throw InkletSetupError.protocolViolation("cipher setup failed (\(status))")
        }
        if let cryptor { CCCryptorRelease(cryptor) }
        cryptor = ref
    }

    /// Encrypts or decrypts (CTR is symmetric) the next bytes of the stream.
    func apply(_ input: Data) throws -> Data {
        guard let cryptor else { throw InkletSetupError.protocolViolation("no secure session") }
        guard !input.isEmpty else { return input }
        var output = Data(count: input.count)
        var moved = 0
        let status = output.withUnsafeMutableBytes { out in
            input.withUnsafeBytes { inp in
                CCCryptorUpdate(cryptor, inp.baseAddress, input.count, out.baseAddress, input.count, &moved)
            }
        }
        guard status == kCCSuccess, moved == input.count else {
            throw InkletSetupError.protocolViolation("cipher failed (\(status))")
        }
        return output
    }
}
