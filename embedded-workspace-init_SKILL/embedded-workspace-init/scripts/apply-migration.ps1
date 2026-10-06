[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $PlanBase64,
    [Parameter(Mandatory)] [ValidatePattern('^[0-9a-f]{64}$')] [string] $ApprovalDigest,
    [int] $MutexTimeoutSeconds = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/workspace-common.psm1') -Force

$payloadJson = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($PlanBase64))
if ((Get-EwiTextSha256 $payloadJson) -ne $ApprovalDigest) {
    throw 'Plan payload does not match the explicitly approved digest.'
}
$plan = $payloadJson | ConvertFrom-Json -Depth 40 -ErrorAction Stop
if ($plan.schema -ne 1 -or $plan.route -ne 'legacy-migration' -or $null -eq $plan.legacy) {
    throw 'The approved payload is not a version 1 legacy migration plan.'
}
$ruleDisposition = if ($plan.legacy.PSObject.Properties.Name -contains 'rule_disposition') { [string]$plan.legacy.rule_disposition } else { 'archive' }
if ($ruleDisposition -notin @('archive', 'preserve-only')) { throw 'Unsupported legacy rule disposition.' }
$registerHistory = if ($plan.legacy.PSObject.Properties.Name -contains 'register_as_history') { [bool]$plan.legacy.register_as_history } else { $true }

$workspace = Resolve-EwiPath -Path ([string]$plan.workspace_root) -AllowMissing
$legacy = Resolve-EwiPath ([string]$plan.legacy.root)
Assert-EwiPathsSeparated -First $workspace -Second $legacy -FirstLabel 'new workspace' -SecondLabel 'legacy workspace' -AllowMissing
if (Test-Path -LiteralPath $workspace) {
    if (@(Get-ChildItem -LiteralPath $workspace -Force).Count -ne 0) {
        throw 'Approved destination is no longer empty.'
    }
}
$legacyInventory = Get-EwiFileInventory -Root $legacy -MappingId 'legacy'
if (-not $legacyInventory.scan_complete -or (Get-EwiInventoryDigest $legacyInventory) -ne $plan.legacy.inventory_digest) {
    throw 'Legacy workspace changed after approval; generate and confirm a new plan.'
}

$copyMappings = @($plan.legacy.copy_mappings)
if ($copyMappings.Count -eq 0) { throw 'Approved migration has no classification mappings.' }
$normalizedMappings = [Collections.Generic.List[object]]::new()
foreach ($mapping in $copyMappings) {
    $sourceRelative = Assert-EwiRelativePath -Path ([string]$mapping.source_relative) -AllowDot
    $action = if ($mapping.PSObject.Properties.Name -contains 'action') { [string]$mapping.action } else { 'copy' }
    if ($action -notin @('copy', 'preserve-only')) { throw "Unsupported migration mapping action: $action" }
    $destinationRelative = $null
    if ($action -eq 'copy') {
        if (-not ($mapping.PSObject.Properties.Name -contains 'destination_relative')) { throw "Copy mapping lacks a destination: $sourceRelative" }
        $destinationRelative = Assert-EwiRelativePath -Path ([string]$mapping.destination_relative)
        if ($destinationRelative -match '^(?:AGENTS(?:\.override)?\.md|README\.md|USER_GUIDE\.md|\.gitignore)$' -or
            $destinationRelative -match '^workspace-management/(?:config|guides|schemas|tools|templates|sync-state)(?:/|$)' -or
            $destinationRelative -match '^sources/[^/]+/integration(?:/|$)' -or
            $destinationRelative -match '^work/[^/]+/sources(?:/|$)') {
            throw "Migration mapping targets a protected managed boundary: $destinationRelative"
        }
        foreach ($ruleFile in @($plan.legacy.rule_files)) {
            if ($sourceRelative -eq '.' -or $ruleFile -eq $sourceRelative -or $ruleFile.StartsWith($sourceRelative.TrimEnd('/') + '/', [StringComparison]::OrdinalIgnoreCase)) {
                throw "Legacy copy mapping '$sourceRelative' includes active rule file '$ruleFile'."
            }
        }
    }
    $normalizedMappings.Add([pscustomobject][ordered]@{
        source_relative = $sourceRelative
        action = $action
        destination_relative = $destinationRelative
        classification = if ($mapping.PSObject.Properties.Name -contains 'classification') { [string]$mapping.classification } else { 'other' }
    })
}

