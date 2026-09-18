import Testing
@testable import TurnstileCore

struct ClassifierTests {
    func classify(_ command: String, interactive: Bool = false, config: Config = Config()) -> Classification? {
        let words = command.split(separator: " ").map(String.init)
        return Classifier.classify(tool: words[0], args: Array(words.dropFirst()), context: ClassifierContext(config: config, interactive: interactive))
    }

    @Test(arguments: [
        ("swift build", ResourceClass.compile, "swift build"),
        ("swift test --filter Foo", .test, "swift test"),
        ("xcodebuild -scheme App build", .compile, "xcodebuild build"),
        ("xcodebuild -scheme App test", .test, "xcodebuild test"),
        ("cargo +nightly t", .test, "cargo test"),
        ("cargo b --release", .compile, "cargo build"),
        ("go test ./...", .test, "go test"),
        ("go -C sub build", .compile, "go build"),
        ("gradle assemble", .compile, "gradle build"),
        ("gradle :app:testDebugUnitTest", .test, "gradle test"),
        ("make -j 8", .compile, "make"),
        ("make test", .test, "make test"),
        ("npm test", .test, "npm run test"),
        ("npm run build", .compile, "npm run build"),
        ("npm run test:e2e", .browser, "npm run test:e2e"),
        ("pnpm --filter web test", .test, "pnpm run test"),
        ("pnpm typecheck", .compile, "pnpm run typecheck"),
        ("yarn lint", .compile, "yarn run lint"),
        ("bun test", .test, "bun test"),
        ("npx vitest run", .test, "vitest run"),
        ("pnpm exec jest", .test, "jest"),
        ("playwright test", .browser, "playwright test"),
        ("tsc -p .", .compile, "tsc"),
    ])
    func gates(command: String, cls: ResourceClass, key: String) {
        let result = classify(command)
        #expect(result?.resourceClass == cls)
        #expect(result?.key == key)
    }

    @Test(arguments: [
        "swift --version", "swift", "swift run", "swift package resolve", "swift format .",
        "xcodebuild -version", "xcodebuild -showBuildSettings -scheme App", "xcodebuild -list",
        "cargo run", "cargo fmt", "go list ./...", "go env GOPATH", "go run .",
        "gradle --stop", "gradle tasks", "make -n", "make clean",
        "npm install", "npm ci", "npm run dev", "npm start", "npm run", "npm exec prettier",
        "pnpm add left-pad", "yarn", "yarn dev", "bun install", "bun script.ts",
        "vitest watch", "vitest --watch", "jest --watch", "playwright install", "tsc --watch",
        "git status", "ls -la",
    ])
    func passesThrough(command: String) {
        #expect(classify(command) == nil)
    }

    @Test func vitestWatchesOnlyInATerminal() {
        #expect(classify("vitest", interactive: true) == nil)
        #expect(classify("vitest", interactive: false)?.resourceClass == .test)
        #expect(classify("vitest --run", interactive: true)?.resourceClass == .test)
    }

    @Test func projectRulesOverrideTheBuiltInTable() {
        let project = ConfigFile(
            commands: ["swift test": .gate(.test, memory: 6 * Bytes.gb), "make": .pass, "go list": .gate(.compile, memory: nil)],
            scripts: ["verify": .gate(.test, memory: nil), "build": .pass]
        )
        let config = Config(project: project)
        #expect(classify("swift test", config: config)?.memory == 6 * Bytes.gb)
        #expect(classify("make test", config: config) == nil)
        #expect(classify("go list ./...", config: config)?.resourceClass == .compile)
        #expect(classify("npm run verify", config: config)?.resourceClass == .test)
        #expect(classify("npm run build", config: config) == nil)
    }

    @Test func longestCommandPrefixWins() {
        let global = ConfigFile(commands: ["swift": .pass, "swift test": .gate(.test, memory: Bytes.gb)])
        let config = Config(global: global)
        #expect(classify("swift build", config: config) == nil)
        #expect(classify("swift test", config: config)?.memory == Bytes.gb)
    }

    @Test(arguments: [
        ("test", ResourceClass?.some(.test)), ("test:unit", .test), ("e2e", .browser), ("build:prod", .compile),
        ("typecheck", .compile), ("dev", nil), ("start", nil), ("test:watch", nil), ("release", nil),
    ])
    func scriptNames(name: String, expected: ResourceClass?) {
        #expect(Classifier.scriptClass(name) == expected)
    }
}
