import Charts
import SwiftUI

struct StatsScreen: View {
    @ObservedObject var store: AppStore
    let showSettings: () -> Void
    @State private var scope = "owned"
    @State private var originalsOnly = true
    @State private var selectedWatch: Watch?
    @State private var completionQueue: [Watch] = []
    @State private var selectedCostTier: String?
    @State private var selectedSizeX: Double?
    @State private var selectedSpendYear: String?
    @State private var selectedLugWatchID: String?
    @State private var priceLedgerExpanded = false

    private var all: [Watch] { store.data?.watches ?? [] }
    private var owned: [Watch] { all.filter { $0.status == "owned" } }
    private var scoped: [Watch] { scope == "owned" ? owned : all }
    private var wrist: WristProfile { store.data?.settings.wrist ?? WristProfile(inches: 6, sweetSpotMin: 35, sweetSpotMax: 40, perfect: 38, lugMax: 47) }

    var body: some View {
        NavigationStack {
            RefreshableScreen(store: store) {
                ScrollView {
                    LazyVStack(spacing: 14) {
                        Picker("Scope", selection: $scope) {
                            Text("Current").tag("owned")
                            Text("All-time").tag("all")
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, 2)
                        headlineTiles
                        costChart
                        priceLedger
                        sizeChart
                        spendChart
                        lugChart
                        categoryCoverage
                        priceLadder
                        brandBreadth
                        varietyPanel(title: "Dial variety", field: \Watch.dialColor, values: store.data?.dialColors ?? [])
                        varietyPanel(title: "Material variety", field: \Watch.material, values: store.data?.materials ?? [])
                        completeData
                    }
                    .padding(14)
                    .padding(.bottom, 18)
                }
                .background(WatchTheme.background)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Collection Stats").font(.headline).serifTitle()
                }
                ToolbarItem(placement: .topBarTrailing) { GearToolbarButton(action: showSettings) }
            }
            .sheet(item: $selectedWatch, onDismiss: advanceCompletionQueue) { watch in
                WatchDetailScreen(store: store, watch: watch)
            }
            .onChange(of: scope) { _, _ in
                selectedCostTier = nil
                selectedSizeX = nil
                selectedSpendYear = nil
                selectedLugWatchID = nil
                priceLedgerExpanded = false
            }
        }
    }

    private var headlineTiles: some View {
        let stats = store.data?.headlineStats?[scope]
        let iqrRange = "\(cad(stats?.q1 ?? 0)) – \(cad(stats?.q3 ?? 0))"
        let measured = owned.filter { $0.diameter != nil }
        let inRange = measured.filter { watch in
            guard let diameter = watch.diameter else { return false }
            return wrist.sweetSpotMin...wrist.sweetSpotMax ~= diameter
        }.count
        let percent = measured.isEmpty ? 0 : Double(inRange) / Double(measured.count) * 100
        let values: [(String, String)] = [
            ("Count", "\(Int(stats?.count ?? 0))"),
            ("Total spent", cad(stats?.total ?? 0)),
            ("Mean", cad(stats?.mean ?? 0)),
            ("Median", cad(stats?.median ?? 0)),
            ("IQR (P25–P75)", iqrRange),
            ("Minimum", cad(stats?.min ?? 0)),
            ("Maximum", cad(stats?.max ?? 0)),
            ("Std dev", cad(stats?.stdDev ?? 0)),
            ("Sweet spot", "\(Int(percent.rounded()))%"),
        ]
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            ForEach(values, id: \.0) { label, value in
                VStack(alignment: .leading, spacing: 5) {
                    Text(label.uppercased())
                        .font(.caption2.weight(.bold))
                        .tracking(0.8)
                        .foregroundStyle(WatchTheme.secondary)
                    Text(value)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(label == "Total spent" ? WatchTheme.gold : .primary)
                        .minimumScaleFactor(0.75)
                }
                .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                .padding(13)
                .watchCard()
            }
        }
    }

    private var costChart: some View {
        let bins = costHistogram(scoped)
        let headline = store.data?.headlineStats?[scope]
        let medianX = headline.map { costReferencePosition($0.median, maximumPrice: $0.max) }
        let meanX = headline.map { costReferencePosition($0.mean, maximumPrice: $0.max) }
        return SectionCard(eyebrow: "Price tiers", title: "Cost histogram") {
            HStack(spacing: 6) {
                Capsule()
                    .fill(WatchTheme.gold.opacity(0.68))
                    .frame(width: 25, height: 2)
                Text("shape")
                    .font(.caption2)
                    .foregroundStyle(WatchTheme.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            Chart {
                ForEach(bins) { bin in
                    BarMark(
                        x: .value("Tier", bin.position),
                        y: .value("Watches", bin.count),
                        width: .ratio(0.68)
                    )
                    .foregroundStyle(selectedCostTier == bin.id ? WatchTheme.gold.gradient : WatchTheme.green.gradient)
                    .opacity(selectedCostTier == nil || selectedCostTier == bin.id ? 1 : 0.42)
                    .cornerRadius(3)
                    .accessibilityLabel(bin.label)
                    .accessibilityValue("\(bin.count) \(bin.count == 1 ? "watch" : "watches")")
                    .annotation(position: .top) {
                        if selectedCostTier == bin.id {
                            ChartAnnotationBubble(text: "\(bin.label) — \(bin.count) \(bin.count == 1 ? "watch" : "watches")")
                        }
                    }
                }
                ForEach(bins) { bin in
                    LineMark(
                        x: .value("Tier", bin.position),
                        y: .value("Shape", bin.count)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(WatchTheme.gold.opacity(0.68))
                    .lineStyle(StrokeStyle(lineWidth: 2))
                }
                if let medianX, let headline {
                    RuleMark(x: .value("Median", medianX))
                        .foregroundStyle(Color(red: 0.93, green: 0.90, blue: 0.82))
                        .lineStyle(StrokeStyle(lineWidth: 1.4))
                        .annotation(position: .top, alignment: .leading) {
                            Text("median \(cad(headline.median))")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(Color(red: 0.93, green: 0.90, blue: 0.82))
                                .fixedSize()
                        }
                }
                if let meanX, let headline {
                    RuleMark(x: .value("Mean", meanX))
                        .foregroundStyle(WatchTheme.gold)
                        .lineStyle(StrokeStyle(lineWidth: 1.4, dash: [6, 5]))
                        .annotation(position: .top, alignment: .leading) {
                            Text("mean \(cad(headline.mean))")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(WatchTheme.gold)
                                .fixedSize()
                                .offset(y: 15)
                        }
                }
            }
            .frame(height: 285)
            .chartXScale(domain: 0...Double(bins.count))
            .chartXAxis {
                AxisMarks(values: bins.map(\.position)) { value in
                    AxisGridLine().foregroundStyle(Color.white.opacity(0.05))
                    AxisTick().foregroundStyle(Color.white.opacity(0.14))
                    AxisValueLabel {
                        if let position = value.as(Double.self),
                           let bin = bins.min(by: { abs($0.position - position) < abs($1.position - position) }) {
                            Text(bin.axisLabel)
                                .font(.system(size: 8))
                        }
                    }
                }
            }
            .chartYAxisLabel("watches")
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Color.clear
                        .contentShape(Rectangle())
                        .highPriorityGesture(
                            SpatialTapGesture().onEnded { tap in
                                selectCostBar(at: tap.location, proxy: proxy, geometry: geometry, bins: bins)
                            }
                        )
                }
            }
            if let headline {
                Text("Mean \(cad(headline.mean)) vs median \(cad(headline.median)) — \(skewShape(headline.skewness)) (skew \(headline.skewness.formatted(.number.precision(.fractionLength(3)))))")
                    .font(.caption)
                    .foregroundStyle(WatchTheme.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var priceLedger: some View {
        let rows = ledgerRows(scoped)
        let grandTotal = rows.last?.subtotalCents ?? 0
        return SectionCard(eyebrow: "Total spent audit", title: "Price ledger") {
            DisclosureGroup(isExpanded: $priceLedgerExpanded) {
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(row.watch.name)
                                .font(.subheadline.weight(.medium))
                                .frame(maxWidth: .infinity, alignment: .leading)
                            VStack(alignment: .trailing, spacing: 3) {
                                Text(cad(row.watch.price))
                                    .font(.subheadline.monospacedDigit())
                                Text("subtotal \(cad(cents: row.subtotalCents))")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(WatchTheme.secondary)
                            }
                        }
                        .padding(.vertical, 9)
                        if row.id != rows.last?.id {
                            Divider().overlay(Color.white.opacity(0.06))
                        }
                    }
                    Divider().overlay(WatchTheme.gold.opacity(0.45))
                    HStack {
                        Text("Grand total")
                            .font(.headline)
                        Spacer()
                        Text(cad(cents: grandTotal))
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(WatchTheme.gold)
                    }
                    .padding(.top, 12)
                }
                .padding(.top, 8)
            } label: {
                HStack {
                    Text("Price ledger — tap to expand")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(rows.count) watches")
                        .font(.caption)
                        .foregroundStyle(WatchTheme.secondary)
                }
            }
            .tint(WatchTheme.gold)
        }
    }

    private var sizeChart: some View {
        let bins = histogram(scoped, keyPath: \Watch.diameter)
        let ceiling = max(1, bins.map(\.count).max() ?? 1)
        let selectedBin = selectedSizeX.flatMap { rawValue in
            bins.min(by: { abs($0.midpoint - rawValue) < abs($1.midpoint - rawValue) })
        }
        return SectionCard(eyebrow: "Diameter", title: "Size distribution") {
            Chart {
                RectangleMark(
                    xStart: .value("Sweet minimum", wrist.sweetSpotMin),
                    xEnd: .value("Sweet maximum", wrist.sweetSpotMax),
                    yStart: .value("Floor", 0),
                    yEnd: .value("Ceiling", ceiling)
                )
                .foregroundStyle(WatchTheme.green.opacity(0.16))
                ForEach(bins) { bin in
                    BarMark(
                        x: .value("Diameter", bin.midpoint),
                        y: .value("Watches", bin.count),
                        width: .fixed(13)
                    )
                    .foregroundStyle(selectedBin?.lower == bin.lower ? WatchTheme.gold.gradient : WatchTheme.green.gradient)
                    .opacity(selectedBin == nil || selectedBin?.lower == bin.lower ? 1 : 0.42)
                    .annotation(position: .top) {
                        if selectedBin?.lower == bin.lower {
                            ChartAnnotationBubble(text: "\(bin.label) — \(bin.count) \(bin.count == 1 ? "watch" : "watches")")
                        }
                    }
                }
                RuleMark(x: .value("Perfect", wrist.perfect))
                    .foregroundStyle(WatchTheme.gold)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4]))
            }
            .frame(height: 190)
            .chartXAxisLabel("mm · shaded \(compactNumber(wrist.sweetSpotMin))–\(compactNumber(wrist.sweetSpotMax)) sweet spot")
            .chartYAxisLabel("watches")
            .chartXSelection(value: $selectedSizeX)
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Color.clear
                        .contentShape(Rectangle())
                        .highPriorityGesture(
                            SpatialTapGesture().onEnded { tap in
                                selectSizeBar(at: tap.location, proxy: proxy, geometry: geometry, bins: bins)
                            }
                        )
                }
            }
        }
    }

    private var spendChart: some View {
        let values = spendByYear(scoped)
        return SectionCard(eyebrow: "Timeline", title: "Spend by year") {
            Chart(values) { point in
                BarMark(x: .value("Year", point.year), y: .value("CAD", point.total))
                    .foregroundStyle(selectedSpendYear == point.year ? WatchTheme.gold.gradient : WatchTheme.green.gradient)
                    .opacity(selectedSpendYear == nil || selectedSpendYear == point.year ? 1 : 0.42)
                    .cornerRadius(4)
                    .annotation(position: .top) {
                        if selectedSpendYear == point.year {
                            ChartAnnotationBubble(text: "\(point.year) — \(cad(point.total))")
                        }
                    }
            }
            .frame(height: 180)
            .chartYAxis { AxisMarks() }
            .chartXSelection(value: $selectedSpendYear)
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Color.clear
                        .contentShape(Rectangle())
                        .highPriorityGesture(
                            SpatialTapGesture().onEnded { tap in
                                selectSpendBar(at: tap.location, proxy: proxy, geometry: geometry, values: values)
                            }
                        )
                }
            }
        }
    }

    private var lugChart: some View {
        let measurements = scoped.compactMap { watch -> LugMeasurement? in
            guard let value = watch.lugToLug else { return nil }
            return LugMeasurement(watch: watch, value: value)
        }
        return SectionCard(eyebrow: "Wearability", title: "Lug-to-lug") {
            if measurements.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "ruler")
                        Text("No \(scope == "owned" ? "current" : "all-time") L2L measurements yet")
                        Spacer()
                    }
                    Chart {
                        RuleMark(x: .value("Comfort ceiling", wrist.lugMax))
                            .foregroundStyle(WatchTheme.amber)
                            .lineStyle(StrokeStyle(lineWidth: 2, dash: [4]))
                            .annotation(position: .top) { Text("\(compactNumber(wrist.lugMax))mm ceiling").font(.caption2).foregroundStyle(WatchTheme.amber) }
                    }
                    .chartXScale(domain: (wrist.lugMax - 10)...(wrist.lugMax + 5))
                    .frame(height: 62)
                }
                .font(.subheadline)
                .foregroundStyle(WatchTheme.secondary)
            } else {
                Chart(measurements) { measurement in
                    BarMark(x: .value("L2L", measurement.value), y: .value("Watch", measurement.id))
                        .foregroundStyle(selectedLugWatchID == measurement.id ? WatchTheme.gold.gradient : WatchTheme.green.gradient)
                        .opacity(selectedLugWatchID == nil || selectedLugWatchID == measurement.id ? 1 : 0.42)
                        .annotation(position: .trailing) {
                            if selectedLugWatchID == measurement.id {
                                ChartAnnotationBubble(text: "\(measurement.watch.name) — \(compactNumber(measurement.value))mm")
                            }
                        }
                    RuleMark(x: .value("Ceiling", wrist.lugMax))
                        .foregroundStyle(WatchTheme.amber)
                }
                .frame(height: 150)
                .chartYAxis(.hidden)
                .chartYSelection(value: $selectedLugWatchID)
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        Color.clear
                            .contentShape(Rectangle())
                            .highPriorityGesture(
                                SpatialTapGesture().onEnded { tap in
                                    selectLugBar(at: tap.location, proxy: proxy, geometry: geometry, values: measurements)
                                }
                            )
                    }
                }
            }
        }
    }

    private var categoryCoverage: some View {
        let categories = store.data?.categories ?? []
        let rows = categories.map { category -> CoverageRow in
            let current = owned.filter { $0.category == category }.count
            let lifetime = all.filter { $0.category == category }.count
            return CoverageRow(category: category, owned: current, allTime: lifetime)
        }.sorted { ($0.rank, categories.firstIndex(of: $0.category) ?? 0) < ($1.rank, categories.firstIndex(of: $1.category) ?? 0) }
        return SectionCard(eyebrow: "Buying guide", title: "Category coverage") {
            VStack(spacing: 0) {
                ForEach(rows) { row in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.category).font(.subheadline.weight(.semibold))
                            Text("\(row.owned) owned · \(row.allTime) all-time")
                                .font(.caption)
                                .foregroundStyle(WatchTheme.secondary)
                        }
                        Spacer()
                        CapsuleChip(text: row.verdict, color: row.owned == 0 ? WatchTheme.gold : row.owned >= 3 ? WatchTheme.amber : WatchTheme.green)
                    }
                    .padding(.vertical, 9)
                    if row.id != rows.last?.id { Divider().overlay(Color.white.opacity(0.06)) }
                }
            }
        }
    }

    private var priceLadder: some View {
        let basis = originalsOnly ? owned.filter { $0.original != false && $0.category != "Smartwatch" } : owned
        let tiers = PriceTier.all
        let gaps = biggestGaps(basis)
        return SectionCard(eyebrow: "Money-side buying guide", title: "Price ladder") {
            Toggle("Originals only", isOn: $originalsOnly)
                .font(.subheadline.weight(.semibold))
            VStack(spacing: 8) {
                ForEach(tiers) { tier in
                    let matches = basis.filter { tier.contains($0.price) }
                    HStack(alignment: .top) {
                        Text(tier.label).font(.subheadline.weight(.semibold)).frame(width: 88, alignment: .leading)
                        Text(matches.isEmpty ? "No owned watch" : matches.map(\.name).joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(WatchTheme.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if matches.isEmpty { CapsuleChip(text: "GAP", color: WatchTheme.gold) }
                    }
                }
            }
            if let first = gaps.first {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Biggest hole: nothing between \(cad(first.low.price)) and \(cad(first.high.price))")
                    if gaps.count > 1 {
                        Text("Second hole: nothing between \(cad(gaps[1].low.price)) and \(cad(gaps[1].high.price))")
                    }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(WatchTheme.gold)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(WatchTheme.gold.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private var brandBreadth: some View {
        let realAll = all.filter { $0.original != false && normalizedBrand($0) != "Generic" }
        let realOwned = realAll.filter { $0.status == "owned" }
        let current = counts(realOwned.map(normalizedBrand))
        let lifetime = counts(realAll.map(normalizedBrand))
        let letGo = lifetime.filter { current[$0.key] == nil }.sorted { $0.value > $1.value }
        return SectionCard(eyebrow: "Explore before repeating", title: "Brand breadth") {
            Text("\(current.count) unique brands / \(owned.count) watches owned · \(lifetime.count) explored all-time")
                .font(.subheadline.weight(.semibold))
            ForEach(current.sorted { $0.value > $1.value }, id: \.key) { brand, count in
                HStack {
                    Text(brand)
                    Spacer()
                    Text("\(count)").foregroundStyle(WatchTheme.secondary)
                    if count >= 2 { CapsuleChip(text: "saturated", color: WatchTheme.amber) }
                }
                .font(.subheadline)
            }
            if !letGo.isEmpty {
                Text("Explored & let go")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(WatchTheme.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack { ForEach(letGo, id: \.key) { CapsuleChip(text: "\($0.key) · \($0.value)") } }
                }
            }
            if let radar = store.data?.brandWatchlist, !radar.isEmpty {
                Text("Brands on radar")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(WatchTheme.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack { ForEach(radar, id: \.brand) { CapsuleChip(text: $0.brand, color: WatchTheme.gold) } }
                }
            }
        }
    }

    private func varietyPanel(title: String, field: KeyPath<Watch, String?>, values: [String]) -> some View {
        let current = counts(owned.compactMap { $0[keyPath: field] })
        return SectionCard(eyebrow: "Variety", title: title) {
            ForEach(values, id: \.self) { value in
                let count = current[value] ?? 0
                HStack {
                    if field == \Watch.dialColor { Circle().fill(dialColor(value)).frame(width: 10, height: 10) }
                    Text(value).font(.subheadline)
                    Spacer()
                    Text(count == 0 ? "not represented" : "\(count) owned")
                        .font(.caption)
                        .foregroundStyle(WatchTheme.secondary)
                    if count >= 2 { CapsuleChip(text: "saturated", color: WatchTheme.amber) }
                }
            }
        }
    }

    private var completeData: some View {
        let missing = owned.filter { $0.dialColor == nil || $0.material == nil || $0.lugToLug == nil }
        let dial = owned.filter { $0.dialColor == nil }.count
        let material = owned.filter { $0.material == nil }.count
        let lug = owned.filter { $0.lugToLug == nil }.count
        return SectionCard(eyebrow: "Collection quality", title: "Complete your data") {
            Text("\(dial) dial colours · \(material) materials · \(lug) lug-to-lug measurements missing")
                .font(.subheadline)
                .foregroundStyle(WatchTheme.secondary)
            Button("Fill in sequence") {
                guard let first = missing.first else { return }
                completionQueue = Array(missing.dropFirst())
                selectedWatch = first
            }
            .buttonStyle(.borderedProminent)
            .disabled(missing.isEmpty || store.isOffline)
        }
    }

    private func advanceCompletionQueue() {
        guard !completionQueue.isEmpty else { return }
        selectedWatch = completionQueue.removeFirst()
    }

    private func selectCostBar(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy, bins: [CostBin]) {
        guard let plotAnchor = proxy.plotFrame else {
            selectedCostTier = nil
            return
        }
        let plotFrame = geometry[plotAnchor]
        guard plotFrame.contains(location) else {
            selectedCostTier = nil
            return
        }
        let plotX = location.x - plotFrame.minX
        let plotY = location.y - plotFrame.minY
        guard let rawX = proxy.value(atX: plotX, as: Double.self),
              let rawY = proxy.value(atY: plotY, as: Double.self),
              let bin = bins.min(by: { abs($0.position - rawX) < abs($1.position - rawX) }),
              abs(bin.position - rawX) <= 0.34,
              rawY >= 0,
              rawY <= Double(bin.count)
        else {
            selectedCostTier = nil
            return
        }
        selectedCostTier = selectedCostTier == bin.id ? nil : bin.id
    }

    private func selectSizeBar(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy, bins: [MetricBin]) {
        guard let plotAnchor = proxy.plotFrame else {
            selectedSizeX = nil
            return
        }
        let plotFrame = geometry[plotAnchor]
        guard plotFrame.contains(location) else {
            selectedSizeX = nil
            return
        }
        let plotX = location.x - plotFrame.minX
        let plotY = location.y - plotFrame.minY
        guard let rawX = proxy.value(atX: plotX, as: Double.self),
              let rawY = proxy.value(atY: plotY, as: Double.self),
              let bin = bins.min(by: { abs($0.midpoint - rawX) < abs($1.midpoint - rawX) }),
              let barX = proxy.position(forX: bin.midpoint),
              abs(barX - plotX) <= 12,
              rawY >= 0,
              rawY <= Double(bin.count)
        else {
            selectedSizeX = nil
            return
        }
        let current = selectedSizeX.flatMap { value in
            bins.min(by: { abs($0.midpoint - value) < abs($1.midpoint - value) })
        }
        selectedSizeX = current?.lower == bin.lower ? nil : bin.midpoint
    }

    private func selectSpendBar(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy, values: [YearSpend]) {
        guard let plotAnchor = proxy.plotFrame else {
            selectedSpendYear = nil
            return
        }
        let plotFrame = geometry[plotAnchor]
        guard plotFrame.contains(location) else {
            selectedSpendYear = nil
            return
        }
        let plotX = location.x - plotFrame.minX
        let plotY = location.y - plotFrame.minY
        guard let year = proxy.value(atX: plotX, as: String.self),
              let point = values.first(where: { $0.year == year }),
              let rawY = proxy.value(atY: plotY, as: Double.self),
              let barX = proxy.position(forX: point.year),
              abs(barX - plotX) <= plotFrame.width / CGFloat(max(values.count, 1)) * 0.44,
              rawY >= 0,
              rawY <= point.total
        else {
            selectedSpendYear = nil
            return
        }
        selectedSpendYear = selectedSpendYear == point.year ? nil : point.year
    }

    private func selectLugBar(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy, values: [LugMeasurement]) {
        guard let plotAnchor = proxy.plotFrame else {
            selectedLugWatchID = nil
            return
        }
        let plotFrame = geometry[plotAnchor]
        guard plotFrame.contains(location) else {
            selectedLugWatchID = nil
            return
        }
        let plotX = location.x - plotFrame.minX
        let plotY = location.y - plotFrame.minY
        guard let watchID = proxy.value(atY: plotY, as: String.self),
              let measurement = values.first(where: { $0.id == watchID }),
              let rawX = proxy.value(atX: plotX, as: Double.self),
              rawX >= 0,
              rawX <= measurement.value
        else {
            selectedLugWatchID = nil
            return
        }
        selectedLugWatchID = selectedLugWatchID == measurement.id ? nil : measurement.id
    }
}

private struct MetricBin: Identifiable {
    var id: Double { lower }
    var lower: Double
    var count: Int
    var midpoint: Double { lower + 1 }
    var label: String { "\(compactNumber(lower))–\(compactNumber(lower + 1.9))mm" }
}

private func histogram(_ watches: [Watch], keyPath: KeyPath<Watch, Double?>) -> [MetricBin] {
    let grouped = Dictionary(grouping: watches.compactMap { $0[keyPath: keyPath] }) { floor($0 / 2) * 2 }
    return grouped.map { MetricBin(lower: $0.key, count: $0.value.count) }.sorted { $0.lower < $1.lower }
}

private struct CostBin: Identifiable {
    var id: String { tier.id }
    var tier: PriceTier
    var count: Int
    var label: String { tier.label }
    var index: Int
    var position: Double { Double(index) + 0.5 }
    var axisLabel: String {
        switch index {
        case 0: "<$50"
        case 1: "$50"
        case 2: "$100"
        case 3: "$200"
        case 4: "$300"
        case 5: "$500"
        case 6: "$750"
        case 7: "$1k"
        default: "$2.5k+"
        }
    }
}

private func costHistogram(_ watches: [Watch]) -> [CostBin] {
    PriceTier.all.enumerated().map { index, tier in
        CostBin(tier: tier, count: watches.filter { tier.contains($0.price) }.count, index: index)
    }
}

private func costReferencePosition(_ value: Double, maximumPrice: Double) -> Double {
    guard let index = PriceTier.all.firstIndex(where: { $0.contains(value) }) else { return 0.5 }
    let tier = PriceTier.all[index]
    let upper = tier.maximum ?? max(maximumPrice, tier.minimum + 1)
    let proportion = min(0.96, max(0.04, (value - tier.minimum) / (upper - tier.minimum)))
    return Double(index) + proportion
}

private func skewShape(_ skewness: Double) -> String {
    if skewness > 0.3 { return "right-skewed" }
    if skewness < -0.3 { return "left-skewed" }
    return "roughly symmetric"
}

private struct YearSpend: Identifiable {
    var id: String { year }
    var year: String
    var total: Double
}

private func spendByYear(_ watches: [Watch]) -> [YearSpend] {
    let grouped = Dictionary(grouping: watches.filter { $0.purchased != nil }) { String($0.purchased!.prefix(4)) }
    return grouped.map { YearSpend(year: $0.key, total: $0.value.reduce(0) { $0 + $1.price }) }.sorted { $0.year < $1.year }
}

private struct LugMeasurement: Identifiable {
    var id: String { watch.id }
    var watch: Watch
    var value: Double
}

private struct LedgerRow: Identifiable {
    var id: String { watch.id }
    var watch: Watch
    var subtotalCents: Int
}

private func ledgerRows(_ watches: [Watch]) -> [LedgerRow] {
    var subtotalCents = 0
    return watches.sorted {
        if $0.price == $1.price { return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return $0.price < $1.price
    }.map { watch in
        subtotalCents += Int(watch.price * 100)
        return LedgerRow(watch: watch, subtotalCents: subtotalCents)
    }
}

private struct ChartAnnotationBubble: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .foregroundStyle(WatchTheme.background)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(WatchTheme.gold)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.white.opacity(0.28), lineWidth: 0.5)
            }
    }
}

private struct CoverageRow: Identifiable {
    var id: String { category }
    var category: String
    var owned: Int
    var allTime: Int
    var rank: Int { owned == 0 ? 0 : owned == 1 ? 1 : owned == 2 ? 2 : 3 }
    var verdict: String { owned == 0 ? "GAP" : owned == 1 ? "thin" : owned == 2 ? "covered" : "well covered" }
}

private struct PriceTier: Identifiable {
    var id: String { label }
    var label: String
    var minimum: Double
    var maximum: Double?
    func contains(_ price: Double) -> Bool { price >= minimum && (maximum.map { price < $0 } ?? true) }

    static let all = [
        PriceTier(label: "<$50", minimum: 0, maximum: 50),
        PriceTier(label: "$50–100", minimum: 50, maximum: 100),
        PriceTier(label: "$100–200", minimum: 100, maximum: 200),
        PriceTier(label: "$200–300", minimum: 200, maximum: 300),
        PriceTier(label: "$300–500", minimum: 300, maximum: 500),
        PriceTier(label: "$500–750", minimum: 500, maximum: 750),
        PriceTier(label: "$750–1000", minimum: 750, maximum: 1000),
        PriceTier(label: "$1000–2500", minimum: 1000, maximum: 2500),
        PriceTier(label: "$2500+", minimum: 2500, maximum: nil),
    ]
}

private struct PriceGap {
    var low: Watch
    var high: Watch
    var amount: Double { high.price - low.price }
}

private func biggestGaps(_ watches: [Watch]) -> [PriceGap] {
    let sorted = watches.sorted { $0.price < $1.price }
    return zip(sorted, sorted.dropFirst())
        .map { PriceGap(low: $0.0, high: $0.1) }
        .sorted { $0.amount > $1.amount }
}

private func normalizedBrand(_ watch: Watch) -> String {
    watch.brand?.isEmpty == false ? watch.brand! : watch.name.split(separator: " ").first.map(String.init) ?? "Unknown"
}

private func counts(_ values: [String]) -> [String: Int] {
    values.reduce(into: [:]) { $0[$1, default: 0] += 1 }
}
