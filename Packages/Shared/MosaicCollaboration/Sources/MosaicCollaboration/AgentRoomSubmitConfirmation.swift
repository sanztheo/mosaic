public import Foundation

/// Pure decision logic for confirming that a relay prompt typed into a peer
/// pane by `CollaborationRuntime.wakeAgentRoomSurface` was actually
/// submitted, not just pasted.
///
/// A bracketed-paste followed by a return key can land in a TUI that hasn't
/// finished ingesting the paste yet, silently swallowing the return and
/// leaving the block sitting unsubmitted at the prompt. Rather than trust a
/// single fixed sleep, the wake loop polls the target's own hook-reported
/// lifecycle for evidence the agent actually started a turn, and re-sends the
/// return key on timeout, up to a bounded number of attempts.
public enum AgentRoomSubmitConfirmation {
    /// One decision from a single poll tick of the confirmation loop.
    public enum Verdict: Equatable, Sendable {
        /// The target's lifecycle flipped to `running`: the submit landed.
        case confirmed
        /// Not yet running, but still inside the current attempt's timeout
        /// window -- keep polling.
        case wait
        /// The current attempt's timeout elapsed with no confirmation and
        /// another attempt is available: re-send the return key.
        case resend
        /// The current attempt's timeout elapsed and no attempts remain.
        case giveUp
    }

    /// Total return-key sends allowed across the whole confirmation loop
    /// (the initial send plus any resends).
    public static let maxAttempts = 3

    /// How long a single attempt waits for the lifecycle to flip to
    /// `running` before either resending or giving up.
    public static let attemptTimeout: TimeInterval = 3.0

    /// Delay between polls within a single attempt's timeout window.
    public static let pollInterval: TimeInterval = 0.3

    /// - Parameters:
    ///   - attempt: 1-indexed count of return-key sends issued so far,
    ///     including the one that started the current wait window.
    ///   - lifecycleIsRunning: whether the target's hook-reported lifecycle
    ///     has been observed as `running` since the current attempt's return
    ///     key was sent.
    ///   - elapsedSinceAttempt: seconds elapsed since the current attempt's
    ///     return key was sent.
    public static func verdict(
        attempt: Int,
        lifecycleIsRunning: Bool,
        elapsedSinceAttempt: TimeInterval
    ) -> Verdict {
        if lifecycleIsRunning { return .confirmed }
        guard elapsedSinceAttempt >= attemptTimeout else { return .wait }
        return attempt < maxAttempts ? .resend : .giveUp
    }

    /// Whether a verdict authorizes advancing the room's acknowledgment
    /// cursor. Only `.confirmed` does: a `.giveUp` must leave pending events
    /// untouched so they survive for the Stop-hook `wake_flush` or the next
    /// natural consume boundary instead of being silently dropped.
    public static func shouldConsume(_ verdict: Verdict) -> Bool {
        verdict == .confirmed
    }
}
