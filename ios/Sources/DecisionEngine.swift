import Foundation

enum DecisionEngine {
    private struct PriceTier {
        let label: String
        let lower: Double
        let upper: Double
    }

    private static let priceTiers = [
        PriceTier(label: "<$50", lower: 0, upper: 50),
        PriceTier(label: "$50–100", lower: 50, upper: 100),
        PriceTier(label: "$100–200", lower: 100, upper: 200),
        PriceTier(label: "$200–300", lower: 200, upper: 300),
        PriceTier(label: "$300–500", lower: 300, upper: 500),
        PriceTier(label: "$500–750", lower: 500, upper: 750),
        PriceTier(label: "$750–1000", lower: 750, upper: 1_000),
        PriceTier(label: "$1000–2500", lower: 1_000, upper: 2_500),
        PriceTier(label: "$2500+", lower: 2_500, upper: .infinity),
    ]

    private static let defaultSuggestionExclusions = [
        "Smartwatch", "Other", "Iced Out", "Novelty", "Fashion/Minimalist",
    ]

    private static let plausibleDials: [String: [String]] = [
        "Pilot": ["Black", "White", "Blue", "Green"],
        "Dress": ["White", "Silver", "Cream", "Blue", "Green"],
        "Field": ["Green", "Cream", "Brown", "Black"],
        "GMT": ["Black", "Blue", "Green"],
        "Chronograph": ["White", "Black", "Blue"],
        "Integrated Bracelet": ["Blue", "Green", "Silver", "Grey"],
    ]

    private static let plausibleMaterials: [String: [String]] = [
        "Pilot": ["Titanium", "Bronze", "Ceramic", "Stainless Steel", "Carbon"],
        "Dress": ["Titanium", "Bronze", "Ceramic", "Stainless Steel", "Gold-plated/PVD", "Two-tone"],
        "Field": ["Titanium", "Bronze", "Ceramic", "Stainless Steel", "Carbon"],
        "GMT": ["Titanium", "Bronze", "Ceramic", "Stainless Steel"],
        "Chronograph": ["Titanium", "Bronze", "Ceramic", "Stainless Steel", "Carbon"],
        "Integrated Bracelet": ["Titanium", "Bronze", "Ceramic", "Stainless Steel"],
        "G-Shock/Digital": ["Titanium", "Ceramic", "Stainless Steel", "Carbon", "Plastic/Resin"],
        "Casual": ["Titanium", "Bronze", "Ceramic", "Stainless Steel", "Aluminum", "Plastic/Resin"],
    ]

    private static let brandPools: [String: [String]] = [
        "Field": ["Hamilton", "Baltic", "Zelos", "Straum", "Marathon"],
        "Pilot": ["Laco", "Stowa", "Hamilton", "Sinn", "IWC"],
        "GMT": ["Baltic", "Formex", "Zelos", "Lorier", "Longines"],
        "Integrated Bracelet": ["Tissot", "Formex", "Christopher Ward", "D1 Milano", "Citizen"],
        "Dress": ["Nomos", "Baltic", "Henry Archer", "Orient", "Junghans"],
        "Chronograph": ["Furlan Marri", "Dan Henry", "Baltic", "Seiko", "Omega"],
        "Dive": ["Zelos", "Baltic", "Christopher Ward", "Seiko"],
        "Casual": ["Casio", "Timex", "Swatch"],
        "G-Shock/Digital": ["Casio"],
    ]

    private static let brandStatusOrder = ["radar": 0, "new": 1, "explored": 2, "current": 3]

    static func withDerivedStats(_ data: CollectionData) -> CollectionData {
        var result = data
        result.headlineStats = [
            "owned": headlineStats(data.watches.filter { $0.status == "owned" }),
            "all": headlineStats(data.watches),
        ]
        return result
    }

    static func scores(for data: CollectionData) -> [String: WishlistScore] {
        Dictionary(uniqueKeysWithValues: data.wishlist.map { ($0.id, score($0, in: data)) })
    }

