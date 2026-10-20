import {
  BridgeProtocolError,
  MAX_ITEM_CHARS,
  SUPERVISOR_SCHEMA_VERSION,
  isRecord,
  sha256Revision,
  supervisorCapabilityDescriptor,
  validBoundedString,
} from './contracts.js'

const SUPERVISE_COMMAND = 'supervise'
const SUPERVISOR_MODES = new Set(['off', 'advice', 'takeover'])
const SUPERVISOR_STRATEGIES = new Set(['plan', 'insight', 'fixed'])
const SUPERVISOR_STATUSES = new Set(['off', 'recovery', 'working', 'thinking', 'suggested', 'silent'])
const NATIVE_BUSY_STATUSES = new Set([
  'running',
  'working',
  'waitingApproval',
  'waiting-approval',
  'pendingApproval',
  'pending-approval',
])
const MAX_ACTION_RECORDS = 4096
const UNSAFE_TEXT_CONTROLS = /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/u

function protocolError(code, message) {
  return new BridgeProtocolError(code, message, 200)
}

function rootsOf(agents) {
  if (agents === undefined || agents === null || typeof agents.roots !== 'function') return undefined
  try {
    const roots = agents.roots()
    if (Array.isArray(roots)) return roots
    if (roots !== undefined && roots !== null && typeof roots[Symbol.iterator] === 'function') {
      return [...roots]
    }
  } catch {
    // Discovery is deliberately fail-closed. Callers receive an unavailable
    // capability instead of falling back to an id-based or session lookup.
  }
  return undefined
}

function registeredCommand(commands, agent) {
  if (commands === undefined || commands === null || agent === undefined) return undefined
  try {
    if (typeof commands.find === 'function') {
      return commands.find(agent, SUPERVISE_COMMAND)
    }
  } catch {
    return undefined
  }
  // `find` is the native CommandRuntime contract. The list fallback keeps
  // capability discovery useful for small Host test doubles, but execution
  // still requires the real `commands.execute` method below.
  try {
    if (typeof commands.list === 'function') {
      const listed = commands.list(agent)
      if (Array.isArray(listed) && listed.some(item => item?.name === SUPERVISE_COMMAND)) {
        return { name: SUPERVISE_COMMAND }
      }
    }
  } catch {
    // Treat a registry read failure as an unavailable command.
  }
  return undefined
}

function hasCommand(commands, agent) {
  return registeredCommand(commands, agent) !== undefined
    && typeof commands?.execute === 'function'
}

/**
 * Discover the Host-side command registration without importing or copying
 * Supervisor implementation details. The installed dsh-supervisor package
 * registers `/supervise` into this CommandRuntime; the bridge only consumes
 * that existing registration.
 */
export function discoverSupervisor({ agents, commands } = {}) {
  if (agents === undefined || commands === undefined
    || typeof agents?.get !== 'function'
    || typeof commands?.execute !== 'function') {
    return { available: false, reason: 'supervisor-unavailable' }
  }
  const roots = rootsOf(agents)
  if (roots === undefined) return { available: false, reason: 'supervisor-unavailable' }
  for (const root of roots) {
    if (root !== undefined && root !== null && hasCommand(commands, root)) {
      return { available: true, reason: undefined }
    }
  }
  return { available: false, reason: 'supervise-command-unavailable' }
}

function resolveTarget({ agents, commands }, sessionId) {
  if (agents === undefined || commands === undefined
    || typeof agents?.get !== 'function'
    || typeof commands?.execute !== 'function') {
    throw protocolError('capability-unavailable', 'Supervisor is unavailable')
  }
  let agent
  try { agent = agents.get(sessionId) } catch { agent = undefined }
  if (agent === undefined || agent === null) {
    throw protocolError('session-unavailable', 'session is not loaded')
  }
  // Identity is intentionally exact. A Host must not substitute a same-id
  // session object or resolve a session by searching a different registry.
  if (agent.id !== sessionId || agent.session?.id !== sessionId) {
    throw protocolError('session-unavailable', 'session identity is unavailable')
  }
  const roots = rootsOf(agents)
  if (roots === undefined || !roots.some(root => root === agent)) {
    throw protocolError('unsupported-session', 'Supervisor only supports a top-level session')
  }
  if (!hasCommand(commands, agent)) {
    throw protocolError('unsupported-session', 'Supervisor command is unavailable for this session')
  }
  return { agent, commands }
}

