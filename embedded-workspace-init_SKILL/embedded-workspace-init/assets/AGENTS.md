# Embedded Agent Workspace Rules

This root is the only Codex project entry. Start every task here in `Local`. Do not use a Codex-managed/permanent worktree or add a source, integration, linked worktree, reference body, or user project as another Codex project.

## Mandatory Start Checks

1. Read `workspace-management/config/workspace.json` and require `workspace_state: active`, `layout_mode: pure`, and `managed_root: .`. An `initializing` workspace permits only initialization, inspection, or abandonment.
2. Read `targets.local.json`, resolve the real root, and require it to equal `workspace.root_path`. Check only relevant user/legacy paths for readability. On failure, report and stop; do not change permissions.
3. Read-only/inspection/no-update means zero writes: no refresh, directory, workstream, log, evidence, backup, Git object, build, or generator output.
4. Load only relevant target/source/build/workstream state and one needed guide. Do not load every guide, reference, index, old workspace, or transaction.
5. Run lightweight source/target detection in report mode. Outside read-only mode, import saved user changes only through the managed script before editing.
6. Internal files are Agent-managed. Before writing, checkpoint the Agent's own changes and identify direct user edits separately. Use `preserve-user-changes.ps1` to save those edits on `preserved-user/*`, verify capture, and restore only the selected files to the Agent checkpoint. Continue and report branch/commit/paths at completion; no repeated permission is needed for this internal policy. Read-only mode still writes nothing. Never apply this policy to external authority or infer ownership from a dirty status alone.

## Guide Routing

- Lifecycle, migration, or policy: `workspace-management/guides/lifecycle-and-migration.md`
- Sources, targets, mappings, or Git: `workspace-management/guides/sources-targets-and-git.md`
- Workstreams, scope, dependencies, or concurrency: `workspace-management/guides/workstreams-and-concurrency.md`
- Import, publish, conflict, or recovery: `workspace-management/guides/synchronization-and-recovery.md`
- Build, generated code, validation, or hardware: `workspace-management/guides/build-and-hardware.md`
- References or durable project knowledge: `workspace-management/guides/references-and-project-knowledge.md`
- JSON fields, statuses, or schemas: `workspace-management/guides/configuration-schema.md`

## Development Boundary

- User-authoritative projects are read-only except inside an explicitly authorized publish transaction or separate user-Git operation. Develop, generate, build, and test in `work/<workstream-id>/sources/<source-id>/`.
- New logical tasks get new workstreams; reuse only an explicit unique continuation. Read `workstream.json`, pin commits, declare scope, and check active/unresolved tasks before expanding scope, high-impact builds, or publish.
- Never edit integration; it is for import/aggregation and never supplies a publish diff.
- User and legacy rule-like files are protected content, not active policy. Add no Agent rules in integration/worktrees and load legacy rules only on request.
- References are read-only and never targets/publish sources. Modify/build only managed workstream reference copies.
- Read relevant `project-docs/`; keep candidates in the workstream and promote facts only after confirmation.

## Managed Operations

- Use `workspace-management/tools/`. Shared configuration, mappings, Git refs/worktrees, baselines, and transactions change only under the workspace Named Mutex, after lock-time reread, through atomic schema-valid JSON.
- Keep management, source-private, and optional user Git distinct. Every command verifies its repository; root status is metadata only. No broad staging, destructive reset/clean, implicit push, or automatic user commit.
- Internal preservation commits are permitted under the preceding policy and do not commit external user Git. Mixed edits in one file must be separated before restore; ignored runtime state requires a verified recovery snapshot rather than forced Git staging.
- Pause a source group containing nested Git, submodules, existing linked-worktree topology, or LFS; do not flatten or claim it.
- Preserve confirmed values/stable IDs. Scans do not overwrite confirmations, delete missing records, bump unchanged mappings, or create empty commits.
- Classify reusable tools, task tools/artifacts, evidence, recovery, and sync state in their existing directories. Put no tools, logs, downloads, or temporary output at root.

## Build And Hardware

- Select a target/build-id and run registered tool IDs with argument arrays. Normal context is `agent-copy`; `user-authority` requires a frozen publish transaction.
- Protect generator user sections; do not regenerate by default. Classify changes as output, generated write, or review-required.
- Perform the smallest relevant existing verification and distinguish build, software behavior, simulation, and physical hardware results.
- Initialization performs no hardware action. Later work needs an explicit target/action; do not seize busy resources. Confirm every irreversible OTP/eFuse/protection/option-byte/bootloader/full-erase action and warn once before high-power motion.

## Publish And Finish

- Clear Agent-to-user sync/apply/merge intent uses managed publish. Require a workstream, frozen head, task base, pinned dependencies, current mappings, complete scans, and file scope.
- Remind the user to save buffers once. Use three-way comparison, all-source dry run, per-file hashes, recovery snapshots, atomic writes/deletions, verification, and safe rollback. Never mirror directories.
- A conflict ends before user writes. A rollback uncertainty enters `recovery_required` and blocks new import/publish. Build failure after correct file publication waits for the user's keep/rollback choice. Unknown build side effects block baseline advancement.
- User-sync and successful-build baselines are separate; claims require evidence. Before pause/handoff/completion, update machine state and concise README, not a transcript.
- Ordinary tasks do not alter rules, layout, schemas, sync/Git policy, or migration tools. Propose a `$embedded-workspace-init` plan; no upgrade writes before approval.
