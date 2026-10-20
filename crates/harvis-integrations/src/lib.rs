pub mod agent_gateway;
pub mod agent_harnesses;
pub mod agent_mail;
pub mod codex_homes;
pub mod codex_threads;
pub mod hub;
pub mod hypermemory;
pub mod local_ports;
pub mod repoatlas;
pub mod router;
pub mod status_query;

pub fn integrations_label() -> &'static str {
    "harvis-integrations"
}
