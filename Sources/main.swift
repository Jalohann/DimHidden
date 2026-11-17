import AppKit
import ApplicationServices
import ServiceManagement

private let dockBundleID = "com.apple.dock"
private let defaults = UserDefaults.standard
private let dimmingStrengths: [(title: String, icon: Double, dot: Double)] = [
    ("Light", 0.4, 0.55),
    ("Medium", 0.55, 0.7),
    ("Strong", 0.7, 0.85),
]

// MARK: - Reading the Dock

struct DockTile {
    let element: AXUIElement
    let path: String
    var frame: CGRect  // Accessibility coordinates: origin at the top-left of the primary screen
    var badge: String?
}

enum DockAX {
    static func list() -> AXUIElement? {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: dockBundleID).first else {
            return nil
        }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        let children: [AXUIElement]? = copy(app, kAXChildrenAttribute)
        return children?.first { (copy($0, kAXRoleAttribute) as String?) == kAXListRole }
    }

    static func appTiles(in list: AXUIElement) -> [DockTile] {
        guard let items: [AXUIElement] = copy(list, kAXChildrenAttribute) else { return [] }
        return items.compactMap { item in
            guard (copy(item, kAXSubroleAttribute) as String?) == "AXApplicationDockItem",
                  let url: URL = copy(item, kAXURLAttribute),
                  let frame = frame(of: item)
            else { return nil }
            return DockTile(element: item, path: normalize(url), frame: frame, badge: badge(of: item))
        }
    }

    static func frame(of element: AXUIElement) -> CGRect? {
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard let p = axValue(element, kAXPositionAttribute), AXValueGetValue(p, .cgPoint, &origin),
              let s = axValue(element, kAXSizeAttribute), AXValueGetValue(s, .cgSize, &size)
        else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// The notification badge text, e.g. "3". Nil when the tile has no badge.
    static func badge(of element: AXUIElement) -> String? {
        let label: String? = copy(element, "AXStatusLabel")
        return label?.isEmpty == false ? label : nil
    }

    static func normalize(_ url: URL) -> String {
        var path = url.resolvingSymlinksInPath().path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }

    private static func copy<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    private static func axValue(_ element: AXUIElement, _ name: String) -> AXValue? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        return (value as! AXValue)
    }
}

// MARK: - Error log

private let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
private let osVersion = ProcessInfo.processInfo.operatingSystemVersionString

/// Problems worth fixing go to ~/Library/Logs/DimHidden/errors.log as JSON lines. The updater turns new entries into
/// GitHub issues, and Report a Problem includes the latest ones. Never put app names or other personal details here:
/// entries can end up in public issues.
@MainActor
enum ErrorLog {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/DimHidden/errors.log")
    private static let maxSize = 256_000
    private static var recorded = Set<String>()

    /// Appends an entry, at most once per launch for each kind and message.
    static func record(_ kind: String, _ message: String) {
        guard recorded.insert(kind + "\u{0}" + message).inserted else { return }
        let entry = ["time": ISO8601DateFormatter().string(from: Date()), "kind": kind, "message": message,
                     "version": appVersion, "macOS": osVersion]
        guard var line = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        line.append(0x0A)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = (try? Data(contentsOf: url)) ?? Data()
        data.append(line)
        if data.count > maxSize { data = data.suffix(maxSize / 2) }  // may cut the oldest kept line; readers skip it
        try? data.write(to: url, options: .atomic)
    }

    static func recent(_ count: Int) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return Array(text.split(separator: "\n").suffix(count).map(String.init))
    }
}

// MARK: - Geometry
enum DockEdge: String {
    case bottom, left, right

    static var current: DockEdge {
        DockEdge(rawValue: UserDefaults(suiteName: dockBundleID)?.string(forKey: "orientation") ?? "") ?? .bottom
    }
}

