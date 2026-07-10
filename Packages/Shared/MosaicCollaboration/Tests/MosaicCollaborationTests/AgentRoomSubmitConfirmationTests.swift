import Testing
@testable import MosaicCollaboration

/// `AgentRoomSubmitConfirmation` is the pure decision logic the wake-loop in
/// `CollaborationRuntime.wakeAgentRoomSurface` polls to decide whether a
/// return key it sent actually submitted the relay prompt, or whether it was
/// swallowed by the TUI mid-paste-ingest and needs a resend.
@Suite
struct AgentRoomSubmitConfirmationTests {
    @Test
    func confirmsAsSoonAsLifecycleFlipsToRunningRegardlessOfElapsedOrAttempt() {
        let verdict = AgentRoomSubmitConfirmation.verdict(
            attempt: 1,
            lifecycleIsRunning: true,
            elapsedSinceAttempt: 0
        )

        #expect(verdict == .confirmed)
    }

    @Test
    func waitsWhileStillInsideTheAttemptTimeoutWindow() {
        let verdict = AgentRoomSubmitConfirmation.verdict(
            attempt: 1,
            lifecycleIsRunning: false,
            elapsedSinceAttempt: AgentRoomSubmitConfirmation.attemptTimeout - 0.1
        )

        #expect(verdict == .wait)
    }

    @Test
    func resendsTheReturnKeyWhenAnAttemptTimesOutAndAttemptsRemain() {
        let verdict = AgentRoomSubmitConfirmation.verdict(
            attempt: 1,
            lifecycleIsRunning: false,
            elapsedSinceAttempt: AgentRoomSubmitConfirmation.attemptTimeout
        )

        #expect(verdict == .resend)

        let secondAttemptVerdict = AgentRoomSubmitConfirmation.verdict(
            attempt: 2,
            lifecycleIsRunning: false,
            elapsedSinceAttempt: AgentRoomSubmitConfirmation.attemptTimeout
        )

        #expect(secondAttemptVerdict == .resend)
    }

    @Test
    func givesUpAfterExhaustingMaxAttempts() {
        let verdict = AgentRoomSubmitConfirmation.verdict(
            attempt: AgentRoomSubmitConfirmation.maxAttempts,
            lifecycleIsRunning: false,
            elapsedSinceAttempt: AgentRoomSubmitConfirmation.attemptTimeout
        )

        #expect(verdict == .giveUp)
    }

    @Test
    func onlyAConfirmedVerdictAuthorizesConsumingPendingEvents() {
        #expect(AgentRoomSubmitConfirmation.shouldConsume(.confirmed) == true)
        #expect(AgentRoomSubmitConfirmation.shouldConsume(.wait) == false)
        #expect(AgentRoomSubmitConfirmation.shouldConsume(.resend) == false)
        #expect(
            AgentRoomSubmitConfirmation.shouldConsume(.giveUp) == false,
            "a give-up verdict must never advance the room's acknowledgment cursor -- pending events must stay queued for the next natural consume boundary"
        )
    }
}
