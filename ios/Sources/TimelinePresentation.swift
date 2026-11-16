import SwiftUI

struct TimelineRoute: Hashable {
    let ownedOnly: Bool
}

/// Every watch in order of arrival as a scroll-through presentation: a title card per year, then one page
/// per watch with a large photo, while a counter keeps the running number and total spent. Scroll freely,
/// use the arrow keys, click a year to jump, or press play to let it run.
struct TimelinePresentationScreen: View {
    @ObservedObject var store: AppStore
    @State private var ownedOnly: Bool
    @State private var position: String?
    @State private var playing = false
    @FocusState private var focused: Bool

    init(store: AppStore, ownedOnly: Bool = false) {
        self.store = store
        _ownedOnly = State(initialValue: ownedOnly)
    }

    private var all: [Watch] { store.data?.watches ?? [] }

    var body: some View {
        let slides = buildSlides()
        let index = slides.firstIndex { $0.id == position } ?? 0
        GeometryReader { geo in
            // Each page lays out between the timeline bar (and on the Mac the picker) at the top and the
            // play controls at the bottom, so nothing slides underneath them.
            let content = CGSize(width: geo.size.width, height: max(geo.size.height - TimelineBarMetrics.chromeTop - TimelineBarMetrics.chromeBottom, 240))
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(slides) { slide in
                        page(slide, size: content)
                            .frame(width: content.width, height: content.height)
                            .padding(.top, TimelineBarMetrics.chromeTop)
                            .padding(.bottom, TimelineBarMetrics.chromeBottom)
                            .frame(width: geo.size.width, height: geo.size.height)
                    }
                }
                .scrollTargetLayout()
            }
            // Free scrolling: the page in the middle of the window counts as the current one.
            .scrollPosition(id: $position, anchor: .center)
            .scrollIndicators(.hidden)
            .overlay(alignment: .top) { timelineBar(slides: slides, index: index) }
            .overlay(alignment: .topLeading) {
                // On the phone this lives in the navigation bar instead, to leave the page room.
                if Platform.isMac {
                    Picker("Show", selection: $ownedOnly) {
                        Text("Every watch").tag(false)
                        Text("Current").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .padding(.leading, 24)
                    .padding(.top, TimelineBarMetrics.height + 20)
                }
            }
            .overlay(alignment: .trailing) { yearRail(slides: slides, current: slides[safe: index]) }
            .overlay(alignment: .bottom) { controls(slides: slides, index: index) }
        }
        .background(WatchTheme.background)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.downArrow) { step(1, in: slides); return .handled }
        .onKeyPress(.rightArrow) { step(1, in: slides); return .handled }
        .onKeyPress(.upArrow) { step(-1, in: slides); return .handled }
        .onKeyPress(.leftArrow) { step(-1, in: slides); return .handled }
        .onKeyPress(.space) { playing.toggle(); return .handled }
        .onAppear {
            if position == nil { position = slides.first?.id }
            focused = true
        }
        .onChange(of: ownedOnly) { _, _ in
            playing = false
            position = "intro"
        }
        .task(id: playing) {
            // Play: move on a page every few seconds, and stop at the end.
            guard playing else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2.8))
                guard !Task.isCancelled else { return }
                let slides = buildSlides()
                let current = slides.firstIndex { $0.id == position } ?? 0
                if current >= slides.count - 1 { playing = false; return }
                step(1, in: slides)
            }
        }
        .navigationTitle("Purchase Timeline")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Show", selection: $ownedOnly) {
                        Text("Every watch").tag(false)
                        Text("Current").tag(true)
                    }
                } label: {
                    Text(ownedOnly ? "Current" : "Every watch")
                }
            }
        }
        #endif
    }

    // MARK: Building the story

    private func buildSlides() -> [TimelineSlide] {
        let entries = arrivals()
        guard let first = entries.first, let last = entries.last else { return [] }
        let numbers = catalogueNumbers(all)
        let grandTotal = entries.reduce(0) { $0 + cost(of: $1.watch, among: entries) }
        let label = "\(entries.count) \(entries.count == 1 ? "watch" : "watches")"
        var slides: [TimelineSlide] = [.intro(label: label, total: grandTotal, from: first.year, to: last.year, photos: Array(entries.suffix(9)))]
        var running = 0.0
        var number = 0
        for (year, group) in groupedByYear(entries) {
            let total = group.reduce(0) { $0 + cost(of: $1.watch, among: entries) }
            slides.append(.year(year, count: group.count, total: total, photos: Array(group.prefix(7)), sinceStart: number))
            for entry in group {
                number += 1
                running += cost(of: entry.watch, among: entries)
                slides.append(.purchase(entry, number: number, of: entries.count, runningTotal: running, catalogue: numbers[entry.watch.id]))
            }
        }
        slides.append(.outro(label: label, total: grandTotal, from: first.year, to: last.year))
        return slides
    }

    /// Every watch in the scope, in the order it arrived. A trade with no date of its own sits at the
    /// date of the watch it came from, as on the Collection cards.
    private func arrivals() -> [PurchaseTimelineEntry] {
        let monthNames = Calendar.current.shortMonthSymbols
        let scoped = ownedOnly ? all.filter { $0.status == "owned" } : all
        let dated: [Watch] = scoped.map { watch in
            var copy = watch
            let source = datedSource(watch, in: all)
            copy.purchased = source.purchased
            copy.purchasedText = source.purchasedText
            return copy
        }
        return acquisitionOrder(dated).compactMap { watch in
            guard let parts = purchaseMonthParts(watch.purchased), monthNames.indices.contains(parts.month - 1),
                  let original = scoped.first(where: { $0.id == watch.id })
            else { return nil }
            return PurchaseTimelineEntry(
                watch: original,
                source: original.isTrade ? all.first { $0.id == original.costSourceWatchID } : nil,
                sortKey: String(format: "%04d-%02d", parts.year, parts.month),
                month: monthNames[parts.month - 1],
                year: String(parts.year)
            )
        }
    }

    /// What a watch adds to the running total. A watch whose cost is already counted through another one
    /// (a trade's carried-over price, a piece of a lot) adds nothing, so the total matches Insights.
    private func cost(of watch: Watch, among entries: [PurchaseTimelineEntry]) -> Double {
        if let source = watch.costSourceWatchID, entries.contains(where: { $0.watch.id == source }) { return 0 }
        return watch.price
    }

    private func groupedByYear(_ entries: [PurchaseTimelineEntry]) -> [(String, [PurchaseTimelineEntry])] {
        var result: [(String, [PurchaseTimelineEntry])] = []
        for entry in entries {
            if result.last?.0 == entry.year { result[result.count - 1].1.append(entry) } else { result.append((entry.year, [entry])) }
        }
        return result
    }

    private func step(_ delta: Int, in slides: [TimelineSlide]) {
        guard !slides.isEmpty else { return }
        let current = slides.firstIndex { $0.id == position } ?? 0
        let next = min(max(current + delta, 0), slides.count - 1)
        withAnimation(.smooth(duration: 0.7)) { position = slides[next].id }
    }

    private func jump(to id: String) {
        withAnimation(.smooth(duration: 0.8)) { position = id }
    }

    // MARK: Pages

    @ViewBuilder
    private func page(_ slide: TimelineSlide, size: CGSize) -> some View {
        let wide = size.width >= 820
        switch slide {
        case let .intro(label, total, from, to, photos):
            VStack(spacing: 22) {
                Eyebrow(ownedOnly ? "The watches you own" : "Every watch you've bought")
                Text("\(from) – \(to)")
                    .font(.system(size: wide ? 92 : 56, weight: .bold))
                    .monospacedDigit()
                    .tracking(-0.6)
                    .foregroundStyle(WatchTheme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text("\(label) · \(cadWhole(total))")
                    .font(.title2.weight(.light))
                    .foregroundStyle(WatchTheme.muted)
                // Inside the page's padding, so the fan never runs off the edge or under the year rail.
                photoFan(photos, size: wide ? 92 : 58, maxWidth: size.width - 2 * (32 + (wide ? 0 : 16)))
                    .padding(.top, 18)
                Label(Platform.isMac ? "Scroll, use the arrow keys, or press play" : "Swipe up, or press play", systemImage: "chevron.down")
                    .font(.callout)
                    .foregroundStyle(WatchTheme.muted)
                    .padding(.top, 26)
            }
            .multilineTextAlignment(.center)
            .padding(32)
            // Clear the year rail on both sides so the centred title never runs under it.
            .padding(.horizontal, wide ? 0 : 16)
            .scrollTransition(.interactive, axis: .vertical) { content, phase in
                content
                    .opacity(1 - abs(phase.value) * 0.9)
                    .scaleEffect(1 - abs(phase.value) * 0.12)
                    .offset(y: phase.value * 160)
            }

        case let .year(year, count, total, photos, sinceStart):
            // A title card per year, on a square panel.
            VStack(spacing: 14) {
                Text(year)
                    .font(.system(size: wide ? 168 : 104, weight: .bold))
                    .monospacedDigit()
                    .tracking(-0.6)
                    .foregroundStyle(WatchTheme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .scrollTransition(.interactive, axis: .vertical) { content, phase in
                        content
                            .scaleEffect(1 + phase.value * 0.35)
                            .opacity(1 - abs(phase.value))
                    }
                Text("\(count) \(count == 1 ? "watch" : "watches") · \(cadWhole(total))")
                    .font(.title2.weight(.light))
                    .foregroundStyle(WatchTheme.muted)
                if sinceStart > 0 {
                    Text("\(sinceStart) before this")
                        .font(.callout)
                        .foregroundStyle(WatchTheme.muted)
                }
                // Inside the card: the card's own padding, and its insets from the page and the year rail.
                photoFan(photos, size: wide ? 84 : 52, maxWidth: min(wide ? 720 : .infinity, size.width - (wide ? 72 : 24) - (Platform.isMac ? 112 : 44)) - 48)
                    .padding(.top, 20)
                    .scrollTransition(.interactive, axis: .vertical) { content, phase in
                        content
                            .offset(y: phase.value * 240)
                            .opacity(1 - abs(phase.value) * 1.4)
                    }
            }
            .padding(.vertical, wide ? 56 : 40)
            .padding(.horizontal, 24)
            .frame(maxWidth: wide ? 720 : .infinity)
            .background(WatchTheme.card)
            .padding(.leading, wide ? 72 : 24)
            .padding(.trailing, Platform.isMac ? 112 : 44)
            .scrollTransition(.interactive, axis: .vertical) { content, phase in
                content.opacity(1 - abs(phase.value) * 0.8)
            }

        case let .purchase(entry, number, of, runningTotal, catalogue):
            purchasePage(entry, number: number, of: of, runningTotal: runningTotal, catalogue: catalogue, size: size, wide: wide)

        case let .outro(label, total, from, to):
            VStack(spacing: 18) {
                Eyebrow("That's the story so far")
                Text(label)
                    .font(.system(size: wide ? 92 : 56, weight: .bold))
                    .tracking(-0.6)
                    .foregroundStyle(WatchTheme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text("\(cadWhole(total)) from \(from) to \(to)")
                    .font(.title2.weight(.light))
                    .foregroundStyle(WatchTheme.muted)
                Button {
                    jump(to: "intro")
                } label: {
                    Label("Back to the start", systemImage: "arrow.up")
                }
                .quietButton()
                .padding(.top, 12)
            }
            .multilineTextAlignment(.center)
            .padding(32)
            .scrollTransition(.interactive, axis: .vertical) { content, phase in
                content.opacity(1 - abs(phase.value)).offset(y: phase.value * 140)
            }
        }
    }

    private func purchasePage(
        _ entry: PurchaseTimelineEntry,
        number: Int,
        of: Int,
        runningTotal: Double,
        catalogue: Int?,
        size: CGSize,
        wide: Bool
    ) -> some View {
        let watch = entry.watch
        // The year rail sits at the right edge, so the page keeps clear of it.
        let rail: CGFloat = Platform.isMac ? 112 : 44
        let inner = size.width - (wide ? 72 + rail : 24 + rail)
        let detailsWidth = wide ? min(440, max(300, inner * 0.42)) : inner
        let photoWidth = wide
            ? max(160, min(inner - detailsWidth - 56, size.height * 0.92 * PhotoShape.plate))
            : max(160, min(inner, size.height * 0.62 * PhotoShape.plate))
        let photoHeight = photoWidth / PhotoShape.plate
        // The photo takes whatever height the text leaves, up to its full size, keeping its shape.
        let photo = Color.clear
            .aspectRatio(PhotoShape.plate, contentMode: .fit)
            .frame(maxWidth: photoWidth, maxHeight: photoHeight)
            .overlay {
                RemoteWatchImage(
                    asset: watch.photos.first.flatMap { store.photoAsset(itemID: watch.id, filename: $0, wishlist: false) },
                    allowsRemoteFetch: !store.isOffline,
                    focus: watch.focus(for: watch.photos.first),
                    maxPixel: DisplayImageCache.page
                )
            }
            .clipped()
        .shadow(color: .black.opacity(0.4), radius: 30, y: 18)
        .background {
            // A soft glow in the dial's colour, so each page takes on the watch's character. As a
            // background it spreads past the photo without taking any room from the text.
            if let dial = watch.dialColor, dial != "Black", dial != "Other" {
                RadialGradient(colors: [dialColor(dial).opacity(0.32), .clear], center: .center, startRadius: 10, endRadius: photoHeight * 0.75)
                    .frame(width: photoWidth * 1.9, height: photoHeight * 1.3)
                    .blur(radius: 30)
                    .allowsHitTesting(false)
            }
        }
        .scrollTransition(.interactive, axis: .vertical) { content, phase in
            content
                .scaleEffect(1 - abs(phase.value) * 0.16)
                .offset(y: phase.value * 90)
                .opacity(1 - abs(phase.value) * 0.5)
        }

        let details = VStack(alignment: wide ? .leading : .center, spacing: 10) {
            Text("\(Text(catalogueLabel(catalogue)).foregroundStyle(WatchTheme.gold))\(Text(verbatim: " · \(number) of \(of)").foregroundStyle(WatchTheme.muted))")
                .font(AtelierType.kicker)
                .tracking(1.4)
            Text(purchaseShortLabel(watch, in: all) ?? "\(entry.month) \(entry.year)")
                .font(.title3.weight(.light))
                .foregroundStyle(WatchTheme.muted)
            Text(watch.name)
                .font(.system(size: wide ? 42 : 30, weight: .bold))
                .tracking(-0.6)
                .foregroundStyle(WatchTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(watch.price == 0 && watch.costSourceWatchID != nil ? "Part of a lot" : cad(watch.price))
                .font(.figure(.title))
                .foregroundStyle(WatchTheme.ink)
            HStack(spacing: 8) {
                if let category = watch.category { CapsuleChip(text: category) }
                if watch.original == false { CapsuleChip(text: "Replica") }
                if watch.status != "owned" { CapsuleChip(text: statusLabel(watch.status)) }
                if watch.isTrade { CapsuleChip(text: "Trade") }
            }
            if let source = entry.source {
                Text("Traded for, carrying over the \(source.name) purchase")
                    .font(.callout)
                    .foregroundStyle(WatchTheme.muted)
            }
            let story = watch.story.trimmingCharacters(in: .whitespacesAndNewlines)
            if !story.isEmpty {
                Text(story)
                    .font(AtelierType.body)
                    .foregroundStyle(WatchTheme.muted)
                    .lineLimit(wide ? 4 : 3)
                    .padding(.top, 4)
            }
            Text("\(number) \(number == 1 ? "watch" : "watches") and \(cadWhole(runningTotal)) so far")
                .font(.callout.weight(.semibold).monospacedDigit())
                .foregroundStyle(WatchTheme.ink)
                .padding(.top, 14)
        }
        .multilineTextAlignment(wide ? .leading : .center)
        .frame(width: detailsWidth, alignment: wide ? .leading : .center)
        .layoutPriority(1)
        // The text travels further than the photo, so the two separate as a page scrolls.
        .scrollTransition(.interactive, axis: .vertical) { content, phase in
            content
                .offset(y: phase.value * 240)
                .opacity(1 - abs(phase.value) * 1.3)
        }

        return Group {
            if wide {
                HStack(spacing: 56) {
                    photo
                    details
                }
                .padding(.leading, 72)
                .padding(.trailing, rail)
            } else {
                VStack(spacing: 22) {
                    photo
                    details
                }
                .padding(.leading, 24)
                .padding(.trailing, rail)
            }
        }
    }

    /// The photos overlapping like a hand of cards, each up to `size` square, smaller where `maxWidth` is too narrow
    /// for the whole fan (its tilt included).
    private func photoFan(_ entries: [PurchaseTimelineEntry], size: CGFloat, maxWidth: CGFloat) -> some View {
        let size = Self.fanTileSize(count: entries.count, preferred: size, maxWidth: maxWidth)
        return HStack(spacing: -size * 0.28) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                RemoteWatchImage(
                    asset: entry.watch.photos.first.flatMap { store.photoAsset(itemID: entry.watch.id, filename: $0, wishlist: false) },
                    allowsRemoteFetch: !store.isOffline,
                    focus: entry.watch.focus(for: entry.watch.photos.first),
                    maxPixel: DisplayImageCache.icon
                )
                .frame(width: size, height: size)
                .clipped()
                .overlay {
                    Rectangle()
                        .stroke(WatchTheme.background, lineWidth: 3)
                }
                .rotationEffect(.degrees(Double(index - entries.count / 2) * 4))
                .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
            }
        }
    }

    /// The fan's tiles overlap by 28% and the outermost tilt up to 16 degrees, which adds about a quarter of a
    /// tile to the fan's width.
    static func fanTileSize(count: Int, preferred: CGFloat, maxWidth: CGFloat) -> CGFloat {
        guard count > 0, maxWidth > 0 else { return preferred }
        let tiles = CGFloat(count) - 0.28 * CGFloat(count - 1) + 0.24
        return min(preferred, (maxWidth / tiles).rounded(.down))
    }

    // MARK: Chrome

    /// A time axis from the first arrival to the last: one dot per watch at its month (stacked when a month
    /// has several), lit once the presentation has passed it, with the month on screen under the playhead.
    /// Click or drag along it to jump.
    private func timelineBar(slides: [TimelineSlide], index: Int) -> some View {
        let entries = slides.compactMap { slide -> PurchaseTimelineEntry? in
            if case let .purchase(entry, _, _, _, _) = slide { return entry }
            return nil
        }
        let months = entries.map { monthNumber($0.sortKey) }
        let first = months.first ?? 0
        let span = Double(max((months.last ?? 0) - first, 1))
        var rows: [Int] = []
        var perMonth: [Int: Int] = [:]
        for month in months {
            rows.append(perMonth[month, default: 0])
            perMonth[month, default: 0] += 1
        }
        let step = min(6, TimelineBarMetrics.dotsHeight / CGFloat(max(perMonth.values.max() ?? 1, 1)))
        let state = barState(slides[safe: index], entries: entries, first: first)
        let lineY = TimelineBarMetrics.dotsHeight + 6

        return GeometryReader { geo in
            let width = geo.size.width
            let x = { (month: Int) -> CGFloat in CGFloat(Double(month - first) / span) * width }
            let head = x(state.month)
            ZStack(alignment: .topLeading) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { offset, entry in
                    let isCurrent = entry.id == state.currentID
                    Circle()
                        .fill(isCurrent || offset < state.lit ? WatchTheme.accent : WatchTheme.separator)
                        .frame(width: isCurrent ? 9 : 5, height: isCurrent ? 9 : 5)
                        .shadow(color: isCurrent ? WatchTheme.accent.opacity(0.6) : .clear, radius: 4)
                        .position(x: x(months[offset]), y: lineY - 10 - CGFloat(rows[offset]) * step)
                }
                Rectangle()
                    .fill(WatchTheme.separator)
                    .frame(width: width, height: 3)
                    .position(x: width / 2, y: lineY)
                Rectangle()
                    .fill(WatchTheme.accent)
                    .frame(width: max(head, 3), height: 3)
                    .position(x: max(head, 3) / 2, y: lineY)
                Circle()
                    .fill(WatchTheme.ink)
                    .frame(width: 9, height: 9)
                    .position(x: head, y: lineY)
                if let label = state.label {
                    Text(label)
                        .font(.callout.weight(.semibold).monospacedDigit())
                        .foregroundStyle(WatchTheme.ink)
                        .fixedSize()
                        .contentTransition(.numericText())
                        .position(x: min(max(head, 36), width - 36), y: lineY + 17)
                }
            }
            .frame(width: width, height: TimelineBarMetrics.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { drag in
                    guard !entries.isEmpty, width > 0 else { return }
                    let month = first + Int((Double(min(max(drag.location.x, 0), width) / width) * span).rounded())
                    let target = entries.indices.last { months[$0] <= month } ?? 0
                    playing = false
                    position = "watch-\(entries[target].id)"
                }
            )
            .animation(.smooth(duration: 0.5), value: index)
        }
        .frame(height: TimelineBarMetrics.height)
        .padding(.horizontal, Platform.isMac ? 28 : 18)
        .padding(.top, 12)
        .accessibilityElement()
        .accessibilityLabel("Timeline")
        .accessibilityValue(state.label ?? "")
    }

    /// How far along the bar is for a page: dots lit, the month the playhead sits at, and its label.
    private func barState(_ slide: TimelineSlide?, entries: [PurchaseTimelineEntry], first: Int)
        -> (lit: Int, month: Int, label: String?, currentID: String?) {
        switch slide {
        case let .purchase(entry, number, _, _, _):
            (number, monthNumber(entry.sortKey), "\(entry.month) \(entry.year)", entry.id)
        case let .year(year, _, _, _, sinceStart):
            (sinceStart, max(first, (Int(year) ?? 0) * 12), year, nil)
        case .outro:
            (entries.count, entries.last.map { monthNumber($0.sortKey) } ?? first, entries.last.map { "\($0.month) \($0.year)" }, nil)
        case .intro, nil:
            (0, first, nil, nil)
        }
    }

    private func monthNumber(_ key: String) -> Int {
        let parts = key.split(separator: "-")
        guard parts.count == 2, let year = Int(parts[0]), let month = Int(parts[1]) else { return 0 }
        return year * 12 + month - 1
    }

    private func yearRail(slides: [TimelineSlide], current: TimelineSlide?) -> some View {
        let years = slides.compactMap { slide -> String? in
            if case let .year(year, _, _, _, _) = slide { return year }
            return nil
        }
        let currentYear = current?.year
        return VStack(alignment: .trailing, spacing: Platform.isMac ? 8 : 5) {
            ForEach(years, id: \.self) { year in
                Button {
                    jump(to: "year-\(year)")
                } label: {
                    Text(year)
                        .font((Platform.isMac ? Font.callout : .caption2).monospacedDigit().weight(year == currentYear ? .bold : .regular))
                        .foregroundStyle(year == currentYear ? WatchTheme.ink : WatchTheme.muted)
                        .scaleEffect(year == currentYear ? 1.15 : 1, anchor: .trailing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Jump to \(year)")
            }
        }
        .animation(.smooth(duration: 0.3), value: currentYear)
        .padding(.trailing, Platform.isMac ? 24 : 8)
    }

    private func controls(slides: [TimelineSlide], index: Int) -> some View {
        HStack(spacing: 14) {
            Button { step(-1, in: slides) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(RoundControlStyle())
                .disabled(index == 0)
                .accessibilityLabel("Previous")
            Button { playing.toggle() } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(RoundControlStyle(prominent: true))
            .accessibilityLabel(playing ? "Pause" : "Play")
            Button { step(1, in: slides) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(RoundControlStyle())
                .disabled(index >= slides.count - 1)
                .accessibilityLabel("Next")
        }
        .padding(.bottom, Platform.isMac ? 24 : 12)
    }
}

/// The presentation's round controls: play in the green gradient, previous and next in the quiet fill.
private struct RoundControlStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.title3.weight(.semibold))
            .foregroundStyle(prominent ? Color.white : WatchTheme.ink)
            .frame(width: 52, height: 52)
            .background {
                if prominent {
                    Circle().fill(configuration.isPressed ? AnyShapeStyle(WatchTheme.accentDeep.opacity(0.9)) : AnyShapeStyle(WatchTheme.prominentGradient))
                } else {
                    Circle().fill(configuration.isPressed ? WatchTheme.raised : WatchTheme.fill)
                }
            }
            .contentShape(Circle())
            .opacity(isEnabled ? 1 : 0.4)
    }
}

private enum TimelineBarMetrics {
    /// Room for the stacked dots above the line; a month with many arrivals squeezes its stack to fit.
    static let dotsHeight: CGFloat = 30
    static let height: CGFloat = dotsHeight + 6 + 30
    /// Space kept clear above each page: the bar, plus the picker under it on the Mac.
    static var chromeTop: CGFloat { 12 + height + (Platform.isMac ? 20 + 32 + 16 : 8) }
    /// Space kept clear below each page for the play controls.
    static var chromeBottom: CGFloat { Platform.isMac ? 24 + 52 + 12 : 12 + 52 + 10 }
}

private enum TimelineSlide: Identifiable {
    case intro(label: String, total: Double, from: String, to: String, photos: [PurchaseTimelineEntry])
    case year(String, count: Int, total: Double, photos: [PurchaseTimelineEntry], sinceStart: Int)
    case purchase(PurchaseTimelineEntry, number: Int, of: Int, runningTotal: Double, catalogue: Int?)
    case outro(label: String, total: Double, from: String, to: String)

    var id: String {
        switch self {
        case .intro: "intro"
        case let .year(year, _, _, _, _): "year-\(year)"
        case let .purchase(entry, _, _, _, _): "watch-\(entry.id)"
        case .outro: "outro"
        }
    }

    /// The year a page belongs to, for the rail on the side.
    var year: String? {
        switch self {
        case let .year(year, _, _, _, _): year
        case let .purchase(entry, _, _, _, _): entry.year
        default: nil
        }
    }
}
