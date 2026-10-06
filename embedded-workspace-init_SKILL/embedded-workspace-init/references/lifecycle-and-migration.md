# Lifecycle and Migration

Read this guide for initialization, refresh, legacy-workspace migration, or policy/schema upgrades. Planning is semantic work by the Agent; scripts supply inventory facts and deterministic application.

## Supported Boundary

Version 1 supports one local Windows host, local paths, a single pure Agent root, and Windows Named Mutex coordination. It does not promise cross-host, network-share, or WSL/Windows concurrency. The managed root must never contain a user-authoritative source, and no source may contain the managed root, including through symlinks, junctions, case aliases, or mapped subpaths.

Daily Codex tasks must open the registered real root in a `Local` environment. Do not use a Codex-managed/permanent worktree for that root or add `sources/*/integration`, a source-private linked worktree, or a user project as a separate Codex project. Do not use `.worktreeinclude` to copy ignored managed state into an outer worktree.

## Route Selection

Run `plan-migration.ps1` without a write switch and classify the candidate:

- `new-empty`: explicit invocation may initialize it after source grouping and mapping are unambiguous.
- `active`: validate `workspace.json`, `targets.local.json`, root identity, policy/schema versions, and fixed files. Perform only the requested fact refresh unless a managed constraint must change.
- `initializing`: permit only inspection, resuming the same approved initialization, or abandoning it. Never perform daily development, import, or publish.
- `nonempty-unmanaged` or `legacy`: inventory and present a complete migration plan. Make no filesystem or Git write before approval.
- `inside-user-source` or `contains-user-source`: reject the location and ask the user to choose an external empty path.

If a path is missing, unreadable, a network/WSL path, ambiguously linked, or known to belong to another active workspace, report it and stop the affected operation. Pass known active roots to planning for ownership checks; never scan the machine or use a global registry to discover alternatives.

## New Workspace

For an approved empty root:

1. Re-resolve every path immediately before writing and ensure the target is still empty.
2. Create the fixed skeleton with `workspace_state: initializing`; record the real root only in ignored `targets.local.json`.
3. Create Agent-management Git, deploy root documents, schemas, templates, canonical guides, and runtime tools.
4. For each confirmed source group, create its integration copy and independent private Git. Import only saved, managed, non-sensitive files through reversible mappings; create a reachable immutable user baseline and file index.
5. Detect target candidates without overriding confirmed facts. Do not repair source or install/build/flash merely to make initialization pass.
6. Validate paths, mappings, schemas, guide hashes, Git boundaries, unique root rules, source baselines, and that user sources did not change.
7. Atomically change the state to `active` only after every required invariant passes. A source compilation failure is recorded separately and does not invalidate a sound layout.

Do not initialize user Git as part of this flow. Offer that as a separate, explicit choice after showing its proposed repository boundary and inclusions/exclusions.

## Legacy Or Nonempty Migration

Use a new empty destination; keep the old directory exactly where it is.

The plan must show real old/new paths, source definitions, explicit old-relative to new-relative copy mappings, exclusions and unresolved items, Git boundaries, legacy rule files, validation, rollback, and an approval digest. Unknown classification blocks application. Partial approval requires a revised complete plan.

After approval, inventory again. Any changed path, file hash, Git state, source definition, or plan digest invalidates approval. Then:

1. Ask the user to save files and pause writes to the old workspace.
2. Initialize the new root as `initializing` and copy only approved mappings. Compare source inventory before and after copying; a change leaves the new root inactive.
3. By default, archive old `AGENTS.md`, `AGENTS.override.md`, and configured fallback instruction files byte-for-byte under `workspace-management/history/legacy-instructions/`. Use timestamp plus short hash names and a schema-valid manifest containing original path, archive path, SHA-256, archive time, and prior-active status. If the user explicitly declines copying old rules, plan `LegacyRuleDisposition: preserve-only`; no rule body or archive manifest is created. `RegisterLegacyWorkspace: false` also omits the historical local-path binding. Both choices belong to the approved payload.
4. Never name an archive as an active fallback instruction file. The new root has one active `AGENTS.md`; old rules remain audit material and are not loaded unless the user asks.
5. Generate `workspace-management/migration/initialization-report.md` with actual paths, copy manifest digest, verification, preserved items, and non-actions. No placeholders may remain.
6. Activate only after verification. On failure, leave the old directory untouched and the new directory clearly `initializing`; do not swap, rename, delete, or create a duplicate pre-init backup of the old root.

The old workspace is an external historical reference, not a normal reference project, source, target, build root, or publish destination. Read only relevant files. To modify or build old content, first copy the needed material to a workstream reference copy.

## Refresh And Managed Upgrades

A fact-only refresh may add missing detected facts, new targets, or new source candidates without rewriting confirmed values, changing unchanged mappings, or creating empty commits. A missing/moved target becomes pending review rather than being deleted.

Any layout, policy, fixed structure, mapping, or schema change is a managed upgrade. Before approval, show current and target versions, exact file operations, mapping and Git effects, workstream/build/sync impact, snapshots, validation, and rollback. Then stop. Before approval, do not mix in routine fact updates.

After approval, use `apply-policy-upgrade.ps1` with the unchanged plan payload and approval digest. It reacquires the workspace mutex, rereads everything, checkpoints only explicit affected paths, snapshots management files, archives a replaced root rule, applies the defined version-specific migration, validates, and records a dated history entry. It rolls back management changes on failure and never publishes source as a side effect. Version 1 has no generic future migration engine.

## Idempotence And Stop Conditions

- Never reinitialize an existing repository or duplicate an object with the same stable ID.
- Do not rewrite unchanged files, increment an unchanged mapping revision, or create empty commits.
- Preserve user-confirmed fields and unrelated dirty files.
- Stop rather than infer through an incomplete scan, unreadable source, nested Git/LFS topology, ambiguous source grouping, recursive path, stale approval, lock timeout, schema failure, or root mismatch.
- `read-only` means zero writes everywhere, including logs, evidence, temporary plan files, Git objects, and build outputs.
