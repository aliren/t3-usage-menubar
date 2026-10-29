import Foundation
import CryptoKit

public enum UsageError: String, Error, LocalizedError {
    case runtimeMissing, unsafeEndpoint, cliMissing, cliFailed, timeout, connection, unauthorized, invalidResponse
    public var errorDescription: String? {
        switch self {
        case .runtimeMissing: return "T3 backend unavailable. Open T3, then refresh."
        case .unsafeEndpoint: return "T3 runtime endpoint is not a valid local loopback address."
        case .cliMissing: return "T3 CLI missing. Open T3 and enable its local CLI."
        case .cliFailed: return "Could not obtain read access through the T3 CLI."
        case .timeout: return "T3 did not respond before the timeout."
        case .connection: return "Connection to the T3 backend failed."
        case .unauthorized: return "T3 rejected the scoped read session."
        case .invalidResponse: return "T3 returned an unsupported or malformed snapshot."
        }
    }
}

public enum Dates {
    public static func parse(_ text: String?) -> Date? {
        guard let text else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = f.date(from: text) { return date }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: text)
    }
    public static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
}
public func opaqueID(_ parts: [String]) -> String {
    let bytes = try! JSONEncoder().encode(parts)
    return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
}
public func cleanLabel(_ text: String) -> String {
    String(text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(180))
}

public struct UsageWindow: Equatable, Sendable {
    public let id: String
    public let kind: String
    public let label: String
    public let usedPercent: Double
    public let resetsAt: Date?
    public let durationMins: Int?
    public var remaining: Int { Int(floor(100 - usedPercent)) }
    public func resetPassed(at now: Date) -> Bool { resetsAt.map { $0 <= now } ?? false }
    public func resetText(at now: Date) -> String {
        guard let reset = resetsAt else { return "Reset time not supplied by T3" }
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
        if reset <= now { return "Reset passed · awaiting new snapshot (\(f.string(from: reset)))" }
        let minutes = max(1, Int(ceil(reset.timeIntervalSince(now) / 60)))
        let days = minutes / 1440, hours = (minutes % 1440) / 60, mins = minutes % 60
        let countdown = days > 0 ? "\(days)d \(hours)h" : hours > 0 ? "\(hours)h \(mins)m" : "\(mins)m"
        return "Resets in \(countdown) · \(f.string(from: reset))"
    }
}

public struct UsageAccount: Equatable, Sendable {
    public let id: String
    public let label: String
    public let driver: String
    public let identity: String
    public let checkedAt: Date?
    public let windows: [UsageWindow]
    public let unavailable: String?
    public func state(for window: UsageWindow?, now: Date, connected: Bool) -> String {
        if let unavailable { return unavailable }
        guard let checkedAt else { return "No quota snapshot" }
        guard let window else { return windows.isEmpty ? "No quota windows supplied" : "Selected window missing" }
        if window.resetPassed(at: now) { return "Reset passed · awaiting T3 update" }
        if checkedAt.timeIntervalSince(now) > 60 { return "Snapshot clock is ahead" }
        if !connected { return "Disconnected · last known snapshot" }
        if now.timeIntervalSince(checkedAt) > 15 * 60 { return "Stale · more than 15 minutes old" }
        return "Current T3 snapshot"
    }
    public func bar(for window: UsageWindow?, now: Date, connected: Bool) -> String {
        guard unavailable == nil, let checkedAt, let window,
              !window.resetPassed(at: now), checkedAt.timeIntervalSince(now) <= 60 else { return "—" }
        let stale = !connected || now.timeIntervalSince(checkedAt) > 15 * 60
        return "\(stale ? "~" : "")\(window.remaining)%"
    }
}
public struct UsageSnapshot: Sendable {
    public let accounts: [UsageAccount]
    public let receivedAt: Date
    public let sourceCount: Int
    public var readSessionRevoked: Bool? = nil
}

