import Foundation
import XCTest
@testable import Sotto

final class PersistenceTests: XCTestCase {
    private var directory: URL!
    private var store: Persistence!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("SottoTests-\(UUID())")
        store = Persistence(directory: directory)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    func testArchiveRoundTripKeepsActualHistoryAndDictionary() throws {
        var archive = AppArchive()
        archive.settings.backend = .openRouter
        archive.history = [DictationRecord(originalText: "hello", text: "Hello.", duration: 1.5, language: "en-US")]
        archive.dictionary = [DictionaryEntry(phrase: "sotto", replacement: "Sotto")]
        try store.save(archive)
        let loaded = try store.load()
        XCTAssertEqual(loaded.settings, archive.settings)
        XCTAssertEqual(loaded.history, archive.history)
        XCTAssertEqual(loaded.dictionary, archive.dictionary)
        let permissions = try FileManager.default.attributesOfItem(atPath: store.archiveURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        let contents = try String(contentsOf: store.archiveURL, encoding: .utf8)
        XCTAssertFalse(contents.contains("apiKey"))
    }

    func testCorruptLibraryIsNotOverwrittenOnRead() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = Data("not valid JSON".utf8)
        try original.write(to: store.archiveURL)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try Data(contentsOf: store.archiveURL), original)
    }

    func testUnsupportedSchemaIsRejected() throws {
        var archive = AppArchive()
        archive.schemaVersion = 99
        try store.save(archive)
        XCTAssertThrowsError(try store.load())
    }

    func testLegacyCloudSettingsMigrateToOpenRouterWithoutReusingEndpointOrModelIDs() throws {
        let old = Data(#"{"backend":"openAICompatible","language":"de-DE","apiBaseURL":"https://api.openai.com/v1","transcriptionModel":"gpt-4o-mini-transcribe","polishModel":"gpt-4.1-mini","insertAutomatically":false}"#.utf8)
        let settings = try JSONDecoder().decode(UserSettings.self, from: old)
        XCTAssertEqual(settings.backend, .openRouter)
        XCTAssertEqual(settings.apiBaseURL, "https://openrouter.ai/api/v1")
        XCTAssertEqual(settings.transcriptionModel, "nvidia/parakeet-tdt-0.6b-v3")
        XCTAssertEqual(settings.polishModel, "google/gemini-3.1-flash-lite")
        XCTAssertEqual(settings.language, "de-DE")
        XCTAssertFalse(settings.insertAutomatically)
        XCTAssertTrue(settings.showFloatingBar)
    }

    func testLegacyLocalSettingsBecomeParakeetAndOldHistoryLoadsWithoutTiming() throws {
        let old = Data(#"{"backend":"appleOnDevice","language":"en-US"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(UserSettings.self, from: old).backend, .localParakeet)
        let record = DictationRecord(originalText: "original", text: "Edited.", duration: 2, language: "en-US")
        let encoder = JSONEncoder()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(record)) as? [String: Any])
        json.removeValue(forKey: "timing")
        let restored = try JSONDecoder().decode(DictationRecord.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(restored.timing)
        XCTAssertEqual(restored.text, "Edited.")
    }

    func testRecordingDeletionCannotEscapeOwnedDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let unrelated = directory.appendingPathComponent("important.wav")
        try Data([1, 2, 3]).write(to: unrelated)
        store.removeRecording(path: unrelated.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        let retained = try store.retainRecording(RecordedAudio(url: unrelated, duration: 1), id: UUID())
        XCTAssertTrue(FileManager.default.fileExists(atPath: retained))
        store.removeRecording(path: retained)
        XCTAssertFalse(FileManager.default.fileExists(atPath: retained))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }
}

final class DictionaryTests: XCTestCase {
    func testReplacementsRespectWordBoundariesAndUnicode() {
        let entries = [DictionaryEntry(phrase: "flow", replacement: "Flow"), DictionaryEntry(phrase: "cafe", replacement: "café")]
        XCTAssertEqual(TextProcessor.applyingDictionary(entries, to: "FLOW workflow cafe caféflow"), "Flow workflow café caféflow")
    }

    func testLongestPhraseWinsWithoutCascading() {
        let entries = [DictionaryEntry(phrase: "new york", replacement: "NYC"),
                       DictionaryEntry(phrase: "new", replacement: "fresh"),
                       DictionaryEntry(phrase: "NYC", replacement: "changed")]
        XCTAssertEqual(TextProcessor.applyingDictionary(entries, to: "New York is new. NYC"), "NYC is fresh. changed")
    }

    func testLiteralRegexCharactersAndEmptyReplacement() {
        let entries = [DictionaryEntry(phrase: "c++", replacement: "C++"), DictionaryEntry(phrase: "sotto", replacement: "")]
        XCTAssertEqual(TextProcessor.applyingDictionary(entries, to: "c++ SOTTO"), "C++ sotto")
        XCTAssertEqual(TextProcessor.applyingDictionary([DictionaryEntry(phrase: "", replacement: "bad")], to: "unchanged"), "unchanged")
    }
}
