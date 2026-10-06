[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $WorkspaceRoot,
    [Parameter(Mandatory)] [ValidatePattern('^[a-z0-9][a-z0-9-]{0,63}$')] [string] $SourceId,
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
$targets = Read-EwiJson -Path $targetsPath -SchemaPath (Join-Path $root 'workspace-management/schemas/targets.schema.json')
$local = Read-EwiJson -Path $localPath -SchemaPath (Join-Path $root 'workspace-management/schemas/targets-local.schema.json')
$sourceProperty = $targets.sources.PSObject.Properties[$SourceId]
$localProperty = $local.sources.PSObject.Properties[$SourceId]
if ($null -eq $sourceProperty -or $null -eq $localProperty) { throw "Unknown or locally unbound source: $SourceId" }
$source = $sourceProperty.Value
$sourceLocal = $localProperty.Value
if ($source.user_source -ne 'configured' -or $source.sync_strategy -ne 'three-way') {
    throw "Source '$SourceId' has no user authority to import."
}

$statePath = Join-Path $root "workspace-management/sync-state/sources/$SourceId.json"
$stateSchema = Join-Path $root 'workspace-management/schemas/source-sync-state.schema.json'
$fileIndexSchema = Join-Path $root 'workspace-management/schemas/file-index-record.schema.json'
$state = Read-EwiJson -Path $statePath -SchemaPath $stateSchema
if (-not $state.scan_complete -or -not $state.user_baseline_commit) {
    throw "Source '$SourceId' has no complete retrievable user baseline."
}
if ($state.mapping_digest -ne (Get-EwiMappingDigest -Mappings @($source.mappings) -LocalMappings $sourceLocal.mappings)) {
    throw "Source '$SourceId' mapping digest is stale."
}
$indexPath = Join-Path (Split-Path -Parent $statePath) $state.file_index
$indexPath = Resolve-EwiPath $indexPath

function Read-Index {
    param([Parameter(Mandatory)] [string] $Path)
    $values = [ordered]@{}
    foreach ($line in [IO.File]::ReadLines($Path)) {
        if ([string]::IsNullOrWhiteSpace($line)) { throw "Blank or partial JSONL record in $Path" }
        if (-not (Test-Json -Json $line -SchemaFile $fileIndexSchema -ErrorAction SilentlyContinue)) { throw "JSONL record does not match schema '$fileIndexSchema': $Path" }
        $entry = $line | ConvertFrom-Json -Depth 20 -ErrorAction Stop
        $key = "$($entry.mapping_id)|$(([string]$entry.path).ToLowerInvariant())"
        if ($values.Contains($key)) { throw "Duplicate file index key: $key" }
        $values[$key] = $entry
    }
    return $values
}

function Inventory-ToMap {
    param([Parameter(Mandatory)] $Inventory)
    $values = [ordered]@{}
    foreach ($entry in @($Inventory.files)) {
        $values["$($entry.mapping_id)|$(([string]$entry.path).ToLowerInvariant())"] = $entry
    }
    return $values
}

function Get-HashOrNull {
    param($Map, [string] $Key)
    if ($Map.Contains($Key)) { return [string]$Map[$Key].sha256 }
    return $null
}

function Get-SourceOutputPatterns {
    param($Targets, [string] $CurrentSourceId)
    $patterns = [Collections.Generic.List[string]]::new()
    foreach ($targetProperty in $Targets.targets.PSObject.Properties) {
        $targetValue = $targetProperty.Value
        if ($targetValue.source -ne $CurrentSourceId) { continue }
        $targetPrefix = ([string]$targetValue.path).Replace('\', '/').TrimEnd('/')
        foreach ($buildProperty in $targetValue.builds.PSObject.Properties) {
            $metadata = $Targets.field_metadata.PSObject.Properties["/targets/$($targetProperty.Name)/builds/$($buildProperty.Name)/output_paths"]
            if ($null -eq $metadata -or $metadata.Value.provenance -ne 'confirmed' -or $metadata.Value.freshness -ne 'current') { continue }
            foreach ($output in @($buildProperty.Value.output_paths)) {
                $relative = ([string]$output).Replace('\', '/')
                $patterns.Add($(if ($targetPrefix -eq '.') { $relative } else { "$targetPrefix/$relative" }))
            }
        }
    }
    return @($patterns)
}

function Test-OutputPath {
    param([string] $IntegrationPath, [string[]] $Patterns)
    $path = $IntegrationPath.Replace('\', '/')
    foreach ($pattern in $Patterns) {
        $glob = $pattern.Replace('**', '*')
        if ($path -like $glob -or $path.StartsWith($glob.TrimEnd([char[]]@('*', '/')) + '/', [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

function Select-ManagedInventory {
    param($Inventory, [string] $IntegrationSubpath, [string[]] $Patterns)
    $subpath = $IntegrationSubpath.Replace('\', '/').TrimEnd('/')
    $managed = @($Inventory.files | Where-Object {
        $integrationPath = if ($subpath -eq '.') { $_.path } else { "$subpath/$($_.path)" }
        -not (Test-OutputPath -IntegrationPath $integrationPath -Patterns $Patterns)
    })
    return [pscustomobject][ordered]@{
        root = $Inventory.root
        scan_complete = $Inventory.scan_complete
        files = $managed
        excluded = @($Inventory.excluded)
        sensitive = @($Inventory.sensitive)
        pending = @($Inventory.pending)
        warnings = @($Inventory.warnings)
        git_topology = @($Inventory.git_topology)
        links = @($Inventory.links)
        errors = @($Inventory.errors)
    }
}

function Get-MeaningfulGitStatus {
    param([string] $Repository, [string[]] $IgnoredOutputPatterns)
    $raw = (Invoke-EwiGit -Repository $Repository -ArgumentList @('status', '--porcelain=v1', '-z')).StdOut
    $meaningful = [Collections.Generic.List[string]]::new()
    foreach ($entry in @($raw.Split([char]0, [StringSplitOptions]::RemoveEmptyEntries))) {
        if ($entry.Length -lt 4) { $meaningful.Add($entry); continue }
        $path = $entry.Substring(3).Replace('\', '/')
        $ignored = $false
        foreach ($pattern in $IgnoredOutputPatterns) {
            $glob = $pattern.Replace('**', '*')
            if ($path -like $glob -or $path.StartsWith($glob.TrimEnd([char[]]@('*', '/')) + '/', [StringComparison]::OrdinalIgnoreCase)) {
                $ignored = $true
                break
            }
        }
        if (-not $ignored) { $meaningful.Add($entry) }
    }
    return @($meaningful)
}

$baseline = Read-Index $indexPath
$userMap = [ordered]@{}
$agentMap = [ordered]@{}
$mappingDetails = [ordered]@{}
$allUserEntries = [Collections.Generic.List[object]]::new()
$integrationRoot = Join-EwiContainedPath -Root $root -RelativePath ([string]$source.integration_path)
$outputPatterns = Get-SourceOutputPatterns -Targets $targets -CurrentSourceId $SourceId
foreach ($key in @($baseline.Keys)) {
    $parts = $key.Split('|', 2)
    $mapping = @($source.mappings | Where-Object mapping_id -eq $parts[0])
    if ($mapping.Count -ne 1) { throw "Baseline index mapping is no longer unique: $key" }
    $integrationPath = if ($mapping[0].integration_subpath -eq '.') { [string]$baseline[$key].path } else { "$($mapping[0].integration_subpath)/$($baseline[$key].path)" }
    if (Test-OutputPath -IntegrationPath $integrationPath -Patterns $outputPatterns) { $baseline.Remove($key) }
}
foreach ($mapping in @($source.mappings)) {
    $mappingId = [string]$mapping.mapping_id
    $localMapping = $sourceLocal.mappings.PSObject.Properties[$mappingId]
    if ($null -eq $localMapping) { throw "Local mapping is missing: $mappingId" }
    $authority = Resolve-EwiPath ([string]$localMapping.Value.source_path)
    Assert-EwiPathsSeparated -First $root -Second $authority -FirstLabel 'workspace' -SecondLabel "authority '$mappingId'"
    $fullUserInventory = Get-EwiFileInventory -Root $authority -MappingId $mappingId
    if (-not $fullUserInventory.scan_complete -or @($fullUserInventory.git_topology).Count -gt 0) { throw "User scan is incomplete or contains linked-worktree/nested Git topology for mapping '$mappingId'." }
    if (@($fullUserInventory.sensitive).Count -gt 0) {
        throw "New sensitive files require review before import: $([string]::Join(', ', @($fullUserInventory.sensitive)))"
    }
    if (@($fullUserInventory.pending).Count -gt 0) {
        throw "Ambiguous license or activation files require confirmation before import: $([string]::Join(', ', @($fullUserInventory.pending)))"
    }
    $integrationSubroot = Join-EwiContainedPath -Root $integrationRoot -RelativePath ([string]$mapping.integration_subpath) -AllowDot
    $fullAgentInventory = Get-EwiFileInventory -Root $integrationSubroot -MappingId $mappingId
    if (-not $fullAgentInventory.scan_complete) { throw "Integration scan is incomplete for mapping '$mappingId'." }
    $userInventory = Select-ManagedInventory -Inventory $fullUserInventory -IntegrationSubpath ([string]$mapping.integration_subpath) -Patterns $outputPatterns
    $agentInventory = Select-ManagedInventory -Inventory $fullAgentInventory -IntegrationSubpath ([string]$mapping.integration_subpath) -Patterns $outputPatterns
    foreach ($entry in @($userInventory.files)) { $allUserEntries.Add($entry) }
    foreach ($pair in (Inventory-ToMap $userInventory).GetEnumerator()) { $userMap[$pair.Key] = $pair.Value }
    foreach ($pair in (Inventory-ToMap $agentInventory).GetEnumerator()) { $agentMap[$pair.Key] = $pair.Value }
    $mappingDetails[$mappingId] = [pscustomobject][ordered]@{
        authority = $authority
        integration = $integrationSubroot
        source_digest = Get-EwiInventoryDigest $userInventory
    }
}

$changes = [Collections.Generic.List[object]]::new()
$conflicts = [Collections.Generic.List[object]]::new()
$keys = @($baseline.Keys + $userMap.Keys + $agentMap.Keys | Sort-Object -Unique)
foreach ($key in $keys) {
    $baselineHash = Get-HashOrNull $baseline $key
    $userHash = Get-HashOrNull $userMap $key
    $agentHash = Get-HashOrNull $agentMap $key
    $userChanged = $userHash -ne $baselineHash
        if (-not $userChanged) { continue }
    $parts = $key.Split('|', 2)
    $operation = if ($null -eq $userHash) { 'delete' } elseif ($null -eq $baselineHash) { 'add' } else { 'modify' }
    $item = [pscustomobject][ordered]@{
        mapping_id = $parts[0]
        path = if ($userMap.Contains($key)) { $userMap[$key].path } elseif ($baseline.Contains($key)) { $baseline[$key].path } else { $agentMap[$key].path }
        operation = $operation
        baseline_hash = $baselineHash
        user_hash = $userHash
        agent_hash = $agentHash
    }
        $changes.Add($item)
}

$integrationHead = (Invoke-EwiGit -Repository $integrationRoot -ArgumentList @('rev-parse', 'HEAD')).StdOut.Trim()
$integrationStatus = @(Get-MeaningfulGitStatus -Repository $integrationRoot -IgnoredOutputPatterns $outputPatterns)
$blockers = [Collections.Generic.List[string]]::new()
if ($integrationHead -ne $state.user_baseline_commit) { $blockers.Add('Integration HEAD is not the current pure user baseline; aggregate changes require explicit coordination.') }
if ($integrationStatus.Count -gt 0) { $blockers.Add('Integration worktree is dirty outside confirmed output paths.') }
if ($conflicts.Count -gt 0) { $blockers.Add('User and Agent changed the same file state; automatic import is unsafe.') }

$workstreams = [Collections.Generic.List[object]]::new()
foreach ($file in Get-ChildItem -LiteralPath (Join-Path $root 'work') -Filter 'workstream.json' -File -Recurse -Depth 2 -ErrorAction SilentlyContinue) {
    $workstream = Read-EwiJson -Path $file.FullName -SchemaPath (Join-Path $root 'workspace-management/schemas/workstream.schema.json')
    $ref = $workstream.agent.refs.PSObject.Properties[$SourceId]
    if ($null -eq $ref) { continue }
    if ($workstream.status -in @('completed', 'abandoned') -and -not $workstream.has_unresolved_changes) { continue }
    if (@($workstream.dependencies).Count -gt 0) {
        $blockers.Add("Workstream '$($workstream.id)' has pinned dependencies; version 1 import replay requires explicit dependency coordination.")
        continue
    }
    $worktree = Join-EwiContainedPath -Root $root -RelativePath ([string]$ref.Value.worktree)
    $status = @(Get-MeaningfulGitStatus -Repository $worktree -IgnoredOutputPatterns $outputPatterns)
    if ($status.Count -gt 0) {
        $blockers.Add("Workstream '$($workstream.id)' has uncommitted changes; checkpoint it before import.")
    }
    if ($ref.Value.user_baseline_commit -ne $state.user_baseline_commit) {
        $blockers.Add("Workstream '$($workstream.id)' uses a different user baseline.")
    }
    $workstreams.Add([pscustomobject][ordered]@{
        path = $file.FullName
        manifest = $workstream
        worktree = $worktree
        branch = [string]$ref.Value.branch
        old_head = (Invoke-EwiGit -Repository $worktree -ArgumentList @('rev-parse', 'HEAD')).StdOut.Trim()
    })
}

foreach ($workstreamItem in $workstreams) {
    $diff = Invoke-EwiGit -Repository $workstreamItem.worktree -ArgumentList @('diff', '--name-status', '--no-renames', "$($state.user_baseline_commit)..$($workstreamItem.old_head)")
    foreach ($line in @($diff.StdOut -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $parts = $line -split "`t", 2
        if ($parts.Count -ne 2) { throw "Unsupported workstream diff entry: $line" }
        $integrationPath = ([string]$parts[1]).Replace('\', '/')
        $matches = [Collections.Generic.List[object]]::new()
        foreach ($mapping in @($source.mappings)) {
            $subpath = ([string]$mapping.integration_subpath).Replace('\', '/').TrimEnd('/')
            $relative = $null
            if ($subpath -eq '.') { $relative = $integrationPath }
            elseif ($integrationPath -eq $subpath) { $relative = '.' }
            elseif ($integrationPath.StartsWith($subpath + '/', [StringComparison]::OrdinalIgnoreCase)) { $relative = $integrationPath.Substring($subpath.Length + 1) }
            if ($null -ne $relative) {
                $matches.Add([pscustomobject]@{ mapping_id = [string]$mapping.mapping_id; path = $relative })
            }
        }
        if ($matches.Count -ne 1) {
            $blockers.Add("Workstream '$($workstreamItem.manifest.id)' changed a path without one reversible mapping: $integrationPath")
            continue
        }
        $match = $matches[0]
        $key = "$($match.mapping_id)|$(([string]$match.path).ToLowerInvariant())"
        $baselineHash = Get-HashOrNull $baseline $key
        $userHash = Get-HashOrNull $userMap $key
        if ($baselineHash -eq $userHash) { continue }
        # A shared text file can merge when user and task edits touch different regions.
        # The locked Git rebase below performs the actual three-way check and rolls back on conflict.
    }
}

$report = [pscustomobject][ordered]@{
    status = 'report-only'
    source_id = $SourceId
    changes = @($changes)
    conflicts = @($conflicts)
    blockers = @($blockers | Sort-Object -Unique)
    can_apply = ($blockers.Count -eq 0)
    changed = $false
}
if (-not $Apply -or $changes.Count -eq 0 -or $blockers.Count -gt 0) {
    if ($Apply -and $changes.Count -eq 0 -and $blockers.Count -eq 0) { $report.status = 'unchanged' }
    $report | ConvertTo-Json -Depth 12
    return
}

$targetsHash = Get-EwiSha256 $targetsPath
$localHash = Get-EwiSha256 $localPath
$stateHash = Get-EwiSha256 $statePath
$indexHash = Get-EwiSha256 $indexPath
$stateOriginal = [IO.File]::ReadAllBytes($statePath)
$indexOriginal = [IO.File]::ReadAllBytes($indexPath)
$result = Invoke-EwiLocked -WorkspaceRoot $root -TimeoutSeconds $MutexTimeoutSeconds -ScriptBlock {
    $null = Assert-EwiActiveWorkspace -WorkspaceRoot $root
    if ((Get-EwiSha256 $targetsPath) -ne $targetsHash -or (Get-EwiSha256 $localPath) -ne $localHash -or
        (Get-EwiSha256 $statePath) -ne $stateHash -or (Get-EwiSha256 $indexPath) -ne $indexHash) {
        throw 'Source configuration or baseline changed after import planning.'
    }
    $nonterminal = @(Get-ChildItem -LiteralPath (Join-Path $root 'workspace-management/sync-state/transactions') -Filter '*.json' -File -ErrorAction SilentlyContinue | Where-Object {
        $tx = Read-EwiJson -Path $_.FullName -SchemaPath (Join-Path $root 'workspace-management/schemas/publish-transaction.schema.json')
        $tx.state -notin @('completed', 'conflicted', 'rolled_back')
    })
    if ($nonterminal.Count -gt 0) { throw 'A nonterminal publish/recovery transaction blocks import.' }
    if ((Invoke-EwiGit -Repository $integrationRoot -ArgumentList @('rev-parse', 'HEAD')).StdOut.Trim() -ne $state.user_baseline_commit -or
        @(Get-MeaningfulGitStatus -Repository $integrationRoot -IgnoredOutputPatterns $outputPatterns).Count -gt 0) {
        throw 'Integration state changed after planning.'
    }

    foreach ($mappingId in $mappingDetails.Keys) {
        $mappingConfig = @($source.mappings | Where-Object mapping_id -eq $mappingId)[0]
        $freshFull = Get-EwiFileInventory -Root $mappingDetails[$mappingId].authority -MappingId $mappingId
        if (-not $freshFull.scan_complete -or @($freshFull.git_topology).Count -gt 0 -or @($freshFull.sensitive).Count -gt 0 -or @($freshFull.pending).Count -gt 0) {
            throw "Source became incomplete or gained unresolved sensitive files after planning: $mappingId"
        }
        $fresh = Select-ManagedInventory -Inventory $freshFull -IntegrationSubpath ([string]$mappingConfig.integration_subpath) -Patterns $outputPatterns
        if ((Get-EwiInventoryDigest $fresh) -ne $mappingDetails[$mappingId].source_digest) {
            throw "User source changed after planning: $mappingId"
        }
    }

    $oldBaseline = [string]$state.user_baseline_commit
    $newCommit = $null
    $rebased = [Collections.Generic.List[object]]::new()
    $workstreamSnapshots = [ordered]@{}
    $newBaselineRef = $null
    try {
        foreach ($change in $changes) {
            $details = $mappingDetails[$change.mapping_id]
            $sourceFile = Join-EwiContainedPath -Root $details.authority -RelativePath $change.path
            $destinationFile = Join-EwiContainedPath -Root $details.integration -RelativePath $change.path
            if ($change.operation -eq 'delete') {
                if (Test-Path -LiteralPath $destinationFile -PathType Leaf) { [IO.File]::Delete($destinationFile) }
            }
            else {
                $parent = Split-Path -Parent $destinationFile
                if (-not (Test-Path -LiteralPath $parent)) { $null = New-Item -ItemType Directory -Path $parent }
                $temporary = Join-Path $parent ('.' + [IO.Path]::GetFileName($destinationFile) + '.' + [Guid]::NewGuid().ToString('N') + '.tmp')
                try {
                    [IO.File]::Copy($sourceFile, $temporary, $true)
                    if ((Get-EwiSha256 $temporary) -ne $change.user_hash) { throw "Import source hash changed: $($change.path)" }
                    [IO.File]::Move($temporary, $destinationFile, $true)
                }
                finally {
                    if (Test-Path -LiteralPath $temporary) { [IO.File]::Delete($temporary) }
                }
            }
        }
        $gitPaths = @($changes | ForEach-Object {
            $subpath = @($source.mappings | Where-Object mapping_id -eq $_.mapping_id)[0].integration_subpath
            if ($subpath -eq '.') { $_.path } else { "$subpath/$($_.path)" }
        })
        $newCommit = New-EwiGitCommit -Repository $integrationRoot -Message 'chore: import saved user changes' -RelativePaths $gitPaths
        if (-not $newCommit) { throw 'Expected import changes did not produce a source-private commit.' }

        foreach ($workstreamItem in $workstreams) {
            $workstreamSnapshots[$workstreamItem.path] = [IO.File]::ReadAllBytes($workstreamItem.path)
            $null = Invoke-EwiGit -Repository $workstreamItem.worktree -ArgumentList @('rebase', '--onto', $newCommit, $oldBaseline, $workstreamItem.branch)
            $rebased.Add($workstreamItem)
        }
        foreach ($workstreamItem in $workstreams) {
            $manifest = $workstreamItem.manifest
            $ref = $manifest.agent.refs.PSObject.Properties[$SourceId].Value
            $ref.user_baseline_commit = $newCommit
            $ref.task_base_commit = $newCommit
            $ref.head_commit = $null
            $manifest.updated_at = Get-EwiTimestamp
            Write-EwiJsonAtomic -Path $workstreamItem.path -Value $manifest -SchemaPath (Join-Path $root 'workspace-management/schemas/workstream.schema.json')
        }

        $baselineId = 'baseline-' + [DateTimeOffset]::Now.ToString('yyyyMMddHHmmssfff')
        $baselineRef = "refs/agent/user-baselines/$baselineId"
        $newBaselineRef = $baselineRef
        $null = Invoke-EwiGit -Repository $integrationRoot -ArgumentList @('update-ref', $baselineRef, $newCommit)
        Write-EwiJsonLinesAtomic -Path $indexPath -Records @($allUserEntries) -SchemaPath (Join-Path $root 'workspace-management/schemas/file-index-record.schema.json')
        $state.user_baseline_id = $baselineId
        $state.user_baseline_commit = $newCommit
        $state.user_baseline_ref = $baselineRef
        $state.captured_at = Get-EwiTimestamp
        $state.scan_complete = $true
        Write-EwiJsonAtomic -Path $statePath -Value $state -SchemaPath $stateSchema
        if ($workstreams.Count -gt 0) {
            $relativeWorkstreams = @($workstreams | ForEach-Object { [IO.Path]::GetRelativePath($root, $_.path).Replace('\', '/') })
            $null = New-EwiGitCommit -Repository $root -Message "chore: rebase workstreams after importing $SourceId" -RelativePaths $relativeWorkstreams
        }
        return [pscustomobject][ordered]@{
            status = 'imported'
            source_id = $SourceId
            files_changed = $changes.Count
            user_baseline_commit = $newCommit
            user_baseline_ref = $baselineRef
            workstreams_rebased = @($workstreams | ForEach-Object { $_.manifest.id })
        }
    }
    catch {
        foreach ($workstreamItem in @($workstreams)) {
            $null = Invoke-EwiGit -Repository $workstreamItem.worktree -ArgumentList @('rebase', '--abort') -AllowFailure
            $null = Invoke-EwiGit -Repository $workstreamItem.worktree -ArgumentList @('reset', '--hard', $workstreamItem.old_head) -AllowFailure
            if ($workstreamSnapshots.Contains($workstreamItem.path)) {
                [IO.File]::WriteAllBytes($workstreamItem.path, $workstreamSnapshots[$workstreamItem.path])
            }
        }
        $null = Invoke-EwiGit -Repository $integrationRoot -ArgumentList @('reset', '--hard', $oldBaseline) -AllowFailure
        if ($newBaselineRef) { $null = Invoke-EwiGit -Repository $integrationRoot -ArgumentList @('update-ref', '-d', $newBaselineRef) -AllowFailure }
        [IO.File]::WriteAllBytes($statePath, $stateOriginal)
        [IO.File]::WriteAllBytes($indexPath, $indexOriginal)
        throw
    }
}

$evidenceId = New-EwiEvidenceId 'source-import'
$null = Write-EwiEvidence -WorkspaceRoot $root -EvidenceId $evidenceId -Kind 'source-import' `
    -Subject ([pscustomobject][ordered]@{ workspace = $root; source_id = $SourceId; target_id = $null; build_id = $null; workstream_id = $null; publish_id = $null; reference_id = $null }) `
    -Result ([pscustomobject][ordered]@{ status = 'passed'; summary = "Imported saved user changes for source '$SourceId'."; exit_code = 0; details = [pscustomobject][ordered]@{ files_changed = $result.files_changed; user_baseline_commit = $result.user_baseline_commit; workstreams_rebased = @($result.workstreams_rebased) } }) -Artifacts @()
$result | Add-Member -NotePropertyName evidence -NotePropertyValue "workspace-management/evidence/$evidenceId.json"
$result | ConvertTo-Json -Depth 12
