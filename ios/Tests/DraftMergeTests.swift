import Foundation

@main
enum DraftMergeTests {
    struct Item: Codable, Equatable {
        var name = "Field"
        var story = "Original"
        var note: String? = "Old note"
        var photos = ["one.jpg"]
        var settings = ["min": 35, "max": 40]
    }
    static func main() throws {
        let base = Item()
        var local = base, remote = base
        local.name = "Edited name"
        remote.story = "New phone story"
        remote.photos.append("two.jpg")
        var merged = try mergeDraft(base: base, draft: local, current: remote)
        precondition(merged.name == local.name && merged.story == remote.story && merged.photos == remote.photos)
        local.note = nil
        merged = try mergeDraft(base: base, draft: local, current: remote)
        precondition(merged.note == nil)
        local.settings["min"] = 36
        remote.settings["max"] = 41
        merged = try mergeDraft(base: base, draft: local, current: remote)
        precondition(merged.settings == ["min": 36, "max": 41])
        let repeated = try mergeDraft(base: base, draft: local, current: merged)
        precondition(repeated == merged)
        remote.name = "Conflicting edit"
        do {
            _ = try mergeDraft(base: base, draft: local, current: remote)
            fatalError("Conflicting form overwrote incoming data")
        } catch DraftMergeError.changedElsewhere { }
        print("Draft merge passed: independent edits, new photos, nullable clearing, nested settings, retries, conflicts.")
    }
}
