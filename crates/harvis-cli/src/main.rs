use anyhow::{bail, Context, Result};
use clap::{Parser, Subcommand};
use harvis_http::{serve_blocking, HttpConfig};
use harvis_integrations::agent_gateway::{agent_step, AgentStepOptions};
use harvis_integrations::agent_harnesses::build_agent_harness_status;
use harvis_integrations::codex_billing::read_codex_home_billing;
use harvis_integrations::codex_homes::{
    discover_codex_homes, launch_codex_cli, launch_codex_desktop, login_codex_home,
    resume_codex_cli,
};
use harvis_integrations::codex_threads::{
    archive_automation_threads, list_codex_threads, read_codex_home_quota, CodexArchiveOptions,
};
use harvis_integrations::hub::{
    hub_path_lookup, hub_status, llmwiki_status, wiki_page, wiki_search,
};
use harvis_integrations::hypermemory::{
    check_surfaces, push_memory_snapshot, push_run_lesson, HyperMemoryPushOptions,
    PushMemorySnapshotOptions, PushRunLessonOptions,
};
use harvis_integrations::repoatlas::{
    repoatlas_find_repo, repoatlas_missing_local_copies, repoatlas_needs_attention,
    repoatlas_status,
};
use harvis_integrations::router::{route_message, RouteMessageOptions};
use harvis_macos::service_manager as macos_service;
use harvis_runtime::agent_pools::{
    agent_pools_status, init_agent_pools, select_runtime_route, AgentPoolsOptions,
    RuntimeSelectionOptions, ALLOW_FIXTURE_POOLS_ENV,
};
use harvis_runtime::agent_room::{
    add_event, add_message, consume_mailbox_loop, create_mailbox_item, create_task, create_topic,
    finalize_handoff_review, init_agent_room, link_task, list_agent_room, list_conversations,
    list_handoffs, list_mailbox, list_participants, list_tasks, mark_mailbox_read, request_handoff,
    task_plan, update_handoff_status, update_participant_status, update_task_status,
    upsert_participant, wake_mailbox_item, workspace_state, HandoffReviewInput, HandoffStatusInput,
    MailboxInput, ParticipantInput, TaskInput, TaskLinkInput,
};
use harvis_runtime::agent_roster::{
    agent_roster_status, validate_agent_roster, AgentRoster, RosterValidationOptions,
};
use harvis_runtime::approvals::{create_approval, decide_approval, list_approvals};
use harvis_runtime::chair::{chair_step, ChairStepOptions};
use harvis_runtime::decisions::verify_decision_chain;
use harvis_runtime::inbox::{scan_inboxes, ScanOptions};
use harvis_runtime::init::init_workspace;
use harvis_runtime::knowledge_graph::{scan_knowledge_graph, KnowledgeGraphOptions};
use harvis_runtime::memory::{generate_snapshot, list_memory_candidates, MemorySnapshotOptions};
use harvis_runtime::notifications::{check_notifications, list_notifications};
use harvis_runtime::persona::{
    create_memory_vault, create_persona_card, create_personality_candidate, create_twin_instance,
    decide_personality_candidate, init_persona_registry, list_persona_state, update_persona_card,
};
use harvis_runtime::profile::init_profile;
use harvis_runtime::projects::{
    discover_projects, list_projects, ProjectDiscoverOptions, ProjectListOptions,
};
use harvis_runtime::runs::{list_runs, resolve_packet_path, sync_packet_runs};
use harvis_runtime::tick::{run_tick, TickOptions};
use harvis_runtime::workbench::{prepare_workbench, WorkbenchOptions};
use serde::Serialize;
use serde_json::{json, Value};
use std::fs;
use std::io::{ErrorKind, Read, Write};
use std::net::TcpStream;
use std::path::{Path, PathBuf};
use std::thread;
use std::time::Duration;

mod dsh_web;
mod healthcheck;
mod ui_healthcheck;

const RUST_FOUNDATION_VERSION: &str = "v0.33-rust-foundation";

