import { createHash, randomUUID as systemRandomUUID } from 'node:crypto'

export const GROUPX_REVIEW_SCHEMA_VERSION = 'harvis.groupx-review-job.v1'
export const GROUPX_REVIEW_MAX_MODEL_CALLS = 16
export const GROUPX_REVIEW_MAX_PARTICIPANTS = 8
export const GROUPX_REVIEW_MAX_ACTIVE_JOBS = 2
export const GROUPX_REVIEW_MAX_COMPLETED_JOBS = 20
export const GROUPX_REVIEW_TIMEOUT_MS = 60_000
export const GROUPX_REVIEW_METADATA_TIMEOUT_MS = 2_000
export const GROUPX_REVIEW_DESCRIBE_TIMEOUT_MS = 1_500
export const GROUPX_REVIEW_MAX_TOKENS = 1_200
export const GROUPX_REVIEW_MAX_TASK_CHARS = 16_000
export const GROUPX_REVIEW_MAX_SUMMARY_CHARS = 12_000

const REVISION_PATTERN = /^sha256:[0-9a-f]{64}$/u
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/iu
const MODEL_PART_PATTERN = /^[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?$/u
const MODEL_PART_MAX_CHARS = 160
const DISPLAY_NAME_MAX_CHARS = 128
const CONTROL_CHARACTERS = /[\u0000-\u001f\u007f]/u
const UNSAFE_TEXT_CONTROLS = /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/u

/** A stable, non-sensitive error that callers can use as a capability reason. */
export class GroupxReviewError extends Error {
  constructor(code, message = code) {
    super(message)
    this.name = 'GroupxReviewError'
    this.code = code
  }
}

function isRecord(value) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) return false
  const prototype = Object.getPrototypeOf(value)
  return prototype === Object.prototype || prototype === null
}

function isObjectLike(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
}

function hasOnlyKeys(value, keys) {
  if (!isRecord(value)) return false
  const allowed = new Set(keys)
  return Object.keys(value).every(key => allowed.has(key))
}

function bounded(value, maximum) {
  if (typeof value !== 'string') return ''
  const points = Array.from(value)
  return points.length <= maximum ? value : points.slice(0, maximum).join('')
}

function timeoutValue(value, fallback, maximum) {
  if (!Number.isSafeInteger(value) || value <= 0) return fallback
  return Math.min(value, maximum)
}

async function withTimeout(operation, timeoutMs, errorCode) {
  let timer
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(() => reject(new GroupxReviewError(errorCode)), timeoutMs)
  })
  try {
    return await Promise.race([Promise.resolve().then(operation), timeout])
  } finally {
    if (timer !== undefined) clearTimeout(timer)
  }
}

function validModelPart(value) {
  return typeof value === 'string'
    && value.length > 0
    && value.length <= MODEL_PART_MAX_CHARS
    && MODEL_PART_PATTERN.test(value)
}

function validDisplayName(value) {
  return typeof value === 'string'
    && value.trim() !== ''
    && Array.from(value).length <= DISPLAY_NAME_MAX_CHARS
    && !/[\u0000-\u001f\u007f]/u.test(value)
}

function normalizeReviewModels(value) {
  if (!Array.isArray(value) || value.length === 0 || value.length > 8) {
    throw new GroupxReviewError('models-invalid')
  }
  const seen = new Set()
  const normalized = []
  for (const entry of value) {
    if (!isRecord(entry)) throw new GroupxReviewError('models-invalid')
    if (!hasOnlyKeys(entry, ['provider', 'model', 'displayName'])) {
      throw new GroupxReviewError('models-invalid')
    }
    if (!validModelPart(entry.provider) || !validModelPart(entry.model)) {
      throw new GroupxReviewError('models-invalid')
    }
    if (entry.displayName !== undefined && !validDisplayName(entry.displayName)) {
      throw new GroupxReviewError('models-invalid')
    }
    const key = `${entry.provider}/${entry.model}`
    if (seen.has(key)) throw new GroupxReviewError('models-invalid')
    seen.add(key)
    normalized.push(Object.freeze({
      provider: entry.provider,
      model: entry.model,
      ...(entry.displayName === undefined ? {} : { displayName: entry.displayName }),
    }))
  }
  return Object.freeze(normalized)
}

function getService(ctx, name) {
  try {
    if (typeof ctx?.get !== 'function') return undefined
    return ctx.get(name)
  } catch {
    // Availability is reported through describe(); service lookup is fail-closed.
  }
  return undefined
}

