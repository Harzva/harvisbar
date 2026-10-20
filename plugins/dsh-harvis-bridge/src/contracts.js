import { Buffer } from 'node:buffer'
import { createHash, randomUUID } from 'node:crypto'

export const BRIDGE_SCHEMA_VERSION = 'harvis.dsh-bridge.v1'
export const BRIDGE_VERSION = '0.2.0'
export const CAPABILITY_CATALOG_SCHEMA_VERSION = 'harvis.dsh-capabilities.v1'
export const USER_INPUTS_SCHEMA_VERSION = 'harvis.dsh-user-inputs.v1'
export const GROUPX_REVIEW_CAPABILITY_ID = 'groupx.review'
export const GROUPX_REVIEW_SCHEMA_VERSION = 'harvis.groupx-review-job.v1'
export const SUPERVISOR_CAPABILITY_ID = 'supervisor.session'
export const SUPERVISOR_SCHEMA_VERSION = 'harvis.dsh-supervisor.v1'
export const SUPERVISOR_OPERATIONS = Object.freeze(['state', 'set', 'regenerate', 'adopt', 'recover'])
export const BRIDGE_PATH = '/harvis-bridge/v1'

export const MAX_REQUEST_BYTES = 64 * 1024
export const MAX_RESPONSE_BYTES = 1024 * 1024
export const MAX_REQUEST_ID_CHARS = 128
export const MAX_SESSION_ID_CHARS = 256
export const MAX_CURSOR_BYTES = 2048
export const MAX_PAGE_LIMIT = 100
export const MAX_ITEM_CHARS = 12_000
export const MAX_ITEMS_PER_SOURCE = 1_000

const SHA256_REVISION = /^sha256:[0-9a-f]{64}$/
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const CONTROL_CHARACTERS = /[\u0000-\u001f\u007f]/u
const UNSAFE_TEXT_CONTROLS = /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/u

/** Error that is safe to convert to a public bridge response. */
export class BridgeProtocolError extends Error {
  /** @param {string} code @param {string} message @param {number} [status] */
  constructor(code, message, status = 400) {
    super(message)
    this.name = 'BridgeProtocolError'
    this.code = code
    this.status = status
  }
}

export function isRecord(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
}

export function hasOnlyKeys(value, keys) {
  if (!isRecord(value)) return false
  const allowed = new Set(keys)
  return Object.keys(value).every(key => allowed.has(key))
}

export function validBoundedString(value, maxChars, { allowEmpty = false } = {}) {
  return typeof value === 'string'
    && (allowEmpty || value.length > 0)
    && value.length <= maxChars
    && !CONTROL_CHARACTERS.test(value)
}

/** User-facing text may contain ordinary line breaks and tabs. */
export function validBoundedText(value, maxChars, { allowEmpty = false } = {}) {
  return typeof value === 'string'
    && (allowEmpty || value.trim().length > 0)
    && Array.from(value).length <= maxChars
    && !UNSAFE_TEXT_CONTROLS.test(value)
}

/**
 * Resolve the immutable authority attached to every response. The caller never
 * supplies authority in a request; this value is deployment configuration plus
 * one process-local runtime id. Runtime identity is deliberately never a
 * configuration field, so a Host restart cannot accidentally reuse it.
 */
export function resolveAuthority(config = {}) {
  if (!isRecord(config)
    || !validBoundedString(config.homeID, 256)
    || !validBoundedString(config.profile, 256)) {
    throw new TypeError('dsh-harvis-bridge: homeID and profile are required')
  }
  const runtimeId = randomUUID()
  if (!validBoundedString(runtimeId, 128)) {
    throw new TypeError('dsh-harvis-bridge: runtimeId must be a bounded string')
  }
  return Object.freeze({ homeID: config.homeID, profile: config.profile, runtimeId })
}

export function authorityWire(authority) {
  return {
    homeID: authority.homeID,
    profile: authority.profile,
    runtimeId: authority.runtimeId,
  }
}

