import XCTest
@testable import WatchCollection

/// The statement sentence on a watch's page: which clauses appear for which fields.
final class StatementTests: XCTestCase {
    private func sentence(_ name: String, material: String?, dial: String?) -> String? {
        statementParts(name: name, material: material, dialColor: dial).map(statementSentence)
    }

    func testMaterialAndDial() {
        XCTAssertEqual(
            sentence("Oris Aquis Date", material: "Stainless Steel", dial: "Grey"),
            "The Oris Aquis Date in stainless steel with a grey dial."
        )
    }

    func testMaterialOnly() {
        XCTAssertEqual(sentence("Seiko 5", material: "Titanium", dial: nil), "The Seiko 5 in titanium.")
    }

    func testDialOnly() {
        XCTAssertEqual(sentence("Seiko 5", material: nil, dial: "Blue"), "The Seiko 5 with a blue dial.")
    }

    func testNeitherFieldMeansNoStatement() {
        XCTAssertNil(statementParts(name: "Seiko 5", material: nil, dialColor: nil))
        XCTAssertNil(statementParts(name: "Seiko 5", material: "  ", dialColor: ""))
    }

    func testOtherMaterialAndScreenDialCountAsMissing() {
        XCTAssertNil(statementParts(name: "Apple Watch", material: "Other", dialColor: "Screen"))
        XCTAssertEqual(sentence("Apple Watch", material: "Aluminum", dial: "Screen"), "The Apple Watch in aluminum.")
        XCTAssertEqual(sentence("Casio", material: "Other", dial: "Black"), "The Casio with a black dial.")
        XCTAssertNil(statementParts(name: "Casio", material: "Other", dialColor: "Other"))
    }

    func testArticleBeforeAVowel() {
        XCTAssertEqual(sentence("Timex Q", material: nil, dial: "Orange"), "The Timex Q with an orange dial.")
    }

    func testAcronymsKeepTheirCapitals() {
        XCTAssertEqual(
            sentence("Zenith 220S", material: "Gold-plated/PVD", dial: "Gold/Champagne"),
            "The Zenith 220S in gold-plated/PVD with a gold/champagne dial."
        )
    }

    func testNameAlreadyStartingWithTheKeepsOneArticle() {
        XCTAssertEqual(sentence("The Explorer", material: "Bronze", dial: nil), "The Explorer in bronze.")
    }

    func testEmphasisMarksTheDataWords() {
        let parts = statementParts(name: "Oris Aquis", material: "Bronze", dialColor: "Green") ?? []
        XCTAssertEqual(parts.filter(\.emphasized).map(\.text), ["Oris Aquis", "bronze", "green"])
        XCTAssertEqual(parts.filter { !$0.emphasized }.map(\.text), ["The ", " in ", " with a ", " dial."])
    }

    func testEmptyNameMeansNoStatement() {
        XCTAssertNil(statementParts(name: " ", material: "Bronze", dialColor: "Green"))
    }
}
