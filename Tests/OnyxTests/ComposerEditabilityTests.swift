import Foundation
import XCTest
@testable import Onyx

@MainActor
final class ComposerEditabilityTests: XCTestCase {
    func testDraftingRemainsEnabledWhenRuntimeIsUnavailable() {
        let suiteName = "ComposerEditabilityTests.unavailable.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = OnyxAppModel(runtime: nil, defaults: defaults)

        XCTAssertFalse(model.canRunAgent)
        XCTAssertTrue(
            model.canEditComposer,
            "A disconnected or unconfigured provider must not erase the user's draft input surface"
        )
    }

    func testDraftingRemainsEnabledDuringProviderReconnect() {
        let suiteName = "ComposerEditabilityTests.connecting.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = OnyxAppModel(runtime: nil, defaults: defaults)
        model.connectionState = .connecting

        XCTAssertFalse(model.canRunAgent)
        XCTAssertTrue(
            model.canEditComposer,
            "The composer must remain writable while the provider handshake is in flight"
        )
    }
}
