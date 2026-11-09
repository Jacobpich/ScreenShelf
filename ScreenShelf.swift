// ScreenShelf — a tiny menu bar shelf for your screenshots.
//
// Click the menu bar icon to see your screenshots in a 4-wide grid.
//   • Click a thumbnail            → copy the image to the clipboard
//   • Right-click a thumbnail      → Copy / Open / Show in Finder / Move to Trash
//   • Drag a thumbnail             → drop the file anywhere (Slack, Finder, browser, …)
//   • The ⓧ on the top-right corner → move that screenshot to the Trash

import AppKit
import ImageIO
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

// MARK: - App entry

@main
enum ScreenShelfMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
        withExtendedLifetime(delegate) { app.run() }
    }
}

// MARK: - Model

struct Shot: Identifiable, Equatable {
    let url: URL
    let date: Date
    var id: URL { url }
}

@MainActor
final class ShotStore: ObservableObject {
    @Published private(set) var shots: [Shot] = []
    @Published private(set) var folder: URL
    @Published private(set) var cannotReadFolder = false

    var onNewShot: (() -> Void)?

    private var source: DispatchSourceFileSystemObject?
    private var pendingReload: DispatchWorkItem?
    private var known: Set<URL> = []
    private var didInitialScan = false

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tif", "tiff", "gif"]

    init() {
        folder = Self.currentScreenshotFolder()
        startWatching()
        reload()
    }

    /// Where macOS saves screenshots (⇧⌘5 → Options → Save to). Defaults to the Desktop.
    static func currentScreenshotFolder() -> URL {
        if let loc = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location") {
            let path = (loc as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }

    private static var namePrefixes: [String] {
        var prefixes = ["Screenshot", "Screen Shot", "CleanShot"]
        if let custom = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "name"), !custom.isEmpty {
            prefixes.append(custom)
        }
        return prefixes
    }

    /// A file counts as a screenshot if macOS tagged it as one, or if it has a screenshot-style name.
    private static func isScreenshot(_ url: URL, prefixes: [String]) -> Bool {
        guard imageExtensions.contains(url.pathExtension.lowercased()) else { return false }
        let tagged = url.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path else { return false }
            return getxattr(path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, 0) >= 0
        }
        if tagged { return true }
        let name = url.lastPathComponent
        return prefixes.contains { name.hasPrefix($0) }
    }

    /// Re-check the screenshot location in case it changed in ⇧⌘5 → Options.
    func refreshFolderIfNeeded() {
        let current = Self.currentScreenshotFolder()
        if current.standardizedFileURL != folder.standardizedFileURL {
            folder = current
            known = []
            didInitialScan = false
            startWatching()
        }
        reload()
    }

    func reload() {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.creationDateKey, .isRegularFileKey]
        let contents: [URL]
        do {
            contents = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
            cannotReadFolder = false
        } catch {
            cannotReadFolder = true
            contents = []
        }

        let prefixes = Self.namePrefixes
        var found: [Shot] = []
        for url in contents {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            guard Self.isScreenshot(url, prefixes: prefixes) else { continue }
            found.append(Shot(url: url, date: values.creationDate ?? .distantPast))
        }
        found.sort { $0.date > $1.date }

        let urls = Set(found.map(\.url))
        let added = urls.subtracting(known)
        known = urls
        if found != shots {
            withAnimation(.easeOut(duration: 0.2)) { shots = found }
        }
        if didInitialScan && !added.isEmpty { onNewShot?() }
        didInitialScan = true
    }

    func trash(_ shot: Shot) {
        do {
            try FileManager.default.trashItem(at: shot.url, resultingItemURL: nil)
            withAnimation(.easeOut(duration: 0.18)) { shots.removeAll { $0.id == shot.id } }
            known.remove(shot.url)
            Thumbnails.forget(shot.url)
        } catch {
            NSSound.beep()
        }
    }

    // Watch the folder for changes (new screenshots, deletions, renames).
    private func startWatching() {
        source?.cancel()
        source = nil
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend], queue: .main)
        src.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleReload() }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    private func scheduleReload() {
        pendingReload?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.reload() }
        }
        pendingReload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
}

// MARK: - Thumbnails & clipboard

enum Thumbnails {
    private static let cache = NSCache<NSURL, NSImage>()

    static func forget(_ url: URL) { cache.removeObject(forKey: url as NSURL) }

    static func load(_ url: URL, maxPixels: Int = 400) async -> NSImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        let image = await Task.detached(priority: .userInitiated) { () -> NSImage? in
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }.value
        if let image { cache.setObject(image, forKey: url as NSURL) }
        return image
    }
}

enum Clipboard {
    /// Puts the image on the clipboard as PNG + TIFF (paste into any app) and as a file (paste into Finder).
    static func copyImage(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url), let image = NSImage(data: data) else { return false }
        let item = NSPasteboardItem()
        if url.pathExtension.lowercased() == "png" {
            item.setData(data, forType: .png)
        } else if let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            item.setData(png, forType: .png)
        }
        if let tiff = image.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        item.setString(url.absoluteString, forType: .fileURL)

        let pb = NSPasteboard.general
        pb.clearContents()
        return pb.writeObjects([item])
    }
}

// MARK: - Views

