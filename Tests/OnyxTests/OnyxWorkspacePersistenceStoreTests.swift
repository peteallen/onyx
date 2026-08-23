import Foundation
import XCTest
@testable import Onyx

@MainActor
final class OnyxWorkspacePersistenceStoreTests: XCTestCase {
    func testLegacyPreferencesMigrateOnlyIntoFirstPreparedWindowNamespace() throws {
        let suite = try makeDefaults()
        defer { suite.cleanUp() }
        let defaults = suite.defaults
        let firstPrefix = "Onyx.window.first"
        let secondPrefix = "Onyx.window.second"
        let legacyPreferences: [String: Any] = [
            "sidebarVisible": false,
            "inspectorVisible": true,
            "bottomPanelVisible": true,
            "inspectorTab": "files",
            "selectedModelID": "gpt-5",
            "reasoningEffort": "high",
            "permissionLabel": "Workspace Write",
            "threadListScope": "all",
            "selectedThreadID": "legacy-thread",
            "composerDrafts": ["legacy-thread": "Unsent legacy draft"],
            "taskModelOverrides": ["legacy-thread": "alternate-model"],
            "taskModelDefaults": ["legacy-thread": "gpt-5"],
            "lastWorkspacePath": "/projects/legacy",
            "terminalHeight": 372.0,
        ]

        for (suffix, value) in legacyPreferences {
            defaults.set(value, forKey: "Onyx.\(suffix)")
        }

        let store = OnyxWorkspacePersistenceStore(defaults: defaults)
        store.prepareNamespace(firstPrefix)

        for (suffix, expectedValue) in legacyPreferences {
            XCTAssertNil(defaults.object(forKey: "Onyx.\(suffix)"))
            XCTAssertEqual(
                defaults.object(forKey: "\(firstPrefix).\(suffix)") as? NSObject,
                expectedValue as? NSObject,
                "Legacy preference \(suffix) did not migrate to the first window."
            )
        }

        defaults.set("late-legacy-thread", forKey: "Onyx.selectedThreadID")
        store.prepareNamespace(secondPrefix)

        XCTAssertEqual(defaults.string(forKey: "Onyx.selectedThreadID"), "late-legacy-thread")
        XCTAssertNil(defaults.object(forKey: "\(secondPrefix).selectedThreadID"))
        XCTAssertEqual(defaults.string(forKey: "\(firstPrefix).selectedThreadID"), "legacy-thread")
        XCTAssertEqual(
            defaults.stringArray(forKey: "Onyx.workspaceWindowPreferencePrefixes"),
            [firstPrefix, secondPrefix]
        )
    }

    func testClearAccountOwnedStateRemovesLegacyAndDormantWindowValuesButKeepsPreferences() throws {
        let suite = try makeDefaults()
        defer { suite.cleanUp() }
        let defaults = suite.defaults
        let firstPrefix = "Onyx.window.first"
        let dormantPrefix = "Onyx.window.dormant"
        let store = OnyxWorkspacePersistenceStore(defaults: defaults)

        store.prepareNamespace(firstPrefix)
        store.prepareNamespace(dormantPrefix)

        for prefix in [firstPrefix, dormantPrefix] {
            defaults.set("\(prefix)-thread", forKey: "\(prefix).selectedThreadID")
            defaults.set(["\(prefix)-thread": "Draft"], forKey: "\(prefix).composerDrafts")
            defaults.set(["\(prefix)-thread": "alternate-model"], forKey: "\(prefix).taskModelOverrides")
            defaults.set(["\(prefix)-thread": "gpt-5"], forKey: "\(prefix).taskModelDefaults")
            defaults.set("/projects/\(prefix)", forKey: "\(prefix).lastWorkspacePath")
            defaults.set(false, forKey: "\(prefix).sidebarVisible")
            defaults.set("gpt-5", forKey: "\(prefix).selectedModelID")
        }
        defaults.set("legacy-thread", forKey: "Onyx.selectedThreadID")
        defaults.set(["legacy-thread": "Legacy draft"], forKey: "Onyx.composerDrafts")
        defaults.set(["legacy-thread": "alternate-model"], forKey: "Onyx.taskModelOverrides")
        defaults.set(["legacy-thread": "gpt-5"], forKey: "Onyx.taskModelDefaults")
        defaults.set("/projects/legacy", forKey: "Onyx.lastWorkspacePath")
        defaults.set(true, forKey: "Onyx.sidebarVisible")

        // A fresh store simulates logout after the second window has been closed.
        OnyxWorkspacePersistenceStore(defaults: defaults).clearAccountOwnedState()

        for prefix in [firstPrefix, dormantPrefix] {
            XCTAssertNil(defaults.object(forKey: "\(prefix).selectedThreadID"))
            XCTAssertNil(defaults.object(forKey: "\(prefix).composerDrafts"))
            XCTAssertNil(defaults.object(forKey: "\(prefix).taskModelOverrides"))
            XCTAssertNil(defaults.object(forKey: "\(prefix).taskModelDefaults"))
            XCTAssertNil(defaults.object(forKey: "\(prefix).lastWorkspacePath"))
            XCTAssertEqual(defaults.object(forKey: "\(prefix).sidebarVisible") as? Bool, false)
            XCTAssertEqual(defaults.string(forKey: "\(prefix).selectedModelID"), "gpt-5")
        }
        XCTAssertNil(defaults.object(forKey: "Onyx.selectedThreadID"))
        XCTAssertNil(defaults.object(forKey: "Onyx.composerDrafts"))
        XCTAssertNil(defaults.object(forKey: "Onyx.taskModelOverrides"))
        XCTAssertNil(defaults.object(forKey: "Onyx.taskModelDefaults"))
        XCTAssertNil(defaults.object(forKey: "Onyx.lastWorkspacePath"))
        XCTAssertEqual(defaults.object(forKey: "Onyx.sidebarVisible") as? Bool, true)
    }

    private func makeDefaults() throws -> (defaults: UserDefaults, cleanUp: () -> Void) {
        let suiteName = "OnyxWorkspacePersistenceStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }
}