function serviceSnapshot(ctx) {
  const llm = getService(ctx, 'llm')
  const roleRegistry = getService(ctx, 'groupxRoleRegistry')
  const artifactStore = getService(ctx, 'groupxArtifactStore')
  if (!isObjectLike(llm)
    || typeof llm.listProviders !== 'function'
    || typeof llm.listModels !== 'function'
    || typeof llm.stream !== 'function') {
    throw new GroupxReviewError('llm-unavailable')
  }
  if (!isObjectLike(roleRegistry)
    || typeof roleRegistry.snapshot !== 'function'
    || typeof roleRegistry.resolve !== 'function') {
    throw new GroupxReviewError('role-registry-unavailable')
  }
  if (!isObjectLike(artifactStore)
    || typeof artifactStore.createSink !== 'function'
    || typeof artifactStore.loadManualRoleBindings !== 'function') {
    throw new GroupxReviewError('artifact-store-unavailable')
  }
  return Object.freeze({ llm, roleRegistry, artifactStore })
}

function normalizeRevision(value) {
  if (typeof value !== 'string' || !REVISION_PATTERN.test(value)) {
    throw new GroupxReviewError('invalid-proposal-revision')
  }
  return value
}

function isWellFormedString(value) {
  if (typeof value.isWellFormed === 'function') return value.isWellFormed()
  for (let index = 0; index < value.length; index += 1) {
    const code = value.charCodeAt(index)
    if (code >= 0xd800 && code <= 0xdbff) {
      const next = value.charCodeAt(index + 1)
      if (!(next >= 0xdc00 && next <= 0xdfff)) return false
      index += 1
    } else if (code >= 0xdc00 && code <= 0xdfff) {
      return false
    }
  }
  return true
}

function normalizeTask(value) {
  if (typeof value !== 'string'
    || value.trim().length === 0
    || Array.from(value).length > GROUPX_REVIEW_MAX_TASK_CHARS
    || UNSAFE_TEXT_CONTROLS.test(value)
    || !isWellFormedString(value)) {
    throw new GroupxReviewError('invalid-task')
  }
  return value
}

function normalizeJobID(value) {
  if (typeof value !== 'string' || !UUID_PATTERN.test(value)) {
    throw new GroupxReviewError('invalid-job-id')
  }
  return value
}

function taskRevision(task) {
  return `sha256:${createHash('sha256').update(task, 'utf8').digest('hex')}`
}

function parseStart(value) {
  if (!hasOnlyKeys(value, ['jobId', 'proposalRevision', 'task'])) {
    throw new GroupxReviewError('invalid-request')
  }
  const jobId = normalizeJobID(value.jobId)
  const proposalRevision = normalizeRevision(value.proposalRevision)
  const task = normalizeTask(value.task)
  if (taskRevision(task) !== proposalRevision) {
    throw new GroupxReviewError('proposal-digest-mismatch')
  }
  return Object.freeze({ jobId, proposalRevision, task })
}

function parseJobRef(value) {
  if (!hasOnlyKeys(value, ['jobId', 'proposalRevision'])) {
    throw new GroupxReviewError('invalid-request')
  }
  return Object.freeze({
    jobId: normalizeJobID(value.jobId),
    proposalRevision: normalizeRevision(value.proposalRevision),
  })
}

function isoNow(now) {
  let value
  try { value = now?.() } catch { value = undefined }
  if (value instanceof Date && !Number.isNaN(value.getTime())) return value.toISOString()
  if (typeof value === 'string' && !Number.isNaN(Date.parse(value))) return new Date(value).toISOString()
  return new Date().toISOString()
}

function projectJob(job) {
  return {
    schemaVersion: GROUPX_REVIEW_SCHEMA_VERSION,
    jobId: job.jobId,
    proposalRevision: job.proposalRevision,
    state: job.state,
    ...(job.startedAt === undefined ? {} : { startedAt: job.startedAt }),
    updatedAt: job.updatedAt,
    ...(job.summary === undefined ? {} : { summary: bounded(job.summary, GROUPX_REVIEW_MAX_SUMMARY_CHARS) }),
    participantCount: Number.isSafeInteger(job.participantCount) && job.participantCount >= 0
      ? job.participantCount
      : 0,
    modelCalls: Number.isSafeInteger(job.modelCalls) && job.modelCalls >= 0 ? job.modelCalls : 0,
    maxModelCalls: GROUPX_REVIEW_MAX_MODEL_CALLS,
    ...(job.errorCode === undefined ? {} : { errorCode: job.errorCode }),
  }
}