foreach ($file in @($legacyInventory.files)) {
    if ($file.path -in @($plan.legacy.rule_files)) { continue }
    $owners = @($normalizedMappings | Where-Object {
        $_.source_relative -eq '.' -or $file.path -eq $_.source_relative -or
        $file.path.StartsWith($_.source_relative.TrimEnd('/') + '/', [StringComparison]::OrdinalIgnoreCase)
    })
    if ($owners.Count -ne 1) {
        throw "Every legacy file must have exactly one approved copy/preserve classification: $($file.path)"
    }
}
for ($left = 0; $left -lt $normalizedMappings.Count; $left++) {
    for ($right = $left + 1; $right -lt $normalizedMappings.Count; $right++) {
        $a = $normalizedMappings[$left].source_relative
        $b = $normalizedMappings[$right].source_relative
        if ($a -eq '.' -or $b -eq '.' -or $a -eq $b -or $a.StartsWith($b.TrimEnd('/') + '/') -or $b.StartsWith($a.TrimEnd('/') + '/')) {
            throw "Legacy mappings overlap: '$a' and '$b'."
        }
    }
}

$sourceDefinitions = @($plan.source_definitions | ForEach-Object {
    [pscustomobject][ordered]@{
        id = $_.id
        origin = $_.origin
        user_source = $_.user_source
        mappings = @($_.mappings | ForEach-Object {
            [pscustomobject][ordered]@{
                id = $_.id
                source_path = $_.source_path
                integration_subpath = $_.integration_subpath
            }
        })
    }
})
$sourceDefinitionsJson = ConvertTo-EwiCanonicalJson $sourceDefinitions
$initOutput = & (Join-Path $PSScriptRoot 'init-workspace.ps1') `
    -WorkspaceRoot $workspace `
    -SourceDefinitionsJson $sourceDefinitionsJson `
    -LeaveInitializing `
    -MutexTimeoutSeconds $MutexTimeoutSeconds | Out-String
$initialized = $initOutput | ConvertFrom-Json -Depth 20 -ErrorAction Stop
if ($initialized.status -ne 'initializing') { throw 'Migration destination did not remain in initializing state.' }