    static func score(_ item: WishlistItem, in data: CollectionData) -> WishlistScore {
        let owned = data.watches.filter { $0.status == "owned" }
        let ownedOriginals = originalsOnly(owned)
        var lenses: [String: LensScore] = [:]

        if let category = item.category {
            let count = owned.filter { $0.category == category }.count
            let points = count == 0 ? 3 : count == 1 ? 2 : count == 2 ? 1 : 0
            let detail = count == 0 ? "you've never owned one" : "\(count) owned"
            lenses["category"] = LensScore(score: points, reason: "\(category) — \(detail)")
        } else {
            lenses["category"] = LensScore(score: 0, reason: "category unset")
        }

        let brand = item.brand.isEmpty ? brandFor(item.name) : item.brand
        let currentBrands = brandCounts(owned)
        let pastBrands = brandCounts(data.watches.filter { $0.status != "owned" })
        let currentCount = currentBrands[brand, default: 0]
        if currentCount >= 2 {
            lenses["brand"] = LensScore(score: -1, reason: "\(brand) — \(currentCount) currently owned")
        } else if currentCount == 1 {
            lenses["brand"] = LensScore(score: 0, reason: "\(brand) — currently owned")
        } else if pastBrands[brand, default: 0] > 0 {
            lenses["brand"] = LensScore(score: 1, reason: "\(brand) — explored before, none kept")
        } else {
            lenses["brand"] = LensScore(score: 2, reason: "\(brand) — new brand")
        }

        if let tier = priceTier(item.priceExpected) {
            let allCount = owned.filter { priceTier($0.price) == tier }.count
            let originalsCount = ownedOriginals.filter { priceTier($0.price) == tier }.count
            if originalsCount == 0 {
                lenses["price"] = LensScore(score: 2, reason: "fills empty \(tier) originals-only tier")
            } else if allCount == 0 {
                lenses["price"] = LensScore(score: 1, reason: "fills empty \(tier) all-owned tier")
            } else {
                lenses["price"] = LensScore(score: 0, reason: "\(tier) tier already represented")
            }
        } else {
            lenses["price"] = LensScore(score: 0, reason: "price unset")
        }

        if let dial = item.dialColor {
            let count = owned.filter { $0.dialColor == dial }.count
            let points = count == 0 ? 2 : count == 1 ? 1 : 0
            let detail = count == 0 ? "not represented" : "\(count) owned"
            lenses["dial"] = LensScore(score: points, reason: "\(dial) dial — \(detail)")
        } else {
            lenses["dial"] = LensScore(score: 0, reason: "dial colour unset")
        }

        let fit = fitInfo(diameter: item.diameter, lugToLug: item.lugToLug, wrist: data.settings.wrist)
        lenses["size"] = LensScore(score: fit.score, reason: fit.label.isEmpty ? "size unset" : fit.label)

        if let material = item.material {
            let count = owned.filter { $0.material == material }.count
            let points = count == 0 ? 2 : count == 1 ? 1 : 0
            let detail = count == 0 ? "not represented" : "\(count) owned"
            lenses["material"] = LensScore(score: points, reason: "\(material) — \(detail)")
        } else {
            lenses["material"] = LensScore(score: 0, reason: "material unset")
        }

        return WishlistScore(total: lenses.values.reduce(0) { $0 + $1.score }, max: 14, lenses: lenses)
    }