enum Layout {
    static let columns = 4
    static let cellWidth: CGFloat = 116
    static let cellHeight: CGFloat = 86
    static let spacing: CGFloat = 16
    static let sidePadding: CGFloat = 18
    static let maxGridHeight: CGFloat = 480

    static var popoverWidth: CGFloat {
        CGFloat(columns) * cellWidth + CGFloat(columns - 1) * spacing + 2 * sidePadding
    }
}

struct ShelfView: View {
    @ObservedObject var store: ShotStore
    @AppStorage("autoOpen") private var autoOpen = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.shots.isEmpty {
                emptyState
            } else {
                grid
            }
        }
        .frame(width: Layout.popoverWidth)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Screenshots").font(.headline)
            if !store.shots.isEmpty {
                Text("\(store.shots.count)")
                    .font(.caption.monospacedDigit())
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.1)))
            }
            Spacer()
            Button {
                NSWorkspace.shared.open(store.folder)
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help("Open \(store.folder.lastPathComponent) in Finder")

            Menu {
                Toggle("Pop open after each screenshot", isOn: $autoOpen)
                Divider()
                Button("Quit ScreenShelf") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, Layout.sidePadding)
        .padding(.vertical, 10)
    }

    private var gridHeight: CGFloat {
        let rows = max(1, Int(ceil(Double(store.shots.count) / Double(Layout.columns))))
        let content = CGFloat(rows) * Layout.cellHeight + CGFloat(rows - 1) * Layout.spacing + 2 * Layout.spacing
        return min(content, Layout.maxGridHeight)
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(Layout.cellWidth), spacing: Layout.spacing), count: Layout.columns),
                spacing: Layout.spacing
            ) {
                ForEach(store.shots) { shot in
                    ShotCell(shot: shot, store: store)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .padding(.horizontal, Layout.sidePadding)
            .padding(.vertical, Layout.spacing) // room for the ⓧ that overhangs the top row
        }
        .frame(height: gridHeight)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: store.cannotReadFolder ? "lock" : "camera.viewfinder")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
            if store.cannotReadFolder {
                Text("Can't read your \(store.folder.lastPathComponent) folder")
                    .font(.callout.weight(.medium))
                Text("Allow ScreenShelf in System Settings › Privacy & Security › Files & Folders.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Text("No screenshots yet").font(.callout.weight(.medium))
                Text("Press ⇧⌘3, ⇧⌘4 or ⇧⌘5 and they'll show up here.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .padding(.horizontal, 24)
    }
}

struct ShotCell: View {
    let shot: Shot
    @ObservedObject var store: ShotStore

    @State private var image: NSImage?
    @State private var hovering = false
    @State private var hoveringX = false
    @State private var copied = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            thumbnail
            deleteButton
                .offset(x: 8, y: -8) // overlap the top-right corner
        }
        .task(id: shot.url) { image = await Thumbnails.load(shot.url) }
    }

    private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.06))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .padding(5)
            } else {
                ProgressView().controlSize(.small)
            }
            if copied {
                Label("Copied", systemImage: "checkmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(Color.black.opacity(0.75)))
                    .transition(.opacity)
            }
        }
        .frame(width: Layout.cellWidth, height: Layout.cellHeight)
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(hovering ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: hovering ? 2 : 1)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { copy() }
        .onDrag { NSItemProvider(contentsOf: shot.url) ?? NSItemProvider() }
        .contextMenu {
            Button("Copy") { copy() }
            Button("Open") { NSWorkspace.shared.open(shot.url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([shot.url]) }
            Divider()
            Button("Move to Trash") { store.trash(shot) }
        }
        .help("\(shot.url.lastPathComponent)\nClick to copy · drag to drop · right-click for more")
    }

    private var deleteButton: some View {
        Button {
            store.trash(shot)
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .heavy))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(hoveringX ? Color.red : Color.black.opacity(0.78)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.95), lineWidth: 1.5))
                .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hoveringX = $0 }
        .help("Move to Trash")
    }

    private func copy() {
        guard Clipboard.copyImage(at: shot.url) else { NSSound.beep(); return }
        withAnimation(.easeOut(duration: 0.12)) { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            withAnimation(.easeIn(duration: 0.2)) { copied = false }
        }
    }
}

// MARK: - Menu bar plumbing

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let store = ShotStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        setIcon(hasNew: false)

        let hosting = NSHostingController(rootView: ShelfView(store: store))
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.animates = true

        store.onNewShot = { [weak self] in self?.screenshotArrived() }
        ensureLaunchAtLogin()
    }

    /// Always keep ScreenShelf registered as a login item, re-registering on every launch if needed.
    private func ensureLaunchAtLogin() {
        let service = SMAppService.mainApp
        if service.status != .enabled {
            do { try service.register() } catch { NSLog("ScreenShelf: login item registration failed: \(error)") }
        }
        NSLog("ScreenShelf: login item status = \(service.status.rawValue)")
    }

    private func setIcon(hasNew: Bool) {
        let name = hasNew ? "photo.stack.fill" : "photo.stack"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Screenshots")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    private func screenshotArrived() {
        if UserDefaults.standard.bool(forKey: "autoOpen") {
            if !popover.isShown { showPopover() }
        } else if !popover.isShown {
            setIcon(hasNew: true)
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        store.refreshFolderIfNeeded()
        setIcon(hasNew: false)
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
}
