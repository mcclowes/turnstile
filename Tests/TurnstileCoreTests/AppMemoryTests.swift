import Foundation
import Testing

@testable import TurnstileCore

struct AppMemoryTests {
    @Test(arguments: [
        (
            "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/1/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)",
            "Google Chrome"
        ),
        ("/Applications/Spotify.app/Contents/MacOS/Spotify", "Spotify"),
        ("/opt/homebrew/bin/node", "node"),
        (
            "/System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine",
            "Virtual machines"
        ),
        (
            "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent",
            "Safari and web views"
        ),
    ])
    func groupsHelpersUnderTheirApp(executable: String, app: String) {
        #expect(AppMemory.app(forExecutable: executable) == app)
    }

    @Test func keepsTheBiggestAppsAndDropsTheLongTail() {
        let processes: [(executable: String, bytes: UInt64)] = [
            ("/Applications/Slack.app/Contents/MacOS/Slack", 300 * Bytes.mb),
            (
                "/Applications/Slack.app/Contents/Frameworks/Slack Helper.app/Contents/MacOS/Slack Helper",
                500 * Bytes.mb
            ),
            ("/Applications/Spotify.app/Contents/MacOS/Spotify", 200 * Bytes.mb),
            ("/usr/libexec/tiny", 10 * Bytes.mb),
            ("/opt/homebrew/bin/node", 400 * Bytes.mb),
        ]
        let top = AppMemory.top(processes, limit: 2, floor: 50 * Bytes.mb)
        #expect(
            top == [
                AppFootprint(app: "Slack", bytes: 800 * Bytes.mb), AppFootprint(app: "node", bytes: 400 * Bytes.mb),
            ])
        #expect(!AppMemory.top(processes, limit: 10, floor: 50 * Bytes.mb).contains { $0.app == "tiny" })
    }

    func store() throws -> (Store, String) {
        let path = NSTemporaryDirectory() + "turnstile-apps-\(UUID().uuidString).sqlite"
        return (try Store(path: path), path)
    }

    @Test("An app's average counts the samples it was missing from as zero", .bug(id: 140))
    func averagesAcrossEverySample() throws {
        let (store, path) = try store()
        defer { try? FileManager.default.removeItem(atPath: path) }
        store.insertMemorySample(
            at: 100, total: 6 * Bytes.gb,
            apps: [AppFootprint(app: "Chrome", bytes: 4 * Bytes.gb), AppFootprint(app: "Spotify", bytes: Bytes.gb)])
        store.insertMemorySample(at: 160, total: 4 * Bytes.gb, apps: [AppFootprint(app: "Chrome", bytes: 2 * Bytes.gb)])
        store.insertMemorySample(at: 10, total: 9 * Bytes.gb, apps: [AppFootprint(app: "Old", bytes: 9 * Bytes.gb)])

        let report = store.appMemory(since: 50, limit: 10)
        #expect(report.samples == 2)
        #expect(report.averageTotal == 5 * Bytes.gb)
        #expect(
            report.apps == [
                AppUsage(app: "Chrome", average: 3 * Bytes.gb, peak: 4 * Bytes.gb, presence: 1),
                AppUsage(app: "Spotify", average: Bytes.gb / 2, peak: Bytes.gb, presence: 0.5),
            ])
        #expect(store.appMemory(since: 50, limit: 1).apps.map(\.app) == ["Chrome"])
        #expect(store.appMemory(since: 50, limit: 1).more == 1)

        store.prune(olderThan: 150)
        #expect(store.appMemory(since: 0, limit: 10).samples == 1)
    }

    @Test func reportsWhatHeldMemoryAndHowLongItWatched() {
        let report = AppMemoryReport(
            days: 7, samples: 852, averageTotal: 9 * Bytes.gb, physical: 36 * Bytes.gb,
            apps: [
                AppUsage(app: "Google Chrome", average: 4_400_000_000, peak: 7 * Bytes.gb, presence: 1),
                AppUsage(app: "Spotify", average: 600 * Bytes.mb, peak: 900 * Bytes.mb, presence: 0.42),
            ], more: 3)
        #expect(
            AppMemoryFormatter.render(report) == """
                apps: sampled every minute while turnstile ran, 14h12m over the last 7 days

                  app            average    peak  present
                  Google Chrome   4.1 GB    7 GB     100%
                  Spotify         600 MB  900 MB      42%
                  and 3 more

                Everything outside turnstile's jobs averaged 9 GB. Like Activity Monitor, that counts
                compressed and swapped memory, so it can add up to more than this Mac's 36 GB.
                """)
    }

    @Test func saysWhenThereIsNothingYet() {
        let report = AppMemoryReport(days: 7, samples: 0, averageTotal: 0, physical: 36 * Bytes.gb, apps: [], more: 0)
        #expect(
            AppMemoryFormatter.render(report)
                == "apps: no samples in the last 7 days. turnstile samples app memory while its daemon runs.")
    }
}