    static func suggestions(for data: CollectionData) -> SuggestionsResponse {
        let owned = data.watches.filter { $0.status == "owned" }
        let categoryCounts = counts(owned.compactMap(\.category))
        let dialCounts = counts(owned.compactMap(\.dialColor))
        let currentBrandCounts = brandCounts(owned)

        let saturated = SaturatedAreas(
            categories: categoryCounts.keys.filter { categoryCounts[$0, default: 0] >= 3 }.sorted {
                let left = categoryCounts[$0, default: 0]
                let right = categoryCounts[$1, default: 0]
                if left != right { return left > right }
                let leftIndex = data.categories.firstIndex(of: $0) ?? data.categories.count
                let rightIndex = data.categories.firstIndex(of: $1) ?? data.categories.count
                return leftIndex == rightIndex ? $0 < $1 : leftIndex < rightIndex
            },
            dials: dialCounts.keys.filter { dialCounts[$0, default: 0] >= 2 }.sorted {
                let left = dialCounts[$0, default: 0]
                let right = dialCounts[$1, default: 0]
                if left != right { return left > right }
                let leftIndex = data.dialColors.firstIndex(of: $0) ?? data.dialColors.count
                let rightIndex = data.dialColors.firstIndex(of: $1) ?? data.dialColors.count
                return leftIndex == rightIndex ? $0 < $1 : leftIndex < rightIndex
            },
            brands: currentBrandCounts.keys.filter { currentBrandCounts[$0, default: 0] >= 2 }.sorted {
                let left = currentBrandCounts[$0, default: 0]
                let right = currentBrandCounts[$1, default: 0]
                return left == right ? $0 < $1 : left > right
            }
        )

        let excluded = Set(data.settings.suggestExclude ?? defaultSuggestionExclusions)
        let ownedDials = Set(dialCounts.keys)
        let ownedMaterials = Set(owned.compactMap(\.material))
        let occupiedTiers = Set(originalsOnly(owned).compactMap { priceTier($0.price) })
        let emptyTiers = priceTiers.filter { !occupiedTiers.contains($0.label) }
        let priceGap = emptyTiers.first { $0.lower >= 200 } ?? emptyTiers.first
        let wrist = data.settings.wrist
        let sizeGuidance = "\(number(wrist.sweetSpotMin))–\(number(wrist.sweetSpotMax))mm, lug-to-lug ≤\(number(wrist.lugMax))mm"
        let allTimeCategoryCounts = counts(data.watches.compactMap(\.category))

        var usedMaterials = Set<String>()
        var rows: [(score: Int, index: Int, suggestion: NextMoveSuggestion)] = []
        for (index, category) in data.categories.enumerated() {
            let currentCount = categoryCounts[category, default: 0]
            guard !excluded.contains(category), currentCount < 2 else { continue }

            let dials = (plausibleDials[category] ?? data.dialColors)
                .filter { data.dialColors.contains($0) && !ownedDials.contains($0) }
                .prefix(2)
            let defaults = ["Titanium", "Bronze", "Ceramic", "Stainless Steel"] + data.materials
            let materialPool = plausibleMaterials[category] ?? orderedUnique(defaults)
            let freshMaterials = materialPool.filter { data.materials.contains($0) && !ownedMaterials.contains($0) }
            let material = freshMaterials.first { !usedMaterials.contains($0) } ?? freshMaterials.first
            if let material { usedMaterials.insert(material) }

            let dialList = Array(dials)
            let categoryScore = currentCount == 0 ? 3 : 2
            let dialScore = dialList.isEmpty ? 0 : 2
            let materialScore = material == nil ? 0 : 2
            let priceScore = priceGap == nil ? 0 : 2
            var reasons: [String] = []
            let noun = category == category.uppercased() ? category : category.lowercased()
            let allTimeCount = allTimeCategoryCounts[category, default: 0]
            if currentCount == 0, allTimeCount == 0 {
                reasons.append("You've never owned a \(noun) watch")
            } else if currentCount == 0 {
                reasons.append("No \(noun) watch is currently owned; \(allTimeCount) explored before")
            } else {
                reasons.append("Only \(currentCount) \(noun) watch is currently owned")
            }
            reasons.append(contentsOf: dialList.map { "\($0) dial — not represented among current watches" })
            if let material { reasons.append("\(material) would be a first material in the current collection") }
            if let priceGap { reasons.append("\(priceGap.label) originals-only tier is empty") }
            let brands = recommendedBrands(category: category, data: data)
            let radarNames = brands.filter { $0.status == "radar" }.map(\.name)
            if !radarNames.isEmpty {
                let phrase: String
                if radarNames.count == 1 { phrase = radarNames[0] }
                else if radarNames.count == 2 { phrase = radarNames.joined(separator: " and ") }
                else { phrase = radarNames.dropLast().joined(separator: ", ") + ", and " + radarNames.last! }
                reasons.append("\(phrase) \(radarNames.count == 1 ? "is" : "are") already on your radar")
            }

            let dialPhrase = dialList.map { $0.lowercased() }.joined(separator: " or ")
            let headline = [
                material.map { "\($0) \(noun)" } ?? noun,
                dialPhrase.isEmpty ? nil : "\(dialPhrase) dial",
                sizeGuidance,
            ].compactMap { $0 }.joined(separator: ", ")
            let total = categoryScore + dialScore + materialScore + priceScore
            let matches = data.wishlist.filter { $0.status == "considering" && $0.category == category }.map(\.id)
            rows.append((total, index, NextMoveSuggestion(
                headline: headline,
                category: category,
                dialColors: dialList,
                material: material,
                sizeGuidance: sizeGuidance,
                priceTier: priceGap?.label,
                score: total,
                reasons: reasons,
                wishlistMatches: matches,
                brands: brands
            )))
        }

        rows.sort { $0.score == $1.score ? $0.index < $1.index : $0.score > $1.score }
        return SuggestionsResponse(saturated: saturated, suggestions: rows.prefix(5).map(\.suggestion))
    }

