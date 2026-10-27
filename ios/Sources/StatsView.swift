import Charts
import SwiftUI

struct StatsScreen: View {
    @ObservedObject var store: AppStore
    let showSettings: () -> Void
    @State private var scope = "owned"
    @State private var originalsOnly = true
    @State private var selectedWatch: Watch?
    @State private var completionQueue: [Watch] = []
    @State private var savedInSequence = false
    @State private var selectedCostTier: String?
    @State private var selectedSizeX: Double?
    @State private var selectedSpendYear: String?
    @State private var selectedLugWatchID: String?
    @State private var priceLedgerExpanded = false

    private var all: [Watch] { store.data?.watches ?? [] }
    private var owned: [Watch] { all.filter { $0.status == "owned" } }
    private var scoped: [Watch] { scope == "owned" ? owned : all }
    private var costScoped: [Watch] { uniqueCostRecords(scoped) }
    private var wrist: WristProfile { store.data?.settings.wrist ?? WristProfile(inches: 6, sweetSpotMin: 35, sweetSpotMax: 40, perfect: 38, lugMax: 47) }

    var body: some View {
        NavigationStack {
            RefreshableScreen(store: store) {
                ScrollView {
                    LazyVStack(spacing: 22) {
                        ScreenHeader(eyebrow: "The numbers", title: "Insights")
                        PillPicker(options: [("owned", "Current"), ("all", "All-time")], selection: $scope)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        headlineTiles
                        maintenanceDashboard
                        costChart
                        priceLedger
                        sizeChart
                        spendChart
                        currentCollectionTimeline
                        lugChart
                        categoryCoverage
                        priceLadder
                        brandBreadth
                        varietyPanel(title: "Dial variety", field: \Watch.dialColor, values: store.data?.dialColors ?? [])
                        varietyPanel(title: "Material variety", field: \Watch.material, values: store.data?.materials ?? [])
                        completeData
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 6)
                    .padding(.bottom, 40)
                }
                .background(WatchTheme.background)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { GearToolbarButton(action: showSettings) }
            }
            .sheet(item: $selectedWatch, onDismiss: advanceCompletionQueue) { watch in
                WatchDetailScreen(store: store, watch: watch, onSaved: { savedInSequence = true })
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
        let measured = owned.filter { $0.diameter != nil }
        let inRange = measured.filter { watch in
            guard let diameter = watch.diameter else { return false }
            return diameter >= wrist.sweetSpotMin && diameter <= wrist.sweetSpotMax
        }.count
        let fraction = measured.isEmpty ? 0 : Double(inRange) / Double(measured.count)
        let count = Int(stats?.count ?? 0)
        let figures: [(String, String)] = [
            ("Mean", cadWhole(stats?.mean ?? 0)),
            ("Median", cadWhole(stats?.median ?? 0)),
            ("Std dev", cadWhole(stats?.stdDev ?? 0)),
            ("Lowest", cadWhole(stats?.min ?? 0)),
            ("Highest", cadWhole(stats?.max ?? 0)),
            ("Middle 50%", "\(cadWhole(stats?.q1 ?? 0))–\(cadWhole(stats?.q3 ?? 0))"),
        ]
        return VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Eyebrow(scope == "owned" ? "Current collection" : "All-time")
                Text(cad(stats?.total ?? 0))
                    .font(.display(46))
                    .foregroundStyle(WatchTheme.gold)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                Text("spent across \(count) watch\(count == 1 ? "" : "es")")
                    .font(.subheadline)
                    .foregroundStyle(WatchTheme.secondary)
            }

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("In your \(compactNumber(wrist.sweetSpotMin))–\(compactNumber(wrist.sweetSpotMax))mm sweet spot")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(WatchTheme.ivory)
                    Spacer()
                    Text("\(inRange) of \(measured.count)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(WatchTheme.gold)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.07))
                        Capsule()
                            .fill(LinearGradient(colors: [WatchTheme.goldDeep, WatchTheme.gold], startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(6, geo.size.width * fraction))
                    }
                }
                .frame(height: 6)
            }

            Rectangle().fill(WatchTheme.hairline).frame(height: 1)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3), alignment: .leading, spacing: 16) {
                ForEach(figures, id: \.0) { label, value in
                    VStack(alignment: .leading, spacing: 4) {
                        Eyebrow(label, color: WatchTheme.secondary)
                        Text(value)
                            .font(.display(16))
                            .foregroundStyle(WatchTheme.ivory)
                            .minimumScaleFactor(0.6)
                            .lineLimit(1)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .watchCard(cornerRadius: 22)
    }

    private var maintenanceDashboard: some View {
        let records = owned.flatMap { watch in serviceRecords(for: watch).map { (watch, $0) } }
        let totalCost = records.compactMap { $0.1.cost }.reduce(0, +)
        let dueItems = serviceDueItems(owned)
        let overdueCount = dueItems.filter { $0.daysUntilDue < 0 }.count
        return SectionCard(eyebrow: "Ownership", title: "Service & maintenance") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 9) {
                ActivityMetricTile(label: "Service records", value: "\(records.count)")
                ActivityMetricTile(label: "Maintenance spent", value: cad(totalCost))
                ActivityMetricTile(label: "Reminders", value: "\(dueItems.count)")
                ActivityMetricTile(label: "Overdue", value: "\(overdueCount)", warning: overdueCount > 0)
            }

            if dueItems.isEmpty {
                Text("Add a service record with a next-due date to see reminders here.")
                    .font(.subheadline)
                    .foregroundStyle(WatchTheme.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(dueItems.prefix(6)) { item in
                        Button {
                            selectedWatch = item.watch
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Image(systemName: item.daysUntilDue < 0 ? "exclamationmark.circle.fill" : "bell")
                                    .foregroundStyle(item.daysUntilDue < 0 ? WatchTheme.amber : WatchTheme.gold)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.watch.name)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    Text(item.record.kind)
                                        .font(.caption)
                                        .foregroundStyle(WatchTheme.secondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 3) {
                                    Text(calendarDayLabel(item.record.nextDue))
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(item.daysUntilDue < 0 ? WatchTheme.amber : WatchTheme.gold)
                                    Text(dueDistanceLabel(item.daysUntilDue))
                                        .font(.caption2)
                                        .foregroundStyle(WatchTheme.secondary)
                                }
                            }
                            .padding(.vertical, 9)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var costChart: some View {
        let bins = costHistogram(costScoped)
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
                        width: .fixed(24)
                    )
                    .foregroundStyle(selectedCostTier == bin.id ? WatchTheme.gold.gradient : WatchTheme.goldDeep.opacity(0.55).gradient)
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
        let rows = ledgerRows(costScoped)
        let grandTotal = rows.last?.subtotalCents ?? 0
        return SectionCard(eyebrow: "Total spent audit", title: "Price ledger") {
            if costScoped.count < scoped.count {
                Text("The original purchase cost carried through a trade is counted once.")
                    .font(.caption).foregroundStyle(WatchTheme.secondary)
            }
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
                .foregroundStyle(WatchTheme.gold.opacity(0.09))
                ForEach(bins) { bin in
                    BarMark(
                        x: .value("Diameter", bin.midpoint),
                        y: .value("Watches", bin.count),
                        width: .fixed(13)
                    )
                    .foregroundStyle(selectedBin?.lower == bin.lower ? WatchTheme.gold.gradient : WatchTheme.goldDeep.opacity(0.7).gradient)
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
            .chartXScale(domain: sizeDomain(bins))
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

    /// Frame the size chart around the actual watches and sweet spot instead of starting at 0mm.
    private func sizeDomain(_ bins: [MetricBin]) -> ClosedRange<Double> {
        let values = bins.filter { $0.count > 0 }.flatMap { [$0.lower, $0.lower + 2] } + [wrist.sweetSpotMin, wrist.sweetSpotMax]
        let lower = ((values.min() ?? 30) - 2).rounded(.down)
        let upper = ((values.max() ?? 50) + 2).rounded(.up)
        return lower...max(upper, lower + 1)
    }

    private var spendChart: some View {
        let values = spendByYear(scoped, all: all)
        let cumulative = cumulativeSpend(values)
        return SectionCard(eyebrow: "Timeline", title: "Acquisition spend") {
            Text("Annual spend")
                .font(.caption.weight(.bold))
                .foregroundStyle(WatchTheme.secondary)
            Chart(values) { point in
                BarMark(x: .value("Year", point.year), y: .value("CAD", point.total))
                    .foregroundStyle(selectedSpendYear == point.year ? WatchTheme.gold.gradient : WatchTheme.goldDeep.opacity(0.7).gradient)
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

            if !cumulative.isEmpty {
                Divider().overlay(Color.white.opacity(0.06))
                HStack {
                    Text("Acquisition basis over time")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(WatchTheme.secondary)
                    Spacer()
                    Text(cad(cumulative.last?.total ?? 0))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(WatchTheme.gold)
                }
                Chart(cumulative) { point in
                    AreaMark(
                        x: .value("Year", point.year),
                        y: .value("Cumulative CAD", point.total)
                    )
                    .foregroundStyle(WatchTheme.gold.opacity(0.12).gradient)
                    LineMark(
                        x: .value("Year", point.year),
                        y: .value("Cumulative CAD", point.total)
                    )
                    .foregroundStyle(WatchTheme.gold)
                    .lineStyle(StrokeStyle(lineWidth: 2.2))
                    PointMark(
                        x: .value("Year", point.year),
                        y: .value("Cumulative CAD", point.total)
                    )
                    .foregroundStyle(WatchTheme.gold)
                }
                .frame(height: 115)
                .chartYAxis { AxisMarks(values: .automatic(desiredCount: 3)) }
            }
        }
    }

    private var currentCollectionTimeline: some View {
        let purchases = uniqueCostRecords(scoped).filter { watch in
            !watch.isTrade || all.contains(where: { $0.id == watch.costSourceWatchID })
        }
        let entries = purchaseTimelineEntries(purchases, all: all)
        let datedIDs = Set(entries.map(\.id))
        let trades = scoped.filter { $0.isTrade && !datedIDs.contains($0.id) }
        let missingCount = purchases.count - entries.count
        return SectionCard(eyebrow: scope == "owned" ? "Current collection" : "All-time", title: "Purchase timeline") {
            if entries.isEmpty {
                ContentUnavailableView(
                    "No purchase dates yet",
                    systemImage: "calendar.badge.clock",
                    description: Text("Purchases with a known month appear here. Trades are listed separately.")
                )
                .foregroundStyle(WatchTheme.secondary)
            } else {
                HStack {
                    Label("\(entries.count) purchases", systemImage: "watch.analog")
                    Spacer()
                    Text("\(entries.first?.year ?? "") – \(entries.last?.year ?? "")")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(WatchTheme.secondary)

                VStack(spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        Button {
                            selectedWatch = entry.watch
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(entry.month.uppercased())
                                        .font(.caption2.weight(.bold))
                                        .tracking(0.7)
                                        .foregroundStyle(WatchTheme.gold)
                                    Text(entry.year)
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(WatchTheme.secondary)
                                }
                                .frame(width: 54, alignment: .trailing)

                                VStack(spacing: 0) {
                                    Circle()
                                        .fill(WatchTheme.gold)
                                        .frame(width: 10, height: 10)
                                        .overlay { Circle().stroke(WatchTheme.gold.opacity(0.25), lineWidth: 5) }
                                    if index < entries.count - 1 {
                                        Rectangle()
                                            .fill(WatchTheme.gold.opacity(0.28))
                                            .frame(width: 1)
                                            .frame(maxHeight: .infinity)
                                    }
                                }
                                .frame(width: 12)

                                VStack(alignment: .leading, spacing: 5) {
                                    Text(entry.watch.name)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                        .multilineTextAlignment(.leading)
                                    HStack(spacing: 8) {
                                        Text(cad(entry.watch.price))
                                            .foregroundStyle(WatchTheme.gold)
                                        if let category = entry.watch.category {
                                            Text(category)
                                                .foregroundStyle(WatchTheme.secondary)
                                        }
                                    }
                                    .font(.caption)
                                    if let source = entry.source {
                                        Text("Original \(source.name) purchase · \(source.purchasedText) · carried over through trade")
                                            .font(.caption).foregroundStyle(WatchTheme.secondary)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.bottom, index < entries.count - 1 ? 18 : 2)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(entry.watch.name), \(entry.source == nil ? "purchased" : "original purchase carried over") \(entry.month) \(entry.year)")
                        .accessibilityHint("Opens watch details")
                    }
                }

                if missingCount > 0 {
                    Label(
                        "\(missingCount) \(missingCount == 1 ? "watch is" : "watches are") missing a purchase month.",
                        systemImage: "exclamationmark.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(WatchTheme.amber)
                }
            }
            if !trades.isEmpty {
                Divider()
                Text("Acquired by trade")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(WatchTheme.secondary)
                ForEach(trades) { watch in
                    Button { selectedWatch = watch } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(watch.name).font(.subheadline.weight(.semibold))
                            Text(watch.costSourceWatchID == nil ? "No separate purchase" : "\(cad(watch.price)) original purchase cost carried over")
                                .font(.caption).foregroundStyle(WatchTheme.secondary)
                        }
                    }
                    .buttonStyle(.plain)
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
                        .foregroundStyle(selectedLugWatchID == measurement.id ? WatchTheme.gold.gradient : WatchTheme.goldDeep.opacity(0.7).gradient)
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

    /// Moves to the next incomplete watch only after a save; Close ends the sequence.
    private func advanceCompletionQueue() {
        defer { savedInSequence = false }
        guard savedInSequence, !completionQueue.isEmpty else {
            completionQueue = []
            return
        }
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

private struct ActivityMetricTile: View {
    let label: String
    let value: String
    var warning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Eyebrow(label, color: WatchTheme.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(value)
                .font(.display(22))
                .foregroundStyle(warning ? WatchTheme.amber : WatchTheme.ivory)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
        .padding(.horizontal, 13)
        .background(WatchTheme.raised.opacity(0.6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}


private struct ServiceDueItem: Identifiable {
    var id: String { "\(watch.id)-\(record.id)" }
    var watch: Watch
    var record: ServiceRecord
    var daysUntilDue: Int
}

private func serviceDueItems(_ watches: [Watch]) -> [ServiceDueItem] {
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())
    return watches.flatMap { watch -> [ServiceDueItem] in
        let latestByKind = Dictionary(grouping: serviceRecords(for: watch), by: \.kind).compactMap { _, records in
            records.max { left, right in
                if left.date == right.date { return left.id < right.id }
                return left.date < right.date
            }
        }
        return latestByKind.compactMap { record in
            guard let due = calendarDayDate(record.nextDue) else { return nil }
            let days = calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: due)).day ?? 0
            return ServiceDueItem(watch: watch, record: record, daysUntilDue: days)
        }
    }.sorted {
        if $0.daysUntilDue == $1.daysUntilDue {
            return $0.watch.name.localizedCaseInsensitiveCompare($1.watch.name) == .orderedAscending
        }
        return $0.daysUntilDue < $1.daysUntilDue
    }
}

private func dueDistanceLabel(_ days: Int) -> String {
    if days < -1 { return "\(-days) days overdue" }
    if days == -1 { return "1 day overdue" }
    if days == 0 { return "Due today" }
    if days == 1 { return "Due tomorrow" }
    return "In \(days) days"
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

private func cumulativeSpend(_ values: [YearSpend]) -> [YearSpend] {
    var runningTotal = 0.0
    return values.map { point in
        runningTotal += point.total
        return YearSpend(year: point.year, total: runningTotal)
    }
}

private struct PurchaseTimelineEntry: Identifiable {
    var id: String { watch.id }
    var watch: Watch
    var source: Watch?
    var sortKey: String
    var month: String
    var year: String
}

private func purchaseTimelineEntries(_ watches: [Watch], all: [Watch]) -> [PurchaseTimelineEntry] {
    let monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    return uniqueCostRecords(watches).compactMap { watch in
        let source = all.first { $0.id == watch.costSourceWatchID }
        guard !watch.isTrade || source != nil,
              let purchased = (source ?? watch).purchased else { return nil }
        let parts = purchased.split(separator: "-")
        guard parts.count >= 2,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              monthNames.indices.contains(month - 1)
        else { return nil }
        return PurchaseTimelineEntry(
            watch: watch,
            source: source,
            sortKey: String(format: "%04d-%02d", year, month),
            month: monthNames[month - 1],
            year: String(year)
        )
    }.sorted {
        // Keep collection order for purchases recorded in the same month.
        return $0.sortKey < $1.sortKey
    }
}

private func spendByYear(_ watches: [Watch], all: [Watch]) -> [YearSpend] {
    let grouped = Dictionary(grouping: purchaseTimelineEntries(watches, all: all), by: \.year)
    return grouped.map { YearSpend(year: $0.key, total: $0.value.reduce(0) { $0 + $1.watch.price }) }.sorted { $0.year < $1.year }
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
        subtotalCents += Int((watch.price * 100).rounded())
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