#[derive(Debug, Parser)]
#[command(name = "harvis")]
#[command(about = "H.A.R.V.I.S. local runtime")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Debug, Subcommand)]
enum Command {
    /// Print the Rust runtime foundation version.
    Version,
    /// Inspect, catalog, start, or explicitly restart DeepSeek Harness Web services.
    DshWeb {
        #[command(subcommand)]
        command: DshWebCommand,
    },
    /// Print a minimal Rust runtime health payload.
    HealthcheckStub,
    /// Run the Rust runtime healthcheck gates.
    Healthcheck {
        #[arg(long, default_value = ".")]
        plugin_root: PathBuf,
    },
    /// Verify the frozen JSON contract used by Studio, Presence, Knowledge Graph, and HarvisBar.
    UiHealthcheck {
        #[arg(long, default_value = ".")]
        root: PathBuf,
        #[arg(long, default_value = "~/.harvis")]
        profile_root: PathBuf,
        #[arg(long, default_value = "127.0.0.1")]
        host: String,
        #[arg(long, default_value_t = 8765)]
        port: u16,
        #[arg(long, default_value = "~/.harvis/auth/http.token")]
        auth_token_file: Option<PathBuf>,
    },
    /// Scan an allowlisted local Obsidian-style vault into graph JSON.
    KnowledgeGraph {
        #[arg(long)]
        root: PathBuf,
        #[arg(long = "config")]
        config_path: Option<PathBuf>,
        #[arg(long)]
        vault: Option<PathBuf>,
        #[arg(long)]
        include_paths: bool,
        #[arg(long, default_value_t = 0)]
        max_files: usize,
        #[arg(long, default_value_t = 0)]
        max_nodes: usize,
    },
    /// Initialize a local H.A.R.V.I.S. file-trigger workspace.
    InitWorkspace {
        #[arg(long, default_value = ".")]
        root: PathBuf,
        #[arg(long)]
        force: bool,
    },
    /// Initialize a global H.A.R.V.I.S. runtime profile.
    InitProfile {
        #[arg(long, default_value = "~/.harvis")]
        profile_root: PathBuf,
        #[arg(long)]
        force: bool,
    },
    /// Scan .harvis inbox files and generate work packets.
    ScanInbox {
        inboxes: Vec<PathBuf>,
        #[arg(long, default_value = ".")]
        root: PathBuf,
        #[arg(long)]
        allow_outside_root: bool,
    },
    /// Sync .harvis/outbox packets into stable run records.
    SyncRuns {
        #[arg(long, default_value = ".")]
        root: PathBuf,
        #[arg(long = "packet")]
        packets: Vec<PathBuf>,
        #[arg(long, default_value_t = 500)]
        limit: usize,
    },
    /// List stable H.A.R.V.I.S. run records.
    Runs {
        #[arg(long, default_value = ".")]
        root: PathBuf,
        #[arg(long, default_value_t = 50)]
        limit: usize,
    },
    /// Run H.A.R.V.I.S. read-only runtime ticks.
    RunTick {
        #[arg(long, default_value = ".")]
        root: PathBuf,
        #[arg(long)]
        once: bool,
        #[arg(long = "loop")]
        loop_mode: bool,
        #[arg(long)]
        interval: Option<u64>,
        #[arg(long)]
        max_ticks: Option<usize>,
        #[arg(long, default_value = "~/.harvis")]
        profile_root: PathBuf,
    },
    /// Generate a private memory snapshot and candidate Digital-Me signals.
    MemorySnapshot {
        #[arg(long, default_value = ".")]
        root: PathBuf,
        #[arg(long, default_value = "~/.harvis")]
        profile_root: PathBuf,
        #[arg(long, default_value_t = 50)]
        max_events: usize,
        #[arg(long, default_value_t = 50)]
        max_packets: usize,
        #[arg(long, default_value_t = 10)]
        max_reports: usize,
        #[arg(long, default_value_t = 1200)]
        max_excerpt_chars: usize,
    },
    /// List memory candidates distilled from the latest snapshot.
    MemoryCandidates {
        #[arg(long, default_value = ".")]
        root: PathBuf,
        #[arg(long, default_value_t = 50)]
        limit: usize,
    },
    /// Prepare Planner / Executor / Reviewer workbench briefs for packets.
    PrepareWorkbench {
        #[arg(long, default_value = ".")]
        root: PathBuf,
        #[arg(long, default_value = "~/.harvis")]
        profile_root: PathBuf,
        #[arg(long)]
        packet: Option<String>,
        #[arg(long, default_value_t = 5)]
        limit: usize,
    },
    /// Probe foreground workspace/profile write access without touching source files.
    PermissionProbe {
        #[arg(long, default_value = ".")]
        root: PathBuf,
        #[arg(long, default_value = "~/.harvis")]
        profile_root: PathBuf,
        #[arg(long, default_value = "rust-cli")]
        context: String,
    },
    /// Query redacted HarzvaHub and local wiki surfaces.
    Hub {
        #[command(subcommand)]
        command: HubCommand,
    },
    /// Query redacted RepoAtlas compact map surfaces.
    Repoatlas {
        #[command(subcommand)]
        command: RepoatlasCommand,
    },
    /// Push review-gated H.A.R.V.I.S. run/snapshot outcomes into HyperMemory.
    Hypermemory {
        #[command(subcommand)]
        command: HyperMemoryCommand,
    },
    /// Inspect safe local agent harness preflight status.
    AgentHarnesses {
        #[arg(long)]
        test: bool,
        #[arg(long, default_value_t = 120)]
        timeout_seconds: usize,
    },
    /// Route a transport message through H.A.R.V.I.S. intent and pool selection.
    RouteMessage {
        #[arg(long, default_value = ".")]
        root: PathBuf,
        #[arg(long, default_value = "manual")]
        transport: String,
        #[arg(long, default_value = "local")]
        sender: String,
        #[arg(long)]
        text: String,
        #[arg(long)]
        chat_id: Option<String>,
        #[arg(long)]
        message_id: Option<String>,
        #[arg(long = "context")]
        context: Vec<String>,
        #[arg(long, default_value_t = true)]
        include_paths: bool,
        #[arg(long)]
        map_path: Option<PathBuf>,
        #[arg(long)]
        agent_pools: Option<PathBuf>,
        /// Allow falling back to the bundled sample agent-pools fixture for
        /// this run (equivalent to HARVIS_ALLOW_FIXTURE_POOLS=1).
        #[arg(long)]
        allow_fixture_pools: bool,
    },
    /// Run one unified H.A.R.V.I.S. agent gateway step for CLI, Feishu, WeChat, or WebView.
    Agent {
        #[arg(long, default_value = ".", global = true)]
        root: PathBuf,
        #[command(subcommand)]
        command: AgentCommand,
    },
    /// Discover and list local projects known to H.A.R.V.I.S.
    Projects {
        #[arg(long, default_value = ".", global = true)]
        root: PathBuf,
        #[command(subcommand)]
        command: ProjectsCommand,
    },
    /// Inspect and initialize Harness / Model / Route pools.
    AgentPools {
        #[arg(long, default_value = ".", global = true)]
        root: PathBuf,
        #[arg(long = "agent-pools", global = true)]
        agent_pools_path: Option<PathBuf>,
        /// Allow falling back to the bundled sample agent-pools fixture for
        /// this run (equivalent to HARVIS_ALLOW_FIXTURE_POOLS=1).
        #[arg(long, global = true)]
        allow_fixture_pools: bool,
        #[command(subcommand)]
        command: AgentPoolsCommand,
    },
    /// Request a record-only approval item for a run.
    RequestApproval {
        #[arg(long, default_value = ".")]
        root: PathBuf,
        #[arg(long)]
        run_id: String,
        #[arg(long)]
        action_type: String,
        #[arg(long)]
        target: String,
        #[arg(long)]
        reason: String,
        #[arg(long, default_value = "medium")]
        risk: String,
        #[arg(long, default_value = "one_time")]
        scope: String,
    },
    /// Decide a pending approval item.
    DecideApproval {
        #[arg(long, default_value = ".")]
        root: PathBuf,
        #[arg(long)]
        approval_id: String,
        #[arg(long)]
        decision: String,
        #[arg(long, default_value = "human")]
        decided_by: String,
        #[arg(long, default_value = "")]
        notes: String,
    },
    /// List approval items.
    Approvals {
        #[arg(long, default_value = ".")]
        root: PathBuf,
        #[arg(long)]
        status: Option<String>,
        #[arg(long, default_value_t = 50)]
        limit: usize,
    },
    /// Inspect and verify immutable Agent Room decision record snapshots.
    Decisions {
        #[arg(long, default_value = ".", global = true)]
        root: PathBuf,
        #[command(subcommand)]
        command: DecisionsCommand,
    },
    /// Manage Agent Room topics, messages, and handoffs.
    AgentRoom {
        #[arg(long, default_value = ".", global = true)]
        root: PathBuf,
        #[command(subcommand)]
        command: AgentRoomCommand,
    },
    /// Run the review-gated H.A.R.V.I.S. Chair orchestrator.
    Chair {
        #[arg(long, default_value = ".", global = true)]
        root: PathBuf,
        #[command(subcommand)]
        command: ChairCommand,
    },
    /// Inspect and validate the canonical H.A.R.V.I.S. agent roster.
    AgentRoster {
        #[arg(long, default_value = ".", global = true)]
        root: PathBuf,
        #[arg(long = "roster", global = true)]
        roster_path: Option<PathBuf>,
        #[arg(long = "provider-registry", global = true)]
        provider_registry: Option<PathBuf>,
        #[arg(long = "agent-pools", global = true)]
        agent_pools: Option<PathBuf>,
        #[arg(long = "lark-config", global = true)]
        lark_config: Option<PathBuf>,
        #[command(subcommand)]
        command: AgentRosterCommand,
    },
    /// Manage persona registry and Copy-Me records.
    Persona {
        #[arg(long, default_value = ".", global = true)]
        root: PathBuf,
        #[command(subcommand)]
        command: PersonaCommand,
    },
    /// Manage H.A.R.V.I.S. notification candidates.
    Notifications {
        #[arg(long, default_value = ".", global = true)]
        root: PathBuf,
        #[command(subcommand)]
        command: NotificationCommand,
    },
    /// Manage explicit, reversible Codex thread cleanup actions.
    Codex {
        #[command(subcommand)]
        command: CodexCommand,
    },
    /// Manage H.A.R.V.I.S. macOS LaunchAgent services.
    ServiceManager {
        #[command(subcommand)]
        command: ServiceManagerCommand,
        #[arg(long, default_value = "http", global = true)]
        service: String,
        #[arg(long, default_value_t = macos_service::DEFAULT_PORT, global = true)]
        port: u16,
        #[arg(long, default_value = ".", global = true)]
        root: PathBuf,
        #[arg(long, default_value = "~/.harvis", global = true)]
        profile_root: PathBuf,
        #[arg(long, default_value_t = macos_service::DEFAULT_INTERVAL, global = true)]
        interval: u64,
        #[arg(long, default_value = ".", global = true)]
        plugin_root: PathBuf,
        #[arg(long, global = true)]
        auth_token_file: Option<PathBuf>,
        #[arg(long, global = true)]
        ensure_token_file: bool,
    },
    /// Run the H.A.R.V.I.S. Rust stdio MCP server.
    Mcp,
    /// Run the H.A.R.V.I.S. localhost Rust HTTP API.
    Http {
        #[arg(long, default_value = "127.0.0.1")]
        host: String,
        #[arg(long, default_value_t = 8765)]
        port: u16,
        #[arg(long)]
        auth_token: Option<String>,
        #[arg(long)]
        auth_token_file: Option<PathBuf>,
        #[arg(long, default_value = ".")]
        plugin_root: PathBuf,
        /// Trusted workspace exposed to localhost UI bootstrap. This value is
        /// never accepted from a browser URL.
        #[arg(long, default_value = ".")]
        root: PathBuf,
    },
}

#[derive(Debug, Subcommand)]
enum DshWebCommand {
    /// Show all running DSH profile processes and listening ports.
    Status,
    /// Show active DSH endpoints without reading runtime or Profile metadata.
    Running,
    /// Discover local DSH runtimes, homes, Profiles, and declared plugins.
    Catalog,
    /// Start one cataloged Web Profile on an explicit or dynamic port.
    Start {
        /// Exact DSH_HOME returned by `dsh-web catalog`.
        #[arg(long)]
        home: PathBuf,
        /// Exact Profile name registered under the selected DSH_HOME.
        #[arg(long, default_value = "web")]
        profile: String,
        /// Listening port; 0 asks DSH to choose a free port.
        #[arg(long, default_value_t = 0)]
        port: u16,
    },
    /// Gracefully restart all or one explicitly identified DSH profile instance.
    Restart {
        /// Restart only the DSH profile instance listening on this port.
        #[arg(long)]
        port: Option<u16>,
    },
}