function unknownJob(jobId, proposalRevision) {
  return {
    schemaVersion: GROUPX_REVIEW_SCHEMA_VERSION,
    jobId,
    proposalRevision,
    state: 'unknown',
    participantCount: 0,
    modelCalls: 0,
    maxModelCalls: GROUPX_REVIEW_MAX_MODEL_CALLS,
    errorCode: 'unknown-job',
  }
}

function activeJob(job) {
  return job.state === 'queued' || job.state === 'running'
}

function safeResultParticipants(result) {
  return Array.isArray(result?.participants)
    ? Math.min(result.participants.length, GROUPX_REVIEW_MAX_PARTICIPANTS)
    : 0
}

function safeResultSummary(result) {
  if (typeof result?.summary !== 'string') return ''
  if (UNSAFE_TEXT_CONTROLS.test(result.summary) || !isWellFormedString(result.summary)) return ''
  return bounded(result.summary, GROUPX_REVIEW_MAX_SUMMARY_CHARS)
}

function modeLoaderFrom(dependencies) {
  if (typeof dependencies?.runRoundtable === 'function') {
    return async () => ({ runRoundtable: dependencies.runRoundtable })
  }
  if (isRecord(dependencies?.mode) && typeof dependencies.mode.runRoundtable === 'function') {
    return async () => dependencies.mode
  }
  if (typeof dependencies?.loadMode === 'function') return dependencies.loadMode
  if (typeof dependencies?.importMode === 'function') return dependencies.importMode
  return async () => import('@harness-flow/dsh-groupx/mode')
}

async function loadPublicMode(dependencies) {
  const loaded = await modeLoaderFrom(dependencies)()
  const mode = isRecord(loaded?.default) ? loaded.default : loaded
  if (!isRecord(mode) || typeof mode.runRoundtable !== 'function') {
    throw new GroupxReviewError('module-unavailable')
  }
  return mode
}

async function verifyModelRefs(llm, models) {
  let providers
  try {
    providers = llm.listProviders()
  } catch {
    throw new GroupxReviewError('model-unavailable')
  }
  if (!Array.isArray(providers)) throw new GroupxReviewError('model-unavailable')
  const providerByID = new Map()
  for (const provider of providers) {
    if (!isRecord(provider) || typeof provider.id !== 'string') continue
    providerByID.set(provider.id, provider)
  }
  const providerIDs = [...new Set(models.map(model => model.provider))]
  const listed = new Map()
  for (const providerID of providerIDs) {
    if (!providerByID.has(providerID)) throw new GroupxReviewError('model-unavailable')
    let entries
    try {
      entries = await llm.listModels(providerID)
    } catch {
      throw new GroupxReviewError('model-unavailable')
    }
    if (!Array.isArray(entries)) throw new GroupxReviewError('model-unavailable')
    listed.set(providerID, entries)
  }
  for (const model of models) {
    const entry = listed.get(model.provider)?.find(candidate => (
      isRecord(candidate)
      && candidate.id === model.model
      && (candidate.provider === undefined || candidate.provider === model.provider)
    ))
    if (entry === undefined) throw new GroupxReviewError('model-unavailable')
  }
  return Object.freeze({ providers: Object.freeze(providerIDs.map(id => providerByID.get(id))), listed })
}

function mergeSignals(first, second) {
  if (first === undefined) return { signal: second, dispose() {} }
  if (second === undefined || first === second) return { signal: first, dispose() {} }
  const controller = new AbortController()
  const abort = reason => {
    if (!controller.signal.aborted) controller.abort(reason)
  }
  const firstAbort = () => abort(first.reason)
  const secondAbort = () => abort(second.reason)
  if (first.aborted) abort(first.reason)
  if (second.aborted) abort(second.reason)
  first.addEventListener?.('abort', firstAbort, { once: true })
  second.addEventListener?.('abort', secondAbort, { once: true })
  return {
    signal: controller.signal,
    dispose() {
      first.removeEventListener?.('abort', firstAbort)
      second.removeEventListener?.('abort', secondAbort)
    },
  }
}