    private static func headlineStats(_ watches: [Watch]) -> HeadlineStatsPayload {
        let prices = uniqueCostRecords(watches).map(\.price).sorted()
        guard !prices.isEmpty else {
            return HeadlineStatsPayload(count: 0, total: 0, mean: 0, median: 0, iqr: 0, q1: 0, q3: 0, min: 0, max: 0, stdDev: 0, skewness: 0)
        }
        let total = prices.reduce(0, +)
        let count = Double(prices.count)
        let mean = total / count
        let variance = prices.count > 1 ? prices.reduce(0) { $0 + pow($1 - mean, 2) } / Double(prices.count - 1) : 0
        let deviation = sqrt(variance)
        let skewness: Double
        if prices.count > 2, deviation > 0 {
            let n = Double(prices.count)
            skewness = n / ((n - 1) * (n - 2)) * prices.reduce(0) { $0 + pow(($1 - mean) / deviation, 3) }
        } else {
            skewness = 0
        }
        let q1 = percentile(prices, percent: 25)
        let q3 = percentile(prices, percent: 75)
        return HeadlineStatsPayload(
            count: Double(watches.count),
            total: total,
            mean: mean,
            median: percentile(prices, percent: 50),
            iqr: q3 - q1,
            q1: q1,
            q3: q3,
            min: prices.first ?? 0,
            max: prices.last ?? 0,
            stdDev: deviation,
            skewness: skewness
        )
    }

    private static func percentile(_ values: [Double], percent: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let position = Double(values.count - 1) * percent / 100
        let lower = Int(floor(position))
        let upper = Int(ceil(position))
        guard lower != upper else { return values[lower] }
        return values[lower] + (values[upper] - values[lower]) * (position - Double(lower))
    }

    private static func originalsOnly(_ watches: [Watch]) -> [Watch] {
        watches.filter { $0.original != false && $0.category != "Smartwatch" }
    }

    private static func brandBreadthWatches(_ watches: [Watch]) -> [Watch] {
        watches.filter { $0.original != false && watchBrand($0) != "Generic" }
    }

    private static func brandCounts(_ watches: [Watch]) -> [String: Int] {
        counts(brandBreadthWatches(watches).map(watchBrand))
    }

    private static func watchBrand(_ watch: Watch) -> String {
        let stored = watch.brand?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stored.isEmpty ? brandFor(watch.name) : stored
    }

