import Foundation

/// The small editable portion of a DSH Supervisor projection.
///
/// A draft is intentionally tied to one session and one last reviewed
/// revision.  Progress fields (used/status/remaining) are not part of this
/// value: they can change while a user is editing settings without making the
/// edit unsafe.  A changed Supervisor setting, however, is a conflict until
/// the user explicitly chooses the latest settings or rechecks the session.
struct ManagedSupervisorSettingsDraft: Equatable, Sendable {
    enum Field: String, CaseIterable, Hashable, Sendable {
        case mode
        case strategy
        case rounds
        case intervalMs
    }

    struct Values: Equatable, Sendable {
        var mode: String
        var strategy: String
        var rounds: Int
        var intervalMs: Int

        init(state: DshSupervisorState) {
            mode = state.mode
            strategy = state.strategy
            rounds = state.rounds
            intervalMs = state.intervalMs
        }

        init(mode: String, strategy: String, rounds: Int, intervalMs: Int) {
            self.mode = mode
            self.strategy = strategy
            self.rounds = rounds
            self.intervalMs = intervalMs
        }

        var intervalSeconds: Int {
            get { max(2, intervalMs / 1_000) }
            set { intervalMs = newValue * 1_000 }
        }

        func changedFields(comparedTo other: Self) -> Set<Field> {
            var result: Set<Field> = []
            if mode != other.mode { result.insert(.mode) }
            if strategy != other.strategy { result.insert(.strategy) }
            if rounds != other.rounds { result.insert(.rounds) }
            if intervalMs != other.intervalMs { result.insert(.intervalMs) }
            return result
        }
    }

    /// Identity of the card that owns this draft.  Session IDs are scoped to a
    /// provider/runtime, so a draft must not survive a card replacement just
    /// because the next card happens to expose the same source ID.
    let identity: String
    let sessionID: String
    private(set) var baseRevision: String
    private(set) var baseline: Values
    private(set) var values: Values
    private(set) var conflictFields: Set<Field>

    /// Fields that differ from the last reviewed settings.  A field becomes
    /// clean again when the user edits it back to the baseline value.
    private(set) var dirtyFields: Set<Field>

    /// The latest remote settings are retained while a conflict is shown so a
    /// caller can offer an explicit "use latest" action without losing the
    /// user's draft first.
    private(set) var latestRemoteValues: Values?
    private(set) var latestRemoteRevision: String?

    init(state: DshSupervisorState, identity: String? = nil) {
        let settings = Values(state: state)
        self.identity = identity ?? state.sessionID
        sessionID = state.sessionID
        baseRevision = state.revision
        baseline = settings
        values = settings
        conflictFields = []
        dirtyFields = []
        latestRemoteValues = nil
        latestRemoteRevision = nil
    }

    init(state: DshSupervisorState, threadID: String) {
        self.init(state: state, identity: threadID)
    }

    var isDirty: Bool { !dirtyFields.isEmpty }
    var isConflicted: Bool { !conflictFields.isEmpty }
    var canSubmit: Bool { isDirty && !isConflicted }

    var mode: String { values.mode }
    var strategy: String { values.strategy }
    var rounds: Int { values.rounds }
    var intervalMs: Int { values.intervalMs }
    var intervalSeconds: Int { values.intervalSeconds }

    /// Returns only fields edited by the user.  A nil result means there is no
    /// safe mutation to send (clean or conflicted drafts must not be applied).
    func patch() -> DshSupervisorPatch? {
        guard canSubmit else { return nil }
        return DshSupervisorPatch(
            mode: dirtyFields.contains(.mode) ? values.mode : nil,
            strategy: dirtyFields.contains(.strategy) ? values.strategy : nil,
            rounds: dirtyFields.contains(.rounds) ? values.rounds : nil,
            intervalMs: dirtyFields.contains(.intervalMs) ? values.intervalMs : nil
        )
    }

    mutating func setMode(_ value: String) {
        values.mode = value
        updateDirty(.mode)
    }

    mutating func setStrategy(_ value: String) {
        values.strategy = value
        updateDirty(.strategy)
    }

    mutating func setRounds(_ value: Int) {
        values.rounds = value
        updateDirty(.rounds)
    }

    mutating func setIntervalMs(_ value: Int) {
        values.intervalMs = value
        updateDirty(.intervalMs)
    }

    mutating func setIntervalSeconds(_ value: Int) {
        values.intervalSeconds = value
        updateDirty(.intervalMs)
    }

    /// Observe a newly read provider state.  A progress-only change advances
    /// the revision while preserving the user's edits.  A settings change
    /// becomes a conflict whenever the draft is dirty.
    mutating func observe(_ state: DshSupervisorState, identity: String? = nil) {
        let observedIdentity = identity ?? self.identity
        guard observedIdentity == self.identity, state.sessionID == sessionID else {
            self = Self(state: state, identity: observedIdentity)
            return
        }

        let remote = Values(state: state)
        if remote == values {
            // An explicit read can reconcile a lost save response. The current
            // settings already match the edit, so another write is unnecessary.
            self = Self(state: state, identity: self.identity)
            return
        }
        guard isDirty else {
            baseRevision = state.revision
            baseline = remote
            values = remote
            conflictFields = []
            latestRemoteValues = nil
            latestRemoteRevision = nil
            return
        }

        let changed = remote.changedFields(comparedTo: baseline)
        baseRevision = state.revision
        if changed.isEmpty {
            conflictFields = []
            latestRemoteValues = nil
            latestRemoteRevision = nil
        } else {
            conflictFields = changed
            latestRemoteValues = remote
            latestRemoteRevision = state.revision
        }
    }

    /// Explicitly discard local edits and use the latest provider settings.
    mutating func useLatestSettings(_ state: DshSupervisorState) {
        self = Self(state: state, identity: identity)
    }

    /// Replace a successful submission with its read-back state.  Keeping this
    /// operation explicit ensures failed or ambiguous requests leave the draft
    /// untouched for the caller to reconcile.
    mutating func markSubmissionSucceeded(with state: DshSupervisorState) {
        self = Self(state: state, identity: identity)
    }

    /// Synonyms kept at the model boundary make the ownership relationship
    /// explicit to callers that refer to the card as a thread.
    var cardIdentity: String { identity }
    var threadID: String { identity }

    private mutating func updateDirty(_ field: Field) {
        let matchesBaseline: Bool
        switch field {
        case .mode: matchesBaseline = values.mode == baseline.mode
        case .strategy: matchesBaseline = values.strategy == baseline.strategy
        case .rounds: matchesBaseline = values.rounds == baseline.rounds
        case .intervalMs: matchesBaseline = values.intervalMs == baseline.intervalMs
        }
        if matchesBaseline {
            dirtyFields.remove(field)
        } else {
            dirtyFields.insert(field)
        }
    }
}
