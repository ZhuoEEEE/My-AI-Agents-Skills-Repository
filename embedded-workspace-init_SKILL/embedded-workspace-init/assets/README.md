# Embedded Agent Workspace

This directory is the single Codex project entry for the embedded product. Open this root in a Codex `Local` environment. Do not create a Codex worktree for the root and do not open a directory below `sources/` or `work/` as a separate project.

- `USER_GUIDE.md`: user-facing workflow and recovery guide.
- `project-docs/`: confirmed product, solution, roadmap, decision, and version knowledge.
- `sources/`: private integration repositories; not normal edit locations.
- `work/`: task records and retained artifacts; engineering worktrees are mounted and released per registered project as needed.
- `reference-projects/`: immutable examples for selective reading.
- `workspace-management/`: configuration, guides, schemas, tools, sync state, evidence, and recovery.

Current machine state is in `workspace-management/config/workspace.json` and `workspace-management/config/targets.local.json`. The root Git repository tracks management metadata only; source status belongs to each source-private repository.

