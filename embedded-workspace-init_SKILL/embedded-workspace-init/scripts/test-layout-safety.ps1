[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('ewils-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$assertions = 0

function Assert-True {
    param([Parameter(Mandatory)] [bool] $Condition, [Parameter(Mandatory)] [string] $Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
    $script:assertions++ | Out-Null
}

function Assert-Equal {
    param($Expected, $Actual, [Parameter(Mandatory)] [string] $Message)
    if ($Expected -cne $Actual) { throw "Assertion failed: $Message. Expected '$Expected', actual '$Actual'." }
    $script:assertions++ | Out-Null
}

function Assert-Throws {
    param([Parameter(Mandatory)] [scriptblock] $Action, [Parameter(Mandatory)] [string] $Pattern)
    try { & $Action }
    catch {
        if ($_.Exception.Message -notlike "*$Pattern*") { throw }
        $script:assertions++ | Out-Null
        return
    }
    throw "Assertion failed: expected an error containing '$Pattern'."
}
function Assert-ThrowsAny {
    param([Parameter(Mandatory)] [scriptblock] $Action)
    try { & $Action }
    catch { $script:assertions++ | Out-Null; return }
    throw 'Assertion failed: expected an error.'
}

function Write-Utf8Text {
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [string] $Text)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) { $null = New-Item -ItemType Directory -Path $parent }
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function Get-TreeFingerprint {
    param([Parameter(Mandatory)] [string] $Root)
    if (-not (Test-Path -LiteralPath $Root)) { return '<missing>' }
    $facts = [Collections.Generic.List[string]]::new()
    foreach ($item in Get-ChildItem -LiteralPath $Root -Recurse -Force | Sort-Object FullName) {
        $relative = [IO.Path]::GetRelativePath($Root, $item.FullName).Replace('\', '/')
        if ($item.PSIsContainer) { $facts.Add("D`t$relative") }
        else { $facts.Add("F`t$relative`t$($item.Length)`t$((Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash)") }
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes([string]::Join("`n", $facts))
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
}

try {
    $planScript = Join-Path $PSScriptRoot 'plan-migration.ps1'
    $missingWorkspace = Join-Path $testRoot 'missing-workspace'
    $missingPlan = (& $planScript -WorkspaceRoot $missingWorkspace | Out-String) | ConvertFrom-Json -Depth 40
    Assert-Equal 'new-empty' $missingPlan.route 'a missing empty candidate must use the new-empty route'
    Assert-True $missingPlan.can_apply 'a missing local candidate with no sources may be initialized'
    Assert-True (-not (Test-Path -LiteralPath $missingWorkspace)) 'read-only planning must not create a missing root'

    $userProject = Join-Path $testRoot 'user-project'
    Write-Utf8Text -Path (Join-Path $userProject 'Makefile') -Text "all:`r`n`t@echo test`r`n"
    Write-Utf8Text -Path (Join-Path $userProject 'src\main.c') -Text "int main(void) { return 0; }`r`n"
    Write-Utf8Text -Path (Join-Path $userProject 'AGENTS.md') -Text "user-owned rule-like content`r`n"
    Write-Utf8Text -Path (Join-Path $userProject 'Debug\old.o') -Text 'stale'
    Write-Utf8Text -Path (Join-Path $userProject 'build\old.elf') -Text 'stale'
    Write-Utf8Text -Path (Join-Path $userProject 'out\old.bin') -Text 'stale'
    $userBefore = Get-TreeFingerprint $userProject

    $insidePlan = (& $planScript -WorkspaceRoot $userProject -UserSourcePath $userProject | Out-String) | ConvertFrom-Json -Depth 40
    Assert-Equal 'inside-user-source' $insidePlan.route 'a user project cannot be used as the managed root'
    Assert-True (-not $insidePlan.can_apply) 'an inside-user-source plan must not be applicable'
    Assert-True $insidePlan.approval_required 'the route must require selection and approval of an external root'
    Assert-True $insidePlan.summary.external_root_required 'the plan must explicitly request an external root'
    Assert-True ($insidePlan.summary.external_root_requirement -like '*real-path disjoint*') 'the external-root proposal must explain the separation requirement'
    Assert-Equal $userBefore (Get-TreeFingerprint $userProject) 'inside-user-source planning must not alter the user project'

    $containingRoot = Join-Path $testRoot 'containing-root'
    $containedSource = Join-Path $containingRoot 'firmware'
    Write-Utf8Text -Path (Join-Path $containedSource 'Makefile') -Text "all:`r`n"
    $containingBefore = Get-TreeFingerprint $containingRoot
    $containsPlan = (& $planScript -WorkspaceRoot $containingRoot -UserSourcePath $containedSource | Out-String) | ConvertFrom-Json -Depth 40
    Assert-Equal 'contains-user-source' $containsPlan.route 'a root containing the authority must use the contains-user-source route'
    Assert-True (-not $containsPlan.can_apply) 'a containing root must not be applicable'
    Assert-Equal $containingBefore (Get-TreeFingerprint $containingRoot) 'contains-user-source planning must be read-only'

    $unmanaged = Join-Path $testRoot 'unmanaged'
    Write-Utf8Text -Path (Join-Path $unmanaged 'existing.txt') -Text 'keep exactly'
    $unmanagedBefore = Get-TreeFingerprint $unmanaged
    $unmanagedPlan = (& $planScript -WorkspaceRoot $unmanaged | Out-String) | ConvertFrom-Json -Depth 40
    Assert-Equal 'nonempty-unmanaged' $unmanagedPlan.route 'a nonempty unmanaged directory must enter migration planning'
    Assert-True (-not $unmanagedPlan.can_apply) 'a nonempty unmanaged root cannot initialize directly'
    Assert-True $unmanagedPlan.approval_required 'migration planning must require approval'
    Assert-Equal $unmanagedBefore (Get-TreeFingerprint $unmanaged) 'unmanaged migration planning must write nothing'

    $outer = Join-Path $testRoot 'outer-git'
    $null = New-Item -ItemType Directory -Path $outer
    $null = & git -C $outer init --initial-branch=main
    $candidateInGit = Join-Path $outer 'candidate'
    $outerPlan = (& $planScript -WorkspaceRoot $candidateInGit | Out-String) | ConvertFrom-Json -Depth 40
    Assert-True (-not $outerPlan.can_apply) 'a candidate inside an outer Git worktree must be blocked'
    Assert-True (@($outerPlan.summary.blockers | Where-Object { $_ -like '*nested inside an outer Git worktree*' }).Count -eq 1) 'the outer Git blocker must be explicit'
    Assert-True (-not (Test-Path -LiteralPath $candidateInGit)) 'outer-worktree inspection must not create the candidate'

    $alias = Join-Path $testRoot 'source-alias'
    $null = New-Item -ItemType Junction -Path $alias -Target $userProject
    $aliasDefinitions = @(
        [ordered]@{ id = 'actual'; origin = 'user-imported'; user_source = 'configured'; mappings = @([ordered]@{ id = 'actual-map'; source_path = $userProject; integration_subpath = '.' }) },
        [ordered]@{ id = 'alias'; origin = 'user-imported'; user_source = 'configured'; mappings = @([ordered]@{ id = 'alias-map'; source_path = $alias; integration_subpath = '.' }) }
    ) | ConvertTo-Json -Depth 10 -Compress
    $aliasPlan = (& $planScript -WorkspaceRoot (Join-Path $testRoot 'alias-workspace') -SourceDefinitionsJson $aliasDefinitions | Out-String) | ConvertFrom-Json -Depth 40
    Assert-True (-not $aliasPlan.can_apply) 'junction aliases of one authority must be detected as overlapping'

    $workspace = Join-Path $testRoot 'workspace'
    $initResult = (& (Join-Path $PSScriptRoot 'init-workspace.ps1') -WorkspaceRoot $workspace -UserSourcePath $userProject | Out-String) | ConvertFrom-Json -Depth 40
    Assert-Equal 'active' $initResult.status 'the isolated workspace must activate'
    Assert-Equal $userBefore (Get-TreeFingerprint $userProject) 'layout initialization must not alter user-authoritative files'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $userProject '.git'))) 'layout initialization must not initialize user Git'

    $requiredDirectories = @(
        'project-docs/decisions', 'project-docs/versions', 'reference-projects', 'sources', 'work',
        'workspace-management/config', 'workspace-management/guides', 'workspace-management/schemas',
        'workspace-management/tools/lib', 'workspace-management/templates/project-docs',
        'workspace-management/sync-state/sources', 'workspace-management/sync-state/indexes',
        'workspace-management/sync-state/transactions', 'workspace-management/evidence',
        'workspace-management/recovery', 'workspace-management/migration',
        'workspace-management/history/legacy-instructions', 'workspace-management/ide-workspaces'
    )
    foreach ($relative in $requiredDirectories) {
        Assert-True (Test-Path -LiteralPath (Join-Path $workspace $relative) -PathType Container) "fixed directory must exist: $relative"
    }
    foreach ($relative in @('AGENTS.md', 'README.md', 'USER_GUIDE.md', '.gitignore')) {
        Assert-True (Test-Path -LiteralPath (Join-Path $workspace $relative) -PathType Leaf) "required root file must exist: $relative"
    }
    Assert-True (Test-Path -LiteralPath (Join-Path $workspace 'AGENTS.md') -PathType Leaf) 'the generated rule file must be at the root'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $workspace 'AGENTS.override.md'))) 'the managed root must not contain an active override'
    Assert-Equal (Get-FileHash -LiteralPath (Join-Path $userProject 'AGENTS.md') -Algorithm SHA256).Hash `
        (Get-FileHash -LiteralPath (Join-Path $workspace 'sources\user-project\integration\AGENTS.md') -Algorithm SHA256).Hash `
        'a user-owned rule-like file must remain byte-for-byte protected content'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $workspace 'project-docs\PRODUCT.md'))) 'initialization must not create an empty product document'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $workspace 'project-docs\SOLUTION.md'))) 'initialization must not create an empty solution document'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $workspace 'project-docs\ROADMAP.md'))) 'initialization must not create an empty roadmap document'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $workspace 'workspace-management\sync-state\workstreams'))) 'the removed workstream cache must not exist'

    $integration = Join-Path $workspace 'sources\user-project\integration'
    Assert-Equal ([IO.Path]::GetFullPath($workspace).Replace('\', '/')) ((& git -C $workspace rev-parse --show-toplevel | Out-String).Trim()) 'management Git must own the workspace root'
    Assert-Equal ([IO.Path]::GetFullPath($integration).Replace('\', '/')) ((& git -C $integration rev-parse --show-toplevel | Out-String).Trim()) 'source-private Git must own only its integration root'
    Assert-Equal '' ((& git -C $integration remote | Out-String).Trim()) 'source-private Git must have no push remote'
    Assert-Equal '' ((& git -C $workspace status --short | Out-String).Trim()) 'management Git must be clean after initialization'
    Assert-Equal '' ((& git -C $integration status --short | Out-String).Trim()) 'source-private Git must be clean after initialization'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $integration 'Debug'))) 'Debug cache must be excluded from the copy'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $integration 'build'))) 'build cache must be excluded from the copy'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $integration 'out'))) 'out cache must be excluded from the copy'

    $targetsPath = Join-Path $workspace 'workspace-management\config\targets.json'
    $localPath = Join-Path $workspace 'workspace-management\config\targets.local.json'
    $targetsRaw = Get-Content -Raw -LiteralPath $targetsPath
    $localRaw = Get-Content -Raw -LiteralPath $localPath
    Assert-True (-not $targetsRaw.Contains($userProject, [StringComparison]::OrdinalIgnoreCase)) 'portable targets must not contain the authority absolute path'
    Assert-True ($localRaw.Contains($userProject.Replace('\', '/'), [StringComparison]::OrdinalIgnoreCase)) 'local targets must contain the authority absolute path'
    $sourceState = Get-Content -Raw -LiteralPath (Join-Path $workspace 'workspace-management\sync-state\sources\user-project.json') | ConvertFrom-Json -Depth 40
    Assert-Equal $sourceState.user_baseline_commit ((& git -C $integration rev-parse $sourceState.user_baseline_ref | Out-String).Trim()) 'the user baseline must be reachable through its stable private ref'
    Assert-True ((& git -C $workspace check-ignore 'workspace-management/config/targets.local.json' | Out-String).Trim().Length -gt 0) 'local configuration must be ignored by management Git'
    Assert-True ((& git -C $workspace check-ignore 'sources/user-project/integration/src/main.c' | Out-String).Trim().Length -gt 0) 'source bodies must be ignored by management Git'
    Assert-True ((& git -C $workspace ls-files 'workspace-management/evidence/README.md' | Out-String).Trim().Length -gt 0) 'the fixed evidence README must be tracked'

    $beforeDetectHash = (Get-FileHash -LiteralPath $targetsPath -Algorithm SHA256).Hash
    $beforeDetectCommit = (& git -C $workspace rev-parse HEAD | Out-String).Trim()
    $detect = (& (Join-Path $workspace 'workspace-management\tools\detect-targets.ps1') -WorkspaceRoot $workspace -Apply | Out-String) | ConvertFrom-Json -Depth 20
    Assert-True (-not $detect.changed) 'repeated detection must report no change'
    Assert-Equal $beforeDetectHash (Get-FileHash -LiteralPath $targetsPath -Algorithm SHA256).Hash 'repeated detection must not rewrite targets'
    Assert-Equal $beforeDetectCommit ((& git -C $workspace rev-parse HEAD | Out-String).Trim()) 'repeated detection must not create an empty commit'

    $beforeReadOnly = Get-TreeFingerprint $workspace
    $null = & (Join-Path $workspace 'workspace-management\tools\detect-targets.ps1') -WorkspaceRoot $workspace
    $null = & (Join-Path $PSScriptRoot 'refresh-workspace.ps1') -WorkspaceRoot $workspace
    Assert-Equal $beforeReadOnly (Get-TreeFingerprint $workspace) 'report-only detection and refresh must make zero filesystem or Git writes'

    Import-Module (Join-Path $PSScriptRoot 'lib\workspace-common.psm1') -Force
    $scratch = Join-Path $testRoot 'json'
    $null = New-Item -ItemType Directory -Path $scratch
    $scratchPath = Join-Path $scratch 'workspace.json'
    $workspaceSchema = Join-Path $PSScriptRoot '..\assets\schemas\workspace.schema.json'
    $valid = [pscustomobject][ordered]@{
        workspace_schema = 1; policy_version = 1; workspace_state = 'initializing'; layout_mode = 'pure'; managed_root = '.'
        initializer = 'embedded-workspace-init'; initialized_at = '2026-09-13T00:00:00+08:00'
        migration = [pscustomobject][ordered]@{ migrated_from = $null; migrated_at = $null }
    }
    Write-EwiJsonAtomic -Path $scratchPath -Value $valid -SchemaPath $workspaceSchema
    $validHash = (Get-FileHash -LiteralPath $scratchPath -Algorithm SHA256).Hash
    $invalid = $valid.PSObject.Copy()
    $invalid.layout_mode = 'embedded'
    Assert-Throws -Pattern 'schema' -Action { Write-EwiJsonAtomic -Path $scratchPath -Value $invalid -SchemaPath $workspaceSchema }
    Assert-Equal $validHash (Get-FileHash -LiteralPath $scratchPath -Algorithm SHA256).Hash 'a rejected JSON write must preserve the previous file'
    $nested = [ordered]@{ leaf = 'value' }
    foreach ($level in 1..105) { $nested = [ordered]@{ child = $nested } }
    Assert-Throws -Pattern 'depth' -Action { $null = ConvertTo-EwiCanonicalJson $nested }
    $lowDepth = [ordered]@{ a = [ordered]@{ b = [ordered]@{ c = 'value' } } }
    Assert-ThrowsAny -Action { $null = $lowDepth | ConvertTo-Json -Depth 1 -WarningAction Stop }
    $invalidIndexPath = Join-Path $scratch 'invalid-index.jsonl'
    Assert-Throws -Pattern 'schema' -Action {
        Write-EwiJsonLinesAtomic -Path $invalidIndexPath -Records @([pscustomobject]@{ foo = 'bar' }) -SchemaPath (Join-Path $PSScriptRoot '..\assets\schemas\file-index-record.schema.json')
    }
    Assert-True (-not (Test-Path -LiteralPath $invalidIndexPath)) 'a schema-invalid JSONL record must never replace the target file'

    $evidencePath = Write-EwiEvidence -WorkspaceRoot $workspace -EvidenceId 'workspace-layout-validation' -Kind 'workspace-validation' `
        -Subject ([pscustomobject][ordered]@{ workspace = $workspace; source_id = $null; target_id = $null; build_id = $null; workstream_id = $null; publish_id = $null; reference_id = $null }) `
        -Result ([pscustomobject][ordered]@{ status = 'passed'; summary = 'Synthetic layout validation passed.'; exit_code = 0; details = [pscustomobject]@{ checks = $assertions } }) `
        -Artifacts @()
    $evidence = Get-Content -Raw -LiteralPath $evidencePath | ConvertFrom-Json -Depth 40
    Assert-Equal (Get-Process -Id $PID).Path $evidence.runtime.powershell_path 'evidence must record the actual PowerShell executable'
    Assert-Equal $PSVersionTable.PSVersion.ToString() $evidence.runtime.powershell_version 'evidence must record the actual PowerShell version'
    Assert-True ((Get-Content -Raw -LiteralPath $evidencePath | Test-Json -SchemaFile (Join-Path $workspace 'workspace-management\schemas\evidence.schema.json'))) 'evidence must match the common schema'
    Assert-True ((& git -C $workspace check-ignore ([IO.Path]::GetRelativePath($workspace, $evidencePath).Replace('\', '/')) | Out-String).Trim().Length -gt 0) 'evidence bodies must be ignored by management Git'

    $scopedRepo = Join-Path $testRoot 'scoped-commit'
    $null = New-Item -ItemType Directory -Path $scopedRepo
    $null = & git -C $scopedRepo init --initial-branch=main
    $null = & git -C $scopedRepo config user.name 'Scoped Commit Test'
    $null = & git -C $scopedRepo config user.email 'scoped@local.invalid'
    Write-Utf8Text -Path (Join-Path $scopedRepo 'unrelated.txt') -Text "old unrelated`r`n"
    Write-Utf8Text -Path (Join-Path $scopedRepo 'requested.txt') -Text "old requested`r`n"
    $null = & git -C $scopedRepo add -- 'unrelated.txt' 'requested.txt'
    $null = & git -C $scopedRepo commit -m baseline
    Write-Utf8Text -Path (Join-Path $scopedRepo 'unrelated.txt') -Text "staged unrelated`r`n"
    Write-Utf8Text -Path (Join-Path $scopedRepo 'requested.txt') -Text "new requested`r`n"
    $null = & git -C $scopedRepo add -- 'unrelated.txt'
    $scopedCommit = New-EwiGitCommit -Repository $scopedRepo -Message 'scoped checkpoint' -RelativePaths @('requested.txt')
    Assert-True (-not [string]::IsNullOrWhiteSpace($scopedCommit)) 'a requested path change must create a checkpoint'
    Assert-Equal 'requested.txt' ((& git -C $scopedRepo show --name-only --pretty=format: HEAD | Out-String).Trim()) 'a scoped checkpoint must not include an unrelated pre-staged file'
    Assert-True ((& git -C $scopedRepo status --short | Out-String).Trim() -like 'M*unrelated.txt*') 'an unrelated pre-staged file must remain staged after the scoped checkpoint'

    $local = Get-Content -Raw -LiteralPath $localPath | ConvertFrom-Json -Depth 40
    $local.workspace.root_path = $testRoot.Replace('\', '/')
    Write-EwiJsonAtomic -Path $localPath -Value $local -SchemaPath (Join-Path $workspace 'workspace-management\schemas\targets-local.schema.json')
    $targetsHashBeforeMismatch = (Get-FileHash -LiteralPath $targetsPath -Algorithm SHA256).Hash
    Assert-Throws -Pattern 'Current root does not match' -Action {
        & (Join-Path $workspace 'workspace-management\tools\detect-targets.ps1') -WorkspaceRoot $workspace -Apply | Out-Null
    }
    Assert-Equal $targetsHashBeforeMismatch (Get-FileHash -LiteralPath $targetsPath -Algorithm SHA256).Hash 'a root mismatch must stop before managed writes'

    $guideNames = @('lifecycle-and-migration.md', 'sources-targets-and-git.md', 'workstreams-and-concurrency.md', 'synchronization-and-recovery.md', 'build-and-hardware.md', 'references-and-project-knowledge.md', 'configuration-schema.md')
    $rootRules = Get-Content -Raw -LiteralPath (Join-Path $workspace 'AGENTS.md')
    foreach ($guide in $guideNames) { Assert-True ($rootRules.Contains("workspace-management/guides/$guide")) "root rules must route to $guide" }
    $userGuide = Get-Content -Raw -LiteralPath (Join-Path $workspace 'USER_GUIDE.md')
    foreach ($term in @('Local', 'Agent 管理 Git', '源组私有 Git', '用户工程 Git', '用户同步基线', '构建基线', 'recovery_required', '编辑器内 Agent 插件', '未保存的编辑器缓冲区', '三方比较', '纯净 Agent 工作区根目录')) {
        Assert-True ($userGuide.Contains($term)) "the Chinese user guide must explain $term"
    }

    [pscustomobject][ordered]@{
        status = 'passed'
        assertions = $assertions
        powershell = $PSVersionTable.PSVersion.ToString()
        git = ((& git --version | Out-String).Trim())
    } | ConvertTo-Json
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        $resolved = (Resolve-Path -LiteralPath $testRoot).Path
        $expectedParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
        if ([IO.Path]::GetDirectoryName($resolved).TrimEnd('\') -ne $expectedParent -or
            -not [IO.Path]::GetFileName($resolved).StartsWith('ewils-')) {
            throw "Refusing to clean unexpected test path: $resolved"
        }
        $links = @(Get-ChildItem -LiteralPath $resolved -Recurse -Force | Where-Object {
            ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
        } | Sort-Object { $_.FullName.Length } -Descending)
        foreach ($link in $links) {
            if ($link.PSIsContainer) { [IO.Directory]::Delete($link.FullName, $false) }
            else { [IO.File]::Delete($link.FullName) }
        }
        Get-ChildItem -LiteralPath $resolved -Recurse -Force | ForEach-Object { $_.Attributes = 'Normal' }
        (Get-Item -LiteralPath $resolved -Force).Attributes = 'Directory'
        [IO.Directory]::Delete($resolved, $true)
    }
}
