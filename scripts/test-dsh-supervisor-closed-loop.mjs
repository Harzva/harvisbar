#!/usr/bin/env node

/**
 * Closed-loop fixture for the installed dsh-supervisor plugin.
 *
 * The test deliberately loads the plugin from DSH_SUPERVISOR_PLUGIN_PATH (or
 * the normal `dsh-supervisor` package resolver), then gives it a small
 * Cordis-shaped host. No account, credential, provider, or business session
 * is used. The only durable file is a temporary Supervisor store.
 */

import assert from 'node:assert/strict'
import { createServer } from 'node:http'
import { once } from 'node:events'
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { statSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { tmpdir } from 'node:os'
import { pathToFileURL } from 'node:url'

const SESSION_ID = 'fixture-supervisor-session'
const BRIDGE_HOME_ID = 'fixture-home'
const BRIDGE_PROFILE = 'fixture-profile'
const SUGGESTION = '确定下一个未完成步骤并执行。'

function packageSpecifier() {
  const configured = process.env.DSH_SUPERVISOR_PLUGIN_PATH?.trim()
  if (!configured) return 'dsh-supervisor'
  if (configured.startsWith('file:')) return configured
  const resolved = resolve(configured)
  try {
    if (statSync(resolved).isDirectory()) return pathToFileURL(join(resolved, 'lib/index.js')).href
  } catch {
    // Import below reports a stable missing-plugin error.
  }
  return pathToFileURL(resolved).href
}

async function loadModule(specifier, label) {
  try {
    return await import(specifier)
  } catch (error) {
    if (label === 'dsh-supervisor' && !process.env.DSH_SUPERVISOR_PLUGIN_PATH) {
      throw new Error('dsh-supervisor is not resolvable; set DSH_SUPERVISOR_PLUGIN_PATH to the installed plugin entry point')
    }
    throw error
  }
}

function deferred() {
  let resolvePromise
  let rejectPromise
  const promise = new Promise((resolveValue, rejectValue) => {
    resolvePromise = resolveValue
    rejectPromise = rejectValue
  })
  return { promise, resolve: resolvePromise, reject: rejectPromise }
}

async function settleMicrotasks() {
  await Promise.resolve()
  await new Promise(resolveValue => setImmediate(resolveValue))
  await Promise.resolve()
}

class FixtureRuntime {
  constructor({ supervisor, bridge, storePath, mountBridge = true, llmBehavior } = {}) {
    this.supervisor = supervisor
    this.bridge = bridge
    this.storePath = storePath
    this.mountBridge = mountBridge
    this.metrics = {
      followups: [],
      steers: [],
      injects: [],
      llmCalls: [],
      logs: [],
      flushes: 0,
      nativeTurnStops: 0,
    }
    this.listeners = new Map()
    this.timeouts = []
    this.intervals = []
    this.effects = []
    this.routes = new Map()
    this.pendingTasks = new Set()
    this.wireResponses = []
    this.disposed = false
    this.sequence = 2
    this.llmBehavior = llmBehavior || (() => SUGGESTION)

    const session = {
      id: SESSION_ID,
      meta: {
        id: SESSION_ID,
        version: 0,
        cwd: '/fixture/workspace',
        agentPreset: 'fixture',
      },
      revision: 'fixture-source-revision-1',
      events: [
        this.event(0, 'turn/start', { turn: 1 }),
        this.event(1, 'user/message', this.message('fixture-user-1', '请完成当前工作并给出下一步。', { kind: 'user' })),
      ],
    }
    this.session = session

    this.agent = {
      id: SESSION_ID,
      title: 'Supervisor fixture',
      status: 'idle',
      options: { provider: 'fixture-provider', model: 'fixture-model' },
      inbox: { nextTurn: [], nextStep: [] },
      session,
      followup: message => this.followup(message),
      steer: message => this.metrics.steers.push({ sid: SESSION_ID, message }),
      inject: message => this.metrics.injects.push({ sid: SESSION_ID, message }),
    }

    this.agentsById = new Map([[SESSION_ID, this.agent]])
    this.commands = {
      definitions: new Map(),
      register: definition => {
        this.commands.definitions.set(definition.name, definition)
        return () => {
          if (this.commands.definitions.get(definition.name) === definition) {
            this.commands.definitions.delete(definition.name)
          }
        }
      },
      find: (_agent, name) => this.commands.definitions.get(name),
      list: () => [...this.commands.definitions.values()],
      get: name => this.commands.definitions.get(name),
      execute: (...args) => this.executeCommand(...args),
    }
    this.webServer = {
      register: definition => {
        this.routes.set(definition.path, definition.handler)
        return () => {
          if (this.routes.get(definition.path) === definition.handler) this.routes.delete(definition.path)
        }
      },
    }

    this.roleRegistry = {
      register: () => () => {},
      resolve: ref => {
        if (!ref || ref.id !== 'dsh-supervisor.forge' || String(ref.version) !== '1') return undefined
        return {
          id: 'dsh-supervisor.forge',
          version: '1',
          label: 'Fixture execution role',
          shortDescription: 'A deterministic execution supervisor used only by this fixture.',
          prompt: {
            identity: '你负责推动当前工作向可验证完成。',
            objectives: ['识别当前工作最小的下一步。'],
            mustCheck: ['依据会话中已有事实。'],
            mustNot: ['不要调用外部服务。'],
            outputContract: ['给出一句具体、可执行的建议。'],
          },
        }
      },
    }

    this.llm = {
      stream: request => this.stream(request),
    }

    this.services = new Map([
      ['agents', {
        roots: () => [this.agent],
        list: () => [this.agent],
        get: id => this.agentsById.get(id),
      }],
      ['commands', this.commands],
      ['webServer', this.webServer],
      ['roleRegistry', this.roleRegistry],
      ['sessions', {
        get: id => this.agentsById.get(id)?.session,
        flush: async sessionValue => {
          assert.equal(sessionValue?.id, SESSION_ID)
          this.metrics.flushes += 1
          return true
        },
      }],
      ['sessionQuery', {
        readSurface: async id => id === SESSION_ID ? { events: this.session.events } : { events: [] },
      }],
      ['sessionProjections', {
        snapshot: () => ({ values: { fixture: true } }),
      }],
      ['sessionPersistence', {
        listSnapshots: async () => [{ header: this.session.meta, revision: this.session.revision }],
        inspect: async id => {
          if (id !== SESSION_ID) throw new Error('session not found')
          return { meta: this.session.meta, events: this.session.events }
        },
      }],
      ['llm', this.llm],
    ])

    this.ctx = {
      logger: {
        info: (...args) => this.metrics.logs.push({ level: 'info', args }),
        warn: (...args) => this.metrics.logs.push({ level: 'warn', args }),
      },
      get: name => this.services.get(name),
      inject: (required, callback) => {
        if (required.every(name => this.services.has(name))) callback(this.ctx)
      },
      effect: factory => this.effect(factory),
      on: (event, handler) => this.on(event, handler),
      interval: (callback, delay) => this.interval(callback, delay),
      timeout: (callback, delay) => this.timeout(callback, delay),
    }

    // Load the real plugin against this host. The package is never copied or
    // modified by the fixture.
    supervisor.apply(this.ctx, {
      mode: 'off',
      strategy: 'insight',
      rounds: 1,
      intervalMs: 2000,
      opinionTimeoutMs: 1000,
      mentors: [{
        id: 'forge',
        name: 'Fixture Forge',
        role: 'execution',
        route: 'fixture-provider/fixture-model',
      }],
      storePath,
    })

    if (mountBridge) {
      assert.ok(bridge?.apply, 'the local dsh-harvis-bridge entry point must export apply')
      bridge.apply(this.ctx, { homeID: BRIDGE_HOME_ID, profile: BRIDGE_PROFILE })
    }
  }

  event(seq, type, data) {
    return { seq, type, time: 1_700_000_000_000 + seq, data, ...(type === 'user/message' ? { surfaceOp: 'append' } : {}) }
  }

  message(id, text, source) {
    return { id, role: 'user', content: [{ type: 'text', text }], source }
  }

  track(promise) {
    this.pendingTasks.add(promise)
    void promise.then(
      () => this.pendingTasks.delete(promise),
      () => this.pendingTasks.delete(promise),
    )
    return promise
  }

  followup(message) {
    this.metrics.followups.push({ sid: SESSION_ID, message })
    const event = this.event(this.sequence++, 'user/message', message)
    this.session.events.push(event)
    this.session.revision = 'fixture-source-revision-' + this.sequence
    this.track(this.emit('session/event', this.session, event))
  }

  stream(request) {
    this.metrics.llmCalls.push(request)
    const behavior = this.llmBehavior
    return (async function* () {
      const value = await behavior(request)
      if (Array.isArray(value)) {
        for (const item of value) {
          if (item !== undefined && item !== null && String(item).length > 0) {
            yield { type: 'text-delta', text: String(item) }
          }
        }
        return
      }
      if (value !== undefined && value !== null && String(value).length > 0) {
        yield { type: 'text-delta', text: String(value) }
      }
    })()
  }

  effect(factory) {
    const entry = { active: true, dispose: undefined }
    this.effects.push(entry)
    const disposer = factory()
    entry.dispose = typeof disposer === 'function' ? disposer : undefined
    return () => {
      if (!entry.active) return
      entry.active = false
      if (entry.dispose) return entry.dispose()
    }
  }

  on(event, handler) {
    const entries = this.listeners.get(event) || []
    const entry = { handler, active: true }
    entries.push(entry)
    this.listeners.set(event, entries)
    return () => { entry.active = false }
  }

  interval(callback, delay) {
    const entry = { callback, delay, active: true }
    this.intervals.push(entry)
    return () => { entry.active = false }
  }

  timeout(callback, delay) {
    const entry = {
      callback: () => this.track(Promise.resolve().then(callback)),
      delay,
      active: true,
    }
    this.timeouts.push(entry)
    return () => { entry.active = false }
  }

  async emit(event, ...args) {
    const entries = (this.listeners.get(event) || []).filter(entry => entry.active)
    await Promise.all(entries.map(entry => Promise.resolve().then(() => entry.handler(...args))))
    await settleMicrotasks()
  }

  async executeCommand(...args) {
    let definition
    let payload
    let nativeCommandCall = false
    if (args[0] && typeof args[0] === 'object' && args[0].id && args[0].session) {
      nativeCommandCall = true
      definition = this.commands.definitions.get('supervise')
      payload = { agent: args[0], rawInput: typeof args[1] === 'string' ? args[1] : '' }
    } else if (typeof args[0] === 'string' && this.commands.definitions.has(args[0])) {
      definition = this.commands.definitions.get(args[0])
      payload = args[1]
    } else if (typeof args[0] === 'string') {
      definition = this.commands.definitions.get('supervise')
      const rawInput = typeof args[1] === 'string' ? args[1] : ''
      payload = { agent: this.agentsById.get(args[0]), rawInput }
    } else if (args[0] && typeof args[0] === 'object') {
      definition = this.commands.definitions.get('supervise')
      const input = args[0]
      payload = {
        agent: input.agent || this.agentsById.get(input.sessionId),
        rawInput: input.rawInput || input.command || input.line || '',
      }
    }
    assert.ok(definition, 'the real supervise command must be registered')
    if (typeof payload === 'string') payload = { agent: this.agent, rawInput: payload }
    payload ||= { agent: this.agent, rawInput: '' }
    if (typeof payload.rawInput === 'string' && payload.rawInput.startsWith('/supervise')) {
      payload = { ...payload, rawInput: payload.rawInput.slice('/supervise'.length).trim() }
    }
    const result = await definition.handler(payload)
    return nativeCommandCall ? { result } : result
  }

  async command(rawInput) {
    return this.executeCommand('supervise', { agent: this.agent, rawInput })
  }

  async state() {
    const result = await this.command('_state')
    assert.equal(result.kind, 'success')
    return JSON.parse(result.text)
  }

  pendingTimeouts() {
    return this.timeouts.filter(entry => entry.active)
  }

  invokeTimeout(entry) {
    assert.ok(entry?.active, 'timeout must be active')
    entry.active = false
    return entry.callback()
  }

  async runAllTimeouts(limit = 30) {
    for (let iteration = 0; iteration < limit; iteration += 1) {
      const batch = this.pendingTimeouts()
      if (batch.length === 0) {
        await this.settle()
        if (this.pendingTimeouts().length === 0) return
        continue
      }
      for (const entry of batch) entry.active = false
      await Promise.all(batch.map(entry => entry.callback()))
      await this.settle()
    }
    assert.fail('fixture timer queue did not drain')
  }

  async waitFor(predicate, message, attempts = 50) {
    for (let index = 0; index < attempts; index += 1) {
      if (predicate()) return
      await settleMicrotasks()
      await new Promise(resolveValue => setTimeout(resolveValue, 0))
    }
    assert.fail(message + ': llm=' + this.metrics.llmCalls.length)
  }

  async settle() {
    for (let index = 0; index < 8; index += 1) {
      await settleMicrotasks()
      const tasks = [...this.pendingTasks]
      if (tasks.length > 0) await Promise.all(tasks)
      if (this.pendingTasks.size === 0) return
    }
  }

  async startHttp() {
    if (this.server) return
    this.server = createServer((request, response) => {
      const pathname = new URL(request.url || '/', 'http://127.0.0.1').pathname
      const handler = this.routes.get(pathname)
      if (!handler) {
        response.writeHead(404, { 'content-type': 'text/plain' })
        response.end('not found')
        return
      }
      Promise.resolve(handler(request, response)).catch(error => {
        if (!response.headersSent) response.writeHead(500, { 'content-type': 'application/json' })
        response.end(JSON.stringify({ error: String(error?.message || error) }))
      })
    })
    this.server.listen(0, '127.0.0.1')
    await once(this.server, 'listening')
    this.port = this.server.address().port
    this.baseUrl = `http://127.0.0.1:${this.port}`
  }

  async request(path, body, method = 'POST') {
    await this.startHttp()
    const options = { method, headers: { accept: 'application/json' } }
    if (body !== undefined) {
      options.headers['content-type'] = 'application/json'
      options.body = JSON.stringify(body)
    }
    const response = await fetch(this.baseUrl + path, options)
    const text = await response.text()
    let value
    try { value = text ? JSON.parse(text) : undefined } catch { value = undefined }
    return { status: response.status, headers: Object.fromEntries(response.headers.entries()), value }
  }

  async bridgeCall(method, params, requestId = 'fixture-' + method.replaceAll('.', '-')) {
    const bridgeModule = await import('../plugins/dsh-harvis-bridge/src/contracts.js')
    const response = await this.request(bridgeModule.BRIDGE_PATH, {
      schemaVersion: bridgeModule.BRIDGE_SCHEMA_VERSION,
      requestId,
      method,
      params,
    })
    if (response.value !== undefined) this.wireResponses.push(response.value)
    return response
  }

  async dispose() {
    if (this.disposed) return
    this.disposed = true
    for (const entries of this.listeners.values()) for (const entry of entries) entry.active = false
    for (const entry of this.timeouts) entry.active = false
    for (const entry of this.intervals) entry.active = false
    for (const entry of [...this.effects].reverse()) {
      if (!entry.active) continue
      entry.active = false
      if (entry.dispose) await entry.dispose()
    }
    await this.settle()
    if (this.server) {
      this.server.close()
      await once(this.server, 'close')
      this.server = undefined
    }
  }
}

async function readStore(path) {
  return JSON.parse(await readFile(path, 'utf8'))
}

function assertSupervisorBridgeValue(value, expectedSessionId = SESSION_ID) {
  assert.equal(value?.schemaVersion, 'harvis.dsh-supervisor.v1')
  assert.equal(value?.sessionId, expectedSessionId)
  assert.equal(typeof value?.revision, 'string')
  assert.ok(value.revision.length > 0)
  return value
}

async function runClosedLoop(supervisor, bridge, directory) {
  const storePath = join(directory, 'supervisor-state.json')
  const runtime = new FixtureRuntime({ supervisor, bridge, storePath })
  await runtime.startHttp()

  try {
    const capabilities = await runtime.bridgeCall('capabilities.describe', {}, 'fixture-capabilities')
    assert.equal(capabilities.status, 200)
    assert.equal(capabilities.value?.result?.ok, true)
    const runtimeId = capabilities.value.authority.runtimeId
    assert.match(runtimeId, /^[0-9a-f-]{36}$/i)
    assert.equal(capabilities.value.authority.homeID, BRIDGE_HOME_ID)
    assert.equal(capabilities.value.authority.profile, BRIDGE_PROFILE)

    const initialResponse = await runtime.bridgeCall('supervisor.session.state', {
      sessionId: SESSION_ID,
      expectedRuntimeId: runtimeId,
    }, 'fixture-state-initial')
    assert.equal(initialResponse.status, 200)
    assert.equal(initialResponse.value?.result?.ok, true, JSON.stringify(initialResponse.value))
    const initial = assertSupervisorBridgeValue(initialResponse.value.result.value)
    assert.equal(initial.mode, 'off')
    let initialRevision = initial.revision
    const initialEventCount = runtime.session.events.length

    // Editing a numeric setting alone must preserve the provider's off mode
    // and all untouched settings; the native panel now sends minimal patches.
    for (const [index, rounds] of [initial.rounds + 1, initial.rounds].entries()) {
      const settingsResponse = await runtime.bridgeCall('supervisor.session.set', {
        sessionId: SESSION_ID,
        expectedRuntimeId: runtimeId,
        expectedRevision: initialRevision,
        actionId: `fixture-rounds-only-${index}`,
        patch: { rounds },
      }, `fixture-state-rounds-only-${index}`)
      assert.equal(settingsResponse.status, 200)
      assert.equal(settingsResponse.value?.result?.ok, true, JSON.stringify(settingsResponse.value))
      const configured = assertSupervisorBridgeValue(settingsResponse.value.result.value)
      assert.equal(configured.mode, 'off')
      assert.equal(configured.rounds, rounds)
      assert.equal(configured.strategy, initial.strategy)
      assert.equal(configured.intervalMs, initial.intervalMs)
      assert.equal(runtime.metrics.llmCalls.length, 0)
      assert.equal(runtime.metrics.followups.length, 0)
      assert.equal(runtime.session.events.length, initialEventCount)
      initialRevision = configured.revision
    }

    const mutationResponse = await runtime.bridgeCall('supervisor.session.set', {
      sessionId: SESSION_ID,
      expectedRuntimeId: runtimeId,
      expectedRevision: initialRevision,
      actionId: 'fixture-enter-advice-1',
      patch: { mode: 'advice' },
    }, 'fixture-state-advice')
    assert.equal(mutationResponse.status, 200)
    assert.equal(mutationResponse.value?.result?.ok, true, JSON.stringify(mutationResponse.value))
    const advice = assertSupervisorBridgeValue(mutationResponse.value.result.value)
    assert.equal(advice.mode, 'advice')
    assert.notEqual(advice.revision, initialRevision)

    const regenerateResponse = await runtime.bridgeCall('supervisor.session.regenerate', {
      sessionId: SESSION_ID,
      expectedRuntimeId: runtimeId,
      expectedRevision: advice.revision,
      actionId: 'fixture-regenerate-1',
    }, 'fixture-supervisor-regenerate')
    assert.equal(regenerateResponse.status, 200)
    assert.equal(regenerateResponse.value?.result?.ok, true, JSON.stringify(regenerateResponse.value))
    const regenerating = assertSupervisorBridgeValue(regenerateResponse.value.result.value)
    assert.equal(regenerating.mode, 'advice')
    assert.equal(regenerating.suggestion, '')
    await runtime.runAllTimeouts()
    const readyResponse = await runtime.bridgeCall('supervisor.session.state', {
      sessionId: SESSION_ID,
      expectedRuntimeId: runtimeId,
    }, 'fixture-supervisor-ready')
    assert.equal(readyResponse.status, 200)
    assert.equal(readyResponse.value?.result?.ok, true, JSON.stringify(readyResponse.value))
    const suggested = assertSupervisorBridgeValue(readyResponse.value.result.value)
    assert.equal(suggested.mode, 'advice')
    assert.equal(suggested.status, 'suggested')
    assert.equal(suggested.suggestion, SUGGESTION)
    assert.equal(runtime.metrics.llmCalls.length, 2, JSON.stringify(runtime.metrics.llmCalls.map(call => ({ system: call.system, messages: call.messages }))))
    assert.equal(runtime.metrics.followups.length, 0)
    assert.equal(runtime.session.events.length, initialEventCount, 'regen must remain read-only for the native session')

    const adoptParams = {
      sessionId: SESSION_ID,
      expectedRuntimeId: runtimeId,
      expectedRevision: suggested.revision,
      actionId: 'fixture-adopt-1',
    }
    const adoptResponse = await runtime.bridgeCall('supervisor.session.adopt', adoptParams, 'fixture-supervisor-adopt')
    assert.equal(adoptResponse.status, 200)
    assert.equal(adoptResponse.value?.result?.ok, true, JSON.stringify(adoptResponse.value))
    const adopted = assertSupervisorBridgeValue(adoptResponse.value.result.value)
    assert.equal(adopted.mode, 'advice')
    assert.equal(adopted.used, 1)
    await runtime.settle()
    assert.equal(runtime.metrics.followups.length, 1)
    assert.equal(runtime.metrics.followups[0].message.source.kind, 'plugin')
    assert.equal(runtime.metrics.followups[0].message.source.plugin, 'dsh-supervisor')
    assert.equal(runtime.session.events.length, initialEventCount + 1)
    assert.equal((runtime.session.events.at(-1).data.message || runtime.session.events.at(-1).data).source.plugin, 'dsh-supervisor')

    const duplicateAdoptResponse = await runtime.bridgeCall(
      'supervisor.session.adopt', adoptParams, 'fixture-supervisor-adopt-replay'
    )
    assert.equal(duplicateAdoptResponse.status, 200)
    assert.equal(duplicateAdoptResponse.value?.result?.ok, true, JSON.stringify(duplicateAdoptResponse.value))
    assert.deepEqual(
      duplicateAdoptResponse.value.result.value,
      adoptResponse.value.result.value,
      'same actionId and payload must replay the cached bridge result',
    )
    await runtime.settle()
    assert.equal(runtime.metrics.followups.length, 1, 'repeating adopt must be exactly once')
    const afterAdopt = assertSupervisorBridgeValue(adoptResponse.value.result.value)
    assert.equal(afterAdopt.used, 1)
    assert.equal(afterAdopt.suggestion, '')
    assert.equal(afterAdopt.recoveryRequired, '')

    // Turning Supervisor off while a native turn is marked running only
    // invalidates Supervisor work. The fixture records any attempt to stop a
    // native turn, which must remain zero.
    runtime.agent.status = 'running'
    const runningResponse = await runtime.bridgeCall('supervisor.session.state', {
      sessionId: SESSION_ID,
      expectedRuntimeId: runtimeId,
    }, 'fixture-supervisor-running')
    assert.equal(runningResponse.status, 200)
    assert.equal(runningResponse.value?.result?.ok, true, JSON.stringify(runningResponse.value))
    const runningState = assertSupervisorBridgeValue(runningResponse.value.result.value)
    assert.equal(runningState.agentStatus, 'running')
    const nativeStopsBeforePause = runtime.metrics.nativeTurnStops
    const offResponse = await runtime.bridgeCall('supervisor.session.set', {
      sessionId: SESSION_ID,
      expectedRuntimeId: runtimeId,
      expectedRevision: runningState.revision,
      actionId: 'fixture-final-off-1',
      patch: { mode: 'off' },
    }, 'fixture-supervisor-off')
    assert.equal(offResponse.status, 200)
    assert.equal(offResponse.value?.result?.ok, true, JSON.stringify(offResponse.value))
    const off = assertSupervisorBridgeValue(offResponse.value.result.value)
    assert.equal(off.mode, 'off')
    assert.equal(off.agentStatus, 'running')
    assert.equal(runtime.metrics.nativeTurnStops, nativeStopsBeforePause)
    assert.equal(runtime.agent.status, 'running')
    runtime.agent.status = 'idle'
    const finalReadyResponse = await runtime.bridgeCall('supervisor.session.state', {
      sessionId: SESSION_ID,
      expectedRuntimeId: runtimeId,
    }, 'fixture-supervisor-final')
    assert.equal(finalReadyResponse.status, 200)
    assert.equal(finalReadyResponse.value?.result?.ok, true, JSON.stringify(finalReadyResponse.value))
    const finalState = assertSupervisorBridgeValue(finalReadyResponse.value.result.value)
    assert.equal(finalState.mode, 'off')

    const persisted = await readStore(storePath)
    assert.equal(persisted.settings[SESSION_ID].mode, 'off')
    assert.equal(persisted.executions[SESSION_ID].state.used, 1)
    const deliveries = Object.values(persisted.executions[SESSION_ID].deliveries)
    assert.equal(deliveries.length, 1)
    assert.ok(['received', 'turn-ended'].includes(deliveries[0].status))
    assert.equal(runtime.metrics.steers.length, 0)
    assert.equal(runtime.metrics.injects.length, 0)

    await runtime.dispose()

    // A second real plugin instance must recover the durable execution state
    // without replaying the delivery.
    const resumed = new FixtureRuntime({ supervisor, bridge, storePath })
    try {
      const resumedCapabilities = await resumed.bridgeCall(
        'capabilities.describe', {}, 'fixture-restart-capabilities'
      )
      assert.equal(resumedCapabilities.status, 200)
      assert.equal(resumedCapabilities.value?.result?.ok, true, JSON.stringify(resumedCapabilities.value))
      const resumedRuntimeId = resumedCapabilities.value.authority.runtimeId
      assert.match(resumedRuntimeId, /^[0-9a-f-]{36}$/i)

      const resumedStateResponse = await resumed.bridgeCall('supervisor.session.state', {
        sessionId: SESSION_ID,
        expectedRuntimeId: resumedRuntimeId,
      }, 'fixture-restart-state')
      assert.equal(resumedStateResponse.status, 200)
      assert.equal(resumedStateResponse.value?.result?.ok, true, JSON.stringify(resumedStateResponse.value))
      const resumedState = assertSupervisorBridgeValue(resumedStateResponse.value.result.value)
      assert.equal(resumedState.mode, 'off')
      assert.equal(resumedState.used, 1)
      assert.equal(resumedState.recoveryRequired, '')
      assert.equal(resumed.metrics.followups.length, 0)

      const recoverResponse = await resumed.bridgeCall('supervisor.session.recover', {
        sessionId: SESSION_ID,
        expectedRuntimeId: resumedRuntimeId,
        expectedRevision: resumedState.revision,
        actionId: 'fixture-supervisor-recover',
      }, 'fixture-supervisor-recover')
      assert.equal(recoverResponse.status, 200)
      assert.equal(recoverResponse.value?.result?.ok, true, JSON.stringify(recoverResponse.value))
      const recovered = assertSupervisorBridgeValue(recoverResponse.value.result.value)
      assert.equal(recovered.mode, 'off')
      assert.equal(recovered.used, 1)
      assert.equal(recovered.recoveryRequired, '')
      assert.equal(resumed.metrics.followups.length, 0)

      // Exercise stale-generation cancellation: let the real plugin enter its
      // LLM stream, turn it off, then release a late deterministic response.
      const pending = deferred()
      resumed.llmBehavior = () => pending.promise
      await resumed.command('mode advice')
      await resumed.command('_regen')
      const regenTimer = resumed.pendingTimeouts().find(entry => entry.delay === 60)
      assert.ok(regenTimer, 'regen must schedule a real Supervisor generation')
      const generationTask = resumed.invokeTimeout(regenTimer)
      await resumed.waitFor(() => resumed.metrics.llmCalls.length === 1, 'real Supervisor generation did not reach fixture LLM')
      await resumed.command('mode off')
      pending.resolve('迟到的建议不应发布。')
      await generationTask
      await resumed.settle()
      const staleState = await resumed.state()
      assert.equal(staleState.mode, 'off')
      assert.equal(staleState.suggestion, '')
      assert.equal(resumed.metrics.followups.length, 0)
    } finally {
      await resumed.dispose()
    }
  } finally {
    await runtime.dispose()
  }

  return {
    sessionId: SESSION_ID,
    llmCalls: 2,
    deliveries: 1,
    restartRecoveredUsed: 1,
    nativeTurnStops: 0,
    partialSettingsPreservedOff: true,
    finalWire: runtime.wireResponses.at(-1),
  }
}

async function main() {
  const supervisor = await loadModule(packageSpecifier(), 'dsh-supervisor')
  const bridge = await loadModule('../plugins/dsh-harvis-bridge/src/index.js', 'dsh-harvis-bridge')
  assert.equal(typeof supervisor.apply, 'function')
  assert.equal(typeof bridge.apply, 'function')

  const directory = await mkdtemp(join(tmpdir(), 'harvis-dsh-supervisor-closed-loop-'))
  try {
    const result = await runClosedLoop(supervisor, bridge, directory)
    const wireOutput = process.env.HARVIS_SUPERVISOR_WIRE_OUTPUT?.trim()
    if (wireOutput) {
      const outputPath = resolve(wireOutput)
      await mkdir(dirname(outputPath), { recursive: true })
      await writeFile(outputPath, JSON.stringify(result.finalWire, null, 2) + '\n', 'utf8')
    }
    process.stdout.write(JSON.stringify({ ok: true, fixture: 'dsh-supervisor-closed-loop', ...result }) + '\n')
  } finally {
    await rm(directory, { recursive: true, force: true })
  }
}

main().catch(error => {
  process.stderr.write('dsh-supervisor closed-loop fixture failed: ' + String(error?.message || error) + '\n')
  process.exitCode = 1
})
