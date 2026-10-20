import assert from 'node:assert/strict'
import { Readable } from 'node:stream'
import test from 'node:test'
import { apply, describeGroupx } from '../src/index.js'
import { collectUserInputs } from '../src/inputs.js'
import {
  BRIDGE_SCHEMA_VERSION,
  MAX_ITEM_CHARS,
  USER_INPUTS_SCHEMA_VERSION,
  parseGroupxReviewStartParams,
  parseSupervisorMutationParams,
  validBoundedText,
} from '../src/contracts.js'

test('review task and summary accept multiline Unicode text but reject unsafe controls', () => {
  const params = { jobId: '12345678-1234-4234-8234-123456789012', proposalRevision: 'sha256:' + 'a'.repeat(64), task: '复核这些建议。\n{"suggestions":[]}' }
  assert.deepEqual(parseGroupxReviewStartParams(params), params)
  assert.equal(validBoundedText('第一行\n\t第二行', 12_000), true)
  assert.equal(validBoundedText('😀'.repeat(12_000), 12_000), true)
  assert.equal(validBoundedText('text\u0000hidden', 12_000), false)
  assert.throws(() => parseGroupxReviewStartParams({ ...params, task: 'text\u0000hidden' }))
})

test('a user source marker cannot promote a non-user role into human evidence', () => {
  const result = collectUserInputs('synthetic-role', { events: [
    event(1, 'user/message', { ...message('human', 'request'), role: 'user' }),
    event(2, 'user/message', { ...message('assistant', 'response'), role: 'assistant' }),
  ] })
  assert.equal(result.items.length, 1)
  assert.equal(result.items[0].id, 'human')
  assert.equal(result.excludedNonHumanItems, 1)
})

class FakeResponse {
  statusCode = 0
  headers = {}
  body = undefined

  writeHead(status, headers) {
    this.statusCode = status
    this.headers = headers
  }

  end(body = '') {
    this.body = Buffer.isBuffer(body) ? body.toString('utf8') : String(body)
  }
}

function event(seq, type, data, time = 1_700_000_000_000) {
  return { seq, type, data, time, ...(type === 'user/message' ? { surfaceOp: 'append' } : {}) }
}

function message(id, text, source = { kind: 'user' }) {
  return { id, role: 'user', content: [{ type: 'text', text }], source }
}

function makePersistence() {
  const session = {
    id: 'session-1',
    meta: { id: 'session-1', version: 0, createdAt: 1 },
    revision: 'revision-1',
    events: [
      event(0, 'turn/start', { turn: 1 }),
      event(1, 'user/message', message('human-1', 'hello')),
      event(2, 'user/message', message('context-1', 'injected', { kind: 'plugin', plugin: 'notice' })),
      event(3, 'user/message', message('rpc-1', 'rpc prompt', { kind: 'user', rpcId: 'rpc-1' })),
      event(4, 'tool/result', { message: { role: 'user', source: { kind: 'tool' }, content: [] } }),
      event(5, 'user/message', message('human-2', 'x'.repeat(MAX_ITEM_CHARS + 5))),
      event(6, 'turn/end', { turn: 1 }),
    ],
  }
  return {
    session,
    listSnapshots: async () => [{ header: session.meta, revision: session.revision }],
    inspect: async id => {
      if (id !== session.id) throw new Error(`session "${id}" not found`)
      return { meta: session.meta, events: session.events }
    },
  }
}

function mount({ persistence = makePersistence(), config = {}, includePersistence = true } = {}) {
  const routeHost = {}
  const services = { webServer: routeHost }
  if (includePersistence) services.sessionPersistence = persistence
  const ctx = {
    get(name) { return services[name] },
    effect(effect) { routeHost.dispose = effect() },
    logger: { warn() {} },
  }
  routeHost.register = route => {
    routeHost.route = route
    return () => { routeHost.route = undefined }
  }
  apply(ctx, { homeID: 'home-1', profile: 'digital-me', ...config })
  return { route: routeHost.route, persistence, routeHost }
}

async function call(route, body, {
  address = '127.0.0.1',
  host = '127.0.0.1',
  origin,
  method = 'POST',
  contentType = 'application/json',
} = {}) {
  const req = Readable.from([JSON.stringify(body)])
  req.method = method
  req.headers = { 'content-type': contentType }
  req.headers.host = host
  if (origin !== undefined) req.headers.origin = origin
  req.socket = { remoteAddress: address }
  const res = new FakeResponse()
  await route.handler(req, res)
  let value
  try { value = res.body ? JSON.parse(res.body) : undefined } catch { value = undefined }
  return { response: res, value }
}

function request(method, params, requestId = 'request-1') {
  return { schemaVersion: BRIDGE_SCHEMA_VERSION, requestId, method, params }
}

test('strictly validates the Supervisor mutation parameter matrix', () => {
  const base = {
    sessionId: 'session-1',
    expectedRuntimeId: 'runtime-1',
    expectedRevision: 'sha256:' + 'a'.repeat(64),
    actionId: 'action-1',
  }

  assert.deepEqual(
    parseSupervisorMutationParams({ ...base, patch: { mode: 'advice' } }, 'set'),
    { ...base, patch: { mode: 'advice' } },
  )
  assert.throws(
    () => parseSupervisorMutationParams(base, 'set'),
    error => error?.code === 'invalid-request',
  )
  assert.throws(
    () => parseSupervisorMutationParams({ ...base, patch: {} }, 'set'),
    error => error?.code === 'invalid-request',
  )

  for (const operation of ['regenerate', 'adopt', 'recover']) {
    assert.deepEqual(parseSupervisorMutationParams(base, operation), { ...base, patch: undefined })
    assert.throws(
      () => parseSupervisorMutationParams({ ...base, patch: { mode: 'advice' } }, operation),
      error => error?.code === 'invalid-request',
    )
  }
})

