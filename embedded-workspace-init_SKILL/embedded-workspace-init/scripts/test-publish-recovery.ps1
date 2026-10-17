[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'fixture-project-copies.ps1')

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('ewipr-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$assertions = 0
$oldGitConfigCount = $env:GIT_CONFIG_COUNT
$oldGitConfigKey = $env:GIT_CONFIG_KEY_0
$oldGitConfigValue = $env:GIT_CONFIG_VALUE_0

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

function Write-Utf8Text {
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [string] $Text)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) { $null = New-Item -ItemType Directory -Path $parent }
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function Add-Build {
    param($Builds, [string] $Id, [string] $Script, [string[]] $OutputPaths, [string[]] $GeneratedPaths, [string[]] $Outputs)
    $Builds | Add-Member -NotePropertyName $Id -NotePropertyValue ([pscustomobject][ordered]@{
        configuration = $Id
        cwd = '.'
        default_execution_context = 'agent-copy'
        command = [pscustomobject][ordered]@{
            tool = 'pwsh'
            args = @('-NoProfile', '-NonInteractive', '-File', $Script)
        }
        command_state = 'candidate'
        output_paths = @($OutputPaths)
        generated_write_paths = @($GeneratedPaths)
        outputs = @($Outputs)
    })
}

function Get-SourceState {
    param($Fixture)
    Get-Content -Raw -LiteralPath (Join-Path $Fixture.workspace 'workspace-management\sync-state\sources\source.json') | ConvertFrom-Json -Depth 40
}

function Get-Transaction {
    param($Fixture, [string] $PublishId)
    Get-Content -Raw -LiteralPath (Join-Path $Fixture.workspace "workspace-management\sync-state\transactions\$PublishId.json") | ConvertFrom-Json -Depth 60
}

function New-Fixture {
    param([Parameter(Mandatory)] [string] $Name)

    $scenario = Join-Path $testRoot $Name
    $source = Join-Path $scenario 'source'
    $workspace = Join-Path $scenario 'workspace'
    Write-Utf8Text -Path (Join-Path $source 'Makefile') -Text "all:`r`n`t@echo synthetic`r`n"
    Write-Utf8Text -Path (Join-Path $source 'app\a.c') -Text "int a = 0;`r`n"
    Write-Utf8Text -Path (Join-Path $source 'app\z.c') -Text "int z = 0;`r`n"
    Write-Utf8Text -Path (Join-Path $source 'app\delete.c') -Text "int obsolete = 1;`r`n"
    Write-Utf8Text -Path (Join-Path $source 'generated\version.h') -Text "#define VERSION 1`r`n"
    Write-Utf8Text -Path (Join-Path $source 'build-output.ps1') -Text @'
$directory = Join-Path $PSScriptRoot 'out'
$null = New-Item -ItemType Directory -Path $directory -Force
[IO.File]::WriteAllText((Join-Path $directory 'firmware.bin'), [Guid]::NewGuid().ToString('N'))
'@
    Write-Utf8Text -Path (Join-Path $source 'build-fail.ps1') -Text "exit 7`r`n"
    Write-Utf8Text -Path (Join-Path $source 'build-generated.ps1') -Text @'
$directory = Join-Path $PSScriptRoot 'out'
$null = New-Item -ItemType Directory -Path $directory -Force
[IO.File]::WriteAllText((Join-Path $directory 'firmware.bin'), [Guid]::NewGuid().ToString('N'))
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'generated/version.h'), ('#define VERSION ' + [DateTimeOffset]::Now.ToUnixTimeMilliseconds()))
'@
    Write-Utf8Text -Path (Join-Path $source 'build-generated-fail.ps1') -Text @'
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'generated/version.h'), '#define VERSION FAILED')
exit 8
'@
    Write-Utf8Text -Path (Join-Path $source 'build-unknown.ps1') -Text @'
