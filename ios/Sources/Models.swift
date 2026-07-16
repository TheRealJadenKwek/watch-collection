import Foundation

struct CollectionData: Codable, Sendable {
    var settings: CollectionSettings
    var watches: [Watch]
    var categories: [String]
    var wishlist: [WishlistItem]
    var brandWatchlist: [BrandRadarItem]
    var dialColors: [String]
    var materials: [String]
    var headlineStats: [String: HeadlineStatsPayload]?
}

struct HeadlineStatsPayload: Codable, Sendable {
    var iqr: Double
    var q1: Double?
    var q3: Double?
}

struct CollectionSettings: Codable, Sendable {
    var autoBackup: Bool
    var backupRemote: String?
    var lastBackup: String?
    var autoImage: Bool
    var suggestExclude: [String]?
    var wrist: WristProfile
}

struct WristProfile: Codable, Sendable {
    var inches: Double
    var sweetSpotMin: Double
    var sweetSpotMax: Double
    var perfect: Double
    var lugMax: Double
}

struct Watch: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var story: String
    var purchased: String?
    var purchasedText: String
    var diameter: Double?
    var price: Double
    var original: Bool?
    var status: String
    var statusNote: String
    var photos: [String]
    var category: String?
    var dialColor: String?
    var lugToLug: Double?
    var material: String?
    var brand: String?
}

struct WishlistItem: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var brand: String
    var category: String?
    var priceExpected: Double?
    var priceNote: String
    var notes: String
    var status: String
    var added: String
    var dialColor: String?
    var diameter: Double?
    var lugToLug: Double?
    var material: String?
    var photos: [String]
}

struct BrandRadarItem: Codable, Hashable, Sendable {
    var brand: String
    var notes: String
    var added: String
}

struct WishlistScoresResponse: Codable, Sendable {
    var scores: [String: WishlistScore]
}

struct WishlistScore: Codable, Hashable, Sendable {
    var total: Int
    var max: Int
    var lenses: [String: LensScore]
}

struct LensScore: Codable, Hashable, Sendable {
    var score: Int
    var reason: String
}

struct SuggestionsResponse: Codable, Hashable, Sendable {
    var saturated: SaturatedAreas
    var suggestions: [NextMoveSuggestion]
}

struct SaturatedAreas: Codable, Hashable, Sendable {
    var categories: [String]
    var dials: [String]
    var brands: [String]
}

struct NextMoveSuggestion: Codable, Hashable, Sendable {
    var headline: String
    var category: String
    var dialColors: [String]
    var material: String?
    var sizeGuidance: String
    var priceTier: String?
    var score: Int
    var reasons: [String]
    var wishlistMatches: [String]
    var brands: [SuggestedBrand]?
}

struct SuggestedBrand: Codable, Hashable, Sendable {
    var name: String
    var status: String
}

struct BackupResponse: Codable, Sendable {
    var ok: Bool
    var output: String
    var lastBackup: String?
}

struct AutoImageResponse: Codable, Sendable {
    var ok: Bool
    var searchUrl: String?
}

struct APIMessage: Codable, Sendable {
    var ok: Bool?
    var error: String?
}

enum WatchStatus: String, CaseIterable, Identifiable {
    case owned
    case givenAway = "given_away"
    case sold
    case broken
    case donated
    case ousted
    case wantToBuyBack = "want_to_buy_back"
    case givingAway = "giving_away"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .owned: "Owned"
        case .givenAway: "Given away"
        case .sold: "Sold"
        case .broken: "Broken"
        case .donated: "Donated"
        case .ousted: "Ousted"
        case .wantToBuyBack: "Want to buy back"
        case .givingAway: "Giving away"
        }
    }
}

enum TaxonomyRoute: String, Identifiable, CaseIterable, Sendable {
    case categories
    case dialcolors
    case materials

    var id: String { rawValue }
    var title: String {
        switch self {
        case .categories: "Categories"
        case .dialcolors: "Dial colours"
        case .materials: "Case materials"
        }
    }
}

enum TaxonomyOperation: Sendable {
    case add(String)
    case rename(from: String, to: String)
    case delete(String)
    case reorder([String])
}

struct FitInfo: Hashable {
    var key: String
    var label: String
    var basis: String
}

enum AppTab: String, CaseIterable {
    case collection
    case past
    case stats
    case wishlist
}