test('requires immutable authority configuration', () => {
  const ctx = { get: () => ({ register() {} }) }
  assert.throws(() => apply(ctx), /homeID and profile are required/)
})

test('describes the user-input capability only when persistence methods exist', async () => {
  const mounted = mount({ includePersistence: true })
  const available = await call(mounted.route, request('capabilities.describe', {}))
  assert.equal(available.response.statusCode, 200)
  assert.equal(available.value.result.ok, true)
  assert.equal(available.value.result.value.schemaVersion, 'harvis.dsh-capabilities.v1')
  assert.equal(available.value.result.value.capabilities[0].availability, 'available')
  assert.equal(available.value.authority.homeID, 'home-1')
  assert.equal(available.value.authority.profile, 'digital-me')
  assert.match(available.value.authority.runtimeId, /^[0-9a-f-]{36}$/)

  const unavailable = mount({ includePersistence: false })
  const described = await call(unavailable.route, request('capabilities.describe', {}, 'request-2'))
  assert.equal(described.value.result.value.capabilities[0].availability, 'unavailable')
  assert.equal(described.value.result.value.capabilities[0].reason, 'source-unavailable')
})

test('projects only text user messages, keeps source provenance, and paginates', async () => {
  const mounted = mount()
  const first = await call(mounted.route, request('session.userInputs', {
    sessionId: 'session-1', cursor: null, limit: 2,
  }))
  assert.equal(first.value.result.ok, true)
  const page = first.value.result.value
  assert.equal(page.schemaVersion, USER_INPUTS_SCHEMA_VERSION)
  assert.equal(page.totalItems, 3)
  assert.equal(page.excludedNonHumanItems, 2)
  assert.deepEqual(page.items.map(item => item.source), ['human', 'unknown'])
  assert.equal(page.items[0].turnId, '1')
  assert.match(page.items[0].originMessageIDHash, /^sha256:[0-9a-f]{64}$/)
  assert.ok(page.nextCursor)

  const second = await call(mounted.route, request('session.userInputs', {
    sessionId: 'session-1', cursor: page.nextCursor, limit: 2,
  }, 'request-2'))
  const secondPage = second.value.result.value
  assert.equal(secondPage.items.length, 1)
  assert.equal(secondPage.items[0].source, 'human')
  assert.equal(secondPage.items[0].truncated, true)
  assert.equal(secondPage.items[0].text.length, MAX_ITEM_CHARS)
  assert.equal(secondPage.nextCursor, null)
})

test('rejects stale cursors and configured internal sessions', async () => {
  const mounted = mount({ config: { internalSessionIds: ['session-1'] } })
  const internal = await call(mounted.route, request('session.userInputs', {
    sessionId: 'session-1', limit: 1,
  }))
  assert.equal(internal.value.result.ok, false)
  assert.equal(internal.value.result.error.code, 'internal-session')

  const normal = mount()
  const first = await call(normal.route, request('session.userInputs', {
    sessionId: 'session-1', limit: 1,
  }))
  normal.persistence.session.revision = 'revision-2'
  const stale = await call(normal.route, request('session.userInputs', {
    sessionId: 'session-1', cursor: first.value.result.value.nextCursor, limit: 1,
  }))
  assert.equal(stale.value.result.ok, false)
  assert.equal(stale.value.result.error.code, 'stale-cursor')
})

test('keeps the route loopback-only and method/content-type strict', async () => {
  const mounted = mount()
  const body = request('capabilities.describe', {})
  assert.equal((await call(mounted.route, body, { address: '192.168.1.4' })).response.statusCode, 403)
  assert.equal((await call(mounted.route, body, { host: 'evil.example' })).response.statusCode, 403)
  assert.equal((await call(mounted.route, body, { origin: 'null' })).response.statusCode, 403)
  assert.equal((await call(mounted.route, body, { origin: 'http://evil.example' })).response.statusCode, 403)
  assert.equal((await call(mounted.route, body, {
    host: '127.0.0.1:1234', origin: 'http://127.0.0.1:1235',
  })).response.statusCode, 403)
  assert.equal((await call(mounted.route, body, {
    host: '127.0.0.1:1234', origin: 'http://127.0.0.1:1234',
  })).response.statusCode, 200)
  assert.equal((await call(mounted.route, body, { method: 'GET' })).response.statusCode, 405)
  assert.equal((await call(mounted.route, body, { contentType: 'text/plain' })).response.statusCode, 415)
})

test('does not let an optional GroupX describe hang bridge discovery', async () => {
  const started = Date.now()
  const descriptor = await describeGroupx({ describe: () => new Promise(() => {}) }, 20)
  assert.equal(descriptor.availability, 'unavailable')
  assert.equal(descriptor.reason, 'capability-timeout')
  assert.ok(Date.now() - started < 500)
})