$directory = Join-Path $PSScriptRoot 'out'
$null = New-Item -ItemType Directory -Path $directory -Force
[IO.File]::WriteAllText((Join-Path $directory 'firmware.bin'), [Guid]::NewGuid().ToString('N'))
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'unknown-side-effect.txt'), 'unexpected')
'@
    Write-Utf8Text -Path (Join-Path $source 'Debug\stale.o') -Text 'stale debug object'
    Write-Utf8Text -Path (Join-Path $source 'out\stale.bin') -Text 'stale output'
    Write-Utf8Text -Path (Join-Path $source 'out\firmware.bin') -Text 'previous firmware'

    $init = (& (Join-Path $PSScriptRoot 'init-workspace.ps1') -WorkspaceRoot $workspace -UserSourcePath $source | Out-String) | ConvertFrom-Json -Depth 40
    if ($init.status -ne 'active') { throw "Fixture did not activate: $Name" }
    $integration = Join-Path $workspace 'sources\source\integration'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $integration 'Debug'))) 'Debug cache must not enter the integration baseline'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $integration 'out'))) 'out cache must not enter the integration baseline'

    Import-Module (Join-Path $workspace 'workspace-management\tools\lib\workspace-common.psm1') -Force
    $targetsPath = Join-Path $workspace 'workspace-management\config\targets.json'
    $localPath = Join-Path $workspace 'workspace-management\config\targets.local.json'
    $targets = Read-EwiJson -Path $targetsPath -SchemaPath (Join-Path $workspace 'workspace-management\schemas\targets.schema.json')
    $local = Read-EwiJson -Path $localPath -SchemaPath (Join-Path $workspace 'workspace-management\schemas\targets-local.schema.json')
    $targetId = @($targets.targets.PSObject.Properties.Name)[0]
    $builds = $targets.targets.PSObject.Properties[$targetId].Value.builds
    Add-Build -Builds $builds -Id 'output' -Script 'build-output.ps1' -OutputPaths @('out') -GeneratedPaths @() -Outputs @('out/firmware.bin')
    Add-Build -Builds $builds -Id 'fail' -Script 'build-fail.ps1' -OutputPaths @('out') -GeneratedPaths @() -Outputs @('out/firmware.bin')
    Add-Build -Builds $builds -Id 'generated' -Script 'build-generated.ps1' -OutputPaths @('out') -GeneratedPaths @('generated/version.h') -Outputs @('out/firmware.bin')
    Add-Build -Builds $builds -Id 'generated-fail' -Script 'build-generated-fail.ps1' -OutputPaths @('out') -GeneratedPaths @('generated/version.h') -Outputs @('out/firmware.bin')
    Add-Build -Builds $builds -Id 'unknown' -Script 'build-unknown.ps1' -OutputPaths @('out') -GeneratedPaths @() -Outputs @('out/firmware.bin')
    foreach ($configuredBuildId in @('output', 'fail', 'generated', 'generated-fail', 'unknown')) {
        foreach ($field in @('output_paths', 'generated_write_paths')) {
            if (@($builds.PSObject.Properties[$configuredBuildId].Value.$field).Count -eq 0) { continue }
            $targets.field_metadata | Add-Member -NotePropertyName "/targets/$targetId/builds/$configuredBuildId/$field" -NotePropertyValue ([pscustomobject][ordered]@{ provenance = 'confirmed'; verification = 'unverified'; freshness = 'current' })
        }
    }
    $local.tools | Add-Member -NotePropertyName pwsh -NotePropertyValue ([pscustomobject][ordered]@{
        executable = (Get-Process -Id $PID).Path
        version = $PSVersionTable.PSVersion.ToString()
    })
    Write-EwiJsonAtomic -Path $targetsPath -Value $targets -SchemaPath (Join-Path $workspace 'workspace-management\schemas\targets.schema.json')
    Write-EwiJsonAtomic -Path $localPath -Value $local -SchemaPath (Join-Path $workspace 'workspace-management\schemas\targets-local.schema.json')

    $scope = @([ordered]@{ source_id = 'source'; targets = @($targetId); paths = @([ordered]@{ path = '.'; access = 'write' }) }) | ConvertTo-Json -Depth 10 -Compress
    $workstream = (& (Join-Path $PSScriptRoot 'new-workstream.ps1') -WorkspaceRoot $workspace -Title $Name -ScopeJson $scope | Out-String) | ConvertFrom-Json -Depth 40
    Mount-FixtureProjectCopies -WorkspaceRoot $workspace -Workstream $workstream
    $manifest = Get-Content -Raw -LiteralPath (Join-Path $workspace "$($workstream.path)\workstream.json") | ConvertFrom-Json -Depth 40
    return [pscustomobject][ordered]@{
        source = $source
        workspace = $workspace
        integration = $integration
        target_id = $targetId
        workstream_id = $workstream.workstream_id
        worktree = Join-Path $workspace $manifest.agent.refs.source.worktree
        original_baseline = (Get-SourceState ([pscustomobject]@{ workspace = $workspace })).user_baseline_commit
    }
}

