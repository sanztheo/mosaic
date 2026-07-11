public import Foundation

/// Pure decision logic for recovering a targeted agent-room wake that
/// `CollaborationRuntime.wakeAgentRoomSurface` deferred because the target's
/// hook-reported lifecycle was `running`.
///
/// Today the only way a deferred wake ever gets delivered is the target's own
/// Stop hook calling `agent.room.wake_flush` once its turn ends. That never
/// fires for a session whose lifecycle got stuck at `running` without a real
/// turn ever starting -- e.g. a pane where the user only ran a built-in slash
/// command (`/model`, `/effort`): `UserPromptSubmit` fires and stamps
/// `agentLifecycle: running`, but the command never calls the model, so no
/// `Stop` hook -- and no `wake_flush` -- ever comes. The pending event then
/// sits deferred forever in a visibly idle pane.
///
/// This type decides what a bounded retry chain should do at each check:
/// keep waiting (`retryLater`), treat the `running` state as stale and
/// bypass the defer gate (`treatAsIdle`), or stop and let the caller surface
/// a stuck-delivery notification (`giveUp`).
public enum AgentRoomDeferredWakeRetry {
    /// One decision from a single check of the retry chain.
    public enum Decision: Equatable, Sendable {
        /// Still plausibly a genuine turn in progress; wait `delay` seconds
        /// and check again.
        case retryLater(delay: TimeInterval)
        /// The `running` state is stale on both available signals: safe to
        /// bypass the defer gate and attempt injection now.
        case treatAsIdle
        /// Retries are exhausted and the state is still ambiguous (running,
        /// but not confidently stale): stop retrying.
        case giveUp
    }

    /// Delay before each successive recheck after a `deferred_running` wake
    /// outcome: a quick recheck, a mid recheck, and a final long recheck
    /// before giving up.
    public static let retryDelays: [TimeInterval] = [15, 45, 120]

    /// A `running` lifecycle is only treated as stale -- and thus safe to
    /// override -- when BOTH the hook store's `updatedAt` age and the
    /// transcript file's mtime age are at least this old. Requiring both
    /// keeps a genuinely streaming turn, which refreshes at least one of the
    /// two signals, from ever being interrupted: `PreToolUse` only refreshes
    /// `updatedAt` at the START of a tool call (there is no `PostToolUse`
    /// hook for Claude), so a single long-running tool call can legitimately
    /// leave `updatedAt` stale for its whole duration.
    public static let staleThreshold: TimeInterval = 90

    /// - Parameters:
    ///   - attempt: 1-indexed count of this check (1 is the first check,
    ///     right after the initial `deferred_running` outcome; each
    ///     subsequent check increments by one).
    ///   - lifecycleIsRunning: whether the target's hook-reported lifecycle
    ///     is currently `running`.
    ///   - updatedAtAge: seconds since the hook session's `updatedAt` was
    ///     last bumped, or `nil` if unavailable.
    ///   - transcriptMTimeAge: seconds since the transcript file was last
    ///     modified, or `nil` if unavailable (no transcript path, or the
    ///     file could not be stat'd). A `nil` signal never counts toward
    ///     staleness -- an unknown signal must not force an override.
    public static func decide(
        attempt: Int,
        lifecycleIsRunning: Bool,
        updatedAtAge: TimeInterval?,
        transcriptMTimeAge: TimeInterval?
    ) -> Decision {
        guard lifecycleIsRunning else { return .treatAsIdle }
        let updatedAtStale = updatedAtAge.map { $0 >= staleThreshold } ?? false
        let transcriptStale = transcriptMTimeAge.map { $0 >= staleThreshold } ?? false
        guard updatedAtStale && transcriptStale else {
            guard attempt >= 1, attempt <= retryDelays.count else { return .giveUp }
            return .retryLater(delay: retryDelays[attempt - 1])
        }
        return .treatAsIdle
    }
}
