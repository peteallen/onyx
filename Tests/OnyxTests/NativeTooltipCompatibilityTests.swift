import Foundation
import XCTest
@testable import Onyx

final class NativeTooltipCompatibilityTests: XCTestCase {
    func testNativeTooltipsRemainEnabledBeforeAffectedMacOSGeneration() {
        XCTAssertTrue(OnyxHelpPresentationPolicy.usesNativeTooltip(macOSMajorVersion: 25))
    }

    func testNativeTooltipsAreDisabledOnAffectedAndLaterMacOSGenerations() {
        XCTAssertFalse(OnyxHelpPresentationPolicy.usesNativeTooltip(macOSMajorVersion: 26))
        XCTAssertFalse(OnyxHelpPresentationPolicy.usesNativeTooltip(macOSMajorVersion: 27))
    }

    func testApplicationSourceRoutesHelpThroughCompatibilityModifier() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceRoot = repositoryRoot.appendingPathComponent("Sources/Onyx", isDirectory: true)
        let compatibilityFile = "OnyxHelpCompatibility.swift"
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: nil
        ) else {
            return XCTFail("Could not enumerate Onyx source files")
        }

        for case let fileURL as URL in enumerator where
            fileURL.pathExtension == "swift" && fileURL.lastPathComponent != compatibilityFile
        {
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            XCTAssertFalse(
                source.range(
                    of: #"\.help\s*\("#,
                    options: .regularExpression
                ) != nil,
                "\(fileURL.lastPathComponent) bypasses the macOS tooltip compatibility policy"
            )
        }
    }
}