function createReviewLlm(llm, models, verified, ownerSignal, stats, onCall) {
  const configuredByKey = new Map(models.map(model => [`${model.provider}/${model.model}`, model]))
  const providers = verified.providers.map(provider => ({
    id: provider.id,
    name: typeof provider.name === 'string' ? provider.name : provider.id,
  }))
  return Object.freeze({
    listProviders() {
      return providers.map(provider => ({ ...provider }))
    },
    async listModels(provider) {
      const selected = models.filter(model => model.provider === provider)
      const advertised = verified.listed.get(provider) ?? []
      return selected.map(model => {
        const found = advertised.find(entry => isRecord(entry) && entry.id === model.model)
        return {
          provider,
          id: model.model,
          name: model.displayName ?? (typeof found?.name === 'string' ? found.name : model.model),
        }
      })
    },
    stream(options) {
      if (!isRecord(options)) {
        stats.invalidCall = true
        throw new GroupxReviewError('model-call-invalid')
      }
      if (ownerSignal?.aborted || options.signal?.aborted) {
        throw new GroupxReviewError('cancelled')
      }
      const key = `${options.provider}/${options.model}`
      if (!configuredByKey.has(key)) {
        stats.modelNotAllowed = true
        throw new GroupxReviewError('model-not-allowed')
      }
      if (stats.calls >= GROUPX_REVIEW_MAX_MODEL_CALLS) {
        stats.budgetExceeded = true
        throw new GroupxReviewError('model-call-budget-exceeded')
      }
      stats.calls += 1
      onCall?.(stats.calls)
      const merged = mergeSignals(options.signal, ownerSignal)
      const forwarded = {
        provider: options.provider,
        model: options.model,
        messages: options.messages,
        system: options.system,
        maxTokens: GROUPX_REVIEW_MAX_TOKENS,
        signal: merged.signal,
      }
      let source
      try {
        source = llm.stream(forwarded)
      } catch (error) {
        merged.dispose()
        throw error
      }
      return (async function* forward() {
        try {
          for await (const chunk of source) yield chunk
        } finally {
          merged.dispose()
        }
      })()
    },
  })
}

function resultState(result, summary, stats) {
  if (stats?.budgetExceeded) return { state: 'failed', errorCode: 'model-call-budget-exceeded' }
  if (stats?.modelNotAllowed) return { state: 'failed', errorCode: 'model-not-allowed' }
  if (stats?.invalidCall) return { state: 'failed', errorCode: 'model-call-invalid' }
  if (result?.state === 'completed' && summary.trim() !== '') return { state: 'succeeded' }
  if (result?.state === 'cancelled' || result?.state === 'superseded') {
    return { state: 'cancelled', errorCode: 'cancelled' }
  }
  if (result?.state === 'unresolved' || result?.state === 'awaiting_publication') {
    return { state: 'blocked', errorCode: 'unresolved' }
  }
  if (result?.state === 'timed_out') return { state: 'failed', errorCode: 'timeout' }
  if (result?.state === 'failed') return { state: 'failed', errorCode: 'run-failed' }
  if (result?.state === 'completed') return { state: 'blocked', errorCode: 'empty-summary' }
  return { state: 'failed', errorCode: 'run-failed' }
}

function occupiesSlot(job) {
  return activeJob(job) || job.unsettled === true
}

function failureCode(error, stats, timedOut) {
  if (timedOut) return 'timeout'
  if (stats.budgetExceeded || error?.code === 'model-call-budget-exceeded') {
    return 'model-call-budget-exceeded'
  }
  if (error?.code === 'model-not-allowed') return 'model-not-allowed'
  if (stats.invalidCall || error?.code === 'model-call-invalid') return 'model-call-invalid'
  return 'run-failed'
}

/**
 * Host-only advisory GroupX job service. It talks to GroupX solely through its
 * public `mode` entry point and keeps all job state in this process.
 */