#[derive(Debug, Subcommand)]
enum AgentRoomCommand {
    Init,
    TaskPlan,
    Participants {
        #[arg(long)]
        topic_id: Option<String>,
    },
    Participant {
        #[command(subcommand)]
        command: ParticipantCommand,
    },
    Topic {
        #[arg(long)]
        title: String,
        #[arg(long, default_value = "")]
        goal: String,
        #[arg(long, default_value = "harvis")]
        created_by: String,
    },
    Event {
        #[arg(long)]
        topic_id: String,
        #[arg(long, default_value = "harvis")]
        agent_id: String,
        #[arg(long, default_value = "coordinator")]
        role: String,
        #[arg(long, default_value = "note")]
        event_type: String,
        #[arg(long, default_value = "")]
        content: String,
    },
    Message {
        #[arg(long)]
        topic_id: String,
        #[arg(long, default_value = "harvis")]
        agent_id: String,
        #[arg(long, default_value = "coordinator")]
        role: String,
        #[arg(long)]
        content: String,
    },
    Handoff {
        #[arg(long)]
        run_id: String,
        #[arg(long)]
        harness: String,
        #[arg(long, default_value = "")]
        instruction: String,
        #[arg(long)]
        topic_id: Option<String>,
        #[arg(long, default_value = "harvis")]
        requested_by: String,
    },
    HandoffStatus {
        #[arg(long)]
        handoff_id: String,
        #[arg(long)]
        state: String,
        #[arg(long, default_value = "")]
        summary: String,
        #[arg(long, default_value = "harvis")]
        updated_by: String,
        #[arg(long)]
        result_path: Option<String>,
        #[arg(long)]
        exit_code: Option<i64>,
    },
    HandoffReview {
        #[arg(long)]
        handoff_id: String,
        #[arg(long)]
        decision: String,
        #[arg(long, default_value = "reviewer")]
        reviewer: String,
        #[arg(long, default_value = "")]
        notes: String,
    },
    List {
        #[arg(long, default_value_t = 50)]
        limit: usize,
    },
    Handoffs {
        #[arg(long, default_value_t = 50)]
        limit: usize,
    },
    Mailbox {
        #[command(subcommand)]
        command: MailboxCommand,
    },
    Task {
        #[command(subcommand)]
        command: TaskCommand,
    },
    Conversations {
        #[arg(long)]
        transport: Option<String>,
        #[arg(long)]
        chat_id: Option<String>,
        #[arg(long)]
        sender: Option<String>,
        #[arg(long, default_value_t = 50)]
        limit: usize,
    },
    WorkspaceState {
        #[arg(long)]
        topic_id: Option<String>,
        #[arg(long, default_value_t = 50)]
        limit: usize,
    },
}

#[derive(Debug, Subcommand)]
enum DecisionsCommand {
    /// Verify every decision snapshot's content hash and the prev_hash chain.
    Verify,
}

#[derive(Debug, Subcommand)]
enum AgentCommand {
    Step {
        #[arg(long, default_value = "manual")]
        channel: String,
        #[arg(long, default_value = "local")]
        sender: String,
        #[arg(long)]
        message: String,
        #[arg(long)]
        chat_id: Option<String>,
        #[arg(long)]
        message_id: Option<String>,
        #[arg(long = "context")]
        context: Vec<String>,
        #[arg(long, default_value_t = true)]
        include_paths: bool,
        #[arg(long)]
        map_path: Option<PathBuf>,
        #[arg(long)]
        agent_pools: Option<PathBuf>,
        #[arg(long)]
        topic_id: Option<String>,
        #[arg(long, default_value_t = true)]
        chair_dry_run: bool,
    },
}

#[derive(Debug, Subcommand)]
enum ProjectsCommand {
    List {
        #[arg(long)]
        query: Option<String>,
    },
    Discover {
        #[arg(long)]
        query: Option<String>,
        #[arg(long)]
        write: bool,
    },
}

#[derive(Debug, Subcommand)]
enum AgentPoolsCommand {
    Status {
        #[arg(long)]
        query: Option<String>,
    },
    Select {
        #[arg(long)]
        text: String,
        #[arg(long)]
        owner_slot_id: Option<String>,
    },
    Init {
        #[arg(long)]
        force: bool,
    },
}

#[derive(Debug, Subcommand)]
enum ChairCommand {
    Step {
        #[arg(long, default_value_t = true, action = clap::ArgAction::Set)]
        dry_run: bool,
        #[arg(long)]
        topic_id: Option<String>,
    },
}

#[derive(Debug, Subcommand)]
enum ParticipantCommand {
    Add {
        #[arg(long)]
        slot_id: String,
        #[arg(long)]
        role: String,
        #[arg(long)]
        display_name: String,
        #[arg(long)]
        provider: Option<String>,
        #[arg(long)]
        model: Option<String>,
        #[arg(long)]
        harness: Option<String>,
        #[arg(long)]
        route: Option<String>,
        #[arg(long, default_value = "record_only")]
        execution_mode: String,
        #[arg(long, default_value = "idle")]
        status: String,
    },
    Status {
        #[arg(long)]
        slot_id: String,
        #[arg(long)]
        status: String,
    },
}

#[derive(Debug, Subcommand)]
enum MailboxCommand {
    List {
        #[arg(long)]
        topic_id: Option<String>,
        #[arg(long)]
        status: Option<String>,
        #[arg(long, default_value_t = 50)]
        limit: usize,
    },
    Create {
        #[arg(long)]
        from_slot_id: String,
        #[arg(long)]
        to_slot_id: String,
        #[arg(long, default_value = "request")]
        kind: String,
        #[arg(long, default_value = "")]
        subject: String,
        #[arg(long, default_value = "")]
        content: String,
        #[arg(long)]
        topic_id: Option<String>,
        #[arg(long)]
        source_event_id: Option<String>,
        #[arg(long)]
        task_id: Option<String>,
    },
    MarkRead {
        #[arg(long)]
        mail_id: String,
        #[arg(long, default_value = "human")]
        read_by: String,
    },
    Wake {
        #[arg(long)]
        mail_id: String,
        #[arg(long, default_value = "harvis-chair")]
        consumer_slot_id: String,
        #[arg(long, default_value = "manual_wake")]
        reason: String,
    },
    Consume {
        #[arg(long, default_value = "harvis-chair")]
        consumer_slot_id: String,
        #[arg(long)]
        topic_id: Option<String>,
        #[arg(long, default_value_t = 10)]
        limit: usize,
        #[arg(long, default_value_t = 1)]
        max_batches: usize,
        #[arg(long, default_value_t = false)]
        dry_run: bool,
    },
}

#[derive(Debug, Subcommand)]
enum TaskCommand {
    List {
        #[arg(long)]
        topic_id: Option<String>,
        #[arg(long)]
        status: Option<String>,
        #[arg(long, default_value_t = 50)]
        limit: usize,
    },
    Create {
        #[arg(long)]
        title: String,
        #[arg(long, default_value = "harvis-chair")]
        owner_slot_id: String,
        #[arg(long)]
        topic_id: Option<String>,
        #[arg(long, default_value = "pending")]
        status: String,
        #[arg(long)]
        source_event_id: Option<String>,
        #[arg(long)]
        approval_id: Option<String>,
        #[arg(long)]
        handoff_id: Option<String>,
        #[arg(long)]
        run_id: Option<String>,
        #[arg(long)]
        packet_id: Option<String>,
        #[arg(long)]
        description: Option<String>,
    },
    Status {
        #[arg(long)]
        task_id: String,
        #[arg(long)]
        status: String,
        #[arg(long, default_value = "")]
        note: String,
    },
    Link {
        #[arg(long)]
        task_id: String,
        #[arg(long)]
        approval_id: Option<String>,
        #[arg(long)]
        handoff_id: Option<String>,
        #[arg(long)]
        run_id: Option<String>,
        #[arg(long)]
        packet_id: Option<String>,
        #[arg(long)]
        status: Option<String>,
        #[arg(long)]
        note: Option<String>,
    },
}

#[derive(Debug, Subcommand)]
enum AgentRosterCommand {
    List,
    Validate,
}

#[derive(Debug, Subcommand)]
enum PersonaCommand {
    Init,
    List {
        #[arg(long, default_value_t = 100)]
        limit: usize,
    },
    CreateVault {
        #[arg(long)]
        display_name: String,
        #[arg(long)]
        vault_id: Option<String>,
        #[arg(long, default_value = "harzva")]
        owner: String,
    },
    CreateCard {
        #[arg(long)]
        display_name: String,
        #[arg(long)]
        persona_id: Option<String>,
        #[arg(long, default_value = "")]
        visual_asset_id: String,
    },
    UpdateCard {
        #[arg(long)]
        persona_id: String,
        #[arg(long)]
        display_name: Option<String>,
        #[arg(long)]
        visual_asset_id: Option<String>,
        #[arg(long)]
        base_template: Option<String>,
        #[arg(long)]
        status: Option<String>,
        #[arg(long)]
        behavior_rule: Vec<String>,
        #[arg(long, default_value_t = -1)]
        warmth: i32,
        #[arg(long, default_value_t = -1)]
        directness: i32,
        #[arg(long, default_value_t = -1)]
        humor: i32,
        #[arg(long, default_value_t = -1)]
        detail: i32,
    },
    CreateTwin {
        #[arg(long)]
        display_name: String,
        #[arg(long)]
        memory_vault_id: String,
        #[arg(long)]
        persona_card_id: String,
        #[arg(long)]
        instance_id: Option<String>,
    },
    CreateCandidate {
        #[arg(long)]
        trait_text: String,
        #[arg(long)]
        target_persona_id: String,
        #[arg(long, default_value = "manual")]
        source_type: String,
        #[arg(long, default_value = "decision_style")]
        trait_type: String,
        #[arg(long, default_value_t = 0.5)]
        confidence: f64,
    },
    DecideCandidate {
        #[arg(long)]
        candidate_id: String,
        #[arg(long)]
        decision: String,
        #[arg(long, default_value = "human")]
        decided_by: String,
        #[arg(long, default_value = "")]
        notes: String,
        #[arg(long, default_value = "")]
        edited_trait: String,
    },
}

