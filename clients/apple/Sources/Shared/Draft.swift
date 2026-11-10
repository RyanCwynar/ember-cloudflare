import Foundation

/// What the composer holds: text with light Markdown, and the people its @mentions name.
struct Draft: Equatable {
    var text = ""
    var mentions: [ComposerMarkup.Mention] = []

    var isBlank: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// The mentions still in the text, since deleting "@Name" by hand should drop it.
    var liveMentions: [ComposerMarkup.Mention] { mentions.filter { text.contains("@\($0.name)") } }
}

extension Draft {
    /// Replaces the "@query" being typed with the person's name, and remembers them as a mention.
    mutating func pick(_ person: DirectoryUser) {
        guard let at = text.lastIndex(of: "@") else { return }
        text = String(text[..<at]) + "@\(person.name) "
        if !mentions.contains(where: { $0.id == person.id }) {
            mentions.append(ComposerMarkup.Mention(id: person.id, name: person.name))
        }
    }
}

/// Who to offer while someone types "@" and a few letters at the end of the composer.
enum MentionSuggestions {
    /// The "@query" being typed at the end of the text, if any.
    static func query(in text: String) -> String? {
        guard let at = text.lastIndex(of: "@") else { return nil }
        if at > text.startIndex {
            let before = text[text.index(before: at)]
            guard before.isWhitespace || before.isPunctuation else { return nil }
        }
        let query = text[text.index(after: at)...]
        guard query.count <= 30, !query.contains("\n"), query.split(separator: " ").count <= 2 else { return nil }
        return String(query)
    }

    /// People whose names contain the query, those starting with it first, at most six.
    static func people(for text: String, from people: [DirectoryUser]) -> [DirectoryUser] {
        guard let query = query(in: text) else { return [] }
        let q = query.lowercased()
        return people
            .filter { q.isEmpty || $0.name.lowercased().contains(q) }
            .sorted { a, b in
                let ap = a.name.lowercased().hasPrefix(q), bp = b.name.lowercased().hasPrefix(q)
                return ap != bp ? ap : a.name < b.name
            }
            .prefix(6)
            .map { $0 }
    }
}
