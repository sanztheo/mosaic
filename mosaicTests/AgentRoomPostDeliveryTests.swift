import Foundation
import Testing

#if canImport(Mosaic_DEV)
@testable import Mosaic_DEV
#elseif canImport(Mosaic)
@testable import Mosaic
#endif

/// Regression coverage for `agent.room.post` delivery.
///
/// The CLI-reachable `agent.room.post` command must append its event through
/// the `ClaudeRoomStore` actor (the source of truth), not a display cache
/// that can drift behind the store; it must normalize target surface ids to
/// their canonical uppercase UUID form; and it must reject a self-addressed
/// post instead of silently appending a message nobody will ever receive.
///
/// Room/member setup below calls `CollaborationRuntime` directly (an
/// always-correct, already-awaited API regardless of the routing bug this
/// file protects). Only the specific `agent.room.post` call under test goes
/// through `TerminalController.handleSocketLine`, off the main thread, so it
/// exercises the same `ControlCommandExecutionPolicy` dispatch decision a
/// real CLI/hook caller hits. `agent.room.post` shares the socket-worker lane
/// with `agent.room.consume`/`recap`/`wake_flush`
/// (`.socketWorker(mainThreadCallable: false)`), and `handleSocketLine`
/// refuses same-thread main-actor dispatch for that policy, so the request
/// must originate off-main.
@MainActor
@Suite(.serialized)
struct AgentRoomPostDeliveryTests {
    @Test func postAfterConsumeReflectsStoreAcknowledgmentNotStaleDisplayCache() async throws {
        let runtime = CollaborationRuntime.shared
        let fromSurfaceID = UUID().uuidString

        let created = await runtime.createAgentRoomForAutomation(title: nil, deliveryPolicy: nil)
        let roomID = try #require(created["room_id"] as? String)

        // `agentRoomConsumePendingForAutomation` resolves its room purely from
        // `surfaceID -> room` membership (it takes no room_id param), and that
        // membership map is rebuilt by `reconcileAgentRoomMembership` on every
        // connect, which drops any surface without a real local
        // `TerminalPanel`. A synthetic UUID would silently fail to resolve, so
        // the target surface here is a real panel in a real (throwaway)
        // workspace. The active tab manager is a process-global on
        // `TerminalController.shared` that other test suites also mutate, so
        // it's scoped as tightly as possible: set only for the one connect
        // call that needs it, restored immediately after. The membership
        // mapping that call writes persists on its own afterward --
        // `agentRoomConsumePendingForAutomation` never re-reconciles it.
        let targetSurfaceID: String
        do {
            let tabManager = TabManager()
            TerminalController.shared.setActiveTabManager(tabManager)
            defer { TerminalController.shared.setActiveTabManager(nil) }
            let workspace = tabManager.addWorkspace(select: true)
            let targetPanel = try #require(workspace.focusedTerminalPanel)
            targetSurfaceID = targetPanel.id.uuidString
            _ = await runtime.connectAgentRoomSurfaceForAutomation(
                roomID: roomID, surfaceID: targetSurfaceID, agentSessionID: nil, displayName: nil
            )
        }

        // Give the target member something to acknowledge (event #1, room-visible).
        _ = await runtime.postAgentRoomEventForAutomation(
            roomID: roomID, kind: nil, fromSurfaceID: fromSurfaceID, targetSurfaceIDs: [], text: "first"
        )

        // Consuming advances the target's acknowledgment cursor directly in
        // the ClaudeRoomStore actor. The display cache
        // (`agentRoomSnapshotsByID`) is never touched by consume, so it
        // still reflects the target's pre-consume (nil) cursor -- this is
        // the deliberate staleness this test exploits.
        _ = await runtime.agentRoomConsumePendingForAutomation(surfaceID: targetSurfaceID)

        // The actual regression subject: this post must be routed and
        // answered from the store's current state, not the stale cache.
        let posted = try await postAgentRoomEventOverSocket(
            roomID: roomID, fromSurfaceID: fromSurfaceID, text: "second"
        )

        #expect(posted["posted"] as? Bool == true)
        let room = try #require(posted["room"] as? [String: Any])
        let members = try #require(room["members"] as? [[String: Any]])
        let target = try #require(members.first { ($0["surfaceID"] as? String) == targetSurfaceID })

        // Before the fix, the CLI-reachable handler built its response (and
        // the store write its fire-and-forget Task performed) from the
        // stale display-cache snapshot, which never saw the consume above --
        // so the target's acknowledgment cursor would read back as unset
        // instead of the 1 the store actually recorded.
        #expect(
            target["acknowledgedEventSequence"] as? Int == 1,
            "agent.room.post must reflect the ClaudeRoomStore's current state, not a stale display-cache snapshot"
        )

