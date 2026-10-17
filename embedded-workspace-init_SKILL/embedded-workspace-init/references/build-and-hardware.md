# Build and Hardware

Use this guide to discover or execute embedded builds, handle IDE/generated code, classify build writes, or plan hardware validation.

## Discover Commands From Evidence

Prefer, in order: repository build/CI scripts and README/tasks; prior IDE/build logs and Make/CMake/Ninja files; IDE project metadata; then standard CLI candidates supported by installed tools. An unsupported heuristic remains `candidate`.

Look for Make, CMake presets, Eclipse `.project`/`.cproject`, Keil `.uvprojx`, IAR `.ewp`, MPLAB `nbproject`, ESP-IDF, Zephyr/west, PlatformIO, and Arduino metadata. Do not recursively search disks. On Windows, resolve tools from `Get-Command`, project/environment setup, vendor variables, installed-software metadata, known vendor locations, and shortcut targets. Store tool IDs and argument arrays portably; store executable paths only in `targets.local.json`.

Each target can have multiple stable `build_id` configurations. A configuration stores relative `cwd`, `default_execution_context: agent-copy`, `{tool,args[]}`, command state, expected `output_paths`, confirmed `generated_write_paths`, and expected artifacts. Paths are relative, nonoverlapping, and cannot escape the target root.

Register or update a discovered build configuration with `workspace-management/tools/set-build-config.ps1`. Keep heuristic commands as `candidate`; an actual successful `invoke-build.ps1 -AllowCandidate` run records evidence and promotes the same stable build ID to `verified`.

## Structured Execution

Resolve a registered tool ID to an explicit executable and pass each argument through `System.Diagnostics.ProcessStartInfo.ArgumentList`. Never execute a concatenated shell string, `Invoke-Expression`, a pipe, redirection, `;`, or `&&`. Validate the working directory under the selected execution root.

Normal development builds run only in a source-private worktree with `execution_context: agent-copy`. Mount the registered complete engineering root and its shared paths first; a target IDE directory is not a complete root. Build commands and response scripts must reference the selected task, never another task's physical engineering copy. Missing mounts/ambiguous boundaries stop the build. Setup never builds merely to validate layout. A `user-authority` build is allowed only from a frozen publish transaction after file verification. Registered SDKs, packs, license services, and wrappers may be external read-only inputs; audit pre/post-build hooks for signing, version writes, external paths, and auto-flash.

Capture executable/version, PowerShell executable/version, target/build IDs, commit, context, cwd, arguments, exit code, stdout/stderr artifact references, before/after file changes, and expected artifact hashes in schema-valid evidence. Do not embed large logs in JSON. A zero exit without a created/updated expected ELF/HEX/BIN is not a passed/verified build.

Command states are `candidate|verified|unavailable|unconfirmed|stale`; individual results are `passed|failed|unavailable|not-run`. Source compilation failure records a failed run without downgrading a previously verified command. Tool/project/dependency changes mark the command stale. Advance a build baseline only on actual success with artifact evidence.

## Safe Initial Build

Require an executable tool with successful version query, an explicit project/config/cwd/output set, an Agent-copy context, no required source regeneration, audited hooks without flash/erase/unknown external writes, and an independent IDE workspace not in use. During initialization do not clean/rebuild/delete caches, install tools, convert build systems, or modify source to pass.

Before and after build, inventory the relevant tree. Changes under confirmed `output_paths` are expected disposable products. Changes under confirmed `generated_write_paths` are declared project writes and require the synchronization rules. Any other project/IDE change is review-required. Store logs/evidence under workspace management or current workstream artifacts, never at the root.

## IDE And Generated Code

Import an Agent copy as a new project, omit Eclipse `.metadata`, use an independent IDE workspace, and do not reuse old objects/dependency files/ELF caches. Check linked resources, path variables, absolute paths, compiler/debug paths, and build hooks. Resulting debug information must point at the copy.

Do not regenerate by default. When requested, checkpoint and snapshot affected files, run only in the copy, inspect the diff, preserve generator user regions such as `USER CODE BEGIN/END`, and warn when existing edits lie in generator-owned sections.

## Verification And Hardware

Use the smallest meaningful available verification: build, existing relevant software tests, a simulator that covers the behavior, board validation with known board/probe/power/ports, or HIL with controllable fixtures and assertions. Do not add a framework during initialization. State separately what built, what software behavior passed, and what physical hardware was not tested.

Initialization never flashes, erases, resets, debugs, or operates hardware. For a later explicit hardware task, do not seize a busy probe/port. Warn once before first motor/high-power action. Require confirmation every time for OTP/eFuse, permanent protection/lock, option bytes, bootloader-area changes, or full-chip erase containing important data. Version 1 creates no hardware lock service.