#[derive(Debug, Subcommand)]
enum NotificationCommand {
    Check {
        #[arg(long, default_value_t = true, action = clap::ArgAction::Set)]
        write: bool,
    },
    List {
        #[arg(long)]
        kind: Option<String>,
        #[arg(long, default_value_t = 50)]
        limit: usize,
    },
}

#[derive(Debug, Subcommand)]
enum HubCommand {
    Status,
    Path {
        query: String,
        #[arg(long, default_value_t = 10)]
        limit: usize,
    },
    Search {
        query: String,
        #[arg(long, default_value_t = 10)]
        limit: usize,
        #[arg(long, default_value_t = 360)]
        max_excerpt_chars: usize,
    },
    Page {
        page: String,
        #[arg(long, default_value_t = 3000)]
        max_chars: usize,
    },
    LlmwikiStatus,
}

#[derive(Debug, Subcommand)]
enum RepoatlasCommand {
    Status {
        #[arg(long = "map")]
        map_path: Option<String>,
        #[arg(long)]
        include_paths: bool,
    },
    Find {
        query: String,
        #[arg(long, default_value_t = 10)]
        limit: usize,
        #[arg(long = "map")]
        map_path: Option<String>,
        #[arg(long)]
        include_paths: bool,
    },
    Missing {
        #[arg(long, default_value_t = 50)]
        limit: usize,
        #[arg(long = "map")]
        map_path: Option<String>,
    },
    Attention {
        #[arg(long, default_value_t = 50)]
        limit: usize,
        #[arg(long = "map")]
        map_path: Option<String>,
        #[arg(long)]
        include_paths: bool,
    },
}

#[derive(Debug, Subcommand)]
enum HyperMemoryCommand {
    /// Check HyperMemory Hindsight/Policy surfaces without approving or executing anything.
    Check {
        #[arg(long, default_value = ".")]
        root: PathBuf,
        #[arg(long)]
        base_url: Option<String>,
        #[arg(long)]
        api_token: Option<String>,
        #[arg(long)]
        api_token_file: Option<PathBuf>,
        #[arg(long, default_value = "default")]
        tenant_id: String,
        #[arg(long, default_value_t = true, action = clap::ArgAction::Set)]
        dry_run: bool,
        #[arg(long, default_value_t = 15)]
        timeout_seconds: u64,
    },
    /// Create a HyperMemory DRAFT Hindsight lesson candidate from a Harvis run.
    PushRun {
        #[arg(long, default_value = ".")]
        root: PathBuf,
        #[arg(long)]
        run_id: String,
        #[arg(long)]
        base_url: Option<String>,
        #[arg(long)]
        api_token: Option<String>,
        #[arg(long)]
        api_token_file: Option<PathBuf>,
        #[arg(long, default_value = "default")]
        tenant_id: String,
        #[arg(long, default_value_t = true, action = clap::ArgAction::Set)]
        dry_run: bool,
        #[arg(long, default_value_t = 15)]
        timeout_seconds: u64,
    },
    /// Create a HyperMemory DRAFT Hindsight lesson candidate from a Harvis memory snapshot/signals report.
    PushMemorySnapshot {
        #[arg(long, default_value = ".")]
        root: PathBuf,
        #[arg(long)]
        snapshot: Option<PathBuf>,
        #[arg(long)]
        signals: Option<PathBuf>,
        #[arg(long)]
        base_url: Option<String>,
        #[arg(long)]
        api_token: Option<String>,
        #[arg(long)]
        api_token_file: Option<PathBuf>,
        #[arg(long, default_value = "default")]
        tenant_id: String,
        #[arg(long, default_value_t = true, action = clap::ArgAction::Set)]
        dry_run: bool,
        #[arg(long, default_value_t = 15)]
        timeout_seconds: u64,
    },
}

#[derive(Debug, Subcommand)]
enum ServiceManagerCommand {
    Plist,
    Install,
    Start,
    Stop,
    Restart,
    Status,
    Logs,
    Uninstall,
    Probe {
        #[arg(long)]
        via_http: bool,
    },
}

#[derive(Debug, Subcommand)]
enum CodexCommand {
    /// Discover local CODEX_HOME directories without returning credential values.
    Homes,
    /// List local Codex threads for one selected CODEX_HOME.
    Chats {
        #[arg(long)]
        home: PathBuf,
        #[arg(long, default_value_t = 100)]
        limit: usize,
    },
    /// Read the official ChatGPT quota for one selected CODEX_HOME.
    Quota {
        #[arg(long)]
        home: PathBuf,
    },
    /// Explicitly refresh configured provider balances for one selected CODEX_HOME.
    Billing {
        #[arg(long)]
        home: PathBuf,
    },
    /// Open the Codex login flow for one selected CODEX_HOME.
    Login {
        #[arg(long)]
        home: PathBuf,
    },
    /// Open an interactive Codex CLI using one selected CODEX_HOME.
    LaunchCli {
        #[arg(long)]
        home: PathBuf,
        #[arg(long, default_value = ".")]
        cwd: PathBuf,
    },
    /// Resume one exact Codex session in an interactive CLI under one selected CODEX_HOME.
    ResumeCli {
        #[arg(long)]
        home: PathBuf,
        #[arg(long)]
        cwd: PathBuf,
        #[arg(long)]
        thread_id: String,
    },
    /// Open an independent Codex Desktop window using one selected CODEX_HOME.
    LaunchDesktop {
        #[arg(long)]
        home: PathBuf,
    },
    /// Archive non-archived threads whose title matches a local automation.
    ArchiveAutomationThreads {
        /// Report strict matches without archiving anything.
        #[arg(long)]
        dry_run: bool,
    },
}

