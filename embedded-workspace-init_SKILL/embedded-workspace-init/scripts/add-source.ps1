[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $WorkspaceRoot,
    [Parameter(Mandatory)] [string] $SourceDefinitionJson,
    [ValidatePattern('^[0-9a-f]{64}$')] [string] $ExpectedPlanDigest,
    [string[]] $KnownActiveWorkspaceRoot = @(),
    [switch] $Apply,
    [int] $MutexTimeoutSeconds = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/workspace-common.psm1') -Force

$context = Assert-EwiActiveWorkspace -WorkspaceRoot $WorkspaceRoot
$root = $context.root
$targetsPath = Join-Path $root 'workspace-management/config/targets.json'
$localPath = Join-Path $root 'workspace-management/config/targets.local.json'
$targetsSchema = Join-Path $root 'workspace-management/schemas/targets.schema.json'
$localSchema = Join-Path $root 'workspace-management/schemas/targets-local.schema.json'
$stateSchema = Join-Path $root 'workspace-management/schemas/source-sync-state.schema.json'
$targets = Read-EwiJson -Path $targetsPath -SchemaPath $targetsSchema
$local = Read-EwiJson -Path $localPath -SchemaPath $localSchema

$planText = & (Join-Path $PSScriptRoot 'plan-migration.ps1') -WorkspaceRoot $root -SourceDefinitionsJson $SourceDefinitionJson -KnownActiveWorkspaceRoot $KnownActiveWorkspaceRoot | Out-String
$basePlan = $planText | ConvertFrom-Json -Depth 50 -ErrorAction Stop
if (-not $basePlan.can_apply) { throw "Source plan is blocked: $([string]::Join('; ', @($basePlan.summary.blockers)))" }
$basePayload = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([string]$basePlan.plan_base64)) | ConvertFrom-Json -Depth 50
$definitions = @($basePayload.source_definitions)
if ($definitions.Count -ne 1) { throw 'Add-source requires exactly one source definition.' }
$definition = $definitions[0]
if ($definition.origin -eq 'reference-promoted') { throw 'Use promote-reference.ps1 for a reference-promoted source.' }
$sourceId = [string]$definition.id
if ($null -ne $targets.sources.PSObject.Properties[$sourceId] -or (Test-Path -LiteralPath (Join-Path $root "sources/$sourceId"))) { throw "Source id already exists: $sourceId" }

$existingMappingIds = @($targets.sources.PSObject.Properties | ForEach-Object { @($_.Value.mappings | ForEach-Object mapping_id) })
foreach ($mapping in @($definition.mappings)) {
    if ($mapping.id -in $existingMappingIds) { throw "Mapping id already exists: $($mapping.id)" }
    foreach ($existingSourceProperty in $local.sources.PSObject.Properties) {
        foreach ($existingMappingProperty in $existingSourceProperty.Value.mappings.PSObject.Properties) {
            Assert-EwiPathsSeparated -First ([string]$mapping.source_path) -Second ([string]$existingMappingProperty.Value.source_path) -FirstLabel "new authority '$($mapping.id)'" -SecondLabel "existing authority '$($existingMappingProperty.Name)'"
        }
    }
}
$targetsHash = Get-EwiSha256 $targetsPath
$localHash = Get-EwiSha256 $localPath
$additionPayload = [pscustomobject][ordered]@{ schema = 1; operation = 'add-source'; workspace_root = $root; source = $definition; targets_hash = $targetsHash; local_hash = $localHash }
$planDigest = Get-EwiTextSha256 (ConvertTo-EwiCanonicalJson $additionPayload)
$report = [pscustomobject][ordered]@{
    status = 'report-only'; source_id = $sourceId; origin = $definition.origin; user_source = $definition.user_source
    mappings = @($definition.mappings); approval_required = $true; plan_digest = $planDigest; can_apply = $true; changed = $false
}
if (-not $Apply) { $report | ConvertTo-Json -Depth 20; return }
if ([string]::IsNullOrWhiteSpace($ExpectedPlanDigest) -or $ExpectedPlanDigest -ne $planDigest) { throw 'Current source plan does not match the explicitly approved digest.' }