function Commit-TaskChanges {
    param($Fixture, [string[]] $Paths = @('app/a.c'))
    foreach ($path in $Paths) {
        switch ($path) {
            'app/a.c' { Write-Utf8Text -Path (Join-Path $Fixture.worktree $path) -Text "int a = 7;`r`n" }
            'app/z.c' { Write-Utf8Text -Path (Join-Path $Fixture.worktree $path) -Text "int z = 9;`r`n" }
            'app/new.c' { Write-Utf8Text -Path (Join-Path $Fixture.worktree $path) -Text "int added = 1;`r`n" }
            'app/delete.c' { [IO.File]::Delete((Join-Path $Fixture.worktree $path)) }
        }
    }
    $null = & git -C $Fixture.worktree add --all -- @($Paths)
    $null = & git -C $Fixture.worktree commit -m 'feat: synthetic task change'
}

function Start-PublishWithBuild {
    param($Fixture)
    $plan = (& (Join-Path $PSScriptRoot 'publish-workstream.ps1') -WorkspaceRoot $Fixture.workspace -WorkstreamId $Fixture.workstream_id | Out-String) | ConvertFrom-Json -Depth 60
    Assert-True $plan.can_apply 'the synthetic publish plan must be applicable'
    $result = (& (Join-Path $PSScriptRoot 'publish-workstream.ps1') -WorkspaceRoot $Fixture.workspace -WorkstreamId $Fixture.workstream_id -ExpectedManifestDigest $plan.manifest_digest -Apply -RequireUserBuild | Out-String) | ConvertFrom-Json -Depth 60
    Assert-Equal 'awaiting-user-build' $result.status 'publish must stop after file verification when a user build is required'
    Assert-Equal $Fixture.original_baseline (Get-SourceState $Fixture).user_baseline_commit 'the user baseline must not advance before build finalization'
    $workstream = Get-Content -Raw -LiteralPath (Join-Path $Fixture.workspace "work\$($Fixture.workstream_id)\workstream.json") | ConvertFrom-Json -Depth 40
    $transaction = Get-Transaction $Fixture $result.publish_id
    Assert-Equal $transaction.head_commits.source $workstream.agent.refs.source.head_commit 'awaiting-user-build must record the frozen head in workstream.json'
    return $result
}

