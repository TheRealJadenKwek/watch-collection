import Foundation

/// One run of the statement sentence on a watch's page. Emphasised runs (the name, the material and
/// the dial colour) are drawn in ink; the connecting words in the quieter grey.
struct StatementPart: Equatable, Sendable {
    let text: String
    let emphasized: Bool
}

/// The sentence a watch's page opens its story with: "The Oris Aquis Date in stainless steel with a
/// grey dial." The clause for a missing field is left out. An "Other" material and a "Screen" or
/// "Other" dial say nothing about the watch, so they count as missing. Nil when nothing is left to say.
func statementParts(name: String, material: String?, dialColor: String?) -> [StatementPart]? {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let material = statementWord(material, skipping: ["other"])
    let dial = statementWord(dialColor, skipping: ["screen", "other"])
    guard !name.isEmpty, material != nil || dial != nil else { return nil }

    var parts: [StatementPart] = []
    if name.lowercased().hasPrefix("the ") {
        parts.append(StatementPart(text: name, emphasized: true))
    } else {
        parts.append(StatementPart(text: "The ", emphasized: false))
        parts.append(StatementPart(text: name, emphasized: true))
    }
    if let material {
        parts.append(StatementPart(text: " in ", emphasized: false))
        parts.append(StatementPart(text: material, emphasized: true))
    }
    if let dial {
        parts.append(StatementPart(text: " with \(indefiniteArticle(for: dial)) ", emphasized: false))
        parts.append(StatementPart(text: dial, emphasized: true))
        parts.append(StatementPart(text: " dial.", emphasized: false))
    } else {
        parts.append(StatementPart(text: ".", emphasized: false))
    }
    return parts
}

/// The plain sentence, for VoiceOver and tests.
func statementSentence(_ parts: [StatementPart]) -> String {
    parts.map(\.text).joined()
}

/// A field as it reads inside a sentence: trimmed and lowercased, keeping acronyms ("Gold-plated/PVD"
/// reads "gold-plated/PVD"). Nil when empty or one of the skipped values.
func statementWord(_ value: String?, skipping skipped: Set<String>) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty,
          !skipped.contains(value.lowercased())
    else { return nil }
    var result = ""
    var word = ""
    func flush() {
        let isAcronym = word.count >= 2 && word.allSatisfy(\.isUppercase)
        result += isAcronym ? word : word.lowercased()
        word = ""
    }
    for character in value {
        if character.isLetter {
            word.append(character)
        } else {
            flush()
            result.append(character)
        }
    }
    flush()
    return result
}

private func indefiniteArticle(for word: String) -> String {
    guard let first = word.lowercased().first else { return "a" }
    return "aeiou".contains(first) ? "an" : "a"
}
