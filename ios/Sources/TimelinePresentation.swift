import SwiftUI

struct TimelineRoute: Hashable {
    let ownedOnly: Bool
}

/// The collection's history as a scroll-through presentation: a title card per year, then one page per
/// purchase with a large photo, while a counter keeps the running number and total spent. Scroll page by
/// page, use the arrow keys, click a year to jump, or press play to let it run.
struct TimelinePresentationScreen: View {
    @ObservedObject var store: AppStore
    let ownedOnly: Bool
    @State private var position: String?
    @State private var playing = false
    @FocusState private var focused: Bool

    private var all: [Watch] { store.data?.watches ?? [] }

    var body: some View {
        let slides = buildSlides()
        let index = slides.firstIndex { $0.id == position } ?? 0
        GeometryReader { geo in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(slides) { slide in
                        page(slide, size: geo.size)
                            .frame(width: geo.size.width, height: geo.size.height)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $position)
            .scrollIndicators(.hidden)
            .overlay(alignment: .top) { progressBar(index: index, count: slides.count) }
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
        .toolbar(.hidden, for: .tabBar)
        #endif
    }

    // MARK: Building the story

    private func buildSlides() -> [TimelineSlide] {
        let scoped = ownedOnly ? all.filter { $0.status == "owned" } : all
        let purchases = uniqueCostRecords(scoped).filter { watch in
            !watch.isTrade || all.contains(where: { $0.id == watch.costSourceWatchID })
        }
        let entries = purchaseTimelineEntries(purchases, all: all, by: .acquisition)
        guard let first = entries.first, let last = entries.last else { return [] }
        let numbers = catalogueNumbers(all)
        let grandTotal = entries.reduce(0) { $0 + $1.watch.price }
        var slides: [TimelineSlide] = [.intro(count: entries.count, total: grandTotal, from: first.year, to: last.year, photos: Array(entries.suffix(9)))]
        var running = 0.0
        var number = 0
        for (year, group) in groupedByYear(entries) {
            let total = group.reduce(0) { $0 + $1.watch.price }
            slides.append(.year(year, count: group.count, total: total, photos: Array(group.prefix(7)), sinceStart: number))
            for entry in group {
                number += 1
                running += entry.watch.price
                slides.append(.purchase(entry, number: number, of: entries.count, runningTotal: running, catalogue: numbers[entry.watch.id]))
            }
        }
        slides.append(.outro(count: entries.count, total: grandTotal, from: first.year, to: last.year))
        return slides
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
        let wide = size.width > 760
        switch slide {
        case let .intro(count, total, from, to, photos):
            VStack(spacing: 22) {
                Text(ownedOnly ? "The watches you own" : "Every watch you've bought")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("\(from) – \(to)")
                    .font(.system(size: wide ? 92 : 56, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("\(count) \(count == 1 ? "purchase" : "purchases") · \(cadWhole(total))")
                    .font(.title2.weight(.medium))
                    .foregroundStyle(.secondary)
                photoFan(photos, size: wide ? 92 : 58)
                    .padding(.top, 18)
                Label(Platform.isMac ? "Scroll, use the arrow keys, or press play" : "Swipe up, or press play", systemImage: "chevron.down")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 26)
            }
            .multilineTextAlignment(.center)
            .padding(32)
            .scrollTransition(.interactive, axis: .vertical) { content, phase in
                content
                    .opacity(1 - abs(phase.value) * 0.9)
                    .scaleEffect(1 - abs(phase.value) * 0.12)
                    .offset(y: phase.value * 160)
            }

        case let .year(year, count, total, photos, sinceStart):
            VStack(spacing: 14) {
                Text(year)
                    .font(.system(size: wide ? 168 : 104, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .scrollTransition(.interactive, axis: .vertical) { content, phase in
                        content
                            .scaleEffect(1 + phase.value * 0.35)
                            .opacity(1 - abs(phase.value))
                    }
                Text("\(count) \(count == 1 ? "watch" : "watches") · \(cadWhole(total))")
                    .font(.title2.weight(.medium))
                    .foregroundStyle(.secondary)
                if sinceStart > 0 {
                    Text("\(sinceStart) before this")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
                photoFan(photos, size: wide ? 84 : 52)
                    .padding(.top, 20)
                    .scrollTransition(.interactive, axis: .vertical) { content, phase in
                        content
                            .offset(y: phase.value * 240)
                            .opacity(1 - abs(phase.value) * 1.4)
                    }
            }
            .padding(32)

        case let .purchase(entry, number, of, runningTotal, catalogue):
            purchasePage(entry, number: number, of: of, runningTotal: runningTotal, catalogue: catalogue, size: size, wide: wide)

        case let .outro(count, total, from, to):
            VStack(spacing: 18) {
                Text("That's the story so far")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("\(count) watches")
                    .font(.system(size: wide ? 92 : 56, weight: .bold, design: .rounded))
                Text("\(cadWhole(total)) from \(from) to \(to)")
                    .font(.title2.weight(.medium))
                    .foregroundStyle(.secondary)
                Button {
                    jump(to: "intro")
                } label: {
                    Label("Back to the start", systemImage: "arrow.up")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
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
        let photoHeight = wide ? min(size.height * 0.74, size.width * 0.42 / PhotoShape.plate) : min(size.height * 0.5, (size.width - 48) / PhotoShape.plate)
        let photo = ZStack {
            // A soft glow in the dial's colour, so each page takes on the watch's character.
            if let dial = watch.dialColor, dial != "Black", dial != "Other" {
                RadialGradient(colors: [dialColor(dial).opacity(0.32), .clear], center: .center, startRadius: 10, endRadius: photoHeight * 0.75)
                    .frame(width: photoHeight * 1.5, height: photoHeight * 1.3)
                    .blur(radius: 30)
            }
            RemoteWatchImage(
                asset: watch.photos.first.flatMap { store.photoAsset(itemID: watch.id, filename: $0, wishlist: false) },
                allowsRemoteFetch: !store.isOffline,
                focus: watch.focus(for: watch.photos.first),
                maxPixel: DisplayImageCache.page
            )
            .frame(width: photoHeight * PhotoShape.plate, height: photoHeight)
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .shadow(color: .black.opacity(0.4), radius: 30, y: 18)
        }
        .scrollTransition(.interactive, axis: .vertical) { content, phase in
            content
                .scaleEffect(1 - abs(phase.value) * 0.16)
                .offset(y: phase.value * 90)
                .opacity(1 - abs(phase.value) * 0.5)
        }

        let details = VStack(alignment: wide ? .leading : .center, spacing: 10) {
            Text("\(catalogueLabel(catalogue)) · \(number) of \(of)")
                .font(.callout.weight(.semibold).monospacedDigit())
                .foregroundStyle(.tertiary)
            Text(purchaseShortLabel(watch, in: all) ?? "\(entry.month) \(entry.year)")
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)
            Text(watch.name)
                .font(.system(size: wide ? 42 : 30, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)
            Text(cad(watch.price))
                .font(.figure(.title))
            HStack(spacing: 8) {
                if let category = watch.category { CapsuleChip(text: category) }
                if watch.original == false { CapsuleChip(text: "Replica") }
                if watch.status != "owned" { CapsuleChip(text: statusLabel(watch.status)) }
                if watch.isTrade { CapsuleChip(text: "Trade") }
            }
            if let source = entry.source {
                Text("Traded for, carrying over the \(source.name) purchase")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            let story = watch.story.trimmingCharacters(in: .whitespacesAndNewlines)
            if !story.isEmpty {
                Text(story)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(wide ? 4 : 3)
                    .padding(.top, 4)
            }
            Text("\(number) \(number == 1 ? "watch" : "watches") and \(cadWhole(runningTotal)) so far")
                .font(.callout.weight(.semibold).monospacedDigit())
                .padding(.top, 14)
        }
        .multilineTextAlignment(wide ? .leading : .center)
        .frame(maxWidth: wide ? 440 : .infinity, alignment: wide ? .leading : .center)
        // The text travels further than the photo, so the two separate as a page scrolls.
        .scrollTransition(.interactive, axis: .vertical) { content, phase in
            content
                .offset(y: phase.value * 240)
                .opacity(1 - abs(phase.value) * 1.3)
        }

        return Group {
            if wide {
                HStack(spacing: 64) {
                    photo
                    details
                }
                .padding(.horizontal, 96)
            } else {
                VStack(spacing: 22) {
                    photo
                    details
                }
                .padding(.horizontal, 24)
            }
        }
    }

    private func photoFan(_ entries: [PurchaseTimelineEntry], size: CGFloat) -> some View {
        HStack(spacing: -size * 0.28) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                RemoteWatchImage(
                    asset: entry.watch.photos.first.flatMap { store.photoAsset(itemID: entry.watch.id, filename: $0, wishlist: false) },
                    allowsRemoteFetch: !store.isOffline,
                    focus: entry.watch.focus(for: entry.watch.photos.first),
                    maxPixel: DisplayImageCache.icon
                )
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                        .stroke(WatchTheme.background, lineWidth: 3)
                }
                .rotationEffect(.degrees(Double(index - entries.count / 2) * 4))
                .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
            }
        }
    }

    // MARK: Chrome

    private func progressBar(index: Int, count: Int) -> some View {
        GeometryReader { geo in
            Capsule()
                .fill(Color.primary.opacity(0.7))
                .frame(width: geo.size.width * CGFloat(index + 1) / CGFloat(max(count, 1)), height: 3)
                .animation(.smooth(duration: 0.5), value: index)
        }
        .frame(height: 3)
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
                        .foregroundStyle(year == currentYear ? Color.primary : Color.secondary.opacity(0.6))
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
        HStack(spacing: 10) {
            Button { step(-1, in: slides) } label: { Image(systemName: "chevron.up") }
                .disabled(index == 0)
                .accessibilityLabel("Previous")
            Button { playing.toggle() } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .contentTransition(.symbolEffect(.replace))
            }
            .accessibilityLabel(playing ? "Pause" : "Play")
            Button { step(1, in: slides) } label: { Image(systemName: "chevron.down") }
                .disabled(index >= slides.count - 1)
                .accessibilityLabel("Next")
        }
        .font(.title3.weight(.semibold))
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .padding(.bottom, Platform.isMac ? 24 : 12)
    }
}

private enum TimelineSlide: Identifiable {
    case intro(count: Int, total: Double, from: String, to: String, photos: [PurchaseTimelineEntry])
    case year(String, count: Int, total: Double, photos: [PurchaseTimelineEntry], sinceStart: Int)
    case purchase(PurchaseTimelineEntry, number: Int, of: Int, runningTotal: Double, catalogue: Int?)
    case outro(count: Int, total: Double, from: String, to: String)

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
