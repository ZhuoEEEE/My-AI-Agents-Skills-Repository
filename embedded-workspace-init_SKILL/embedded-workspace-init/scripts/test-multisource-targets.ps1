[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'fixture-project-copies.ps1')

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('ewimt-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
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

function Write-Utf8Text {
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [string] $Text)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) { $null = New-Item -ItemType Directory -Path $parent }
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function Get-SourceState {
    param([string] $Workspace, [string] $SourceId)
    Get-Content -Raw -LiteralPath (Join-Path $Workspace "workspace-management\sync-state\sources\$SourceId.json") | ConvertFrom-Json -Depth 30
}

try {
    $motor = Join-Path $testRoot 'authority-motor'
    $display = Join-Path $testRoot 'authority-display'
    $sensor = Join-Path $testRoot 'authority-sensor'
    $workspace = Join-Path $testRoot 'workspace'
    Write-Utf8Text -Path (Join-Path $motor 'Makefile') -Text "all:`r`n"
    Write-Utf8Text -Path (Join-Path $motor 'main.c') -Text "int motor = 0;`r`n"
    Write-Utf8Text -Path (Join-Path $display 'CMakeLists.txt') -Text "cmake_minimum_required(VERSION 3.20)`r`n"
    Write-Utf8Text -Path (Join-Path $display 'main.c') -Text "int display = 0;`r`n"
    Write-Utf8Text -Path (Join-Path $sensor 'platformio.ini') -Text "[env:test]`r`nplatform = native`r`n"
    Write-Utf8Text -Path (Join-Path $sensor 'main.c') -Text "int sensor = 0;`r`n"

    $definitions = @(
        [ordered]@{
            id = 'controller'
            origin = 'user-imported'
            user_source = 'configured'
            mappings = @(
                [ordered]@{ id = 'motor'; source_path = $motor; integration_subpath = 'firmware/motor' },
                [ordered]@{ id = 'display'; source_path = $display; integration_subpath = 'firmware/display' }
            )
        },
        [ordered]@{
            id = 'sensor'
            origin = 'user-imported'
            user_source = 'configured'
            mappings = @([ordered]@{ id = 'sensor-map'; source_path = $sensor; integration_subpath = 'node/sensor' })
        }
    ) | ConvertTo-Json -Depth 20 -Compress
    $init = (& (Join-Path $PSScriptRoot 'init-workspace.ps1') -WorkspaceRoot $workspace -SourceDefinitionsJson $definitions | Out-String) | ConvertFrom-Json -Depth 40
    Assert-Equal 'active' $init.status 'the multi-source workspace must activate'
    Assert-Equal 2 @($init.source_groups).Count 'two source-private Git domains must be created'
    Assert-Equal 3 $init.targets_detected 'three initial MCU projects must use the same target model'

    $targetsPath = Join-Path $workspace 'workspace-management\config\targets.json'
    $localPath = Join-Path $workspace 'workspace-management\config\targets.local.json'
    $targets = Get-Content -Raw -LiteralPath $targetsPath | ConvertFrom-Json -Depth 40
    $local = Get-Content -Raw -LiteralPath $localPath | ConvertFrom-Json -Depth 40
    Assert-Equal 2 @($targets.sources.controller.mappings).Count 'the dispersed controller paths must remain one source group with two mappings'
    Assert-Equal 'firmware/motor,firmware/display' ((@($targets.sources.controller.mappings.integration_subpath)) -join ',') 'portable mapping topology must preserve the selected integration paths'
    Assert-Equal $motor.Replace('\', '/') $local.sources.controller.mappings.motor.source_path 'the local motor path must remain outside portable config'
    Assert-Equal $display.Replace('\', '/') $local.sources.controller.mappings.display.source_path 'the local display path must remain outside portable config'
    Assert-True (-not ((Get-Content -Raw -LiteralPath $targetsPath).Contains($motor, [StringComparison]::OrdinalIgnoreCase))) 'portable targets must contain no authority absolute path'
    foreach ($sourceId in @('controller', 'sensor')) {
        $integration = Join-Path $workspace "sources\$sourceId\integration"
        Assert-Equal '' ((& git -C $integration remote | Out-String).Trim()) "source-private Git must have no remote: $sourceId"
        $state = Get-SourceState $workspace $sourceId
        Assert-Equal $state.user_baseline_commit ((& git -C $integration rev-parse $state.user_baseline_ref | Out-String).Trim()) "the source baseline must be reachable: $sourceId"
    }

    $controllerTargets = @($targets.targets.PSObject.Properties | Where-Object { $_.Value.source -eq 'controller' } | ForEach-Object Name)
    $sensorTargets = @($targets.targets.PSObject.Properties | Where-Object { $_.Value.source -eq 'sensor' } | ForEach-Object Name)
    try {
        $invalidScope = @([ordered]@{ source_id = 'sensor'; targets = @($controllerTargets[0]); paths = @([ordered]@{ path = '.'; access = 'write' }) }) | ConvertTo-Json -Depth 10 -Compress
        & (Join-Path $PSScriptRoot 'new-workstream.ps1') -WorkspaceRoot $workspace -Title 'Invalid target owner' -ScopeJson $invalidScope | Out-Null
        throw 'Expected target/source mismatch was not rejected.'
    }
    catch { Assert-True ($_.Exception.Message -like '*does not belong to scope source*') 'workstream creation must reject a target from another source' }
    Import-Module (Join-Path $workspace 'workspace-management\tools\lib\workspace-common.psm1') -Force
    $confirmedTargetId = $controllerTargets[0]
    $confirmedProject = $targets.targets.PSObject.Properties[$confirmedTargetId].Value.project | ConvertTo-Json -Depth 10 -Compress
    $confirmedMetadata = $targets.field_metadata.PSObject.Properties["/targets/$confirmedTargetId/project"].Value
    $confirmedMetadata.provenance = 'confirmed'
    $confirmedMetadata.verification = 'verified'
    Write-EwiJsonAtomic -Path $targetsPath -Value $targets -SchemaPath (Join-Path $workspace 'workspace-management\schemas\targets.schema.json')
    $null = & (Join-Path $PSScriptRoot 'detect-targets.ps1') -WorkspaceRoot $workspace -Apply
    $confirmedAfter = Get-Content -Raw -LiteralPath $targetsPath | ConvertFrom-Json -Depth 40
    Assert-Equal $confirmedProject ($confirmedAfter.targets.PSObject.Properties[$confirmedTargetId].Value.project | ConvertTo-Json -Depth 10 -Compress) 'detection must not overwrite a confirmed project fact'
    Assert-Equal 'confirmed' $confirmedAfter.field_metadata.PSObject.Properties["/targets/$confirmedTargetId/project"].Value.provenance 'confirmed provenance must survive detection'
    $scope = @(
        [ordered]@{ source_id = 'controller'; targets = $controllerTargets; paths = @([ordered]@{ path = '.'; access = 'write' }) },
        [ordered]@{ source_id = 'sensor'; targets = $sensorTargets; paths = @([ordered]@{ path = '.'; access = 'write' }) }
    ) | ConvertTo-Json -Depth 12 -Compress
    $workstream = (& (Join-Path $PSScriptRoot 'new-workstream.ps1') -WorkspaceRoot $workspace -Title 'Cross source publish' -ScopeJson $scope | Out-String) | ConvertFrom-Json -Depth 30
    Mount-FixtureProjectCopies -WorkspaceRoot $workspace -Workstream $workstream
    $manifestPath = Join-Path $workspace "$($workstream.path)\workstream.json"
    $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json -Depth 40
    $removedSourceScope = @([ordered]@{ source_id = 'controller'; targets = $controllerTargets; paths = @([ordered]@{ path = '.'; access = 'write' }) }) | ConvertTo-Json -Depth 10 -Compress
    try {
        & (Join-Path $PSScriptRoot 'update-workstream.ps1') -WorkspaceRoot $workspace -WorkstreamId $workstream.workstream_id -ScopeJson $removedSourceScope | Out-Null
        throw 'Expected source mount mismatch was not rejected.'
    }
    catch { Assert-True ($_.Exception.Message -like '*Keep existing source refs in scope*') 'scope update must retain source provenance while engineering release is managed separately' }
    $controllerWorktree = Join-Path $workspace $manifest.agent.refs.controller.worktree
    $sensorWorktree = Join-Path $workspace $manifest.agent.refs.sensor.worktree
    Write-Utf8Text -Path (Join-Path $controllerWorktree 'firmware\motor\main.c') -Text "int motor = 7;`r`n"
    Write-Utf8Text -Path (Join-Path $sensorWorktree 'node\sensor\main.c') -Text "int sensor = 9;`r`n"
    $null = & git -C $controllerWorktree add -- 'firmware/motor/main.c'
    $null = & git -C $controllerWorktree commit -m 'feat: motor change'
    $null = & git -C $sensorWorktree add -- 'node/sensor/main.c'
    $null = & git -C $sensorWorktree commit -m 'feat: sensor change'

    $controllerBaseline = (Get-SourceState $workspace 'controller').user_baseline_commit
    $sensorBaseline = (Get-SourceState $workspace 'sensor').user_baseline_commit
    $plan = (& (Join-Path $PSScriptRoot 'publish-workstream.ps1') -WorkspaceRoot $workspace -WorkstreamId $workstream.workstream_id | Out-String) | ConvertFrom-Json -Depth 50
    Assert-True $plan.can_apply 'the cross-source publish plan must be applicable'
    Assert-Equal 2 @($plan.files).Count 'the plan must freeze one file in each source'

    $lockedFile = Join-Path $sensor 'main.c'
    $stream = [IO.File]::Open($lockedFile, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        try { & (Join-Path $PSScriptRoot 'publish-workstream.ps1') -WorkspaceRoot $workspace -WorkstreamId $workstream.workstream_id -ExpectedManifestDigest $plan.manifest_digest -Apply | Out-Null }
        catch { Assert-True ($_.Exception.Message -like '*Access to the path*') 'the locked second authority must cause the intended apply failure' }
    }
    finally { $stream.Dispose() }
    $failedTransaction = Get-ChildItem -LiteralPath (Join-Path $workspace 'workspace-management\sync-state\transactions') -Filter '*.json' | Select-Object -First 1
    $failedState = Get-Content -Raw -LiteralPath $failedTransaction.FullName | ConvertFrom-Json -Depth 40
    Assert-Equal 'rolled_back' $failedState.state 'a second-source apply failure must roll back the whole transaction'
    Assert-Equal "int motor = 0;`r`n" ([IO.File]::ReadAllText((Join-Path $motor 'main.c'))) 'the first source must be restored after a later source fails'
    Assert-Equal "int sensor = 0;`r`n" ([IO.File]::ReadAllText((Join-Path $sensor 'main.c'))) 'the failed second source must remain unchanged'
    Assert-Equal $controllerBaseline (Get-SourceState $workspace 'controller').user_baseline_commit 'controller baseline must not advance on multi-source failure'
    Assert-Equal $sensorBaseline (Get-SourceState $workspace 'sensor').user_baseline_commit 'sensor baseline must not advance on multi-source failure'
    foreach ($item in $failedState.manifest) {
        Assert-True (Test-Path -LiteralPath (Join-Path $workspace "$($failedState.recovery_path)\original\$($item.source_id)\$($item.mapping_id)\$($item.relative_path)")) 'every source snapshot must exist before multi-source apply'
    }

    $retryPlan = (& (Join-Path $PSScriptRoot 'publish-workstream.ps1') -WorkspaceRoot $workspace -WorkstreamId $workstream.workstream_id | Out-String) | ConvertFrom-Json -Depth 50
    Assert-True $retryPlan.can_apply 'a fully rolled-back transaction must permit an unchanged retry'
    $success = (& (Join-Path $PSScriptRoot 'publish-workstream.ps1') -WorkspaceRoot $workspace -WorkstreamId $workstream.workstream_id -ExpectedManifestDigest $retryPlan.manifest_digest -Apply | Out-String) | ConvertFrom-Json -Depth 40
    Assert-Equal 'completed' $success.status 'the cross-source retry must complete'
    Assert-Equal "int motor = 7;`r`n" ([IO.File]::ReadAllText((Join-Path $motor 'main.c'))) 'controller authority must receive its frozen result'
    Assert-Equal "int sensor = 9;`r`n" ([IO.File]::ReadAllText((Join-Path $sensor 'main.c'))) 'sensor authority must receive its frozen result'

    Write-Utf8Text -Path (Join-Path $motor 'boot\Makefile') -Text "all:`r`n"
    Write-Utf8Text -Path (Join-Path $motor 'boot\boot.c') -Text "int boot = 1;`r`n"
    $import = (& (Join-Path $PSScriptRoot 'import-sources.ps1') -WorkspaceRoot $workspace -SourceId controller -Apply | Out-String) | ConvertFrom-Json -Depth 40
    Assert-Equal 'imported' $import.status 'a later MCU project must first import through its existing source mapping'
    $detection = (& (Join-Path $PSScriptRoot 'detect-targets.ps1') -WorkspaceRoot $workspace -Apply | Out-String) | ConvertFrom-Json -Depth 30
    Assert-Equal 1 $detection.registered 'the later MCU project must receive one stable target id'
    Assert-True (Test-Path -LiteralPath (Join-Path $workspace $detection.evidence)) 'new target registration must record evidence'
    $targetsAfter = Get-Content -Raw -LiteralPath $targetsPath | ConvertFrom-Json -Depth 40
    $newTarget = @($targetsAfter.targets.PSObject.Properties | Where-Object { $_.Value.path -eq 'firmware/motor/boot' })
    Assert-Equal 1 $newTarget.Count 'the new target must belong to the original controller source group'
    Assert-Equal 'detected' $targetsAfter.field_metadata.PSObject.Properties["/targets/$($newTarget[0].Name)/project"].Value.provenance 'the new target must record detected provenance'
    $repeat = (& (Join-Path $PSScriptRoot 'detect-targets.ps1') -WorkspaceRoot $workspace -Apply | Out-String) | ConvertFrom-Json -Depth 20
    Assert-Equal 0 $repeat.registered 'repeated detection must not duplicate the new target'

    $targetCountBeforeFailure = @($targetsAfter.targets.PSObject.Properties).Count
    $failedTargetDirectory = Join-Path $workspace 'sources\controller\integration\failed-target'
    Write-Utf8Text -Path (Join-Path $failedTargetDirectory 'Makefile') -Text "all:`r`n"
    $detectionHook = Join-Path $workspace '.git\hooks\pre-commit'
    Write-Utf8Text -Path $detectionHook -Text "#!/bin/sh`nexit 1`n"
    try {
        try { & (Join-Path $PSScriptRoot 'detect-targets.ps1') -WorkspaceRoot $workspace -Apply | Out-Null }
        catch { Assert-True ($_.Exception.Message -like '*Git commit failed*') 'a target-registration checkpoint failure must surface the commit error' }
    }
    finally {
        [IO.File]::Delete($detectionHook)
        [IO.Directory]::Delete($failedTargetDirectory, $true)
    }
    $targetsAfterDetectionFailure = Get-Content -Raw -LiteralPath $targetsPath | ConvertFrom-Json -Depth 40
    Assert-Equal $targetCountBeforeFailure @($targetsAfterDetectionFailure.targets.PSObject.Properties).Count 'failed target registration must restore targets.json'
    Assert-Equal '' ((& git -C $workspace status --short | Out-String).Trim()) 'failed target registration must leave management Git clean'

    [IO.File]::Delete((Join-Path $motor 'boot\Makefile'))
    $null = & (Join-Path $PSScriptRoot 'import-sources.ps1') -WorkspaceRoot $workspace -SourceId controller -Apply
    $missing = (& (Join-Path $PSScriptRoot 'detect-targets.ps1') -WorkspaceRoot $workspace | Out-String) | ConvertFrom-Json -Depth 20
    Assert-True (@($missing.missing_or_moved | Where-Object { $_ -eq "target:$($newTarget[0].Name)" }).Count -eq 1) 'a missing project marker must be reported for review'
    $targetsFinal = Get-Content -Raw -LiteralPath $targetsPath | ConvertFrom-Json -Depth 40
    Assert-True ($null -ne $targetsFinal.targets.PSObject.Properties[$newTarget[0].Name]) 'a missing target must not be deleted automatically'

    $completedManifest = Read-EwiJson -Path $manifestPath -SchemaPath (Join-Path $workspace 'workspace-management\schemas\workstream.schema.json')
    $completedManifest.status = 'completed'
    $completedManifest.has_unresolved_changes = $false
    $completedManifest.updated_at = Get-EwiTimestamp
    Write-EwiJsonAtomic -Path $manifestPath -Value $completedManifest -SchemaPath (Join-Path $workspace 'workspace-management\schemas\workstream.schema.json')
    $null = New-EwiGitCommit -Repository $workspace -Message 'chore: complete cross source test workstream' -RelativePaths @("work/$($workstream.workstream_id)/workstream.json")

    $staleWorkstream = (& (Join-Path $PSScriptRoot 'new-workstream.ps1') -WorkspaceRoot $workspace -Title 'Stale mapping' -ScopeJson (@([ordered]@{ source_id = 'controller'; targets = @($controllerTargets[0]); paths = @([ordered]@{ path = 'firmware/display'; access = 'write' }) }) | ConvertTo-Json -Depth 10 -Compress) | Out-String) | ConvertFrom-Json -Depth 20
    Mount-FixtureProjectCopies -WorkspaceRoot $workspace -Workstream $staleWorkstream
    $staleManifestPath = Join-Path $workspace "$($staleWorkstream.path)\workstream.json"
    $staleManifest = Read-EwiJson -Path $staleManifestPath -SchemaPath (Join-Path $workspace 'workspace-management\schemas\workstream.schema.json')
    $staleManifest.agent.refs.controller.mapping_revision++
    Write-EwiJsonAtomic -Path $staleManifestPath -Value $staleManifest -SchemaPath (Join-Path $workspace 'workspace-management\schemas\workstream.schema.json')
    $null = New-EwiGitCommit -Repository $workspace -Message 'chore: inject stale mapping revision' -RelativePaths @("work/$($staleWorkstream.workstream_id)/workstream.json")
    Write-Utf8Text -Path (Join-Path $workspace "$($staleManifest.agent.refs.controller.worktree)\firmware\display\main.c") -Text "int display = 5;`r`n"
    $staleTree = Join-Path $workspace $staleManifest.agent.refs.controller.worktree
    $null = & git -C $staleTree add -- 'firmware/display/main.c'
    $null = & git -C $staleTree commit -m 'feat: stale mapping change'
    $stalePlan = (& (Join-Path $PSScriptRoot 'publish-workstream.ps1') -WorkspaceRoot $workspace -WorkstreamId $staleWorkstream.workstream_id | Out-String) | ConvertFrom-Json -Depth 30
    Assert-True (@($stalePlan.blockers | Where-Object { $_ -like '*mapping revision is stale*' }).Count -eq 1) 'a stale workstream mapping revision must block publish'

    $external = Join-Path $testRoot 'authority-external'
    Write-Utf8Text -Path (Join-Path $external 'Makefile') -Text "all:`r`n"
    Write-Utf8Text -Path (Join-Path $external 'external.c') -Text "int external = 1;`r`n"
    $externalDefinition = @([ordered]@{ id = 'external'; origin = 'user-imported'; user_source = 'configured'; mappings = @([ordered]@{ id = 'external-map'; source_path = $external; integration_subpath = '.' }) }) | ConvertTo-Json -Depth 12 -Compress
    $deployedAddSource = Join-Path $workspace 'workspace-management\tools\add-source.ps1'
    $additionPlan = (& $deployedAddSource -WorkspaceRoot $workspace -SourceDefinitionJson $externalDefinition | Out-String) | ConvertFrom-Json -Depth 30
    Assert-True $additionPlan.can_apply 'an external disjoint source must produce a digest-bound addition plan'
    Assert-True $additionPlan.approval_required 'source registration must require explicit plan approval'
    try { & $deployedAddSource -WorkspaceRoot $workspace -SourceDefinitionJson $externalDefinition -ExpectedPlanDigest ('0' * 64) -Apply | Out-Null }
    catch { Assert-True ($_.Exception.Message -like '*explicitly approved digest*') 'a wrong source plan digest must be rejected' }
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $workspace 'sources\external'))) 'a wrong source plan digest must create no source directory'
    $added = (& $deployedAddSource -WorkspaceRoot $workspace -SourceDefinitionJson $externalDefinition -ExpectedPlanDigest $additionPlan.plan_digest -Apply | Out-String) | ConvertFrom-Json -Depth 30
    Assert-Equal 'added' $added.status 'the approved external source must be registered'
    Assert-Equal 1 $added.target_detection.registered 'a target in the newly added source must be registered'
    $externalState = Get-SourceState $workspace 'external'
    Assert-Equal $externalState.user_baseline_commit ((& git -C (Join-Path $workspace 'sources\external\integration') rev-parse $externalState.user_baseline_ref | Out-String).Trim()) 'the added user source must have a reachable user baseline'

    $externalTargetId = @((Get-Content -Raw -LiteralPath $targetsPath | ConvertFrom-Json -Depth 40).targets.PSObject.Properties | Where-Object { $_.Value.source -eq 'external' } | ForEach-Object Name)[0]
    $externalScope = @([ordered]@{ source_id = 'external'; targets = @($externalTargetId); paths = @([ordered]@{ path = '.'; access = 'write' }) }) | ConvertTo-Json -Depth 10 -Compress
    $oldMappingWorkstream = (& (Join-Path $PSScriptRoot 'new-workstream.ps1') -WorkspaceRoot $workspace -Title 'Old mapping task' -ScopeJson $externalScope | Out-String) | ConvertFrom-Json -Depth 20
    Mount-FixtureProjectCopies -WorkspaceRoot $workspace -Workstream $oldMappingWorkstream
    $oldMappingManifest = Get-Content -Raw -LiteralPath (Join-Path $workspace "$($oldMappingWorkstream.path)\workstream.json") | ConvertFrom-Json -Depth 30
    $oldMappingTree = Join-Path $workspace $oldMappingManifest.agent.refs.external.worktree
    Write-Utf8Text -Path (Join-Path $oldMappingTree 'external.c') -Text "int external = 7;`r`n"
    $null = & git -C $oldMappingTree add -- 'external.c'
    $null = & git -C $oldMappingTree commit -m 'feat: old mapping task'

    $unchangedMapping = @([ordered]@{ mapping_id = 'external-map'; source_path = $external; integration_subpath = '.' }) | ConvertTo-Json -Depth 10 -Compress
    $unchangedMappingPlan = (& (Join-Path $PSScriptRoot 'migrate-source-mappings.ps1') -WorkspaceRoot $workspace -SourceId external -MappingsJson $unchangedMapping | Out-String) | ConvertFrom-Json -Depth 30
    Assert-True (-not $unchangedMappingPlan.can_apply) 'an unchanged mapping must not be applicable as a migration'
    Assert-Equal 1 $unchangedMappingPlan.new_revision 'an unchanged mapping must not increment mapping_revision'

    $relocatedAuthority = Join-Path $testRoot 'authority-external-relocated'
    Write-Utf8Text -Path (Join-Path $relocatedAuthority 'Makefile') -Text "all:`r`n"
    Write-Utf8Text -Path (Join-Path $relocatedAuthority 'external.c') -Text "int external = 2;`r`n"
    $changedMapping = @([ordered]@{ mapping_id = 'external-map'; source_path = $relocatedAuthority; integration_subpath = 'relocated' }) | ConvertTo-Json -Depth 10 -Compress
    $changedMappingPlan = (& (Join-Path $PSScriptRoot 'migrate-source-mappings.ps1') -WorkspaceRoot $workspace -SourceId external -MappingsJson $changedMapping | Out-String) | ConvertFrom-Json -Depth 30
    Assert-True $changedMappingPlan.can_apply 'a real authority/topology change must require an applicable controlled migration'
    Assert-Equal 2 $changedMappingPlan.new_revision 'a real mapping change must increment mapping_revision exactly once'
    try { & (Join-Path $PSScriptRoot 'migrate-source-mappings.ps1') -WorkspaceRoot $workspace -SourceId external -MappingsJson $changedMapping -ExpectedPlanDigest ('0' * 64) -Apply | Out-Null }
    catch { Assert-True ($_.Exception.Message -like '*explicitly approved digest*') 'a wrong mapping migration digest must be rejected' }
    $oldExternalBaseline = $externalState.user_baseline_commit
    $migration = (& (Join-Path $PSScriptRoot 'migrate-source-mappings.ps1') -WorkspaceRoot $workspace -SourceId external -MappingsJson $changedMapping -ExpectedPlanDigest $changedMappingPlan.plan_digest -Apply | Out-String) | ConvertFrom-Json -Depth 30
    Assert-Equal 'migrated' $migration.status 'the approved mapping migration must complete'
    Assert-Equal 2 $migration.new_revision 'the applied mapping revision must match the approved plan'
    Assert-Equal $migration.user_baseline_commit ((& git -C (Join-Path $workspace 'sources\external\integration') rev-parse $migration.user_baseline_ref | Out-String).Trim()) 'the migrated authority must establish a reachable new user baseline'
    $null = & git -C (Join-Path $workspace 'sources\external\integration') cat-file -e "$oldExternalBaseline^{commit}"
    Assert-Equal 0 $LASTEXITCODE 'mapping migration must preserve old private history'
    $targetsAfterMapping = Get-Content -Raw -LiteralPath $targetsPath | ConvertFrom-Json -Depth 40
    Assert-Equal $externalTargetId @($targetsAfterMapping.targets.PSObject.Properties | Where-Object { $_.Value.source -eq 'external' } | ForEach-Object Name)[0] 'mapping migration must preserve the stable target id'
    Assert-Equal 'relocated' $targetsAfterMapping.targets.PSObject.Properties[$externalTargetId].Value.path 'same mapping-id topology migration must update the target path'
    $oldMappingPublish = (& (Join-Path $PSScriptRoot 'publish-workstream.ps1') -WorkspaceRoot $workspace -WorkstreamId $oldMappingWorkstream.workstream_id | Out-String) | ConvertFrom-Json -Depth 30
    Assert-True (@($oldMappingPublish.blockers | Where-Object { $_ -like '*mapping revision is stale*' }).Count -eq 1) 'an old workstream must not publish through a migrated mapping'
    $null = & (Join-Path $PSScriptRoot 'update-workstream.ps1') -WorkspaceRoot $workspace -WorkstreamId $oldMappingWorkstream.workstream_id -Status abandoned -HasUnresolvedChanges $false
    $postMigrationImport = (& (Join-Path $PSScriptRoot 'import-sources.ps1') -WorkspaceRoot $workspace -SourceId external | Out-String) | ConvertFrom-Json -Depth 30
    Assert-True $postMigrationImport.can_apply 'the new mapping digest must validate in normal import planning'

    $failedExternal = Join-Path $testRoot 'authority-failed-add'
    Write-Utf8Text -Path (Join-Path $failedExternal 'Makefile') -Text "all:`r`n"
    $failedDefinition = @([ordered]@{ id = 'failed-add'; origin = 'user-imported'; user_source = 'configured'; mappings = @([ordered]@{ id = 'failed-map'; source_path = $failedExternal; integration_subpath = '.' }) }) | ConvertTo-Json -Depth 12 -Compress
    $failedPlan = (& $deployedAddSource -WorkspaceRoot $workspace -SourceDefinitionJson $failedDefinition | Out-String) | ConvertFrom-Json -Depth 30
    $hook = Join-Path $workspace '.git\hooks\pre-commit'
    Write-Utf8Text -Path $hook -Text "#!/bin/sh`nexit 1`n"
    try {
        try { & $deployedAddSource -WorkspaceRoot $workspace -SourceDefinitionJson $failedDefinition -ExpectedPlanDigest $failedPlan.plan_digest -Apply | Out-Null }
        catch { Assert-True ($_.Exception.Message -like '*Git commit failed*') 'a management checkpoint failure must abort source addition' }
    }
    finally { [IO.File]::Delete($hook) }
    $afterFailedAdd = Get-Content -Raw -LiteralPath $targetsPath | ConvertFrom-Json -Depth 40
    Assert-True ($null -eq $afterFailedAdd.sources.PSObject.Properties['failed-add']) 'failed source addition must restore portable config'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $workspace 'sources\failed-add'))) 'failed source addition must remove its private source directory'
    Assert-Equal '' ((& git -C $workspace status --short | Out-String).Trim()) 'failed source addition must leave management Git clean'

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
            -not [IO.Path]::GetFileName($resolved).StartsWith('ewimt-')) {
            throw "Refusing to clean unexpected test path: $resolved"
        }
        Get-ChildItem -LiteralPath $resolved -Recurse -Force | ForEach-Object { $_.Attributes = 'Normal' }
        (Get-Item -LiteralPath $resolved -Force).Attributes = 'Directory'
        [IO.Directory]::Delete($resolved, $true)
    }
}
