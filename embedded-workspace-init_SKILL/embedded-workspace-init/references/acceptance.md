# Acceptance Matrix

Read this file only when validating or releasing the skill. `P0` and `P2` are the minimum usable release gate. `P1` remains required before its real multi-source, concurrency, migration, user-Git, or complex build scenario is enabled. Each original number 1 through 81 must occur exactly once; capability IDs are stable and unique.

Run all `scripts/test-*.ps1` validation scripts before release; they use isolated synthetic fixtures and remove them after completion.

Format: `ID | priority | original number | observable requirement`.

- CORE-01 | P0 | original=1 | An empty directory initializes the complete pure skeleton, three root documents, schemas, guides, and management Git.
- CORE-02 | P0 | original=2 | A current directory that is a user project receives only an external-root proposal; no path is written before approval.
- CORE-03 | P0 | original=3 | Real paths, links, junctions, mappings, and known multi-active ownership cannot create recursive containment.
- MIG-01 | P0 | original=4 | A nonempty unmanaged candidate remains unchanged until one complete migration plan is approved.
- MIG-02 | P1 | original=5 | A legacy workspace migrates to a new empty path while the old path remains an external read-only history source.
- CORE-04 | P0 | original=6 | Only `layout_mode: pure` and `managed_root: .` are accepted; no embedded compatibility layout exists.
- CORE-05 | P0 | original=7 | Layout initialization adds no rule, guide, Git ignore, or Agent file to user authority.
- GIT-01 | P0 | original=8 | User Git and its ignore file are created only through separately explicit authorization.
- CORE-06 | P0 | original=9 | An active workspace has exactly one generated root `AGENTS.md` and no active root override/fallback.
- MIG-03 | P1 | original=10 | Default legacy-rule archival is byte-for-byte with provenance and nondiscoverable names; explicit digest-bound preserve-only copies no rule bodies or archive manifest.
- CORE-07 | P1 | original=11 | Rule-like files already present in external user sources remain byte-for-byte unchanged.
- CORE-08 | P0 | original=12 | Initialization records/rechecks the real root before activation; nonlocal/root mismatch/outer worktree states stop writes.
- MIG-04 | P1 | original=13 | Legacy history is read only on demand and is never automatically targeted, built, synced, published, or loaded as policy.
- MAP-01 | P1 | original=14 | Single- and multi-MCU products use the same source-group and target model.
- MAP-02 | P1 | original=15 | Multiple dispersed mappings preserve required topology without copying an unrelated common parent.
- MAP-03 | P0 | original=16 | Portable mapping identity/topology is in `targets.json`; absolute paths occur only in ignored `targets.local.json`.
- MAP-04 | P0 | original=17 | Every user-synced integration file reverses to exactly one mapping; no-authority sources have empty mappings and cannot publish.
- MAP-05 | P1 | original=18 | Mapping revision changes only with topology; stale workstreams/transactions cannot publish.
- MAP-06 | P1 | original=19 | Agent-created sources use `agent-created`, `user_source: none`, and `sync_strategy: none`.
- REF-01 | P2 | original=20 | Promoted references use `reference-promoted` and never invent a user authority.
- MAP-07 | P1 | original=21 | A later MCU project is assigned stable identity/origin and added to the correct source-private Git.
- MAP-08 | P0 | original=22 | Repeated detection does not duplicate targets, overwrite confirmed facts, bump unchanged mappings, or create empty commits.
- MAP-09 | P1 | original=23 | Sparse field metadata preserves provenance, verification, and freshness; confirmed values resist scans.
- BUILD-01 | P1 | original=24 | Tool/project/config changes mark affected facts stale without renaming stable build IDs.
- GIT-02 | P0 | original=25 | User, management, and source-private Git boundaries remain distinct and every Git command verifies its repository.
- GIT-03 | P0 | original=26 | Management Git tracks only declared metadata/knowledge/tools and checkpoints explicit operation paths.
- GIT-04 | P0 | original=27 | Management Git ignores source/reference bodies and local/dynamic state while tracking every fixed responsibility README.
- GIT-05 | P1 | original=28 | Existing user Git is not auto-committed/pushed; absent Git records enabled, disabled, or deferred only after the matching choice.
- GIT-06 | P0 | original=29 | Every supported source has independent no-push private Git; user imports also have reachable stable baseline refs.
- GIT-07 | P1 | original=30 | A simple Git authority imports saved dirty/untracked state; submodule/nested-worktree/LFS topology pauses without flattening.
- WORK-01 | P0 | original=31 | Each workstream edits fixed-path linked worktrees, never the public integration copy.
- WORK-02 | P0 | original=32 | `workstream.json` alone owns task identity, scope, baselines, refs, and dependencies; README is human handoff only.
- WORK-03 | P1 | original=33 | Workstreams work without conversation IDs; new tasks default new and only explicit unique continuations reuse.
- WORK-04 | P1 | original=34 | Scope is source plus normalized relative path/access, and expansion/publish rechecks overlap.
- WORK-05 | P1 | original=35 | Terminal workstreams with unresolved changes continue to participate in conflict detection.
- WORK-06 | P1 | original=36 | Parallel worktrees are independent, overlapping writes are reported, and shared state uses one workspace mutex.
- WORK-07 | P1 | original=37 | An integration aggregate may be verified but never supplies the publish difference.
- SYNC-01 | P0 | original=38 | User-sync and build baselines are independent; never-built targets can still synchronize.
- SYNC-02 | P0 | original=39 | User baseline, task base, and frozen head have distinct recorded meanings.
- SYNC-03 | P0 | original=40 | A stable private ref keeps every managed user baseline's content retrievable.
- SYNC-04 | P0 | original=41 | Complete indexes record mapping/path/type/size/time/hash; incomplete scans never imply deletion.
- SYNC-05 | P1 | original=42 | Import into active tasks replays task commits onto new user/task bases without leaking user content into task diff.
- SYNC-06 | P0 | original=43 | Publish includes only task-base-to-frozen-head changes and fixed dependency closure.
- SYNC-07 | P0 | original=44 | A frozen per-file manifest records mapping, operation, all three states, expected result, and write precondition.
- SYNC-08 | P0 | original=45 | Same-location edits, stale mappings, incomplete scans, and changed precondition hashes stop before user writes.
- SYNC-09 | P0 | original=46 | Publish uses per-file atomic replace and explicit recoverable deletion, never directory mirror overwrite.
- SYNC-10 | P1 | original=47 | Multi-source publish completes all preflight/backups before applying any source and verifies as one transaction.
- SYNC-11 | P0 | original=48 | Path/apply/file verification failure safely rolls back all transaction writes and leaves baseline unchanged.
- SYNC-12 | P0 | original=49 | Correct file publish plus failed user build preserves scene/snapshot and waits for keep/rollback choice.
- SYNC-13 | P0 | original=50 | Accepting failed-build files advances only user sync baseline and never records build success.
- SYNC-14 | P0 | original=51 | Unavailable safe build may complete after file verification with explicit unverified-build status.
- SYNC-15 | P0 | original=52 | Unprovable/failed rollback enters `recovery_required` and blocks import/publish.
- SYNC-16 | P0 | original=53 | Equivalent Agent-to-user wording uses one publish flow; only ambiguous direction prompts.
- BUILD-02 | P0 | original=54 | Stable build IDs store tool ID/args/cwd and separate command trust, run result, and side-effect state.
- BUILD-03 | P0 | original=55 | Agent builds avoid old caches/use independent IDE state; user builds only occur in frozen publish transactions.
- SAFE-01 | P0 | original=56 | Read-only mode creates no state, directories, logs, backups, Git objects, or build output.
- SAFE-02 | P0 | original=57 | Import preserves legal notices, filters credentials, and leaves ambiguous license/secret files pending.
- SAFE-03 | P0 | original=58 | Suspected secrets enter no Agent Git while high entropy alone does not exclude binary dependencies.
- CORE-09 | P0 | original=59 | Tools/logs/downloads/tests stay out of root and every created responsibility boundary has an accurate README.
- REF-02 | P2 | original=60 | A reference has an independent wrapper/manifest/immutable body and is never auto-targeted or published.
- REF-03 | P2 | original=61 | A mutable task reference copy records provenance/cleanup, owns temporary private Git, and never publishes.
- REF-04 | P2 | original=62 | Agents load only task-relevant references rather than traversing all reference code.
- DOC-01 | P2 | original=63 | Product, current solution, roadmap, decisions, and version bounds have distinct durable locations.
- DOC-02 | P2 | original=64 | Unconfirmed task conclusions are not project facts and superseded decisions remain linked.
- MIG-05 | P1 | original=65 | A constraint upgrade is a zero-write plan until complete explicit approval; refusal/cancel/partial approval writes nothing.
- MIG-06 | P1 | original=66 | An approved upgrade archives old rules and checkpoints management/affected private Git without committing user Git.
- MIG-07 | P1 | original=67 | Ordinary fact updates are not bundled into a pending migration and never occur in read-only mode.
- MIG-08 | P1 | original=68 | Fact-only rescans are idempotent; structural/policy/mapping/schema differences switch the whole run to plan mode.
- MIG-09 | P1 | original=69 | Legacy migration copies directly from unchanged old root to new initializing root without duplicate pre-init backup.
- MIG-10 | P1 | original=70 | Migration records source/time/report and activates only after validation; old root is never swapped/moved/deleted.
- DOC-03 | P0 | original=71 | Chinese `USER_GUIDE.md` explains Local entry, three Git domains, multi-build, baselines, sync, and recovery without script knowledge.
- CORE-10 | P0 | original=72 | Ordinary Agents can find guides, scripts, configs, schemas, templates, project knowledge, and task state without a daily skill.
- SAFE-04 | P0 | original=73 | Initialization does not repair source/install tools/change permissions/flash hardware/force tests and stops on unreadable paths.
- DOC-04 | P2 | original=74 | Empty PRODUCT/SOLUTION/ROADMAP bodies are not generated without real content.
- CORE-11 | P1 | original=75 | Case/separator/link aliases yield one mutex identity and lock timeout writes no shared state.
- WORK-08 | P1 | original=76 | Parallel shared updates serialize, reread inside lock, and atomically replace without lost updates.
- BUILD-04 | P0 | original=77 | Commands use tool ID, argument arrays, and `ProcessStartInfo.ArgumentList`, including paths with spaces/CJK/special characters.
- BUILD-05 | P0 | original=78 | Ordinary builds use `agent-copy`; `user-authority` is available only to a frozen publish transaction.
- BUILD-06 | P0 | original=79 | Output-only user builds complete; successful confirmed generated writes enter user baseline but not task diff.
- BUILD-07 | P0 | original=80 | Failed generated writes do not advance baseline; unknown project writes require side-effect review and block sync.
- MIG-11 | P1 | original=81 | Legacy migration keeps old root unchanged and new root inactive on source drift or validation failure.

Lightweight-design additions have no original number:

- DATA-01 | P0 | original=new | Workspace machine state/evidence is schema-valid JSON/JSONL without external YAML modules; native logs stay separate.
- DATA-02 | P0 | original=new | JSON writes use explicit depth, terminating warnings, reparse/schema/deep round-trip checks, and atomic replace; a low-depth counterexample is rejected and runtime PowerShell is recorded.
- DATA-03 | P0 | original=new | Evidence uses the common envelope and artifact references/hashes; bodies are ignored while evidence README is tracked.
- CONTEXT-01 | P0 | original=new | SKILL/root-rule size targets are soft and no safety behavior is removed merely to meet them.
- CONTEXT-02 | P0 | original=new | Ordinary tasks load only relevant guides/state and scripts emit summaries rather than complete logs/indexes/history.
- SYNC-17 | P0 | original=new | No `sync-state/workstreams/` cache exists; comparisons derive from source state, indexes, and workstream manifests.
- GIT-08 | P0 | original=new | Selected internal user edits survive on a verified branch before file restore; Agent HEAD, unrelated edits/index entries, and external authority stay unchanged; stale plans and secrets prevent restore.