export function createGroupxReviewService(ctx, reviewModels, dependencies = {}) {
  let models
  let modelError
  try {
    models = normalizeReviewModels(reviewModels)
  } catch (error) {
    modelError = error instanceof GroupxReviewError ? error : new GroupxReviewError('models-invalid')
  }

  const jobs = new Map()
  const now = typeof dependencies?.now === 'function' ? dependencies.now : () => new Date()
  const makeUUID = typeof dependencies?.randomUUID === 'function' ? dependencies.randomUUID : systemRandomUUID
  const modePromise = { value: undefined, pending: undefined, error: undefined }
  const timeoutMs = timeoutValue(
    dependencies?.timeoutMs,
    GROUPX_REVIEW_TIMEOUT_MS,
    GROUPX_REVIEW_TIMEOUT_MS,
  )
  const metadataTimeoutMs = timeoutValue(
    dependencies?.metadataTimeoutMs,
    GROUPX_REVIEW_METADATA_TIMEOUT_MS,
    GROUPX_REVIEW_METADATA_TIMEOUT_MS,
  )
  const describeTimeoutMs = timeoutValue(
    dependencies?.describeTimeoutMs,
    GROUPX_REVIEW_DESCRIBE_TIMEOUT_MS,
    GROUPX_REVIEW_DESCRIBE_TIMEOUT_MS,
  )
  let disposed = false

  async function loadMode() {
    if (modePromise.value !== undefined) return modePromise.value
    if (modePromise.error !== undefined) throw modePromise.error
    modePromise.pending ??= loadPublicMode(dependencies)
      .then(mode => { modePromise.value = mode; return mode })
      .catch(error => {
        modePromise.error = error instanceof GroupxReviewError
          ? error
          : new GroupxReviewError('module-unavailable')
        throw modePromise.error
      })
    return modePromise.pending
  }

  async function ready() {
    if (disposed) throw new GroupxReviewError('service-disposed')
    if (modelError !== undefined) throw modelError
    let services
    try {
      services = serviceSnapshot(ctx)
    } catch (error) {
      throw error instanceof GroupxReviewError
        ? error
        : new GroupxReviewError('services-unavailable')
    }
    const mode = await loadMode()
    const verified = await verifyModelRefs(services.llm, models)
    return Object.freeze({ services, mode, verified })
  }

  async function readyWithin(limit) {
    return withTimeout(() => ready(), limit, 'metadata-timeout')
  }

  function trimCompletedJobs() {
    const completed = [...jobs.values()]
      .filter(job => !occupiesSlot(job))
      .sort((left, right) => left.completedOrder - right.completedOrder)
    while (completed.length > GROUPX_REVIEW_MAX_COMPLETED_JOBS) {
      const oldest = completed.shift()
      if (oldest !== undefined && jobs.get(oldest.jobId) === oldest) jobs.delete(oldest.jobId)
    }
  }

  function makeJob(input) {
    return {
      jobId: input.jobId,
      proposalRevision: input.proposalRevision,
      state: 'queued',
      startedAt: undefined,
      updatedAt: isoNow(now),
      summary: undefined,
      participantCount: 0,
      modelCalls: 0,
      errorCode: undefined,
      controller: new AbortController(),
      cancelRequested: false,
      timedOut: false,
      unsettled: true,
      completedOrder: 0,
      promise: undefined,
    }
  }

  function terminal(job, patch) {
    Object.assign(job, patch, { updatedAt: isoNow(now) })
    if (!occupiesSlot(job)) {
      job.completedOrder = Date.now()
      trimCompletedJobs()
    }
  }

  async function execute(job, prepared, task) {
    let runSettled = true
    const stats = { calls: 0, budgetExceeded: false }
    let timer
    let timedOut = false
    try {
      if (job.cancelRequested || disposed) return
      job.state = 'running'
      job.startedAt = isoNow(now)
      job.updatedAt = job.startedAt
      const reviewLlm = createReviewLlm(
        prepared.services.llm,
        models,
        prepared.verified,
        job.controller.signal,
        stats,
        calls => {
          job.modelCalls = calls
          job.updatedAt = isoNow(now)
        },
      )
      const sessionId = `harvis-review-${makeUUID()}`
      const run = prepared.mode.runRoundtable({
        sessionId,
        task,
        config: {
          dshModels: models,
          timeoutMs: GROUPX_REVIEW_TIMEOUT_MS,
          dshMaxTokens: GROUPX_REVIEW_MAX_TOKENS,
          maxParticipants: models.length,
        },
        roleRegistry: prepared.services.roleRegistry,
        llm: reviewLlm,
        artifactStore: prepared.services.artifactStore,
        signal: job.controller.signal,
      })
      runSettled = false
      const observedRun = Promise.resolve(run).then(
        value => {
          runSettled = true
          job.unsettled = false
          if (!occupiesSlot(job)) {
            job.completedOrder = Date.now()
            trimCompletedJobs()
          }
          return value
        },
        error => {
          runSettled = true
          job.unsettled = false
          if (!occupiesSlot(job)) {
            job.completedOrder = Date.now()
            trimCompletedJobs()
          }
          throw error
        },
      )
      const timeout = new Promise((_, reject) => {
        timer = setTimeout(() => {
          timedOut = true
          job.timedOut = true
          job.controller.abort(new Error('groupx-review-timeout'))
          reject(new GroupxReviewError('timeout'))
        }, timeoutMs)
      })
      const result = await Promise.race([observedRun, timeout])
      if (job.cancelRequested || disposed) return
      const summary = safeResultSummary(result)
      const mapped = resultState(result, summary, stats)
      terminal(job, {
        state: mapped.state,
        summary: summary || undefined,
        participantCount: safeResultParticipants(result),
        modelCalls: stats.calls,
        errorCode: mapped.errorCode,
      })
    } catch (error) {
      if (job.cancelRequested || disposed) return
      terminal(job, {
        state: 'failed',
        summary: timedOut ? 'GroupX review timed out.' : 'GroupX review failed.',
        participantCount: 0,
        modelCalls: stats.calls,
        errorCode: failureCode(error, stats, timedOut),
      })
    } finally {
      if (timer !== undefined) clearTimeout(timer)
      job.modelCalls = stats.calls
      if (runSettled) job.unsettled = false
      if (!occupiesSlot(job)) {
        job.completedOrder = Date.now()
        trimCompletedJobs()
      }
    }
  }

  async function describe() {
    const descriptor = (available, reason) => ({
      id: 'groupx.review',
      version: 1,
      title: 'GroupX project review',
      scope: 'project',
      operations: ['start', 'status', 'cancel'],
      availability: available ? 'available' : 'unavailable',
      ...(available ? {} : { reason: reason ?? 'capability-unavailable' }),
      requiresApproval: false,
      supportsCancel: true,
    })
    if (disposed) return descriptor(false, 'service-disposed')
    if (modelError !== undefined) return descriptor(false, modelError.code)
    try {
      await readyWithin(describeTimeoutMs)
      return descriptor(true)
    } catch (error) {
      return descriptor(false, error instanceof GroupxReviewError ? error.code : 'service-unavailable')
    }
  }

  async function start(input) {
    const params = parseStart(input)
    const existing = jobs.get(params.jobId)
    if (existing !== undefined) {
      if (existing.proposalRevision !== params.proposalRevision) {
        throw new GroupxReviewError('job-proposal-mismatch')
      }
      return projectJob(existing)
    }
    const prepared = await readyWithin(metadataTimeoutMs)
    if (disposed) throw new GroupxReviewError('service-disposed')
    const raced = jobs.get(params.jobId)
    if (raced !== undefined) {
      if (raced.proposalRevision !== params.proposalRevision) {
        throw new GroupxReviewError('job-proposal-mismatch')
      }
      return projectJob(raced)
    }
    if ([...jobs.values()].filter(occupiesSlot).length >= GROUPX_REVIEW_MAX_ACTIVE_JOBS) {
      throw new GroupxReviewError('active-job-limit')
    }
    const job = makeJob(params)
    jobs.set(job.jobId, job)
    job.promise = execute(job, prepared, params.task).catch(() => undefined)
    return projectJob(job)
  }

  async function status(input) {
    const params = parseJobRef(input)
    const job = jobs.get(params.jobId)
    if (job === undefined) return unknownJob(params.jobId, params.proposalRevision)
    if (job.proposalRevision !== params.proposalRevision) {
      throw new GroupxReviewError('job-proposal-mismatch')
    }
    return projectJob(job)
  }

  async function cancel(input) {
    const params = parseJobRef(input)
    const job = jobs.get(params.jobId)
    if (job === undefined) return unknownJob(params.jobId, params.proposalRevision)
    if (job.proposalRevision !== params.proposalRevision) {
      throw new GroupxReviewError('job-proposal-mismatch')
    }
    if (activeJob(job)) {
      job.cancelRequested = true
      job.controller.abort(new Error('groupx-review-cancelled'))
      terminal(job, {
        state: 'cancelled',
        summary: 'GroupX review cancelled.',
        errorCode: 'cancelled',
      })
    }
    return projectJob(job)
  }

  function dispose() {
    if (disposed) return
    disposed = true
    for (const job of jobs.values()) {
      if (!activeJob(job)) continue
      job.cancelRequested = true
      job.controller.abort(new Error('groupx-review-disposed'))
      terminal(job, {
        state: 'cancelled',
        summary: 'GroupX review cancelled.',
        errorCode: 'cancelled',
      })
    }
  }

  return Object.freeze({ describe, start, status, cancel, dispose })
}
