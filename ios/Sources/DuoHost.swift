#if os(iOS)
import SwiftUI
import UIKit

// The iPhone side of the Duo layout engine: reads the window and the hinge, hands every view its posture, and
// lets the inner screen turn while the cover screen and ordinary iPhones stay upright.

/// What the hinge last said, and the orientation the app may turn to.
@MainActor @Observable final class DuoMonitor {
    private(set) var hinge: DuoLayout.Hinge = .unknown
    /// The home indicator's inset, remembered so a raised keyboard is not mistaken for it.
    @ObservationIgnored private var restingBottom: CGFloat = 0
    @ObservationIgnored private var gate = HingeGate()
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored weak var view: UIView?

    init() {
        #if DEBUG
        // `-WatchHinge half` lays the app out half open, for screenshots and tests. The real hinge is then ignored.
        if let forced = Self.forcedHinge { hinge = forced; gate = HingeGate(shown: forced) }
        #endif
    }

    #if DEBUG
    static var forcedHinge: DuoLayout.Hinge? {
        switch UserDefaults.standard.string(forKey: "WatchHinge") {
        case "half": .partiallyOpen
        case "open": .fullyOpen
        case "closed": .closed
        default: nil
        }
    }
    #endif

    /// What the hinge says goes through `HingeGate`: the half-open layout waits until the hinge has stayed part open,
    /// and the hinge reporting the same state again does not restart that wait.
    func hingeChanged(to next: DuoLayout.Hinge) {
        perform(gate.update(next))
    }

    private func perform(_ action: HingeGate.Action) {
        switch action {
        case .none:
            return
        case .cancelWait:
            pending?.cancel()
            pending = nil
        case .startWait:
            pending?.cancel()
            pending = Task { [weak self] in
                try? await Task.sleep(for: HingeGate.wait)
                guard !Task.isCancelled, let self else { return }
                self.pending = nil
                self.perform(self.gate.waitEnded())
            }
        case .show:
            pending?.cancel()
            pending = nil
            hinge = gate.shown
            turnToMatch()
        }
    }

    func layout(size: CGSize, insets: EdgeInsets) -> DuoLayout {
        DuoLayout(size: size, insets: DuoLayout.restingInsets(insets, resting: &restingBottom), hinge: hinge)
    }

    // MARK: Turning

    /// The interface orientation that puts the picture the right way up on the inner screen for how the phone is
    /// held, or nil to leave it alone. The inner screen's own portrait is a quarter turn from the phone's: held like
    /// a book the phone reports portrait and the screen is wide. Seen on the real phone.
    /// iOS refuses upside-down portrait on an iPhone, so that one hold is left as it is.
    static func orientation(device: UIDeviceOrientation, halfOpen: Bool, windowIsTall: Bool) -> UIInterfaceOrientationMask? {
        switch device {
        case .portrait: return .landscapeLeft
        case .landscapeLeft: return .portrait
        case .portraitUpsideDown: return .landscapeRight
        case .landscapeRight: return nil
        default:
            // Flat on a table the phone cannot tell which way is up. Half open there, the crease has to run across.
            return halfOpen && !windowIsTall ? .portrait : nil
        }
    }

    /// Only the inner screen turns. With rotation lock on iOS would leave it sideways, so the app asks for the turn.
    func turnToMatch() {
        guard let window = view?.window, let scene = window.windowScene else { return }
        let bounds = window.bounds
        guard min(bounds.width, bounds.height) >= DuoLayout.innerSide else { return }
        window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        guard let mask = Self.orientation(device: UIDevice.current.orientation, halfOpen: hinge == .partiallyOpen,
                                          windowIsTall: bounds.height >= bounds.width) else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
    }
}

/// Sits behind the app, listens to the hinge and to the phone being turned.
struct HingeReader: UIViewRepresentable {
    let monitor: DuoMonitor

    func makeUIView(context: Context) -> HingeView { HingeView(monitor: monitor) }
    func updateUIView(_ view: HingeView, context: Context) {}

    final class HingeView: UIView {
        private let monitor: DuoMonitor

        init(monitor: DuoMonitor) {
            self.monitor = monitor
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            monitor.view = self
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            NotificationCenter.default.addObserver(self, selector: #selector(turned), name: UIDevice.orientationDidChangeNotification, object: nil)
            #if DEBUG
            if DuoMonitor.forcedHinge != nil { return }
            #endif
            if #available(iOS 27.1, *) {
                addInteraction(UIHingeInteraction { [weak monitor] _, update in
                    let next: DuoLayout.Hinge
                    switch update.hinge?.status {
                    case .closed: next = .closed
                    case .partiallyOpen: next = .partiallyOpen
                    case .fullyOpen: next = .fullyOpen
                    default: next = .unknown
                    }
                    monitor?.hingeChanged(to: next)
                })
            }
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        @objc private func turned() { monitor.turnToMatch() }

        /// The window changes size when the phone is opened or shut: the allowed orientations change with it.
        override func layoutSubviews() {
            super.layoutSubviews()
            window?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            monitor.turnToMatch()
        }
    }
}

/// The cover screen and ordinary iPhones stay upright. The inner screen may be held either way round.
final class WatchAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Self.orientations(window: window?.bounds.size ?? .zero, screen: window?.windowScene?.screen.bounds.size ?? .zero)
    }

    static func orientations(window: CGSize, screen: CGSize) -> UIInterfaceOrientationMask {
        let inner = min(window.width, window.height) >= DuoLayout.innerSide || min(screen.width, screen.height) >= DuoLayout.innerSide
        return inner ? .allButUpsideDown : .portrait
    }
}

