[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('ewipc-' + [Guid]::NewGuid().ToString('N').Substring(0,8))
$assertions = 0
function Assert-Copy([bool] $Condition, [string] $Message) { if (-not $Condition) { throw "Assertion failed: $Message" }; $script:assertions++ }
function Write-CopyFile([string] $Path, [string] $Text) { $null = New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force; [IO.File]::WriteAllText($Path,$Text,[Text.UTF8Encoding]::new($false)) }
function Run-Copy([string] $TaskId, [string[]] $Ids, [string] $Action, [bool] $Apply = $true) {
    $args = @{WorkspaceRoot=$workspace;WorkstreamId=$TaskId;SourceId='source';ProjectId=$Ids;Action=$Action}
    $plan = & (Join-Path $PSScriptRoot 'manage-project-copy.ps1') @args | ConvertFrom-Json -Depth 50
    if ($Apply -and $plan.can_apply -and $plan.changed) { return & (Join-Path $PSScriptRoot 'manage-project-copy.ps1') @args -Apply -ExpectedPlanDigest $plan.plan_digest | ConvertFrom-Json -Depth 50 }
    return $plan
}
function New-CopyTask([string] $Title, [string] $ScopePath = 'mcu-a') {
    $scope = @(@{source_id='source';targets=@();paths=@(@{path=$ScopePath;access='write'})}) | ConvertTo-Json -Depth 12 -Compress
    return & (Join-Path $PSScriptRoot 'new-workstream.ps1') -WorkspaceRoot $workspace -Title $Title -ScopeJson $scope | ConvertFrom-Json -Depth 30
}
try {
    $source = Join-Path $testRoot 'source'; $workspace = Join-Path $testRoot 'workspace'
    foreach ($name in @('mcu-a','mcu-b')) {
        Write-CopyFile (Join-Path $source "$name/$name.ioc") 'Mcu.Name=Synthetic'
        Write-CopyFile (Join-Path $source "$name/Makefile") "all:`n`t@echo synthetic`n"
        Write-CopyFile (Join-Path $source "$name/main.c") "int $($name.Replace('-','_')) = 1;`n"
    }
    Write-CopyFile (Join-Path $source 'protocol/common.h') "#define PROTOCOL 1`n"
    Write-CopyFile (Join-Path $source 'protocol.h') "#define ROOT_PROTOCOL 1`n"
    $null = & (Join-Path $PSScriptRoot 'init-workspace.ps1') -WorkspaceRoot $workspace -UserSourcePath $source
    foreach ($name in @('mcu-a','mcu-b')) {
        $arguments = @{WorkspaceRoot=$workspace;SourceId='source';ProjectId=$name;ProjectRoot=$name;SharedPath=@('protocol','protocol.h')}
        $definition = & (Join-Path $PSScriptRoot 'set-source-project.ps1') @arguments | ConvertFrom-Json -Depth 30
        $null = & (Join-Path $PSScriptRoot 'set-source-project.ps1') @arguments -Apply -ExpectedPlanDigest $definition.plan_digest
    }
    $docs = & (Join-Path $PSScriptRoot 'new-workstream.ps1') -WorkspaceRoot $workspace -Title 'Docs only' | ConvertFrom-Json -Depth 20
    Assert-Copy (-not (Test-Path (Join-Path $workspace "$($docs.path)/sources/source"))) 'document workstream creates no engineering worktree'
    $docsFinished = & (Join-Path $PSScriptRoot 'update-workstream.ps1') -WorkspaceRoot $workspace -WorkstreamId $docs.workstream_id -Status completed -HasUnresolvedChanges $false | ConvertFrom-Json -Depth 40
    Assert-Copy ($docsFinished.workstream_status -eq 'completed') 'document-only task completes with an empty source scope'
    $docsAgain = & (Join-Path $PSScriptRoot 'update-workstream.ps1') -WorkspaceRoot $workspace -WorkstreamId $docs.workstream_id -Status completed -HasUnresolvedChanges $false | ConvertFrom-Json -Depth 40
    Assert-Copy ($docsAgain.status -eq 'unchanged') 'repeated document completion remains unchanged'
    $task = New-CopyTask 'Two projects'
    $tree = Join-Path $workspace "$($task.path)/sources/source"
    Assert-Copy (-not (Test-Path $tree)) 'source read/write scope alone creates no engineering files'
    $headBefore = (& git -C $workspace rev-parse HEAD | Out-String).Trim()
    $plan = Run-Copy $task.workstream_id @('mcu-a') 'Mount' $false
    Assert-Copy ($plan.can_apply -and -not (Test-Path $tree)) 'mount planning is zero-write'
    Assert-Copy ($headBefore -eq ((& git -C $workspace rev-parse HEAD | Out-String).Trim())) 'mount planning does not create a Git commit'
    $mount = Run-Copy $task.workstream_id @('mcu-a') 'Mount'
    Assert-Copy ($mount.status -eq 'mounted') 'first engineering project mounts'
    Assert-Copy ((Test-Path "$tree/mcu-a/main.c") -and -not (Test-Path "$tree/mcu-b")) 'mount checks out only selected project'
    Assert-Copy ((Test-Path "$tree/protocol/common.h") -and (Test-Path "$tree/protocol.h")) 'directory and individual-file dependencies are present'
    Write-CopyFile "$tree/mcu-a/main.c" "int mcu_a = 2;`n"
    $mount = Run-Copy $task.workstream_id @('mcu-b') 'Mount'
    Assert-Copy ((Test-Path "$tree/mcu-b/main.c") -and [IO.File]::ReadAllText("$tree/mcu-a/main.c").Contains('= 2')) 'adding a project preserves existing uncommitted changes'
    $blocked = Run-Copy $task.workstream_id @('mcu-a') 'Release' $false
    Assert-Copy (-not $blocked.can_apply) 'uncommitted project changes block its release'
    $released = Run-Copy $task.workstream_id @('mcu-b') 'Release'
    Assert-Copy ($released.status -eq 'released' -and -not (Test-Path "$tree/mcu-b")) 'another project can release while the retained project is dirty'
    Assert-Copy (Test-Path "$tree/protocol/common.h") 'dependency used by retained project remains'
    $null = & git -C $tree add -- 'mcu-a/main.c'
    $null = & git -C $tree commit -m 'feat: synthetic task'
    Write-CopyFile "$tree/mcu-a/report.txt" 'unique report'
    Write-CopyFile "$tree/mcu-a/.gitignore" "*.bin`n"
    $null = & git -C $tree add -- 'mcu-a/.gitignore'; $null = & git -C $tree commit -m 'test: ignore runtime binary'
    Write-CopyFile "$tree/mcu-a/kept-report.txt" 'registered tracked output'
    $null = & git -C $tree add -- 'mcu-a/kept-report.txt'; $null = & git -C $tree commit -m 'test: tracked build report'
    Import-Module (Join-Path $PSScriptRoot 'lib/workspace-common.psm1') -Force
    $fixtureTargetsPath = Join-Path $workspace 'workspace-management/config/targets.json'
    $fixtureTargets = Read-EwiJson $fixtureTargetsPath
    $fixtureTarget = @($fixtureTargets.targets.PSObject.Properties | Where-Object { $_.Value.path -eq 'mcu-a' })[0]
    $fixtureTarget.Value.builds | Add-Member -NotePropertyName fixture -NotePropertyValue ([pscustomobject]@{configuration='fixture';cwd='.';default_execution_context='agent-copy';command=[pscustomobject]@{tool='fixture';args=@()};command_state='unconfirmed';output_paths=@('kept-report.txt');generated_write_paths=@();outputs=@()})
    $fixtureTargets.field_metadata | Add-Member -NotePropertyName "/targets/$($fixtureTarget.Name)/builds/fixture/output_paths" -NotePropertyValue ([pscustomobject]@{provenance='confirmed';verification='unverified';freshness='current'})
    Write-EwiJsonAtomic $fixtureTargetsPath $fixtureTargets -SchemaPath (Join-Path $workspace 'workspace-management/schemas/targets.schema.json')
    [IO.File]::WriteAllBytes("$tree/mcu-a/firmware.bin", [byte[]]@(0,1,2,255))
    $expected = (& git -C $tree hash-object -- 'mcu-a/main.c' | Out-String).Trim()
    $released = Run-Copy $task.workstream_id @('mcu-a') 'Release'
    Assert-Copy ($released.status -eq 'released' -and -not (Test-Path $tree)) 'last release removes physical worktree'
    Assert-Copy ((Test-Path (Join-Path $workspace "$($released.preserved_at)/mcu-a/report.txt")) -and (Test-Path (Join-Path $workspace "$($released.preserved_at)/mcu-a/firmware.bin"))) 'untracked and ignored artifacts survive outside engineering copy'
    Assert-Copy (Test-Path (Join-Path $workspace "$($released.preserved_at)/mcu-a/kept-report.txt")) 'registered tracked build output also survives outside engineering copy'
    $again = Run-Copy $task.workstream_id @('mcu-a') 'Release'
    Assert-Copy (-not $again.changed) 'repeated release is idempotent'
    $mount = Run-Copy $task.workstream_id @('mcu-a') 'Mount'
    Assert-Copy ($expected -eq ((& git -C $tree hash-object -- 'mcu-a/main.c' | Out-String).Trim())) 'released project restores exact committed contents'
    Assert-Copy (-not (Test-Path "$tree/mcu-b")) 'restoration does not check out unrelated released engineering project'
    # A released upstream remains available as a pinned Git dependency.
    $released = Run-Copy $task.workstream_id @('mcu-a') 'Release'
    $consumer = New-CopyTask 'Consumer' 'mcu-b'
    $null = Run-Copy $consumer.workstream_id @('mcu-b') 'Mount'
    $pin = & (Join-Path $PSScriptRoot 'pin-workstream-dependency.ps1') -WorkspaceRoot $workspace -WorkstreamId $consumer.workstream_id -DependencyWorkstreamId $task.workstream_id -Apply | ConvertFrom-Json -Depth 40
    Assert-Copy ($pin.status -eq 'pinned') 'released upstream can supply pinned dependency commits'
    Assert-Copy (-not (Test-Path $tree)) 'dependency pin does not restore upstream physical copy'
    $consumerTree = Join-Path $workspace "$($consumer.path)/sources/source"
    Assert-Copy (-not (Test-Path "$consumerTree/mcu-a")) 'dependency merge retains consumer sparse boundary'
    # Automatic release happens only at a clean formal completion.
    $null = & (Join-Path $PSScriptRoot 'update-workstream.ps1') -WorkspaceRoot $workspace -WorkstreamId $consumer.workstream_id -Status completed -HasUnresolvedChanges $false
    Assert-Copy (-not (Test-Path $consumerTree)) 'formal completion automatically releases clean engineering copies'
    $null = & (Join-Path $PSScriptRoot 'update-workstream.ps1') -WorkspaceRoot $workspace -WorkstreamId $task.workstream_id -Status completed -HasUnresolvedChanges $false
    $fresh = New-CopyTask 'Sparse import' 'mcu-a'
    $null = Run-Copy $fresh.workstream_id @('mcu-a') 'Mount'
    Write-CopyFile (Join-Path $source 'mcu-b/main.c') "int mcu_b = 3;`n"
    $import = & (Join-Path $PSScriptRoot 'import-sources.ps1') -WorkspaceRoot $workspace -SourceId source -Apply | ConvertFrom-Json -Depth 40
    Assert-Copy ($import.status -eq 'imported') 'sparse active task accepts user import'
    $freshTree = Join-Path $workspace "$($fresh.path)/sources/source"
    Assert-Copy (-not (Test-Path "$freshTree/mcu-b")) 'import does not materialize unselected project'
    $publish = & (Join-Path $PSScriptRoot 'publish-workstream.ps1') -WorkspaceRoot $workspace -WorkstreamId $fresh.workstream_id | ConvertFrom-Json -Depth 40
    Assert-Copy (@($publish.files).Count -eq 0) 'unselected project absence never creates a publish deletion'
    Write-CopyFile "$freshTree/mcu-a/main.c" "int mcu_a = 5;`r`n"
    $null = & git -C $freshTree add -- 'mcu-a/main.c'; $null = & git -C $freshTree commit -m 'test: sparse publish'
    $otherProjectHash = (Get-FileHash (Join-Path $source 'mcu-b/main.c')).Hash
    $publish = & (Join-Path $PSScriptRoot 'publish-workstream.ps1') -WorkspaceRoot $workspace -WorkstreamId $fresh.workstream_id | ConvertFrom-Json -Depth 40
    Assert-Copy ($publish.can_apply -and @($publish.files).Count -eq 1 -and $publish.files[0].relative_path -eq 'mcu-a/main.c') 'sparse publish freezes only selected project changes'
    $published = & (Join-Path $PSScriptRoot 'publish-workstream.ps1') -WorkspaceRoot $workspace -WorkstreamId $fresh.workstream_id -Apply -ExpectedManifestDigest $publish.manifest_digest | ConvertFrom-Json -Depth 40
    Assert-Copy ($published.status -eq 'completed' -and $otherProjectHash -eq (Get-FileHash (Join-Path $source 'mcu-b/main.c')).Hash -and -not (Test-Path "$freshTree/mcu-b")) 'sparse publication preserves unselected user project and checkout boundary'
    # Plan digests reject file drift without changing state.
    $stale = Run-Copy $fresh.workstream_id @('mcu-a') 'Release' $false
    Write-CopyFile "$freshTree/mcu-a/main.c" 'changed after planning'
    $caught = $false
    try { $null = & (Join-Path $PSScriptRoot 'manage-project-copy.ps1') -WorkspaceRoot $workspace -WorkstreamId $fresh.workstream_id -SourceId source -ProjectId 'mcu-a' -Action Release -Apply -ExpectedPlanDigest $stale.plan_digest } catch { $caught = $_.Exception.Message -like '*stale*' }
    Assert-Copy $caught 'stale release plan refuses writes'
    $null = & git -C $freshTree restore -- 'mcu-a/main.c'
    # Failed metadata commit rolls the engineering selection and artifacts back.
    $beforeManifest = [IO.File]::ReadAllText((Join-Path $workspace "$($fresh.path)/workstream.json"))
    Write-CopyFile "$freshTree/mcu-a/failure-report.txt" 'must survive rollback'
    Write-CopyFile (Join-Path $workspace '.git/hooks/pre-commit') "#!/bin/sh`nexit 1`n"
    $releasePlan = Run-Copy $fresh.workstream_id @('mcu-a') 'Release' $false
    $failed = $false
    try { $null = & (Join-Path $PSScriptRoot 'manage-project-copy.ps1') -WorkspaceRoot $workspace -WorkstreamId $fresh.workstream_id -SourceId source -ProjectId 'mcu-a' -Action Release -Apply -ExpectedPlanDigest $releasePlan.plan_digest } catch { $failed = $true }
    [IO.File]::Delete((Join-Path $workspace '.git/hooks/pre-commit'))
    Assert-Copy $failed 'injected checkpoint failure is reported'
    Assert-Copy ((Test-Path "$freshTree/mcu-a/main.c") -and [IO.File]::ReadAllText("$freshTree/mcu-a/failure-report.txt") -eq 'must survive rollback') 'failed release restores engineering files and unique artifacts'
    Assert-Copy ($beforeManifest -ceq [IO.File]::ReadAllText((Join-Path $workspace "$($fresh.path)/workstream.json"))) 'failed release restores exact manifest'
    # Active released branches import through an empty temporary checkout.
    $released = Run-Copy $fresh.workstream_id @('mcu-a') 'Release'
    Write-CopyFile (Join-Path $source 'mcu-b/main.c') "int mcu_b = 4;`n"
    $import = & (Join-Path $PSScriptRoot 'import-sources.ps1') -WorkspaceRoot $workspace -SourceId source -Apply | ConvertFrom-Json -Depth 40
    Assert-Copy ($import.status -eq 'imported' -and -not (Test-Path $freshTree)) 'active released branch rebases without retained physical checkout'
    $null = Run-Copy $fresh.workstream_id @('mcu-a') 'Mount'
    $null = & (Join-Path $PSScriptRoot 'update-workstream.ps1') -WorkspaceRoot $workspace -WorkstreamId $fresh.workstream_id -Status paused -HasUnresolvedChanges $true
    $pausedRelease = Run-Copy $fresh.workstream_id @('mcu-a') 'Release' $false
    Assert-Copy (-not $pausedRelease.can_apply -and (Test-Path $freshTree)) 'paused unresolved task retains engineering copy'
    # Upgrade a synthetic old policy without touching a dirty paused source file.
    Write-CopyFile "$freshTree/mcu-a/main.c" 'paused edit must remain byte-identical'
    $pausedHash = (Get-FileHash "$freshTree/mcu-a/main.c").Hash
    Import-Module (Join-Path $PSScriptRoot 'lib/workspace-common.psm1') -Force
    $configPath = Join-Path $workspace 'workspace-management/config/workspace.json'
    $oldConfig = Read-EwiJson $configPath; $oldConfig.workspace_schema=1; $oldConfig.policy_version=1
    Write-EwiJsonAtomic $configPath $oldConfig -SchemaPath (Join-Path $workspace 'workspace-management/schemas/workspace.schema.json')
    $targetsPath = Join-Path $workspace 'workspace-management/config/targets.json'
    $oldTargets = Read-EwiJson $targetsPath; $oldTargets.schema=1
    foreach ($sp in $oldTargets.sources.PSObject.Properties) { $sp.Value.PSObject.Properties.Remove('projects') }
    foreach ($tp in $oldTargets.targets.PSObject.Properties) { $tp.Value.PSObject.Properties.Remove('project_id') }
    Write-EwiJsonAtomic $targetsPath $oldTargets -SchemaPath (Join-Path $workspace 'workspace-management/schemas/targets.schema.json')
    $oldManifestPath = Join-Path $workspace "$($fresh.path)/workstream.json"
    $oldManifest = Read-EwiJson $oldManifestPath; $oldManifest.schema=1
    $oldManifest.agent.refs.source.PSObject.Properties.Remove('checkout_state'); $oldManifest.agent.refs.source.PSObject.Properties.Remove('projects')
    Write-EwiJsonAtomic $oldManifestPath $oldManifest -SchemaPath (Join-Path $workspace 'workspace-management/schemas/workstream.schema.json')
    $upgrade = & (Join-Path $PSScriptRoot 'plan-migration.ps1') -WorkspaceRoot $workspace -PolicyUpgrade | ConvertFrom-Json -Depth 60
    Assert-Copy ($upgrade.can_apply -and $upgrade.summary.state_operations.Count -ge 3) 'policy 1-to-2 plan includes exact state transformations'
    $applied = & (Join-Path $PSScriptRoot 'apply-policy-upgrade.ps1') -PlanBase64 $upgrade.plan_base64 -ApprovalDigest $upgrade.approval_digest | ConvertFrom-Json -Depth 40
    Assert-Copy ($applied.status -eq 'upgraded') 'explicit policy 1-to-2 migration applies'
    Assert-Copy ($pausedHash -eq (Get-FileHash "$freshTree/mcu-a/main.c").Hash) 'migration preserves dirty paused bytes'
    $migrated = Read-EwiJson $oldManifestPath
    Assert-Copy ($migrated.agent.refs.source.checkout_state -eq 'legacy-full' -and $migrated.has_unresolved_changes) 'old physical checkout is marked legacy without shrinking it'
    $upgradeAgain = & (Join-Path $PSScriptRoot 'plan-migration.ps1') -WorkspaceRoot $workspace -PolicyUpgrade | ConvertFrom-Json -Depth 60
    Assert-Copy (-not $upgradeAgain.can_apply -and $upgradeAgain.summary.state_operations.Count -eq 0) 'repeated migration has no operations'
    [pscustomobject]@{status='passed';assertions=$assertions} | ConvertTo-Json
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        $resolved = [IO.Path]::GetFullPath($testRoot)
        if ([IO.Path]::GetDirectoryName($resolved).TrimEnd('\') -ne [IO.Path]::GetTempPath().TrimEnd('\') -or -not [IO.Path]::GetFileName($resolved).StartsWith('ewipc-')) { throw 'Unexpected fixture cleanup path.' }
        Get-ChildItem -LiteralPath $resolved -Recurse -Force | ForEach-Object { $_.Attributes='Normal' }
        [IO.Directory]::Delete($resolved,$true)
    }
}