/// Where to draw the veil for one Dock tile, in Accessibility coordinates.
///
/// Measured on macOS 27 at 32pt icons, from rest size up to full magnification:
/// - A tile is the icon plus 1pt on each side, plus a 12pt strip on the screen-edge side for the dot.
/// - The icon artwork is 81% of the icon size, centered in the tile. With the Dock on the right, the artwork
///   and dot are drawn 2.5pt closer to the screen edge than the tile suggests.
/// - The dot (~4pt) sits 5.75pt from the screen-edge side of the tile (6.25pt on side Docks).
/// - The badge does not scale exactly with the artwork (A): its diameter is 0.474A + 0.67pt, and its center is
///   0.3585A + 0.68pt right of and 0.385A above the artwork's center. Two-character labels still fit the circle
///   ("22" and "26" measured 13pt wide, the same as "1"); longer labels widen it to the left.
struct VeilGeometry {
    let icon: CGRect
    let dot: CGRect
    let badge: CGRect?

    init(tile: CGRect, edge: DockEdge, badge label: String?) {
        let iconSize = min(tile.width, tile.height) - 2
        let art = iconSize * 0.81
        let shift: CGFloat = edge == .right ? 2.5 : 0
        let center = CGPoint(x: tile.midX + shift, y: tile.midY)
        let side = art + 2  // 1pt overlap on each side hides the artwork's anti-aliased edge
        icon = CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)

        // The dot veil is a little larger than the ~4pt dot to absorb sub-point rounding; over the Dock's
        // background the extra area is invisible.
        let dotCenter: CGPoint
        switch edge {
        case .bottom: dotCenter = CGPoint(x: tile.midX, y: tile.maxY - 5.75)
        case .left: dotCenter = CGPoint(x: tile.minX + 6.25, y: tile.midY - 0.5)
        case .right: dotCenter = CGPoint(x: tile.maxX - 6.25 + shift, y: tile.midY - 0.5)
        }
        let dotSize: CGFloat = 7
        dot = CGRect(x: dotCenter.x - dotSize / 2, y: dotCenter.y - dotSize / 2, width: dotSize, height: dotSize)

        if let label = label {
            let d = art * 0.474 + 0.67
            let badgeCenter = CGPoint(x: center.x + art * 0.3585 + 0.68, y: center.y - art * 0.385)
            let width = d * (0.55 + 0.45 * CGFloat(min(max(label.count - 1, 1), 4)))
            // Slightly smaller than the badge: a faintly dimmed badge rim is less visible than a bright ring of
            // undimmed icon around it.
            let inset = CGFloat(defaults.object(forKey: "badgeInset") as? Double ?? 0.5)
            badge = CGRect(x: badgeCenter.x + d / 2 - width, y: badgeCenter.y - d / 2, width: width, height: d)
                .insetBy(dx: inset, dy: inset)
        } else {
            badge = nil
        }
    }
}

// MARK: - Wallpaper

/// In Light Mode the Dock's glass shows the wallpaper behind it, lightened. Measured on macOS 27.2 over a dark blue
/// wallpaper, the glass between icons matched the wallpaper under it blended with about 12% white (within ~10/255 per
/// channel; blue came out a little higher). A light-mode veil therefore takes that color; a fixed light gray showed
/// up as pale squares and gray discs on dark wallpapers.
@MainActor
final class Wallpaper {
    private struct Snapshot {
        let url: URL
        let options: NSDictionary
        let frame: CGRect  // the screen, in the Accessibility API's top-left coordinates
        let width: Int
        let height: Int
        let pixels: [UInt8]  // sRGB, RGBA, top row first
    }

    /// Pixels per point. The veil averages the wallpaper under a whole icon, so a coarse copy is enough.
    private let scale: CGFloat = 0.25
    private let glassWhite: CGFloat = 0.12
    private var snapshots: [Snapshot] = []

