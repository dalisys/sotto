import AVFoundation
import XCTest
@testable import Sotto

final class DictationSetupTests: XCTestCase {
    func testLocalDictationDoesNotRequireKeyEvenWhenCloudCleanupWasSaved() throws {
        for backend in [TranscriptionBackend.localParakeet, .localWhisper] {
            var settings = UserSettings()
            settings.backend = backend
            settings.polishEnabled = true
            let plan = try DictationPlan(settings: settings, apiKey: nil)
            XCTAssertEqual(plan.settings.backend, backend)
            XCTAssertFalse(plan.settings.polishEnabled)
            XCTAssertNotNil(plan.notice)
            XCTAssertNil(plan.apiKey)
            XCTAssertTrue(settings.polishEnabled, "Resolving a recording must not silently change saved preferences.")
        }
    }

    func testLocalCleanupUsesKeyWhenAvailableAndCloudTranscriptionStillRequiresIt() throws {
        var settings = UserSettings()
        settings.polishEnabled = true
        XCTAssertTrue(try DictationPlan(settings: settings, apiKey: "test-key").settings.polishEnabled)
        settings.backend = .openRouter
        XCTAssertThrowsError(try DictationPlan(settings: settings, apiKey: "   "))
        XCTAssertEqual(try DictationPlan(settings: settings, apiKey: " test-key ").apiKey, "test-key")
    }

    func testMicrophoneCanBeRequestedBeforeAnyModelOrKeyIsConfigured() async {
        var prompts = 0
        let granted = await MicrophonePermission.request(status: .notDetermined) { prompts += 1; return true }
        XCTAssertTrue(granted)
        XCTAssertEqual(prompts, 1)
    }

    func testAuthorizedAndDeniedPermissionsDoNotReprompt() async {
        var prompts = 0
        let authorized = await MicrophonePermission.request(status: .authorized) { prompts += 1; return false }
        let denied = await MicrophonePermission.request(status: .denied) { prompts += 1; return true }
        let restricted = await MicrophonePermission.request(status: .restricted) { prompts += 1; return true }
        XCTAssertTrue(authorized)
        XCTAssertFalse(denied)
        XCTAssertFalse(restricted)
        XCTAssertEqual(prompts, 0)
    }
}
