import assert from 'node:assert/strict'
import test from 'node:test'
import { createSupervisorController, normalizeSupervisorProjection } from '../src/supervisor.js'

function state(overrides = {}) {
  return {
    mode: 'advice',
    strategy: 'insight',
    rounds: 1,
    used: 0,
    intervalMs: 2_000,
    status: 'silent',
    suggestion: '',
    suggestError: '',
    execution: {
      remaining: 1,
      done: false,
      runId: 'run-1',
      suggestionId: '',
      recoveryRequired: '',
    },
    ...overrides,
  }
}

function fixture() {
  const agent = { id: 'session-1', session: { id: 'session-1' }, status: 'idle' }
  const controls = { raw: state({ mode: 'off', status: 'off' }), writes: [], loseResponse: false, beforeRead: undefined }
  const services = {
    agents: { get: id => id === 'session-1' ? agent : undefined, roots: () => [agent] },
    commands: {
      find: () => ({ name: 'supervise' }),
      execute: async (target, line, images, signal) => {
        assert.equal(target, agent)
        assert.deepEqual(images, [])
        if (line === '/supervise _state') {
          if (controls.beforeRead) await controls.beforeRead(signal)
        } else {
          controls.writes.push(line)
          if (line.startsWith('/supervise _set ')) {
            Object.assign(controls.raw, JSON.parse(line.slice('/supervise _set '.length)))
            controls.raw.status = controls.raw.mode === 'off' ? 'off' : 'silent'
          }
          if (line === '/supervise _adopt') {
            controls.raw.used += 1
            controls.raw.execution.remaining -= 1
            controls.raw.execution.done = true
          }
          if (controls.loseResponse) return undefined
        }
        return { commandId: 'fixture-command', result: { kind: 'success', text: JSON.stringify(controls.raw) } }
      },
    },
  }
  const controller = createSupervisorController({ authority: { runtimeId: 'runtime-1' }, getServices: () => services })
  const identity = { sessionId: 'session-1', expectedRuntimeId: 'runtime-1' }
  return { agent, controls, services, controller, identity }
}

test('source runtime, exact root object and native session id are required', async () => {
  const f = fixture()
  assert.equal(f.controller.descriptor().availability, 'available')
  await assert.rejects(async () => f.controller.read({ ...f.identity, expectedRuntimeId: 'restarted' }), { code: 'runtime-mismatch' })
  await assert.rejects(async () => f.controller.read({ ...f.identity, sessionId: 'other-session' }), { code: 'session-unavailable' })
  f.services.agents.roots = () => [{ ...f.agent }]
  await assert.rejects(async () => f.controller.read(f.identity), { code: 'unsupported-session' })
  f.services.agents.roots = () => [f.agent]
  f.agent.session.id = 'other-session'
  await assert.rejects(async () => f.controller.read(f.identity), { code: 'session-unavailable' })
  f.services.commands.find = () => undefined
  assert.equal(f.controller.descriptor().availability, 'unavailable')
  assert.equal(f.controls.writes.length, 0)
})

test('stale revisions reject before writing and parallel duplicates share one receipt', async () => {
  const f = fixture()
  const before = await f.controller.read(f.identity)
  const params = { ...f.identity, expectedRevision: before.revision, actionId: 'start-1', patch: { mode: 'advice' } }
  const [left, right] = await Promise.all([f.controller.mutate('set', params), f.controller.mutate('set', params)])
  assert.deepEqual(left, right)
  assert.equal(left.mode, 'advice')
  assert.equal(f.controls.writes.length, 1)
  await assert.rejects(async () => f.controller.mutate('set', { ...params, patch: { mode: 'takeover' } }), { code: 'action-conflict' })
  await assert.rejects(async () => f.controller.mutate('set', { ...params, actionId: 'stale-2' }), { code: 'stale-revision' })
  assert.equal(f.controls.writes.length, 1)
  assert.equal((await f.controller.read(f.identity)).mode, 'advice')
})