try {
    $env:GIT_CONFIG_COUNT = '1'
    $env:GIT_CONFIG_KEY_0 = 'core.autocrlf'
    $env:GIT_CONFIG_VALUE_0 = 'true'

    Write-Host '[1/8] stale-plan'
    $stale = New-Fixture 'stale'
    Commit-TaskChanges $stale @('app/a.c', 'app/z.c')
    $stalePlan = (& (Join-Path $PSScriptRoot 'publish-workstream.ps1') -WorkspaceRoot $stale.workspace -WorkstreamId $stale.workstream_id | Out-String) | ConvertFrom-Json -Depth 60
    Write-Utf8Text -Path (Join-Path $stale.source 'app\a.c') -Text "int a = 100;`r`n"
    Assert-Throws -Pattern 'Publish plan is blocked' -Action {
        & (Join-Path $PSScriptRoot 'publish-workstream.ps1') -WorkspaceRoot $stale.workspace -WorkstreamId $stale.workstream_id -ExpectedManifestDigest $stalePlan.manifest_digest -Apply | Out-Null
    }
    Assert-Equal 0 @(Get-ChildItem -LiteralPath (Join-Path $stale.workspace 'workspace-management\sync-state\transactions') -Filter '*.json').Count 'a stale plan must create no transaction'
    Assert-Equal "int z = 0;`r`n" ([IO.File]::ReadAllText((Join-Path $stale.source 'app\z.c'))) 'a stale plan must write no unaffected authority file'

    Write-Host '[2/8] mid-apply-rollback'
    $locked = New-Fixture 'lock'
    Commit-TaskChanges $locked @('app/a.c', 'app/z.c')
    $lockedManifest = Get-Content -Raw -LiteralPath (Join-Path $locked.workspace "work\$($locked.workstream_id)\workstream.json") | ConvertFrom-Json -Depth 40
    $lockedBase = [string]$lockedManifest.agent.refs.source.task_base_commit
    $lockedHead = (& git -C $locked.worktree rev-parse HEAD | Out-String).Trim()
    $null = & git -C $locked.worktree cat-file -e "$lockedBase^{commit}"
    Assert-Equal 0 $LASTEXITCODE 'the locked fixture base commit must be reachable'
    $null = & git -C $locked.worktree cat-file -e "$lockedHead^{commit}"
    Assert-Equal 0 $LASTEXITCODE 'the locked fixture head commit must be reachable'
    $lockedPlan = (& (Join-Path $PSScriptRoot 'publish-workstream.ps1') -WorkspaceRoot $locked.workspace -WorkstreamId $locked.workstream_id | Out-String) | ConvertFrom-Json -Depth 60
    $lockedFile = Join-Path $locked.source 'app\z.c'
    $stream = [IO.File]::Open($lockedFile, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        Assert-Throws -Pattern 'Access to the path' -Action {
            & (Join-Path $PSScriptRoot 'publish-workstream.ps1') -WorkspaceRoot $locked.workspace -WorkstreamId $locked.workstream_id -ExpectedManifestDigest $lockedPlan.manifest_digest -Apply | Out-Null
        }
    }
    finally { $stream.Dispose() }
    $lockedTransactionFiles = @(Get-ChildItem -LiteralPath (Join-Path $locked.workspace 'workspace-management\sync-state\transactions') -Filter '*.json')
    Assert-Equal 1 $lockedTransactionFiles.Count 'the failed apply must persist exactly one transaction'
    $lockedTransactionFile = $lockedTransactionFiles[0]
    $lockedTransaction = Get-Content -Raw -LiteralPath $lockedTransactionFile.FullName | ConvertFrom-Json -Depth 60
    Assert-Equal 'rolled_back' $lockedTransaction.state 'a mid-apply failure must roll back automatically'
    Assert-Equal "int a = 0;`r`n" ([IO.File]::ReadAllText((Join-Path $locked.source 'app\a.c'))) 'automatic rollback must restore an earlier applied file'
    Assert-Equal "int z = 0;`r`n" ([IO.File]::ReadAllText($lockedFile)) 'automatic rollback must preserve the file that failed to apply'
    Assert-Equal $locked.original_baseline (Get-SourceState $locked).user_baseline_commit 'automatic rollback must not advance the baseline'

    Write-Host '[3/8] file-operations'
    $operations = New-Fixture 'ops'
    Commit-TaskChanges $operations @('app/a.c', 'app/new.c', 'app/delete.c')
    $operationsPlan = (& (Join-Path $PSScriptRoot 'publish-workstream.ps1') -WorkspaceRoot $operations.workspace -WorkstreamId $operations.workstream_id | Out-String) | ConvertFrom-Json -Depth 60
    Assert-Equal 'add,delete,modify' ((@($operationsPlan.files.operation | Sort-Object -Unique)) -join ',') 'the manifest must distinguish add, delete, and modify'
    $operationsResult = (& (Join-Path $PSScriptRoot 'publish-workstream.ps1') -WorkspaceRoot $operations.workspace -WorkstreamId $operations.workstream_id -ExpectedManifestDigest $operationsPlan.manifest_digest -Apply | Out-String) | ConvertFrom-Json -Depth 60
    Assert-Equal 'completed' $operationsResult.status 'a three-operation publish must complete'
    Assert-True (Test-Path -LiteralPath (Join-Path $operations.source 'app\new.c')) 'published addition must exist'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $operations.source 'app\delete.c'))) 'published deletion must be absent'
    Assert-Equal "int a = 7;`r`n" ([IO.File]::ReadAllText((Join-Path $operations.source 'app\a.c'))) 'published modification must match the task'

    Write-Host '[4/8] failed-build-rollback'
    $rollback = New-Fixture 'rollback'
    Commit-TaskChanges $rollback
    $rollbackPublish = Start-PublishWithBuild $rollback
    $rollbackBuild = (& (Join-Path $PSScriptRoot 'invoke-build.ps1') -WorkspaceRoot $rollback.workspace -TargetId $rollback.target_id -BuildId 'fail' -BuildContext user-authority -PublishId $rollbackPublish.publish_id -AllowCandidate | Out-String) | ConvertFrom-Json -Depth 40
    Assert-Equal 'failed' $rollbackBuild.status 'the failing build must be recorded as failed'
    Assert-Equal 'verification_failed' (Get-Transaction $rollback $rollbackPublish.publish_id).state 'a failed build must preserve the published scene for a decision'
    $rollbackResult = (& (Join-Path $PSScriptRoot 'publish-workstream.ps1') -WorkspaceRoot $rollback.workspace -PublishId $rollbackPublish.publish_id -Rollback | Out-String) | ConvertFrom-Json
    Assert-Equal 'rolled_back' $rollbackResult.status 'the user rollback choice must restore the transaction'
    Assert-Equal "int a = 0;`r`n" ([IO.File]::ReadAllText((Join-Path $rollback.source 'app\a.c'))) 'rollback must restore the authority file'
    Assert-Equal $rollback.original_baseline (Get-SourceState $rollback).user_baseline_commit 'rollback must retain the original baseline'

    Write-Host '[5/8] failed-build-accept'
    $accept = New-Fixture 'accept'
    Commit-TaskChanges $accept
    $acceptPublish = Start-PublishWithBuild $accept
    $null = & (Join-Path $PSScriptRoot 'invoke-build.ps1') -WorkspaceRoot $accept.workspace -TargetId $accept.target_id -BuildId 'fail' -BuildContext user-authority -PublishId $acceptPublish.publish_id -AllowCandidate
    $acceptResult = (& (Join-Path $PSScriptRoot 'publish-workstream.ps1') -WorkspaceRoot $accept.workspace -PublishId $acceptPublish.publish_id -Finalize -AcceptUnverifiedBuild | Out-String) | ConvertFrom-Json -Depth 40
    $acceptState = Get-SourceState $accept
    Assert-Equal 'completed' $acceptResult.status 'explicit acceptance must complete a failed-build transaction'
    Assert-True ($acceptState.user_baseline_commit -ne $accept.original_baseline) 'explicit acceptance must advance only the user baseline'
    $acceptBuildBaseline = $acceptState.build_baselines.PSObject.Properties["$($accept.target_id)/fail"]
    Assert-True ($null -eq $acceptBuildBaseline -or $null -eq $acceptBuildBaseline.Value.last_successful_build_commit) 'explicit acceptance must not record build success'

    Write-Host '[6/8] recovery-required'
    $recovery = New-Fixture 'recover'
    Commit-TaskChanges $recovery
    $recoveryPublish = Start-PublishWithBuild $recovery
    $null = & (Join-Path $PSScriptRoot 'invoke-build.ps1') -WorkspaceRoot $recovery.workspace -TargetId $recovery.target_id -BuildId 'fail' -BuildContext user-authority -PublishId $recoveryPublish.publish_id -AllowCandidate
    Write-Utf8Text -Path (Join-Path $recovery.source 'app\a.c') -Text "int a = 999;`r`n"
    $recoveryResult = (& (Join-Path $PSScriptRoot 'publish-workstream.ps1') -WorkspaceRoot $recovery.workspace -PublishId $recoveryPublish.publish_id -Rollback | Out-String) | ConvertFrom-Json
    Assert-Equal 'recovery_required' $recoveryResult.status 'external drift before rollback must require manual recovery'
    Assert-Equal "int a = 999;`r`n" ([IO.File]::ReadAllText((Join-Path $recovery.source 'app\a.c'))) 'unsafe rollback must not overwrite external changes'
    $blockedPlan = (& (Join-Path $PSScriptRoot 'publish-workstream.ps1') -WorkspaceRoot $recovery.workspace -WorkstreamId $recovery.workstream_id | Out-String) | ConvertFrom-Json -Depth 40
    Assert-True (@($blockedPlan.blockers | Where-Object { $_ -like '*Nonterminal transaction blocks publish*' }).Count -eq 1) 'recovery_required must block another publish'

    Write-Host '[7/8] output-only-build'
    $output = New-Fixture 'output'
    Commit-TaskChanges $output
    $outputPublish = Start-PublishWithBuild $output
    $outputBuild = (& (Join-Path $PSScriptRoot 'invoke-build.ps1') -WorkspaceRoot $output.workspace -TargetId $output.target_id -BuildId 'output' -BuildContext user-authority -PublishId $outputPublish.publish_id -AllowCandidate | Out-String) | ConvertFrom-Json -Depth 40
    Assert-Equal 'passed' $outputBuild.status 'an output-only build must pass'
    Assert-Equal 'clean' $outputBuild.side_effect_status 'ordinary outputs must not become project side effects'
    $outputFinal = (& (Join-Path $PSScriptRoot 'publish-workstream.ps1') -WorkspaceRoot $output.workspace -PublishId $outputPublish.publish_id -Finalize | Out-String) | ConvertFrom-Json -Depth 40
    Assert-Equal 'completed' $outputFinal.status 'an output-only build must finalize'
    Assert-True (Test-Path -LiteralPath (Join-Path $output.source 'out\firmware.bin')) 'a disposable user build output may remain on disk'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $output.integration 'out\firmware.bin'))) 'a disposable output must not enter the source-private baseline'

    Write-Host '[8a/8] generated-success'
    $generated = New-Fixture 'genok'
    Commit-TaskChanges $generated
    $generatedPublish = Start-PublishWithBuild $generated
    $generatedBuild = (& (Join-Path $PSScriptRoot 'invoke-build.ps1') -WorkspaceRoot $generated.workspace -TargetId $generated.target_id -BuildId 'generated' -BuildContext user-authority -PublishId $generatedPublish.publish_id -AllowCandidate | Out-String) | ConvertFrom-Json -Depth 40
    Assert-Equal 'passed' $generatedBuild.status 'a successful declared generated write must pass'
    Assert-Equal 'declared' $generatedBuild.side_effect_status 'a confirmed generated write must be classified as declared'
    $generatedFinal = (& (Join-Path $PSScriptRoot 'publish-workstream.ps1') -WorkspaceRoot $generated.workspace -PublishId $generatedPublish.publish_id -Finalize | Out-String) | ConvertFrom-Json -Depth 40
    $generatedState = Get-SourceState $generated
    Assert-Equal 'completed' $generatedFinal.status 'a successful generated write must finalize'
    Assert-Equal ([IO.File]::ReadAllText((Join-Path $generated.source 'generated\version.h'))) ([IO.File]::ReadAllText((Join-Path $generated.integration 'generated\version.h'))) 'the generated file must enter the user baseline'
    Assert-Equal $generatedState.user_baseline_commit $generatedState.build_baselines.PSObject.Properties["$($generated.target_id)/generated"].Value.last_successful_build_commit 'the successful build baseline must point at the finalized user baseline'

    Write-Host '[8b/8] generated-failure'
    $generatedFail = New-Fixture 'genfail'
    Commit-TaskChanges $generatedFail
    $generatedFailPublish = Start-PublishWithBuild $generatedFail
    $generatedBefore = [IO.File]::ReadAllText((Join-Path $generatedFail.source 'generated\version.h'))
    $generatedFailBuild = (& (Join-Path $PSScriptRoot 'invoke-build.ps1') -WorkspaceRoot $generatedFail.workspace -TargetId $generatedFail.target_id -BuildId 'generated-fail' -BuildContext user-authority -PublishId $generatedFailPublish.publish_id -AllowCandidate | Out-String) | ConvertFrom-Json -Depth 40
    Assert-Equal 'failed' $generatedFailBuild.status 'a failed generated-write build must fail'
    Assert-Equal 'verification_failed' (Get-Transaction $generatedFail $generatedFailPublish.publish_id).state 'a failed generated-write build must await a decision'
    $null = & (Join-Path $PSScriptRoot 'publish-workstream.ps1') -WorkspaceRoot $generatedFail.workspace -PublishId $generatedFailPublish.publish_id -Rollback
    Assert-Equal $generatedBefore ([IO.File]::ReadAllText((Join-Path $generatedFail.source 'generated\version.h'))) 'rollback must restore a generated file changed by a failed build'
    Assert-Equal $generatedFail.original_baseline (Get-SourceState $generatedFail).user_baseline_commit 'a failed generated build must not advance the baseline'

    Write-Host '[8c/8] unknown-side-effect'
    $unknown = New-Fixture 'unknown'
    Commit-TaskChanges $unknown
    $unknownPublish = Start-PublishWithBuild $unknown
    $unknownBuild = (& (Join-Path $PSScriptRoot 'invoke-build.ps1') -WorkspaceRoot $unknown.workspace -TargetId $unknown.target_id -BuildId 'unknown' -BuildContext user-authority -PublishId $unknownPublish.publish_id -AllowCandidate | Out-String) | ConvertFrom-Json -Depth 40
    Assert-Equal 'passed' $unknownBuild.status 'the command and expected artifact may pass despite an unknown side effect'
    Assert-Equal 'review_required' $unknownBuild.side_effect_status 'an unknown project write must require review'
    $unknownTargets = Get-Content -Raw -LiteralPath (Join-Path $unknown.workspace 'workspace-management\config\targets.json') | ConvertFrom-Json -Depth 40
    Assert-Equal 'candidate' $unknownTargets.targets.PSObject.Properties[$unknown.target_id].Value.builds.unknown.command_state 'unknown side effects must not promote command trust to verified'
    Assert-Equal 'side_effect_review_required' (Get-Transaction $unknown $unknownPublish.publish_id).state 'the transaction must block on unknown side effects'
    $unknownPlan = (& (Join-Path $PSScriptRoot 'publish-workstream.ps1') -WorkspaceRoot $unknown.workspace -WorkstreamId $unknown.workstream_id | Out-String) | ConvertFrom-Json -Depth 40
    Assert-True (@($unknownPlan.blockers | Where-Object { $_ -like '*Nonterminal transaction blocks publish*' }).Count -eq 1) 'unknown side effects must block another publish'
    $null = & (Join-Path $PSScriptRoot 'publish-workstream.ps1') -WorkspaceRoot $unknown.workspace -PublishId $unknownPublish.publish_id -Rollback
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $unknown.source 'unknown-side-effect.txt'))) 'rollback must remove an unknown file created by the build'

    [pscustomobject][ordered]@{
        status = 'passed'
        assertions = $assertions
        powershell = $PSVersionTable.PSVersion.ToString()
        git = ((& git --version | Out-String).Trim())
    } | ConvertTo-Json
}
finally {
    if ($null -eq $oldGitConfigCount) { Remove-Item Env:GIT_CONFIG_COUNT -ErrorAction SilentlyContinue } else { $env:GIT_CONFIG_COUNT = $oldGitConfigCount }
    if ($null -eq $oldGitConfigKey) { Remove-Item Env:GIT_CONFIG_KEY_0 -ErrorAction SilentlyContinue } else { $env:GIT_CONFIG_KEY_0 = $oldGitConfigKey }
    if ($null -eq $oldGitConfigValue) { Remove-Item Env:GIT_CONFIG_VALUE_0 -ErrorAction SilentlyContinue } else { $env:GIT_CONFIG_VALUE_0 = $oldGitConfigValue }
    if (Test-Path -LiteralPath $testRoot) {
        $resolved = (Resolve-Path -LiteralPath $testRoot).Path
        $expectedParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
        if ([IO.Path]::GetDirectoryName($resolved).TrimEnd('\') -ne $expectedParent -or
            -not [IO.Path]::GetFileName($resolved).StartsWith('ewipr-')) {
            throw "Refusing to clean unexpected test path: $resolved"
        }
        Get-ChildItem -LiteralPath $resolved -Recurse -Force | ForEach-Object { $_.Attributes = 'Normal' }
        (Get-Item -LiteralPath $resolved -Force).Attributes = 'Directory'
        [IO.Directory]::Delete($resolved, $true)
    }
}
