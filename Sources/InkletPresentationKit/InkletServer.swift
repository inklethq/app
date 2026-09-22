import Foundation

/// The inklet API host, for the app and the widget alike.
///
/// A build can point both at another host: `Scripts/build-app.sh` and
/// `Scripts/build-widgets.sh` copy `INKLET_API_BASE_URL` into each bundle's
/// Info.plist as `InkletAPIBaseURL`. Unset, empty, or not an https URL, it is
/// the default below — which is also what tests and `swift run` get, having
/// no such key.
nonisolated public enum InkletServer {
    public static let defaultAPIBase = URL(string: "https://dev.iminklet.com")!

    public static let apiBase = apiBase(from: Bundle.main.object(forInfoDictionaryKey: "InkletAPIBaseURL") as? String)

    /// Account tokens ride on every request to this host, so only https is
    /// taken. A trailing slash is dropped so paths join the same way whatever
    /// the build wrote.
    static func apiBase(from raw: String?) -> URL {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return defaultAPIBase }
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), url.scheme?.lowercased() == "https",
              let host = url.host(), !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return defaultAPIBase }
        return url
    }
}
