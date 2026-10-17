[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'fixture-project-copies.ps1')

$skillRoot = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('embedded workspace regression ' + [Guid]::NewGuid().ToString('N'))
$sourceRoot = Join-Path $testRoot '用户 Source'
$referenceRoot = Join-Path $testRoot 'Reference Source'
$pendingRoot = Join-Path $testRoot 'Ambiguous License'
$workspaceRoot = Join-Path $testRoot 'Agent Workspace'
$failureRoot = Join-Path $testRoot 'Activation Failure'
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
    try {
        & $Action
    }
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
    param($Builds, [string] $Id, [string] $Script, [string[]] $OutputPaths, [string[]] $GeneratedPaths, [string[]] $Outputs, [string[]] $ExtraArgs = @())
    $value = [pscustomobject][ordered]@{
        configuration = $Id
        cwd = '.'
        default_execution_context = 'agent-copy'
        command = [pscustomobject][ordered]@{
            tool = 'pwsh'
            args = @('-NoProfile', '-NonInteractive', '-File', $Script) + @($ExtraArgs)
        }
        command_state = 'candidate'
        output_paths = @($OutputPaths)
        generated_write_paths = @($GeneratedPaths)
        outputs = @($Outputs)
    }
    $Builds | Add-Member -NotePropertyName $Id -NotePropertyValue $value
}

try {
    $env:GIT_CONFIG_COUNT = '1'
    $env:GIT_CONFIG_KEY_0 = 'core.autocrlf'
    $env:GIT_CONFIG_VALUE_0 = 'true'

    $null = New-Item -ItemType Directory -Path $sourceRoot
    Write-Utf8Text -Path (Join-Path $sourceRoot 'Makefile') -Text "all:`r`n`t@echo build`r`n"
    Write-Utf8Text -Path (Join-Path $sourceRoot 'src\main.c') -Text "int main(void) { return 0; }`r`n"
    Write-Utf8Text -Path (Join-Path $sourceRoot 'LICENSE') -Text "Legal example containing api_key='documentation-example-value'.`r`n"
    Write-Utf8Text -Path (Join-Path $sourceRoot 'artifacts\a.bin') -Text 'old-a'
    Write-Utf8Text -Path (Join-Path $sourceRoot 'artifacts\b.bin') -Text 'old-b'
    Write-Utf8Text -Path (Join-Path $sourceRoot 'build-partial.ps1') -Text @'
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'artifacts/a.bin'), [Guid]::NewGuid().ToString('N'))
'@
    Write-Utf8Text -Path (Join-Path $sourceRoot 'build-full.ps1') -Text @'
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'artifacts/a.bin'), [Guid]::NewGuid().ToString('N'))
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'artifacts/b.bin'), [Guid]::NewGuid().ToString('N'))
'@
    Write-Utf8Text -Path (Join-Path $sourceRoot 'build-overlap.ps1') -Text @'
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'overlap-ran.txt'), 'ran')
'@
    Write-Utf8Text -Path (Join-Path $sourceRoot 'build-args.ps1') -Text @'
