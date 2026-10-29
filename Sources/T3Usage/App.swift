import AppKit
import T3UsageCore

@MainActor
final class UsageController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var snapshot: UsageSnapshot?
    var selection = Selection()
    var connected = false
    var errorText: String?
    var gate = RefreshGate()
    var status: NSStatusItem?
    var timer: Timer?
    var task: Task<Void, Never>?
    /// Borderless card under the status item. NSPopover overrode every fade and resize, so we own the window.
    let panel = CardPanel(contentRect: NSRect(x: 0, y: 0, width: 280, height: 200), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    /// The card's one content view; rebuilds replace its subview.
    let host = FlippedView()
    var cardSize = NSSize.zero
    var clickMonitor: Any?
    var lastClose = Date.distantPast
    var shown: Bool { panel.isVisible && !closing }
    // Motion: long enough to read as intentional, short enough not to wait on.
    static let openDuration = 0.3, swapDuration = 0.36, closeDuration = 0.22
    static let settle = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
    static let glide = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)
    var pickingAccount = false
    var closing = false
    let fixture: String?
    let defaults: UserDefaults?
    var now: Date { fixture == nil ? Date() : Fixture.now }
    nonisolated static let contentWidth: CGFloat = 244
    static let lowRemaining = 20
    static let background = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.08, green: 0.08, blue: 0.08, alpha: 1) : .windowBackgroundColor
    }
    static let edge = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.09) : NSColor(white: 0, alpha: 0.1) }
    // Two solid text greys from the approved mock. Translucent label colours render noticeably brighter.
    static let mid = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.604, alpha: 1) : NSColor(white: 0.45, alpha: 1) }
    static let dim = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.39, alpha: 1) : NSColor(white: 0.62, alpha: 1) }
    init(fixture: String? = nil) {
        self.fixture = fixture
        self.defaults = fixture == nil ? UserDefaults(suiteName: "local.ali.T3Usage.preferences") : nil
        super.init()
        selection = Selection.fromStored(defaults?.data(forKey: "selection.v1"))
        if let fixture {
            snapshot = try? Fixture.snapshot(fixture); connected = true
            selection.initializeIfNeeded(snapshot?.accounts ?? [])
            if fixture == "missing" { selection.accountID = "missing-fixture-account" }
        }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status = item
        item.button?.target = self; item.button?.action = #selector(toggleCard)
        item.button?.imagePosition = .imageLeading
        item.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .popUpMenu; panel.animationBehavior = .none; panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false; panel.delegate = self
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        host.wantsLayer = true
        host.layer?.cornerRadius = 14; host.layer?.cornerCurve = .continuous
        host.layer?.masksToBounds = true; host.layer?.borderWidth = 1
        panel.contentView = host
        rebuild()
        // Escape steps back out of the account list, then closes; ⌘Q quits (accessory apps have no menu).
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.shown else { return event }
            if event.keyCode == 53 {
                if self.pickingAccount { self.toggleAccounts() } else { self.closeCard() }
                return nil
            }
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, event.charactersIgnoringModifiers == "q" { NSApp.terminate(nil); return nil }
            return event
        }
        if fixture == nil { refresh() }
        // Opening the app should reveal its controls even when macOS hides the status item.
        showWhenPlaced(attempts: 40)
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // UI freshness advances every 30 seconds; snapshot access is gated to >= 5 minutes.
                self.updateStatus()
                if self.shown { self.rebuild() }
                guard self.fixture == nil else { return }
                // Right after a reset T3 updates within a minute or two; check each minute instead of waiting five.
                let sinceRead = Date().timeIntervalSince(self.gate.lastAttempt ?? .distantPast)
                if self.awaitingReset, sinceRead >= 60 { self.refresh(manual: true) }
                else if self.gate.secondsRemaining(now: Date()) == 0 { self.refresh() }
            }
        }
    }
    /// Ring gauge for the menu bar. Template (adapts to the menu bar) unless low, which draws orange.
    static func ring(_ fraction: Double?, low: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            let center = NSPoint(x: rect.midX, y: rect.midY), radius: CGFloat = 5.5
            let track = NSBezierPath(); track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            track.lineWidth = 1.6
            (low ? NSColor.labelColor : NSColor.black).withAlphaComponent(0.25).setStroke(); track.stroke()
            guard let fraction, fraction > 0 else { return true }
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360 * CGFloat(min(1, fraction)), clockwise: true)
            arc.lineWidth = 1.6; arc.lineCapStyle = .round
            (low ? NSColor.systemOrange : NSColor.black).setStroke(); arc.stroke()
            return true
        }
        image.isTemplate = !low; image.accessibilityDescription = "T3 Usage"
        return image
    }
    /// The selected window's reset time has passed but T3 hasn't sent the new allowance yet.
    var awaitingReset: Bool {
        guard let account = selection.account(in: snapshot), let window = selection.window(in: account) else { return false }
        return window.resetPassed(at: now)
    }
    func persist() {
        if let data = try? JSONEncoder().encode(selection) { defaults?.set(data, forKey: "selection.v1") }
    }
    func updateStatus() {
        let account = selection.account(in: snapshot)
        let window = account.flatMap { selection.window(in: $0) }
        let value = account?.bar(for: window, now: now, connected: connected) ?? "—"
        let available = value != "—"
        let remaining = available ? window?.remaining : nil
        status?.button?.image = Self.ring(remaining.map { Double($0) / 100 }, low: (remaining ?? 100) <= Self.lowRemaining)
        status?.button?.title = " " + value.replacingOccurrences(of: "~", with: "")
        // Last-known values ("~" from the core) are dimmed rather than prefixed.
        status?.button?.appearsDisabled = value.hasPrefix("~") || value == "—"
        let state = account.map { $0.state(for: window, now: now, connected: connected) } ?? "Selected account unavailable"
        status?.button?.toolTip = "T3 Usage · \(value) remaining\n\(account?.label ?? "No selected account")\n\(state)"
        status?.button?.setAccessibilityLabel("T3 Usage, \(value) remaining. \(state)")
    }
    /// Centred under the status item, 6 pt below the menu bar, kept on screen.
    func cardFrame(height: CGFloat) -> NSRect {
        let width = Self.contentWidth + 36
        guard let anchor = status?.button?.window?.frame else { return NSRect(x: 0, y: 0, width: width, height: height) }
        let screen = status?.button?.window?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? anchor
        let x = min(max(anchor.midX - width / 2, screen.minX + 8), screen.maxX - width - 8)
        return NSRect(x: x.rounded(), y: anchor.minY - 6 - height, width: width, height: height)
    }
    @objc func toggleCard() {
        if shown { closeCard() }
        // A click on the status item also resigns the card's key status; don't reopen what that just closed.
        else if Date().timeIntervalSince(lastClose) > 0.3 { openCard() }
    }
    func openCard() {
        guard !shown, status?.button?.window != nil else { return }
        pickingAccount = false; rebuild()
        // Opening the card is a request to look, so bring anything older than 30 s up to date.
        if fixture == nil, Date().timeIntervalSince(gate.lastAttempt ?? .distantPast) > 30 { refresh(manual: true) }
        // Fade in while settling 8 pt down into place.
        let final = cardFrame(height: cardSize.height)
        panel.setFrame(final.offsetBy(dx: 0, dy: 8), display: false)
        panel.alphaValue = 0
        // An accessory app may focus its card without creating a Dock icon.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.openDuration; context.timingFunction = Self.settle
            panel.animator().alphaValue = 1
            panel.animator().setFrame(final, display: true)
        }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.closeCard() }
        }
    }
    func closeCard() {
        guard shown else { return }
        closing = true; lastClose = Date()
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor); self.clickMonitor = nil }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.closeDuration; context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            panel.animator().setFrame(panel.frame.offsetBy(dx: 0, dy: 6), display: true)
        }, completionHandler: {
            MainActor.assumeIsolated {
                self.panel.orderOut(nil); self.closing = false; self.pickingAccount = false
            }
        })
    }
    func windowDidResignKey(_ notification: Notification) { closeCard() }
    /// The status item has no on-screen frame for a moment after launch, so the card has nothing to sit under.
    func showWhenPlaced(attempts: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            // Also wait for the first read, so the card opens with numbers instead of a placeholder.
            let placed = (self.status?.button?.window?.frame.height ?? 0) > 0
            let ready = self.snapshot != nil || (self.fixture == nil && !self.gate.busy)
            if (placed && ready) || attempts <= 0 { self.openCard() }
            else { self.showWhenPlaced(attempts: attempts - 1) }
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openCard()
        return true
    }
    /// Swap the card's content in place. `animated` crossfades and glides the height, for changes the user caused.
    func rebuild(animated: Bool = false) {
        updateStatus()
        let content = contentView(), size = content.frame.size
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
            host.layer?.backgroundColor = Self.background.cgColor; host.layer?.borderColor = Self.edge.cgColor
        }
        // Real views pinned to the top, not a layer transition: a transition's snapshot slides when the card grows.
        // The old content leaves quickly, the new arrives just after, so the two never read as one muddle.
        if animated, shown, let old = host.subviews.last {
            content.alphaValue = 0; host.addSubview(content)
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.16; context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                old.animator().alphaValue = 0
            }, completionHandler: { MainActor.assumeIsolated { old.removeFromSuperview() } })
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.28; context.timingFunction = Self.settle
                    content.animator().alphaValue = 1
                }
            }
        } else { host.subviews = [content] }
        let resized = size != cardSize
        cardSize = size
        guard shown, resized else { return }
        // The top edge stays put; content is top-anchored, so growing reveals and shrinking tucks away.
        let target = cardFrame(height: size.height)
        guard animated else { panel.setFrame(target, display: true); panel.invalidateShadow(); return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.swapDuration; context.timingFunction = Self.glide
            panel.animator().setFrame(target, display: true)
        }, completionHandler: {
            MainActor.assumeIsolated { self.panel.invalidateShadow() }
        })
    }
    func text(_ value: String, size: CGFloat = 12, weight: NSFont.Weight = .regular,
              color: NSColor = .labelColor, width: CGFloat? = UsageController.contentWidth) -> NSTextField {
        let label = width == nil ? NSTextField(labelWithString: value) : NSTextField(wrappingLabelWithString: value)
        label.font = .monospacedDigitSystemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.setContentHuggingPriority(.required, for: .vertical)
        if let width { label.widthAnchor.constraint(equalToConstant: width).isActive = true }
        return label
    }
    func separator() -> NSBox {
        let box = NSBox(); box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        return box
    }
    func row(_ leading: NSView, _ trailing: NSView, alignment: NSLayoutConstraint.Attribute = .firstBaseline) -> NSStackView {
        let row = NSStackView(); row.orientation = .horizontal; row.alignment = alignment; row.spacing = 8
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        leading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        trailing.setContentCompressionResistancePriority(.required, for: .horizontal)
        row.addArrangedSubview(leading); row.addArrangedSubview(spacer); row.addArrangedSubview(trailing)
        row.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        return row
    }
    /// "resets 1h 37m" for the hero row, "resets in 4d 15h" below secondary bars.
    func resetCaption(_ window: UsageWindow, compact: Bool = false) -> String {
        if window.resetPassed(at: now) { return "awaiting update" }
        guard window.resetsAt != nil else { return compact ? "" : "reset time unknown" }
        let countdown = String(window.resetText(at: now).components(separatedBy: " · ").first ?? "")
            .replacingOccurrences(of: "Resets in ", with: "")
        return (compact ? "resets " : "resets in ") + countdown
    }
    /// Account labels arrive as "Provider · account"; the trailing plan word adds nothing here.
    func displayLabel(_ label: String) -> String {
        label.hasSuffix(" Subscription") ? String(label.dropLast(" Subscription".count)) : label
    }
    func accountButton(_ selected: UsageAccount?) -> NSButton {
        let title = NSMutableAttributedString()
        if pickingAccount {
            title.append(NSAttributedString(string: "Accounts", attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: Self.mid]))
        } else if let selected {
            let parts = displayLabel(selected.label).components(separatedBy: " · ")
            title.append(NSAttributedString(string: parts[0], attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.labelColor]))
            if parts.count > 1 {
                title.append(NSAttributedString(string: " · " + parts.dropFirst().joined(separator: " · "),
                    attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: Self.mid]))
            }
        } else {
            title.append(NSAttributedString(string: selection.accountID == nil ? "Choose account" : "Account unavailable",
                attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: Self.mid]))
        }
        let button = NSButton(title: "", target: self, action: #selector(toggleAccounts))
        button.isBordered = false; button.attributedTitle = title
        button.image = NSImage(systemSymbolName: pickingAccount ? "chevron.up" : "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .semibold))
        button.imagePosition = .imageTrailing; button.imageHugsTitle = true
        button.contentTintColor = .tertiaryLabelColor
        button.cell?.lineBreakMode = .byTruncatingTail
        button.widthAnchor.constraint(lessThanOrEqualToConstant: Self.contentWidth).isActive = true
        button.toolTip = selected?.label
        button.setAccessibilityLabel(pickingAccount ? "Close account list" : "Choose account")
        return button
    }
    @objc func toggleAccounts() { pickingAccount.toggle(); rebuild(animated: true) }
    /// The window an account would show if picked: its saved one, else session, else the first.
    func previewWindow(_ account: UsageAccount) -> UsageWindow? {
        account.windows.first { $0.id == selection.windowsByAccount[account.id] }
            ?? account.windows.first { $0.kind == "session" } ?? account.windows.first
    }
    /// A full-width hover row. Its highlight overhangs the text column by `HoverRow.inset` on each side.
    func listRow(_ title: NSAttributedString, detail: String, accessibility: String, action: @escaping () -> Void) -> NSView {
        // Attributed text ignores the field's line break mode, so truncation lives in the paragraph style.
        let styled = NSMutableAttributedString(attributedString: title), paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        styled.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: styled.length))
        let name = NSTextField(labelWithAttributedString: styled)
        name.maximumNumberOfLines = 1; name.usesSingleLineMode = true; name.lineBreakMode = .byTruncatingTail
        let value = text(detail, size: 12, color: Self.dim, width: nil)
        let line = row(name, value, alignment: .centerY)
        let hover = HoverRow(action: action); hover.setAccessibilityLabel(accessibility)
        line.translatesAutoresizingMaskIntoConstraints = false; hover.addSubview(line)
        NSLayoutConstraint.activate([line.centerYAnchor.constraint(equalTo: hover.centerYAnchor),
                                     line.leadingAnchor.constraint(equalTo: hover.leadingAnchor, constant: HoverRow.inset)])
        let slot = NSView(); slot.translatesAutoresizingMaskIntoConstraints = false
        hover.translatesAutoresizingMaskIntoConstraints = false; slot.addSubview(hover)
        NSLayoutConstraint.activate([slot.widthAnchor.constraint(equalToConstant: Self.contentWidth), slot.heightAnchor.constraint(equalToConstant: 30),
            hover.topAnchor.constraint(equalTo: slot.topAnchor), hover.bottomAnchor.constraint(equalTo: slot.bottomAnchor),
            hover.leadingAnchor.constraint(equalTo: slot.leadingAnchor, constant: -HoverRow.inset),
            hover.trailingAnchor.constraint(equalTo: slot.trailingAnchor, constant: HoverRow.inset)])
        return slot
    }
    func accountList(_ add: (NSView, CGFloat) -> Void) {
        let accounts = snapshot?.accounts ?? []
        // Keep account identities out of the normal UI; disambiguate only duplicate names.
        let names = Dictionary(grouping: accounts, by: \.label)
        for (index, account) in accounts.enumerated() {
            let current = account.id == selection.accountID
            let parts = displayLabel(account.label).components(separatedBy: " · ")
            let title = NSMutableAttributedString(string: parts[0], attributes: [.font: NSFont.systemFont(ofSize: 12, weight: current ? .medium : .regular),
                .foregroundColor: current ? NSColor.labelColor : Self.mid])
            if parts.count > 1 {
                title.append(NSAttributedString(string: " · " + parts.dropFirst().joined(separator: " · "), attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: Self.dim]))
            }
            if (names[account.label]?.count ?? 0) > 1 {
                title.append(NSAttributedString(string: " \(account.id.prefix(4))", attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: Self.dim]))
            }
            let value = account.bar(for: previewWindow(account), now: now, connected: connected).replacingOccurrences(of: "~", with: "")
            let id = account.id
            add(listRow(title, detail: value, accessibility: "\(account.label), \(value) remaining") { [weak self] in self?.accountPicked(id) }, index == 0 ? 10 : 0)
        }
        if accounts.isEmpty { add(text(gate.busy ? "Connecting to T3…" : "No accounts available", color: Self.mid), 12) }
        add(separator(), 10)
        let quit = NSAttributedString(string: "Quit T3 Usage", attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: Self.mid])
        add(listRow(quit, detail: "⌘Q", accessibility: "Quit T3 Usage") { NSApp.terminate(nil) }, 6)
    }
    func refreshControl() -> NSView {
        if gate.busy {
            let spinner = NSProgressIndicator(); spinner.style = .spinning; spinner.controlSize = .small
            spinner.widthAnchor.constraint(equalToConstant: 14).isActive = true
            spinner.heightAnchor.constraint(equalToConstant: 14).isActive = true
            spinner.toolTip = "Refreshing…"; spinner.startAnimation(nil)
            return spinner
        }
        let image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh usage")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
        let button = NSButton(image: image ?? NSImage(), target: self, action: #selector(refreshClicked))
        button.isBordered = false; button.contentTintColor = Self.mid
        button.widthAnchor.constraint(equalToConstant: 22).isActive = true
        button.heightAnchor.constraint(equalToConstant: 22).isActive = true
        button.isEnabled = fixture == nil
        button.toolTip = "Refresh from T3"
        button.setAccessibilityLabel("Refresh usage")
        return button
    }
    /// Hero title and one-line detail for every state where there is no trustworthy number.
    func blankState(_ account: UsageAccount, window: UsageWindow?) -> (title: String, detail: String) {
        if let window, window.resetPassed(at: now), account.unavailable == nil {
            let minutes = window.resetsAt.map { max(0, Int(now.timeIntervalSince($0) / 60)) } ?? 0
            let name = window.kind == "session" ? "Session" : window.label
            return ("Reset", "\(name) reset \(ago(minutes)) · waiting for T3")
        }
        switch account.state(for: window, now: now, connected: connected) {
        case "Quota unsupported by T3": return ("Not tracked", "T3 doesn't report quota for this account")
        case "T3 quota probe failed": return ("Unavailable", "T3 couldn't read this quota")
        case let state: return ("Unavailable", state)
        }
    }
    func ago(_ minutes: Int) -> String {
        minutes == 0 ? "just now" : minutes < 60 ? "\(minutes)m ago" : minutes < 1440 ? "\(minutes / 60)h ago" : "\(minutes / 1440)d ago"
    }
    /// One status line for the footer; `calm` is false whenever the number should not be trusted as current.
    func footerStatus(_ account: UsageAccount, window: UsageWindow?) -> (text: String, calm: Bool) {
        let state = account.state(for: window, now: now, connected: connected)
        let age = account.checkedAt.map { max(0, Int(now.timeIntervalSince($0) / 60)) }
        var status: (String, Bool)
        switch state {
        case "Current T3 snapshot": status = (age.map { "Updated " + ago($0) } ?? "Usage unavailable", true)
        case _ where state.hasPrefix("Stale"): status = (age.map { "Updated " + ago($0) } ?? state, false)
        case _ where state.hasPrefix("Disconnected"): status = ("Offline · last known", false)
        // Other states already appear under the hero number; the footer just dates the snapshot.
        // A permanent "not tracked" is not a warning; everything else here is.
        default: status = (age.map { "Updated " + ago($0) } ?? state, state == "Quota unsupported by T3")
        }
        if errorText != nil, connected, status.1 { status = ("Connection needs attention", false) }
        return (fixture != nil ? "Preview · " + status.0 : status.0, status.1)
    }
    func footer(_ status: (text: String, calm: Bool), tooltip: String?) -> NSStackView {
        let label = text(status.text, size: 11, color: Self.dim, width: nil)
        label.lineBreakMode = .byTruncatingTail; label.toolTip = tooltip
        let left = NSStackView(views: [Dot(status.calm ? .tertiaryLabelColor : .systemOrange), label])
        left.orientation = .horizontal; left.alignment = .centerY; left.spacing = 6
        return row(left, refreshControl(), alignment: .centerY)
    }
    func contentView() -> NSView {
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 18, bottom: 10, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        func add(_ view: NSView, gap: CGFloat) {
            if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(gap, after: last) }
            stack.addArrangedSubview(view)
        }
        let selected = selection.account(in: snapshot)
        add(accountButton(selected), gap: 0)
        if pickingAccount {
            accountList(add)
        } else if let selected {
            let window = selection.window(in: selected)
            let value = selected.bar(for: window, now: now, connected: connected)
            let available = value != "—"
            // No number to show: say what is going on in the hero itself rather than leaving a lone dash.
            let blank = blankState(selected, window: window)
            let number = NSTextField(labelWithAttributedString: NSAttributedString(
                string: available ? value.trimmingCharacters(in: CharacterSet(charactersIn: "~%")) : blank.title,
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: available ? 46 : 28, weight: .light),
                             .kern: available ? -1.6 : -0.4, .foregroundColor: NSColor.labelColor]))
            let hero = NSStackView(views: [number])
            if available { hero.addArrangedSubview(text("%", size: 20, weight: .light, color: Self.mid, width: nil)) }
            hero.orientation = .horizontal; hero.alignment = .firstBaseline; hero.spacing = 1
            add(hero, gap: 14)
            if let window, available {
                let what = window.kind == "session" ? "left this session" : "left · \(window.label)"
                let reset = text(resetCaption(window, compact: true), size: 12, color: Self.dim, width: nil)
                reset.toolTip = window.resetText(at: now)
                add(row(text(what, size: 12, color: Self.mid, width: nil), reset), gap: 6)
                add(Meter(Double(window.remaining) / 100, tint: window.remaining <= Self.lowRemaining ? .systemOrange : .labelColor), gap: 10)
            } else {
                add(text(blank.detail, size: 12, color: Self.mid), gap: 8)
                if blank.title == "Reset" { add(Meter(nil, tint: .labelColor), gap: 10) }
            }
            for other in selected.windows where other.id != window?.id {
                let quota = selected.bar(for: other, now: now, connected: connected)
                let remaining = quota == "—" ? nil : other.remaining
                add(row(text(other.label, size: 12, color: Self.mid, width: nil),
                        text(quota.replacingOccurrences(of: "~", with: ""), size: 12, width: nil)), gap: 20)
                add(Meter(remaining.map { Double($0) / 100 }, tint: (remaining ?? 100) <= Self.lowRemaining
                    ? .systemOrange : NSColor.labelColor.withAlphaComponent(0.55)), gap: 8)
                let reset = text(resetCaption(other), size: 11, color: Self.dim)
                reset.toolTip = other.resetText(at: now)
                add(reset, gap: 7)
            }
            add(separator(), gap: 16)
            let tooltip = [selected.checkedAt.map { "Quota checked: " + dateText($0) }, errorText].compactMap { $0 }.joined(separator: "\n")
            add(footer(footerStatus(selected, window: window), tooltip: tooltip), gap: 8)
        } else {
            add(text("—", size: 46, weight: .light), gap: 14)
            add(text(gate.busy ? "Connecting to T3…" : "Choose an available account above.", color: Self.mid), gap: 6)
            add(separator(), gap: 16)
            add(footer((errorText ?? (fixture != nil ? "Preview" : "No account selected"), errorText == nil), tooltip: errorText), gap: 8)
        }
        let fitting = stack.fittingSize
        let width = Self.contentWidth + 36, height = min(520, max(120, fitting.height))
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        root.wantsLayer = true
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance { root.layer?.backgroundColor = Self.background.cgColor }
        let scroll = NSScrollView(frame: root.bounds); scroll.autoresizingMask = [.width, .height]
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let document = FlippedView(frame: NSRect(x: 0, y: 0, width: width, height: fitting.height))
        document.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: document.leadingAnchor), stack.topAnchor.constraint(equalTo: document.topAnchor), stack.widthAnchor.constraint(equalToConstant: width)])
        scroll.documentView = document; root.addSubview(scroll); root.layoutSubtreeIfNeeded()
        return root
    }
    func dateText(_ date: Date) -> String { let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .medium; return f.string(from: date) }
    func accountPicked(_ id: String) {
        guard let account = snapshot?.accounts.first(where: { $0.id == id }) else { return }
        selection.choose(account); persist(); pickingAccount = false; rebuild(animated: true)
    }
    @objc func refreshClicked() { refresh(manual: true) }
    func refresh(manual: Bool = false) {
        guard fixture == nil, gate.begin(now: Date(), manual: manual) else { return }
        rebuild()
        task = Task {
            do {
                let value = try await LocalT3Client().readSnapshot()
                snapshot = value; connected = true
                errorText = value.readSessionRevoked == false ? "Read session revocation failed; its access expires within 5 minutes." : nil
                selection.initializeIfNeeded(value.accounts); persist()
            } catch {
                connected = false
                errorText = (error as? UsageError)?.localizedDescription ?? UsageError.connection.localizedDescription
            }
            gate.end(); rebuild(animated: shown); task = nil
        }
    }
    func applicationWillTerminate(_ notification: Notification) { timer?.invalidate(); task?.cancel() }
}
@MainActor final class FlippedView: NSView { override var isFlipped: Bool { true } }
/// Borderless panels refuse key status by default; the card needs it for Esc and ⌘Q.
final class CardPanel: NSPanel { override var canBecomeKey: Bool { true } }
/// 3 pt rounded track with a filled share; `nil` draws the track only.
@MainActor final class Meter: NSView {
    let fraction: Double?, tint: NSColor
    init(_ fraction: Double?, tint: NSColor) {
        self.fraction = fraction; self.tint = tint
        super.init(frame: .zero)
        heightAnchor.constraint(equalToConstant: 3).isActive = true
        widthAnchor.constraint(equalToConstant: UsageController.contentWidth).isActive = true
    }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        NSColor.labelColor.withAlphaComponent(0.1).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        guard let fraction, fraction > 0 else { return }
        var fill = bounds; fill.size.width = max(bounds.height, bounds.width * min(1, fraction))
        tint.setFill(); NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
    }
}
@MainActor final class Dot: NSView {
    let color: NSColor
    init(_ color: NSColor) {
        self.color = color
        super.init(frame: .zero)
        widthAnchor.constraint(equalToConstant: 5).isActive = true
        heightAnchor.constraint(equalToConstant: 5).isActive = true
    }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) { color.setFill(); NSBezierPath(ovalIn: bounds).fill() }
}
/// Clickable list row with a soft rounded hover highlight. Owns all clicks inside it.
@MainActor final class HoverRow: NSView {
    static let inset: CGFloat = 8
    let action: () -> Void
    var hovered = false { didSet { needsDisplay = true } }
    init(action: @escaping () -> Void) { self.action = action; super.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
    }
    override func draw(_ dirtyRect: NSRect) {
        guard hovered else { return }
        NSColor.labelColor.withAlphaComponent(0.07).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }
}