/// Wraps the app: measures the window, reads the hinge, and gives every view below it the posture.
struct DuoRoot<Content: View>: View {
    @State private var monitor = DuoMonitor()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if DEBUG
    /// A snapshot is rendered away from the screen, with the hinge it asks for.
    var hinge: DuoLayout.Hinge?
    #endif
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { geo in
            let safe = geo.safeAreaInsets
            let size = CGSize(width: geo.size.width + safe.leading + safe.trailing, height: geo.size.height + safe.top + safe.bottom)
            let duo = layout(size: size, insets: safe)
            content()
                .environment(\.duo, duo)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.32), value: duo.posture)
                #if DEBUG
                .task(id: duo) { DuoDebug.note(duo) }
                #endif
        }
        .background { HingeReader(monitor: monitor).allowsHitTesting(false).accessibilityHidden(true) }
    }

    private func layout(size: CGSize, insets: EdgeInsets) -> DuoLayout {
        #if DEBUG
        if let hinge { return DuoLayout(size: size, insets: insets, hinge: hinge) }
        #endif
        return monitor.layout(size: size, insets: insets)
    }
}
#endif

#if DEBUG && os(iOS)
/// `-WatchSnapshot 669x951` draws the app away from the screen at that size and writes
/// `Documents/snapshot-<name>.png` (`-WatchSnapshotName`, default "app"), then `snapshot-done.txt`. The simulator
/// cannot be unfolded from the command line, so this is how the open and half-open layouts are looked at.
/// `-WatchHinge half` makes them half open; `-WatchSnapshotTop 24` sets the top safe area (24 by default).
/// The page drawn is whatever the launch arguments open: `-selectedTabV4 <n>`, `-collectionScope`,
/// `-collectionLayout`, and the `AtelierProbe` arguments (`-atelierProbe dossier:<id>|timeline|settings`,
/// `-atelierSearch`, `-atelierScroll`). `-WatchSnapshotRegular 1` draws it with a regular width size class.
enum DuoSnapshot {
    @MainActor static func runIfAsked(store: AppStore) async {
        let parts = (UserDefaults.standard.string(forKey: "WatchSnapshot") ?? "").split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2 else { return }
        let size = CGSize(width: parts[0], height: parts[1])
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let name = UserDefaults.standard.string(forKey: "WatchSnapshotName") ?? "app"
        try? FileManager.default.removeItem(at: documents.appendingPathComponent("snapshot-done.txt"))
        // The collection has to be open before there is anything to draw.
        for _ in 0..<60 where store.data == nil { try? await Task.sleep(for: .milliseconds(500)) }
        try? await Task.sleep(for: .seconds(1))
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        let top = UserDefaults.standard.object(forKey: "WatchSnapshotTop") as? Double ?? 24
        let wanted = UIEdgeInsets(top: top, left: 0, bottom: 34, right: 0)
        let root = DuoRoot(hinge: DuoMonitor.forcedHinge ?? .fullyOpen) {
            RootView(store: store)
        }
        .tint(WatchTheme.accent)
        let host = SnapshotHost(rootView: root)
        if UserDefaults.standard.bool(forKey: "WatchSnapshotRegular") {
            host.traitOverrides.horizontalSizeClass = .regular
        }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.windowLevel = .normal - 1
        window.rootViewController = host
        window.isHidden = false
        // The window stands on the cover screen and takes its safe area. Trade it for the inner screen's.
        // The tabs and stacks are UIKit controllers underneath and each works its own safe area out again, so each is
        // told. A page a probe opens a few seconds in is given time to come up, and is told as well.
        for pass in 0..<10 {
            window.layoutIfNeeded()
            var all = [UIViewController](), queue: [UIViewController] = [host]
            while let next = queue.popLast() {
                all.append(next)
                queue.append(contentsOf: next.children)
                if let sheet = next.presentedViewController, sheet.presentingViewController === next { queue.append(sheet) }
            }
            for controller in all {
                let real = controller.view.safeAreaInsets
                if real.right > 0 { controller.additionalSafeAreaInsets.right -= real.right }
                if controller === host {
                    controller.additionalSafeAreaInsets.top += wanted.top - real.top
                    controller.additionalSafeAreaInsets.bottom += wanted.bottom - real.bottom
                }
            }
            try? await Task.sleep(for: .milliseconds(pass < 3 ? 150 : 1000))
        }
        try? await Task.sleep(for: .seconds(2.5))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            window.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
        }
        try? image.pngData()?.write(to: documents.appendingPathComponent("snapshot-\(name).png"))
        window.isHidden = true
        try? "done".write(to: documents.appendingPathComponent("snapshot-done.txt"), atomically: true, encoding: .utf8)
    }
}

/// The snapshot's window stands on the cover screen, where iOS gathers the status bar, the toolbar items and the tab bar
/// into one vertical bar down the trailing edge. The inner screen has none (its safe area has no side inset), so the
/// snapshot turns it off and gets the ordinary bars: the navigation bar at the top and the tab bar at the bottom.
final class SnapshotHost<Content: View>: UIHostingController<Content> {
    @available(iOS 27.1, *)
    override var preferredVerticalBarBehavior: UIVerticalBarBehavior { .disabled }
    @available(iOS 27.1, *)
    override var childForPreferredVerticalBarBehavior: UIViewController? { nil }
}

enum DuoDebug {
    /// One line per posture change in `Documents/duo.log`: what the window really measured.
    static func note(_ duo: DuoLayout) {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("duo.log")
        let i = duo.insets
        let line = "\(duo.posture.rawValue) \(Int(duo.size.width))x\(Int(duo.size.height)) safe \(Int(i.top)) \(Int(i.leading)) \(Int(i.bottom)) \(Int(i.trailing))\n"
        let old = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try? (old + line).write(to: url, atomically: true, encoding: .utf8)
    }
}
#endif
