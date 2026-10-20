import { Buffer } from 'node:buffer'
import {
  BRIDGE_PATH,
  BRIDGE_SCHEMA_VERSION,
  GROUPX_REVIEW_CAPABILITY_ID,
  GROUPX_REVIEW_SCHEMA_VERSION,
  MAX_REQUEST_BYTES,
  MAX_RESPONSE_BYTES,
  MAX_ITEMS_PER_SOURCE,
  BridgeProtocolError,
  capabilityCatalog,
  groupxReviewCapabilityDescriptor,
  decodeCursor,
  encodeCursor,
  failureResponse,
  isRecord,
  parseCapabilitiesParams,
  parseGroupxReviewJobParams,
  parseGroupxReviewStartParams,
  parseRequestEnvelope,
  parseSupervisorMutationParams,
  parseSupervisorStateParams,
  parseUserInputsParams,
  resolveAuthority,
  revisionInput,
  sha256Revision,
  successResponse,
  isSourceRevision,
  validBoundedString,
  validBoundedText,
} from './contracts.js'
import { collectUserInputs, isInternalSession, validatePolicy } from './inputs.js'
import { createSupervisorController } from './supervisor.js'

/** Host-only Cordis plugin name. */
export const name = 'dsh-harvis-bridge'

/** The carrier is required; data services are discovered fail-closed at runtime. */
export const inject = ['webServer']

const GROUPX_DESCRIBE_TIMEOUT_MS = 1_500

function getService(ctx, name) {
  try {
    if (typeof ctx?.get === 'function') {
      const value = ctx.get(name)
      if (value !== undefined) return value
    }
  } catch {
    // An optional Service is intentionally reported as unavailable below.
  }
  return ctx?.[name]
}

function serviceSet(ctx) {
  const persistence = getService(ctx, 'sessionPersistence')
  const sessions = getService(ctx, 'sessions')
  const available = isRecord(persistence)
    && typeof persistence.inspect === 'function'
    && typeof persistence.listSnapshots === 'function'
  return { persistence, sessions, available }
}

function configParts(config) {
  const input = isRecord(config) ? config : {}
  const authorityConfig = isRecord(input.authority) ? input.authority : input
  const policyConfig = isRecord(input.policy) ? input.policy : input
  return {
    authority: resolveAuthority(authorityConfig),
    policy: validatePolicy(policyConfig),
    reviewModels: input.reviewModels,
  }
}

function optionalGroupxFactory(ctx) {
  return import('./groupx-review.mjs')
    .then(module => {
      if (typeof module.createGroupxReviewService === 'function') return module.createGroupxReviewService
      if (typeof module.default?.createGroupxReviewService === 'function') {
        return module.default.createGroupxReviewService
      }
      return typeof module.default === 'function' ? module.default : undefined
    })
    .catch(() => undefined)
}

async function makeGroupxService(ctx, reviewModels) {
  const factory = await optionalGroupxFactory(ctx)
  if (factory === undefined) return undefined
  try {
    return await factory(ctx, reviewModels, {
      get: name => getService(ctx, name),
      getService: name => getService(ctx, name),
    })
  } catch (error) {
    // Do not log provider/model errors or task text across the bridge boundary.
    try { ctx.logger?.warn?.(new Error('dsh-harvis-bridge: GroupX service unavailable')) } catch { /* best effort */ }
    return undefined
  }
}

function normalizeGroupxDescriptor(value) {
  if (!isRecord(value)) return undefined
  // The isolated service deliberately keeps capability metadata Host-local
  // and reports `{ available, reason }`; accept a fully formed descriptor too
  // so the bridge remains forwards-compatible with a richer provider.
  if (value.id === undefined) {
    return groupxReviewCapabilityDescriptor({
      available: value.available === true,
      reason: typeof value.reason === 'string' ? value.reason : 'capability-unavailable',
    })
  }
  if (value.id !== GROUPX_REVIEW_CAPABILITY_ID) return undefined
  return {
    id: GROUPX_REVIEW_CAPABILITY_ID,
    version: 1,
    title: typeof value.title === 'string' && value.title.length > 0
      ? value.title : 'GroupX project review',
    scope: 'project',
    operations: ['start', 'status', 'cancel'],
    availability: value.availability === 'unavailable' ? 'unavailable' : 'available',
    ...(value.availability === 'unavailable'
      ? { reason: typeof value.reason === 'string' ? value.reason : 'capability-unavailable' }
      : {}),
    requiresApproval: false,
    supportsCancel: true,
  }
}