    private static func brandFor(_ name: String) -> String {
        let specialCases = [
            ("Audemars Piguet", "Audemars Piguet"), ("Miss Fox", "Miss Fox"),
            ("U.S. Polo Assn.", "U.S. Polo Assn."), ("Omega Moonswatch", "Omega"),
            ("Moonswatch", "Omega"), ("Casio G-Shock", "Casio"), ("Casio G-Steel", "Casio"),
            ("Christopher Ward", "Christopher Ward"), ("D1 Milano", "D1 Milano"),
            ("Henry Archer", "Henry Archer"), ("Furlan Marri", "Furlan Marri"),
            ("Dan Henry", "Dan Henry"), ("Rolex", "Rolex"),
        ]
        for (prefix, brand) in specialCases where name.lowercased().hasPrefix(prefix.lowercased()) { return brand }
        return name.split(separator: " ").first.map(String.init) ?? "Unknown"
    }

    private static func priceTier(_ value: Double?) -> String? {
        guard let value else { return nil }
        return priceTiers.first { value >= $0.lower && value < $0.upper }?.label
    }

    private static func fitInfo(diameter: Double?, lugToLug: Double?, wrist: WristProfile) -> (score: Int, label: String) {
        if let lugToLug {
            if lugToLug <= wrist.lugMax - 1 { return (3, "great fit · \(number(lugToLug)) L2L") }
            if lugToLug <= wrist.lugMax { return (2, "at the limit · \(number(lugToLug)) L2L") }
            return (0, "+\(number(lugToLug - wrist.lugMax))mm L2L over")
        }
        guard let diameter else { return (0, "") }
        if abs(diameter - wrist.perfect) <= 1 { return (3, "perfect · \(number(diameter))mm") }
        if diameter >= wrist.sweetSpotMin, diameter <= wrist.sweetSpotMax { return (2, "sweet spot · \(number(diameter))mm") }
        if diameter >= wrist.sweetSpotMin - 1, diameter < wrist.sweetSpotMin { return (1, "−\(number(wrist.sweetSpotMin - diameter))mm under") }
        if diameter > wrist.sweetSpotMax, diameter <= wrist.sweetSpotMax + 1 { return (1, "+\(number(diameter - wrist.sweetSpotMax))mm over") }
        if diameter < wrist.sweetSpotMin { return (0, "−\(number(wrist.sweetSpotMin - diameter))mm under") }
        return (0, "+\(number(diameter - wrist.sweetSpotMax))mm over")
    }

    private static func recommendedBrands(category: String, data: CollectionData) -> [SuggestedBrand] {
        guard let pool = brandPools[category] else { return [] }
        let currentCounts = brandCounts(data.watches.filter { $0.status == "owned" })
        let pastCounts = brandCounts(data.watches.filter { $0.status != "owned" })
        let radar = Set(data.brandWatchlist.map { $0.brand.lowercased() })
        func count(_ counts: [String: Int], brand: String) -> Int {
            counts.reduce(0) { $0 + ($1.key.caseInsensitiveCompare(brand) == .orderedSame ? $1.value : 0) }
        }
        return pool.enumerated().compactMap { index, brand -> (Int, Int, SuggestedBrand)? in
            let current = count(currentCounts, brand: brand)
            guard current < 2 else { return nil }
            let status: String
            if radar.contains(brand.lowercased()) { status = "radar" }
            else if current == 1 { status = "current" }
            else if count(pastCounts, brand: brand) > 0 { status = "explored" }
            else { status = "new" }
            return (brandStatusOrder[status] ?? 99, index, SuggestedBrand(name: brand, status: status))
        }.sorted {
            $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0
        }.prefix(4).map(\.2)
    }

    private static func counts(_ values: [String]) -> [String: Int] {
        values.reduce(into: [:]) { $0[$1, default: 0] += 1 }
    }

    private static func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func number(_ value: Double) -> String {
        if abs(value.rounded() - value) < 0.000000000001 { return String(Int(value.rounded())) }
        return String(format: "%.4f", value).replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
    }
}
