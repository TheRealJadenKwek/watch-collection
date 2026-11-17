#if WC_PERF_BENCH
// Bench builds only: compiled when the build passes `-D WC_PERF_BENCH`, so no shipped build contains any of this.
//
// Drives the wishlist's scroll view on a fixed pattern from a display link and records when each frame was shown, so
// a scroll can be measured the same way before and after a change. Launch arguments:
//   -WCPerfDelay <s>    seconds after the wishlist appears before the first pass (default 12)
//   -WCPerfPasses <n>   passes to run (default 2): the first is cold (nothing decoded yet), the rest warm
//   -WCPerfQuit YES     quit when done (default YES)
// Each pass scrolls slowly to the bottom, fast to the top, fast to the bottom and slowly back to the top. Results go to
// standard output as `PERF` lines and to `perf-<time>.json` in the app's temporary folder.
import AppKit
import Combine
import OSLog
import QuartzCore
import SwiftUI

@MainActor
enum PerfBench {
    struct Segment {
        let name: String
        /// 1 scrolls down the page, -1 up.
        let direction: CGFloat
        /// Points per second.
        let speed: CGFloat
    }

    static let pattern: [Segment] = [
        Segment(name: "slow-down", direction: 1, speed: 800),
        Segment(name: "fast-up", direction: -1, speed: 4000),
        Segment(name: "fast-down", direction: 1, speed: 4000),
        Segment(name: "slow-up", direction: -1, speed: 800),
    ]

    static let signposter = OSSignposter(subsystem: "com.jadenkwek.watchcollection.perf", category: .pointsOfInterest)

    private static var driver: Driver?

    static func attach(_ scrollView: NSScrollView, store: AppStore) {
        guard driver == nil else { return }
        let defaults = UserDefaults.standard
        let delay = defaults.object(forKey: "WCPerfDelay") == nil ? 12 : defaults.double(forKey: "WCPerfDelay")
        let passes = defaults.object(forKey: "WCPerfPasses") == nil ? 2 : defaults.integer(forKey: "WCPerfPasses")
        let quit = defaults.object(forKey: "WCPerfQuit") == nil ? true : defaults.bool(forKey: "WCPerfQuit")
        let driver = Driver(scrollView: scrollView, store: store, passes: passes, quit: quit)
        self.driver = driver
        print("PERF attached delay=\(delay) passes=\(passes)")
        if let window = scrollView.window {
            // The same window size every run, whatever the last one left. Never brought to the front or activated: a
            // bench run must not take the screen (launch it with `open -g`).
            window.setContentSize(NSSize(width: 1360, height: 880))
            window.setFrameOrigin(NSPoint(x: 80, y: 80))
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            driver.start()
        }
    }

    @MainActor
    final class Driver: NSObject {
        weak var scrollView: NSScrollView?
        let store: AppStore
        let passes: Int
        let quit: Bool
        private var link: CADisplayLink?
        private var pass = 0
        private var segment = 0
        private var offset: CGFloat = 0
        private var lastTarget: CFTimeInterval?
        private var lastShown: CFTimeInterval?
        private var pauseUntil: CFTimeInterval = 0
        private var publishes = 0
        private var watch: AnyCancellable?
        private var interval: OSSignpostIntervalState?
        /// Per pass and segment: the interval between frames shown, in seconds.
        private var intervals: [String: [Double]] = [:]
        private var publishesBy: [String: Int] = [:]
        private var started: CFTimeInterval = 0

        init(scrollView: NSScrollView, store: AppStore, passes: Int, quit: Bool) {
            self.scrollView = scrollView
            self.store = store
            self.passes = passes
            self.quit = quit
        }

        private var key: String { "\(pass + 1)/\(PerfBench.pattern[segment].name)" }

        func start() {
            guard let scrollView else { return }
            guard passes > 0 else { finish(); return }
            watch = store.objectWillChange.sink { [weak self] _ in
                guard let self else { return }
                self.publishes += 1
                self.publishesBy[self.key, default: 0] += 1
            }
            let clip = scrollView.contentView
            offset = clip.bounds.origin.y
            let document = scrollView.documentView
            print("PERF start flipped=\(document?.isFlipped ?? false) doc=\(document?.frame.size ?? .zero) clip=\(clip.bounds) insets=\(scrollView.contentInsets.top)")
            let link = scrollView.displayLink(target: self, selector: #selector(tick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            self.link = link
            beginInterval()
        }

        private func beginInterval() {
            started = CACurrentMediaTime()
            let name: StaticString = pass == 0 ? "cold" : "warm"
            interval = PerfBench.signposter.beginInterval(name, id: PerfBench.signposter.makeSignpostID())
        }

        private func endInterval() {
            if let interval {
                PerfBench.signposter.endInterval(pass == 0 ? "cold" : "warm", interval)
            }
            interval = nil
        }

        @objc private func tick(_ link: CADisplayLink) {
            guard let scrollView else { return }
            let target = link.targetTimestamp
            let shown = link.timestamp
            defer {
                lastTarget = target
                lastShown = shown
            }
            if pauseUntil > 0 {
                if shown < pauseUntil { return }
                pauseUntil = 0
                beginInterval()
                lastShown = nil
                lastTarget = nil
                return
            }
            if let lastShown, shown > lastShown {
                intervals[key, default: []].append(shown - lastShown)
            }
            let dt = lastTarget.map { target - $0 } ?? (1.0 / 120)
            let step = PerfBench.pattern[segment]
            let clip = scrollView.contentView
            let proposed = offset + step.direction * step.speed * CGFloat(dt)
            let allowed = clip.constrainBoundsRect(NSRect(origin: NSPoint(x: clip.bounds.origin.x, y: proposed), size: clip.bounds.size)).origin.y
            offset = allowed
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: allowed))
            scrollView.reflectScrolledClipView(clip)
            guard abs(allowed - proposed) > 0.01 else { return }
            // The end of the page in this direction: on to the next segment, or the next pass.
            segment += 1
            if segment == PerfBench.pattern.count {
                segment = 0
                report(pass: pass)
                endInterval()
                pass += 1
                if pass == passes {
                    finish()
                    return
                }
                // A second at the top between passes.
                pauseUntil = shown + 1
            }
        }