#[derive(Debug, Serialize)]
struct HealthcheckStub {
    ok: bool,
    runtime: &'static str,
    autonomy_level: u8,
    version: &'static str,
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    match cli.command {
        Command::Version => println!("{RUST_FOUNDATION_VERSION}"),
        Command::DshWeb { command } => {
            let response = match command {
                DshWebCommand::Status => dsh_web::status()?,
                DshWebCommand::Running => dsh_web::running()?,
                DshWebCommand::Catalog => dsh_web::catalog()?,
                DshWebCommand::Start {
                    home,
                    profile,
                    port,
                } => dsh_web::start(&home, &profile, port)?,
                DshWebCommand::Restart { port } => dsh_web::restart(port)?,
            };
            println!("{}", serde_json::to_string_pretty(&response)?);
        }
        Command::HealthcheckStub => {
            let payload = HealthcheckStub {
                ok: true,
                runtime: "rust",
                autonomy_level: 1,
                version: RUST_FOUNDATION_VERSION,
            };
            println!("{}", serde_json::to_string_pretty(&payload)?);
        }
        Command::Healthcheck { plugin_root } => {
            healthcheck::run(plugin_root)?;
        }
        Command::UiHealthcheck {
            root,
            profile_root,
            host,
            port,
            auth_token_file,
        } => {
            ui_healthcheck::run(ui_healthcheck::UiHealthcheckConfig {
                root,
                profile_root,
                host,
                port,
                auth_token_file,
            })?;
        }
        Command::KnowledgeGraph {
            root,
            config_path,
            vault,
            include_paths,
            max_files,
            max_nodes,
        } => {
            let graph = scan_knowledge_graph(KnowledgeGraphOptions {
                root,
                config_path,
                vault_override: vault,
                include_paths_override: include_paths.then_some(true),
                max_files_override: (max_files > 0).then_some(max_files),
                max_nodes_override: (max_nodes > 0).then_some(max_nodes),
            })?;
            println!("{}", serde_json::to_string_pretty(&graph)?);
        }
        Command::InitWorkspace { root, force } => {
            for message in init_workspace(&root, force)? {
                println!("{message}");
            }
        }
        Command::InitProfile {
            profile_root,
            force,
        } => {
            for message in init_profile(&profile_root, force)? {
                println!("{message}");
            }
        }
        Command::ScanInbox {
            inboxes,
            root,
            allow_outside_root,
        } => {
            let written = scan_inboxes(ScanOptions {
                root,
                inboxes,
                allow_outside_root,
            })?;
            if written.is_empty() {
                println!("No @harvis tasks found.");
            } else {
                for path in written {
                    println!("wrote: {}", path.display());
                }
            }
        }
        Command::SyncRuns {
            root,
            packets,
            limit,
        } => {
            let resolved_packets = if packets.is_empty() {
                None
            } else {
                let mut resolved = Vec::new();
                for packet in packets {
                    resolved.push(resolve_packet_path(&root, &packet)?);
                }
                Some(resolved)
            };
            let response = sync_packet_runs(&root, resolved_packets, limit)?;
            println!("{}", serde_json::to_string_pretty(&response)?);
        }
        Command::Runs { root, limit } => {
            let response = list_runs(&root, limit)?;
            println!("{}", serde_json::to_string_pretty(&response)?);
        }
        Command::RunTick {
            root,
            once: _,
            loop_mode,
            interval,
            max_ticks,
            profile_root,
        } => {
            if !loop_mode {
                run_one_tick(root, interval, profile_root)?;
            } else {
                let mut ticks = 0usize;
                loop {
                    let tick_interval = run_one_tick(root.clone(), interval, profile_root.clone())?;
                    ticks += 1;
                    if max_ticks.is_some_and(|max| ticks >= max) {
                        break;
                    }
                    thread::sleep(Duration::from_secs(tick_interval));
                }
            }
        }
        Command::MemorySnapshot {
            root,
            profile_root,
            max_events,
            max_packets,
            max_reports,
            max_excerpt_chars,
        } => {
            let result = generate_snapshot(MemorySnapshotOptions {
                root,
                profile_root,
                max_events,
                max_packets,
                max_reports,
                max_excerpt_chars,
            })?;
            println!("wrote snapshot: {}", result.snapshot_path);
            println!("wrote signals: {}", result.signals_path);
            println!("wrote index: {}", result.index_path);
            println!("candidate signals: {}", result.candidate_signal_count);
            if !result.warnings.is_empty() {
                println!("warnings: {}", result.warnings.len());
            }
        }
        Command::MemoryCandidates { root, limit } => {
            let response = list_memory_candidates(&root, limit)?;
            println!("{}", serde_json::to_string_pretty(&response)?);
        }
        Command::PrepareWorkbench {
            root,
            profile_root,
            packet,
            limit,
        } => {
            let response = prepare_workbench(WorkbenchOptions {
                root,
                profile_root,
                packet,
                limit,
            })?;
            println!("{}", serde_json::to_string_pretty(&response)?);
        }
        Command::PermissionProbe {
            root,
            profile_root,
            context,
        } => {
            let response = permission_probe_data(&root, &profile_root, &context);
            println!("{}", serde_json::to_string_pretty(&response)?);
        }
        Command::Hub { command } => {
            let response = match command {
                HubCommand::Status => hub_status(),
                HubCommand::Path { query, limit } => hub_path_lookup(&query, limit)?,
                HubCommand::Search {
                    query,
                    limit,
                    max_excerpt_chars,
                } => wiki_search(&query, limit, max_excerpt_chars)?,
                HubCommand::Page { page, max_chars } => wiki_page(&page, max_chars)?,
                HubCommand::LlmwikiStatus => llmwiki_status(),
            };
            println!("{}", serde_json::to_string_pretty(&response)?);
        }
        Command::Repoatlas { command } => {
            let response = match command {
                RepoatlasCommand::Status {
                    map_path,
                    include_paths,
                } => repoatlas_status(map_path.as_deref(), include_paths),
                RepoatlasCommand::Find {
                    query,
                    limit,
                    map_path,
                    include_paths,
                } => repoatlas_find_repo(&query, limit, map_path.as_deref(), include_paths)?,
                RepoatlasCommand::Missing { limit, map_path } => {
                    repoatlas_missing_local_copies(limit, map_path.as_deref())
                }
                RepoatlasCommand::Attention {
                    limit,
                    map_path,
                    include_paths,
                } => repoatlas_needs_attention(limit, map_path.as_deref(), include_paths),
            };
            println!("{}", serde_json::to_string_pretty(&response)?);
        }
        Command::Hypermemory { command } => {
            let response = match command {
                HyperMemoryCommand::Check {
                    root,
                    base_url,
                    api_token,
                    api_token_file,
                    tenant_id,
                    dry_run,
                    timeout_seconds,
                } => check_surfaces(HyperMemoryPushOptions {
                    root,
                    base_url,
                    api_token,
                    api_token_file,
                    tenant_id,
                    dry_run,
                    timeout_seconds,
                })?,
                HyperMemoryCommand::PushRun {
                    root,
                    run_id,
                    base_url,
                    api_token,
                    api_token_file,
                    tenant_id,
                    dry_run,
                    timeout_seconds,
                } => push_run_lesson(PushRunLessonOptions {
                    common: HyperMemoryPushOptions {
                        root,
                        base_url,
                        api_token,
                        api_token_file,
                        tenant_id,
                        dry_run,
                        timeout_seconds,
                    },
                    run_id,
                })?,
                HyperMemoryCommand::PushMemorySnapshot {
                    root,
                    snapshot,
                    signals,
                    base_url,
                    api_token,
                    api_token_file,
                    tenant_id,
                    dry_run,
                    timeout_seconds,
                } => push_memory_snapshot(PushMemorySnapshotOptions {
                    common: HyperMemoryPushOptions {
                        root,
                        base_url,
                        api_token,
                        api_token_file,
                        tenant_id,
                        dry_run,
                        timeout_seconds,
                    },
                    snapshot,
                    signals,
                })?,
            };
            println!("{}", serde_json::to_string_pretty(&response)?);
        }
        Command::AgentHarnesses {
            test,
            timeout_seconds,
        } => {
            let response = build_agent_harness_status(test, timeout_seconds);
            println!("{}", serde_json::to_string_pretty(&response)?);
        }
        Command::RouteMessage {
            root,
            transport,
            sender,
            text,
            chat_id,
            message_id,
            context,
            include_paths,
            map_path,
            agent_pools,
            allow_fixture_pools,
        } => {
            if allow_fixture_pools {
                std::env::set_var(ALLOW_FIXTURE_POOLS_ENV, "1");
            }
            let response = route_message(RouteMessageOptions {
                root,
                transport,
                sender,
                text,
                chat_id,
                message_id,
                context,
                include_paths,
                map_path,
                agent_pools_path: agent_pools,
            })?;
            println!("{}", serde_json::to_string_pretty(&response)?);
        }
        Command::Agent { root, command } => {
            let response = match command {
                AgentCommand::Step {
                    channel,
                    sender,
                    message,
                    chat_id,
                    message_id,
                    context,
                    include_paths,
                    map_path,
                    agent_pools,
                    topic_id,
                    chair_dry_run,
                } => agent_step(AgentStepOptions {
                    root,
                    channel,
                    sender,
                    message,
                    chat_id,
                    message_id,
                    context,
                    include_paths,
                    map_path,
                    agent_pools_path: agent_pools,
                    topic_id,
                    chair_dry_run,
                })?,
            };
            println!("{}", serde_json::to_string_pretty(&response)?);
        }
        Command::Projects { root, command } => {
            let response = match command {
                ProjectsCommand::List { query } => {
                    list_projects(ProjectListOptions { root, query })?
                }
                ProjectsCommand::Discover { query, write } => {
                    discover_projects(ProjectDiscoverOptions { root, query, write })?
                }
            };
            println!("{}", serde_json::to_string_pretty(&response)?);
        }
        Command::AgentPools {
            root,
            agent_pools_path,
            allow_fixture_pools,
            command,
        } => {
            if allow_fixture_pools {
                std::env::set_var(ALLOW_FIXTURE_POOLS_ENV, "1");
            }
            let response = match command {
                AgentPoolsCommand::Status { query } => agent_pools_status(AgentPoolsOptions {
                    root,
                    path: agent_pools_path,
                    query,
                })?,
                AgentPoolsCommand::Select {
                    text,
                    owner_slot_id,
                } => select_runtime_route(RuntimeSelectionOptions {
                    root,
                    path: agent_pools_path,
                    text,
                    selected_preset: None,
                    owner_slot_id,
                })?,
                AgentPoolsCommand::Init { force } => init_agent_pools(&root, force)?,
            };
            println!("{}", serde_json::to_string_pretty(&response)?);
        }
        Command::RequestApproval {
            root,
            run_id,
            action_type,
            target,
            reason,
            risk,
            scope,
        } => {
            let response = create_approval(
                &root,
                &run_id,
                &action_type,
                &target,
                &reason,
                &risk,
                &scope,
            )?;
            println!("{}", serde_json::to_string_pretty(&response)?);
        }
        Command::DecideApproval {
            root,
            approval_id,
            decision,
            decided_by,
            notes,
        } => {
            let response = decide_approval(&root, &approval_id, &decision, &decided_by, &notes)?;
            println!("{}", serde_json::to_string_pretty(&response)?);
        }
        Command::Approvals {
            root,
            status,
            limit,
        } => {
            let response = list_approvals(&root, status.as_deref(), limit)?;
            println!("{}", serde_json::to_string_pretty(&response)?);
        }
        Command::Decisions { root, command } => match command {
            DecisionsCommand::Verify => {
                let report = verify_decision_chain(&root)?;
                println!("{}", serde_json::to_string_pretty(&report)?);
                if report.get("ok").and_then(Value::as_bool) != Some(true) {
                    std::process::exit(1);
                }
            }
        },
        Command::AgentRoom { root, command } => {
            let response = match command {
                AgentRoomCommand::Init => init_agent_room(&root)?,
                AgentRoomCommand::TaskPlan => task_plan(&root)?,
                AgentRoomCommand::Participants { topic_id } => {
                    list_participants(&root, topic_id.as_deref())?
                }
                AgentRoomCommand::Participant { command } => match command {
                    ParticipantCommand::Add {
                        slot_id,
                        role,
                        display_name,
                        provider,
                        model,
                        harness,
                        route,
                        execution_mode,
                        status,
                    } => upsert_participant(
                        &root,
                        ParticipantInput {
                            slot_id,
                            role,
                            display_name,
                            provider_ref: provider,
                            model_ref: model,
                            harness_ref: harness,
                            route_ref: route,
                            execution_mode: Some(execution_mode),
                            status: Some(status),
                            permissions: None,
                        },
                    )?,
                    ParticipantCommand::Status { slot_id, status } => {
                        update_participant_status(&root, &slot_id, &status)?
                    }
                },
                AgentRoomCommand::Topic {
                    title,
                    goal,
                    created_by,
                } => create_topic(&root, &title, &goal, &created_by)?,
                AgentRoomCommand::Event {
                    topic_id,
                    agent_id,
                    role,
                    event_type,
                    content,
                } => add_event(
                    &root,
                    &topic_id,
                    &agent_id,
                    &role,
                    &event_type,
                    &content,
                    Vec::new(),
                    "internal",
                    None,
                )?,
                AgentRoomCommand::Message {
                    topic_id,
                    agent_id,
                    role,
                    content,
                } => add_message(
                    &root,
                    &topic_id,
                    &agent_id,
                    &role,
                    &content,
                    Vec::new(),
                    "internal",
                    None,
                )?,
                AgentRoomCommand::Handoff {
                    run_id,
                    harness,
                    instruction,
                    topic_id,
                    requested_by,
                } => request_handoff(
                    &root,
                    &run_id,
                    &harness,
                    &instruction,
                    topic_id.as_deref(),
                    &requested_by,
                )?,
                AgentRoomCommand::HandoffStatus {
                    handoff_id,
                    state,
                    summary,
                    updated_by,
                    result_path,
                    exit_code,
                } => update_handoff_status(
                    &root,
                    HandoffStatusInput {
                        handoff_id,
                        state,
                        summary: Some(summary),
                        updated_by: Some(updated_by),
                        result_path,
                        exit_code,
                        ..HandoffStatusInput::default()
                    },
                )?,
                AgentRoomCommand::HandoffReview {
                    handoff_id,
                    decision,
                    reviewer,
                    notes,
                } => finalize_handoff_review(
                    &root,
                    HandoffReviewInput {
                        handoff_id,
                        decision,
                        reviewer: Some(reviewer),
                        notes: Some(notes),
                    },
                )?,
                AgentRoomCommand::List { limit } => list_agent_room(&root, limit)?,
                AgentRoomCommand::Handoffs { limit } => list_handoffs(&root, limit)?,
                AgentRoomCommand::Mailbox { command } => match command {
                    MailboxCommand::List {
                        topic_id,
                        status,
                        limit,
                    } => list_mailbox(&root, topic_id.as_deref(), status.as_deref(), limit)?,
                    MailboxCommand::Create {
                        from_slot_id,
                        to_slot_id,
                        kind,
                        subject,
                        content,
                        topic_id,
                        source_event_id,
                        task_id,
                    } => create_mailbox_item(
                        &root,
                        MailboxInput {
                            topic_id,
                            from_slot_id,
                            to_slot_id,
                            kind,
                            subject,
                            content,
                            source_event_id,
                            task_id,
                        },
                    )?,
                    MailboxCommand::MarkRead { mail_id, read_by } => {
                        mark_mailbox_read(&root, &mail_id, &read_by)?
                    }
                    MailboxCommand::Wake {
                        mail_id,
                        consumer_slot_id,
                        reason,
                    } => wake_mailbox_item(&root, &mail_id, &consumer_slot_id, &reason)?,
                    MailboxCommand::Consume {
                        consumer_slot_id,
                        topic_id,
                        limit,
                        max_batches,
                        dry_run,
                    } => consume_mailbox_loop(
                        &root,
                        &consumer_slot_id,
                        topic_id.as_deref(),
                        limit,
                        max_batches,
                        dry_run,
                    )?,
                },
                AgentRoomCommand::Task { command } => match command {
                    TaskCommand::List {
                        topic_id,
                        status,
                        limit,
                    } => list_tasks(&root, topic_id.as_deref(), status.as_deref(), limit)?,
                    TaskCommand::Create {
                        title,
                        owner_slot_id,
                        topic_id,
                        status,
                        source_event_id,
                        approval_id,
                        handoff_id,
                        run_id,
                        packet_id,
                        description,
                    } => create_task(
                        &root,
                        TaskInput {
                            topic_id,
                            title,
                            owner_slot_id,
                            status: Some(status),
                            source_event_id,
                            approval_id,
                            handoff_id,
                            run_id,
                            packet_id,
                            description,
                            metadata: None,
                        },
                    )?,
                    TaskCommand::Status {
                        task_id,
                        status,
                        note,
                    } => update_task_status(&root, &task_id, &status, &note)?,
                    TaskCommand::Link {
                        task_id,
                        approval_id,
                        handoff_id,
                        run_id,
                        packet_id,
                        status,
                        note,
                    } => link_task(
                        &root,
                        TaskLinkInput {
                            task_id,
                            approval_id,
                            handoff_id,
                            run_id,
                            packet_id,
                            status,
                            note,
                        },
                    )?,
                },
                AgentRoomCommand::Conversations {
                    transport,
                    chat_id,
                    sender,
                    limit,
                } => list_conversations(
                    &root,
                    transport.as_deref(),
                    chat_id.as_deref(),
                    sender.as_deref(),
                    limit,
                )?,
                AgentRoomCommand::WorkspaceState { topic_id, limit } => {
                    workspace_state(&root, topic_id.as_deref(), limit)?
                }
            };
            println!("{}", serde_json::to_string_pretty(&response)?);
        }
        Command::Chair { root, command } => {
            let response = match command {
                ChairCommand::Step { dry_run, topic_id } => chair_step(ChairStepOptions {
                    root,
                    topic_id,
                    dry_run,
                })?,
            };
            println!("{}", serde_json::to_string_pretty(&response)?);
        }
        Command::AgentRoster {
            root,
            roster_path,
            provider_registry,
            agent_pools,
            lark_config,
            command,
        } => {
            let options = RosterValidationOptions {
                provider_registry,
                agent_pools,
                root: Some(root.clone()),
                lark_config,
            };
            let response = match command {
                AgentRosterCommand::List => {
                    agent_roster_status(&root, roster_path.as_deref(), options)?
                }
                AgentRosterCommand::Validate => {
                    let roster_path =
                        roster_path.unwrap_or_else(|| root.join(".harvis/agent-roster.json"));
                    let text = fs::read_to_string(&roster_path).with_context(|| {
                        format!("agent roster not found: {}", roster_path.display())
                    })?;
                    let roster: AgentRoster = serde_json::from_str(&text).with_context(|| {
                        format!("invalid agent roster json: {}", roster_path.display())
                    })?;
                    let validation = validate_agent_roster(&roster, options)?;
                    if !validation["ok"].as_bool().unwrap_or(false) {
                        println!("{}", serde_json::to_string_pretty(&validation)?);
                        bail!("agent roster validation failed");
                    }
                    validation
                }
            };
            println!("{}", serde_json::to_string_pretty(&response)?);
        }
        Command::Persona { root, command } => {
            let response = match command {
                PersonaCommand::Init => init_persona_registry(&root)?,
                PersonaCommand::List { limit } => list_persona_state(&root, limit)?,
                PersonaCommand::CreateVault {
                    display_name,
                    vault_id,
                    owner,
                } => create_memory_vault(&root, &display_name, vault_id.as_deref(), &owner)?,
                PersonaCommand::CreateCard {
                    display_name,
                    persona_id,
                    visual_asset_id,
                } => create_persona_card(
                    &root,
                    &display_name,
                    persona_id.as_deref(),
                    &visual_asset_id,
                )?,
                PersonaCommand::UpdateCard {
                    persona_id,
                    display_name,
                    visual_asset_id,
                    base_template,
                    status,
                    behavior_rule,
                    warmth,
                    directness,
                    humor,
                    detail,
                } => {
                    let rules =
                        (!behavior_rule.is_empty()).then(|| serde_json::json!(behavior_rule));
                    let mut tone = serde_json::Map::new();
                    for (key, value) in [
                        ("warmth", warmth),
                        ("directness", directness),
                        ("humor", humor),
                        ("detail", detail),
                    ] {
                        if value >= 0 {
                            tone.insert(key.to_string(), json!(value));
                        }
                    }
                    let tone = (!tone.is_empty()).then(|| Value::Object(tone));
                    update_persona_card(
                        &root,
                        &persona_id,
                        display_name.as_deref(),
                        visual_asset_id.as_deref(),
                        base_template.as_deref(),
                        status.as_deref(),
                        tone.as_ref(),
                        None,
                        rules.as_ref(),
                    )?
                }
                PersonaCommand::CreateTwin {
                    display_name,
                    memory_vault_id,
                    persona_card_id,
                    instance_id,
                } => create_twin_instance(
                    &root,
                    &display_name,
                    &memory_vault_id,
                    &persona_card_id,
                    instance_id.as_deref(),
                    None,
                    None,
                )?,
                PersonaCommand::CreateCandidate {
                    trait_text,
                    target_persona_id,
                    source_type,
                    trait_type,
                    confidence,
                } => create_personality_candidate(
                    &root,
                    &trait_text,
                    &target_persona_id,
                    &source_type,
                    Vec::new(),
                    &trait_type,
                    confidence,
                )?,
                PersonaCommand::DecideCandidate {
                    candidate_id,
                    decision,
                    decided_by,
                    notes,
                    edited_trait,
                } => decide_personality_candidate(
                    &root,
                    &candidate_id,
                    &decision,
                    &decided_by,
                    &notes,
                    &edited_trait,
                )?,
            };
            println!("{}", serde_json::to_string_pretty(&response)?);
        }
        Command::Notifications { root, command } => {
            let response = match command {
                NotificationCommand::Check { write } => check_notifications(&root, write)?,
                NotificationCommand::List { kind, limit } => {
                    list_notifications(&root, kind.as_deref(), limit)?
                }
            };
            println!("{}", serde_json::to_string_pretty(&response)?);
        }
        Command::Codex { command } => match command {
            CodexCommand::Homes => {
                println!(
                    "{}",
                    serde_json::to_string_pretty(&discover_codex_homes()?)?
                );
            }
            CodexCommand::Chats { home, limit } => {
                println!(
                    "{}",
                    serde_json::to_string_pretty(&list_codex_threads(&home, limit)?)?
                );
            }
            CodexCommand::Quota { home } => {
                println!(
                    "{}",
                    serde_json::to_string_pretty(&read_codex_home_quota(&home)?)?
                );
            }
            CodexCommand::Billing { home } => {
                println!(
                    "{}",
                    serde_json::to_string_pretty(&read_codex_home_billing(&home)?)?
                );
            }
            CodexCommand::Login { home } => {
                println!(
                    "{}",
                    serde_json::to_string_pretty(&login_codex_home(&home)?)?
                );
            }
            CodexCommand::LaunchCli { home, cwd } => {
                println!(
                    "{}",
                    serde_json::to_string_pretty(&launch_codex_cli(&home, &cwd)?)?
                );
            }
            CodexCommand::ResumeCli {
                home,
                cwd,
                thread_id,
            } => {
                println!(
                    "{}",
                    serde_json::to_string_pretty(&resume_codex_cli(&home, &cwd, &thread_id)?)?
                );
            }
            CodexCommand::LaunchDesktop { home } => {
                println!(
                    "{}",
                    serde_json::to_string_pretty(&launch_codex_desktop(&home)?)?
                );
            }
            CodexCommand::ArchiveAutomationThreads { dry_run } => {
                let response = archive_automation_threads(CodexArchiveOptions { dry_run })?;
                println!("{}", serde_json::to_string_pretty(&response)?);
            }
        },
        Command::ServiceManager {
            command,
            service,
            port,
            root,
            profile_root,
            interval,
            plugin_root,
            auth_token_file,
            ensure_token_file,
        } => run_service_manager(
            command,
            service,
            port,
            root,
            profile_root,
            interval,
            plugin_root,
            auth_token_file,
            ensure_token_file,
        )?,
        Command::Mcp => {
            harvis_mcp::serve_stdio()?;
        }
        Command::Http {
            host,
            port,
            auth_token,
            auth_token_file,
            plugin_root,
            root,
        } => {
            if !matches!(host.as_str(), "127.0.0.1" | "localhost" | "::1") {
                eprintln!("warning: binding outside localhost expands the API exposure surface");
            }
            serve_blocking(HttpConfig {
                host,
                port,
                auth_token,
                auth_token_file,
                plugin_root,
                workspace_root: expanduser_cli(&root),
            })?;
        }
    }
    Ok(())
}

