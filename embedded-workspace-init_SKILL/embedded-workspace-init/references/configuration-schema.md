# Configuration and Schema

Use this guide when reading/writing workspace state, targets/local bindings, workstreams, source sync state, publish transactions, manifests, or evidence.

## Machine Data Rules

Except skill frontmatter and `agents/openai.yaml`, all structured workspace state is UTF-8 JSON or JSONL and has a bundled schema. Do not add a YAML dependency. Each schema types every known object/array node, requires every field needed for a safety decision, constrains finite states with `enum`, and uses deterministic patterns for IDs/hashes/relative paths where `format` alone is insufficient.

Use the common atomic writer. Serialize with an explicit depth sufficient for the schema and make warnings terminating. Write a same-directory temporary file, reparse it, validate with `Test-Json -SchemaFile`, recursively compare original versus round-tripped JSON types/values/array lengths/object keys, then atomically replace. A low-depth warning or nested type change must fail. Each JSONL line is a complete object; any partial/unparseable line makes the scan incomplete and blocks mutation/deletion inference.

Runtime evidence uses a common envelope with `schema`, `evidence_id`, `kind`, `captured_at`, `subject`, `result`, and `artifacts`. Artifacts are relative references with media type, size, and available SHA-256; stdout, stderr, binary reports, and vendor logs remain separate. Evidence bodies are ignored by management Git while `evidence/README.md` is tracked.

Record the actual `pwsh` executable path/version and JSON/schema capability used for validation; do not substitute a different terminal's version. Runtime must not install parsing modules.

## Core Files

`workspace-management/config/workspace.json` owns `workspace_schema`, `policy_version`, `workspace_state`, fixed `layout_mode: pure`, fixed `managed_root: .`, initializer identity, timestamps, and optional legacy migration ID/time. `initializing` permits no ordinary task; only verified atomic transition enables `active`.

`targets.json` contains portable source groups, mappings, target/build facts, and sparse `field_metadata`. It must contain no absolute local paths or secrets. `targets.local.json` contains the registered real root, local authority paths, legacy-workspace paths, tool executables, and hardware bindings; it is ignored by every managed Git and contains no secret.

For user-backed sources, mapping IDs in both files are one-to-one. The reversible relation is:

`source_path/<relative> <-> integration_path/integration_subpath/<relative>`

Every managed sync file resolves to exactly one mapping. Source groups without user authority have empty mappings and cannot publish.

`field_metadata` keys are stable JSON Pointers for important identity/path/MCU/project/build/generated-code facts. Provenance is `detected|confirmed|imported`; verification is `unverified|verified|failed`; freshness is `current|stale|conflicted`. Scans may add missing data or update detected data, never silently replace confirmed data. Actual evidence alone grants `verified`; changed dependencies retain values but set `stale`.

`workstream.json` is the only machine source for task identity/scope/status/refs/dependencies. Per-source sync state owns mapping digest/revision, reachable user baseline commit/ref, scan completeness, file-index link, and build baselines. Publish transactions own frozen manifest, preconditions, snapshots, phase, independent file/build/side-effect statuses, and recovery facts. Do not duplicate these facts in prose or a sync-state workstream cache.

## Loading And Versioning

Read `workspace.json` and the registered root first, then only current source/target/build/workstream records and the guide needed for the task. Load complete indexes, evidence, transactions, old workspace, or reference bodies only for a relevant conflict, recovery, audit, or requested comparison.

Never silently accept an unknown schema/policy version. Fact refresh may not change schema, policy, layout, mappings, or safety policy. A known version-specific migration requires a read-only plan, explicit approval, snapshots/checkpoints, deterministic apply, schema validation, and rollback. Policy 2 supports only the explicit 1-to-2 engineering-copy migration; unknown future versions are rejected. Workspace, targets and workstream schemas have a known legacy-read form and a version-2 form. Ordinary mutations require policy 2. Targets version 2 adds source project registries and optional target project IDs; workstreams version 2 add per-project mount records and checkout state. Upgrade plans contain hash-bound transformed state, leaving source mappings/baselines unchanged. Old worktrees remain `legacy-full` until separately released, including dirty paused tasks.