function validGroupxJobProjection(value) {
  const states = new Set(['queued', 'running', 'succeeded', 'failed', 'cancelled', 'unknown', 'blocked'])
  return isRecord(value)
    && value.schemaVersion === GROUPX_REVIEW_SCHEMA_VERSION
    && validBoundedString(value.jobId, 64)
    && isSourceRevision(value.proposalRevision)
    && states.has(value.state)
    && Number.isSafeInteger(value.participantCount)
    && value.participantCount >= 0 && value.participantCount <= 8
    && Number.isSafeInteger(value.modelCalls)
    && value.modelCalls >= 0 && value.modelCalls <= 16
    && value.maxModelCalls === 16
    && (value.summary === undefined || validBoundedText(value.summary, 12_000, { allowEmpty: true }))
    && (value.errorCode === undefined || validBoundedString(value.errorCode, 128))
}

export async function describeGroupx(service, timeoutMs = GROUPX_DESCRIBE_TIMEOUT_MS) {
  if (service === undefined || typeof service.describe !== 'function') return undefined
  let timer
  try {
    const timeout = new Promise(resolve => {
      // Keep the awaited deadline alive even when the optional service has no handles.
      timer = setTimeout(() => resolve(undefined), timeoutMs)
    })
    const described = await Promise.race([Promise.resolve().then(() => service.describe()), timeout])
    if (described === undefined) {
      return groupxReviewCapabilityDescriptor({ available: false, reason: 'capability-timeout' })
    }
    return normalizeGroupxDescriptor(described)
  } catch {
    return groupxReviewCapabilityDescriptor({ available: false, reason: 'capability-unavailable' })
  } finally {
    if (timer !== undefined) clearTimeout(timer)
  }
}

function isLoopback(req) {
  const address = req?.socket?.remoteAddress
  if (address === '127.0.0.1' || address === '::1' || address === '::ffff:127.0.0.1') return true
  // Node may render an IPv4-mapped loopback address as hexadecimal.
  return address === '::ffff:7f00:1'
}

function trustedLoopbackHost(value) {
  if (typeof value !== 'string' || value.length === 0 || value.length > 128) return undefined
  const match = /^(127\.0\.0\.1|\[::1\])(?::([0-9]{1,5}))?$/u.exec(value)
  if (match === null) return undefined
  const port = match[2] === undefined ? undefined : Number(match[2])
  if (port !== undefined && (port < 1 || port > 65_535)) return undefined
  return { host: match[1], port }
}

/** Reject DNS rebinding and cross-origin browser reads of the paid bridge. */
function sameTrustedOrigin(req) {
  const host = trustedLoopbackHost(req?.headers?.host)
  if (host === undefined) return false
  const origin = req?.headers?.origin
  if (origin === undefined) return true
  if (typeof origin !== 'string' || origin === 'null' || origin.length > 256) return false
  let parsed
  try { parsed = new URL(origin) } catch { return false }
  if (parsed.protocol !== 'http:' || parsed.username !== '' || parsed.password !== ''
    || parsed.pathname !== '/' || parsed.search !== '' || parsed.hash !== '') return false
  const originHost = parsed.hostname === '127.0.0.1' ? '127.0.0.1'
    : parsed.hostname === '[::1]' || parsed.hostname === '::1' ? '[::1]' : undefined
  if (originHost === undefined || originHost !== host.host) return false
  const originPort = parsed.port === '' ? undefined : Number(parsed.port)
  if (originPort !== undefined && (originPort < 1 || originPort > 65_535)) return false
  return originPort === host.port || (originPort === undefined && host.port === undefined)
}

function writeJson(res, status, value) {
  const body = Buffer.from(JSON.stringify(value), 'utf8')
  if (body.byteLength > MAX_RESPONSE_BYTES) {
    res.writeHead(500, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' })
    res.end(JSON.stringify({ error: 'response-too-large' }))
    return
  }
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'cache-control': 'no-store',
    'content-length': String(body.byteLength),
  })
  res.end(body)
}

function writePlain(res, status, body = '') {
  const bytes = Buffer.byteLength(body, 'utf8')
  res.writeHead(status, {
    'content-type': 'text/plain; charset=utf-8',
    'cache-control': 'no-store',
    'content-length': String(bytes),
  })
  res.end(body)
}