function canonicalJson(value) {
  if (Array.isArray(value)) return '[' + value.map(canonicalJson).join(',') + ']'
  if (isRecord(value)) {
    return '{' + Object.keys(value).sort().map(key => JSON.stringify(key) + ':' + canonicalJson(value[key])).join(',') + '}'
  }
  const encoded = JSON.stringify(value)
  return encoded === undefined ? 'null' : encoded
}

function optionalText(value) {
  if (value === undefined || value === null) return ''
  if (typeof value !== 'string' || UNSAFE_TEXT_CONTROLS.test(value)
    || Array.from(value).length > MAX_ITEM_CHARS) {
    throw protocolError('invalid-state', 'Supervisor returned an invalid text field')
  }
  return value
}

function boundedIdentifier(value) {
  if (value === undefined || value === null) return ''
  if (!validBoundedString(value, MAX_ITEM_CHARS, { allowEmpty: true })) {
    throw protocolError('invalid-state', 'Supervisor returned an invalid identifier')
  }
  return value
}

function firstText(...values) {
  for (const value of values) {
    const text = optionalText(value)
    if (text.length > 0) return text
  }
  return ''
}

function agentStatusOf(agent) {
  const candidates = [
    agent?.status,
    agent?.executionStatus,
    agent?.agentStatus,
    agent?.session?.status,
    agent?.session?.executionStatus,
  ]
  for (const value of candidates) {
    if (typeof value === 'string' && validBoundedString(value, 128)) return value
  }
  if (agent?.waitingApproval === true || agent?.session?.waitingApproval === true) return 'waitingApproval'
  return ''
}

function busyAgent(agent, state) {
  if (agent?.waitingApproval === true || agent?.session?.waitingApproval === true) return true
  return [agentStatusOf(agent), state.agentStatus, state.status].some(value => NATIVE_BUSY_STATUSES.has(value))
}

/**
 * Project only the fixed Supervisor state contract. Native `_state` contains
 * additional mentor, plan, memory, and execution bookkeeping. Those details
 * stay Host-local; only the bounded fields used by Harvis cross this bridge.
 */
export function normalizeSupervisorProjection(sessionId, raw, agent) {
  if (!isRecord(raw)) throw protocolError('invalid-state', 'Supervisor returned an invalid state')
  const execution = isRecord(raw.execution) ? raw.execution : undefined
  if (execution === undefined
    || !SUPERVISOR_MODES.has(raw.mode)
    || !SUPERVISOR_STRATEGIES.has(raw.strategy)
    || !Number.isSafeInteger(raw.rounds) || raw.rounds < 1 || raw.rounds > 10_000
    || !Number.isSafeInteger(raw.used) || raw.used < 0 || raw.used > 10_000
    || !Number.isSafeInteger(raw.intervalMs) || raw.intervalMs < 2_000 || raw.intervalMs > 3_600_000
    || !SUPERVISOR_STATUSES.has(raw.status)
    || !Number.isSafeInteger(execution.remaining) || execution.remaining < 0 || execution.remaining > 10_000
    || typeof execution.done !== 'boolean'
    || !validBoundedString(execution.runId, MAX_ITEM_CHARS)) {
    throw protocolError('invalid-state', 'Supervisor returned an invalid state')
  }
  const mode = raw.mode
  const strategy = raw.strategy
  const rounds = raw.rounds
  const used = raw.used
  const remaining = execution.remaining
  const suggestion = optionalText(raw.suggestion)
  const suggestError = optionalText(raw.suggestError)
  const suggestionId = boundedIdentifier(execution.suggestionId ?? raw.suggestionId)
  const runId = execution.runId
  const recoveryRequired = optionalText(execution.recoveryRequired ?? raw.recoveryRequired)
  const agentStatus = agentStatusOf(agent)
  const status = raw.status
  const mentor = isRecord(raw.mentor) ? raw.mentor : {}
  const mentorName = firstText(mentor.name, mentor.displayName, mentor.title)
  const done = execution.done
  const projection = {
    schemaVersion: SUPERVISOR_SCHEMA_VERSION,
    sessionId,
    mode,
    strategy,
    rounds,
    used,
    intervalMs: raw.intervalMs,
    status,
    suggestion,
    suggestionId,
    runId,
    recoveryRequired,
    done,
    remaining,
    agentStatus,
    mentorName,
    suggestError,
  }
  const semantic = { ...projection }
  projection.revision = sha256Revision(canonicalJson(semantic))
  return {
    schemaVersion: projection.schemaVersion,
    sessionId: projection.sessionId,
    revision: projection.revision,
    mode: projection.mode,
    strategy: projection.strategy,
    rounds: projection.rounds,
    used: projection.used,
    intervalMs: projection.intervalMs,
    status: projection.status,
    suggestion: projection.suggestion,
    suggestionId: projection.suggestionId,
    runId: projection.runId,
    recoveryRequired: projection.recoveryRequired,
    done: projection.done,
    remaining: projection.remaining,
    agentStatus: projection.agentStatus,
    mentorName: projection.mentorName,
    suggestError: projection.suggestError,
  }
}

