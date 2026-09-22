import Foundation
import Testing
@testable import InkletMac

// `ASWebAuthenticationSession` hands back any `inklet:` URL. Tokens count only
// when they arrive at exactly the portal's callback address.

private func parse(_ raw: String) -> WebAuthCallback? {
    WebAuthCallback(URL(string: raw)!)
}

@Test func thePortalsCallbackCarriesTheSession() {
    #expect(parse("inklet://auth/callback?accessToken=a.b.c&refreshToken=r-1")
            == .tokens(AuthTokens(accessToken: "a.b.c", refreshToken: "r-1")))
    // Scheme and host are case-insensitive; the order of the query is not a rule.
    #expect(parse("INKLET://Auth/callback?refreshToken=r-1&accessToken=a.b.c")
            == .tokens(AuthTokens(accessToken: "a.b.c", refreshToken: "r-1")))
}

@Test func aFailureIsReportedAsOne() {
    #expect(parse("inklet://auth/callback?error=oauth_failed") == .failure("oauth_failed"))
    // An error wins over tokens that came with it.
    #expect(parse("inklet://auth/callback?error=oauth_failed&accessToken=a&refreshToken=r") == .failure("oauth_failed"))
}

@Test func tokensAnywhereElseAreNotASignIn() {
    for raw in [
        "inklet://evil/callback?accessToken=a&refreshToken=r",
        "inklet://auth/other?accessToken=a&refreshToken=r",
        "inklet://auth/callback/extra?accessToken=a&refreshToken=r",
        "inklet://auth/Callback?accessToken=a&refreshToken=r",
        "inklet://auth?accessToken=a&refreshToken=r",
        "inklet-mac://auth/callback?accessToken=a&refreshToken=r",
        "https://auth/callback?accessToken=a&refreshToken=r",
        "inklet://user@auth/callback?accessToken=a&refreshToken=r",
        "inklet://auth:8080/callback?accessToken=a&refreshToken=r",
        "inklet://auth/callback?accessToken=a&refreshToken=r#fragment",
    ] {
        #expect(parse(raw) == nil, "\(raw)")
    }
}

@Test func aCallbackWithoutAWholeSessionIsNothing() {
    for raw in [
        "inklet://auth/callback",
        "inklet://auth/callback?accessToken=a",
        "inklet://auth/callback?refreshToken=r",
        "inklet://auth/callback?accessToken=&refreshToken=r",
        "inklet://auth/callback?accessToken=a&accessToken=b&refreshToken=r",
    ] {
        #expect(parse(raw) == nil, "\(raw)")
    }
}
