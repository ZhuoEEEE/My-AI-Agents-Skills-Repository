# Sources, Targets, and Git

Use this guide when grouping authoritative paths, defining mappings, discovering MCU projects, filtering imported files, or operating any of the three Git domains.

## Source And Mapping Model

A source group preserves one coherent relative topology and owns one private integration Git repository. Group projects under a reasonable common product root when that root contains no large unrelated tree. Use separate groups for independent dispersed roots. If dispersed paths share relative dependencies or generated configuration, use multiple mappings in one source group rather than copying an unrelated common parent.

Each mapping is a directory mapping with a stable `mapping_id`, a non-overlapping normalized `integration_subpath`, and a local `source_path`. Portable identity and topology belong in `targets.json`; absolute paths belong only in ignored `targets.local.json`. Reject absolute or `..` integration paths, overlapping subpaths, recursive containment, and any managed file that cannot map uniquely back to exactly one authority path. Increment `mapping_revision` only for a real approved topology change.

Source origins are independent of project type:

- `user-imported`: has external authority mappings, `explicit-publish-only`, and three-way synchronization.
- `agent-created`: has `user_source: none`, `sync_strategy: none`, empty mappings, and no import/publish or user-Git prompt.
- `reference-promoted`: was explicitly promoted; it still has no user source unless the user separately creates an approved mapping.

Do not invent a user path for an Agent-created or reference-promoted source. Adding one later uses `workspace-management/tools/migrate-source-mappings.ps1` with a reviewed digest-bound plan and first user baseline. The same command changes an existing mapping topology; unchanged mappings do not increment the revision.

Add a new external or Agent-created source to an active workspace with `workspace-management/tools/add-source.ps1`. Review its complete digest-bound plan before `-Apply`; reference promotion uses its dedicated command instead.

## Import Filtering

Before copying, enumerate the supplied roots only. Preserve source topology and legal material such as `LICENSE`, `NOTICE`, `COPYING`, copyright lists, startup code, linker scripts, required firmware blobs, and libraries.

Exclude `.git` metadata, IDE workspace state such as Eclipse `.metadata`, known reproducible caches/build products, and operating-system noise. Detect likely private keys, tokens, credentials, production signing files, license activation material, and device dumps by specific names/content markers; list them without copying. If `license` might mean a legal notice or a secret, mark it unresolved. High entropy is a warning only, not an exclusion rule.

Reject or pause external symlink/junction expansion. Never silently expand an SDK or unrelated tree. If an explicitly permitted sensitive dependency is legally copyable, keep it out of every managed Git and prefer an environment variable, license server, or external read-only reference.

Capture a file inventory before and after copying. A changing or incomplete source snapshot cannot become a baseline. Never interpret a filtered, unreadable, or unscanned item as a deletion.

## Target Discovery

Discover only in registered integration copies, never in `reference-projects/`. Recognize concrete markers such as `Makefile`, `CMakeLists.txt`, `CMakePresets.json`, `.project`/`.cproject`, `.uvprojx`, `.ewp`, `nbproject`, `sdkconfig`, `idf_component.yml`, `west.yml`, `platformio.ini`, and supported Arduino metadata.

Generate a concise human-readable `target_id` from project purpose/name and add the smallest suffix for collision. A stored ID survives folder or IDE display-name changes. New findings add missing detected facts; they never overwrite `provenance: confirmed`. Ambiguous backups/examples, nested entries, moved/split projects, nested Git, or conflicting generator/build facts remain candidates for user confirmation.

Stable build configurations use `build_id` values such as `debug` or `release`; do not derive a new ID merely from case or display-name changes. Tool or project changes mark affected detected/verified facts `stale` while preserving the prior value and evidence.

## Three Git Domains

### Direct Internal User Edits

The managed workspace is operated by the Agent. External authority remains user-owned and uses import/publish; direct edits to managed internal files follow a different policy. Before the Agent starts writing, record a clean relevant checkpoint. If direct user edits appear, first checkpoint any separate Agent-owned changes. Never label all dirty paths as user edits or restore a file containing mixed Agent/user changes without separating them.

Use `preserve-user-changes.ps1 -WorkspaceRoot <root> -RepositoryRelative <registered-repo-or-dot> -RelativePaths <explicit-files>` for a zero-write plan, then run it with `-Apply -ExpectedPlanDigest <digest>`. A standing internal-edit policy authorizes this operation without repeated confirmation. The script locks and rereads state, records only selected index/worktree content through an isolated Git index, creates a reachable `preserved-user/*` branch with verified raw-file blobs, restores selected files/index entries to the unchanged Agent HEAD, and writes recovery evidence. Additions, deletions, staged edits, and binaries are retained. It never checks out the preservation branch, moves Agent HEAD, broadly stages, resets a repository, or operates outside registered internal Git boundaries. Report the branch, commits, affected paths, and restoration result to the user after continuing the task. A failed capture prevents restore; drift/failure after capture stops with the preserved branch retained.

Ignored local configuration/runtime state cannot be made safe by forcing it into Git. Use the matching recovery operation and a verified snapshot; if ownership or the last valid state is unavailable, preserve the scene and stop that operation. Secrets never enter preservation Git. User-requested policy/configuration changes are explicit managed operations, not accidental edits to discard.

Every Git invocation uses `git -C <verified-root>` (or the common structured runner) and verifies the repository owner/type. Root Git status describes metadata only, never source status.

**Agent-management Git** at the workspace root tracks root docs, fixed responsibility READMEs, portable configuration, schemas, guides, templates, project knowledge, migration history, reference wrappers/manifests, and workstream metadata. It ignores integration/private worktrees, reference bodies, local config, dynamic sync state/indexes/transactions, evidence bodies, recovery data, IDE state, outputs, and temporary files while re-including each fixed README. Checkpoints stage only explicit paths for one management operation; never use broad add, commit-all, push, or rewrite unrelated history.

**Source-private Git** is mandatory per source group. Prefer an independent local clone for a simple single-Git authority only when it does not share an object store and saved dirty plus needed untracked content is imported. Otherwise initialize the integration copy. Maintain immutable, reachable user baseline commits/refs for user-imported groups, source checkpoints, workstream branches, and linked worktrees under `work/<id>/sources/<source-id>/`. Configure no push destination and never write private commits into user Git.

Pause a group containing a submodule, nested Git, existing linked worktree topology, or Git LFS. Report the detected topology; do not copy `.git`, flatten repositories, rewrite history, or claim byte-restorable LFS support. Independent nested repositories may become separate source groups only after confirmation.

**User Git** is optional and separately authorized through `workspace-management/tools/set-user-git.ps1`. Existing user Git is inspected and preserved; ordinary development and publish never auto-commit or push. For a source without Git, show the exact repository root, nested-repository checks, sensitive/build exclusions, and proposed `.gitignore`. On approval, initialize and make a baseline commit containing only reviewed saved content. Record refusal as `disabled` and no response as `deferred`; neither blocks workspace initialization. Mention reduced rollback protection only after a task actually writes/publishes user content.