test('unknown mutation results stay reserved and are never replayed', async () => {
  const f = fixture()
  const before = await f.controller.read(f.identity)
  f.controls.loseResponse = true
  const params = { ...f.identity, expectedRevision: before.revision, actionId: 'unknown-1', patch: { mode: 'advice' } }
  await assert.rejects(async () => f.controller.mutate('set', params), { code: 'action-unknown' })
  await assert.rejects(async () => f.controller.mutate('set', params), { code: 'action-unknown' })
  assert.equal(f.controls.writes.length, 1)
  assert.equal((await f.controller.read(f.identity)).mode, 'advice')
})

test('adopt requires reviewed text and respects native busy or approval state', async () => {
  const f = fixture()
  f.controls.raw = state({ suggestion: 'Reviewed suggestion' })
  f.controls.raw.execution.suggestionId = 'suggestion-1'
  for (const status of ['running', 'pendingApproval']) {
    f.agent.status = status
    const before = await f.controller.read(f.identity)
    await assert.rejects(async () => f.controller.mutate('adopt', {
      ...f.identity, expectedRevision: before.revision, actionId: 'blocked-' + status,
    }), { code: 'action-unavailable' })
  }
  f.agent.status = 'idle'
  const before = await f.controller.read(f.identity)
  const params = { ...f.identity, expectedRevision: before.revision, actionId: 'adopt-1' }
  await Promise.all([f.controller.mutate('adopt', params), f.controller.mutate('adopt', params)])
  assert.equal(f.controls.writes.filter(line => line.endsWith('_adopt')).length, 1)
  assert.equal(f.controls.raw.used, 1)
  for (const suggestion of ['x'.repeat(12_001), 'hidden\u0000suffix']) {
    assert.throws(() => normalizeSupervisorProjection('session-1', state({ suggestion }), f.agent), { code: 'invalid-state' })
  }
})

test('agent replacement after reading cannot mutate the stale root', async () => {
  const f = fixture()
  const before = await f.controller.read(f.identity)
  f.controls.beforeRead = async () => { f.services.agents.get = () => ({ ...f.agent }) }
  await assert.rejects(async () => f.controller.mutate('set', {
    ...f.identity, expectedRevision: before.revision, actionId: 'replace-1', patch: { mode: 'advice' },
  }), { code: 'unsupported-session' })
  assert.equal(f.controls.writes.length, 0)
})

test('bridge disposal aborts an active read and rejects queued writes', async () => {
  const f = fixture()
  const before = await f.controller.read(f.identity)
  let started
  const ready = new Promise(resolve => { started = resolve })
  f.controls.beforeRead = signal => new Promise((resolve, reject) => {
    started()
    signal.addEventListener('abort', () => reject(signal.reason), { once: true })
  })
  const pending = f.controller.read(f.identity)
  const readFailure = assert.rejects(pending, { code: 'action-unknown' })
  await ready
  const queued = f.controller.mutate('set', {
    ...f.identity, expectedRevision: before.revision, actionId: 'disposed-1', patch: { mode: 'advice' },
  })
  const queuedFailure = assert.rejects(queued, { code: 'capability-unavailable' })
  await f.controller.dispose()
  await Promise.all([readFailure, queuedFailure])
  assert.equal(f.controls.writes.length, 0)
})

test('projects the required execution identity fields without fallback coercion', () => {
  const projection = normalizeSupervisorProjection('session-1', state(), { status: 'idle' })
  assert.equal(projection.runId, 'run-1')
  assert.equal(projection.done, false)
  assert.match(projection.revision, /^sha256:[0-9a-f]{64}$/)

  assert.throws(
    () => normalizeSupervisorProjection('session-1', state({ execution: {
      remaining: 1,
      done: 'false',
      runId: 'run-1',
    } }), { status: 'idle' }),
    error => error?.code === 'invalid-state',
  )
  assert.throws(
    () => normalizeSupervisorProjection('session-1', state({ execution: {
      remaining: 1,
      done: false,
      runId: '',
    } }), { status: 'idle' }),
    error => error?.code === 'invalid-state',
  )
  assert.throws(
    () => normalizeSupervisorProjection('session-1', state({ execution: {
      remaining: 1,
      done: false,
    } }), { status: 'idle' }),
    error => error?.code === 'invalid-state',
  )
})
