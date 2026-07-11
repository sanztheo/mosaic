import Testing
@testable import MosaicCollaboration

/// `AgentRoomDeferredWakeRetry` is the pure decision logic a bounded retry
/// chain in `CollaborationRuntime` polls after `wakeAgentRoomSurface` returns
/// `deferred_running`, so a target stuck at `running` with no real turn in
/// progress (e.g. a pane whose only prompt was a built-in slash command) is
/// eventually reaped instead of stranding the pending event forever.
@Suite
struct AgentRoomDeferredWakeRetryTests {
    @Test
    func retriesAtTheExpectedDelaysWhileRunningAndFresh() {
        let firstCheck = AgentRoomDeferredWakeRetry.decide(
            attempt: 1,
            lifecycleIsRunning: true,
            updatedAtAge: 0,
            transcriptMTimeAge: 0
        )
        #expect(firstCheck == .retryLater(delay: 15))

        let secondCheck = AgentRoomDeferredWakeRetry.decide(
            attempt: 2,
            lifecycleIsRunning: true,
            updatedAtAge: 15,
            transcriptMTimeAge: 15
        )
        #expect(secondCheck == .retryLater(delay: 45))

        let thirdCheck = AgentRoomDeferredWakeRetry.decide(
            attempt: 3,
            lifecycleIsRunning: true,
            updatedAtAge: 60,
            transcriptMTimeAge: 60
        )
        #expect(thirdCheck == .retryLater(delay: 120))
    }

    @Test
    func givesUpAfterTheLastRetryWhenStillAmbiguous() {
        let verdict = AgentRoomDeferredWakeRetry.decide(
            attempt: 4,
            lifecycleIsRunning: true,
            updatedAtAge: 89,
            transcriptMTimeAge: 89
        )
        #expect(verdict == .giveUp)
    }

    @Test
    func treatsAsIdleOnlyWhenBothSignalsAreStale() {
        let bothStale = AgentRoomDeferredWakeRetry.decide(
            attempt: 1,
            lifecycleIsRunning: true,
            updatedAtAge: 90,
            transcriptMTimeAge: 90
        )
        #expect(bothStale == .treatAsIdle)

        let onlyUpdatedAtStale = AgentRoomDeferredWakeRetry.decide(
            attempt: 1,
            lifecycleIsRunning: true,
            updatedAtAge: 200,
            transcriptMTimeAge: 5
        )
        #expect(onlyUpdatedAtStale == .retryLater(delay: 15))

        let onlyTranscriptStale = AgentRoomDeferredWakeRetry.decide(
            attempt: 1,
            lifecycleIsRunning: true,
            updatedAtAge: 5,
            transcriptMTimeAge: 200
        )
        #expect(onlyTranscriptStale == .retryLater(delay: 15))
    }

    @Test
    func neverOverridesAGenuinelyRunningSessionOnAFreshSignal() {
        // A single long-running tool call can leave `updatedAt` stale for its
        // whole duration (no PostToolUse hook refreshes it mid-call), but the
        // transcript keeps growing -- that fresh transcript alone must keep
        // this from ever being treated as idle.
        let freshTranscriptOnly = AgentRoomDeferredWakeRetry.decide(
            attempt: 3,
            lifecycleIsRunning: true,
            updatedAtAge: 999,
            transcriptMTimeAge: 1
        )
        #expect(freshTranscriptOnly != .treatAsIdle)

        let freshUpdatedAtOnly = AgentRoomDeferredWakeRetry.decide(
            attempt: 3,
            lifecycleIsRunning: true,
            updatedAtAge: 1,
            transcriptMTimeAge: 999
        )
        #expect(freshUpdatedAtOnly != .treatAsIdle)
    }

    @Test
    func unknownTranscriptSignalNeverForcesAnOverride() {
        let verdict = AgentRoomDeferredWakeRetry.decide(
            attempt: 1,
            lifecycleIsRunning: true,
            updatedAtAge: 200,
            transcriptMTimeAge: nil
        )
        #expect(verdict == .retryLater(delay: 15))
    }

    @Test
    func notRunningIsTreatedAsIdleRegardlessOfAttemptOrAge() {
        let verdict = AgentRoomDeferredWakeRetry.decide(
            attempt: 1,
            lifecycleIsRunning: false,
            updatedAtAge: 0,
            transcriptMTimeAge: 0
        )
        #expect(verdict == .treatAsIdle)
    }
}
