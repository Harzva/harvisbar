# What makes a tool usable by agents?

A working implementation and a schema are the foundation. A useful agent-facing tool also needs:

1. **Discovery:** a precise tool/skill name and description, help, examples, and registration in the actual client. Avoid a catch-all description that activates on unrelated work.
2. **Executable contract:** typed inputs and outputs, stable IDs, allowed operations, bounds, pagination and versioned compatibility. A schema describes a contract; runtime validation enforces it.
3. **Recoverable errors:** stable error codes, exit codes, retryability, timeouts and useful next actions. Do not conflate missing results with failed queries.
4. **Evidence:** observation time, data source, freshness and partial-success state. Distinguish declared, installed, running and published state. Unknown is not false or zero.
5. **Mutation controls:** previews, precise target scope, verified preconditions, concurrency checks, idempotency, concrete authorization and tested restore paths. Expose capability limits until the real executor exists.
6. **Operational verification:** test through a real client, not only direct function calls; retain request IDs and scoped receipts without recording credentials. Verify registration and distinguish an existing connection from a pending client reload.
7. **One implementation:** UI, CLI and MCP call the same underlying logic. A skill teaches when/how to use it; it should not duplicate the implementation or invent permissions.

For Harvis Versions, discovery, schema-validated reads, bounded pagination, stable errors, source/freshness evidence, read-only previews and preview revalidation are implemented. Actual product upgrade and rollback remain explicitly disabled. This distinction is returned in capabilities, every plan and the skill rather than hidden in documentation alone.
