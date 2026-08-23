import Foundation
import XCTest
@testable import Onyx

final class CodexEphemeralForkWireTests: XCTestCase {
    func testRealJSONLClientUsesStrictEphemeralForkShape() async throws {
        let script = #"""
        while IFS= read -r line; do
          id=$(printf '%s' "$line" | sed -E 's/.*"id":([0-9]+).*/\1/')
          case "$line" in
            *'"method":"initialize"'*)
              printf '{"id":%s,"result":{}}\n' "$id"
              ;;
            *'"method":"initialized"'*) ;;
            *'"method":"account\/read"'*)
              printf '{"id":%s,"result":{"account":{"type":"chatgpt","email":"wire-test@example.test"},"requiresOpenaiAuth":true}}\n' "$id"
              ;;
            *'"method":"model\/list"'*)
              printf '{"id":%s,"result":{"data":[]}}\n' "$id"
              ;;
            *'"method":"thread\/fork"'*)
              case "$line" in
                *'"ephemeral":true'*'"excludeTurns":true'*|*'"excludeTurns":true'*'"ephemeral":true'*)
                  printf '{"id":%s,"result":{"thread":{"id":"strict-side-thread","preview":"Strict side chat","ephemeral":true,"turns":[]}}}\n' "$id"
                  ;;
                *)
                  printf '{"id":%s,"error":{"code":-32600,"message":"ephemeral fork requires ephemeral=true and excludeTurns=true"}}\n' "$id"
                  ;;
              esac
              ;;
          esac
        done
        """#
        let client = CodexAppServerClient(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            processArguments: ["-c", script]
        )
        let runtime = CodexRuntime(client: client)

        do {
            _ = try await runtime.connect()
            let sideChat = try await runtime.forkEphemeralThread(id: "parent-thread")

            XCTAssertEqual(sideChat.thread.id, "strict-side-thread")
            XCTAssertTrue(sideChat.items.isEmpty)
            await runtime.disconnect()
        } catch {
            await runtime.disconnect()
            throw error
        }
    }
}