    /// Re-renders the wallpaper of any screen whose picture, placement, or frame changed.
    func reload() {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        snapshots = NSScreen.screens.compactMap { screen in
            guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
            let options = (NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]) as NSDictionary
            let frame = CGRect(x: screen.frame.minX, y: primaryHeight - screen.frame.maxY,
                               width: screen.frame.width, height: screen.frame.height)
            if let old = snapshots.first(where: { $0.url == url && $0.options == options && $0.frame == frame }) {
                return old
            }
            return render(url: url, options: options, frame: frame, backingScale: screen.backingScaleFactor)
        }
    }

    /// The Dock glass color over `rect`, in top-left screen coordinates.
    func glassColor(under rect: CGRect) -> NSColor? {
        guard let s = snapshots.first(where: { $0.frame.contains(CGPoint(x: rect.midX, y: rect.midY)) }) else { return nil }
        func clamp(_ v: CGFloat, _ upper: Int) -> Int { min(max(Int(v), 0), upper) }
        let x0 = clamp((rect.minX - s.frame.minX) * scale, s.width - 1)
        let x1 = clamp(((rect.maxX - s.frame.minX) * scale).rounded(.up), s.width)
        let y0 = clamp((rect.minY - s.frame.minY) * scale, s.height - 1)
        let y1 = clamp(((rect.maxY - s.frame.minY) * scale).rounded(.up), s.height)
        var sum = (0, 0, 0), count = 0
        for y in y0..<max(y1, y0 + 1) {
            for x in x0..<max(x1, x0 + 1) {
                let i = (y * s.width + x) * 4
                sum.0 += Int(s.pixels[i]); sum.1 += Int(s.pixels[i + 1]); sum.2 += Int(s.pixels[i + 2])
                count += 1
            }
        }
        let n = CGFloat(count * 255)
        func glass(_ channel: Int) -> CGFloat { CGFloat(channel) / n * (1 - glassWhite) + glassWhite }
        return NSColor(srgbRed: glass(sum.0), green: glass(sum.1), blue: glass(sum.2), alpha: 1)
    }

    private func render(url: URL, options: NSDictionary, frame: CGRect, backingScale: CGFloat) -> Snapshot? {
        let width = max(Int(frame.width * scale), 1), height = max(Int(frame.height * scale), 1)
        // Decoding a full-size wallpaper took 21 s and 550 MB on a 6016 px HEIC; a decoder-side thumbnail takes
        // about 0.15 s. Twice the canvas size leaves room for a wallpaper that is cropped to fill the screen.
        let thumbnailOptions: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                 kCGImageSourceCreateThumbnailWithTransform: true,
                                                 kCGImageSourceThumbnailMaxPixelSize: 2 * max(width, height)]
        // Some moving wallpapers have no still image to read; their veils keep the fixed color.
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, CGImageSourceGetPrimaryImageIndex(source),
                                                              thumbnailOptions as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, CGImageSourceGetPrimaryImageIndex(source), nil)
                as? [CFString: Any],
              let pixelWidth = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let pixelHeight = properties[kCGImagePropertyPixelHeight] as? CGFloat, pixelWidth > 0, pixelHeight > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let fullSize = CGSize(width: pixelWidth / backingScale, height: pixelHeight / backingScale)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let cg = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                     bytesPerRow: width * 4, space: space,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            let canvas = CGSize(width: width, height: height)
            cg.setFillColor((options[NSWorkspace.DesktopImageOptionKey.fillColor] as? NSColor ?? .black).cgColor)
            cg.fill(CGRect(origin: .zero, size: canvas))
            cg.interpolationQuality = .medium
            cg.draw(image, in: placement(of: fullSize, in: canvas, options: options))
            return true
        }
        guard drawn else { return nil }
        return Snapshot(url: url, options: options, frame: frame, width: width, height: height, pixels: pixels)
    }

    /// Where the Desktop draws the picture, following the screen's "Fill Screen", "Fit to Screen", "Stretch to Fill
    /// Screen", and "Center" choices.
    private func placement(of image: CGSize, in canvas: CGSize, options: NSDictionary) -> CGRect {
        let raw = (options[NSWorkspace.DesktopImageOptionKey.imageScaling] as? NSNumber)?.uintValue
        let scaling = raw.flatMap(NSImageScaling.init(rawValue:)) ?? .scaleProportionallyUpOrDown
        let clips = (options[NSWorkspace.DesktopImageOptionKey.allowClipping] as? NSNumber)?.boolValue ?? true
        let fit = min(canvas.width / image.width, canvas.height / image.height)
        let fill = max(canvas.width / image.width, canvas.height / image.height)
        let factor: CGFloat
        switch scaling {
        case .scaleAxesIndependently: return CGRect(origin: .zero, size: canvas)
        case .scaleNone: factor = scale
        case .scaleProportionallyDown: factor = min(fit, scale)
        default: factor = clips ? fill : fit
        }
        let size = CGSize(width: image.width * factor, height: image.height * factor)
        return CGRect(x: (canvas.width - size.width) / 2, y: (canvas.height - size.height) / 2,
                      width: size.width, height: size.height)
    }
}

