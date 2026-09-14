import Foundation

/// AuthenticationServices may complete on its XPC queue. This adapter has no
/// actor isolation; CheckedContinuation safely resumes the awaiting actor.
/// The lock also arbitrates an immediate start failure and a later callback.
final class WebAuthResultRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, any Error>?

    init(_ continuation: CheckedContinuation<URL, any Error>) {
        self.continuation = continuation
    }

    var completion: @Sendable (URL?, (any Error)?) -> Void {
        { [self] callback, error in finish(callback: callback, error: error) }
    }

    func finish(callback: URL?, error: (any Error)?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        guard let pending else { return }
        if let error { pending.resume(throwing: error) }
        else if let callback { pending.resume(returning: callback) }
        else { pending.resume(throwing: URLError(.badServerResponse)) }
    }
}
