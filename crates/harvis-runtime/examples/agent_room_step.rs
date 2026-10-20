//! Dev driver for one Agent Room speaker step (T308/T309 acceptance runs).
//! It performs no provider calls; use `--dry-run` or roster participants with
//! a local `harness_ref`.
//!
//! Usage:
//!   cargo run -p harvis-runtime --example agent_room_step -- \
//!       --root /tmp/room --topic-id gwt-workbench --prompt "..." [--dry-run]

use anyhow::{bail, Result};
use harvis_runtime::speaker::{
    agent_room_speaker_step, LlmCallRequest, LlmCallResponse, SpeakerStepOptions,
};
use std::path::PathBuf;

fn main() -> Result<()> {
    let mut root: Option<PathBuf> = None;
    let mut topic_id: Option<String> = None;
    let mut prompt: Option<String> = None;
    let mut dry_run = false;
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--root" => root = args.next().map(PathBuf::from),
            "--topic-id" => topic_id = args.next(),
            "--prompt" => prompt = args.next(),
            "--dry-run" => dry_run = true,
            other => bail!("unknown argument: {other}"),
        }
    }
    let root = root.ok_or_else(|| anyhow::anyhow!("--root is required"))?;
    let mut llm = |_request: &LlmCallRequest| -> Result<LlmCallResponse> {
        bail!("example driver performs no provider calls")
    };
    let value = agent_room_speaker_step(
        &SpeakerStepOptions {
            root,
            topic_id,
            prompt,
            dry_run,
            ..SpeakerStepOptions::default()
        },
        &mut llm,
    )?;
    println!("{}", serde_json::to_string_pretty(&value)?);
    Ok(())
}
