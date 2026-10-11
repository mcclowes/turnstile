import Testing

@testable import TurnstileCore

struct PausePolicyTests {
    @Test(arguments: [
        (nil as Bool?, [ResourceClass.compile]),
        (true, ResourceClass.allCases),
        (false, []),
    ])
    func eligibilityMatchesConfiguration(_ configured: Bool?, _ eligible: [ResourceClass]) {
        let policy = PausePolicy(configured: configured)
        #expect(policy.configured == configured)
        for resourceClass in ResourceClass.allCases {
            #expect(policy.allows(agent: true, resourceClass: resourceClass) == eligible.contains(resourceClass))
            #expect(!policy.allows(agent: false, resourceClass: resourceClass))
        }
    }
}