$result = Invoke-EwiLocked -WorkspaceRoot $workspace -TimeoutSeconds $MutexTimeoutSeconds -ScriptBlock {
    $context = Assert-EwiActiveWorkspace -WorkspaceRoot $workspace -AllowInitializing
    if ($context.workspace.workspace_state -ne 'initializing') { throw 'Migration destination is not initializing.' }
    $currentLegacy = Get-EwiFileInventory -Root $legacy -MappingId 'legacy'
    if ((Get-EwiInventoryDigest $currentLegacy) -ne $plan.legacy.inventory_digest) {
        throw 'Legacy workspace changed after destination initialization.'
    }

    $copiedFiles = [Collections.Generic.List[string]]::new()
    foreach ($mapping in $normalizedMappings) {
        if ($mapping.action -eq 'preserve-only') { continue }
        $source = Join-EwiContainedPath -Root $legacy -RelativePath $mapping.source_relative -AllowDot
        $destination = Join-EwiContainedPath -Root $workspace -RelativePath $mapping.destination_relative
        if (Test-Path -LiteralPath $destination) { throw "Migration destination already exists: $($mapping.destination_relative)" }
        if (Test-Path -LiteralPath $source -PathType Container) {
            $copied = Copy-EwiSnapshot -Source $source -Destination $destination -MappingId 'legacy'
            foreach ($entry in @($copied.files)) {
                $copiedFiles.Add(($mapping.destination_relative.TrimEnd('/') + '/' + $entry.path).TrimStart('/'))
            }
        }
        elseif (Test-Path -LiteralPath $source -PathType Leaf) {
            $parent = Split-Path -Parent $destination
            if (-not (Test-Path -LiteralPath $parent)) { $null = New-Item -ItemType Directory -Path $parent }
            [IO.File]::Copy($source, $destination, $false)
            $expected = @($legacyInventory.files | Where-Object path -eq $mapping.source_relative)
            if ($expected.Count -ne 1 -or (Get-EwiSha256 $destination) -ne $expected[0].sha256) {
                throw "Migrated file hash mismatch: $($mapping.source_relative)"
            }
            $copiedFiles.Add($mapping.destination_relative)
        }
        else {
            throw "Approved legacy path disappeared: $($mapping.source_relative)"
        }
    }

    $timestamp = [DateTimeOffset]::Now.ToString('yyyyMMdd-HHmmss')
    $legacyIdBase = ConvertTo-EwiId ([IO.Path]::GetFileName($legacy)) -MaximumLength 40 -Fallback 'workspace'
    $legacyId = "legacy-$legacyIdBase-$((Get-EwiTextSha256 (Get-EwiPathIdentity $legacy)).Substring(0, 8))"
    $archiveRoot = Join-Path $workspace 'workspace-management/history/legacy-instructions'
    $archiveFiles = [Collections.Generic.List[object]]::new()
    foreach ($ruleName in @($plan.legacy.rule_files | Where-Object { $ruleDisposition -eq 'archive' })) {
        $original = Join-EwiContainedPath -Root $legacy -RelativePath ([string]$ruleName)
        if (-not (Test-Path -LiteralPath $original -PathType Leaf)) { throw "Approved legacy rule disappeared: $ruleName" }
        $hash = Get-EwiSha256 $original
        $kind = if ($ruleName -eq 'AGENTS.override.md') { 'agents-override' } else { 'agents' }
        $originHash = (Get-EwiTextSha256 ([string]$ruleName)).Substring(0, 8)
        $archiveName = "legacy-$kind-$timestamp-$originHash-$($hash.Substring(0, 8)).txt"
        $archive = Join-Path $archiveRoot $archiveName
        [IO.File]::Copy($original, $archive, $false)
        if ((Get-EwiSha256 $archive) -ne $hash) { throw "Legacy rule archive hash mismatch: $ruleName" }
        $archiveFiles.Add([pscustomobject][ordered]@{
            original_path = $original
            archive_path = "workspace-management/history/legacy-instructions/$archiveName"
            archived_at = Get-EwiTimestamp
            sha256 = $hash
            was_active = $true
        })
        $copiedFiles.Add("workspace-management/history/legacy-instructions/$archiveName")
    }
    if ($ruleDisposition -eq 'archive') {
    $manifest = [ordered]@{
        schema = 1
        legacy_workspace_id = $legacyId
        archived_at = Get-EwiTimestamp
        files = @($archiveFiles)
    }
    $manifestPath = Join-Path $archiveRoot 'manifest.json'
    Write-EwiJsonAtomic -Path $manifestPath -Value $manifest -SchemaPath (Join-Path $workspace 'workspace-management/schemas/legacy-instructions-manifest.schema.json')
    $copiedFiles.Add('workspace-management/history/legacy-instructions/manifest.json')
    }

    if ($registerHistory) {
    $localPath = Join-Path $workspace 'workspace-management/config/targets.local.json'
    $localSchema = Join-Path $workspace 'workspace-management/schemas/targets-local.schema.json'
    $local = Read-EwiJson -Path $localPath -SchemaPath $localSchema
    $local.legacy_workspaces | Add-Member -NotePropertyName $legacyId -NotePropertyValue ([pscustomobject][ordered]@{ path = $legacy.Replace('\', '/') })
    Write-EwiJsonAtomic -Path $localPath -Value $local -SchemaPath $localSchema
    }

    $reportTemplate = Get-Content -LiteralPath (Join-Path $workspace 'workspace-management/templates/initialization-report.md') -Raw -Encoding UTF8
    $copySummary = @($normalizedMappings | ForEach-Object { "- $($_.source_relative) -> $(if ($_.action -eq 'copy') { $_.destination_relative } else { 'preserved only at legacy path' }) [$($_.classification)]" }) -join [Environment]::NewLine
    $report = $reportTemplate.Replace('{{LEGACY_ROOT}}', $legacy).
        Replace('{{WORKSPACE_ROOT}}', $workspace).
        Replace('{{MIGRATED_AT}}', (Get-EwiTimestamp)).
        Replace('{{PLAN_DIGEST}}', $ApprovalDigest).
        Replace('{{MANIFEST_DIGEST}}', (Get-EwiInventoryDigest $currentLegacy)).
        Replace('{{COPY_MAPPINGS}}', $copySummary).
        Replace('{{VERIFICATION}}', '- Legacy inventory unchanged.`n- Copied files matched approved hashes.`n- New root paths, schemas, Git boundaries, and approved rule disposition verified.'.Replace('`n', [Environment]::NewLine)).
        Replace('{{PRESERVED_AND_SKIPPED}}', ('- Legacy workspace remained in place and unchanged.`n- Legacy rule disposition: ' + $ruleDisposition + '.`n- Legacy path registered for historical access: ' + $registerHistory + '.`n- User Git, builds, hardware, permissions, and tool installation were not modified.').Replace('`n', [Environment]::NewLine))
    $reportPath = Join-Path $workspace 'workspace-management/migration/initialization-report.md'
    [IO.File]::WriteAllText($reportPath, $report.TrimEnd() + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    $copiedFiles.Add('workspace-management/migration/initialization-report.md')

    $afterLegacy = Get-EwiFileInventory -Root $legacy -MappingId 'legacy'
    if ((Get-EwiInventoryDigest $afterLegacy) -ne $plan.legacy.inventory_digest) {
        throw 'Legacy workspace changed during migration; destination remains initializing.'
    }
    foreach ($guideName in @('lifecycle-and-migration.md', 'sources-targets-and-git.md', 'workstreams-and-concurrency.md', 'synchronization-and-recovery.md', 'build-and-hardware.md', 'references-and-project-knowledge.md', 'configuration-schema.md')) {
        $guide = Join-Path $PSScriptRoot "../references/$guideName"
        $deployed = Join-Path $workspace "workspace-management/guides/$guideName"
        if ((Get-EwiSha256 $guide) -ne (Get-EwiSha256 $deployed)) { throw "Guide hash mismatch: $guideName" }
    }
    $workspacePath = Join-Path $workspace 'workspace-management/config/workspace.json'
    $workspaceSchema = Join-Path $workspace 'workspace-management/schemas/workspace.schema.json'
    $workspaceState = Read-EwiJson -Path $workspacePath -SchemaPath $workspaceSchema
    $workspaceState.migration.migrated_from = $legacyId
    $workspaceState.migration.migrated_at = Get-EwiTimestamp
    Write-EwiJsonAtomic -Path $workspacePath -Value $workspaceState -SchemaPath $workspaceSchema
    $copiedFiles.Add('workspace-management/config/workspace.json')

    $trackedCopied = [Collections.Generic.List[string]]::new()
    foreach ($relative in @($copiedFiles | Sort-Object -Unique)) {
        $ignored = Invoke-EwiGit -Repository $workspace -ArgumentList @('check-ignore', '-q', '--', $relative) -AllowFailure
        if ($ignored.ExitCode -eq 1) { $trackedCopied.Add($relative) }
        elseif ($ignored.ExitCode -notin @(0, 1)) { throw "Could not evaluate management Git ownership: $relative" }
    }
    $migrationCommit = New-EwiGitCommit -Repository $workspace -Message "chore: prepare migrated workspace from $legacyId" -RelativePaths @($trackedCopied)
    $migrationCommit = (Invoke-EwiGit -Repository $workspace -ArgumentList @('rev-parse', 'HEAD')).StdOut.Trim()
    try {
        $workspaceState.workspace_state = 'active'
        Write-EwiJsonAtomic -Path $workspacePath -Value $workspaceState -SchemaPath $workspaceSchema
        $managementCommit = New-EwiGitCommit -Repository $workspace -Message "chore: activate migrated workspace from $legacyId" -RelativePaths @('workspace-management/config/workspace.json')
        $evidenceId = New-EwiEvidenceId 'migration'
        $reportRelative = 'workspace-management/migration/initialization-report.md'
        $reportArtifact = [pscustomobject][ordered]@{
            path = $reportRelative
            media_type = 'text/markdown'
            size = (Get-Item -LiteralPath $reportPath).Length
            sha256 = Get-EwiSha256 $reportPath
        }
        $null = Write-EwiEvidence -WorkspaceRoot $workspace -EvidenceId $evidenceId -Kind migration `
            -Subject ([pscustomobject][ordered]@{ workspace = $workspace; source_id = $null; target_id = $null; build_id = $null; workstream_id = $null; publish_id = $null; reference_id = $null }) `
            -Result ([pscustomobject][ordered]@{ status = 'passed'; summary = 'The approved legacy workspace migration was verified and activated.'; exit_code = 0; details = [pscustomobject][ordered]@{ legacy_workspace_id = $legacyId; migrated_from = $legacy; copied_files = @($copiedFiles).Count; management_commit = $managementCommit } }) `
            -Artifacts @($reportArtifact)
        return [pscustomobject][ordered]@{
            status = 'active'
            workspace_root = $workspace
            migrated_from = $legacy
            legacy_workspace_id = $legacyId
            copied_files = @($copiedFiles).Count
            management_commit = $managementCommit
            old_workspace_unchanged = $true
            evidence = "workspace-management/evidence/$evidenceId.json"
        }
    }
    catch {
        $null = Invoke-EwiGit -Repository $workspace -ArgumentList @('reset', '--mixed', $migrationCommit) -AllowFailure
        $workspaceState.workspace_state = 'initializing'
        Write-EwiJsonAtomic -Path $workspacePath -Value $workspaceState -SchemaPath $workspaceSchema
        $null = Invoke-EwiGit -Repository $workspace -ArgumentList @('reset', '--', 'workspace-management/config/workspace.json') -AllowFailure
        throw
    }
}

$result | ConvertTo-Json -Depth 10
