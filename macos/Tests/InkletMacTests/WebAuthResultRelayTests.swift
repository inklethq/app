import Foundation
import Testing
@testable import InkletMac

@MainActor
@Test func webAuthenticationCanCompleteFromBackgroundQueue() async throws {
    let expected = URL(string: "inklet://auth/callback?test=success")!
    let received: URL = try await withCheckedThrowingContinuation { continuation in
        let result = WebAuthResultRelay(continuation)
        let callback = result.completion
        DispatchQueue.global().async { callback(expected, nil) }
    }
    #expect(received == expected)
}

@MainActor
@Test func webAuthenticationFailureAndLateCallbackResumeOnlyOnce() async {
    do {
        let _: URL = try await withCheckedThrowingContinuation { continuation in
            let result = WebAuthResultRelay(continuation)
            result.finish(callback: nil, error: URLError(.cannotConnectToHost))
            result.completion(URL(string: "inklet://auth/callback?test=late"), nil)
        }
        Issue.record("Expected the first completion's failure")
    } catch let error as URLError {
        #expect(error.code == .cannotConnectToHost)
    } catch { Issue.record("Unexpected error type") }
}