function requestContentType(req) {
  const value = req?.headers?.['content-type']
  return typeof value === 'string' ? value.split(';', 1)[0].trim().toLowerCase() : undefined
}

async function readBody(req) {
  const declared = req?.headers?.['content-length']
  if (declared !== undefined) {
    const length = Number(declared)
    if (!Number.isSafeInteger(length) || length < 0 || length > MAX_REQUEST_BYTES) {
      throw new BridgeProtocolError('invalid-request', 'request body is too large')
    }
  }
  return await new Promise((resolve, reject) => {
    const chunks = []
    let size = 0
    let settled = false
    const finish = (callback, value) => {
      if (settled) return
      settled = true
      callback(value)
    }
    req.on('data', chunk => {
      if (settled) return
      const bytes = Buffer.isBuffer(chunk) ? chunk : Buffer.from(String(chunk))
      size += bytes.byteLength
      if (size > MAX_REQUEST_BYTES) {
        finish(reject, new BridgeProtocolError('invalid-request', 'request body is too large'))
        if (typeof req.resume === 'function') req.resume()
        return
      }
      chunks.push(bytes)
    })
    req.once('end', () => {
      if (settled) return
      const body = Buffer.concat(chunks).toString('utf8')
      if (body.length === 0) {
        finish(reject, new BridgeProtocolError('invalid-request', 'request body is empty'))
        return
      }
      try {
        finish(resolve, JSON.parse(body))
      } catch {
        finish(reject, new BridgeProtocolError('invalid-request', 'request body is not JSON'))
      }
    })
    req.once('aborted', () => finish(reject, new BridgeProtocolError('invalid-request', 'request was aborted')))
    req.once('error', () => finish(reject, new BridgeProtocolError('invalid-request', 'request could not be read')))
  })
}

function snapshotFor(snapshots, sessionId) {
  if (!Array.isArray(snapshots)) return undefined
  return snapshots.find(snapshot => snapshot?.header?.id === sessionId)
}

function revisionForInspection(sessionId, inspection, snapshot, live) {
  if (snapshot !== undefined && !live) {
    // Cold reads bind directly to the backend's opaque revision, namespaced by
    // session id. Harvis treats the resulting digest as equality-only.
    return sha256Revision(JSON.stringify({
      sessionId,
      revision: revisionInput(snapshot.revision),
    }))
  }
  // A live Session can be ahead of a backend checkpoint. Hash the immutable
  // inspection as a source-local fallback so cursors detect an unflushed tail.
  return sha256Revision(JSON.stringify({ sessionId, events: inspection.events }))
}

function sameOpaqueRevision(left, right) {
  return left !== undefined && right !== undefined
    && revisionInput(left) === revisionInput(right)
}

function sourceError(code, message) {
  return new BridgeProtocolError(code, message, 200)
}

function safeErrorCode(error) {
  const code = error !== null && typeof error === 'object' && !Array.isArray(error)
    ? error.code
    : undefined
  return validBoundedString(code, 128) ? code : 'source-unavailable'
}

function isMissingSessionError(error) {
  return error instanceof Error && /not found|does not exist|unknown session/i.test(error.message)
}

async function inspectSource(services, sessionId) {
  if (!services.available) throw sourceError('source-unavailable', 'session source is unavailable')
  let beforeSnapshots
  try {
    beforeSnapshots = await services.persistence.listSnapshots()
  } catch {
    throw sourceError('source-unavailable', 'session source is unavailable')
  }
  const before = snapshotFor(beforeSnapshots, sessionId)
  let inspection
  try {
    inspection = await services.persistence.inspect(sessionId)
  } catch (error) {
    if (isMissingSessionError(error)) throw sourceError('session-not-found', 'session was not found')
    throw sourceError('source-unavailable', 'session source is unavailable')
  }
  let afterSnapshots
  try {
    afterSnapshots = await services.persistence.listSnapshots()
  } catch {
    throw sourceError('source-unavailable', 'session source is unavailable')
  }
  const after = snapshotFor(afterSnapshots, sessionId)
  if (before?.revision !== undefined && after?.revision !== undefined
    && !sameOpaqueRevision(before.revision, after.revision)) {
    throw sourceError('source-changed', 'session source changed during inspection')
  }
  const snapshot = after ?? before
  const meta = inspection?.meta ?? snapshot?.header
  if (!isRecord(meta) || meta.id !== sessionId || !Array.isArray(inspection?.events)) {
    throw sourceError('source-unavailable', 'session source is invalid')
  }
  let live = false
  try {
    live = services.sessions?.get?.(sessionId) !== undefined
  } catch {
    live = false
  }
  return {
    inspection,
    meta,
    revision: revisionForInspection(sessionId, inspection, snapshot, live),
  }
}

