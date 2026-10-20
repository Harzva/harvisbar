import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import test from 'node:test'
import { createGroupxReviewService } from '../src/groupx-review.mjs'

const models = Object.freeze([
  Object.freeze({ provider: 'provider-a', model: 'model-a', displayName: 'Model A' }),
  Object.freeze({ provider: 'provider-b', model: 'model-b', displayName: 'Model B' }),
])

const roleRegistry = {
  snapshot: () => [],
  resolve: () => undefined,
}

const artifactStore = {
  createSink: async () => ({}),
  loadManualRoleBindings: async () => [],
}

function context({ llm, roles = roleRegistry, artifacts = artifactStore } = {}) {
  const services = { llm, groupxRoleRegistry: roles, groupxArtifactStore: artifacts }
  return { get: name => services[name] }
}

function digest(task) {
  return `sha256:${createHash('sha256').update(task, 'utf8').digest('hex')}`
}

function ref(jobId, task) {
  return { jobId, proposalRevision: digest(task) }
}

function validJobID(index = 1) {
  return `00000000-0000-4000-8000-${String(index).padStart(12, '0')}`
}

function unavailableDescriptor(reason) {
  return {
    id: 'groupx.review',
    version: 1,
    title: 'GroupX project review',
    scope: 'project',
    operations: ['start', 'status', 'cancel'],
    availability: 'unavailable',
    reason,
    requiresApproval: false,
    supportsCancel: true,
  }
}

function availableDescriptor() {
  return {
    id: 'groupx.review',
    version: 1,
    title: 'GroupX project review',
    scope: 'project',
    operations: ['start', 'status', 'cancel'],
    availability: 'available',
    requiresApproval: false,
    supportsCancel: true,
  }
}

function makeLlm({ stream = defaultStream } = {}) {
  const calls = []
  const llm = {
    calls,
    listProviders: () => [
      { id: 'provider-a', name: 'Provider A' },
      { id: 'provider-b', name: 'Provider B' },
      { id: 'unselected-provider', name: 'Unselected' },
    ],
    listModels: async provider => {
      if (provider === 'provider-a') return [{ provider, id: 'model-a', name: 'Model A' }]
      if (provider === 'provider-b') return [{ provider, id: 'model-b', name: 'Model B' }]
      return [{ provider, id: 'unselected-model', name: 'Unselected' }]
    },
    stream(options) {
      calls.push(options)
      return stream(options)
    },
  }
  return llm
}

async function* defaultStream() {
  yield { type: 'text-delta', text: 'advice' }
  yield { type: 'finish', reason: { kind: 'stop' } }
}

function modeWith({ state = 'completed', summary = 'Review summary', calls = 1, delay = 0, onInput } = {}) {
  return {
    async runRoundtable(input) {
      onInput?.(input)
      if (delay > 0) {
        await new Promise(resolve => setTimeout(resolve, delay))
      }
      for (let index = 0; index < calls; index += 1) {
        await collect(input.llm.stream({
          provider: models[index % models.length].provider,
          model: models[index % models.length].model,
          messages: [{
            id: `message-${index}`,
            role: 'user',
            content: [{ type: 'text', text: input.task }],
            source: { kind: 'user' },
          }],
          system: 'advisory system',
          maxTokens: 999,
          signal: input.signal,
          tools: [{ name: 'must-not-forward' }],
          agent: { name: 'must-not-forward' },
        }))
      }
      return {
        state,
        summary,
        participants: [{ actorId: 'dsh:provider-a/model-a' }],
      }
    },
  }
}

async function collect(iterable) {
  const chunks = []
  for await (const chunk of iterable) chunks.push(chunk)
  return chunks
}

async function waitForTerminal(service, job, task, { attempts = 50 } = {}) {
  let latest = job
  for (let index = 0; index < attempts; index += 1) {
    latest = await service.status(ref(job.jobId, task))
    if (!['queued', 'running'].includes(latest.state)) return latest
    await new Promise(resolve => setTimeout(resolve, 0))
  }
  throw new Error(`job did not finish: ${latest.state}`)
}

