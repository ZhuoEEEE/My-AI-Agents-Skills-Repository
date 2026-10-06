---
name: embedded-workspace-init
description: Initialize, migrate, or explicitly refresh an isolated Windows Agent workspace for embedded and MCU products while preserving external IDE projects as user-authoritative sources. Use only when the user explicitly invokes this skill for workspace setup, source registration, reference import, rescanning, or a controlled workspace-policy upgrade; do not use for ordinary firmware development.
---

# Embedded Workspace Init

Build or maintain a pure Agent workspace without reorganizing or taking ownership of the user's authoritative projects. The durable behavior comes from the generated root `AGENTS.md`, canonical guides, machine state, and deterministic scripts.

## Start Safely

1. Treat `read-only`, `inspect only`, or equivalent wording as an absolute zero-write mode. Do not create a plan file, directory, log, build output, Git object, or refreshed fact.
2. Resolve this skill's directory from this `SKILL.md`; invoke scripts by absolute path. Never initialize the installed skill directory.
3. Resolve the candidate workspace, every supplied user source, and any legacy workspace to real local Windows paths. Reject unreadable paths, network/WSL paths, reparse-point ambiguity, recursive containment, a source used as its own integration copy, or an outer Codex-managed/permanent worktree.
4. Inspect the candidate root before choosing a route. Do not scan whole drives or paths the user did not supply.

Read [lifecycle-and-migration.md](references/lifecycle-and-migration.md) for every initialization, migration, refresh, or policy-upgrade request. Read only the additional guide needed by the operation:

- Source grouping, mappings, target discovery, filtering, or Git: [sources-targets-and-git.md](references/sources-targets-and-git.md)
- Workstreams or parallel task setup: [workstreams-and-concurrency.md](references/workstreams-and-concurrency.md)
- Import, publish, conflict, or recovery: [synchronization-and-recovery.md](references/synchronization-and-recovery.md)
- Build discovery, validation, generated code, or hardware: [build-and-hardware.md](references/build-and-hardware.md)
- Reference projects or durable project knowledge: [references-and-project-knowledge.md](references/references-and-project-knowledge.md)
- JSON fields, states, schemas, or evidence: [configuration-schema.md](references/configuration-schema.md)

For direct user edits inside an Agent-managed workspace, read the internal-edit section of [sources-targets-and-git.md](references/sources-targets-and-git.md). Preserve the selected changes on a Git branch before restoring the Agent checkpoint; external authority edits still use normal import.

Do not load all references, all targets, all workstreams, complete indexes, historical transactions, or every reference project by default.

## Route The Request

Use `scripts/plan-migration.ps1` for read-only inventory and route selection. It must remain the only action when the request is read-only or any safety fact is unresolved.

- **Empty new root:** explicit invocation authorizes creation of the fixed pure-workspace skeleton. Resolve source grouping and reversible directory mappings first, then run `scripts/init-workspace.ps1`. It may write only the new workspace and private managed copies; it must not change a user source or initialize user Git.
- **Active compatible root:** preserve stable IDs and confirmed fields. Run `scripts/refresh-workspace.ps1` only for the requested idempotent fact refresh. If it reports a structural, policy, mapping, or schema change, switch to the controlled-upgrade route.
- **Nonempty uninitialized or legacy root:** inventory only, present one complete migration plan and its approval digest, then stop. After explicit approval, rerun the inventory. Apply only the unchanged approved plan with `scripts/apply-migration.ps1`; keep the old root untouched.
- **Candidate inside a user project, or containing one:** do not create anything there. Propose a user-selected external empty root, present its complete plan, and wait for approval.
- **Reference import:** read the reference guide, then use `scripts/import-reference.ps1`. A reference stays outside source/target discovery and publishing.

Partial approval does not authorize a partial migration. Revise the plan and request confirmation again. A material change between plan and apply invalidates approval.

Honor explicit legacy exclusions. `plan-migration.ps1 -LegacyRuleDisposition preserve-only -RegisterLegacyWorkspace:$false` keeps old instructions solely at the old path and omits a live historical-path binding. These choices are digest-bound; classify unwanted legacy directories/files as `preserve-only`, never delete them.

## Shared Invariants

- The only supported layout is `layout_mode: pure`, `managed_root: .`; daily Codex tasks start at that real root in a `Local` environment.
- The workspace must be `active` for ordinary development, import, or publish. An `initializing` root permits only initialization, inspection, or abandonment.
- User-authoritative projects are read-only except during an explicit publish transaction or a separately authorized user-Git operation. Normal edits and builds occur in `work/<workstream-id>/sources/<source-id>/`.
- Keep Agent-management Git, one private Git per source group, and optional user Git distinct. Every Git command names and verifies its repository. Never stage unrelated changes with broad add/commit forms.
- Shared configuration, mappings, Git refs/worktrees, baselines, and publish state change only through managed scripts under the workspace Named Mutex, with state reread after lock acquisition.
- JSON/JSONL writes use the shared atomic writer, explicit serialization depth, schema validation, and round-trip comparison. Never hand-edit dynamic state during an operation.
- Preserve license and copyright material. Do not copy likely credentials, private keys, production signing material, license secrets, `.git` metadata, IDE workspace state, or known rebuildable caches. Ambiguity blocks that item; high entropy alone does not classify a binary as secret.
- Do not flatten nested Git, submodules, linked worktrees, or LFS. Pause the affected source group and report its topology.
- Do not build, regenerate, flash, erase, debug, install tools, change permissions, repair source, or initialize user Git merely as part of layout setup.
- Never use a whole-directory mirror or delete synchronization against a user source. Publish only a frozen workstream commit and pinned dependency closure through per-file preconditions, recovery snapshots, atomic replacement, verification, and rollback rules.
- Create dynamic project documents, reference instances, workstreams, evidence, logs, recovery snapshots, and migration records only when the corresponding operation actually occurs.

## Finish

Verify the root path, schemas, fixed skeleton, unique root `AGENTS.md`, guide hashes, Git boundaries, source baselines, reversible mappings, and absence of user-source writes before changing `workspace_state` atomically to `active`. Report what was created or refreshed, what was deliberately preserved or excluded, current build evidence, any deferred user-Git choice, and every blocked or unverified capability. Never claim a build, hardware test, migration, rollback, or publish succeeded without its recorded evidence.

For implementation or release validation of this skill itself, read [acceptance.md](references/acceptance.md). Do not deploy that matrix into initialized workspaces.
