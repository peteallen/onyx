import Combine
import XCTest
@testable import Onyx

/// The primary composer is deliberately a child observable object.  These
/// tests protect the user-visible performance boundary: typing may update the
/// composer subtree, but must not announce a change through the large app
/// workspace model.
@MainActor
final class ComposerObservationIsolationTests: XCTestCase {
    func testDraftTypingPublishesComposerChildWithoutInvalidatingAppModel() {
        let suiteName = "ComposerObservationIsolationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = OnyxAppModel(runtime: nil, defaults: defaults)
        var appModelChanges = 0
        var composerChanges = 0
        let appCancellable = model.objectWillChange.sink { _ in
            appModelChanges += 1
        }
        let composerCancellable = model.composerDraftModel.objectWillChange.sink { _ in
            composerChanges += 1
        }

        model.composerText = "h"

        XCTAssertEqual(appModelChanges, 0, "A keystroke must not invalidate the whole workspace model")
        XCTAssertEqual(composerChanges, 1, "The isolated composer must still publish its draft update")
        withExtendedLifetime((appCancellable, composerCancellable)) {}
    }

    func testStartsWithNewTaskUsesDistinctFocusIdentity() {
        let firstSuite = "ComposerObservationIsolationTests.first.\(UUID().uuidString)"
        let secondSuite = "ComposerObservationIsolationTests.second.\(UUID().uuidString)"
        let firstDefaults = UserDefaults(suiteName: firstSuite)!
        let secondDefaults = UserDefaults(suiteName: secondSuite)!
        firstDefaults.removePersistentDomain(forName: firstSuite)
        secondDefaults.removePersistentDomain(forName: secondSuite)
        defer {
            firstDefaults.removePersistentDomain(forName: firstSuite)
            secondDefaults.removePersistentDomain(forName: secondSuite)
        }

        let first = OnyxAppModel(runtime: nil, defaults: firstDefaults, startsWithNewTask: true)
        let second = OnyxAppModel(runtime: nil, defaults: secondDefaults, startsWithNewTask: true)

        XCTAssertNotNil(first.composerFocusRequest)
        XCTAssertNotNil(second.composerFocusRequest)
        XCTAssertNotEqual(
            first.composerFocusRequest,
            second.composerFocusRequest,
            "Replacing a provider-bound model must not reuse a consumed focus token"
        )
    }
}
