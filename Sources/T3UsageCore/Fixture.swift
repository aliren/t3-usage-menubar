import Foundation

/// Entirely synthetic; fixed clock and identities. Never loaded or persisted in live mode.
public enum Fixture {
    public static let now = Dates.parse("2026-10-28T18:00:00Z")!
    public static func snapshot(_ scenario: String = "current") throws -> UsageSnapshot {
        let checked = scenario == "stale" ? "2026-10-28T16:00:00Z" : "2026-10-28T17:58:00Z"
        var limits: [String: Any] = ["checkedAt": checked, "windows": [
            ["id": "session", "kind": "session", "label": "5 hour", "usedPercent": 37.0,
             "resetsAt": scenario == "reset" ? "2026-10-28T17:59:00Z" : "2026-10-28T20:30:00Z"],
            ["id": "weekly", "kind": "weekly", "label": "Weekly", "usedPercent": 72.0, "resetsAt": "2026-11-01T09:00:00Z"]]]
        if scenario == "failed" { limits["unavailable"] = ["reason": "probeFailed", "message": "Synthetic failure"] }
        if scenario == "unsupported" { limits["unavailable"] = ["reason": "unsupported"]; limits["windows"] = [] }
        let provider: [String: Any] = ["enabled": true, "instanceId": "codex-personal", "driver": "codex", "displayName": "Codex Personal", "auth": ["label": "Demo subscription", "profileId": "demo"], "usageLimits": limits]
        let config: [String: Any] = ["environment": ["environmentId": "fixture-only"], "providers": scenario == "missing" ? [] : [provider,
            ["enabled": true, "instanceId": "claude-work", "driver": "claudeAgent", "displayName": "Claude Work", "auth": ["label": "Demo team"], "usageLimits": ["checkedAt": checked, "windows": [], "unavailable": ["reason": "unsupported"]]]]]
        let sources: [[String: Any]] = [["id": "demo-hub", "label": "Demo Hub", "accounts": [["id": "account-1", "driver": "codex", "email": "demo@example.invalid", "usageLimits": limits]]]]
        return try SnapshotParser.parse(config: config, sources: sources, now: now)
    }
}
