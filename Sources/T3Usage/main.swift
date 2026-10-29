import AppKit
import T3UsageCore

let args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? { guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }; return args[i + 1] }
// Reject incomplete fixture/render arguments before any live access or status item is created.
var consumed = Set<Int>()
for i in args.indices where !consumed.contains(i) {
    if ["--help", "--diagnose", "--dark", "--accounts"].contains(args[i]) { continue }
    if ["--fixture", "--render-fixture"].contains(args[i]), i + 1 < args.count, !args[i + 1].hasPrefix("--") {
        consumed.insert(i + 1); continue
    }
    print("Invalid arguments. Use --help."); exit(2)
}
let fixture = option("--fixture")
if (args.contains("--render-fixture") && (fixture == nil || args.contains("--diagnose"))) || (args.contains("--dark") && fixture == nil) {
    print("Rendering/dark preview requires --fixture and cannot be combined with --diagnose."); exit(2)
}
let validFixtures = ["current", "stale", "failed", "unsupported", "missing", "reset"]
if let fixture, !validFixtures.contains(fixture) { print("Unknown fixture. Use current, stale, failed, unsupported, missing, reset."); exit(2) }

if args.contains("--help") {
    print("T3 Usage: native menu bar companion\n  --diagnose [--fixture current|stale|failed|unsupported|missing|reset]\n  --fixture <scenario>          Synthetic UI, no T3 access or saved preferences\n  --render-fixture <PNG path> --fixture <scenario> [--dark]\nDiagnostics redact labels, emails, credentials and raw config. They never force provider probes.")
    exit(0)
}
if args.contains("--diagnose") {
    Task {
        do {
            let snapshot: UsageSnapshot
            var selection = Selection()
            if let fixture { snapshot = try Fixture.snapshot(fixture) }
            else {
                snapshot = try await LocalT3Client().readSnapshot()
                selection = Selection.fromStored(UserDefaults(suiteName: "local.ali.T3Usage.preferences")?.data(forKey: "selection.v1"))
            }
            selection.initializeIfNeeded(snapshot.accounts)
            if fixture == "missing" { selection.accountID = "missing-fixture-account" }
            let account = selection.account(in: snapshot)
            let now = fixture == nil ? Date() : Fixture.now
            var output: [String: Any] = ["schema": 1, "mode": fixture == nil ? "live" : "fixture", "read": "success", "mechanism": "local CLI scoped session + config WebSocket stream", "forcedProviderProbe": false,
                "accounts": snapshot.accounts.count, "hubSources": snapshot.sourceCount, "selectedAccountPresent": account != nil]
            output["readSessionRevoked"] = snapshot.readSessionRevoked
            if let account {
                let window = selection.window(in: account)
                output["selectedAccountHash"] = String(account.id.prefix(12))
                output["driver"] = ["codex", "claudeAgent", "opencode", "hub"].contains(account.driver) ? account.driver : "other"
                output["windowCount"] = account.windows.count
                output["selectedWindowPresent"] = window != nil
                output["selectedWindowKind"] = window?.kind
                output["remainingPercent"] = window?.remaining
                output["statusBar"] = account.bar(for: window, now: now, connected: true)
                output["state"] = account.state(for: window, now: now, connected: true)
                output["checkedAt"] = account.checkedAt.map(Dates.iso)
                output["resetAt"] = window?.resetsAt.map(Dates.iso)
            }
            if account == nil { output["statusBar"] = "—"; output["state"] = selection.accountID == nil ? "No account snapshots" : "Saved account unavailable" }
            let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self)); exit(0)
        } catch {
            let code = (error as? UsageError)?.rawValue ?? "connection"
            print("{\"read\":\"failed\",\"error\":\"\(code)\",\"credentialsPrinted\":false}"); exit(1)
        }
    }
    dispatchMain()
}
MainActor.assumeIsolated {
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = UsageController(fixture: fixture)
if let render = option("--render-fixture") {
    guard fixture != nil else { print("Rendering requires --fixture; live UI data cannot be exported."); exit(2) }
    app.appearance = NSAppearance(named: args.contains("--dark") ? .darkAqua : .aqua)
    controller.pickingAccount = args.contains("--accounts")
    let view = controller.contentView()
    let window = NSWindow(contentRect: view.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = view; window.backgroundColor = .windowBackgroundColor
    window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
    window.orderBack(nil)
    window.display()
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    view.layoutSubtreeIfNeeded()
    view.display()
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { print("Fixture render failed"); exit(1) }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
    do { try png.write(to: URL(fileURLWithPath: render)); print("Synthetic fixture rendered.") } catch { print("Could not write fixture PNG."); exit(1) }
    window.close(); exit(0)
}
app.delegate = controller
withExtendedLifetime(controller) { app.run() }

}