async function executeCommand(target, line, lifecycle = {}) {
  const controller = new AbortController()
  lifecycle.activeControllers?.add(controller)
  const call = Promise.resolve().then(() => target.commands.execute(
    target.agent, line, [], controller.signal
  ))
  lifecycle.activeCommands?.add(call)
  let execution
  try {
    execution = await call
  } catch {
    throw protocolError('action-unknown', 'Supervisor command result is unknown')
  } finally {
    lifecycle.activeControllers?.delete(controller)
    lifecycle.activeCommands?.delete(call)
  }
  if (!isRecord(execution) || !isRecord(execution.result)) {
    throw protocolError('action-unknown', 'Supervisor command result is unknown')
  }
  const result = execution.result
  if (result.kind === 'error') {
    throw protocolError('action-unavailable', 'Supervisor action is unavailable')
  }
  if (result.kind !== 'success' || typeof result.text !== 'string' || result.text.length === 0) {
    throw protocolError('action-unknown', 'Supervisor command result is unknown')
  }
  let value
  try { value = JSON.parse(result.text) } catch {
    throw protocolError('action-unknown', 'Supervisor command result is unknown')
  }
  return value
}

function assertActionAllowed(operation, state, agent) {
  if (operation === 'set') return
  if (operation === 'recover') return
  if (operation === 'regenerate') {
    if (state.mode === 'off' || state.recoveryRequired || state.done || state.remaining <= 0
      || state.status === 'working' || state.status === 'thinking' || busyAgent(agent, state)) {
      throw protocolError('action-unavailable', 'Supervisor cannot regenerate in the current state')
    }
    return
  }
  if (operation === 'adopt') {
    if (state.mode === 'off' || state.recoveryRequired || state.done || state.remaining <= 0
      || state.suggestion.length === 0 || state.suggestionId.length === 0
      || state.status === 'working' || state.status === 'thinking' || busyAgent(agent, state)) {
      throw protocolError('action-unavailable', 'Supervisor cannot adopt in the current state')
    }
    return
  }
  throw protocolError('capability-unavailable', 'Supervisor operation is unavailable')
}

function actionLine(operation, patch) {
  if (operation === 'set') return '/supervise _set ' + JSON.stringify(patch ?? {})
  if (operation === 'regenerate') return '/supervise _regen'
  if (operation === 'adopt') return '/supervise _adopt'
  if (operation === 'recover') return '/supervise _recover'
  throw protocolError('capability-unavailable', 'Supervisor operation is unavailable')
}

function queueForSession(queues, sessionId, task) {
  const previous = queues.get(sessionId) ?? Promise.resolve()
  const run = previous.catch(() => {}).then(task)
  const tail = run.then(() => {
    if (queues.get(sessionId) === tail) queues.delete(sessionId)
  }, () => {
    if (queues.get(sessionId) === tail) queues.delete(sessionId)
  })
  queues.set(sessionId, tail)
  return run
}