fn run_one_tick(root: PathBuf, interval: Option<u64>, profile_root: PathBuf) -> Result<u64> {
    let (status, side_effects) = run_tick(TickOptions {
        root,
        interval_override: interval,
        profile_root,
    })?;
    if side_effects.writes_refused {
        println!("refused: second state tree outside state_root; no state written");
    } else {
        println!("wrote status: {}", side_effects.status_path.display());
        println!("wrote report: {}", side_effects.report_path.display());
    }
    println!("state_root: {}", status.state_root);
    println!("packets: {}", status.packets_written.len());
    if !status.errors.is_empty() {
        println!("errors: {}", status.errors.len());
    }
    if !status.warnings.is_empty() {
        println!("warnings: {}", status.warnings.len());
    }
    Ok(status.tick_interval_seconds)
}

#[allow(clippy::too_many_arguments)]
fn run_service_manager(
    command: ServiceManagerCommand,
    service: String,
    port: u16,
    root: PathBuf,
    profile_root: PathBuf,
    interval: u64,
    plugin_root: PathBuf,
    auth_token_file: Option<PathBuf>,
    ensure_token_file: bool,
) -> Result<()> {
    let home = macos_service::home_dir();
    let mut token_info = Value::Null;
    let token_file = if let Some(path) = auth_token_file {
        Some(expanduser_cli(&path))
    } else if ensure_token_file {
        Some(macos_service::default_token_file(&home))
    } else {
        None
    };
    if ensure_token_file {
        if let Some(path) = &token_file {
            let (path, created) = ensure_service_token_file(path)?;
            token_info = json!({
                "token_file": path.display().to_string(),
                "created": created,
                "token_value_returned": false
            });
        }
    }

    let services = macos_service::selected_services(&service)?;
    if matches!(command, ServiceManagerCommand::Plist) && services.len() != 1 {
        bail!("plist command requires --service http or --service tick");
    }

    let configs = services
        .iter()
        .map(|service| {
            let mut config = macos_service::LaunchAgentConfig::new(*service, plugin_root.clone());
            config.home = home.clone();
            config.port = port;
            config.root = root.clone();
            config.profile_root = profile_root.clone();
            config.interval = interval;
            if *service == macos_service::Service::Http {
                config.auth_token_file = token_file.clone();
            }
            config
        })
        .collect::<Vec<_>>();

    match command {
        ServiceManagerCommand::Plist => {
            print!("{}", macos_service::render_launch_agent(&configs[0]));
        }
        ServiceManagerCommand::Status => {
            let services = configs
                .iter()
                .map(|config| macos_service::service_status(config.service, &home, port))
                .collect::<Vec<_>>();
            println!(
                "{}",
                serde_json::to_string_pretty(&json!({"services": services, "token": token_info}))?
            );
        }
        ServiceManagerCommand::Logs => {
            let log_dir = macos_service::ensure_log_dir(&home)?;
            let services = configs
                .iter()
                .map(|config| macos_service::service_status(config.service, &home, port))
                .collect::<Vec<_>>();
            println!(
                "{}",
                serde_json::to_string_pretty(&json!({
                    "log_dir": log_dir.display().to_string(),
                    "services": services,
                    "token": token_info
                }))?
            );
        }
        ServiceManagerCommand::Install
        | ServiceManagerCommand::Start
        | ServiceManagerCommand::Restart => {
            let action = match command {
                ServiceManagerCommand::Install => "install",
                ServiceManagerCommand::Start => "start",
                ServiceManagerCommand::Restart => "restart",
                _ => unreachable!(),
            };
            let mut results = Vec::new();
            for config in configs {
                let path = macos_service::write_launch_agent(&config)?;
                if action == "restart" {
                    let _ = macos_service::bootout(config.service, &home);
                }
                let proc = macos_service::bootstrap(config.service, &home);
                results.push(json!({
                    "service": config.service.as_str(),
                    "plist": path.display().to_string(),
                    "action": action,
                    "returncode": proc.returncode,
                    "stderr": proc.stderr
                }));
            }
            println!(
                "{}",
                serde_json::to_string_pretty(&json!({"results": results, "token": token_info}))?
            );
        }
        ServiceManagerCommand::Stop => {
            let mut results = Vec::new();
            for config in configs {
                let proc = macos_service::bootout(config.service, &home);
                results.push(json!({
                    "service": config.service.as_str(),
                    "action": "stop",
                    "returncode": proc.returncode,
                    "stderr": proc.stderr
                }));
            }
            println!(
                "{}",
                serde_json::to_string_pretty(&json!({"results": results, "token": token_info}))?
            );
        }
        ServiceManagerCommand::Uninstall => {
            let mut results = Vec::new();
            for config in configs {
                let proc = macos_service::bootout(config.service, &home);
                let path = macos_service::launch_agent_path(config.service, &home);
                if path.exists() {
                    fs::remove_file(&path)?;
                }
                results.push(json!({
                    "service": config.service.as_str(),
                    "action": "uninstall",
                    "returncode": proc.returncode,
                    "plist_removed": !path.exists()
                }));
            }
            println!(
                "{}",
                serde_json::to_string_pretty(&json!({"results": results, "token": token_info}))?
            );
        }
        ServiceManagerCommand::Probe { via_http } => {
            let services = configs
                .iter()
                .map(|config| macos_service::service_status(config.service, &home, port))
                .collect::<Vec<_>>();
            let probe = if via_http {
                service_manager_http_permission_probe(
                    &root,
                    &profile_root,
                    port,
                    token_file.as_ref(),
                )?
            } else {
                service_manager_direct_permission_probe(&root, &profile_root)
            };
            println!(
                "{}",
                serde_json::to_string_pretty(
                    &json!({"services": services, "probe": probe, "token": token_info})
                )?
            );
        }
    }
    Ok(())
}

