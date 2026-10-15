import Foundation

struct AppArchive: Codable {
    var schemaVersion = 1
    var settings = UserSettings()
    var history: [DictationRecord] = []
    var dictionary: [DictionaryEntry] = []
}

final class Persistence {
    let directory: URL
    private let manager: FileManager
    var archiveURL: URL { directory.appendingPathComponent("library.json") }
    var recordingsDirectory: URL { directory.appendingPathComponent("Recordings", isDirectory: true) }

    init(directory: URL? = nil, manager: FileManager = .default) {
        self.manager = manager
        self.directory = directory ?? manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sotto", isDirectory: true)
    }

    func load() throws -> AppArchive {
        guard manager.fileExists(atPath: archiveURL.path) else { return AppArchive() }
        let data = try Data(contentsOf: archiveURL)
        let archive = try JSONDecoder().decode(AppArchive.self, from: data)
        guard archive.schemaVersion == 1 else {
            throw SottoError.message("This library was created by a newer version of Sotto.")
        }
        return archive
    }

    func save(_ archive: AppArchive) throws {
        try prepareDirectory(directory)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(archive).write(to: archiveURL, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: archiveURL.path)
    }

    func retainRecording(_ recording: RecordedAudio, id: UUID) throws -> String {
        try prepareDirectory(recordingsDirectory)
        let destination = recordingsDirectory.appendingPathComponent(id.uuidString).appendingPathExtension("wav")
        try manager.copyItem(at: recording.url, to: destination)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        return destination.path
    }

    func removeRecording(path: String?) {
        guard let path else { return }
        let candidate = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let expectedParent = recordingsDirectory.standardizedFileURL.resolvingSymlinksInPath()
        guard candidate.deletingLastPathComponent() == expectedParent,
              candidate.pathExtension == "wav" else { return }
        try? manager.removeItem(at: candidate)
    }

    private func prepareDirectory(_ url: URL) throws {
        try manager.createDirectory(at: url, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}

enum TextProcessor {
    /// Match against the original text once, so one replacement cannot trigger another.
    static func applyingDictionary(_ entries: [DictionaryEntry], to text: String) -> String {
        let valid = entries.filter { !$0.phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.phrase.count > $1.phrase.count }
        guard !valid.isEmpty else { return text }
        let alternatives = valid.map { NSRegularExpression.escapedPattern(for: $0.phrase) }.joined(separator: "|")
        let pattern = "(?<![\\p{L}\\p{N}_])(?:" + alternatives + ")(?![\\p{L}\\p{N}_])"
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        let input = text as NSString
        let result = NSMutableString(string: text)
        for match in expression.matches(in: text, range: NSRange(location: 0, length: input.length)).reversed() {
            let phrase = input.substring(with: match.range)
            guard let entry = valid.first(where: { $0.phrase.caseInsensitiveCompare(phrase) == .orderedSame }) else { continue }
            result.replaceCharacters(in: match.range, with: entry.replacement.isEmpty ? entry.phrase : entry.replacement)
        }
        return result as String
    }
}
