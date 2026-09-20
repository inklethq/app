import Foundation
import Testing
@testable import InkletMac

// A Quote/0 arrives as an ordinary device row with `transport: "dot_cloud"`
// and a serial number; the app tells it apart by that alone, and an older
// backend that sends no transport is still inklet hardware.

private func decodeDevice(_ json: String) throws -> Device {
    Device(dto: try JSONDecoder().decode(DeviceDTO.self, from: Data(json.utf8)))
}

@Test func aDotCloudRowIsAQuote0NamedByItsSerial() throws {
    let device = try decodeDevice(#"""
    {"id":"d1","hwId":"dot:ABCD1234ABCD","thingName":"quote0-abcd1234abcd","transport":"dot_cloud",
     "cloudDeviceId":"ABCD1234ABCD","cloudModel":"quote_0","online":true,"battery":85,"firmware":"1.2.3",
     "cloudDeliveryError":"Dot. could not find the display, or it has no Image API item in its loop task.",
     "cloudDeliveryErrorAt":"2026-09-20T01:02:03Z"}
    """#)
    #expect(device.kind == .quote0)
    #expect(device.displayName == "ABCD1234ABCD")
    #expect(device.identifier == "ABCD1234ABCD")
    #expect(device.identifierLabel == "Serial")
    #expect(device.modelName == "Quote/0")
    #expect(device.symbol == "cloud")
    #expect(device.cloudDeliveryError?.hasPrefix("Dot. could not find") == true)
    #expect(device.cloudDeliveryErrorAt != nil)
    #expect(device.battery == 85)
}

@Test func aNicknameStillWinsOnAQuote0() throws {
    let device = try decodeDevice(#"{"id":"d1","hwId":"dot:ABCD1234ABCD","thingName":"t","transport":"dot_cloud","cloudDeviceId":"ABCD1234ABCD","nickname":"Desk"}"#)
    #expect(device.displayName == "Desk")
    #expect(device.identifier == "ABCD1234ABCD")
}

@Test func aRowWithoutATransportIsInkletHardware() throws {
    let device = try decodeDevice(#"{"id":"d2","hwId":"92be8ee85ee74c7b9ea7de00b6eb3801","thingName":"inklet-1","online":false}"#)
    #expect(device.kind == .inklet)
    #expect(device.displayName == "92be8ee85ee74c7b9ea7de00b6eb3801")
    #expect(device.identifierLabel == "Hardware ID")
    #expect(device.modelName == "inklet D1")
    #expect(device.cloudDeliveryError == nil)

    let explicit = try decodeDevice(#"{"id":"d3","hwId":"aa","thingName":"t","transport":"mqtt"}"#)
    #expect(explicit.kind == .inklet)
}

@Test func anEmptyDeliveryErrorReadsAsNone() throws {
    let device = try decodeDevice(#"{"id":"d1","hwId":"dot:X","thingName":"t","transport":"dot_cloud","cloudDeviceId":"ABCD1234ABCD","cloudDeliveryError":""}"#)
    #expect(device.cloudDeliveryError == nil)
}

@Test func theBindResponseIsTheNFCBindsShape() throws {
    let response = try JSONDecoder().decode(Quote0BindResponseDTO.self, from: Data(#"""
    {"device":{"id":"d1","hwId":"dot:ABCD1234ABCD","thingName":"t","transport":"dot_cloud","cloudDeviceId":"ABCD1234ABCD"},"status":"bound"}
    """#.utf8))
    #expect(response.status == "bound")
    #expect(Device(dto: response.device).kind == .quote0)
}

// The backend's codes decide the message; an unknown code keeps the backend's
// own sentence rather than inventing one.
@Test func bindErrorsFollowTheBackendCodes() {
    #expect(Quote0BindError.from(status: 400, code: "INVALID_DOT_API_KEY", message: "x") == .invalidKey)
    #expect(Quote0BindError.from(status: 404, code: "DOT_DEVICE_NOT_FOUND", message: "x") == .notInAccount)
    #expect(Quote0BindError.from(status: 409, code: "DEVICE_ALREADY_BOUND", message: "x") == .alreadyBound)
    #expect(Quote0BindError.from(status: 429, code: "DOT_RATE_LIMITED", message: "x") == .rateLimited)
    #expect(Quote0BindError.from(status: 502, code: "DOT_UNAVAILABLE", message: "x") == .dotUnavailable)
    #expect(Quote0BindError.from(status: 503, code: "QUOTE0_UNAVAILABLE", message: "x") == .unavailable)
    #expect(Quote0BindError.from(status: 500, code: "INTERNAL_ERROR", message: "internal error") == .other("internal error"))
    #expect(Quote0BindError.from(status: 418, code: nil, message: nil) == .other("The display couldn't be connected (418)."))
    for error in [Quote0BindError.invalidKey, .notInAccount, .alreadyBound, .rateLimited, .dotUnavailable, .unavailable] {
        #expect(error.errorDescription?.isEmpty == false)
    }
}
