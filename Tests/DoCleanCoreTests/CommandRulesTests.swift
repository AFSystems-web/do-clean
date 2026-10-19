import XCTest
@testable import DoCleanCore

final class CommandRulesTests: XCTestCase {
    var fs: FakeFS!
    override func setUp() { fs = FakeFS() }

    func scan(_ id: String, runner: FakeRunner) async throws -> RuleResult {
        await CleanScanner(environment: fs.env(runner: runner)).scan(rule: try rule(id))
    }

    func testSimctlUnavailableSumsDataPaths() async throws {
        let dev = "Library/Developer/CoreSimulator/Devices/"
        fs.file(dev + "AAAA/data/x.bin", size: 400_000); fs.file(dev + "BBBB/data/x.bin", size: 300_000)
        fs.file(dev + "CCCC/data/x.bin", size: 900_000)   // available simulator: must not be counted
        let json = """
        {"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-16-0":[
          {"dataPath":"\(fs.path(dev + "AAAA/data").path)","name":"a","isAvailable":false},
          {"dataPath":"\(fs.path(dev + "BBBB/data").path)","name":"b","isAvailable":false}]}}
        """
        var runner = FakeRunner(installed: ["xcrun"])
        runner.outputs["simctl list devices unavailable -j"] = CommandOutput(status: 0, stdout: json)
        let r = try await scan("simulators-unavailable", runner: runner)
        XCTAssertEqual(r.status, .ready)
        XCTAssertEqual(r.items.count, 1)
        XCTAssertTrue(r.items[0].isCommand)
        XCTAssertGreaterThanOrEqual(r.bytes, 700_000); XCTAssertLessThan(r.bytes, 900_000)
    }

    func testSimctlMissingIsUnavailable() async throws {
        let r = try await scan("simulators-unavailable", runner: FakeRunner())
        XCTAssertEqual(r.status, .unavailable)
    }

    func testSimulatorsEraseAllCountsDeviceData() async throws {
        let dev = "Library/Developer/CoreSimulator/Devices/"
        fs.file(dev + "AAAA/data/x.bin", size: 400_000); fs.file(dev + "AAAA/device.plist", size: 10)
        let r = try await scan("simulators-data", runner: FakeRunner(installed: ["xcrun"]))
        XCTAssertGreaterThanOrEqual(r.bytes, 400_000); XCTAssertLessThan(r.bytes, 450_000)
        XCTAssertEqual(r.rule.tier, .yellow)
    }

    func testBrewCleanupParsesEstimate() async throws {
        var runner = FakeRunner(installed: ["brew"])
        runner.outputs["cleanup -n --prune=all"] = CommandOutput(status: 0, stdout: "Would remove: x\n==> This operation would free approximately 1.5GB of disk space.\n")
        let r = try await scan("homebrew-cleanup", runner: runner)
        XCTAssertEqual(r.bytes, 1_500_000_000)
        runner.outputs["cleanup -n --prune=all"] = CommandOutput(status: 0, stdout: "")
        let r1 = try await scan("homebrew-cleanup", runner: runner)
        XCTAssertEqual(r1.status, .empty)
        let r2 = try await scan("homebrew-cleanup", runner: FakeRunner())
        XCTAssertEqual(r2.status, .unavailable)
    }

    func testDockerOnlyIfInstalledAndRunning() async throws {
        let r3 = try await scan("docker", runner: FakeRunner())
        XCTAssertEqual(r3.status, .unavailable)
        var runner = FakeRunner(installed: ["docker"])
        runner.outputs["system df --format {{json .}}"] = CommandOutput(status: 0, stdout: """
        {"Type":"Images","Reclaimable":"2.5GB (60%)"}
        {"Type":"Containers","Reclaimable":"500MB (100%)"}
        {"Type":"Build Cache","Reclaimable":"0B"}
        """)
        let r = try await scan("docker", runner: runner)
        XCTAssertEqual(r.bytes, 3_000_000_000)
        runner.outputs["system df --format {{json .}}"] = CommandOutput(status: 1, stdout: "")
        let r4 = try await scan("docker", runner: runner)
        XCTAssertEqual(r4.status, .unavailable)
    }

    func testParseSize() {
        XCTAssertEqual(CleanScanner.parseSize("1.5GB"), 1_500_000_000)
        XCTAssertEqual(CleanScanner.parseSize("850 MB"), 850_000_000)
        XCTAssertEqual(CleanScanner.parseSize("12.5kB"), 12_500)
        XCTAssertEqual(CleanScanner.parseSize("0B"), 0)
        XCTAssertEqual(CleanScanner.parseSize("garbage"), 0)
    }
}