function pageWithinResponseSize(page) {
  return Buffer.byteLength(JSON.stringify(page), 'utf8') <= MAX_RESPONSE_BYTES
}

async function readUserInputs(services, policy, params) {
  const source = await inspectSource(services, params.sessionId)
  if (isInternalSession(source.meta, policy)) {
    throw sourceError('internal-session', 'internal session is not exposed')
  }

  let offset = 0
  if (params.cursor !== undefined) {
    const cursor = decodeCursor(params.cursor)
    if (cursor.sessionId !== params.sessionId) {
      throw sourceError('stale-cursor', 'cursor belongs to another session')
    }
    if (cursor.sourceRevision !== source.revision) {
      throw sourceError('stale-cursor', 'cursor does not match the current source')
    }
    offset = cursor.offset
  }

  const projection = collectUserInputs(params.sessionId, source.inspection)
  if (offset > projection.totalItems) {
    throw sourceError('stale-cursor', 'cursor is past the source')
  }

  const pageItems = []
  let nextOffset = offset
  while (pageItems.length < params.limit && nextOffset < projection.totalItems) {
    const item = projection.items[nextOffset]
    if (item === undefined) break
    const candidateItems = [...pageItems, item]
    const candidateNext = nextOffset + 1 < projection.totalItems
      && nextOffset + 1 < MAX_ITEMS_PER_SOURCE
      ? encodeCursor({ sessionId: params.sessionId, sourceRevision: source.revision, offset: nextOffset + 1 })
      : null
    const candidate = {
      schemaVersion: 'harvis.dsh-user-inputs.v1',
      sessionId: params.sessionId,
      sourceAvailable: true,
      sourceRevision: source.revision,
      items: candidateItems,
      nextCursor: candidateNext,
      excludedNonHumanItems: projection.excludedNonHumanItems,
      totalItems: projection.totalItems,
    }
    if (!pageWithinResponseSize(candidate)) {
      if (pageItems.length === 0) throw sourceError('source-unavailable', 'one input exceeds bridge bounds')
      break
    }
    pageItems.push(item)
    nextOffset += 1
  }

  const nextCursor = nextOffset < projection.totalItems && nextOffset < MAX_ITEMS_PER_SOURCE
    ? encodeCursor({ sessionId: params.sessionId, sourceRevision: source.revision, offset: nextOffset })
    : null
  const page = {
    schemaVersion: 'harvis.dsh-user-inputs.v1',
    sessionId: params.sessionId,
    sourceAvailable: true,
    sourceRevision: source.revision,
    items: pageItems,
    nextCursor,
    excludedNonHumanItems: projection.excludedNonHumanItems,
    totalItems: projection.totalItems,
  }
  if (!pageWithinResponseSize(page)) throw sourceError('source-unavailable', 'input page exceeds bridge bounds')
  return page
}

