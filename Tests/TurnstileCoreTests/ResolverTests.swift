import Testing
@testable import TurnstileCore

struct ResolverTests {
    @Test func homebrewInstallsLinkThroughThePrefix() {
        #expect(Resolver.homebrewLink(for: "/opt/homebrew/Cellar/turnstile/0.3.0/bin/turnstile") == "/opt/homebrew/bin/turnstile")
        #expect(Resolver.homebrewLink(for: "/usr/local/Cellar/turnstile/0.3.0_1/bin/turnstile") == "/usr/local/bin/turnstile")
        #expect(Resolver.homebrewLink(for: "/Users/me/turnstile/.build/release/turnstile") == nil)
    }
}