test('reports missing services, invalid models, and missing public module as unavailable', async () => {
  const missing = createGroupxReviewService(context(), models, {
    mode: modeWith(),
  })
  assert.deepEqual(await missing.describe(), unavailableDescriptor('llm-unavailable'))

  const invalidModels = createGroupxReviewService(context({ llm: makeLlm() }), [
    { provider: 'provider-a', model: 'model-a', tools: ['exfiltrate'] },
  ], { mode: modeWith() })
  assert.deepEqual(await invalidModels.describe(), unavailableDescriptor('models-invalid'))

  const missingMode = createGroupxReviewService(
    context({ llm: makeLlm() }),
    models,
    { loadMode: async () => { throw new Error('module missing') } },
  )
  assert.deepEqual(await missingMode.describe(), unavailableDescriptor('module-unavailable'))
})

test('validates malicious parameters and binds the proposal digest to exact UTF-8 task text', async () => {
  const service = createGroupxReviewService(
    context({ llm: makeLlm() }),
    models,
    { mode: modeWith() },
  )
  const jobId = validJobID()
  const task = 'Review exact text.'
  await assert.rejects(
    service.start({ jobId, proposalRevision: digest('different'), task }),
    error => error.code === 'proposal-digest-mismatch',
  )
  await assert.rejects(
    service.start({ jobId, proposalRevision: digest(task), task, __proto__: { polluted: true } }),
    error => error.code === 'invalid-request',
  )
  await assert.rejects(
    service.start({ jobId: 'not-a-uuid', proposalRevision: digest(task), task }),
    error => error.code === 'invalid-job-id',
  )
  await assert.rejects(
    service.start({ jobId, proposalRevision: digest('x'.repeat(16_001)), task: 'x'.repeat(16_001) }),
    error => error.code === 'invalid-task',
  )
})

test('bounds metadata readiness and never creates a late job after timeout', async () => {
  const llm = makeLlm()
  llm.listModels = async () => new Promise(() => {})
  const service = createGroupxReviewService(
    context({ llm }),
    models,
    { mode: modeWith(), metadataTimeoutMs: 5, describeTimeoutMs: 5 },
  )
  const task = 'Metadata timeout review.'
  const input = { jobId: validJobID(5), proposalRevision: digest(task), task }
  await assert.rejects(service.start(input), error => error.code === 'metadata-timeout')
  assert.deepEqual(await service.describe(), unavailableDescriptor('metadata-timeout'))
  assert.equal((await service.status(ref(input.jobId, task))).state, 'unknown')
})

test('uses a synthetic session, advisory config, selected model refs, and forwards no tools', async () => {
  const llm = makeLlm()
  let captured
  const service = createGroupxReviewService(
    context({ llm }),
    models,
    {
      mode: modeWith({ summary: '第一行\n😀第二行', onInput: input => { captured = input } }),
    },
  )
  const task = 'Summarize the proposal.\n😀'
  assert.deepEqual(await service.describe(), availableDescriptor())
  const started = await service.start({ jobId: validJobID(), proposalRevision: digest(task), task })
  const finished = await waitForTerminal(service, started, task)
  assert.equal(finished.state, 'succeeded')
  assert.equal(finished.summary, '第一行\n😀第二行')
  assert.equal(finished.participantCount, 1)
  assert.equal(finished.modelCalls, 1)
  assert.equal(finished.maxModelCalls, 16)
  assert.match(captured.sessionId, /^harvis-review-[0-9a-f-]{36}$/u)
  assert.deepEqual(captured.config, {
    dshModels: models,
    timeoutMs: 60_000,
    dshMaxTokens: 1_200,
    maxParticipants: models.length,
  })
  assert.strictEqual(captured.roleRegistry, roleRegistry)
  assert.strictEqual(captured.artifactStore, artifactStore)
  assert.equal(llm.calls.length, 1)
  assert.equal(llm.calls[0].provider, 'provider-a')
  assert.equal(llm.calls[0].model, 'model-a')
  assert.equal(llm.calls[0].maxTokens, 1_200)
  assert.equal('tools' in llm.calls[0], false)
  assert.equal('agent' in llm.calls[0], false)
  assert.ok(llm.calls[0].signal instanceof AbortSignal)
})