        private func report(pass: Int) {
            let budget = 1.0 / 120
            var all: [Double] = []
            for step in PerfBench.pattern {
                let key = "\(pass + 1)/\(step.name)"
                let values = intervals[key] ?? []
                all += values
                print("PERF " + Self.line(key, values, budget: budget, publishes: publishesBy[key] ?? 0))
            }
            let total = PerfBench.pattern.reduce(0) { $0 + (publishesBy["\(pass + 1)/\($1.name)"] ?? 0) }
            print("PERF " + Self.line("\(pass + 1)/all", all, budget: budget, publishes: total))
        }

        static func line(_ key: String, _ values: [Double], budget: Double, publishes: Int) -> String {
            let stats = Stats(values, budget: budget)
            return String(format: "%@ frames=%d seconds=%.2f median=%.2fms over=%d hitchms=%.1f ratio=%.2fms/s worst=%.1fms p99=%.1fms publishes=%d",
                          key, stats.frames, stats.seconds, stats.median * 1000, stats.over, stats.hitch * 1000,
                          stats.ratio * 1000, stats.worst * 1000, stats.p99 * 1000, publishes)
        }

        private func finish() {
            link?.invalidate()
            link = nil
            watch = nil
            let payload: [String: Any] = [
                "intervals": intervals,
                "publishes": publishesBy,
                "pattern": PerfBench.pattern.map { ["name": $0.name, "speed": $0.speed, "direction": $0.direction] },
            ]
            if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("perf-\(Int(Date().timeIntervalSince1970)).json")
                try? data.write(to: url)
                print("PERF json=\(url.path)")
            }
            print("PERF done")
            fflush(stdout)
            if quit {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(300))
                    NSApp.terminate(nil)
                }
            }
        }
    }

    struct Stats {
        let frames: Int
        let seconds: Double
        let median: Double
        /// Frames shown later than one and a half budgets after the one before: at least one refresh was missed.
        let over: Int
        /// The time past the budget of those frames, added up.
        let hitch: Double
        /// Hitch time per second of scrolling.
        let ratio: Double
        let worst: Double
        let p99: Double

        init(_ values: [Double], budget: Double) {
            frames = values.count
            seconds = values.reduce(0, +)
            let sorted = values.sorted()
            median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
            p99 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.99))]
            worst = sorted.last ?? 0
            let late = values.filter { $0 > budget * 1.5 }
            over = late.count
            hitch = late.reduce(0) { $0 + ($1 - budget) }
            ratio = seconds > 0 ? hitch / seconds : 0
        }
    }
}

/// Placed at the window's root: records every frame for the first seconds after the window opens (`-WCPerfLaunch`,
/// default 10), so the cost of building the sections at launch shows as one `PERF launch` line.
struct PerfLaunchProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> ProbeView { ProbeView() }
    func updateNSView(_ view: ProbeView, context: Context) {}

    final class ProbeView: NSView {
        private var link: CADisplayLink?
        private var last: CFTimeInterval?
        private var started: CFTimeInterval = 0
        private var values: [Double] = []
        private var seconds: Double = 10

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, link == nil else { return }
            let defaults = UserDefaults.standard
            seconds = defaults.object(forKey: "WCPerfLaunch") == nil ? 10 : defaults.double(forKey: "WCPerfLaunch")
            guard seconds > 0 else { return }
            let link = displayLink(target: self, selector: #selector(tick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            self.link = link
            started = CACurrentMediaTime()
        }

        @objc private func tick(_ link: CADisplayLink) {
            let shown = link.timestamp
            if let last, shown > last { values.append(shown - last) }
            last = shown
            guard CACurrentMediaTime() - started >= seconds else { return }
            link.invalidate()
            self.link = nil
            let budget = 1.0 / 120
            let stats = PerfBench.Stats(values, budget: budget)
            let longest = values.sorted(by: >).prefix(5).map { String(format: "%.0f", $0 * 1000) }.joined(separator: ",")
            print(String(format: "PERF launch frames=%d seconds=%.2f over=%d hitchms=%.1f worst=%.1fms longest=%@",
                         stats.frames, stats.seconds, stats.over, stats.hitch * 1000, stats.worst * 1000, longest))
            fflush(stdout)
        }
    }
}

/// Placed in the wishlist's scroll content: hands its scroll view to the bench once it is in a window.
struct PerfBenchProbe: NSViewRepresentable {
    let store: AppStore

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.store = store
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) {}

    final class ProbeView: NSView {
        var store: AppStore?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, let store else { return }
            DispatchQueue.main.async { [weak self] in
                guard let scroll = self?.enclosingScrollView else {
                    print("PERF no scroll view")
                    return
                }
                MainActor.assumeIsolated { PerfBench.attach(scroll, store: store) }
            }
        }
    }
}
#endif
