import { sha256Revision, MAX_ITEM_CHARS, MAX_ITEMS_PER_SOURCE } from './contracts.js'

const DEFAULT_INTERNAL_SESSION_PREFIXES = Object.freeze(['harvis-review-', 'harvis-organizer-'])
const DEFAULT_INTERNAL_AGENT_PRESETS = Object.freeze(['harzva-meta', 'delivery-manager'])

function isObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
}

function codePointCount(value) {
  return Array.from(value).length
}

function boundedText(value) {
  const points = Array.from(value)
  if (points.length <= MAX_ITEM_CHARS) {
    return { text: value, originalCharacterCount: points.length, truncated: false }
  }
  return {
    text: points.slice(0, MAX_ITEM_CHARS).join(''),
    originalCharacterCount: points.length,
    truncated: true,
  }
}

/** Return only visible text blocks, preserving block order and boundaries. */
export function textFromContent(content) {
  if (!Array.isArray(content)) return ''
  return content
    .filter(block => isObject(block) && block.type === 'text' && typeof block.text === 'string')
    .map(block => block.text)
    .join('\n')
}

function messageID(data, sessionId, sequence) {
  if (isObject(data) && typeof data.id === 'string' && data.id.length > 0 && data.id.length <= 256) {
    return data.id
  }
  return `${sessionId}:${sequence}`
}

function sourceClass(data) {
  if (!isObject(data) || data.role !== 'user') return undefined
  const source = isObject(data) && isObject(data.source) ? data.source : undefined
  if (source?.kind !== 'user') return undefined
  // The Host API's prompt path attaches rpcId to the same source kind. Its
  // presence proves transport admission, but not a natural-person author.
  return Object.prototype.hasOwnProperty.call(source, 'rpcId') ? 'unknown' : 'human'
}

function timestampOf(time) {
  if (!Number.isFinite(time) || time < 0) return undefined
  const value = new Date(time)
  return Number.isNaN(value.getTime()) ? undefined : value.toISOString()
}

function turnOf(turn) {
  return Number.isSafeInteger(turn) && turn >= 0 ? String(turn) : undefined
}

function projectItem(sessionId, event, turnId, source) {
  const data = event.data
  const fullText = textFromContent(isObject(data) ? data.content : undefined)
  if (fullText.length === 0) return undefined
  const bounded = boundedText(fullText)
  const id = messageID(data, sessionId, event.seq)
  return {
    id,
    sequence: event.seq,
    ...(turnId === undefined ? {} : { turnId }),
    ...(timestampOf(event.time) === undefined ? {} : { timestamp: timestampOf(event.time) }),
    text: bounded.text,
    truncated: bounded.truncated,
    originalCharacterCount: bounded.originalCharacterCount,
    source,
    ...(typeof data?.id === 'string' && data.id.length > 0
      ? { originMessageIDHash: sha256Revision(data.id) }
      : {}),
  }
}

/**
 * Project an immutable SessionInspection into Harvis-safe text evidence.
 * The full event log never leaves this function; callers receive only bounded
 * records and the count of user-role records intentionally excluded.
 */
export function collectUserInputs(sessionId, inspection) {
  const records = []
  let totalItems = 0
  let excludedNonHumanItems = 0
  let activeTurn

  for (const event of inspection?.events ?? []) {
    if (!isObject(event)) continue
    if (event.type === 'turn/start') {
      activeTurn = turnOf(event.data?.turn)
      continue
    }
    if (event.type === 'turn/end') {
      activeTurn = undefined
      continue
    }

    // Tool results are user-role model context, never human inputs.
    if (event.type === 'tool/result') {
      excludedNonHumanItems += 1
      continue
    }
    if (event.type !== 'user/message') continue

    const source = sourceClass(event.data)
    if (source === undefined) {
      excludedNonHumanItems += 1
      continue
    }
    const item = projectItem(sessionId, event, activeTurn, source)
    if (item === undefined) {
      // Image-only or otherwise non-text prompts cannot be sent as text
      // evidence. Count them so the caller can explain the omission.
      excludedNonHumanItems += 1
      continue
    }
    totalItems += 1
    // Keep one sentinel beyond Harvis' normal read bound so a direct caller
    // can advance a cursor at the bound without receiving an endless cursor.
    if (records.length <= MAX_ITEMS_PER_SOURCE) records.push(item)
  }

  return {
    items: records,
    totalItems,
    excludedNonHumanItems,
  }
}

export function isInternalSession(meta, policy = {}) {
  const id = meta?.id
  const agentPreset = meta?.agentPreset
  if (typeof id !== 'string') return false
  if (Array.isArray(policy.internalSessionIds) && policy.internalSessionIds.includes(id)) return true
  if (Array.isArray(policy.internalSessionPrefixes)
    && policy.internalSessionPrefixes.some(prefix => id.startsWith(prefix))) return true
  return typeof agentPreset === 'string'
    && Array.isArray(policy.internalAgentPresets)
    && policy.internalAgentPresets.includes(agentPreset)
}

export function validatePolicy(policy = {}) {
  if (!isObject(policy)) throw new TypeError('dsh-harvis-bridge: policy must be an object')
  const keys = ['internalSessionIds', 'internalSessionPrefixes', 'internalAgentPresets']
  for (const key of keys) {
    if (policy[key] === undefined) continue
    if (!Array.isArray(policy[key])
      || policy[key].some(value => typeof value !== 'string' || value.length === 0 || value.length > 256)) {
      throw new TypeError(`dsh-harvis-bridge: ${key} must be a list of bounded strings`)
    }
  }
  return Object.freeze({
    internalSessionIds: Object.freeze([...(policy.internalSessionIds ?? [])]),
    internalSessionPrefixes: Object.freeze([
      ...DEFAULT_INTERNAL_SESSION_PREFIXES,
      ...(policy.internalSessionPrefixes ?? []),
    ]),
    internalAgentPresets: Object.freeze([
      ...DEFAULT_INTERNAL_AGENT_PRESETS,
      ...(policy.internalAgentPresets ?? []),
    ]),
  })
}

export { codePointCount }