/** Parse and validate the outer request envelope. */
export function parseRequestEnvelope(value) {
  if (!isRecord(value) || !hasOnlyKeys(value, ['schemaVersion', 'requestId', 'method', 'params'])) {
    throw new BridgeProtocolError('invalid-request', 'request envelope is invalid')
  }
  if (value.schemaVersion !== BRIDGE_SCHEMA_VERSION
    || !validBoundedString(value.requestId, MAX_REQUEST_ID_CHARS)
    || !validBoundedString(value.method, 128)
    || !isRecord(value.params)) {
    throw new BridgeProtocolError('invalid-request', 'request envelope is invalid')
  }
  return {
    schemaVersion: value.schemaVersion,
    requestId: value.requestId,
    method: value.method,
    params: value.params,
  }
}

export function parseCapabilitiesParams(value) {
  if (!hasOnlyKeys(value, [])) {
    throw new BridgeProtocolError('invalid-request', 'capabilities.describe params are invalid')
  }
  return {}
}

export function parseUserInputsParams(value) {
  if (!hasOnlyKeys(value, ['sessionId', 'cursor', 'limit'])
    || !validBoundedString(value.sessionId, MAX_SESSION_ID_CHARS)) {
    throw new BridgeProtocolError('invalid-request', 'session.userInputs params are invalid')
  }
  if (value.cursor !== undefined && value.cursor !== null
    && !validBoundedString(value.cursor, MAX_CURSOR_BYTES)) {
    throw new BridgeProtocolError('invalid-request', 'session.userInputs cursor is invalid')
  }
  if (!Number.isSafeInteger(value.limit) || value.limit < 1 || value.limit > MAX_PAGE_LIMIT) {
    throw new BridgeProtocolError('invalid-request', 'session.userInputs limit is invalid')
  }
  return {
    sessionId: value.sessionId,
    cursor: value.cursor ?? undefined,
    limit: value.limit,
  }
}

export function parseGroupxReviewStartParams(value) {
  if (!hasOnlyKeys(value, ['jobId', 'proposalRevision', 'task'])
    || !validBoundedString(value.jobId, 64)
    || !UUID.test(value.jobId)
    || !isSourceRevision(value.proposalRevision)
    || !validBoundedText(value.task, 16_000)) {
    throw new BridgeProtocolError('invalid-request', 'groupx.review.start params are invalid')
  }
  return { jobId: value.jobId, proposalRevision: value.proposalRevision, task: value.task }
}

export function parseGroupxReviewJobParams(value, method) {
  if (!hasOnlyKeys(value, ['jobId', 'proposalRevision'])
    || !validBoundedString(value.jobId, 64)
    || !UUID.test(value.jobId)
    || !isSourceRevision(value.proposalRevision)) {
    throw new BridgeProtocolError('invalid-request', `groupx.review.${method} params are invalid`)
  }
  return { jobId: value.jobId, proposalRevision: value.proposalRevision }
}

export function parseSupervisorStateParams(value) {
  if (!hasOnlyKeys(value, ['sessionId', 'expectedRuntimeId'])
    || !validBoundedString(value.sessionId, MAX_SESSION_ID_CHARS)
    || !validBoundedString(value.expectedRuntimeId, 128)) {
    throw new BridgeProtocolError('invalid-request', 'supervisor.session.state params are invalid')
  }
  return {
    sessionId: value.sessionId,
    expectedRuntimeId: value.expectedRuntimeId,
  }
}

const SUPERVISOR_MODES = new Set(['off', 'advice', 'takeover'])
const SUPERVISOR_STRATEGIES = new Set(['plan', 'insight', 'fixed'])

