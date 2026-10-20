pub mod agent_pools;
pub mod agent_room;
pub mod agent_roster;
pub mod approvals;
pub mod chair;
pub mod decisions;
pub mod gbrain_memory;
pub mod inbox;
pub mod init;
pub mod knowledge_graph;
pub mod knowledge_provider;
pub mod mcp_stdio;
pub mod memory;
pub mod memory_profiles;
pub mod memory_provider;
pub mod notifications;
pub mod persona;
pub mod profile;
pub mod projects;
pub mod provider_registry;
pub mod retention;
pub mod runs;
pub mod speaker;
pub mod stalled;
pub mod termination;
pub mod tick;
pub mod trace;
pub mod workbench;

pub fn runtime_label() -> &'static str {
    "harvis-runtime"
}