test('same job and digest is idempotent, while a digest mismatch is rejected', async () => {
  const llm = makeLlm()
  let executions = 0
  const mode = modeWith({ onInput: () => { executions += 1 } })
  const service = createGroupxReviewService(context({ llm }), models, { mode })
  const task = 'Idempotent review.'
  const input = { jobId: validJobID(), proposalRevision: digest(task), task }
  const first = await service.start(input)
  const duplicate = await service.start(input)
  assert.equal(duplicate.jobId, first.jobId)
  assert.equal(duplicate.proposalRevision, first.proposalRevision)
  await waitForTerminal(service, first, task)
  assert.equal(executions, 1)
  const otherTask = 'another task'
  await assert.rejects(
    service.start({ ...input, proposalRevision: digest(otherTask), task: otherTask }),
    error => error.code === 'job-proposal-mismatch',
  )
})

test('concurrent same-job starts reserve one job and execute one roundtable', async () => {
  const llm = makeLlm()
  let executions = 0
  const service = createGroupxReviewService(
    context({ llm }),
    models,
    { mode: modeWith({ delay: 5, onInput: () => { executions += 1 } }) },
  )
  const task = 'Concurrent review.'
  const input = { jobId: validJobID(4), proposalRevision: digest(task), task }
  const [first, duplicate] = await Promise.all([service.start(input), service.start(input)])
  assert.equal(first.jobId, duplicate.jobId)
  assert.equal(first.proposalRevision, duplicate.proposalRevision)
  await waitForTerminal(service, first, task)
  assert.equal(executions, 1)
})

test('enforces the sixteen-call budget and reports actual model calls', async () => {
  const llm = makeLlm()
  const service = createGroupxReviewService(
    context({ llm }),
    models,
    { mode: modeWith({ calls: 20 }) },
  )
  const task = 'Budget review.'
  const started = await service.start({ jobId: validJobID(), proposalRevision: digest(task), task })
  const finished = await waitForTerminal(service, started, task)
  assert.equal(finished.state, 'failed')
  assert.equal(finished.errorCode, 'model-call-budget-exceeded')
  assert.equal(finished.modelCalls, 16)
  assert.equal(llm.calls.length, 16)
})

test('publishes model call count while the review is still running', async () => {
  let release
  const gate = new Promise(resolve => { release = resolve })
  const mode = {
    async runRoundtable(input) {
      await collect(input.llm.stream({ provider: models[0].provider, model: models[0].model,
        messages: [{ id: 'm1', role: 'user', content: [{ type: 'text', text: input.task }], source: { kind: 'user' } }] }))
      await gate
      return { state: 'completed', summary: 'Review summary', participants: [] }
    },
  }
  const service = createGroupxReviewService(context({ llm: makeLlm() }), models, { mode })
  const task = 'Synthetic progress review.'
  const job = await service.start({ jobId: validJobID(500), proposalRevision: digest(task), task })
  const running = await service.status(ref(job.jobId, task))
  assert.equal(running.state, 'running')
  assert.equal(running.modelCalls, 1)
  release()
  assert.equal((await waitForTerminal(service, job, task)).modelCalls, 1)
})