export function parseSupervisorMutationParams(value, operation) {
  if (!SUPERVISOR_OPERATIONS.includes(operation) || operation === 'state') {
    throw new TypeError('unknown supervisor operation')
  }
  if (!hasOnlyKeys(value, ['sessionId', 'expectedRuntimeId', 'expectedRevision', 'actionId', 'patch'])
    || !validBoundedString(value.sessionId, MAX_SESSION_ID_CHARS)
    || !validBoundedString(value.expectedRuntimeId, 128)
    || !isSourceRevision(value.expectedRevision)
    || !validBoundedString(value.actionId, MAX_REQUEST_ID_CHARS)) {
    throw new BridgeProtocolError('invalid-request', `supervisor.session.${operation} params are invalid`)
  }
  if (operation === 'set'
    && (!isRecord(value.patch) || Object.keys(value.patch).length === 0)) {
    throw new BridgeProtocolError('invalid-request', `supervisor.session.${operation} patch is invalid`)
  }
  if (operation !== 'set' && value.patch !== undefined) {
    throw new BridgeProtocolError('invalid-request', `supervisor.session.${operation} patch is invalid`)
  }
  if (value.patch !== undefined) {
    if (!isRecord(value.patch) || !hasOnlyKeys(value.patch, ['mode', 'strategy', 'rounds', 'intervalMs'])) {
      throw new BridgeProtocolError('invalid-request', `supervisor.session.${operation} patch is invalid`)
    }
    if (value.patch.mode !== undefined && (!validBoundedString(value.patch.mode, 32) || !SUPERVISOR_MODES.has(value.patch.mode))) {
      throw new BridgeProtocolError('invalid-request', `supervisor.session.${operation} patch is invalid`)
    }
    if (value.patch.strategy !== undefined && (!validBoundedString(value.patch.strategy, 32) || !SUPERVISOR_STRATEGIES.has(value.patch.strategy))) {
      throw new BridgeProtocolError('invalid-request', `supervisor.session.${operation} patch is invalid`)
    }
    if (value.patch.rounds !== undefined && (!Number.isSafeInteger(value.patch.rounds) || value.patch.rounds < 1 || value.patch.rounds > 10_000)) {
      throw new BridgeProtocolError('invalid-request', `supervisor.session.${operation} patch is invalid`)
    }
    if (value.patch.intervalMs !== undefined && (!Number.isSafeInteger(value.patch.intervalMs) || value.patch.intervalMs < 2_000 || value.patch.intervalMs > 3_600_000)) {
      throw new BridgeProtocolError('invalid-request', `supervisor.session.${operation} patch is invalid`)
    }
  }
  return {
    sessionId: value.sessionId,
    expectedRuntimeId: value.expectedRuntimeId,
    expectedRevision: value.expectedRevision,
    actionId: value.actionId,
    patch: value.patch === undefined ? undefined : { ...value.patch },
  }
}

export function isSourceRevision(value) {
  return typeof value === 'string' && SHA256_REVISION.test(value)
}

export function sha256Revision(value) {
  return `sha256:${createHash('sha256').update(value).digest('hex')}`
}

/** Stable enough for persistence's opaque revision and immutable inspections. */
export function revisionInput(value) {
  if (typeof value === 'string') return value
  try {
    return JSON.stringify(value)
  } catch {
    return String(value)
  }
}

function encodeBase64Url(text) {
  return Buffer.from(text, 'utf8').toString('base64url')
}

function decodeBase64Url(value) {
  try {
    return Buffer.from(value, 'base64url').toString('utf8')
  } catch {
    throw new BridgeProtocolError('invalid-request', 'cursor is invalid')
  }
}

export function encodeCursor({ sessionId, sourceRevision, offset }) {
  if (!validBoundedString(sessionId, MAX_SESSION_ID_CHARS)
    || !isSourceRevision(sourceRevision)
    || !Number.isSafeInteger(offset)
    || offset < 0
    || offset > MAX_ITEMS_PER_SOURCE) {
    throw new TypeError('cannot encode invalid bridge cursor')
  }
  const value = JSON.stringify({ v: 1, sessionId, sourceRevision, offset })
  const encoded = encodeBase64Url(value)
  if (Buffer.byteLength(encoded, 'utf8') > MAX_CURSOR_BYTES) {
    throw new TypeError('bridge cursor exceeds its byte limit')
  }
  return encoded
}