/** Construct one bridge-local Supervisor adapter for one Host process. */
export function createSupervisorController({ authority, getServices } = {}) {
  const queues = new Map()
  const actions = new Map()
  const activeControllers = new Set()
  const activeCommands = new Set()
  let disposed = false

  const services = () => {
    try { return getServices?.() ?? {} } catch { return {} }
  }

  const descriptor = () => supervisorCapabilityDescriptor(discoverSupervisor(services()))

  const assertRuntime = expectedRuntimeId => {
    if (expectedRuntimeId !== authority?.runtimeId) {
      throw protocolError('runtime-mismatch', 'Supervisor runtime identity does not match')
    }
  }

  const assertActive = () => {
    if (disposed) throw protocolError('capability-unavailable', 'Supervisor bridge is unavailable')
  }

  const read = params => {
    assertActive()
    assertRuntime(params.expectedRuntimeId)
    return queueForSession(queues, params.sessionId, async () => {
      assertActive()
      const target = resolveTarget(services(), params.sessionId)
      const raw = await executeCommand(target, '/supervise _state', { activeControllers, activeCommands })
      return normalizeSupervisorProjection(params.sessionId, raw, target.agent)
    })
  }

  const mutate = (operation, params) => {
    try { assertActive() } catch (error) { return Promise.reject(error) }
    assertRuntime(params.expectedRuntimeId)
    const payload = {
      operation,
      sessionId: params.sessionId,
      expectedRuntimeId: params.expectedRuntimeId,
      expectedRevision: params.expectedRevision,
      actionId: params.actionId,
      patch: params.patch ?? null,
    }
    const payloadHash = sha256Revision(canonicalJson(payload))
    const existing = actions.get(params.actionId)
    if (existing !== undefined) {
      if (existing.payloadHash !== payloadHash) {
        return Promise.reject(protocolError('action-conflict', 'actionId was already used for another action'))
      }
      return existing.promise.then(outcome => {
        if (outcome.ok) return outcome.value
        throw outcome.error
      })
    }
    if (actions.size >= MAX_ACTION_RECORDS) {
      // Action ids remain reserved for the lifetime of this process. Evicting
      // a settled id would allow a replay after the bridge forgot its receipt.
      return Promise.reject(protocolError('action-unavailable', 'too many Supervisor actions are recorded'))
    }
    const promise = queueForSession(queues, params.sessionId, async () => {
      assertActive()
      const target = resolveTarget(services(), params.sessionId)
      // Read and compare under the same per-session queue. `_state` is the
      // provider's semantic state source; its lifecycle append does not enter
      // this projection revision.
      const rawBefore = await executeCommand(target, '/supervise _state', { activeControllers, activeCommands })
      const before = normalizeSupervisorProjection(params.sessionId, rawBefore, target.agent)
      if (before.revision !== params.expectedRevision) {
        throw protocolError('stale-revision', 'Supervisor state changed before this action')
      }
      assertActionAllowed(operation, before, target.agent)
      // The exact agent object must still be the current root after the
      // potentially slow `_state` call. Never mutate through a stale agent
      // reference after HMR or session replacement.
      assertActive()
      const currentTarget = resolveTarget(services(), params.sessionId)
      if (currentTarget.agent !== target.agent) {
        throw protocolError('session-unavailable', 'session identity changed before this action')
      }
      const rawAfter = await executeCommand(currentTarget, actionLine(operation, params.patch), { activeControllers, activeCommands })
      return normalizeSupervisorProjection(params.sessionId, rawAfter, currentTarget.agent)
    }).then(
      value => ({ ok: true, value }),
      error => ({ ok: false, error: error instanceof BridgeProtocolError ? error : protocolError('action-unknown', 'Supervisor command result is unknown') }),
    )
    actions.set(params.actionId, { payloadHash, promise })
    return promise.then(outcome => {
      if (outcome.ok) return outcome.value
      throw outcome.error
    })
  }

  const dispose = async () => {
    if (disposed) return
    disposed = true
    for (const controller of activeControllers) controller.abort(new Error('Supervisor bridge unloaded'))
    await Promise.allSettled([...activeCommands])
  }

  return Object.freeze({ descriptor, read, mutate, dispose })
}

export { canonicalJson }
