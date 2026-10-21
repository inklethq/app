import Foundation

/// A hardware display's claim credential: `inklet://bind?v=2&kid=…&hw=…&cv=…&p=…`,
/// the URI its NFC tag carries (backend: internal/nfc). A Mac can't read the
/// tag, so the display hands the same URI over during Bluetooth setup, inside
/// the session secured by the code on its screen.
///
/// Only the shape is checked here; the backend verifies the proof and answers
/// every unusable credential with the same INVALID_NFC_CREDENTIAL.
struct DisplayBindCredential: Equatable, Sendable {
    let keyID: String
    let hwID: String
    let credentialVersion: Int
    let proof: String

    init?(uri: String) {
        guard let components = URLComponents(string: uri),
              components.scheme == "inklet", components.host == "bind" else { return nil }
        func value(_ name: String) -> String? {
            components.queryItems?.first { $0.name == name }?.value
        }
        guard value("v") == "2",
              let kid = value("kid"), !kid.isEmpty,
              let hw = value("hw"), hw.count == 32,
              let cv = value("cv").flatMap(Int.init), cv >= 1,
              let proof = value("p"), !proof.isEmpty
        else { return nil }
        keyID = kid
        hwID = hw
        credentialVersion = cv
        self.proof = proof
    }

    /// Body of `POST /api/devices/bind/nfc`.
    var requestBody: [String: Any] {
        ["version": 2, "keyId": keyID, "hwId": hwID, "credentialVersion": credentialVersion, "proof": proof]
    }
}

/// One case per backend code; the wording is ours, the codes are the contract.
enum DisplayBindError: LocalizedError, Equatable, Sendable {
    case invalidCredential
    case alreadyBound
    case notFound
    case other(String)

    var errorDescription: String? {
        switch self {
        case .invalidCredential: "This display's pairing credential wasn't accepted. Contact inklet support."
        case .alreadyBound: "This display already belongs to another inklet account. Its owner has to remove it first."
        case .notFound: "inklet doesn't know this display yet. Contact inklet support."
        case .other(let message): message
        }
    }

    static func from(status: Int, code: String?, message: String?) -> DisplayBindError {
        switch code {
        case "INVALID_NFC_CREDENTIAL": .invalidCredential
        case "DEVICE_ALREADY_BOUND": .alreadyBound
        case "DEVICE_NOT_FOUND": .notFound
        default: .other(message ?? "Couldn't add the display (\(status)).")
        }
    }
}