param([string] $First, [string] $Second, [string] $Third)
$value = [pscustomobject]@{ first = $First; second = $Second; third = $Third }
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'artifacts/args.json'), ($value | ConvertTo-Json -Compress))
'@
    Write-Utf8Text -Path (Join-Path $sourceRoot 'build-hardware.ps1') -Text @'
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'hardware-ran.txt'), 'unsafe')
'@
    Write-Utf8Text -Path (Join-Path $sourceRoot 'build-unknown.ps1') -Text @'
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'artifacts/unknown.bin'), [Guid]::NewGuid().ToString('N'))
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'unknown-project-write.txt'), 'unexpected')
'@
    Write-Utf8Text -Path (Join-Path $referenceRoot 'LICENSE') -Text "Legal example containing api_key='documentation-example-value'.`r`n"
    Write-Utf8Text -Path (Join-Path $referenceRoot 'README.md') -Text "# Synthetic reference`r`n"
    Write-Utf8Text -Path (Join-Path $pendingRoot 'main.c') -Text "int pending;`r`n"
    Write-Utf8Text -Path (Join-Path $pendingRoot 'license.dat') -Text "ambiguous license material`r`n"
    $definiteSecretRoot = Join-Path $testRoot 'Legal Named Secret'
    Write-Utf8Text -Path (Join-Path $definiteSecretRoot 'main.c') -Text "int secret_test;`r`n"
    Write-Utf8Text -Path (Join-Path $definiteSecretRoot 'LICENSE') -Text "-----BEGIN PRIVATE KEY-----`r`nsynthetic-test-only`r`n-----END PRIVATE KEY-----`r`n"

    $pendingPlan = (& (Join-Path $PSScriptRoot 'plan-migration.ps1') -WorkspaceRoot (Join-Path $testRoot 'Pending Workspace') -UserSourcePath $pendingRoot | Out-String) | ConvertFrom-Json -Depth 40
    Assert-True (-not $pendingPlan.can_apply) 'an ambiguous license file must block import pending confirmation'
    Assert-True (@($pendingPlan.summary.blockers | Where-Object { $_ -like '*ambiguous license or activation*' }).Count -eq 1) 'the pending license blocker must be explicit'
    $definiteSecretPlan = (& (Join-Path $PSScriptRoot 'plan-migration.ps1') -WorkspaceRoot (Join-Path $testRoot 'Secret Workspace') -UserSourcePath $definiteSecretRoot | Out-String) | ConvertFrom-Json -Depth 40
    Assert-True (-not $definiteSecretPlan.can_apply) 'a legal filename must not override a definite private-key marker'
    Assert-True (@($definiteSecretPlan.summary.blockers | Where-Object { $_ -like '*sensitive-content review*LICENSE*' }).Count -eq 1) 'a definite secret in a legal-name file must be blocked explicitly'

    Import-Module (Join-Path $PSScriptRoot 'lib\workspace-common.psm1') -Force
    $inventory = Get-EwiFileInventory -Root $sourceRoot -MappingId 'source'
    Assert-True (@($inventory.files | Where-Object path -eq 'LICENSE').Count -eq 1) 'a legal file must remain in the managed inventory'
    Assert-True (@($inventory.warnings).Count -eq 1) 'a legal file content match must produce a warning'
    Assert-True (@($inventory.sensitive | Where-Object { $_ -eq 'LICENSE' }).Count -eq 0) 'a legal file content match must not become a blocking secret'

    $duplicateDefinitions = @(
        [ordered]@{ id = 'first'; origin = 'user-imported'; user_source = 'configured'; mappings = @([ordered]@{ id = 'first-map'; source_path = $sourceRoot; integration_subpath = '.' }) },
        [ordered]@{ id = 'second'; origin = 'user-imported'; user_source = 'configured'; mappings = @([ordered]@{ id = 'second-map'; source_path = $sourceRoot; integration_subpath = '.' }) }
    ) | ConvertTo-Json -Depth 10 -Compress
    $duplicatePlan = (& (Join-Path $PSScriptRoot 'plan-migration.ps1') -WorkspaceRoot $workspaceRoot -SourceDefinitionsJson $duplicateDefinitions | Out-String) | ConvertFrom-Json -Depth 40
    Assert-True (-not $duplicatePlan.can_apply) 'duplicate authority paths across source groups must block initialization'
    Assert-True (@($duplicatePlan.summary.blockers | Where-Object { $_ -like '*must be real-path disjoint*' }).Count -gt 0) 'the duplicate authority blocker must explain the overlap'

    $promotedDefinition = @(
        [ordered]@{ id = 'promoted'; origin = 'reference-promoted'; user_source = 'configured'; mappings = @([ordered]@{ id = 'promoted-map'; source_path = $sourceRoot; integration_subpath = '.' }) }
    ) | ConvertTo-Json -Depth 10 -Compress
    Assert-Throws -Pattern 'must be created without a user authority mapping' -Action {
        & (Join-Path $PSScriptRoot 'plan-migration.ps1') -WorkspaceRoot $workspaceRoot -SourceDefinitionsJson $promotedDefinition | Out-Null
    }

    $plan = (& (Join-Path $PSScriptRoot 'plan-migration.ps1') -WorkspaceRoot $workspaceRoot -UserSourcePath $sourceRoot | Out-String) | ConvertFrom-Json -Depth 40
    Assert-True $plan.can_apply 'legal-file warnings must not block initialization'
    Assert-True (@($plan.summary.warnings | Where-Object { $_ -like '*Legal file*retained for review*' }).Count -eq 1) 'the initialization plan must surface the legal-file warning'

    $initialized = (& (Join-Path $PSScriptRoot 'init-workspace.ps1') -WorkspaceRoot $workspaceRoot -UserSourcePath $sourceRoot | Out-String) | ConvertFrom-Json -Depth 40
    Assert-Equal 'active' $initialized.status 'the synthetic workspace must activate'
    Assert-True (@($initialized.warnings | Where-Object { $_ -like '*Legal file*retained for review*' }).Count -eq 1) 'initialization must return the legal-file warning'
    Assert-True (Test-Path -LiteralPath (Join-Path $workspaceRoot 'sources\source\integration\LICENSE')) 'the warned legal file must be copied'
    Assert-Equal '2' ((& git -C $workspaceRoot rev-list --count HEAD | Out-String).Trim()) 'normal initialization must have a prepare commit and an activation commit'
    $prepareCommit = (& git -C $workspaceRoot rev-parse 'HEAD^' | Out-String).Trim()
    $prepareConfig = (& git -C $workspaceRoot show "$prepareCommit`:workspace-management/config/workspace.json" | Out-String) | ConvertFrom-Json
    Assert-Equal 'initializing' $prepareConfig.workspace_state 'the durable prepare checkpoint must remain initializing'
    $activeConfig = Get-Content -Raw -LiteralPath (Join-Path $workspaceRoot 'workspace-management\config\workspace.json') | ConvertFrom-Json
    Assert-Equal 'active' $activeConfig.workspace_state 'only the final checkpoint may activate the workspace'

    $referencePlan = (& (Join-Path $PSScriptRoot 'import-reference.ps1') -WorkspaceRoot $workspaceRoot -ReferenceId 'legal-warning' -SourcePath $referenceRoot -Purpose 'Regression fixture' | Out-String) | ConvertFrom-Json -Depth 20
    Assert-True (@($referencePlan.warnings).Count -eq 1) 'reference planning must surface a legal-file content warning'
    $referenceImport = (& (Join-Path $PSScriptRoot 'import-reference.ps1') -WorkspaceRoot $workspaceRoot -ReferenceId 'legal-warning' -SourcePath $referenceRoot -Purpose 'Regression fixture' -Apply | Out-String) | ConvertFrom-Json -Depth 20
    Assert-True (@($referenceImport.warnings).Count -eq 1) 'reference import must retain the legal-file warning'
    Assert-True (Test-Path -LiteralPath (Join-Path $workspaceRoot 'reference-projects\legal-warning\project\LICENSE')) 'a warned legal file must remain in the reference snapshot'

    $promotionPlan = (& (Join-Path $PSScriptRoot 'promote-reference.ps1') -WorkspaceRoot $workspaceRoot -ReferenceId 'legal-warning' -SourceId 'promoted-ref' | Out-String) | ConvertFrom-Json -Depth 20
    Assert-True $promotionPlan.can_apply 'an immutable reference must be promotable after explicit selection'
    $promotion = (& (Join-Path $PSScriptRoot 'promote-reference.ps1') -WorkspaceRoot $workspaceRoot -ReferenceId 'legal-warning' -SourceId 'promoted-ref' -Apply | Out-String) | ConvertFrom-Json -Depth 30
    Assert-Equal 'promoted' $promotion.status 'reference promotion must create a formal source'
    $promotedTargets = Get-Content -Raw -LiteralPath (Join-Path $workspaceRoot 'workspace-management\config\targets.json') | ConvertFrom-Json -Depth 40
    $promotedSource = $promotedTargets.sources.'promoted-ref'
    Assert-Equal 'reference-promoted' $promotedSource.origin 'the promoted source must retain its origin'
    Assert-Equal 'none' $promotedSource.user_source 'promotion must not invent user authority'
    Assert-Equal 0 @($promotedSource.mappings).Count 'promotion must create no user mapping'
    Assert-Equal '' ((& git -C (Join-Path $workspaceRoot 'sources\promoted-ref\integration') remote | Out-String).Trim()) 'the promoted source must use no-push private Git'
    $promotedScope = @([ordered]@{ source_id = 'promoted-ref'; targets = @(); paths = @([ordered]@{ path = '.'; access = 'write' }) }) | ConvertTo-Json -Depth 10 -Compress
    $promotedWorkstream = (& (Join-Path $PSScriptRoot 'new-workstream.ps1') -WorkspaceRoot $workspaceRoot -Title 'Promoted source check' -ScopeJson $promotedScope | Out-String) | ConvertFrom-Json -Depth 20
    Mount-FixtureProjectCopies -WorkspaceRoot $workspaceRoot -Workstream $promotedWorkstream
    $promotedManifest = Get-Content -Raw -LiteralPath (Join-Path $workspaceRoot "$($promotedWorkstream.path)\workstream.json") | ConvertFrom-Json -Depth 30
    $promotedWorktree = Join-Path $workspaceRoot $promotedManifest.agent.refs.'promoted-ref'.worktree
    Write-Utf8Text -Path (Join-Path $promotedWorktree 'README.md') -Text "# Changed promoted reference`r`n"
    $null = & git -C $promotedWorktree add -- 'README.md'
    $null = & git -C $promotedWorktree commit -m 'feat: promoted source change'
    $promotedPublish = (& (Join-Path $PSScriptRoot 'publish-workstream.ps1') -WorkspaceRoot $workspaceRoot -WorkstreamId $promotedWorkstream.workstream_id | Out-String) | ConvertFrom-Json -Depth 40
    Assert-True (-not $promotedPublish.can_apply) 'a promoted source without user authority must not publish'
    Assert-True (@($promotedPublish.blockers | Where-Object { $_ -like '*Source is not publishable*' }).Count -eq 1) 'the nonpublishable promoted source must be reported explicitly'

    $failureReference = (& (Join-Path $PSScriptRoot 'import-reference.ps1') -WorkspaceRoot $workspaceRoot -ReferenceId 'failure-ref' -SourcePath $referenceRoot -Purpose 'Failure injection fixture' -Apply | Out-String) | ConvertFrom-Json -Depth 20
    Assert-Equal 'imported' $failureReference.status 'the failure-injection reference must be registered'
    $rootHook = Join-Path $workspaceRoot '.git\hooks\pre-commit'
    $referenceIndexPath = Join-Path $workspaceRoot 'reference-projects\README.md'
    $referenceIndexHash = (Get-FileHash -LiteralPath $referenceIndexPath -Algorithm SHA256).Hash
    Write-Utf8Text -Path $rootHook -Text "#!/bin/sh`nexit 1`n"
    try {
        Assert-Throws -Pattern 'Git commit failed' -Action {
            & (Join-Path $PSScriptRoot 'import-reference.ps1') -WorkspaceRoot $workspaceRoot -ReferenceId 'import-failure' -SourcePath $referenceRoot -Purpose 'Expected failure' -Apply | Out-Null
        }
        Assert-Equal $referenceIndexHash (Get-FileHash -LiteralPath $referenceIndexPath -Algorithm SHA256).Hash 'failed reference import must restore the reference index'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $workspaceRoot 'reference-projects\import-failure'))) 'failed reference import must remove its wrapper and body'
        Assert-Throws -Pattern 'Git commit failed' -Action {
            & (Join-Path $PSScriptRoot 'promote-reference.ps1') -WorkspaceRoot $workspaceRoot -ReferenceId 'failure-ref' -SourceId 'promotion-failure' -Apply | Out-Null
        }
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $workspaceRoot 'sources\promotion-failure'))) 'failed reference promotion must remove its source-private Git directory'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $workspaceRoot 'workspace-management\sync-state\sources\promotion-failure.json'))) 'failed reference promotion must remove dynamic source state'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $workspaceRoot 'workspace-management\sync-state\indexes\promotion-failure.jsonl'))) 'failed reference promotion must remove its file index'
    }
    finally { [IO.File]::Delete($rootHook) }
    Assert-Equal '' ((& git -C $workspaceRoot status --short | Out-String).Trim()) 'failed reference operations must leave management Git clean'

    $targets = Get-Content -Raw -LiteralPath (Join-Path $workspaceRoot 'workspace-management\config\targets.json') | ConvertFrom-Json -Depth 40
    $targetId = @($targets.targets.PSObject.Properties.Name)[0]
    $managedBuildConfig = [ordered]@{
        build_id = 'managed'
        configuration = 'Managed candidate'
        cwd = '.'
        command = [ordered]@{ tool = 'pwsh'; args = @('-NoProfile', '-NonInteractive', '-File', 'build-args.ps1', 'space value', '中文值', 'special&value') }
        command_state = 'candidate'
        output_paths = @('artifacts')
        generated_write_paths = @()
        outputs = @('artifacts/args.json')
        tool_executable = (Get-Process -Id $PID).Path
        tool_version = $PSVersionTable.PSVersion.ToString()
    } | ConvertTo-Json -Depth 15 -Compress
    $managedTargetsHash = (Get-FileHash -LiteralPath (Join-Path $workspaceRoot 'workspace-management\config\targets.json') -Algorithm SHA256).Hash
    Assert-Throws -Pattern 'only with confirmed provenance' -Action {
        & (Join-Path $workspaceRoot 'workspace-management\tools\set-build-config.ps1') -WorkspaceRoot $workspaceRoot -TargetId $targetId -ConfigurationJson $managedBuildConfig | Out-Null
    }
    $managedPlan = (& (Join-Path $workspaceRoot 'workspace-management\tools\set-build-config.ps1') -WorkspaceRoot $workspaceRoot -TargetId $targetId -ConfigurationJson $managedBuildConfig -Provenance confirmed | Out-String) | ConvertFrom-Json -Depth 30
    Assert-True $managedPlan.can_apply 'a discovered candidate build must produce a digest-bound plan'
    Assert-Equal $managedTargetsHash (Get-FileHash -LiteralPath (Join-Path $workspaceRoot 'workspace-management\config\targets.json') -Algorithm SHA256).Hash 'build configuration planning must write nothing'
    $managedApply = (& (Join-Path $workspaceRoot 'workspace-management\tools\set-build-config.ps1') -WorkspaceRoot $workspaceRoot -TargetId $targetId -ConfigurationJson $managedBuildConfig -Provenance confirmed -ExpectedPlanDigest $managedPlan.plan_digest -Apply | Out-String) | ConvertFrom-Json -Depth 20
    Assert-Equal 'configured' $managedApply.status 'the approved candidate build must be configured'
    $managedRepeat = (& (Join-Path $workspaceRoot 'workspace-management\tools\set-build-config.ps1') -WorkspaceRoot $workspaceRoot -TargetId $targetId -ConfigurationJson $managedBuildConfig -Provenance confirmed | Out-String) | ConvertFrom-Json -Depth 20
    Assert-True (-not $managedRepeat.can_apply) 'repeating the same build configuration must be idempotent'
    $scope = @([ordered]@{ source_id = 'source'; targets = @($targetId); paths = @([ordered]@{ path = '.'; access = 'write' }) }) | ConvertTo-Json -Depth 10 -Compress
    $workstream = (& (Join-Path $PSScriptRoot 'new-workstream.ps1') -WorkspaceRoot $workspaceRoot -Title 'Regression publish' -ScopeJson $scope | Out-String) | ConvertFrom-Json -Depth 40
    Mount-FixtureProjectCopies -WorkspaceRoot $workspaceRoot -Workstream $workstream
    $workstreamState = Get-Content -Raw -LiteralPath (Join-Path $workspaceRoot "$($workstream.path)\workstream.json") | ConvertFrom-Json -Depth 40
    $worktree = Join-Path $workspaceRoot $workstreamState.agent.refs.source.worktree
    $referenceBody = Join-Path $workspaceRoot 'reference-projects\legal-warning\project\README.md'
    $referenceBodyHash = (Get-FileHash -LiteralPath $referenceBody -Algorithm SHA256).Hash
    $referenceCopy = (& (Join-Path $PSScriptRoot 'create-reference-copy.ps1') -WorkspaceRoot $workspaceRoot -WorkstreamId $workstream.workstream_id -ReferenceId 'legal-warning' -Purpose 'Validate mutable copy isolation' | Out-String) | ConvertFrom-Json -Depth 20
    Assert-Equal 'created' $referenceCopy.status 'a task reference copy must be created through the managed operation'
    $referenceCopyProject = Join-Path $workspaceRoot $referenceCopy.path
    Assert-Equal '' ((& git -C $referenceCopyProject remote | Out-String).Trim()) 'the mutable reference copy must have independent no-push Git'
    Assert-Equal $referenceCopyProject.Replace('\', '/') ((& git -C $referenceCopyProject rev-parse --show-toplevel | Out-String).Trim()) 'the reference copy Git root must own only its project body'
    $referenceCopyReadme = Get-Content -Raw -LiteralPath (Join-Path $referenceCopyProject '..\README.md')
    Assert-True ($referenceCopyReadme.Contains('legal-warning') -and $referenceCopyReadme.Contains('Validate mutable copy isolation')) 'the reference copy wrapper must record provenance and purpose'
    Assert-True ($referenceCopyReadme.Contains('terminal') -or $referenceCopyReadme.Contains('cleanup')) 'the reference copy wrapper must record a cleanup condition'
    Write-Utf8Text -Path (Join-Path $referenceCopyProject 'README.md') -Text "# Modified reference copy`r`n"
    $null = & git -C $referenceCopyProject add -- 'README.md'
    $null = & git -C $referenceCopyProject commit -m 'test: modify reference copy'
    Assert-Equal $referenceBodyHash (Get-FileHash -LiteralPath $referenceBody -Algorithm SHA256).Hash 'modifying the task copy must not change the immutable reference body'
    $workstreamManifestPath = Join-Path $workspaceRoot "$($workstream.path)\workstream.json"
    $workstreamManifestHash = (Get-FileHash -LiteralPath $workstreamManifestPath -Algorithm SHA256).Hash
    Write-Utf8Text -Path $rootHook -Text "#!/bin/sh`nexit 1`n"
    try {
        Assert-Throws -Pattern 'Git commit failed' -Action {
            & (Join-Path $PSScriptRoot 'create-reference-copy.ps1') -WorkspaceRoot $workspaceRoot -WorkstreamId $workstream.workstream_id -ReferenceId 'failure-ref' -Purpose 'Expected copy failure' | Out-Null
        }
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $workspaceRoot "$($workstream.path)\reference-copies\failure-ref"))) 'failed reference-copy creation must remove read-only private Git objects and wrapper'
        Assert-Throws -Pattern 'Git commit failed' -Action {
            & (Join-Path $PSScriptRoot 'update-workstream.ps1') -WorkspaceRoot $workspaceRoot -WorkstreamId $workstream.workstream_id -Status paused | Out-Null
        }
        Assert-Equal $workstreamManifestHash (Get-FileHash -LiteralPath $workstreamManifestPath -Algorithm SHA256).Hash 'failed workstream update must restore the original machine manifest'
    }
    finally { [IO.File]::Delete($rootHook) }
    Assert-Equal '' ((& git -C $workspaceRoot status --short | Out-String).Trim()) 'failed reference-copy and workstream updates must leave management Git clean'
    Write-Utf8Text -Path (Join-Path $worktree 'src\main.c') -Text "int main(void) { return 7; }`r`n"
    $null = & git -C $worktree add -- 'src/main.c'
    $null = & git -C $worktree commit -m 'feat: regression change'
    $publishPlan = (& (Join-Path $PSScriptRoot 'publish-workstream.ps1') -WorkspaceRoot $workspaceRoot -WorkstreamId $workstream.workstream_id | Out-String) | ConvertFrom-Json -Depth 60
    $sourceHash = (Get-FileHash -LiteralPath (Join-Path $sourceRoot 'src\main.c') -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-True $publishPlan.can_apply 'a clean CRLF authority must not conflict with its normalized Git baseline'
    Assert-Equal 1 @($publishPlan.files).Count 'a source publish manifest must exclude reference-copy changes'
    Assert-Equal 0 @($publishPlan.conflicts).Count 'the filter-aware publish plan must contain no false conflict'
    Assert-Equal $sourceHash $publishPlan.files[0].baseline_hash 'baseline and authority hashes must use checked-out file bytes'
    $publish = (& (Join-Path $PSScriptRoot 'publish-workstream.ps1') -WorkspaceRoot $workspaceRoot -WorkstreamId $workstream.workstream_id -ExpectedManifestDigest $publishPlan.manifest_digest -Apply | Out-String) | ConvertFrom-Json -Depth 60
    Assert-Equal 'completed' $publish.status 'the CRLF publish must complete without a false conflict'
    $publishedHash = (Get-FileHash -LiteralPath (Join-Path $sourceRoot 'src\main.c') -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-Equal $publishPlan.files[0].expected_hash $publishedHash 'publish must write the checked-out workstream bytes recorded by the manifest'

    $workspaceModule = Join-Path $workspaceRoot 'workspace-management\tools\lib\workspace-common.psm1'
    Import-Module $workspaceModule -Force
    $targetsPath = Join-Path $workspaceRoot 'workspace-management\config\targets.json'
    $localPath = Join-Path $workspaceRoot 'workspace-management\config\targets.local.json'
    $targets = Read-EwiJson -Path $targetsPath -SchemaPath (Join-Path $workspaceRoot 'workspace-management\schemas\targets.schema.json')
    $local = Read-EwiJson -Path $localPath -SchemaPath (Join-Path $workspaceRoot 'workspace-management\schemas\targets-local.schema.json')
    $builds = $targets.targets.PSObject.Properties[$targetId].Value.builds
    Add-Build -Builds $builds -Id 'partial' -Script 'build-partial.ps1' -OutputPaths @('artifacts') -GeneratedPaths @() -Outputs @('artifacts/a.bin', 'artifacts/b.bin')
    Add-Build -Builds $builds -Id 'full' -Script 'build-full.ps1' -OutputPaths @('artifacts') -GeneratedPaths @() -Outputs @('artifacts/a.bin', 'artifacts/b.bin')
    Add-Build -Builds $builds -Id 'overlap' -Script 'build-overlap.ps1' -OutputPaths @('artifacts') -GeneratedPaths @('artifacts/generated.c') -Outputs @('artifacts/a.bin')
    Add-Build -Builds $builds -Id 'args' -Script 'build-args.ps1' -OutputPaths @('artifacts') -GeneratedPaths @() -Outputs @('artifacts/args.json') -ExtraArgs @('space value', '中文值', 'special&value')
    Add-Build -Builds $builds -Id 'hardware' -Script 'build-hardware.ps1' -OutputPaths @('artifacts') -GeneratedPaths @() -Outputs @('artifacts/a.bin') -ExtraArgs @('flash')
    Add-Build -Builds $builds -Id 'untrusted' -Script 'build-hardware.ps1' -OutputPaths @() -GeneratedPaths @() -Outputs @('artifacts/a.bin')
    $builds.untrusted.command_state = 'verified'
    Add-Build -Builds $builds -Id 'noversion' -Script 'build-hardware.ps1' -OutputPaths @() -GeneratedPaths @() -Outputs @('artifacts/a.bin')
    $builds.noversion.command.tool = 'noversion'
    Add-Build -Builds $builds -Id 'unknown' -Script 'build-unknown.ps1' -OutputPaths @('artifacts') -GeneratedPaths @() -Outputs @('artifacts/unknown.bin')
    Add-Build -Builds $builds -Id 'unconfirmed-path' -Script 'build-hardware.ps1' -OutputPaths @('artifacts') -GeneratedPaths @() -Outputs @('artifacts/a.bin')
    foreach ($configuredBuildId in @('partial', 'full', 'overlap', 'args', 'hardware', 'unknown')) {
        foreach ($field in @('output_paths', 'generated_write_paths')) {
            if (@($builds.PSObject.Properties[$configuredBuildId].Value.$field).Count -eq 0) { continue }
            $targets.field_metadata | Add-Member -NotePropertyName "/targets/$targetId/builds/$configuredBuildId/$field" -NotePropertyValue ([pscustomobject][ordered]@{ provenance = 'confirmed'; verification = 'unverified'; freshness = 'current' })
        }
    }
    $local.tools | Add-Member -NotePropertyName noversion -NotePropertyValue ([pscustomobject][ordered]@{ executable = (Get-Process -Id $PID).Path; version = $null })
    Write-EwiJsonAtomic -Path $targetsPath -Value $targets -SchemaPath (Join-Path $workspaceRoot 'workspace-management\schemas\targets.schema.json')
    Write-EwiJsonAtomic -Path $localPath -Value $local -SchemaPath (Join-Path $workspaceRoot 'workspace-management\schemas\targets-local.schema.json')

    Assert-Throws -Pattern 'Build configuration is stale' -Action {
        & (Join-Path $PSScriptRoot 'invoke-build.ps1') -WorkspaceRoot $workspaceRoot -TargetId $targetId -BuildId 'untrusted' -WorkstreamId $workstream.workstream_id | Out-Null
    }
    Assert-Throws -Pattern 'requires a recorded version' -Action {
        & (Join-Path $PSScriptRoot 'invoke-build.ps1') -WorkspaceRoot $workspaceRoot -TargetId $targetId -BuildId 'noversion' -WorkstreamId $workstream.workstream_id -AllowCandidate | Out-Null
    }
    Assert-Throws -Pattern 'not confirmed and current' -Action {
        & (Join-Path $PSScriptRoot 'invoke-build.ps1') -WorkspaceRoot $workspaceRoot -TargetId $targetId -BuildId 'unconfirmed-path' -WorkstreamId $workstream.workstream_id -AllowCandidate | Out-Null
    }
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $worktree 'hardware-ran.txt'))) 'untrusted and versionless commands must stop before execution'

    Assert-Throws -Pattern 'overlaps generated-write path' -Action {
        & (Join-Path $PSScriptRoot 'invoke-build.ps1') -WorkspaceRoot $workspaceRoot -TargetId $targetId -BuildId 'overlap' -WorkstreamId $workstream.workstream_id -AllowCandidate | Out-Null
    }
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $worktree 'overlap-ran.txt'))) 'overlapping path classes must stop before process execution'
    Assert-Throws -Pattern 'cannot execute flash' -Action {
        & (Join-Path $PSScriptRoot 'invoke-build.ps1') -WorkspaceRoot $workspaceRoot -TargetId $targetId -BuildId 'hardware' -WorkstreamId $workstream.workstream_id -AllowCandidate | Out-Null
    }
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $worktree 'hardware-ran.txt'))) 'a hardware-like build command must stop before process execution'

    $argsBuild = (& (Join-Path $PSScriptRoot 'invoke-build.ps1') -WorkspaceRoot $workspaceRoot -TargetId $targetId -BuildId 'args' -WorkstreamId $workstream.workstream_id -AllowCandidate | Out-String) | ConvertFrom-Json -Depth 40
    Assert-Equal 'passed' $argsBuild.status 'structured arguments with spaces, CJK, and shell metacharacters must execute'
    $receivedArgs = Get-Content -Raw -LiteralPath (Join-Path $worktree 'artifacts\args.json') | ConvertFrom-Json
    Assert-Equal 'space value' $receivedArgs.first 'the spaced argument must remain one argument'
    Assert-Equal '中文值' $receivedArgs.second 'the CJK argument must round-trip unchanged'
    Assert-Equal 'special&value' $receivedArgs.third 'the shell metacharacter must not be reinterpreted'

    [IO.File]::Delete((Join-Path $worktree 'artifacts\args.json'))
    Assert-Throws -Pattern 'Candidate command requires explicit' -Action {
        & (Join-Path $PSScriptRoot 'invoke-build.ps1') -WorkspaceRoot $workspaceRoot -TargetId $targetId -BuildId 'managed' -WorkstreamId $workstream.workstream_id | Out-Null
    }
    $managedBuild = (& (Join-Path $PSScriptRoot 'invoke-build.ps1') -WorkspaceRoot $workspaceRoot -TargetId $targetId -BuildId 'managed' -WorkstreamId $workstream.workstream_id -AllowCandidate | Out-String) | ConvertFrom-Json -Depth 40
    Assert-Equal 'passed' $managedBuild.status 'a candidate build may run only with explicit candidate authorization'
    $managedAfter = Get-Content -Raw -LiteralPath $targetsPath | ConvertFrom-Json -Depth 40
    Assert-Equal 'verified' $managedAfter.targets.PSObject.Properties[$targetId].Value.builds.managed.command_state 'successful candidate evidence must promote the stable build id to verified'

    $unknownBuild = (& (Join-Path $PSScriptRoot 'invoke-build.ps1') -WorkspaceRoot $workspaceRoot -TargetId $targetId -BuildId 'unknown' -WorkstreamId $workstream.workstream_id -AllowCandidate | Out-String) | ConvertFrom-Json -Depth 40
    Assert-Equal 'passed' $unknownBuild.status 'the process and expected artifact may pass despite an unknown project write'
    Assert-Equal 'review_required' $unknownBuild.side_effect_status 'an unknown agent-copy project write must require review'
    $unknownAfter = Get-Content -Raw -LiteralPath $targetsPath | ConvertFrom-Json -Depth 40
    Assert-Equal 'candidate' $unknownAfter.targets.PSObject.Properties[$targetId].Value.builds.unknown.command_state 'unknown side effects must not promote an agent-copy command to verified'
    Assert-Equal 'failed' $unknownAfter.field_metadata.PSObject.Properties["/targets/$targetId/builds/unknown/command"].Value.verification 'unknown side effects must not mark agent-copy command evidence verified'
    [IO.File]::Delete((Join-Path $worktree 'unknown-project-write.txt'))

    $partial = (& (Join-Path $PSScriptRoot 'invoke-build.ps1') -WorkspaceRoot $workspaceRoot -TargetId $targetId -BuildId 'partial' -WorkstreamId $workstream.workstream_id -AllowCandidate | Out-String) | ConvertFrom-Json -Depth 40
    Assert-Equal 'failed' $partial.status 'one updated artifact and one stale artifact must fail the build result'
    Assert-True (@($partial.expected_artifacts | Where-Object { -not $_.updated }).Count -eq 1) 'the stale artifact must be explicit in the result'

    $builtCommit = (& git -C $worktree rev-parse HEAD | Out-String).Trim()
    $full = (& (Join-Path $PSScriptRoot 'invoke-build.ps1') -WorkspaceRoot $workspaceRoot -TargetId $targetId -BuildId 'full' -WorkstreamId $workstream.workstream_id -AllowCandidate | Out-String) | ConvertFrom-Json -Depth 40
    Assert-Equal 'passed' $full.status 'all declared artifacts updated with exit zero must pass'
    $evidence = Get-Content -Raw -LiteralPath (Join-Path $workspaceRoot $full.evidence) | ConvertFrom-Json -Depth 40
    Assert-Equal 'pwsh' $evidence.result.details.tool_id 'build evidence must record the tool id'
    Assert-Equal $PSVersionTable.PSVersion.ToString() $evidence.result.details.tool_version 'build evidence must record the configured tool version'
    Assert-Equal $builtCommit $evidence.result.details.commit 'build evidence must record the actual built commit'

    $artifactHash = (Get-FileHash -LiteralPath (Join-Path $worktree 'artifacts\a.bin') -Algorithm SHA256).Hash
    $makefilePath = Join-Path $worktree 'Makefile'
    $makefileOriginal = [IO.File]::ReadAllText($makefilePath)
    Write-Utf8Text -Path $makefilePath -Text "all:`r`n`t@echo changed configuration`r`n"
    Assert-Throws -Pattern 'Build configuration is stale' -Action {
        & (Join-Path $PSScriptRoot 'invoke-build.ps1') -WorkspaceRoot $workspaceRoot -TargetId $targetId -BuildId 'full' -WorkstreamId $workstream.workstream_id | Out-Null
    }
    Assert-Equal $artifactHash (Get-FileHash -LiteralPath (Join-Path $worktree 'artifacts\a.bin') -Algorithm SHA256).Hash 'a stale project configuration must stop before build output changes'
    $staleTargets = Get-Content -Raw -LiteralPath $targetsPath | ConvertFrom-Json -Depth 40
    Assert-Equal 'stale' $staleTargets.targets.PSObject.Properties[$targetId].Value.builds.full.command_state 'project changes must mark the existing build id stale'
    Assert-Equal 'stale' $staleTargets.field_metadata.PSObject.Properties["/targets/$targetId/builds/full/command"].Value.freshness 'project changes must mark command metadata stale'

    Write-Utf8Text -Path $makefilePath -Text $makefileOriginal
    Import-Module $workspaceModule -Force
    $staleTargets.targets.PSObject.Properties[$targetId].Value.builds.full.command_state = 'verified'
    $staleTargets.field_metadata.PSObject.Properties["/targets/$targetId/builds/full/command"].Value.freshness = 'current'
    $local = Read-EwiJson -Path $localPath -SchemaPath (Join-Path $workspaceRoot 'workspace-management\schemas\targets-local.schema.json')
    $local.tools.pwsh.version = 'changed-tool-version'
    Write-EwiJsonAtomic -Path $targetsPath -Value $staleTargets -SchemaPath (Join-Path $workspaceRoot 'workspace-management\schemas\targets.schema.json')
    Write-EwiJsonAtomic -Path $localPath -Value $local -SchemaPath (Join-Path $workspaceRoot 'workspace-management\schemas\targets-local.schema.json')
    Assert-Throws -Pattern 'Build configuration is stale' -Action {
        & (Join-Path $PSScriptRoot 'invoke-build.ps1') -WorkspaceRoot $workspaceRoot -TargetId $targetId -BuildId 'full' -WorkstreamId $workstream.workstream_id | Out-Null
    }
    $toolStaleTargets = Get-Content -Raw -LiteralPath $targetsPath | ConvertFrom-Json -Depth 40
    Assert-True ($null -ne $toolStaleTargets.targets.PSObject.Properties[$targetId].Value.builds.PSObject.Properties['full']) 'tool changes must preserve the stable build id'
    Assert-Equal 'stale' $toolStaleTargets.targets.PSObject.Properties[$targetId].Value.builds.full.command_state 'tool changes must mark the build command stale'

    $failureInit = (& (Join-Path $PSScriptRoot 'init-workspace.ps1') -WorkspaceRoot $failureRoot -LeaveInitializing | Out-String) | ConvertFrom-Json -Depth 20
    Assert-Equal 'initializing' $failureInit.status 'the failure-injection workspace must start initializing'
    $hook = Join-Path $failureRoot '.git\hooks\pre-commit'
    Write-Utf8Text -Path $hook -Text "#!/bin/sh`nexit 1`n"
    Assert-Throws -Pattern 'Git commit failed' -Action {
        & (Join-Path $PSScriptRoot 'init-workspace.ps1') -WorkspaceRoot $failureRoot -ResumeInitializing | Out-Null
    }
    $failedConfig = Get-Content -Raw -LiteralPath (Join-Path $failureRoot 'workspace-management\config\workspace.json') | ConvertFrom-Json
    Assert-Equal 'initializing' $failedConfig.workspace_state 'a failed activation commit must restore initializing state'
    Assert-Equal '' ((& git -C $failureRoot status --short | Out-String).Trim()) 'a failed activation commit must leave management Git clean'

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
            -not [IO.Path]::GetFileName($resolved).StartsWith('embedded workspace regression ')) {
            throw "Refusing to clean unexpected regression path: $resolved"
        }
        Get-ChildItem -LiteralPath $resolved -Recurse -Force | ForEach-Object { $_.Attributes = 'Normal' }
        (Get-Item -LiteralPath $resolved -Force).Attributes = 'Directory'
        [IO.Directory]::Delete($resolved, $true)
    }
}