export function decodeCursor(value) {
  if (!validBoundedString(value, MAX_CURSOR_BYTES)) {
    throw new BridgeProtocolError('invalid-request', 'cursor is invalid')
  }
  let decoded
  try {
    decoded = JSON.parse(decodeBase64Url(value))
  } catch {
    throw new BridgeProtocolError('invalid-request', 'cursor is invalid')
  }
  if (!isRecord(decoded)
    || !hasOnlyKeys(decoded, ['v', 'sessionId', 'sourceRevision', 'offset'])
    || decoded.v !== 1
    || !validBoundedString(decoded.sessionId, MAX_SESSION_ID_CHARS)
    || !isSourceRevision(decoded.sourceRevision)
    || !Number.isSafeInteger(decoded.offset)
    || decoded.offset < 0
    || decoded.offset > MAX_ITEMS_PER_SOURCE) {
    throw new BridgeProtocolError('invalid-request', 'cursor is invalid')
  }
  return {
    sessionId: decoded.sessionId,
    sourceRevision: decoded.sourceRevision,
    offset: decoded.offset,
  }
}

export function capabilityDescriptor({ available, reason } = {}) {
  return {
    id: 'session.userInputs',
    version: 1,
    title: 'Session user inputs',
    scope: 'session',
    operations: ['read'],
    availability: available ? 'available' : 'unavailable',
    ...(available ? {} : { reason: reason ?? 'source-unavailable' }),
    requiresApproval: false,
    supportsCancel: false,
  }
}

export function groupxReviewCapabilityDescriptor({ available, reason } = {}) {
  return {
    id: GROUPX_REVIEW_CAPABILITY_ID,
    version: 1,
    title: 'GroupX project review',
    scope: 'project',
    operations: ['start', 'status', 'cancel'],
    availability: available ? 'available' : 'unavailable',
    ...(available ? {} : { reason: reason ?? 'capability-unavailable' }),
    requiresApproval: false,
    supportsCancel: true,
  }
}

export function supervisorCapabilityDescriptor({ available, reason } = {}) {
  return {
    id: SUPERVISOR_CAPABILITY_ID,
    version: 1,
    title: 'Supervisor session',
    scope: 'session',
    operations: [...SUPERVISOR_OPERATIONS],
    availability: available ? 'available' : 'unavailable',
    ...(available ? {} : { reason: reason ?? 'supervisor-unavailable' }),
    requiresApproval: false,
    supportsCancel: false,
  }
}

export function capabilityCatalog(available, reason, extras = []) {
  return {
    schemaVersion: CAPABILITY_CATALOG_SCHEMA_VERSION,
    bridgeVersion: BRIDGE_VERSION,
    capabilities: [capabilityDescriptor({ available, reason }), ...extras],
  }
}

export function userInputsEmptyPage(sessionId, sourceAvailable, sourceRevision, excludedNonHumanItems = 0) {
  return {
    schemaVersion: USER_INPUTS_SCHEMA_VERSION,
    sessionId,
    sourceAvailable,
    ...(sourceRevision === undefined ? {} : { sourceRevision }),
    items: [],
    nextCursor: null,
    excludedNonHumanItems,
    totalItems: 0,
  }
}

export function successResponse(requestId, authority, value) {
  return {
    schemaVersion: BRIDGE_SCHEMA_VERSION,
    requestId,
    authority: authorityWire(authority),
    result: { ok: true, value },
  }
}

export function failureResponse(requestId, authority, code, message) {
  return {
    schemaVersion: BRIDGE_SCHEMA_VERSION,
    requestId,
    authority: authorityWire(authority),
    result: {
      ok: false,
      error: {
        code,
        ...(message === undefined ? {} : { message }),
      },
    },
  }
}