async function dispatch(ctx, authority, policy, groupxService, supervisor, request) {
  const services = serviceSet(ctx)
  if (request.method === 'capabilities.describe') {
    parseCapabilitiesParams(request.params)
    const groupxDescriptor = await describeGroupx(groupxService)
    const supervisorDescriptor = supervisor.descriptor()
    return successResponse(request.requestId, authority, capabilityCatalog(
      services.available,
      services.available ? undefined : 'source-unavailable',
      [supervisorDescriptor, ...(groupxDescriptor === undefined ? [] : [groupxDescriptor])],
    ))
  }
  if (request.method === 'session.userInputs') {
    const params = parseUserInputsParams(request.params)
    const value = await readUserInputs(services, policy, params)
    return successResponse(request.requestId, authority, value)
  }
  if (request.method === 'supervisor.session.state') {
    const params = parseSupervisorStateParams(request.params)
    const value = await supervisor.read(params)
    return successResponse(request.requestId, authority, value)
  }
  if (request.method === 'supervisor.session.set'
    || request.method === 'supervisor.session.regenerate'
    || request.method === 'supervisor.session.adopt'
    || request.method === 'supervisor.session.recover') {
    const operation = request.method.slice('supervisor.session.'.length)
    const params = parseSupervisorMutationParams(request.params, operation)
    const value = await supervisor.mutate(operation, params)
    return successResponse(request.requestId, authority, value)
  }
  if (request.method === 'groupx.review.start'
    || request.method === 'groupx.review.status'
    || request.method === 'groupx.review.cancel') {
    if (groupxService === undefined) {
      return failureResponse(request.requestId, authority, 'capability-unavailable', 'GroupX review is unavailable')
    }
    const operation = request.method.slice('groupx.review.'.length)
    const params = operation === 'start'
      ? parseGroupxReviewStartParams(request.params)
      : parseGroupxReviewJobParams(request.params, operation)
    if (typeof groupxService[operation] !== 'function') {
      return failureResponse(request.requestId, authority, 'capability-unavailable', 'GroupX review is unavailable')
    }
    try {
      const value = await groupxService[operation](params)
      // Keep the bridge schema stable even if an implementation returns a
      // business-failure union instead of throwing it.
      if (isRecord(value) && value.ok === false && isRecord(value.error)) {
        return failureResponse(
          request.requestId,
          authority,
          validBoundedString(value.error.code, 128) ? value.error.code : 'source-unavailable',
          undefined,
        )
      }
      if (!validGroupxJobProjection(value)) {
        return failureResponse(request.requestId, authority, 'source-unavailable', 'GroupX review returned an invalid projection')
      }
      return successResponse(request.requestId, authority, value)
    } catch (error) {
      const code = safeErrorCode(error)
      return failureResponse(request.requestId, authority, code, 'GroupX review request failed')
    }
  }
  return failureResponse(request.requestId, authority, 'capability-unavailable', 'capability is unavailable')
}

async function handleRequest(ctx, authority, policy, groupxService, supervisor, req, res) {
  if (!isLoopback(req) || !sameTrustedOrigin(req)) {
    writePlain(res, 403, 'loopback only')
    return
  }
  if (req.method !== 'POST') {
    writePlain(res, 405, 'POST required')
    return
  }
  if (requestContentType(req) !== 'application/json') {
    writePlain(res, 415, 'application/json required')
    return
  }
  let request
  try {
    request = parseRequestEnvelope(await readBody(req))
  } catch (error) {
    const protocol = error instanceof BridgeProtocolError
      ? error
      : new BridgeProtocolError('invalid-request', 'request is invalid')
    writeJson(res, protocol.status, { error: protocol.code })
    return
  }

  try {
    writeJson(res, 200, await dispatch(ctx, authority, policy, groupxService, supervisor, request))
  } catch (error) {
    if (error instanceof BridgeProtocolError) {
      if (error.status === 200) {
        writeJson(res, 200, failureResponse(request.requestId, authority, error.code, error.message))
      } else {
        writeJson(res, error.status, { error: error.code })
      }
      return
    }
    try { ctx.logger?.warn?.(new Error('dsh-harvis-bridge: request dispatch failed')) } catch { /* logging is best effort */ }
    writeJson(res, 200, failureResponse(request.requestId, authority, 'source-unavailable', 'bridge source is unavailable'))
  }
}

/** Mount the loopback-only Host route. */
export function apply(ctx, config = {}) {
  const { authority, policy, reviewModels } = configParts(config)
  const webServer = getService(ctx, 'webServer')
  if (!webServer || typeof webServer.register !== 'function') {
    throw new TypeError('dsh-harvis-bridge: webServer is required')
  }
  const supervisor = createSupervisorController({
    authority,
    getServices: () => ({
      agents: getService(ctx, 'agents'),
      commands: getService(ctx, 'commands'),
    }),
  })
  const groupxServicePromise = makeGroupxService(ctx, reviewModels)
  let groupxService
  groupxServicePromise.then(service => { groupxService = service }).catch(() => { /* handled by factory */ })
  const route = {
    kind: 'exact',
    path: BRIDGE_PATH,
    handler: async (req, res) => {
      // The first request waits for optional service construction; later
      // requests use the same process-local service instance.
      groupxService = groupxService ?? await groupxServicePromise
      return handleRequest(ctx, authority, policy, groupxService, supervisor, req, res)
    },
  }
  const register = () => {
    const unregister = webServer.register(route)
    return async () => {
      const drained = supervisor.dispose()
      unregister()
      await drained
      const service = await groupxServicePromise
      await service?.dispose?.()
    }
  }
  if (typeof ctx?.effect === 'function') {
    ctx.effect(register, 'dsh-harvis-bridge: route')
  } else {
    register()
  }
}

export { BRIDGE_SCHEMA_VERSION }
