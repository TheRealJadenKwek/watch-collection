import Foundation

enum DraftMergeError: LocalizedError {
    case changedElsewhere(String)
    var errorDescription: String? {
        switch self {
        case let .changedElsewhere(field):
            return "\(field) changed on another device while this editor was open. Close and reopen the editor to review the latest version."
        }
    }
}

// Forms can remain open across a background sync. Only apply fields the user
// actually changed, and reject conflicting edits instead of saving a stale form.
func mergeDraft<T: Codable>(base: T, draft: T, current: T) throws -> T {
    func object(_ value: T) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
    }
    func equal(_ a: Any?, _ b: Any?) -> Bool {
        NSDictionary(dictionary: ["value": a ?? NSNull()]).isEqual(to: ["value": b ?? NSNull()])
    }
    func combine(_ old: [String: Any], _ edited: [String: Any], _ live: [String: Any]) throws -> [String: Any] {
        var result = live
        for key in Set(old.keys).union(edited.keys) where !equal(old[key], edited[key]) {
            if let b = old[key] as? [String: Any], let d = edited[key] as? [String: Any], let c = live[key] as? [String: Any] {
                result[key] = try combine(b, d, c)
            } else {
                guard equal(live[key], old[key]) || equal(live[key], edited[key]) else { throw DraftMergeError.changedElsewhere(key) }
                result[key] = edited[key]
            }
        }
        return result
    }
    return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: combine(object(base), object(draft), object(current))))
}