fn service_manager_direct_permission_probe(root: &Path, profile_root: &Path) -> Value {
    let data = permission_probe_data(root, profile_root, "rust-service-manager-direct");
    let ok = data.get("ok").and_then(Value::as_bool).unwrap_or(false);

    json!({
        "mode": "rust-service-manager-direct",
        "response": {
            "ok": ok,
            "data": data
        },
        "token_value_returned": false
    })
}

fn permission_probe_data(root: &Path, profile_root: &Path, context: &str) -> Value {
    let root = expanduser_cli(&root.to_path_buf());
    let profile_root = expanduser_cli(&profile_root.to_path_buf());
    let harvis_dir = root.join(".harvis");
    let checks = vec![
        service_manager_probe_dir("workspace-root", &root),
        service_manager_probe_dir("workspace-harvis", &harvis_dir),
        service_manager_probe_dir("profile-root", &profile_root),
    ];
    let ok = checks
        .iter()
        .all(|check| check.get("ok").and_then(Value::as_bool).unwrap_or(false));

    json!({
        "permission_probe_version": "v0.43-rust-cli",
        "ok": ok,
        "context": context,
        "checks": checks,
        "redacted": true,
        "includesLocalAbsolutePaths": false
    })
}

fn service_manager_http_permission_probe(
    root: &Path,
    profile_root: &Path,
    port: u16,
    token_file: Option<&PathBuf>,
) -> Result<Value> {
    let root = expanduser_cli(&root.to_path_buf());
    let profile_root = expanduser_cli(&profile_root.to_path_buf());
    let token = token_file
        .map(expanduser_cli)
        .and_then(|path| fs::read_to_string(path).ok())
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty());
    let request_path = format!(
        "/permission-probe?root={}&profile_root={}&full=true",
        url_encode_cli(&root.display().to_string()),
        url_encode_cli(&profile_root.display().to_string())
    );
    let (status, body) = local_http_get(port, &request_path, token.as_deref())?;
    let response = serde_json::from_str::<Value>(&body).unwrap_or_else(|error| {
        json!({
            "ok": false,
            "endpoint": "/permission-probe",
            "error": format!("invalid JSON response: {error}")
        })
    });
    let envelope_ok = response.get("ok").and_then(Value::as_bool).unwrap_or(false);
    let data_ok = response
        .get("data")
        .and_then(|data| data.get("ok"))
        .and_then(Value::as_bool)
        .unwrap_or(envelope_ok);
    let ok = (200..300).contains(&status) && envelope_ok && data_ok;

    Ok(json!({
        "mode": "rust-service-manager-http",
        "http_status": status,
        "response": response,
        "ok": ok,
        "token_value_returned": false
    }))
}