// MARK: - Veil window

final class VeilWindow: NSWindow {
    private let iconLayer = CALayer()
    private let dotLayer = CALayer()
    private let badgeMask = CAShapeLayer()
    private var lastGeometry: (CGRect, CGRect, CGRect?)?

    init() {
        super.init(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        // One level above the Dock's icons. No .fullScreenAuxiliary, so the veil stays off full-screen spaces,
        // where the Dock is hidden.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        let view = NSView()
        view.wantsLayer = true
        iconLayer.cornerCurve = .continuous
        badgeMask.fillRule = .evenOdd
        view.layer?.addSublayer(iconLayer)
        view.layer?.addSublayer(dotLayer)
        contentView = view
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func apply(_ g: VeilGeometry, primaryHeight: CGFloat, iconColor: NSColor, dotColor: NSColor) {
        let union = g.icon.union(g.dot)
        let frame = CGRect(x: union.minX, y: primaryHeight - union.maxY, width: union.width, height: union.height)
        func local(_ r: CGRect) -> CGRect {
            CGRect(x: r.minX - union.minX, y: union.maxY - r.maxY, width: r.width, height: r.height)
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if self.frame != frame { setFrame(frame, display: false) }
        iconLayer.backgroundColor = iconColor.cgColor
        dotLayer.backgroundColor = dotColor.cgColor
        if lastGeometry == nil || lastGeometry! != (g.icon, g.dot, g.badge) {
            lastGeometry = (g.icon, g.dot, g.badge)
            let iconFrame = local(g.icon)
            iconLayer.frame = iconFrame
            iconLayer.cornerRadius = iconFrame.width * 0.225
            dotLayer.frame = local(g.dot)
            dotLayer.cornerRadius = g.dot.width / 2
            if let badge = g.badge {
                // Punch the badge out of the veil so it stays fully visible.
                let b = local(badge).offsetBy(dx: -iconFrame.minX, dy: -iconFrame.minY)
                let path = CGMutablePath()
                path.addRect(CGRect(origin: .zero, size: iconFrame.size))
                path.addRoundedRect(in: b, cornerWidth: b.height / 2, cornerHeight: b.height / 2)
                badgeMask.frame = CGRect(origin: .zero, size: iconFrame.size)
                badgeMask.path = path
                iconLayer.mask = badgeMask
            } else {
                iconLayer.mask = nil
            }
        }
        CATransaction.commit()
    }
}

private func != (a: (CGRect, CGRect, CGRect?), b: (CGRect, CGRect, CGRect?)) -> Bool {
    a.0 != b.0 || a.1 != b.1 || a.2 != b.2
}

// MARK: - Controller

@MainActor
final class Controller: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var windows: [String: VeilWindow] = [:]
    private var hiddenTiles: [DockTile] = []
    private var dockList: AXUIElement?
    private var hoverZone: CGRect = .null
    private var idleTimer: Timer?
    private var displayLink: CADisplayLink?
    private var mouseMonitor: Any?
    private var lastFullRefresh = Date.distantPast
    private var settledFrames = 0
    private var missingTilesSince: Date?
    private var missingDockListSince: Date?
    // Read once per full refresh; the display-frame path must stay cheap.
    private var edge = DockEdge.bottom
    private var iconColor = NSColor.clear
    private var dotColor = NSColor.clear
    private var lightMode = false
    private let wallpaper = Wallpaper()

    private var enabled: Bool {
        get { defaults.object(forKey: "enabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "enabled") }
    }

    func start() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "eye.slash", accessibilityDescription: "Hidden apps")
        statusItem.button?.imagePosition = .imageLeading
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification,
                     NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            workspace.addObserver(self, selector: #selector(changed), name: name, object: nil)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(changed),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(changed),
                                                            name: .init("AppleInterfaceThemeChangedNotification"), object: nil)

        registerLoginItemOnFirstLaunch()
        if !AXIsProcessTrusted() {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        refresh()
    }

    @objc private func changed() {
        // The Dock rearranges its tiles slightly after these notifications arrive.
        refresh()
        for delay in [0.15, 0.6] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.refresh() }
        }
    }

    private func hiddenApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { $0.isHidden && $0.activationPolicy == .regular }
    }

