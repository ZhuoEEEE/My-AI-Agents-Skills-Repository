[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/workspace-common.psm1') -Force
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('ewi-internal-' + [Guid]::NewGuid().ToString('N'))
$assertions = 0
function Assert-Equal {
    param($Expected, $Actual, [string] $Message)
    if ($Expected -cne $Actual) { throw "Assertion failed: $Message; expected '$Expected', actual '$Actual'." }
    $script:assertions++
}
function Assert-Throws {
    param([scriptblock] $Action, [string] $Pattern)
    try { & $Action }
    catch { if ($_.Exception.Message -notlike "*$Pattern*") { throw }; $script:assertions++; return }
    throw "Expected error: $Pattern"
}
function Write-Text {
    param([string] $Path, [string] $Text)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) { $null = New-Item -ItemType Directory -Path $parent }
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}
try {
    $workspace = Join-Path $testRoot 'workspace'
    $null = & (Join-Path $PSScriptRoot 'init-workspace.ps1') -WorkspaceRoot $workspace
    $tool = Join-Path $workspace 'workspace-management/tools/preserve-user-changes.ps1'
    foreach ($name in @('modified.txt', 'deleted.txt', 'staged.txt', 'staged-only.txt', 'unrelated.txt', 'binary.dat')) { Write-Text (Join-Path $workspace "project-docs/$name") 'agent-baseline' }
    $null = New-EwiGitCommit -Repository $workspace -RelativePaths @('project-docs/modified.txt', 'project-docs/deleted.txt', 'project-docs/staged.txt', 'project-docs/staged-only.txt', 'project-docs/unrelated.txt', 'project-docs/binary.dat') -Message 'Agent checkpoint'
    $head = (Invoke-EwiGit $workspace @('rev-parse', 'HEAD')).StdOut.Trim()
    $savedGitDirectory = $env:GIT_DIR
    $savedGitIndex = $env:GIT_INDEX_FILE
    try {
        $env:GIT_DIR = Join-Path $testRoot 'wrong-repository'
        $env:GIT_INDEX_FILE = Join-Path $testRoot 'wrong-index'
        Assert-Equal $head (Invoke-EwiGit $workspace @('rev-parse', 'HEAD')).StdOut.Trim() 'inherited Git directory cannot redirect operations'
        Assert-Equal $false (Test-Path -LiteralPath $env:GIT_INDEX_FILE) 'inherited Git index remains untouched'
    }
    finally { $env:GIT_DIR = $savedGitDirectory; $env:GIT_INDEX_FILE = $savedGitIndex }
    Write-Text (Join-Path $workspace 'project-docs/modified.txt') 'user-saved'
    [IO.File]::Delete((Join-Path $workspace 'project-docs/deleted.txt'))
    Write-Text (Join-Path $workspace 'project-docs/staged.txt') 'user-index'
    $null = Invoke-EwiGit $workspace @('add', '--', 'project-docs/staged.txt')
    Write-Text (Join-Path $workspace 'project-docs/staged.txt') 'user-worktree'
    Write-Text (Join-Path $workspace 'project-docs/staged-only.txt') 'user-index-only'
    $null = Invoke-EwiGit $workspace @('add', '--', 'project-docs/staged-only.txt')
    Write-Text (Join-Path $workspace 'project-docs/staged-only.txt') 'agent-baseline'
    Write-Text (Join-Path $workspace 'project-docs/added.txt') 'user-addition'
    [IO.File]::WriteAllBytes((Join-Path $workspace 'project-docs/binary.dat'), [byte[]]@(0, 255, 13, 10, 128))
    Write-Text (Join-Path $workspace 'project-docs/unrelated.txt') 'agent-staged-unrelated'
    $null = Invoke-EwiGit $workspace @('add', '--', 'project-docs/unrelated.txt')
    $paths = @('project-docs/modified.txt', 'project-docs/deleted.txt', 'project-docs/staged.txt', 'project-docs/staged-only.txt', 'project-docs/added.txt', 'project-docs/binary.dat')
    $status = (Invoke-EwiGit $workspace @('status', '--porcelain=v1')).StdOut
    $refs = (Invoke-EwiGit $workspace @('show-ref')).StdOut
    $plan = (& $tool -WorkspaceRoot $workspace -RelativePaths $paths | Out-String) | ConvertFrom-Json -Depth 20
    Assert-Equal $status (Invoke-EwiGit $workspace @('status', '--porcelain=v1')).StdOut 'planning is zero-write'
    Assert-Equal $refs (Invoke-EwiGit $workspace @('show-ref')).StdOut 'planning creates no refs'
    Assert-Throws { & $tool -WorkspaceRoot $workspace -RelativePaths $paths -Apply -ExpectedPlanDigest ('0' * 64) | Out-Null } 'reviewed preservation plan'
    Assert-Equal 'user-saved' ([IO.File]::ReadAllText((Join-Path $workspace 'project-docs/modified.txt'))) 'stale plan cannot restore'
    $result = (& $tool -WorkspaceRoot $workspace -RelativePaths $paths -Apply -ExpectedPlanDigest $plan.plan_digest | Out-String) | ConvertFrom-Json -Depth 20
    Assert-Equal 'restored' $result.status 'capture precedes restoration'
    Assert-Equal $head (Invoke-EwiGit $workspace @('rev-parse', 'HEAD')).StdOut.Trim() 'Agent HEAD is unchanged'
    Assert-Equal 'agent-baseline' ([IO.File]::ReadAllText((Join-Path $workspace 'project-docs/modified.txt'))) 'modified file restored'
    Assert-Equal 'agent-baseline' ([IO.File]::ReadAllText((Join-Path $workspace 'project-docs/deleted.txt'))) 'deletion restored'
    Assert-Equal $false (Test-Path -LiteralPath (Join-Path $workspace 'project-docs/added.txt')) 'addition moved into preserved branch'
    Assert-Equal 'agent-baseline' ([IO.File]::ReadAllText((Join-Path $workspace 'project-docs/staged.txt'))) 'staged and disk edits restored'
    $saved = $result.details.preserved_commit
    Assert-Equal 'user-saved' (Invoke-EwiGit $workspace @('show', "$saved`:project-docs/modified.txt")).StdOut 'user modification retained'
    Assert-Equal 'user-worktree' (Invoke-EwiGit $workspace @('show', "$saved`:project-docs/staged.txt")).StdOut 'user worktree retained'
    Assert-Equal 'user-index' (Invoke-EwiGit $workspace @('show', "$($result.details.preserved_index_commit)`:project-docs/staged.txt")).StdOut 'user staging retained separately'
    Assert-Equal 'user-index-only' (Invoke-EwiGit $workspace @('show', "$($result.details.preserved_index_commit)`:project-docs/staged-only.txt")).StdOut 'index-only edits retained'
    Assert-Equal 'agent-baseline' (Invoke-EwiGit $workspace @('show', ':project-docs/staged-only.txt')).StdOut 'index-only edits restored'
    Assert-Equal 'user-addition' (Invoke-EwiGit $workspace @('show', "$saved`:project-docs/added.txt")).StdOut 'user addition retained'
    Assert-Equal '' (Invoke-EwiGit $workspace @('ls-tree', '-r', '--name-only', $saved, '--', 'project-docs/deleted.txt')).StdOut.Trim() 'user deletion retained'
    Assert-Equal 'agent-staged-unrelated' (Invoke-EwiGit $workspace @('show', ':project-docs/unrelated.txt')).StdOut 'unrelated staged Agent content retained'
    Assert-Equal 'agent-baseline' (Invoke-EwiGit $workspace @('show', "$saved`:project-docs/unrelated.txt")).StdOut 'unrelated Agent edits excluded from preservation'
    Assert-Equal 5 (Invoke-EwiGit $workspace @('cat-file', '-s', "$saved`:project-docs/binary.dat")).StdOut.Trim() 'binary saved byte-for-byte'
    Assert-Equal $true (Test-Path -LiteralPath (Join-Path $workspace $result.evidence)) 'recovery evidence recorded'
    Write-Text (Join-Path $workspace 'project-docs/secret.txt') '-----BEGIN PRIVATE KEY-----'
    Assert-Throws { & $tool -WorkspaceRoot $workspace -RelativePaths 'project-docs/secret.txt' | Out-Null } 'Sensitive or ambiguous'
    Assert-Throws { & $tool -WorkspaceRoot $workspace -RelativePaths 'workspace-management/config/targets.local.json' | Out-Null } 'Ignored content'

    $legacy = Join-Path $testRoot 'legacy'
    Write-Text (Join-Path $legacy 'AGENTS.md') 'old instructions'
    Write-Text (Join-Path $legacy 'workspace-management/README.md') 'old management conversation'
    Write-Text (Join-Path $legacy 'plan.md') 'current product facts'
    $mappings = @(
        @{ source_relative = 'plan.md'; destination_relative = 'project-docs/imported/plan.md'; classification = 'product' },
        @{ source_relative = 'workspace-management'; action = 'preserve-only'; classification = 'unwanted-management' }
    ) | ConvertTo-Json -Depth 10 -Compress
    $destination = Join-Path $testRoot 'migration'
    $migrationPlan = (& (Join-Path $PSScriptRoot 'plan-migration.ps1') -WorkspaceRoot $destination -LegacyWorkspaceRoot $legacy -CopyMappingsJson $mappings -LegacyRuleDisposition preserve-only -RegisterLegacyWorkspace:$false | Out-String) | ConvertFrom-Json -Depth 20
    Assert-Equal $true $migrationPlan.can_apply 'explicit legacy exclusions are applicable'
    $migration = (& (Join-Path $PSScriptRoot 'apply-migration.ps1') -PlanBase64 $migrationPlan.plan_base64 -ApprovalDigest $migrationPlan.approval_digest | Out-String) | ConvertFrom-Json -Depth 20
    Assert-Equal 'active' $migration.status 'excluded-rule migration activates'
    Assert-Equal $false (Test-Path -LiteralPath (Join-Path $destination 'workspace-management/history/legacy-instructions/manifest.json')) 'no rule archive manifest created'
    Assert-Equal 0 @(Get-ChildItem -LiteralPath (Join-Path $destination 'workspace-management/history/legacy-instructions') -Filter '*.txt').Count 'no old rule bodies copied'
    $local = Get-Content -LiteralPath (Join-Path $destination 'workspace-management/config/targets.local.json') -Raw | ConvertFrom-Json
    Assert-Equal 0 @($local.legacy_workspaces.PSObject.Properties).Count 'old path is not a live binding'
    Assert-Equal 'old instructions' ([IO.File]::ReadAllText((Join-Path $legacy 'AGENTS.md'))) 'legacy remains unchanged'
    [pscustomobject]@{ status = 'passed'; assertions = $assertions } | ConvertTo-Json
}
finally {
    $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if (-not $resolvedTestRoot.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Test cleanup escaped the temporary root.' }
    if (Test-Path -LiteralPath $resolvedTestRoot) { Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force }
}