test('cancels owned work, maps failed and unresolved results, and exposes unknown jobs safely', async () => {
  const llm = makeLlm()
  let release
  const delayedMode = {
    async runRoundtable(input) {
      await new Promise(resolve => { release = resolve })
      if (input.signal.aborted) return { state: 'cancelled', summary: '', participants: [] }
      return { state: 'completed', summary: 'late', participants: [] }
    },
  }
  const service = createGroupxReviewService(context({ llm }), models, { mode: delayedMode })
  const task = 'Cancel review.'
  const started = await service.start({ jobId: validJobID(2), proposalRevision: digest(task), task })
  const cancelled = await service.cancel(ref(started.jobId, task))
  assert.equal(cancelled.state, 'cancelled')
  assert.equal(cancelled.errorCode, 'cancelled')
  assert.equal(cancelled.modelCalls, 0)
  release?.()

  const failedService = createGroupxReviewService(context({ llm }), models, {
    mode: {
      async runRoundtable() { throw new Error('private failure') },
    },
  })
  const failedTask = 'Failure review.'
  const failedStart = await failedService.start({
    jobId: validJobID(3), proposalRevision: digest(failedTask), task: failedTask,
  })
  const failed = await waitForTerminal(failedService, failedStart, failedTask)
  assert.equal(failed.state, 'failed')
  assert.equal(failed.errorCode, 'run-failed')
  const unknown = await failedService.status(ref(validJobID(99), 'unknown review'))
  assert.equal(unknown.state, 'unknown')
  assert.equal(unknown.errorCode, 'unknown-job')
  assert.equal(unknown.modelCalls, 0)
})

test('retains an active slot until cancelled underlying work settles', async () => {
  const llm = makeLlm()
  const releases = []
  const service = createGroupxReviewService(context({ llm }), models, {
    mode: {
      async runRoundtable() {
        await new Promise(resolve => { releases.push(resolve) })
        return { state: 'completed', summary: 'late', participants: [] }
      },
    },
  })
  const firstTask = 'Held cancel review.'
  const secondTask = 'Held second review.'
  const first = await service.start({
    jobId: validJobID(6), proposalRevision: digest(firstTask), task: firstTask,
  })
  const second = await service.start({
    jobId: validJobID(7), proposalRevision: digest(secondTask), task: secondTask,
  })
  assert.equal(releases.length, 2)
  assert.equal((await service.cancel(ref(first.jobId, firstTask))).state, 'cancelled')
  const thirdTask = 'Held third review.'
  await assert.rejects(
    service.start({ jobId: validJobID(8), proposalRevision: digest(thirdTask), task: thirdTask }),
    error => error.code === 'active-job-limit',
  )
  for (const release of releases) release()
  assert.equal((await waitForTerminal(service, first, firstTask)).state, 'cancelled')
  assert.equal((await waitForTerminal(service, second, secondTask)).state, 'succeeded')
})

test('limits active jobs and keeps at most twenty completed projections', async () => {
  const llm = makeLlm()
  const releases = []
  const blockedMode = {
    async runRoundtable() {
      await new Promise(resolve => { releases.push(resolve) })
      return { state: 'completed', summary: 'done', participants: [] }
    },
  }
  const service = createGroupxReviewService(context({ llm }), models, { mode: blockedMode })
  const jobs = []
  for (let index = 0; index < 2; index += 1) {
    const task = `Active ${index}`
    jobs.push(await service.start({ jobId: validJobID(10 + index), proposalRevision: digest(task), task }))
  }
  const thirdTask = 'Active third'
  await assert.rejects(
    service.start({ jobId: validJobID(12), proposalRevision: digest(thirdTask), task: thirdTask }),
    error => error.code === 'active-job-limit',
  )
  for (const release of releases) release()
  await Promise.all(jobs.map(job => waitForTerminal(service, job, `Active ${jobs.indexOf(job)}`)))

  const fastService = createGroupxReviewService(context({ llm }), models, {
    mode: modeWith(),
  })
  const completed = []
  for (let index = 0; index < 21; index += 1) {
    const task = `Completed ${index}`
    const job = await fastService.start({
      jobId: validJobID(100 + index), proposalRevision: digest(task), task,
    })
    completed.push(await waitForTerminal(fastService, job, task))
  }
  const evicted = await fastService.status(ref(validJobID(100), 'Completed 0'))
  assert.equal(evicted.state, 'unknown')
  assert.equal(completed.at(-1).state, 'succeeded')
})
