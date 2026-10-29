import Foundation
import T3UsageCore

final class CoreTests {
    let now = Fixture.now
    func config(limits: [String: Any]? = nil) -> [String: Any] {
        var provider: [String: Any] = ["enabled": true, "instanceId": "codex-a", "driver": "codex", "displayName": "Custom", "auth": ["email": "synthetic@example.invalid"]]
        if let limits { provider["usageLimits"] = limits }
        return ["environment": ["environmentId": "env-a"], "providers": [provider]]
    }
    func limits(_ used: Any = 31.2) -> [String: Any] {
        ["checkedAt": "2026-10-28T17:59:00Z", "windows": [["id": "w", "kind": "session", "label": "5h", "usedPercent": used, "resetsAt": "2026-10-28T20:00:00Z"]]]
    }
    func parse(_ limits: [String: Any]?) throws -> UsageAccount {
        try SnapshotParser.parse(config: config(limits: limits), sources: [], now: now).accounts[0]
    }
    func testDecodingAndConservativeRemaining() throws {
        for (used, remaining) in [(0.0,100),(0.1,99),(31.2,68),(100,0)] {
            let a = try parse(limits(used)); let w = try unwrap(a.windows.first)
            expectEqual(w.remaining, remaining)
            expectEqual(a.bar(for: w, now: now, connected: true), "\(remaining)%")
        }
    }
    func testMissingAndEmptyNeverBecomeFull() throws {
        let absent = try parse(nil)
        expectEqual(absent.bar(for: nil, now: now, connected: true), "—")
        var raw = limits(); raw["windows"] = []
        let empty = try parse(raw)
        expectEqual(empty.bar(for: nil, now: now, connected: true), "—")
        expectEqual(empty.state(for: nil, now: now, connected: true), "No quota windows supplied")
    }
    func testMalformedValuesAndWindowDataFailClosed() throws {
        for bad: Any in [-0.1, 100.1, "20", true, NSNull(), Double.nan, Double.infinity] {
            let a = try parse(limits(bad)); expectNotNil(a.unavailable)
            expectEqual(a.bar(for: a.windows.first, now: now, connected: true), "—")
        }
        var malformed = limits(0); malformed["unavailable"] = "bad"
        expectNotNil(try parse(malformed).unavailable)
        for field in ["checkedAt", "windows"] {
            var raw = limits(); raw.removeValue(forKey: field)
            expectNotNil(try parse(raw).unavailable)
        }
        var raw = limits(); raw["windows"] = [["id": "w", "kind": "session", "label": "Bad reset", "usedPercent": 0, "resetsAt": "bad"]]
        expectNotNil(try parse(raw).unavailable)
        expectThrows(try SnapshotParser.parse(config: ["providers": []], sources: []))
    }
    func testUnavailableSnapshotsKeepFailureWithBars() throws {
        for reason in ["unsupported", "probeFailed", "futureReason"] {
            var raw = limits(0); raw["unavailable"] = ["reason": reason, "message": "sensitive upstream error"]
            let a = try parse(raw)
            expectNotNil(a.unavailable)
            expectEqual(a.bar(for: a.windows.first, now: now, connected: true), "—")
            expectFalse(a.unavailable!.contains("sensitive"))
        }
    }
    func testStaleDisconnectedAndFutureClock() throws {
        let a = try parse(limits(40)); let w = try unwrap(a.windows.first)
        expectEqual(a.bar(for: w, now: now.addingTimeInterval(1000), connected: true), "~60%")
        expectEqual(a.bar(for: w, now: now, connected: false), "~60%")
        expectEqual(a.bar(for: w, now: now.addingTimeInterval(-200), connected: true), "—")
        expectTrue(a.state(for: w, now: now.addingTimeInterval(1000), connected: true).contains("Stale"))
    }
    func testResetBoundaryAndMissingReset() throws {
        let a = try parse(limits(0)); let w = try unwrap(a.windows.first)
        expectTrue(w.resetText(at: now).contains("Resets in 2h 0m"))
        let reset = try unwrap(w.resetsAt)
        expectEqual(a.bar(for: w, now: reset, connected: true), "—")
        expectTrue(w.resetText(at: reset).contains("Reset passed"))
        var raw = limits(); raw["windows"] = [["id": "w", "kind": "other", "label": "Window", "usedPercent": 10]]
        let noReset = try unwrap(parse(raw).windows.first)
        expectEqual(noReset.resetText(at: now), "Reset time not supplied by T3")
    }
    func testStableIndividualIdentitiesAndHubAccounts() throws {
        let a = try SnapshotParser.parse(config: config(limits: limits()), sources: [], now: now)
        var changed = config(limits: limits(70)); var p = changed["providers"] as! [[String: Any]]
        p[0]["displayName"] = "Renamed"; changed["providers"] = p
        let b = try SnapshotParser.parse(config: changed, sources: [], now: now)
        expectEqual(a.accounts[0].id, b.accounts[0].id)
        p[0]["auth"] = ["email": "different@example.invalid"]; changed["providers"] = p
        expectNotEqual(a.accounts[0].id, try SnapshotParser.parse(config: changed, sources: []).accounts[0].id)
        let demo = try Fixture.snapshot()
        expectEqual(demo.accounts.count, 3); expectEqual(Set(demo.accounts.map(\.id)).count, 3)
        expectEqual(demo.sourceCount, 1)
    }
    func testSelectionPersistenceMissingAccountAndWindow() throws {
        let s = try Fixture.snapshot(); var selection = Selection()
        selection.initializeIfNeeded(s.accounts)
        expectEqual(selection.account(in: s)?.driver, "codex")
        let account = try unwrap(selection.account(in: s))
        selection.windowsByAccount[account.id] = "weekly"
        let decoded = try JSONDecoder().decode(Selection.self, from: JSONEncoder().encode(selection))
        expectEqual(decoded, selection)
        expectEqual(Selection.fromStored(try JSONEncoder().encode(selection)), selection)
        var corrupt = Selection.fromStored(Data("bad-json".utf8))
        corrupt.initializeIfNeeded(s.accounts)
        expectEqual(corrupt.accountID, "invalid-saved-selection")
        expectEqual(decoded.window(in: account)?.kind, "weekly")
        selection.windowsByAccount[account.id] = "removed-window"
        selection.initializeIfNeeded(s.accounts)
        expectNil(selection.window(in: account))
        selection.accountID = "removed-account"
        selection.initializeIfNeeded(s.accounts)
        expectEqual(selection.accountID, "removed-account"); expectNil(selection.account(in: s))
        var awaiting = Selection(accountID: account.id)
        awaiting.initializeIfNeeded(s.accounts)
        expectNotNil(awaiting.window(in: account))
        selection.choose(s.accounts[2]); selection.choose(account)
        expectEqual(selection.windowsByAccount[account.id], "removed-window")
    }
    func testHubFailureAndDuplicateWindows() throws {
        let sources: [[String: Any]] = [["id": "hub", "label": "Work hub", "accounts": [], "error": "private server error"]]
        let s = try SnapshotParser.parse(config: config(), sources: sources)
        expectEqual(s.accounts.last?.unavailable, "Hub snapshot unavailable")
        var raw = limits(); let w = (raw["windows"] as! [[String: Any]])[0]; raw["windows"] = [w,w]
        expectNotNil(try parse(raw).unavailable)
    }
    func testRefreshGateNoOverlapAndFailureCooldown() {
        var gate = RefreshGate()
        expectTrue(gate.begin(now: now)); expectFalse(gate.begin(now: now.addingTimeInterval(301)))
        gate.end()
        expectFalse(gate.begin(now: now.addingTimeInterval(299)))
        expectTrue(gate.begin(now: now.addingTimeInterval(300)))
        expectEqual(gate.secondsRemaining(now: now.addingTimeInterval(301)), 299)
    }
    func testRuntimeRejectsRemoteMalformedAndCredentialURLs() throws {
        func encoded(_ origin: String, host: String = "127.0.0.1", port: Any = 3773) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["origin": origin, "host": host, "port": port])
        }
        let endpoint = try RuntimeEndpoint.decode(encoded("http://127.0.0.1:3773"))
        expectEqual(endpoint.webSocketURL.absoluteString, "ws://127.0.0.1:3773/ws?orchestrationProtocol=2")
        for origin in ["https://127.0.0.1:3773", "http://example.com:3773", "http://127.0.0.1:3774", "http://user:secret@127.0.0.1:3773", "http://127.0.0.1:3773/path", "http://127.0.0.1:3773?token=secret"] {
            expectThrows(try RuntimeEndpoint.decode(encoded(origin)))
        }
        expectThrows(try RuntimeEndpoint.decode(encoded("http://127.0.0.1:3773", port: true)))
        expectThrows(try RuntimeEndpoint.decode(encoded("http://127.0.0.1:3773", port: 3773.5)))
    }
    func testDisabledProvidersHiddenAndSelectionPreserved() throws {
        var c = config(limits: limits())
        let original = try SnapshotParser.parse(config: c, sources: [], now: now)
        var selection = Selection(); selection.initializeIfNeeded(original.accounts)
        let selectedID = selection.accountID
        let originalProvider = (c["providers"] as! [[String: Any]])[0]
        var providers: [[String: Any]] = []
        for (i, enabled) in [false, true, NSNull(), "true", 1].enumerated() {
            var provider = originalProvider
            provider["instanceId"] = i == 0 ? "codex-a" : "instance-\(i)"
            provider["enabled"] = enabled
            providers.append(provider)
        }
        var missing = originalProvider; missing.removeValue(forKey: "enabled"); missing["instanceId"] = "missing"
        providers.append(missing); c["providers"] = providers
        let filtered = try SnapshotParser.parse(config: c, sources: [], now: now)
        expectEqual(filtered.accounts.count, 1)
        selection.initializeIfNeeded(filtered.accounts)
        expectEqual(selection.accountID, selectedID)
        expectNil(selection.account(in: filtered))
        c["providers"] = [originalProvider]
        let restored = try SnapshotParser.parse(config: c, sources: [], now: now)
        expectNotNil(selection.account(in: restored))
    }
    func testManualRefreshBypassesTimerButNeverOverlaps() {
        var gate = RefreshGate()
        expectTrue(gate.begin(now: now))
        expectFalse(gate.begin(now: now, manual: true))
        gate.end()
        expectFalse(gate.begin(now: now.addingTimeInterval(1)))
        expectTrue(gate.begin(now: now.addingTimeInterval(1), manual: true))
        expectFalse(gate.begin(now: now.addingTimeInterval(2), manual: true))
        gate.end()
        expectEqual(gate.secondsRemaining(now: now.addingTimeInterval(2)), 299)
    }
    func testDatesAndLabels() {
        expectNotNil(Dates.parse("2026-10-28T18:00:00.123Z")); expectNil(Dates.parse("not-a-date"))
        expectEqual(cleanLabel("Demo\n\tAccount"), "DemoAccount")
    }
}