$targetsOriginal = [IO.File]::ReadAllBytes($targetsPath)
$localOriginal = [IO.File]::ReadAllBytes($localPath)
$sourceRoot = Join-Path $root "sources/$sourceId"
$integration = Join-Path $sourceRoot 'integration'
$indexPath = Join-Path $root "workspace-management/sync-state/indexes/$sourceId.jsonl"
$statePath = Join-Path $root "workspace-management/sync-state/sources/$sourceId.json"
$result = Invoke-EwiLocked -WorkspaceRoot $root -TimeoutSeconds $MutexTimeoutSeconds -ScriptBlock {
    $null = Assert-EwiActiveWorkspace -WorkspaceRoot $root
    if ((Get-EwiSha256 $targetsPath) -ne $targetsHash -or (Get-EwiSha256 $localPath) -ne $localHash) { throw 'Workspace source configuration changed after addition planning.' }
    $currentTargets = Read-EwiJson -Path $targetsPath -SchemaPath $targetsSchema
    $currentLocal = Read-EwiJson -Path $localPath -SchemaPath $localSchema
    if ($null -ne $currentTargets.sources.PSObject.Properties[$sourceId] -or (Test-Path -LiteralPath $sourceRoot)) { throw "Source appeared after planning: $sourceId" }

    try {
        $null = New-Item -ItemType Directory -Path $integration
        $portableMappings = [Collections.Generic.List[object]]::new()
        $localMappings = [ordered]@{}
        $indexEntries = [Collections.Generic.List[object]]::new()
        $gitPaths = [Collections.Generic.List[string]]::new()
        foreach ($mapping in @($definition.mappings)) {
            $subpath = Assert-EwiRelativePath -Path ([string]$mapping.integration_subpath) -AllowDot
            $destination = Join-EwiContainedPath -Root $integration -RelativePath $subpath -AllowDot
            $copied = Copy-EwiSnapshot -Source ([string]$mapping.source_path) -Destination $destination -MappingId ([string]$mapping.id)
            foreach ($entry in @($copied.files)) {
                $indexEntries.Add($entry)
                $gitPaths.Add($(if ($subpath -eq '.') { [string]$entry.path } else { "$subpath/$($entry.path)" }))
            }
            $portableMappings.Add([pscustomobject][ordered]@{ mapping_id = [string]$mapping.id; integration_subpath = $subpath; kind = 'directory' })
            $localMappings[[string]$mapping.id] = [ordered]@{ source_path = ([string]$mapping.source_path).Replace('\', '/'); user_git = [ordered]@{ status = 'deferred'; repository_path = $null } }
        }
        $hasUserSource = [string]$definition.user_source -eq 'configured'
        $null = Initialize-EwiGitRepository -Repository $integration
        $sourceCommit = if ($gitPaths.Count -gt 0) {
            New-EwiGitCommit -Repository $integration -Message $(if ($hasUserSource) { 'chore: establish user synchronization baseline' } else { 'chore: establish source baseline' }) -RelativePaths @($gitPaths)
        }
        else {
            $null = Invoke-EwiGit -Repository $integration -ArgumentList @('commit', '--allow-empty', '-m', 'chore: establish source baseline')
            (Invoke-EwiGit -Repository $integration -ArgumentList @('rev-parse', 'HEAD')).StdOut.Trim()
        }
        $sourceValue = [pscustomobject][ordered]@{
            origin = [string]$definition.origin; user_source = [string]$definition.user_source; integration_path = "sources/$sourceId/integration"
            write_policy = if ($hasUserSource) { 'explicit-publish-only' } else { 'workspace-only' }
            sync_strategy = if ($hasUserSource) { 'three-way' } else { 'none' }
            mapping_revision = if ($hasUserSource) { 1 } else { 0 }; mappings = @($portableMappings)
        }
        $sourceValue | Add-Member -NotePropertyName projects -NotePropertyValue ([pscustomobject]@{})
        $currentTargets.sources | Add-Member -NotePropertyName $sourceId -NotePropertyValue $sourceValue
        $currentLocal.sources | Add-Member -NotePropertyName $sourceId -NotePropertyValue ([pscustomobject][ordered]@{ mappings = [pscustomobject]$localMappings })
        Write-EwiJsonAtomic -Path $targetsPath -Value $currentTargets -SchemaPath $targetsSchema
        Write-EwiJsonAtomic -Path $localPath -Value $currentLocal -SchemaPath $localSchema
        Write-EwiJsonLinesAtomic -Path $indexPath -Records @($indexEntries) -SchemaPath (Join-Path $root 'workspace-management/schemas/file-index-record.schema.json')
        $baselineId = if ($hasUserSource) { 'baseline-' + [DateTimeOffset]::Now.ToString('yyyyMMddHHmmssfff') } else { $null }
        $baselineRef = if ($hasUserSource) { "refs/agent/user-baselines/$baselineId" } else { $null }
        if ($hasUserSource) { $null = Invoke-EwiGit -Repository $integration -ArgumentList @('update-ref', $baselineRef, $sourceCommit) }
        $state = [pscustomobject][ordered]@{
            schema = 1; source_id = $sourceId; mapping_revision = [int]$sourceValue.mapping_revision
            mapping_digest = if ($hasUserSource) { Get-EwiMappingDigest -Mappings @($portableMappings) -LocalMappings $localMappings } else { Get-EwiTextSha256 (ConvertTo-EwiCanonicalJson @()) }; user_baseline_id = $baselineId
            user_baseline_commit = if ($hasUserSource) { $sourceCommit } else { $null }; user_baseline_ref = $baselineRef
            captured_at = Get-EwiTimestamp; scan_complete = $true; file_index = "../indexes/$sourceId.jsonl"; build_baselines = [pscustomobject]@{}
        }
        Write-EwiJsonAtomic -Path $statePath -Value $state -SchemaPath $stateSchema
        $readme = "# Source $sourceId`n`nOrigin: $($definition.origin)`n`nIntegration: ``sources/$sourceId/integration```n`nThe integration directory is owned by source-private Git. Develop in workstream linked worktrees; user-backed writes require explicit publish.`n"
        [IO.File]::WriteAllText((Join-Path $sourceRoot 'README.md'), $readme, [Text.UTF8Encoding]::new($false))
        $managementCommit = New-EwiGitCommit -Repository $root -Message "chore: add source $sourceId" -RelativePaths @('workspace-management/config/targets.json', "sources/$sourceId/README.md")
        $evidenceId = New-EwiEvidenceId 'source-add'
        $null = Write-EwiEvidence -WorkspaceRoot $root -EvidenceId $evidenceId -Kind 'source-import' `
            -Subject ([pscustomobject][ordered]@{ workspace = $root; source_id = $sourceId; target_id = $null; build_id = $null; workstream_id = $null; publish_id = $null; reference_id = $null }) `
            -Result ([pscustomobject][ordered]@{ status = 'passed'; summary = "Added source '$sourceId' to the active workspace."; exit_code = 0; details = [pscustomobject][ordered]@{ origin = $definition.origin; files = $indexEntries.Count; source_commit = $sourceCommit; management_commit = $managementCommit } }) -Artifacts @()
        return [pscustomobject][ordered]@{
            status = 'added'; source_id = $sourceId; origin = $definition.origin; user_source = $definition.user_source; source_commit = $sourceCommit
            user_baseline_ref = $baselineRef; files = $indexEntries.Count; management_commit = $managementCommit; evidence = "workspace-management/evidence/$evidenceId.json"
        }
    }
    catch {
        [IO.File]::WriteAllBytes($targetsPath, $targetsOriginal)
        [IO.File]::WriteAllBytes($localPath, $localOriginal)
        $null = Invoke-EwiGit -Repository $root -ArgumentList @('reset', '--', 'workspace-management/config/targets.json', "sources/$sourceId/README.md") -AllowFailure
        foreach ($path in @($indexPath, $statePath)) { if (Test-Path -LiteralPath $path) { [IO.File]::Delete($path) } }
        if (Test-Path -LiteralPath $sourceRoot) {
            Get-ChildItem -LiteralPath $sourceRoot -Recurse -Force | ForEach-Object { $_.Attributes = 'Normal' }
            (Get-Item -LiteralPath $sourceRoot -Force).Attributes = 'Directory'
            [IO.Directory]::Delete($sourceRoot, $true)
        }
        throw
    }
}

$detection = (& (Join-Path $PSScriptRoot 'detect-targets.ps1') -WorkspaceRoot $root -Apply | Out-String) | ConvertFrom-Json -Depth 30
$result | Add-Member -NotePropertyName target_detection -NotePropertyValue $detection
$result | ConvertTo-Json -Depth 30
