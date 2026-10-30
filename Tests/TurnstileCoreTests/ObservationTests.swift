import Darwin
import Foundation
import Testing

@testable import TurnstileCore

struct MemoryObservationTests {
    @Test func healthyObservationsAreMeasuredAndRoundTrip() throws {
        let home = "/tmp/ts-memory-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        var environment: [String: String] = [:]
        for (name, value) in [("MEMORY_LEVEL", "82"), ("PRESSURE_LEVEL", "1"), ("SWAP_USED", "0")] {
            let path = home + "/" + name
            try value.write(toFile: path, atomically: true, encoding: .utf8)
            environment["TURNSTILE_" + name + "_FILE"] = path
        }
        let observation = SystemMemory.observation(environment: environment, at: 42)
        #expect(observation.complete)
        #expect(observation.level == 82)
        #expect(observation.kernelPressure == 1)
        #expect(observation.swapUsed == 0)
        #expect(observation.physical == SystemMemory.physical)
        #expect(observation.summary.contains("unknown") == false)
        #expect(
            try JSONDecoder().decode(MemoryObservation.self, from: JSONEncoder().encode(observation)) == observation)
    }

    @Test func failedOverridesAreUnknownAndSchedulingStillFailsOpen() {
        let observation = SystemMemory.observation(environment: ["TURNSTILE_MEMORY_LEVEL_FILE": "/no-such-file"])
        #expect(observation.level == nil)
        #expect(observation.complete == false)
        #expect(observation.errors["kern.memorystatus_level"] != nil)
        #expect(observation.summary.contains("unknown"))
        #expect(observation.schedulingSample(at: 0).level == 100)
    }

    @Test(arguments: [EPERM, EACCES, ENOENT, ECONNREFUSED, ENAMETOOLONG, ETIMEDOUT])
    func connectionErrorsKeepTheirMeaning(_ code: Int32) {
        let failure = ConnectionFailure(code: code)
        switch code {
        case EPERM, EACCES: #expect(failure.observation == "permissionDenied")
        case ENOENT, ECONNREFUSED: #expect(failure.observation == "absent")
        case ENAMETOOLONG: #expect(failure.observation == "unknown")
        default: #expect(failure.observation == "unreachable")
        }
    }
}