fn service_manager_probe_dir(label: &str, path: &Path) -> Value {
    let existed_before = path.exists();
    let writable = fs::create_dir_all(path)
        .and_then(|_| {
            let probe = path.join(".harvis-permission-probe.tmp");
            fs::write(&probe, "ok\n")?;
            fs::remove_file(probe)
        })
        .is_ok();

    json!({
        "label": label,
        "exists": existed_before || path.exists(),
        "ok": writable,
        "writable": writable
    })
}

fn local_http_get(port: u16, path: &str, token: Option<&str>) -> Result<(u16, String)> {
    let mut stream = TcpStream::connect(("127.0.0.1", port))
        .with_context(|| format!("connect to H.A.R.V.I.S. Runtime API on 127.0.0.1:{port}"))?;
    stream.set_read_timeout(Some(Duration::from_secs(5)))?;
    stream.set_write_timeout(Some(Duration::from_secs(5)))?;

    let auth_header = token
        .map(|value| format!("Authorization: Bearer {value}\r\n"))
        .unwrap_or_default();
    let request = format!(
        "GET {path} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nAccept: application/json\r\nConnection: close\r\n{auth_header}\r\n"
    );
    stream.write_all(request.as_bytes())?;

    let mut response_bytes = Vec::new();
    let mut buffer = [0_u8; 8192];
    loop {
        match stream.read(&mut buffer) {
            Ok(0) => break,
            Ok(count) => response_bytes.extend_from_slice(&buffer[..count]),
            Err(error) if matches!(error.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut) => {
                if response_bytes.is_empty() {
                    return Err(error.into());
                }
                break;
            }
            Err(error) => return Err(error.into()),
        }
    }
    let response =
        String::from_utf8(response_bytes).context("non-UTF-8 H.A.R.V.I.S. API response")?;
    let (headers, body) = response
        .split_once("\r\n\r\n")
        .context("malformed HTTP response from H.A.R.V.I.S. API")?;
    let status = headers
        .lines()
        .next()
        .and_then(|line| line.split_whitespace().nth(1))
        .and_then(|code| code.parse::<u16>().ok())
        .context("missing HTTP status from H.A.R.V.I.S. API")?;

    Ok((status, body.to_string()))
}

fn url_encode_cli(value: &str) -> String {
    value
        .bytes()
        .flat_map(|byte| match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => {
                vec![byte as char]
            }
            _ => format!("%{byte:02X}").chars().collect::<Vec<_>>(),
        })
        .collect()
}

fn ensure_service_token_file(path: &PathBuf) -> Result<(PathBuf, bool)> {
    let path = expanduser_cli(path);
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    if path.exists() {
        secure_file_permissions(&path)?;
        return Ok((path, false));
    }
    fs::write(&path, format!("{}\n", random_hex_token()?))?;
    secure_file_permissions(&path)?;
    Ok((path, true))
}

fn random_hex_token() -> Result<String> {
    let mut bytes = [0u8; 32];
    fs::File::open("/dev/urandom")
        .context("open /dev/urandom")?
        .read_exact(&mut bytes)
        .context("read random token")?;
    Ok(bytes.iter().map(|byte| format!("{byte:02x}")).collect())
}

#[cfg(unix)]
fn secure_file_permissions(path: &PathBuf) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;
    let mut permissions = fs::metadata(path)?.permissions();
    permissions.set_mode(0o600);
    fs::set_permissions(path, permissions)?;
    Ok(())
}

#[cfg(not(unix))]
fn secure_file_permissions(_path: &PathBuf) -> Result<()> {
    Ok(())
}

fn expanduser_cli(path: &PathBuf) -> PathBuf {
    let Some(value) = path.to_str() else {
        return path.clone();
    };
    if value == "~" {
        return macos_service::home_dir();
    }
    if let Some(rest) = value.strip_prefix("~/") {
        return macos_service::home_dir().join(rest);
    }
    path.clone()
}