    /// Re-reads the whole Dock and rebuilds the veils.
    private func refresh() {
        let hidden = hiddenApps()
        statusItem.button?.title = hidden.isEmpty ? "" : " \(hidden.count)"
        lastFullRefresh = Date()

        let trusted = AXIsProcessTrusted()
        let needsDock = trusted && enabled && !hidden.isEmpty
        let list = needsDock ? DockAX.list() : nil
        guard let list else {
            if needsDock {
                // The Dock can briefly lose its accessibility tree while starting or rearranging.
                let since = missingDockListSince ?? Date()
                missingDockListSince = since
                if Date().timeIntervalSince(since) > 3 {
                    ErrorLog.record("dockListUnavailable", "Accessibility is allowed, but the Dock's icon list could not be read.")
                }
            } else {
                missingDockListSince = nil
            }
            hiddenTiles = []
            dockList = nil
            missingTilesSince = nil
            draw()
            setTracking(false)
            scheduleIdle(after: needsDock ? 0.5 : (trusted ? nil : 2))
            return
        }
        missingDockListSince = nil

        edge = DockEdge.current
        if let raw = UserDefaults(suiteName: dockBundleID)?.string(forKey: "orientation"), DockEdge(rawValue: raw) == nil {
            ErrorLog.record("unknownDockOrientation", "The Dock's orientation setting is \"\(raw)\".")
        }
        lightMode = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) != .darkAqua
        if lightMode { wallpaper.reload() }
        iconColor = veilColor(opacityKey: "opacity", fallback: 0.55)
        dotColor = veilColor(opacityKey: "dotOpacity", fallback: 0.7)
        let hiddenPaths = Set(hidden.compactMap { $0.bundleURL.map(DockAX.normalize) })
        let hiddenIDs = Set(hidden.compactMap(\.bundleIdentifier))
        dockList = list
        hiddenTiles = DockAX.appTiles(in: list).filter {
            hiddenPaths.contains($0.path) || bundleID(for: $0.path).map(hiddenIDs.contains) == true
        }
        checkTiles(hiddenCount: hidden.count)
        updateHoverZone()
        draw()
        setTracking(true)
        if pointerInHoverZone() { startDisplayLink() }
        scheduleIdle(after: 0.5)
    }

    /// Logs hidden apps whose Dock tile can't be found, and tiles with implausible frames. The Dock briefly lacks a
    /// tile while an app launches, so a missing tile only counts once it has been missing for a few seconds.
    private func checkTiles(hiddenCount: Int) {
        let missing = hiddenCount - hiddenTiles.count
        if missing > 0 {
            let since = missingTilesSince ?? Date()
            missingTilesSince = since
            if Date().timeIntervalSince(since) > 3 {
                ErrorLog.record("hiddenAppTileMissing", "\(missing) of \(hiddenCount) hidden apps had no matching Dock tile.")
            }
        } else {
            missingTilesSince = nil
        }
        for tile in hiddenTiles where tile.frame.width < 8 || tile.frame.height < 8 || tile.frame.width > 1024 || tile.frame.height > 1024 {
            ErrorLog.record("unexpectedTileFrame", "A Dock tile reported the frame \(tile.frame).")
        }
    }
    /// Re-reads only the hidden tiles' frames. Cheap enough to run every display frame.
    private func updateFrames() -> Bool {
        var moved = false
        for i in hiddenTiles.indices {
            guard let frame = DockAX.frame(of: hiddenTiles[i].element) else {
                refresh()  // The element went away (Dock restarted or tile removed).
                return true
            }
            if frame != hiddenTiles[i].frame {
                hiddenTiles[i].frame = frame
                moved = true
            }
        }
        return moved
    }

    private func draw() {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        var shown = Set<String>()
        for tile in hiddenTiles {
            let window = windows[tile.path] ?? VeilWindow()
            windows[tile.path] = window
            let g = VeilGeometry(tile: tile.frame, edge: edge, badge: tile.badge)
            // The dot sits on the Dock's glass a few points from the icon, so sample a little around it.
            window.apply(g, primaryHeight: primaryHeight, iconColor: tone(under: g.icon, fallback: iconColor),
                         dotColor: tone(under: g.dot.insetBy(dx: -4, dy: -4), fallback: dotColor))
            if !window.isVisible { window.orderFrontRegardless() }
            shown.insert(tile.path)
        }
        for (path, window) in windows where !shown.contains(path) {
            window.orderOut(nil)
            windows[path] = nil
        }
    }

    // MARK: Tracking the pointer and magnification

    /// The area where the pointer makes the Dock magnify or rearrange: the Dock itself, extended toward the
    /// screen center by the largest magnified icon size.
    private func updateHoverZone() {
        guard let list = dockList, let frame = DockAX.frame(of: list) else { hoverZone = .null; return }
        let dockPrefs = UserDefaults(suiteName: dockBundleID)
        let magnified = dockPrefs?.bool(forKey: "magnification") == true
        let reach = magnified ? CGFloat(dockPrefs?.double(forKey: "largesize") ?? 0).nonZero(or: 128) : 16
        switch edge {
        case .bottom: hoverZone = CGRect(x: frame.minX - reach, y: frame.minY - reach,
                                         width: frame.width + 2 * reach, height: frame.height + reach)
        case .left: hoverZone = CGRect(x: frame.minX, y: frame.minY - reach,
                                       width: frame.width + reach, height: frame.height + 2 * reach)
        case .right: hoverZone = CGRect(x: frame.minX - reach, y: frame.minY - reach,
                                        width: frame.width + reach, height: frame.height + 2 * reach)
        }
    }

    private func pointerInHoverZone() -> Bool {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let mouse = NSEvent.mouseLocation
        return hoverZone.contains(CGPoint(x: mouse.x, y: primaryHeight - mouse.y))
    }

    /// Watches the pointer while any app is hidden, so tracking starts the moment it reaches the Dock.
    private func setTracking(_ on: Bool) {
        if on, mouseMonitor == nil {
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.displayLink == nil, self.pointerInHoverZone() else { return }
                    self.startDisplayLink()
                }
            }
        } else if !on {
            if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
            mouseMonitor = nil
            stopDisplayLink()
        }
    }

    private func startDisplayLink() {
        guard displayLink == nil, let screen = NSScreen.screens.first else { return }
        settledFrames = 0
        let link = screen.displayLink(target: self, selector: #selector(displayFrame))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func displayFrame() {
        guard !hiddenTiles.isEmpty else { stopDisplayLink(); return }
        if updateFrames() { draw(); settledFrames = 0 } else { settledFrames += 1 }
        // Tiles only move in response to the pointer, so stop once they settle; the next pointer movement over
        // the Dock starts tracking again.
        if settledFrames > 20 { stopDisplayLink() }
    }

    // MARK: Idle checks

    private func scheduleIdle(after interval: TimeInterval?) {
        idleTimer?.invalidate()
        guard let interval else { return }
        idleTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.idleTick() }
        }
    }

    /// Badges, Dock position, and icon size change without any notification, so check the hidden tiles twice a
    /// second. Re-read the whole Dock every few seconds as a safety net for anything else that rearranges it.
    private func idleTick() {
        if dockList == nil || !AXIsProcessTrusted() || Date().timeIntervalSince(lastFullRefresh) > 5 {
            refresh()
            return
        }
        var changed = false
        for i in hiddenTiles.indices {
            guard let frame = DockAX.frame(of: hiddenTiles[i].element) else {
                refresh()  // The element went away (Dock restarted or tile removed).
                return
            }
            let badge = DockAX.badge(of: hiddenTiles[i].element)
            if frame != hiddenTiles[i].frame || badge != hiddenTiles[i].badge {
                hiddenTiles[i].frame = frame
                hiddenTiles[i].badge = badge
                changed = true
            }
        }
        if changed {
            updateHoverZone()
            draw()
        }
        scheduleIdle(after: 0.5)
    }

    // MARK: Helpers

    private var bundleIDCache: [String: String] = [:]

    private func bundleID(for path: String) -> String? {
        if let cached = bundleIDCache[path] { return cached.isEmpty ? nil : cached }
        let id = Bundle(path: path)?.bundleIdentifier
        bundleIDCache[path] = id ?? ""
        return id
    }

    private func veilColor(opacityKey: String, fallback: Double) -> NSColor {
        let alpha = CGFloat(defaults.object(forKey: opacityKey) as? Double ?? fallback)
        // In Light Mode this is only used when the wallpaper can't be read; mid gray is the least wrong guess.
        return lightMode ? NSColor(white: 0.5, alpha: alpha) : NSColor(white: 0.13, alpha: alpha)
    }

    private func tone(under rect: CGRect, fallback: NSColor) -> NSColor {
        guard lightMode, let color = wallpaper.glassColor(under: rect) else { return fallback }
        return color.withAlphaComponent(fallback.alphaComponent)
    }

    private func registerLoginItemOnFirstLaunch() {
        guard !defaults.bool(forKey: "loginItemConfigured") else { return }
        defaults.set(true, forKey: "loginItemConfigured")
        do {
            try SMAppService.mainApp.register()
        } catch {
            ErrorLog.record("loginItemRegistration", error.localizedDescription)
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if !AXIsProcessTrusted() {
            menu.addItem(withTitle: "Allow Accessibility Access…", action: #selector(openAccessibility), keyEquivalent: "")
                .target = self
            menu.addItem(.separator())
        }
        let hidden = hiddenApps().sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
        let header = NSMenuItem(title: hidden.isEmpty ? "No Hidden Apps" : "Hidden Apps", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for app in hidden {
            let item = NSMenuItem(title: app.localizedName ?? "App", action: #selector(unhide(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = app
            if let icon = app.icon?.copy() as? NSImage {
                icon.size = NSSize(width: 16, height: 16)
                item.image = icon
            }
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let toggle = NSMenuItem(title: "Dim Hidden Apps in Dock", action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.target = self
        toggle.state = enabled ? .on : .off
        menu.addItem(toggle)

        let strengthMenu = NSMenu(title: "Dimming Strength")
        let iconOpacity = defaults.object(forKey: "opacity") as? Double ?? 0.55
        let dotOpacity = defaults.object(forKey: "dotOpacity") as? Double ?? 0.7
        for (index, strength) in dimmingStrengths.enumerated() {
            let item = NSMenuItem(title: strength.title, action: #selector(setDimmingStrength(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = iconOpacity == strength.icon && dotOpacity == strength.dot ? .on : .off
            strengthMenu.addItem(item)
        }
        let strengthItem = NSMenuItem(title: "Dimming Strength", action: nil, keyEquivalent: "")
        strengthItem.submenu = strengthMenu
        menu.addItem(strengthItem)

        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        let report = NSMenuItem(title: "Report a Problem…", action: #selector(reportProblem), keyEquivalent: "")
        report.target = self
        menu.addItem(report)
        let request = NSMenuItem(title: "Request a Feature…", action: #selector(requestFeature), keyEquivalent: "")
        request.target = self
        menu.addItem(request)

        menu.addItem(.separator())
        let version = NSMenuItem(title: "DimHidden \(appVersion)", action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)
        menu.addItem(withTitle: "Quit DimHidden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }
    @objc private func unhide(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? NSRunningApplication else { return }
        app.unhide()
        app.activate()
    }

    @objc private func toggleEnabled() {
        enabled.toggle()
        refresh()
    }

    @objc private func setDimmingStrength(_ sender: NSMenuItem) {
        guard dimmingStrengths.indices.contains(sender.tag) else { return }
        let strength = dimmingStrengths[sender.tag]
        defaults.set(strength.icon, forKey: "opacity")
        defaults.set(strength.dot, forKey: "dotOpacity")
        refresh()
    }

    @objc private func toggleLoginItem() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            ErrorLog.record("loginItemToggle", error.localizedDescription)
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func reportProblem() {
        openIssueForm("bug_report.yml", fields: ["environment": diagnostics()])
    }

    @objc private func requestFeature() {
        openIssueForm("feature_request.yml", fields: [:])
    }

    /// Opens a new GitHub issue with the given issue form, pre-filling form fields by their ids.
    private func openIssueForm(_ template: String, fields: [String: String]) {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let query = (["template": template].merging(fields) { a, _ in a })
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")
        if let url = URL(string: "https://github.com/Jalohann/DimHidden/issues/new?" + query) {
            NSWorkspace.shared.open(url)
        }
    }

    /// Settings that affect where the veils go. No app names: this text is posted publicly.
    private func diagnostics() -> String {
        let dock = UserDefaults(suiteName: dockBundleID)
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let magnification = dock?.bool(forKey: "magnification") == true
            ? "on (\(Int(dock?.double(forKey: "largesize") ?? 0)))" : "off"
        var lines = [
            "DimHidden \(appVersion)",
            "macOS \(osVersion)",
            "Dock: \(DockEdge.current.rawValue), icon size \(Int(dock?.double(forKey: "tilesize") ?? 0)), "
                + "magnification \(magnification), auto-hide \(dock?.bool(forKey: "autohide") == true ? "on" : "off")",
            "Appearance: \(dark ? "Dark" : "Light")",
            "Displays: \(NSScreen.screens.count)",
            "Accessibility: \(AXIsProcessTrusted() ? "allowed" : "not allowed")",
            "Hidden apps: \(hiddenApps().count), tiles found: \(hiddenTiles.count)",
        ]
        let errors = ErrorLog.recent(10)
        if !errors.isEmpty { lines += ["", "Recent errors:"] + errors }
        return lines.joined(separator: "\n")
    }
}
private extension CGFloat {
    func nonZero(or fallback: CGFloat) -> CGFloat { self > 0 ? self : fallback }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = MainActor.assumeIsolated {
    let controller = Controller()
    controller.start()
    return controller
}
app.run()