/// Extract only quota/account fields. No raw config, credentials, messages or emails enter diagnostics.
public enum SnapshotParser {
    public static func parse(config: [String: Any], sources: [[String: Any]], now: Date = Date()) throws -> UsageSnapshot {
        guard let environment = config["environment"] as? [String: Any],
              let environmentID = environment["environmentId"] as? String ?? environment["id"] as? String,
              !environmentID.isEmpty,
              let providers = config["providers"] as? [[String: Any]] else { throw UsageError.invalidResponse }
        var accounts: [UsageAccount] = []
        for p in providers {
            guard let enabled = p["enabled"] as? NSNumber,
                  CFGetTypeID(enabled) == CFBooleanGetTypeID(), enabled.boolValue else { continue }
            guard let instance = nonempty(p["instanceId"]), let driver = nonempty(p["driver"]) else { continue }
            let auth = p["auth"] as? [String: Any] ?? [:]
            let limits = p["usageLimits"] as? [String: Any]
            let anchor = nonempty(auth["profileId"]) ?? nonempty(auth["email"]) ?? nonempty(limits?["credentialFingerprint"]) ?? nonempty(auth["label"]) ?? "instance"
            let id = opaqueID([environmentID, "provider", instance, anchor, nonempty(auth["workspaceId"]) ?? ""])
            let base = nonempty(p["displayName"]) ?? driver.capitalized
            let accountLabel = nonempty(auth["label"]) ?? nonempty(auth["email"])
            let label = [base, accountLabel].compactMap { $0 }.joined(separator: " · ")
            accounts.append(account(id: id, label: label, driver: driver, identity: "Instance: \(instance)", limits: limits))
        }
        for s in sources {
            guard let source = nonempty(s["id"]), let label = nonempty(s["label"]) else { continue }
            let entries = s["accounts"] as? [[String: Any]] ?? []
            for a in entries {
                guard let accountID = nonempty(a["id"]), let driver = nonempty(a["driver"]) else { continue }
                let id = opaqueID([environmentID, "hub", source, accountID, nonempty(a["workspaceId"]) ?? ""])
                let name = nonempty(a["email"]) ?? "Account \(String(opaqueID([accountID]).prefix(8)))"
                accounts.append(account(id: id, label: "\(label) · \(driver.capitalized) · \(name)", driver: driver,
                    identity: "Hub: \(source) · account \(String(opaqueID([accountID]).prefix(8)))", limits: a["usageLimits"] as? [String: Any],
                    override: s["error"] == nil ? nil : "Hub snapshot unavailable"))
            }
            if entries.isEmpty {
                accounts.append(account(id: opaqueID([environmentID, "hub", source]), label: "\(label) · hub", driver: "hub", identity: "Hub: \(source)", limits: nil,
                    override: s["error"] == nil ? "Hub has no account snapshots" : "Hub snapshot unavailable"))
            }
        }
        guard Set(accounts.map(\.id)).count == accounts.count else { throw UsageError.invalidResponse }
        return UsageSnapshot(accounts: accounts, receivedAt: now, sourceCount: sources.count)
    }
    static func nonempty(_ v: Any?) -> String? {
        guard let s = v as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }
    static func account(id: String, label: String, driver: String, identity: String, limits: [String: Any]?, override: String? = nil) -> UsageAccount {
        var windows: [UsageWindow] = []; var failure = override
        let checked = Dates.parse(limits?["checkedAt"] as? String)
        if let limits {
            if limits["unavailable"] != nil && !(limits["unavailable"] is [String: Any]) { failure = "Malformed T3 quota snapshot" }
            if let u = limits["unavailable"] as? [String: Any] {
                failure = u["reason"] as? String == "unsupported" ? "Quota unsupported by T3" : "T3 quota probe failed"
            }
            if let raw = limits["windows"] as? [[String: Any]], checked != nil {
                for w in raw {
                    guard let wid = nonempty(w["id"]), let kind = nonempty(w["kind"]), ["session", "weekly", "monthly", "other"].contains(kind),
                          let title = nonempty(w["label"]), let used = w["usedPercent"] as? NSNumber,
                          CFGetTypeID(used) != CFBooleanGetTypeID(), used.doubleValue.isFinite,
                          (0...100).contains(used.doubleValue),
                          w["resetsAt"] == nil || Dates.parse(w["resetsAt"] as? String) != nil else {
                        failure = "Malformed T3 quota snapshot"; continue
                    }
                    windows.append(UsageWindow(id: wid, kind: kind, label: cleanLabel(title), usedPercent: used.doubleValue,
                        resetsAt: Dates.parse(w["resetsAt"] as? String), durationMins: w["windowDurationMins"] as? Int))
                }
                if Set(windows.map(\.id)).count != windows.count { windows = []; failure = "Malformed T3 quota snapshot" }
            } else { failure = "Malformed T3 quota snapshot" }
        }
        return UsageAccount(id: id, label: cleanLabel(label), driver: cleanLabel(driver), identity: cleanLabel(identity), checkedAt: checked, windows: windows, unavailable: failure)
    }
}
import CoreFoundation

public struct Selection: Codable, Equatable, Sendable {
    public var accountID: String?
    public var windowsByAccount: [String: String]
    public init(accountID: String? = nil, windowsByAccount: [String: String] = [:]) {
        self.accountID = accountID; self.windowsByAccount = windowsByAccount
    }
    public static func fromStored(_ data: Data?) -> Selection {
        guard let data else { return Selection() }
        return (try? JSONDecoder().decode(Selection.self, from: data)) ?? Selection(accountID: "invalid-saved-selection")
    }
    public mutating func initializeIfNeeded(_ accounts: [UsageAccount]) {
        if let current = accounts.first(where: { $0.id == accountID }) { choose(current); return }
        guard accountID == nil, let first = accounts.first(where: { $0.driver == "codex" && !$0.windows.isEmpty && $0.unavailable == nil }) ?? accounts.first(where: { $0.driver == "codex" }) ?? accounts.first else { return }
        choose(first)
    }
    public mutating func choose(_ account: UsageAccount) {
        accountID = account.id
        if windowsByAccount[account.id] == nil, let w = account.windows.first(where: { $0.kind == "session" }) ?? account.windows.first {
            windowsByAccount[account.id] = w.id
        }
    }
    public func account(in snapshot: UsageSnapshot?) -> UsageAccount? { snapshot?.accounts.first { $0.id == accountID } }
    public func window(in account: UsageAccount) -> UsageWindow? { account.windows.first { $0.id == windowsByAccount[account.id] } }
}

public struct RefreshGate {
    public private(set) var lastAttempt: Date?
    public private(set) var busy = false
    public init() {}
    public mutating func begin(now: Date, manual: Bool = false) -> Bool {
        guard !busy, manual || (lastAttempt.map({ now.timeIntervalSince($0) >= 300 }) ?? true) else { return false }
        lastAttempt = now; busy = true; return true
    }
    public mutating func end() { busy = false }
    public func secondsRemaining(now: Date) -> Int { max(0, Int(ceil(300 - now.timeIntervalSince(lastAttempt ?? .distantPast)))) }
}
