import SwiftUI

#if DEBUG
/// Debug builds only. Launch arguments for capturing screens on a simulator, which has no tap input:
///   -atelierProbe dossier:<watch-id>   opens that watch's page from Collection
///   -atelierProbe edit:<watch-id>      opens that watch's page, then its edit sheet
///   -atelierProbe timeline             opens the purchase timeline from Insights
///   -atelierTimelinePage <n>           then moves it to its nth page (0 is the opening page)
///   -atelierProbe settings             opens Settings
///   -atelierSearch <text>              starts Search with that text
///   -atelierScroll <screen>:<points>   scrolls collection, dossier, insights, wishlist or search
/// Tabs, scope and layout need no probe: -selectedTabV4 stats, -collectionScope Archive,
/// -collectionLayout grid.
enum AtelierProbe {
    static var page: String? { UserDefaults.standard.string(forKey: "atelierProbe") }

    static var dossierID: String? {
        guard let page else { return nil }
        for prefix in ["dossier:", "edit:"] where page.hasPrefix(prefix) { return String(page.dropFirst(prefix.count)) }
        return nil
    }

    static var opensEdit: Bool { page?.hasPrefix("edit:") == true }

    static var opensTimeline: Bool { page == "timeline" }
    static var timelinePage: Int? { UserDefaults.standard.string(forKey: "atelierTimelinePage").flatMap { Int($0) } }
    static var opensSettings: Bool { page == "settings" }
    static var search: String? { UserDefaults.standard.string(forKey: "atelierSearch") }

    static func scroll(for screen: String) -> CGFloat? {
        guard let value = UserDefaults.standard.string(forKey: "atelierScroll") else { return nil }
        let parts = value.split(separator: ":")
        guard parts.count == 2, parts[0] == screen, let points = Double(parts[1]) else { return nil }
        return CGFloat(points)
    }
}

private struct ProbeScroll: ViewModifier {
    let y: CGFloat
    @State private var position = ScrollPosition(edge: .top)

    func body(content: Content) -> some View {
        content
            .scrollPosition($position)
            .task {
                // Give the collection time to load and lay out before moving.
                try? await Task.sleep(for: .seconds(5))
                withAnimation(.none) { position.scrollTo(y: y) }
            }
    }
}
#endif

extension View {
    /// Debug builds only: scrolls this screen's scroll view to the offset in `-atelierScroll`.
    @ViewBuilder
    func atelierProbeScroll(_ screen: String) -> some View {
        #if DEBUG
        if let y = AtelierProbe.scroll(for: screen) {
            modifier(ProbeScroll(y: y))
        } else {
            self
        }
        #else
        self
        #endif
    }
}
