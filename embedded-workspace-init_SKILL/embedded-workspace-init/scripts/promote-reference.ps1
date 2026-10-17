[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $WorkspaceRoot,
    [Parameter(Mandatory)] [ValidatePattern('^[a-z0-9][a-z0-9-]{0,63}$')] [string] $ReferenceId,
    [Parameter(Mandatory)] [ValidatePattern('^[a-z0-9][a-z0-9-]{0,63}$')] [string] $SourceId,
    [switch] $Apply,
    [int] $MutexTimeoutSeconds = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/workspace-common.psm1') -Force

$context = Assert-EwiActiveWorkspace -WorkspaceRoot $WorkspaceRoot
$root = $context.root
$referenceRoot = Join-Path $root "reference-projects/$ReferenceId"
$projectRoot = Join-Path $referenceRoot 'project'
$manifestPath = Join-Path $referenceRoot 'manifest.json'
if (-not (Test-Path -LiteralPath $projectRoot -PathType Container) -or -not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "Reference snapshot is incomplete or missing: $ReferenceId"
}

$manifestSchema = Join-Path $root 'workspace-management/schemas/reference-manifest.schema.json'
$sourceStateSchema = Join-Path $root 'workspace-management/schemas/source-sync-state.schema.json'
$targetsSchema = Join-Path $root 'workspace-management/schemas/targets.schema.json'
$localSchema = Join-Path $root 'workspace-management/schemas/targets-local.schema.json'
$targetsPath = Join-Path $root 'workspace-management/config/targets.json'
$localPath = Join-Path $root 'workspace-management/config/targets.local.json'
$manifest = Read-EwiJson -Path $manifestPath -SchemaPath $manifestSchema
$inventory = Get-EwiFileInventory -Root $projectRoot -MappingId $ReferenceId
if (-not $inventory.scan_complete -or @($inventory.git_topology).Count -gt 0 -or @($inventory.sensitive).Count -gt 0 -or @($inventory.pending).Count -gt 0 -or
    (Get-EwiInventoryDigest $inventory) -ne $manifest.inventory_digest) {
    throw 'Reference snapshot is incomplete, changed, or contains unresolved sensitive/license files.'
}

$targets = Read-EwiJson -Path $targetsPath -SchemaPath $targetsSchema
$existing = $targets.sources.PSObject.Properties[$SourceId]
$report = [pscustomobject][ordered]@{
    status = 'report-only'
    reference_id = $ReferenceId
    source_id = $SourceId
    origin = 'reference-promoted'
    user_source = 'none'
    mappings = @()
    file_count = @($inventory.files).Count
    inventory_digest = Get-EwiInventoryDigest $inventory
    can_apply = ($null -eq $existing)
    blockers = if ($null -eq $existing) { @() } else { @("Source id already exists: $SourceId") }
}
if (-not $Apply) {
    $report | ConvertTo-Json -Depth 10
    return
}
if (-not $report.can_apply) { throw $report.blockers[0] }

$sourceRoot = Join-Path $root "sources/$SourceId"
$integration = Join-Path $sourceRoot 'integration'
$indexPath = Join-Path $root "workspace-management/sync-state/indexes/$SourceId.jsonl"
$statePath = Join-Path $root "workspace-management/sync-state/sources/$SourceId.json"
$result = Invoke-EwiLocked -WorkspaceRoot $root -TimeoutSeconds $MutexTimeoutSeconds -ScriptBlock {
    $null = Assert-EwiActiveWorkspace -WorkspaceRoot $root
    $currentManifest = Read-EwiJson -Path $manifestPath -SchemaPath $manifestSchema
    $currentInventory = Get-EwiFileInventory -Root $projectRoot -MappingId $ReferenceId
    if (-not $currentInventory.scan_complete -or @($currentInventory.git_topology).Count -gt 0 -or @($currentInventory.sensitive).Count -gt 0 -or @($currentInventory.pending).Count -gt 0 -or
        (Get-EwiInventoryDigest $currentInventory) -ne $report.inventory_digest -or
        $currentManifest.inventory_digest -ne $report.inventory_digest) {
        throw 'Reference snapshot changed after promotion planning.'
    }

    $currentTargets = Read-EwiJson -Path $targetsPath -SchemaPath $targetsSchema
    $currentLocal = Read-EwiJson -Path $localPath -SchemaPath $localSchema
    if ($null -ne $currentTargets.sources.PSObject.Properties[$SourceId] -or (Test-Path -LiteralPath $sourceRoot)) {
        throw "Promoted source appeared after planning: $SourceId"
    }
    $targetsOriginal = [IO.File]::ReadAllBytes($targetsPath)
    $localOriginal = [IO.File]::ReadAllBytes($localPath)

    try {
        $null = New-Item -ItemType Directory -Path $integration
        $copied = Copy-EwiSnapshot -Source $projectRoot -Destination $integration -MappingId $ReferenceId
        $readme = "# Source $SourceId`n`nOrigin: reference-promoted from ``$ReferenceId```n`nIntegration: ``sources/$SourceId/integration```n`nThis source has no user authority mapping and cannot be imported or published. Develop through a workstream linked worktree.`n"
        [IO.File]::WriteAllText((Join-Path $sourceRoot 'README.md'), $readme, [Text.UTF8Encoding]::new($false))

        $null = Initialize-EwiGitRepository -Repository $integration
        $gitPaths = @($copied.files | ForEach-Object path)
        $sourceCommit = if ($gitPaths.Count -gt 0) {
            New-EwiGitCommit -Repository $integration -Message "chore: promote reference $ReferenceId" -RelativePaths $gitPaths
        }
        else {
            $null = Invoke-EwiGit -Repository $integration -ArgumentList @('commit', '--allow-empty', '-m', "chore: promote reference $ReferenceId")
            (Invoke-EwiGit -Repository $integration -ArgumentList @('rev-parse', 'HEAD')).StdOut.Trim()
        }

        $currentTargets.sources | Add-Member -NotePropertyName $SourceId -NotePropertyValue ([pscustomobject][ordered]@{
            projects = [pscustomobject]@{}
            origin = 'reference-promoted'
            user_source = 'none'
            integration_path = "sources/$SourceId/integration"
            write_policy = 'workspace-only'
            sync_strategy = 'none'
            mapping_revision = 0
            mappings = @()
        })
        $currentLocal.sources | Add-Member -NotePropertyName $SourceId -NotePropertyValue ([pscustomobject][ordered]@{ mappings = [pscustomobject]@{} })
        Write-EwiJsonAtomic -Path $targetsPath -Value $currentTargets -SchemaPath $targetsSchema
        Write-EwiJsonAtomic -Path $localPath -Value $currentLocal -SchemaPath $localSchema

        Write-EwiJsonLinesAtomic -Path $indexPath -Records @($copied.files) -SchemaPath (Join-Path $root 'workspace-management/schemas/file-index-record.schema.json')
        $state = [pscustomobject][ordered]@{
            schema = 1
            source_id = $SourceId
            mapping_revision = 0
            mapping_digest = Get-EwiTextSha256 (ConvertTo-EwiCanonicalJson @())
            user_baseline_id = $null
            user_baseline_commit = $null
            user_baseline_ref = $null
            captured_at = Get-EwiTimestamp
            scan_complete = $true
            file_index = "../indexes/$SourceId.jsonl"
            build_baselines = [pscustomobject]@{}
        }
        Write-EwiJsonAtomic -Path $statePath -Value $state -SchemaPath $sourceStateSchema
        $managementCommit = New-EwiGitCommit -Repository $root -Message "chore: promote reference $ReferenceId as $SourceId" -RelativePaths @(
            "sources/$SourceId/README.md",
            'workspace-management/config/targets.json'
        )
        return [pscustomobject][ordered]@{
            status = 'promoted'
            reference_id = $ReferenceId
            source_id = $SourceId
            origin = 'reference-promoted'
            user_source = 'none'
            mappings = @()
            source_commit = $sourceCommit
            management_commit = $managementCommit
            files = @($copied.files).Count
        }
    }
    catch {
        [IO.File]::WriteAllBytes($targetsPath, $targetsOriginal)
        [IO.File]::WriteAllBytes($localPath, $localOriginal)
        $null = Invoke-EwiGit -Repository $root -ArgumentList @('reset', '--', 'workspace-management/config/targets.json', "sources/$SourceId/README.md") -AllowFailure
        foreach ($dynamicPath in @($indexPath, $statePath)) { if (Test-Path -LiteralPath $dynamicPath) { [IO.File]::Delete($dynamicPath) } }
        if (Test-Path -LiteralPath $sourceRoot) {
            Get-ChildItem -LiteralPath $sourceRoot -Recurse -Force | ForEach-Object { $_.Attributes = 'Normal' }
            (Get-Item -LiteralPath $sourceRoot -Force).Attributes = 'Directory'
            [IO.Directory]::Delete($sourceRoot, $true)
        }
        throw
    }
}

$detection = (& (Join-Path $PSScriptRoot 'detect-targets.ps1') -WorkspaceRoot $root -Apply | Out-String) | ConvertFrom-Json -Depth 20
$result | Add-Member -NotePropertyName target_detection -NotePropertyValue $detection
$evidenceId = New-EwiEvidenceId 'reference-promotion'
$null = Write-EwiEvidence -WorkspaceRoot $root -EvidenceId $evidenceId -Kind 'source-import' `
    -Subject ([pscustomobject][ordered]@{ workspace = $root; source_id = $SourceId; target_id = $null; build_id = $null; workstream_id = $null; publish_id = $null; reference_id = $ReferenceId }) `
    -Result ([pscustomobject][ordered]@{ status = 'passed'; summary = "Promoted reference '$ReferenceId' as non-publishable source '$SourceId'."; exit_code = 0; details = [pscustomobject][ordered]@{ source_commit = $result.source_commit; files = $result.files; targets_registered = $detection.registered } }) -Artifacts @()
$result | Add-Member -NotePropertyName evidence -NotePropertyValue "workspace-management/evidence/$evidenceId.json"
$result | ConvertTo-Json -Depth 20
