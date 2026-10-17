# Synchronization and Recovery

Use this guide for inspecting/importing saved user changes, publishing a workstream, resolving sync conflicts, handling build side effects, or recovering a transaction.

## Direction And Baselines

Only three operations exist: `inspect` is read-only, `import` flows user authority to private integration/current workstream, and `publish` flows a frozen workstream to user authority. Natural-language equivalents follow the same path; ask once only when direction or workstream is genuinely unclear.

The user sync baseline is retrievable content in a source-private immutable commit/ref. It is distinct from each workstream's task base and from the last successful build baseline. Hash indexes accelerate comparison but never replace retrievable commits. A project that has never built can still use three-way synchronization.

Dynamic per-source state lives in `workspace-management/sync-state/sources/<source-id>.json`; the managed file index lives in `indexes/<source-id>.jsonl`; publish transactions live in `transactions/<publish-id>.json`. Do not create a workstream comparison cache under sync state; derive comparisons from source state, index, and `workstream.json`.

## Inspect And Import

At task start, and again before build/publish in a long task, scan only registered mappings. With Git, inspect commits and worktree differences. Without it, compare path/type/size/mtime first and hash candidates. A scan must identify completeness; unreadable, filtered, or unscanned items are not deletions.

In read-only mode, report and stop. Otherwise, import nonconflicting saved user changes into the integration/private Git and create a new reachable user-baseline commit/ref plus file index. Different text regions may merge; same-region changes, delete/modify, binary, generated-code, and IDE-metadata conflicts stop the affected file.

For an active workstream, first checkpoint its own changes, then replay them and its pinned dependencies on the new user baseline. Update both `user_baseline_commit` and `task_base_commit`. User-originated content must not remain in `task_base_commit..head_commit`. A replay conflict stops without rewriting task intent.

## Publish Authorization And Freeze

Publishing requires explicit Agent-to-user intent and an identified current workstream. Remind the user once to save IDE/editor buffers. Do not process unsaved buffers.

Under the workspace mutex, reject non-active/recovery-blocked state, stale mappings, incomplete indexes, unreachable baselines/dependencies, out-of-scope changes, dirty unfrozen task content, or conflicts. Freeze `head_commit`; calculate publish content only from `task_base_commit..head_commit` plus pinned dependency closures.

Create a schema-valid transaction and per-file manifest. Every entry records source/mapping, normalized relative path, `add|modify|delete`, baseline/user/Agent/expected hashes, and immediate write precondition. Perform a complete all-source dry run before any user write. Three-way conflict, ambiguous mapping, user drift, range violation, or incomplete scan ends `conflicted` with zero source writes.

## Apply And Verify

1. Create a recovery snapshot and SHA-256 manifest for every affected authority path, excluding only confirmed rebuildable outputs. Finish all preflight and backups before applying any source.
2. Immediately before the first write, recheck every manifest precondition: changed/deleted files equal `user_hash`; additions remain absent.
3. Reject absolute/`..`/link escape. Never use directory mirroring, implicit deletion, time-based overwrite, `/MIR`, or `--delete`.
4. Before each file, recheck its hash. Write additions/modifications through a same-directory temporary file and atomic replacement. Move deletions into the recovery area before removing their source name.
5. Verify every resulting hash against the frozen manifest. Multiple roots use all-preflight, all-backup, per-source apply, and one final verification; filesystem-wide atomicity is not claimed.
6. If safely available, the transaction may invoke a registered user-authority build. Record file, build, and side-effect status independently. Advance the user baseline only after the transaction reaches a permitted terminal state.

Normal transaction progression is `planned -> backed_up -> applying -> applied -> file_verified -> completed`. Other states include `conflicted`, `apply_failed`, `rolled_back`, `verification_failed`, `side_effect_review_required`, and `recovery_required`. A nonterminal transaction blocks new import/publish. Persist and release the mutex before waiting for a user decision; recovery reacquires it and revalidates current hashes.

## Failure And Side Effects

On path/apply/file-verification failure, roll back all applied roots only when each current file still equals the transaction's expected result. Verify restoration and leave the baseline unchanged. If an external writer changed a result or restoration fails, enter `recovery_required`; do not overwrite and block new import/publish.

When files publish correctly but the user build fails, enter `verification_failed`, preserve the files/snapshot/log, and ask whether to keep or roll back. Accepting advances only the user sync baseline, never the successful-build baseline. If a safe build is unavailable, completion may record `build_status: unavailable` after file verification.

Confirmed `output_paths` are disposable outputs and do not enter the user baseline. Confirmed `generated_write_paths` may enter a new user baseline only after a successful build and must not enter the task diff. A failed build that changes such files remains `verification_failed`. Any other project/config/IDE write is `side_effect_review_required`; file publication may remain verified, but no baseline advances and new sync operations remain blocked until the user classifies or restores it. A changed tool, hook, project, mapping, or path classification makes prior classification stale.

Only an actual successful build with expected updated artifacts advances `last_successful_build_commit`. Report file publication, build verification, and hardware verification as separate facts.


## Sparse Engineering State

Private Git commits contain the complete source-group tree while a workstream may check out only selected engineering paths. Compare committed trees for task and dependency changes; physical absence outside the mounted selection is never a delete. Import replay preserves active sparse selections; a released nonterminal branch may use a temporary empty sparse worktree for replay and removes it afterward. `none` refs need no replay until first mount. A publish report must request restoring released projects and any missing dependency-closure paths before the normal frozen plan/apply flow; it never silently materializes files in read-only mode. Git commits and user/build baselines survive engineering-copy release. `recovery-required` copy state blocks import, mount, build, dependency changes and publish for that source until restored.
