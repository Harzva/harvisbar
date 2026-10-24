import Foundation

struct HarvisGroupMemory: Codable, Equatable, Sendable {
    var summary = ""
    var keyDecisions: [String] = []
    var openItems: [String] = []
}

struct HarvisGroupSubmissionReceipt: Codable, Equatable, Sendable {
    let groupID: UUID
    let messageID: UUID
    let runID: UUID?
    let dispatchIDs: [UUID]
}

struct HarvisGroupRequestReceipt: Codable, Equatable, Sendable {
    let requestID: String
    let payloadHash: String
    let receipt: HarvisGroupSubmissionReceipt
}

enum HarvisGroupRunState: String, Codable, Sendable {
    case planning, working, reviewing, completed, needsInput, deliveryUnknown, cancelled, failed
    var isTerminal: Bool { self == .completed || self == .cancelled || self == .failed }
}

enum HarvisGroupStepState: String, Codable, Sendable { case planned, enqueueStarted, submitted, finished, deliveryUnknown, cancelled }

struct HarvisGroupRunStep: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var memberID: UUID
    var task: String
    var dependencies: [String] = []
    var dispatchID: UUID = UUID()
    var state: HarvisGroupStepState = .planned
}

struct HarvisGroupRun: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var requestID: String?
    var rootMessageID: UUID
    var ownerMemberID: UUID?
    var ownerBinding: HarvisGroupBinding?
    var permission: HarvisGroupPermission
    var state: HarvisGroupRunState
    var ownerDispatchID: UUID?
    var ownerDispatchState: HarvisGroupStepState = .planned
    var ownerRound = 0
    var roundLimit = 8
    var taskLimit = 24
    var processedOwnerTurns: [String] = []
    var steps: [HarvisGroupRunStep] = []
    var summary = ""
    var lastError: String?
}

struct HarvisGroupOrchestrationConfiguration: Codable, Equatable, Sendable {
    var ownerMemberID: UUID?
    var projectPermission: HarvisGroupPermission = .discussion
    var backgroundEnabled = false
    var runs: [HarvisGroupRun] = []
    var memory = HarvisGroupMemory()
    var memorySequence = 0
    var requests: [HarvisGroupRequestReceipt] = []
}

enum HarvisGroupMessageOrigin: Codable, Equatable, Sendable {
    case user
    case ownerPlan(runID: UUID, sourceDispatchID: UUID, stepID: String)
    case ownerReview(runID: UUID)
}

struct HarvisGroupOwnerDecision: Codable, Equatable, Sendable {
    enum Action: String, Codable, Sendable { case assign, complete, needsInput }
    struct Assignment: Codable, Equatable, Sendable {
        let id: String
        let memberID: UUID
        let task: String
        let dependencies: [String]
    }
    let action: Action
    let summary: String
    let assignments: [Assignment]
    let memory: HarvisGroupMemory
}