        _ = await runtime.resetAgentRoomForAutomation(roomID: roomID)
    }

    @Test func postNormalizesLowercaseTargetSurfaceIDs() async throws {
        let runtime = CollaborationRuntime.shared
        let fromSurfaceID = UUID().uuidString
        let targetSurfaceID = UUID().uuidString

        let created = await runtime.createAgentRoomForAutomation(title: nil, deliveryPolicy: nil)
        let roomID = try #require(created["room_id"] as? String)
        _ = await runtime.connectAgentRoomSurfaceForAutomation(
            roomID: roomID, surfaceID: fromSurfaceID, agentSessionID: nil, displayName: nil
        )

        let posted = try await postAgentRoomEventOverSocket(
            roomID: roomID,
            fromSurfaceID: fromSurfaceID,
            targetSurfaceIDs: [targetSurfaceID.lowercased()],
            text: "lowercase target"
        )

        #expect(posted["posted"] as? Bool == true)
        let event = try #require(posted["event"] as? [String: Any])
        let storedTargets = try #require(event["targetSurfaceIDs"] as? [String])
        #expect(
            storedTargets == [targetSurfaceID],
            "agent.room.post must normalize target surface ids to their canonical uppercase UUID form (got \(storedTargets))"
        )

        _ = await runtime.resetAgentRoomForAutomation(roomID: roomID)
    }

    @Test func postRejectsSelfAddressedTarget() async throws {
        let runtime = CollaborationRuntime.shared
        let surfaceID = UUID().uuidString

        let created = await runtime.createAgentRoomForAutomation(title: nil, deliveryPolicy: nil)
        let roomID = try #require(created["room_id"] as? String)
        _ = await runtime.connectAgentRoomSurfaceForAutomation(
            roomID: roomID, surfaceID: surfaceID, agentSessionID: nil, displayName: nil
        )

        let posted = try await postAgentRoomEventOverSocket(
            roomID: roomID,
            fromSurfaceID: surfaceID,
            targetSurfaceIDs: [surfaceID],
            text: "talking to myself"
        )

        #expect(posted["posted"] as? Bool == false)
        let error = posted["error"] as? String
        #expect(error?.localizedCaseInsensitiveContains("self-addressed") == true, "got: \(error ?? "nil")")

        let digest = await runtime.agentRoomDigestForAutomation(roomID: roomID, surfaceID: nil, since: nil)
        #expect(digest["last_sequence"] as? Int == 0, "a rejected self-addressed post must not append an event")

        _ = await runtime.resetAgentRoomForAutomation(roomID: roomID)
    }

    /// Sends `agent.room.post` through the real `TerminalController`
    /// dispatcher off the main thread, mirroring how a CLI/hook caller
    /// reaches the socket-worker lane. Returns the decoded `result` payload.
    private func postAgentRoomEventOverSocket(
        roomID: String,
        fromSurfaceID: String,
        targetSurfaceIDs: [String] = [],
        text: String
    ) async throws -> [String: Any] {
        var params: [String: Any] = [
            "room_id": roomID,
            "from_surface_id": fromSurfaceID,
            "text": text,
        ]
        if !targetSurfaceIDs.isEmpty {
            params["target_surface_ids"] = targetSurfaceIDs
        }
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "agent.room.post",
            "params": params,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let line = try #require(String(data: data, encoding: .utf8))
        let responseLine = await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: TerminalController.shared.handleSocketLine(line))
            }
        }
        let responseData = Data(responseLine.utf8)
        let envelope = try #require(JSONSerialization.jsonObject(with: responseData) as? [String: Any])
        #expect(envelope["ok"] as? Bool == true, "agent.room.post envelope: \(envelope)")
        return try #require(envelope["result"] as? [String: Any])
    }
}
