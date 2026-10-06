[CmdletBinding(DefaultParameterSetName = 'Plan')]
param(
    [Parameter(Mandatory)] [string] $WorkspaceRoot,
    [Parameter(Mandatory, ParameterSetName = 'Plan')]
    [Parameter(Mandatory, ParameterSetName = 'Apply')]
    [ValidatePattern('^\d{8}-[a-z0-9][a-z0-9-]{0,47}-[a-f0-9]{4}$')] [string] $WorkstreamId,
    [Parameter(Mandatory, ParameterSetName = 'Apply')] [string] $ExpectedManifestDigest,
    [Parameter(Mandatory, ParameterSetName = 'Rollback')]
    [Parameter(Mandatory, ParameterSetName = 'Finalize')]
    [ValidatePattern('^publish-[a-z0-9-]+$')] [string] $PublishId,
    [Parameter(ParameterSetName = 'Apply')] [switch] $Apply,
    [Parameter(ParameterSetName = 'Apply')] [switch] $RequireUserBuild,
    [Parameter(Mandatory, ParameterSetName = 'Rollback')] [switch] $Rollback,
    [Parameter(Mandatory, ParameterSetName = 'Finalize')] [switch] $Finalize,
    [Parameter(ParameterSetName = 'Finalize')] [switch] $AcceptUnverifiedBuild,
    [int] $MutexTimeoutSeconds = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/workspace-common.psm1') -Force

$context = Assert-EwiActiveWorkspace -WorkspaceRoot $WorkspaceRoot
$root = $context.root
$targetsSchema = Join-Path $root 'workspace-management/schemas/targets.schema.json'
$localSchema = Join-Path $root 'workspace-management/schemas/targets-local.schema.json'
$workstreamSchema = Join-Path $root 'workspace-management/schemas/workstream.schema.json'
$sourceStateSchema = Join-Path $root 'workspace-management/schemas/source-sync-state.schema.json'
$transactionSchema = Join-Path $root 'workspace-management/schemas/publish-transaction.schema.json'
$fileIndexSchema = Join-Path $root 'workspace-management/schemas/file-index-record.schema.json'

function Get-ObjectNames {
    param($Object)
    if ($Object -is [Collections.IDictionary]) { return @($Object.Keys) }
    return @($Object.PSObject.Properties | ForEach-Object Name)
}

function Get-ObjectValue {
    param($Object, [string] $Name)
    if ($Object -is [Collections.IDictionary]) { return $Object[$Name] }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-BytesSha256 {
    param([Parameter(Mandatory)] [byte[]] $Bytes)
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

function Get-WorktreeFileBytes {
    param(
        [Parameter(Mandatory)] [string] $Worktree,
        [Parameter(Mandatory)] [string] $Path
    )

    $file = Join-EwiContainedPath -Root $Worktree -RelativePath $Path
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return $null }
    return ,([IO.File]::ReadAllBytes($file))
}

function Read-IndexMap {
    param([Parameter(Mandatory)] [string] $Path)
    $map = [ordered]@{}
    foreach ($line in [IO.File]::ReadLines($Path)) {
        if ([string]::IsNullOrWhiteSpace($line)) { throw "Incomplete JSONL index: $Path" }
        if (-not (Test-Json -Json $line -SchemaFile $fileIndexSchema -ErrorAction SilentlyContinue)) { throw "JSONL record does not match schema '$fileIndexSchema': $Path" }
        $item = $line | ConvertFrom-Json -Depth 20 -ErrorAction Stop
        $key = "$($item.mapping_id)|$(([string]$item.path).ToLowerInvariant())"
        if ($map.Contains($key)) { throw "Duplicate index key: $key" }
        $map[$key] = $item
    }
    return $map
}

function Test-PathInScope {
    param($Scope, [string] $SourceId, [string] $Path)
    $candidate = (Assert-EwiRelativePath -Path $Path -AllowDot).ToLowerInvariant()
    foreach ($sourceScope in @($Scope | Where-Object source_id -eq $SourceId)) {
        foreach ($pathScope in @($sourceScope.paths | Where-Object access -eq 'write')) {
            $allowed = (Assert-EwiRelativePath -Path ([string]$pathScope.path) -AllowDot).ToLowerInvariant()
            if ($allowed -eq '.' -or $candidate -eq $allowed -or $candidate.StartsWith($allowed.TrimEnd('/') + '/')) { return $true }
        }
    }
    return $false
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

function Get-SourceGeneratedPatterns {
    param($Targets, [string] $CurrentSourceId)
    $patterns = [Collections.Generic.List[string]]::new()
    foreach ($targetProperty in $Targets.targets.PSObject.Properties) {
        $targetValue = $targetProperty.Value
        if ($targetValue.source -ne $CurrentSourceId) { continue }
        $targetPrefix = ([string]$targetValue.path).Replace('\', '/').TrimEnd('/')
        foreach ($buildProperty in $targetValue.builds.PSObject.Properties) {
            $metadata = $Targets.field_metadata.PSObject.Properties["/targets/$($targetProperty.Name)/builds/$($buildProperty.Name)/generated_write_paths"]
            if ($null -eq $metadata -or $metadata.Value.provenance -ne 'confirmed' -or $metadata.Value.freshness -ne 'current') { continue }
            foreach ($generated in @($buildProperty.Value.generated_write_paths)) {
                $relative = ([string]$generated).Replace('\', '/')
                $patterns.Add($(if ($targetPrefix -eq '.') { $relative } else { "$targetPrefix/$relative" }))
            }
        }
    }
    return @($patterns)
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

function Resolve-Mapping {
    param($Source, $LocalSource, [string] $IntegrationPath)

    $normalized = (Assert-EwiRelativePath -Path $IntegrationPath -AllowDot).Replace('\', '/')
    $matches = [Collections.Generic.List[object]]::new()
    foreach ($mapping in @($Source.mappings)) {
        $subpath = ([string]$mapping.integration_subpath).Replace('\', '/').TrimEnd('/')
        $relative = $null
        if ($subpath -eq '.') { $relative = $normalized }
        elseif ($normalized -eq $subpath) { $relative = '.' }
        elseif ($normalized.StartsWith($subpath + '/', [StringComparison]::OrdinalIgnoreCase)) { $relative = $normalized.Substring($subpath.Length + 1) }
        if ($null -ne $relative) {
            $localMapping = $LocalSource.mappings.PSObject.Properties[[string]$mapping.mapping_id]
            if ($null -eq $localMapping) { throw "Missing local mapping '$($mapping.mapping_id)'." }
            $matches.Add([pscustomobject][ordered]@{
                mapping_id = [string]$mapping.mapping_id
                integration_subpath = $subpath
                relative_path = $relative
                authority_root = Resolve-EwiPath ([string]$localMapping.Value.source_path)
            })
        }
    }
    if ($matches.Count -ne 1) { throw "Integration path does not resolve through exactly one mapping: $IntegrationPath" }
    return $matches[0]
}

function Get-DiffPaths {
    param([string] $Repository, [string] $BaseCommit, [string] $HeadCommit)
    $diff = Invoke-EwiGit -Repository $Repository -ArgumentList @('diff', '--name-status', '--no-renames', "$BaseCommit..$HeadCommit")
    $result = [Collections.Generic.List[object]]::new()
    foreach ($line in @($diff.StdOut -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $parts = $line -split "`t", 2
        if ($parts.Count -ne 2 -or $parts[0] -notin @('A', 'M', 'D', 'T')) { throw "Unsupported Git diff entry: $line" }
        $result.Add([pscustomobject][ordered]@{ status = $parts[0]; path = $parts[1].Replace('\', '/') })
    }
    return @($result)
}

function Get-PublishPlan {
    param([Parameter(Mandatory)] [string] $Id)

    $targets = Read-EwiJson -Path (Join-Path $root 'workspace-management/config/targets.json') -SchemaPath $targetsSchema
    $local = Read-EwiJson -Path (Join-Path $root 'workspace-management/config/targets.local.json') -SchemaPath $localSchema
    $workstreamPath = Join-Path $root "work/$Id/workstream.json"
    $workstream = Read-EwiJson -Path $workstreamPath -SchemaPath $workstreamSchema
    if ($workstream.status -notin @('active', 'paused', 'blocked')) { throw "Workstream is terminal: $($workstream.status)" }

    $blockers = [Collections.Generic.List[string]]::new()
    $conflicts = [Collections.Generic.List[object]]::new()
    $manifest = [Collections.Generic.List[object]]::new()
    $headCommits = [ordered]@{}
    $mappingRevisions = [ordered]@{}
    $content = [ordered]@{}
    $internal = [ordered]@{}

    $transactions = Get-ChildItem -LiteralPath (Join-Path $root 'workspace-management/sync-state/transactions') -Filter '*.json' -File -ErrorAction SilentlyContinue
    foreach ($transactionFile in $transactions) {
        $transaction = Read-EwiJson -Path $transactionFile.FullName -SchemaPath $transactionSchema
        if ($transaction.state -notin @('completed', 'conflicted', 'rolled_back')) {
            $blockers.Add("Nonterminal transaction blocks publish: $($transaction.publish_id) [$($transaction.state)]")
        }
    }

    $allowedScope = [Collections.Generic.List[object]]::new()
    foreach ($scopeEntry in @($workstream.scope)) { $allowedScope.Add($scopeEntry) }
    foreach ($dependency in @($workstream.dependencies)) {
        $dependencyPath = Join-Path $root "work/$($dependency.workstream_id)/workstream.json"
        if (-not (Test-Path -LiteralPath $dependencyPath)) {
            $blockers.Add("Pinned dependency manifest is missing: $($dependency.workstream_id)")
            continue
        }
        $dependencyManifest = Read-EwiJson -Path $dependencyPath -SchemaPath $workstreamSchema
        foreach ($scopeEntry in @($dependencyManifest.scope)) { $allowedScope.Add($scopeEntry) }
    }

    foreach ($sourceId in Get-ObjectNames $workstream.agent.refs) {
        $sourceRef = Get-ObjectValue $workstream.agent.refs $sourceId
        $source = Get-ObjectValue $targets.sources $sourceId
        $localSource = Get-ObjectValue $local.sources $sourceId
        if ($null -eq $source -or $null -eq $localSource -or $source.user_source -ne 'configured') {
            $blockers.Add("Source is not publishable: $sourceId")
            continue
        }
        if ([int]$sourceRef.mapping_revision -ne [int]$source.mapping_revision) {
            $blockers.Add("Workstream mapping revision is stale for source '$sourceId'.")
            continue
        }
        $mappingRevisions[$sourceId] = [int]$source.mapping_revision
        $worktree = Join-EwiContainedPath -Root $root -RelativePath ([string]$sourceRef.worktree)
        $outputPatterns = Get-SourceOutputPatterns -Targets $targets -CurrentSourceId $sourceId
        $status = @(Get-MeaningfulGitStatus -Repository $worktree -IgnoredOutputPatterns $outputPatterns)
        if ($status.Count -gt 0) {
            $blockers.Add("Workstream source '$sourceId' has uncommitted changes; checkpoint before publish.")
            continue
        }
        $head = (Invoke-EwiGit -Repository $worktree -ArgumentList @('rev-parse', 'HEAD')).StdOut.Trim()
        $headCommits[$sourceId] = $head
        $integration = Join-EwiContainedPath -Root $root -RelativePath ([string]$source.integration_path)
        $statePath = Join-Path $root "workspace-management/sync-state/sources/$sourceId.json"
        $state = Read-EwiJson -Path $statePath -SchemaPath $sourceStateSchema
        if (-not $state.scan_complete -or $state.mapping_revision -ne $source.mapping_revision -or
            $state.user_baseline_commit -ne $sourceRef.user_baseline_commit -or
            $state.mapping_digest -ne (Get-EwiMappingDigest -Mappings @($source.mappings) -LocalMappings $localSource.mappings)) {
            $blockers.Add("User baseline or mapping state is stale/incomplete for '$sourceId'.")
            continue
        }
        $reachable = Invoke-EwiGit -Repository $integration -ArgumentList @('cat-file', '-e', "$($state.user_baseline_commit)^{commit}") -AllowFailure
        $refValue = Invoke-EwiGit -Repository $integration -ArgumentList @('rev-parse', $state.user_baseline_ref) -AllowFailure
        if ($reachable.ExitCode -ne 0 -or $refValue.ExitCode -ne 0 -or $refValue.StdOut.Trim() -ne $state.user_baseline_commit) {
            $blockers.Add("User baseline is not retrievable through its stable ref for '$sourceId'.")
            continue
        }
        $integrationHead = (Invoke-EwiGit -Repository $integration -ArgumentList @('rev-parse', 'HEAD')).StdOut.Trim()
        $integrationDirty = @(Get-MeaningfulGitStatus -Repository $integration -IgnoredOutputPatterns $outputPatterns)
        if ($integrationHead -ne $state.user_baseline_commit -or $integrationDirty.Count -gt 0) {
            $blockers.Add("Integration repository for '$sourceId' is not a clean pure user baseline.")
            continue
        }

        foreach ($otherFile in Get-ChildItem -LiteralPath (Join-Path $root 'work') -Filter 'workstream.json' -File -Recurse -Depth 2 -ErrorAction SilentlyContinue) {
            $other = Read-EwiJson -Path $otherFile.FullName -SchemaPath $workstreamSchema
            if ($other.id -eq $Id) { continue }
            if ($other.status -in @('completed', 'abandoned') -and -not $other.has_unresolved_changes) { continue }
            if ($null -ne $other.agent.refs.PSObject.Properties[$sourceId]) {
                $pinnedDependency = @($workstream.dependencies | Where-Object workstream_id -eq $other.id)
                if ($pinnedDependency.Count -eq 1) {
                    $pinnedRef = $pinnedDependency[0].refs.PSObject.Properties[$sourceId]
                    $otherRef = $other.agent.refs.PSObject.Properties[$sourceId]
                    if ($null -ne $pinnedRef -and $null -ne $otherRef) {
                        $otherWorktree = Join-EwiContainedPath -Root $root -RelativePath ([string]$otherRef.Value.worktree)
                        $otherHead = (Invoke-EwiGit -Repository $otherWorktree -ArgumentList @('rev-parse', 'HEAD')).StdOut.Trim()
                        if ($otherHead -eq [string]$pinnedRef.Value.head_commit) { continue }
                    }
                }
                $blockers.Add("Another active or unresolved workstream uses '$sourceId': $($other.id). Coordinate/rebase it before publish.")
            }
        }

        $diffEntries = [Collections.Generic.List[object]]::new()
        foreach ($entry in Get-DiffPaths -Repository $worktree -BaseCommit ([string]$sourceRef.task_base_commit) -HeadCommit $head) {
            $diffEntries.Add($entry)
        }
        foreach ($dependency in @($workstream.dependencies)) {
            $pinned = $dependency.refs.PSObject.Properties[$sourceId]
            if ($null -eq $pinned) { continue }
            if ([int]$pinned.Value.mapping_revision -ne [int]$source.mapping_revision) {
                $blockers.Add("Pinned dependency mapping is stale for '$sourceId': $($dependency.workstream_id)")
                continue
            }
            $ancestor = Invoke-EwiGit -Repository $worktree -ArgumentList @('merge-base', '--is-ancestor', [string]$pinned.Value.head_commit, [string]$sourceRef.task_base_commit) -AllowFailure
            if ($ancestor.ExitCode -ne 0) {
                $blockers.Add("Pinned dependency commit is not contained in task_base_commit: $($dependency.workstream_id)/$sourceId")
                continue
            }
            foreach ($entry in Get-DiffPaths -Repository $worktree -BaseCommit ([string]$pinned.Value.task_base_commit) -HeadCommit ([string]$pinned.Value.head_commit)) {
                $diffEntries.Add($entry)
            }
        }

        $indexPath = Resolve-EwiPath (Join-Path (Split-Path -Parent $statePath) ([string]$state.file_index))
        $baselineIndex = Read-IndexMap $indexPath
        foreach ($key in @($baselineIndex.Keys)) {
            $parts = $key.Split('|', 2)
            $mapping = @($source.mappings | Where-Object mapping_id -eq $parts[0])
            if ($mapping.Count -ne 1) { throw "Baseline index mapping is no longer unique: $key" }
            $integrationPath = if ($mapping[0].integration_subpath -eq '.') { [string]$baselineIndex[$key].path } else { "$($mapping[0].integration_subpath)/$($baselineIndex[$key].path)" }
            if (Test-OutputPath -IntegrationPath $integrationPath -Patterns $outputPatterns) { $baselineIndex.Remove($key) }
        }
        $currentUserIndex = [ordered]@{}
        $sourceInventories = [Collections.Generic.List[object]]::new()
        foreach ($mapping in @($source.mappings)) {
            $localMapping = $localSource.mappings.PSObject.Properties[[string]$mapping.mapping_id]
            if ($null -eq $localMapping) { throw "Missing local mapping '$($mapping.mapping_id)'." }
            $authority = Resolve-EwiPath ([string]$localMapping.Value.source_path)
            Assert-EwiPathsSeparated -First $root -Second $authority -FirstLabel 'workspace' -SecondLabel "authority '$($mapping.mapping_id)'"
            $fullInventory = Get-EwiFileInventory -Root $authority -MappingId ([string]$mapping.mapping_id)
            if (-not $fullInventory.scan_complete) { $blockers.Add("User scan is incomplete for '$($mapping.mapping_id)'.") }
            if (@($fullInventory.git_topology).Count -gt 0) { $blockers.Add("Linked-worktree or nested Git topology exists in '$($mapping.mapping_id)'.") }
            if (@($fullInventory.sensitive).Count -gt 0) { $blockers.Add("Unresolved sensitive files exist in '$($mapping.mapping_id)'.") }
            if (@($fullInventory.pending).Count -gt 0) { $blockers.Add("Ambiguous license or activation files exist in '$($mapping.mapping_id)'.") }
            $inventory = Select-ManagedInventory -Inventory $fullInventory -IntegrationSubpath ([string]$mapping.integration_subpath) -Patterns $outputPatterns
            foreach ($item in @($inventory.files)) {
                $currentUserIndex["$($item.mapping_id)|$(([string]$item.path).ToLowerInvariant())"] = $item
            }
            $sourceInventories.Add([pscustomobject][ordered]@{
                mapping_id = [string]$mapping.mapping_id
                authority = $authority
                inventory = $inventory
            })
        }

        $diffByPath = [ordered]@{}
        foreach ($entry in @($diffEntries)) { $diffByPath[([string]$entry.path).ToLowerInvariant()] = $entry }
        foreach ($entry in $diffByPath.Values) {
            $path = Assert-EwiRelativePath -Path ([string]$entry.path)
            if (-not (Test-PathInScope -Scope @($allowedScope) -SourceId $sourceId -Path $path)) {
                $blockers.Add("Publish path is outside declared write scope: $sourceId/$path")
                continue
            }
            $mapping = Resolve-Mapping -Source $source -LocalSource $localSource -IntegrationPath $path
            $authorityFile = Join-EwiContainedPath -Root $mapping.authority_root -RelativePath $mapping.relative_path -AllowDot
            # Git can store normalized blobs while clean worktrees contain filtered bytes.
            # Compare and publish the actual checked-out bytes at all three locations.
            $baselineBytes = Get-WorktreeFileBytes -Worktree $integration -Path $path
            $agentBytes = Get-WorktreeFileBytes -Worktree $worktree -Path $path
            $baselineHash = if ($null -eq $baselineBytes) { $null } else { Get-BytesSha256 $baselineBytes }
            $agentHash = if ($null -eq $agentBytes) { $null } else { Get-BytesSha256 $agentBytes }
            $userHash = if (Test-Path -LiteralPath $authorityFile -PathType Leaf) { Get-EwiSha256 $authorityFile } else { $null }
            if ($agentHash -eq $baselineHash) { continue }
            $operation = if ($null -eq $agentHash) { 'delete' } elseif ($null -eq $baselineHash) { 'add' } else { 'modify' }
            $manifestItem = [pscustomobject][ordered]@{
                source_id = $sourceId
                mapping_id = $mapping.mapping_id
                relative_path = $mapping.relative_path
                operation = $operation
                baseline_hash = $baselineHash
                user_hash = $userHash
                agent_hash = $agentHash
                expected_hash = $agentHash
                precondition_hash = $userHash
            }
            if ($userHash -ne $baselineHash -and $userHash -ne $agentHash) {
                $conflicts.Add($manifestItem)
            }
            $manifest.Add($manifestItem)
            $content["$sourceId|$path"] = $agentBytes
            $internal["$sourceId|$($mapping.mapping_id)|$($mapping.relative_path.ToLowerInvariant())"] = [pscustomobject][ordered]@{
                integration_path = $path
                authority_file = $authorityFile
                authority_root = $mapping.authority_root
                integration_root = $integration
                worktree = $worktree
                state_path = $statePath
                index_path = $indexPath
            }
        }

        $manifestKeys = @{}
        foreach ($item in @($manifest | Where-Object source_id -eq $sourceId)) {
            $manifestKeys["$($item.mapping_id)|$(([string]$item.relative_path).ToLowerInvariant())"] = $item
        }
        foreach ($key in @($baselineIndex.Keys + $currentUserIndex.Keys | Sort-Object -Unique)) {
            $baselineHash = if ($baselineIndex.Contains($key)) { $baselineIndex[$key].sha256 } else { $null }
            $userHash = if ($currentUserIndex.Contains($key)) { $currentUserIndex[$key].sha256 } else { $null }
            if ($baselineHash -ne $userHash -and -not $manifestKeys.ContainsKey($key)) {
                $blockers.Add("User source changed outside the publish manifest; import it first: $sourceId/$key")
            }
        }
        $internal["source|$sourceId"] = [pscustomobject][ordered]@{
            source = $source
            local_source = $localSource
            state = $state
            state_path = $statePath
            index_path = $indexPath
            integration = $integration
            inventories = @($sourceInventories)
        }
    }

    $orderedManifest = @($manifest | Sort-Object source_id, mapping_id, relative_path)
    $manifestDigest = Get-EwiTextSha256 (ConvertTo-EwiCanonicalJson $orderedManifest)
    return [pscustomobject][ordered]@{
        workstream = $workstream
        workstream_path = $workstreamPath
        manifest = $orderedManifest
        manifest_digest = $manifestDigest
        head_commits = $headCommits
        mapping_revisions = $mappingRevisions
        conflicts = @($conflicts)
        blockers = @($blockers | Sort-Object -Unique)
        content = $content
        internal = $internal
    }
}

function Resolve-TransactionAuthorityFile {
    param($Targets, $Local, $Item)
    $source = Get-ObjectValue $Targets.sources ([string]$Item.source_id)
    $localSource = Get-ObjectValue $Local.sources ([string]$Item.source_id)
    $mapping = @($source.mappings | Where-Object mapping_id -eq $Item.mapping_id)
    if ($mapping.Count -ne 1) { throw "Transaction mapping is no longer unique: $($Item.mapping_id)" }
    $localMapping = $localSource.mappings.PSObject.Properties[[string]$Item.mapping_id]
    if ($null -eq $localMapping) { throw "Transaction local mapping is missing: $($Item.mapping_id)" }
    return Join-EwiContainedPath -Root ([string]$localMapping.Value.source_path) -RelativePath ([string]$Item.relative_path) -AllowDot
}

function Resolve-TransactionTargetRoot {
    param($Targets, $Local, [string] $TargetId)
    $target = Get-ObjectValue $Targets.targets $TargetId
    if ($null -eq $target) { throw "Build target is no longer configured: $TargetId" }
    $source = Get-ObjectValue $Targets.sources ([string]$target.source)
    $localSource = Get-ObjectValue $Local.sources ([string]$target.source)
    if ($null -eq $source -or $null -eq $localSource) { throw "Build target source is no longer locally bound: $TargetId" }
    $targetPath = (Assert-EwiRelativePath -Path ([string]$target.path) -AllowDot).Replace('\', '/')
    $matches = [Collections.Generic.List[string]]::new()
    foreach ($mapping in @($source.mappings)) {
        $subpath = ([string]$mapping.integration_subpath).Replace('\', '/').TrimEnd('/')
        $relative = $null
        if ($subpath -eq '.') { $relative = $targetPath }
        elseif ($targetPath -eq $subpath) { $relative = '.' }
        elseif ($targetPath.StartsWith($subpath + '/', [StringComparison]::OrdinalIgnoreCase)) { $relative = $targetPath.Substring($subpath.Length + 1) }
        if ($null -ne $relative) {
            $localMapping = $localSource.mappings.PSObject.Properties[[string]$mapping.mapping_id]
            if ($null -eq $localMapping) { throw "Build target local mapping is missing: $($mapping.mapping_id)" }
            $matches.Add((Join-EwiContainedPath -Root ([string]$localMapping.Value.source_path) -RelativePath $relative -AllowDot))
        }
    }
    if ($matches.Count -ne 1) { throw "Build target does not map to exactly one authority root: $TargetId" }
    return $matches[0]
}

function Restore-TransactionBuildSideEffects {
    param($Transaction, $Targets, $Local, [string] $RecoveryRoot)
    if (-not $Transaction.build_target_id) { return $true }
    $target = Get-ObjectValue $Targets.targets ([string]$Transaction.build_target_id)
    $build = if ($null -eq $target -or -not $Transaction.build_id) { $null } else { Get-ObjectValue $target.builds ([string]$Transaction.build_id) }
    if ($null -eq $build) { return $false }
    $targetRoot = Resolve-TransactionTargetRoot -Targets $Targets -Local $Local -TargetId ([string]$Transaction.build_target_id)
    $snapshotRoot = Join-EwiContainedPath -Root $RecoveryRoot -RelativePath "pre-build/$($Transaction.build_target_id)"
    $manifestPath = Join-Path $snapshotRoot 'manifest.jsonl'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { return $false }

    $before = [ordered]@{}
    foreach ($line in [IO.File]::ReadLines($manifestPath)) {
        if ([string]::IsNullOrWhiteSpace($line)) { return $false }
        $entry = $line | ConvertFrom-Json -Depth 20 -DateKind String -ErrorAction Stop
        $before[([string]$entry.path).ToLowerInvariant()] = $entry
    }
    $currentInventory = Get-EwiFileInventory -Root $targetRoot -MappingId ([string]$Transaction.build_target_id) -IncludeBuildDirectories
    if (-not $currentInventory.scan_complete) { return $false }
    $current = [ordered]@{}
    $allTargetOutputPaths = @($target.builds.PSObject.Properties | ForEach-Object {
        $metadata = $Targets.field_metadata.PSObject.Properties["/targets/$($Transaction.build_target_id)/builds/$($_.Name)/output_paths"]
        if ($null -ne $metadata -and $metadata.Value.provenance -eq 'confirmed' -and $metadata.Value.freshness -eq 'current') { @($_.Value.output_paths) }
    })
    foreach ($entry in @($currentInventory.files)) {
        if (-not (Test-OutputPath -IntegrationPath ([string]$entry.path) -Patterns $allTargetOutputPaths)) {
            $current[([string]$entry.path).ToLowerInvariant()] = $entry
        }
    }
    $afterHashes = [ordered]@{}
    foreach ($effect in @($Transaction.side_effects | Where-Object classification -ne 'output')) {
        $afterHashes[([string]$effect.path).ToLowerInvariant()] = $effect.after_hash
    }

    foreach ($key in @($before.Keys + $current.Keys | Sort-Object -Unique)) {
        $beforeHash = if ($before.Contains($key)) { $before[$key].sha256 } else { $null }
        $currentHash = if ($current.Contains($key)) { $current[$key].sha256 } else { $null }
        if ($beforeHash -eq $currentHash) { continue }
        if (-not $afterHashes.Contains($key) -or $afterHashes[$key] -ne $currentHash) { return $false }
    }

    foreach ($key in @($before.Keys + $current.Keys | Sort-Object -Unique)) {
        $beforeHash = if ($before.Contains($key)) { $before[$key].sha256 } else { $null }
        $currentHash = if ($current.Contains($key)) { $current[$key].sha256 } else { $null }
        if ($beforeHash -eq $currentHash) { continue }
        $relative = if ($before.Contains($key)) { [string]$before[$key].path } else { [string]$current[$key].path }
        $targetFile = Join-EwiContainedPath -Root $targetRoot -RelativePath $relative
        if ($null -eq $beforeHash) {
            if (Test-Path -LiteralPath $targetFile -PathType Leaf) { [IO.File]::Delete($targetFile) }
        }
        else {
            $snapshot = Join-EwiContainedPath -Root (Join-Path $snapshotRoot 'files') -RelativePath $relative
            if (-not (Test-Path -LiteralPath $snapshot -PathType Leaf) -or (Get-EwiSha256 $snapshot) -ne $beforeHash) { return $false }
            $parent = Split-Path -Parent $targetFile
            if (-not (Test-Path -LiteralPath $parent)) { $null = New-Item -ItemType Directory -Path $parent }
            $temporary = Join-Path $parent ('.build-restore-' + [Guid]::NewGuid().ToString('N') + '.tmp')
            try {
                [IO.File]::Copy($snapshot, $temporary, $true)
                [IO.File]::Move($temporary, $targetFile, $true)
            }
            finally {
                if (Test-Path -LiteralPath $temporary) { [IO.File]::Delete($temporary) }
            }
        }
    }
    return $true
}

function Restore-TransactionFiles {
    param($Transaction, [switch] $UpdateState)
    $targets = Read-EwiJson -Path (Join-Path $root 'workspace-management/config/targets.json') -SchemaPath $targetsSchema
    $local = Read-EwiJson -Path (Join-Path $root 'workspace-management/config/targets.local.json') -SchemaPath $localSchema
    $recoveryRoot = Join-EwiContainedPath -Root $root -RelativePath ([string]$Transaction.recovery_path)
    if (-not (Restore-TransactionBuildSideEffects -Transaction $Transaction -Targets $targets -Local $local -RecoveryRoot $recoveryRoot)) {
        if ($UpdateState) {
            $Transaction.state = 'recovery_required'
            $Transaction.updated_at = Get-EwiTimestamp
            $Transaction.message = 'Build side effects could not be restored without risking external changes.'
        }
        return $false
    }
    foreach ($item in @($Transaction.manifest)) {
        $target = Resolve-TransactionAuthorityFile -Targets $targets -Local $local -Item $item
        $currentHash = if (Test-Path -LiteralPath $target -PathType Leaf) { Get-EwiSha256 $target } else { $null }
        if ($currentHash -ne $item.expected_hash -and $currentHash -ne $item.user_hash) {
            if ($UpdateState) {
                $Transaction.state = 'recovery_required'
                $Transaction.updated_at = Get-EwiTimestamp
                $Transaction.message = "Rollback precondition changed: $($item.source_id)/$($item.mapping_id)/$($item.relative_path)"
            }
            return $false
        }
    }
    foreach ($item in @($Transaction.manifest | Sort-Object { $_.relative_path.Length } -Descending)) {
        $target = Resolve-TransactionAuthorityFile -Targets $targets -Local $local -Item $item
        $currentHash = if (Test-Path -LiteralPath $target -PathType Leaf) { Get-EwiSha256 $target } else { $null }
        if ($currentHash -eq $item.user_hash) { continue }
        if ($null -eq $item.user_hash) {
            if (Test-Path -LiteralPath $target -PathType Leaf) { [IO.File]::Delete($target) }
        }
        else {
            $snapshot = Join-EwiContainedPath -Root $recoveryRoot -RelativePath "original/$($item.source_id)/$($item.mapping_id)/$($item.relative_path)"
            if (-not (Test-Path -LiteralPath $snapshot -PathType Leaf)) {
                $snapshot = Join-EwiContainedPath -Root $recoveryRoot -RelativePath "deleted/$($item.source_id)/$($item.mapping_id)/$($item.relative_path)"
            }
            if (-not (Test-Path -LiteralPath $snapshot -PathType Leaf) -or (Get-EwiSha256 $snapshot) -ne $item.user_hash) {
                if ($UpdateState) {
                    $Transaction.state = 'recovery_required'
                    $Transaction.updated_at = Get-EwiTimestamp
                    $Transaction.message = "Recovery snapshot missing or invalid: $($item.relative_path)"
                }
                return $false
            }
            $parent = Split-Path -Parent $target
            if (-not (Test-Path -LiteralPath $parent)) { $null = New-Item -ItemType Directory -Path $parent }
            $temporary = Join-Path $parent ('.restore-' + [Guid]::NewGuid().ToString('N') + '.tmp')
            [IO.File]::Copy($snapshot, $temporary, $true)
            [IO.File]::Move($temporary, $target, $true)
        }
    }
    foreach ($item in @($Transaction.manifest)) {
        $target = Resolve-TransactionAuthorityFile -Targets $targets -Local $local -Item $item
        $restoredHash = if (Test-Path -LiteralPath $target -PathType Leaf) { Get-EwiSha256 $target } else { $null }
        if ($restoredHash -ne $item.user_hash) { return $false }
    }
    if ($UpdateState) {
        $Transaction.state = 'rolled_back'
        $Transaction.file_publish_status = 'failed'
        $Transaction.updated_at = Get-EwiTimestamp
        $Transaction.message = 'All user files were restored and verified.'
    }
    return $true
}

function Write-PublishOperationEvidence {
    param(
        [Parameter(Mandatory)] $Transaction,
        [Parameter(Mandatory)] [string] $TransactionPath,
        [Parameter(Mandatory)] [ValidateSet('publish', 'recovery')] [string] $Kind,
        [Parameter(Mandatory)] [ValidateSet('passed', 'failed', 'blocked')] [string] $Status,
        [Parameter(Mandatory)] [string] $Summary
    )

    $relativeTransaction = [IO.Path]::GetRelativePath($root, $TransactionPath).Replace('\', '/')
    $artifact = [pscustomobject][ordered]@{
        path = $relativeTransaction
        media_type = 'application/json'
        size = (Get-Item -LiteralPath $TransactionPath).Length
        sha256 = Get-EwiSha256 $TransactionPath
    }
    $null = Write-EwiEvidence -WorkspaceRoot $root -EvidenceId ([string]$Transaction.publish_id) -Kind $Kind `
        -Subject ([pscustomobject][ordered]@{ workspace = $root; source_id = $null; target_id = $Transaction.build_target_id; build_id = $Transaction.build_id; workstream_id = $Transaction.workstream_id; publish_id = $Transaction.publish_id; reference_id = $null }) `
        -Result ([pscustomobject][ordered]@{ status = $Status; summary = $Summary; exit_code = $null; details = [pscustomobject][ordered]@{ transaction_state = $Transaction.state; file_publish_status = $Transaction.file_publish_status; build_status = $Transaction.build_status; side_effect_status = $Transaction.side_effect_status } }) `
        -Artifacts @($artifact)
    return "workspace-management/evidence/$($Transaction.publish_id).json"
}

function Complete-PublishTransaction {
    param(
        [Parameter(Mandatory)] $Transaction,
        [Parameter(Mandatory)] [string] $TransactionPath,
        [switch] $AcceptUnverified
    )

    if ($Transaction.side_effect_status -eq 'review_required' -or @($Transaction.side_effects | Where-Object classification -eq 'review-required').Count -gt 0) {
        throw 'Unclassified build side effects must be resolved before finalization.'
    }
    if ($Transaction.state -eq 'verification_failed') {
        if (-not $AcceptUnverified) { throw 'Build verification failed; use explicit -AcceptUnverifiedBuild or roll back.' }
    }
    elseif ($Transaction.state -ne 'file_verified') {
        throw "Transaction state cannot be finalized: $($Transaction.state)"
    }
    if ($Transaction.build_status -eq 'not-run') {
        throw 'The required user-authority build has not run.'
    }
    if ($Transaction.build_status -eq 'failed' -and -not $AcceptUnverified) {
        throw 'A failed build cannot advance the user baseline without explicit unverified acceptance.'
    }

    $targets = Read-EwiJson -Path (Join-Path $root 'workspace-management/config/targets.json') -SchemaPath $targetsSchema
    $local = Read-EwiJson -Path (Join-Path $root 'workspace-management/config/targets.local.json') -SchemaPath $localSchema
    $workstreamPath = Join-Path $root "work/$($Transaction.workstream_id)/workstream.json"
    $workstream = Read-EwiJson -Path $workstreamPath -SchemaPath $workstreamSchema
    $workstreamOriginal = [IO.File]::ReadAllBytes($workstreamPath)
    $transactionOriginal = [IO.File]::ReadAllBytes($TransactionPath)
    $updates = [Collections.Generic.List[object]]::new()

    try {
        foreach ($sourceId in Get-ObjectNames $Transaction.head_commits) {
            $source = Get-ObjectValue $targets.sources $sourceId
            $localSource = Get-ObjectValue $local.sources $sourceId
            $sourceRefProperty = $workstream.agent.refs.PSObject.Properties[$sourceId]
            if ($null -eq $source -or $null -eq $localSource -or $null -eq $sourceRefProperty) {
                throw "Finalization source is no longer configured: $sourceId"
            }
            $sourceRef = $sourceRefProperty.Value
            if ([int]$source.mapping_revision -ne [int]$Transaction.mapping_revisions.PSObject.Properties[$sourceId].Value -or
                [int]$sourceRef.mapping_revision -ne [int]$source.mapping_revision) {
                throw "Mapping revision changed before finalization: $sourceId"
            }
            $integration = Join-EwiContainedPath -Root $root -RelativePath ([string]$source.integration_path)
            $worktree = Join-EwiContainedPath -Root $root -RelativePath ([string]$sourceRef.worktree)
            $frozenHead = [string]$Transaction.head_commits.PSObject.Properties[$sourceId].Value
            if ([string]$sourceRef.head_commit -ne $frozenHead) { throw "Workstream frozen head is not recorded for finalization: $sourceId" }
            if ((Invoke-EwiGit -Repository $worktree -ArgumentList @('rev-parse', 'HEAD')).StdOut.Trim() -ne $frozenHead) {
                throw "Workstream head changed before finalization: $sourceId"
            }
            $outputPatterns = Get-SourceOutputPatterns -Targets $targets -CurrentSourceId $sourceId
            if (@(Get-MeaningfulGitStatus -Repository $worktree -IgnoredOutputPatterns $outputPatterns).Count -gt 0) {
                throw "Workstream has changes outside confirmed outputs: $sourceId"
            }

            $statePath = Join-Path $root "workspace-management/sync-state/sources/$sourceId.json"
            $state = Read-EwiJson -Path $statePath -SchemaPath $sourceStateSchema
            $stateOriginal = [IO.File]::ReadAllBytes($statePath)
            if ($state.user_baseline_commit -ne $sourceRef.user_baseline_commit -or
                (Invoke-EwiGit -Repository $integration -ArgumentList @('rev-parse', 'HEAD')).StdOut.Trim() -ne $state.user_baseline_commit -or
                @(Get-MeaningfulGitStatus -Repository $integration -IgnoredOutputPatterns $outputPatterns).Count -gt 0) {
                throw "Source-private baseline changed before finalization: $sourceId"
            }
            $oldBaseline = [string]$state.user_baseline_commit
            $indexPath = Resolve-EwiPath (Join-Path (Split-Path -Parent $statePath) ([string]$state.file_index))
            $oldIndex = Read-IndexMap $indexPath
            $indexOriginal = [IO.File]::ReadAllBytes($indexPath)
            $currentIndex = [ordered]@{}
            $currentEntries = [Collections.Generic.List[object]]::new()
            $mappingDetails = [ordered]@{}
            foreach ($mapping in @($source.mappings)) {
                $mappingId = [string]$mapping.mapping_id
                $localMapping = $localSource.mappings.PSObject.Properties[$mappingId]
                if ($null -eq $localMapping) { throw "Local mapping is missing: $mappingId" }
                $authority = Resolve-EwiPath ([string]$localMapping.Value.source_path)
                $fullInventory = Get-EwiFileInventory -Root $authority -MappingId $mappingId
                if (-not $fullInventory.scan_complete -or @($fullInventory.git_topology).Count -gt 0 -or @($fullInventory.sensitive).Count -gt 0 -or @($fullInventory.pending).Count -gt 0) {
                    throw "Authority scan is incomplete or contains unresolved sensitive files: $mappingId"
                }
                $inventory = Select-ManagedInventory -Inventory $fullInventory -IntegrationSubpath ([string]$mapping.integration_subpath) -Patterns $outputPatterns
                foreach ($entry in @($inventory.files)) {
                    $key = "$mappingId|$(([string]$entry.path).ToLowerInvariant())"
                    $currentIndex[$key] = $entry
                    $currentEntries.Add($entry)
                }
                $mappingDetails[$mappingId] = [pscustomobject][ordered]@{
                    authority = $authority
                    integration_subpath = [string]$mapping.integration_subpath
                }
            }

            $generatedPatterns = Get-SourceGeneratedPatterns -Targets $targets -CurrentSourceId $sourceId
            $manifestIntegrationPaths = @{}
            foreach ($item in @($Transaction.manifest | Where-Object source_id -eq $sourceId)) {
                $key = "$($item.mapping_id)|$(([string]$item.relative_path).ToLowerInvariant())"
                $currentHash = if ($currentIndex.Contains($key)) { $currentIndex[$key].sha256 } else { $null }
                $subpath = $mappingDetails[[string]$item.mapping_id].integration_subpath
                $integrationPath = if ($subpath -eq '.') { [string]$item.relative_path } else { "$subpath/$($item.relative_path)" }
                $manifestIntegrationPaths[$integrationPath.ToLowerInvariant()] = $true
                if ($currentHash -ne $item.expected_hash -and -not (Test-OutputPath -IntegrationPath $integrationPath -Patterns $generatedPatterns)) {
                    throw "Published file changed outside a confirmed generated-write path: $sourceId/$integrationPath"
                }
            }

            $gitPaths = [Collections.Generic.List[string]]::new()
            foreach ($key in @($oldIndex.Keys + $currentIndex.Keys | Sort-Object -Unique)) {
                $oldHash = if ($oldIndex.Contains($key)) { $oldIndex[$key].sha256 } else { $null }
                $newHash = if ($currentIndex.Contains($key)) { $currentIndex[$key].sha256 } else { $null }
                if ($oldHash -eq $newHash) { continue }
                $parts = $key.Split('|', 2)
                $mappingId = $parts[0]
                $relative = if ($currentIndex.Contains($key)) { [string]$currentIndex[$key].path } else { [string]$oldIndex[$key].path }
                $details = $mappingDetails[$mappingId]
                $integrationPath = if ($details.integration_subpath -eq '.') { $relative } else { "$($details.integration_subpath)/$relative" }
                if (-not $manifestIntegrationPaths.ContainsKey($integrationPath.ToLowerInvariant()) -and
                    -not (Test-OutputPath -IntegrationPath $integrationPath -Patterns $generatedPatterns)) {
                    throw "Authority changed outside the frozen manifest and confirmed generated-write paths: $sourceId/$integrationPath"
                }
                $integrationFile = Join-EwiContainedPath -Root $integration -RelativePath $integrationPath
                if ($null -eq $newHash) {
                    if (Test-Path -LiteralPath $integrationFile -PathType Leaf) { [IO.File]::Delete($integrationFile) }
                }
                else {
                    $authorityFile = Join-EwiContainedPath -Root $details.authority -RelativePath $relative
                    $parent = Split-Path -Parent $integrationFile
                    if (-not (Test-Path -LiteralPath $parent)) { $null = New-Item -ItemType Directory -Path $parent }
                    $temporary = Join-Path $parent ('.finalize-' + [Guid]::NewGuid().ToString('N') + '.tmp')
                    try {
                        [IO.File]::Copy($authorityFile, $temporary, $true)
                        if ((Get-EwiSha256 $temporary) -ne $newHash) { throw "Authority changed during finalization: $sourceId/$integrationPath" }
                        [IO.File]::Move($temporary, $integrationFile, $true)
                    }
                    finally {
                        if (Test-Path -LiteralPath $temporary) { [IO.File]::Delete($temporary) }
                    }
                }
                $gitPaths.Add($integrationPath)
            }
            $newBaseline = New-EwiGitCommit -Repository $integration -Message "chore: finalize publish $($Transaction.publish_id)" -RelativePaths @($gitPaths)
            if (-not $newBaseline) { throw "Finalization produced no new user baseline: $sourceId" }
            $baselineId = 'baseline-' + [DateTimeOffset]::Now.ToString('yyyyMMddHHmmssfff') + '-' + $sourceId
            $baselineRef = "refs/agent/user-baselines/$baselineId"
            $publishRef = "refs/agent/publishes/$($Transaction.publish_id)/$sourceId"
            $null = Invoke-EwiGit -Repository $integration -ArgumentList @('update-ref', $baselineRef, $newBaseline)
            $null = Invoke-EwiGit -Repository $integration -ArgumentList @('update-ref', $publishRef, $frozenHead)
            $updates.Add([pscustomobject][ordered]@{
                source_id = $sourceId
                integration = $integration
                worktree = $worktree
                frozen_head = $frozenHead
                old_baseline = $oldBaseline
                new_baseline = $newBaseline
                baseline_id = $baselineId
                baseline_ref = $baselineRef
                publish_ref = $publishRef
                state = $state
                state_path = $statePath
                state_original = $stateOriginal
                index_path = $indexPath
                index_original = $indexOriginal
                current_entries = @($currentEntries)
            })
        }

        foreach ($update in $updates) {
            $null = Invoke-EwiGit -Repository $update.worktree -ArgumentList @('reset', '--hard', $update.new_baseline)
            $sourceRef = $workstream.agent.refs.PSObject.Properties[$update.source_id].Value
            $sourceRef.user_baseline_commit = $update.new_baseline
            $sourceRef.task_base_commit = $update.new_baseline
            $sourceRef.head_commit = $null
            Write-EwiJsonLinesAtomic -Path $update.index_path -Records @($update.current_entries) -SchemaPath (Join-Path $root 'workspace-management/schemas/file-index-record.schema.json')
            $sourceState = $update.state
            $sourceState.user_baseline_id = $update.baseline_id
            $sourceState.user_baseline_commit = $update.new_baseline
            $sourceState.user_baseline_ref = $update.baseline_ref
            $sourceState.captured_at = Get-EwiTimestamp
            $sourceState.scan_complete = $true
            if ($Transaction.build_status -eq 'passed' -and $Transaction.build_target_id -and $Transaction.build_id) {
                $builtTarget = Get-ObjectValue $targets.targets ([string]$Transaction.build_target_id)
                if ($null -ne $builtTarget -and $builtTarget.source -eq $update.source_id) {
                    $key = "$($Transaction.build_target_id)/$($Transaction.build_id)"
                    $baseline = [pscustomobject][ordered]@{
                        last_successful_build_commit = $update.new_baseline
                        evidence_ref = $Transaction.build_evidence_ref
                    }
                    $existing = $sourceState.build_baselines.PSObject.Properties[$key]
                    if ($null -eq $existing) { $sourceState.build_baselines | Add-Member -NotePropertyName $key -NotePropertyValue $baseline }
                    else { $existing.Value = $baseline }
                }
            }
            Write-EwiJsonAtomic -Path $update.state_path -Value $sourceState -SchemaPath $sourceStateSchema
        }
        $workstream.has_unresolved_changes = $false
        $workstream.updated_at = Get-EwiTimestamp
        Write-EwiJsonAtomic -Path $workstreamPath -Value $workstream -SchemaPath $workstreamSchema
        $Transaction.state = 'completed'
        $Transaction.updated_at = Get-EwiTimestamp
        $Transaction.message = if ($Transaction.build_status -eq 'failed') {
            'User explicitly accepted the file state without successful build verification; the build baseline was not advanced.'
        }
        else {
            'User file state and baselines were finalized after build verification.'
        }
        Write-EwiJsonAtomic -Path $TransactionPath -Value $Transaction -SchemaPath $transactionSchema
        $null = New-EwiGitCommit -Repository $root -Message "chore: finalize publish $($Transaction.publish_id)" -RelativePaths @("work/$($Transaction.workstream_id)/workstream.json")
        return [pscustomobject][ordered]@{
            status = 'completed'
            publish_id = $Transaction.publish_id
            build_status = $Transaction.build_status
            user_baselines = @($updates | ForEach-Object { [pscustomobject]@{ source_id = $_.source_id; commit = $_.new_baseline; ref = $_.baseline_ref } })
            accepted_unverified = [bool]($Transaction.build_status -eq 'failed')
        }
    }
    catch {
        foreach ($update in @($updates)) {
            $null = Invoke-EwiGit -Repository $update.worktree -ArgumentList @('reset', '--hard', $update.frozen_head) -AllowFailure
            $null = Invoke-EwiGit -Repository $update.integration -ArgumentList @('reset', '--hard', $update.old_baseline) -AllowFailure
            $null = Invoke-EwiGit -Repository $update.integration -ArgumentList @('update-ref', '-d', $update.baseline_ref) -AllowFailure
            $null = Invoke-EwiGit -Repository $update.integration -ArgumentList @('update-ref', '-d', $update.publish_ref) -AllowFailure
            [IO.File]::WriteAllBytes($update.state_path, $update.state_original)
            [IO.File]::WriteAllBytes($update.index_path, $update.index_original)
        }
        [IO.File]::WriteAllBytes($workstreamPath, $workstreamOriginal)
        [IO.File]::WriteAllBytes($TransactionPath, $transactionOriginal)
        throw
    }
}

if ($Finalize) {
    $transactionPath = Join-Path $root "workspace-management/sync-state/transactions/$PublishId.json"
    $result = Invoke-EwiLocked -WorkspaceRoot $root -TimeoutSeconds $MutexTimeoutSeconds -ScriptBlock {
        $current = Read-EwiJson -Path $transactionPath -SchemaPath $transactionSchema
        return Complete-PublishTransaction -Transaction $current -TransactionPath $transactionPath -AcceptUnverified:$AcceptUnverifiedBuild
    }
    $finalTransaction = Read-EwiJson -Path $transactionPath -SchemaPath $transactionSchema
    $evidence = Write-PublishOperationEvidence -Transaction $finalTransaction -TransactionPath $transactionPath -Kind publish -Status passed -Summary 'The publish transaction was finalized and its user baseline updates were recorded.'
    $result | Add-Member -NotePropertyName evidence -NotePropertyValue $evidence
    $result | ConvertTo-Json -Depth 10
    return
}

if ($Rollback) {
    $transactionPath = Join-Path $root "workspace-management/sync-state/transactions/$PublishId.json"
    $transaction = Read-EwiJson -Path $transactionPath -SchemaPath $transactionSchema
    if ($transaction.state -notin @('verification_failed', 'side_effect_review_required', 'apply_failed', 'recovery_required')) {
        throw "Transaction state does not permit rollback: $($transaction.state)"
    }
    $rolledBack = Invoke-EwiLocked -WorkspaceRoot $root -TimeoutSeconds $MutexTimeoutSeconds -ScriptBlock {
        $current = Read-EwiJson -Path $transactionPath -SchemaPath $transactionSchema
        $success = Restore-TransactionFiles -Transaction $current -UpdateState
        Write-EwiJsonAtomic -Path $transactionPath -Value $current -SchemaPath $transactionSchema
        return $success
    }
    $finalTransaction = Read-EwiJson -Path $transactionPath -SchemaPath $transactionSchema
    $evidence = Write-PublishOperationEvidence -Transaction $finalTransaction -TransactionPath $transactionPath -Kind recovery -Status $(if ($rolledBack) { 'passed' } else { 'blocked' }) -Summary $(if ($rolledBack) { 'The publish transaction was rolled back and restoration was verified.' } else { 'Automatic rollback stopped because a safe restoration could not be proven.' })
    [pscustomobject][ordered]@{
        status = if ($rolledBack) { 'rolled_back' } else { 'recovery_required' }
        publish_id = $PublishId
        user_baseline_advanced = $false
        evidence = $evidence
    } | ConvertTo-Json -Depth 5
    return
}

$plan = Get-PublishPlan -Id $WorkstreamId
$canApply = @($plan.blockers).Count -eq 0 -and @($plan.conflicts).Count -eq 0 -and @($plan.manifest).Count -gt 0
if (-not $Apply) {
    [pscustomobject][ordered]@{
        status = 'report-only'
        workstream_id = $WorkstreamId
        reminder = 'Save related IDE and editor files before applying this publish plan.'
        can_apply = $canApply
        manifest_digest = $plan.manifest_digest
        files = @($plan.manifest)
        conflicts = @($plan.conflicts)
        blockers = @($plan.blockers)
        changed = $false
    } | ConvertTo-Json -Depth 15
    return
}
if (-not $canApply) {
    throw "Publish plan is blocked: $([string]::Join('; ', @($plan.blockers)))"
}
if ($ExpectedManifestDigest -ne $plan.manifest_digest) {
    throw 'Approved manifest digest does not match the current publish plan.'
}

$publishIdValue = 'publish-' + [DateTimeOffset]::Now.ToString('yyyyMMddHHmmssfff') + '-' + ([Guid]::NewGuid().ToString('N').Substring(0, 6))
$transactionPathValue = Join-Path $root "workspace-management/sync-state/transactions/$publishIdValue.json"
$result = Invoke-EwiLocked -WorkspaceRoot $root -TimeoutSeconds $MutexTimeoutSeconds -ScriptBlock {
    $null = Assert-EwiActiveWorkspace -WorkspaceRoot $root
    $lockedPlan = Get-PublishPlan -Id $WorkstreamId
    if (@($lockedPlan.blockers).Count -gt 0 -or @($lockedPlan.conflicts).Count -gt 0 -or $lockedPlan.manifest_digest -ne $ExpectedManifestDigest) {
        throw 'Publish state changed after planning; no user files were written.'
    }

    $now = Get-EwiTimestamp
    $recoveryRelative = "workspace-management/recovery/$publishIdValue"
    $recoveryRoot = Join-EwiContainedPath -Root $root -RelativePath $recoveryRelative
    $null = New-Item -ItemType Directory -Path $recoveryRoot
    $transaction = [ordered]@{
        schema = 1
        publish_id = $publishIdValue
        workstream_id = $WorkstreamId
        state = 'planned'
        created_at = $now
        updated_at = $now
        mapping_revisions = $lockedPlan.mapping_revisions
        head_commits = $lockedPlan.head_commits
        manifest = @($lockedPlan.manifest)
        manifest_digest = $lockedPlan.manifest_digest
        recovery_path = $recoveryRelative
        file_publish_status = 'pending'
        build_status = 'not-run'
        side_effect_status = 'clean'
        side_effects = @()
        build_target_id = $null
        build_id = $null
        build_evidence_ref = $null
        message = $null
    }
    Write-EwiJsonAtomic -Path $transactionPathValue -Value $transaction -SchemaPath $transactionSchema

    $privateUpdates = [Collections.Generic.List[object]]::new()
    $workstreamOriginal = [IO.File]::ReadAllBytes($lockedPlan.workstream_path)
    try {
        foreach ($item in @($transaction.manifest)) {
            $internalKey = "$($item.source_id)|$($item.mapping_id)|$(([string]$item.relative_path).ToLowerInvariant())"
            $details = $lockedPlan.internal[$internalKey]
            $currentHash = if (Test-Path -LiteralPath $details.authority_file -PathType Leaf) { Get-EwiSha256 $details.authority_file } else { $null }
            if ($currentHash -ne $item.precondition_hash) { throw "Publish precondition changed: $internalKey" }
            if ($null -ne $item.user_hash) {
                $snapshot = Join-EwiContainedPath -Root $recoveryRoot -RelativePath "original/$($item.source_id)/$($item.mapping_id)/$($item.relative_path)"
                $parent = Split-Path -Parent $snapshot
                if (-not (Test-Path -LiteralPath $parent)) { $null = New-Item -ItemType Directory -Path $parent }
                [IO.File]::Copy($details.authority_file, $snapshot, $true)
                if ((Get-EwiSha256 $snapshot) -ne $item.user_hash) { throw "Recovery snapshot hash mismatch: $internalKey" }
            }
        }
        $transaction.state = 'backed_up'
        $transaction.updated_at = Get-EwiTimestamp
        Write-EwiJsonAtomic -Path $transactionPathValue -Value $transaction -SchemaPath $transactionSchema

        foreach ($item in @($transaction.manifest)) {
            $internalKey = "$($item.source_id)|$($item.mapping_id)|$(([string]$item.relative_path).ToLowerInvariant())"
            $details = $lockedPlan.internal[$internalKey]
            $currentHash = if (Test-Path -LiteralPath $details.authority_file -PathType Leaf) { Get-EwiSha256 $details.authority_file } else { $null }
            if ($currentHash -ne $item.precondition_hash) { throw "Pre-apply hash changed: $internalKey" }
        }

        $transaction.state = 'applying'
        $transaction.updated_at = Get-EwiTimestamp
        Write-EwiJsonAtomic -Path $transactionPathValue -Value $transaction -SchemaPath $transactionSchema
        foreach ($item in @($transaction.manifest)) {
            $internalKey = "$($item.source_id)|$($item.mapping_id)|$(([string]$item.relative_path).ToLowerInvariant())"
            $details = $lockedPlan.internal[$internalKey]
            $currentHash = if (Test-Path -LiteralPath $details.authority_file -PathType Leaf) { Get-EwiSha256 $details.authority_file } else { $null }
            if ($currentHash -ne $item.precondition_hash) { throw "Per-file hash changed: $internalKey" }
            if ($item.operation -eq 'delete') {
                $deleted = Join-EwiContainedPath -Root $recoveryRoot -RelativePath "deleted/$($item.source_id)/$($item.mapping_id)/$($item.relative_path)"
                $parent = Split-Path -Parent $deleted
                if (-not (Test-Path -LiteralPath $parent)) { $null = New-Item -ItemType Directory -Path $parent }
                [IO.File]::Move($details.authority_file, $deleted, $true)
            }
            else {
                $bytes = $lockedPlan.content["$($item.source_id)|$($details.integration_path)"]
                if ($null -eq $bytes -or (Get-BytesSha256 $bytes) -ne $item.expected_hash) { throw "Frozen Agent blob is unavailable: $internalKey" }
                $parent = Split-Path -Parent $details.authority_file
                if (-not (Test-Path -LiteralPath $parent)) { $null = New-Item -ItemType Directory -Path $parent }
                $temporary = Join-Path $parent ('.publish-' + [Guid]::NewGuid().ToString('N') + '.tmp')
                try {
                    [IO.File]::WriteAllBytes($temporary, $bytes)
                    [IO.File]::Move($temporary, $details.authority_file, $true)
                }
                finally {
                    if (Test-Path -LiteralPath $temporary) { [IO.File]::Delete($temporary) }
                }
            }
        }
        $transaction.state = 'applied'
        $transaction.updated_at = Get-EwiTimestamp
        Write-EwiJsonAtomic -Path $transactionPathValue -Value $transaction -SchemaPath $transactionSchema

        foreach ($item in @($transaction.manifest)) {
            $details = $lockedPlan.internal["$($item.source_id)|$($item.mapping_id)|$(([string]$item.relative_path).ToLowerInvariant())"]
            $actualHash = if (Test-Path -LiteralPath $details.authority_file -PathType Leaf) { Get-EwiSha256 $details.authority_file } else { $null }
            if ($actualHash -ne $item.expected_hash) { throw "Published file verification failed: $($item.relative_path)" }
        }
        $transaction.state = 'file_verified'
        $transaction.file_publish_status = 'verified'
        $transaction.build_status = if ($RequireUserBuild) { 'not-run' } else { 'unavailable' }
        $transaction.message = if ($RequireUserBuild) {
            'Files are verified. Run invoke-build.ps1 with BuildContext user-authority and this publish id, then finalize or roll back.'
        }
        else {
            'Files verified; no safe user-authority build was requested, so build verification is unavailable.'
        }
        $transaction.updated_at = Get-EwiTimestamp
        Write-EwiJsonAtomic -Path $transactionPathValue -Value $transaction -SchemaPath $transactionSchema

        $frozenWorkstream = $lockedPlan.workstream
        foreach ($sourceId in Get-ObjectNames $transaction.head_commits) {
            $frozenRef = Get-ObjectValue $frozenWorkstream.agent.refs $sourceId
            $frozenRef.head_commit = [string](Get-ObjectValue $transaction.head_commits $sourceId)
        }
        $frozenWorkstream.updated_at = Get-EwiTimestamp
        Write-EwiJsonAtomic -Path $lockedPlan.workstream_path -Value $frozenWorkstream -SchemaPath $workstreamSchema
        $null = New-EwiGitCommit -Repository $root -Message "chore: freeze publish $publishIdValue" -RelativePaths @("work/$WorkstreamId/workstream.json")

        if ($RequireUserBuild) {
            return [pscustomobject][ordered]@{
                status = 'awaiting-user-build'
                publish_id = $publishIdValue
                files = @($transaction.manifest).Count
                build_status = 'not-run'
                user_baseline_advanced = $false
                recovery_path = $recoveryRelative
            }
        }

        foreach ($sourceId in Get-ObjectNames $lockedPlan.head_commits) {
            $sourceInfo = $lockedPlan.internal["source|$sourceId"]
            $oldBaseline = [string]$sourceInfo.state.user_baseline_commit
            $gitPaths = [Collections.Generic.List[string]]::new()
            foreach ($item in @($transaction.manifest | Where-Object source_id -eq $sourceId)) {
                $details = $lockedPlan.internal["$sourceId|$($item.mapping_id)|$(([string]$item.relative_path).ToLowerInvariant())"]
                $integrationFile = Join-EwiContainedPath -Root $sourceInfo.integration -RelativePath $details.integration_path
                if ($item.operation -eq 'delete') {
                    if (Test-Path -LiteralPath $integrationFile -PathType Leaf) { [IO.File]::Delete($integrationFile) }
                }
                else {
                    $bytes = $lockedPlan.content["$sourceId|$($details.integration_path)"]
                    $parent = Split-Path -Parent $integrationFile
                    if (-not (Test-Path -LiteralPath $parent)) { $null = New-Item -ItemType Directory -Path $parent }
                    $temporary = Join-Path $parent ('.baseline-' + [Guid]::NewGuid().ToString('N') + '.tmp')
                    try {
                        [IO.File]::WriteAllBytes($temporary, $bytes)
                        [IO.File]::Move($temporary, $integrationFile, $true)
                    }
                    finally {
                        if (Test-Path -LiteralPath $temporary) { [IO.File]::Delete($temporary) }
                    }
                }
                $gitPaths.Add($details.integration_path)
            }
            $newBaseline = New-EwiGitCommit -Repository $sourceInfo.integration -Message "chore: record published user baseline $publishIdValue" -RelativePaths @($gitPaths)
            if (-not $newBaseline) { throw "Published source '$sourceId' did not create a new baseline commit." }
            $baselineId = 'baseline-' + [DateTimeOffset]::Now.ToString('yyyyMMddHHmmssfff') + '-' + $sourceId
            $baselineRef = "refs/agent/user-baselines/$baselineId"
            $publishRef = "refs/agent/publishes/$publishIdValue/$sourceId"
            $null = Invoke-EwiGit -Repository $sourceInfo.integration -ArgumentList @('update-ref', $baselineRef, $newBaseline)
            $null = Invoke-EwiGit -Repository $sourceInfo.integration -ArgumentList @('update-ref', $publishRef, [string]$lockedPlan.head_commits[$sourceId])
            $privateUpdates.Add([pscustomobject][ordered]@{
                source_id = $sourceId
                integration = $sourceInfo.integration
                old_baseline = $oldBaseline
                new_baseline = $newBaseline
                baseline_ref = $baselineRef
                publish_ref = $publishRef
            })
        }

        $workstream = $lockedPlan.workstream
        foreach ($update in $privateUpdates) {
            $ref = $workstream.agent.refs.PSObject.Properties[$update.source_id].Value
            $worktree = Join-EwiContainedPath -Root $root -RelativePath ([string]$ref.worktree)
            $null = Invoke-EwiGit -Repository $worktree -ArgumentList @('reset', '--hard', $update.new_baseline)
            $ref.user_baseline_commit = $update.new_baseline
            $ref.task_base_commit = $update.new_baseline
            $ref.head_commit = $null

            $sourceInfo = $lockedPlan.internal["source|$($update.source_id)"]
            $newEntries = [Collections.Generic.List[object]]::new()
            foreach ($inventoryInfo in @($sourceInfo.inventories)) {
                $mappingConfig = @($sourceInfo.source.mappings | Where-Object mapping_id -eq $inventoryInfo.mapping_id)[0]
                $freshFull = Get-EwiFileInventory -Root $inventoryInfo.authority -MappingId $inventoryInfo.mapping_id
                $fresh = Select-ManagedInventory -Inventory $freshFull -IntegrationSubpath ([string]$mappingConfig.integration_subpath) -Patterns (Get-SourceOutputPatterns -Targets (Read-EwiJson -Path (Join-Path $root 'workspace-management/config/targets.json') -SchemaPath $targetsSchema) -CurrentSourceId $update.source_id)
                if (-not $fresh.scan_complete) { throw "Post-publish user scan is incomplete: $($inventoryInfo.mapping_id)" }
                foreach ($entry in @($fresh.files)) { $newEntries.Add($entry) }
            }
            Write-EwiJsonLinesAtomic -Path $sourceInfo.index_path -Records @($newEntries) -SchemaPath (Join-Path $root 'workspace-management/schemas/file-index-record.schema.json')
            $sourceState = $sourceInfo.state
            $sourceState.user_baseline_id = [IO.Path]::GetFileName($update.baseline_ref)
            $sourceState.user_baseline_commit = $update.new_baseline
            $sourceState.user_baseline_ref = $update.baseline_ref
            $sourceState.captured_at = Get-EwiTimestamp
            $sourceState.scan_complete = $true
            Write-EwiJsonAtomic -Path $sourceInfo.state_path -Value $sourceState -SchemaPath $sourceStateSchema
        }
        $workstream.has_unresolved_changes = $false
        $workstream.updated_at = Get-EwiTimestamp
        Write-EwiJsonAtomic -Path $lockedPlan.workstream_path -Value $workstream -SchemaPath $workstreamSchema

        $transaction.state = 'completed'
        $transaction.updated_at = Get-EwiTimestamp
        Write-EwiJsonAtomic -Path $transactionPathValue -Value $transaction -SchemaPath $transactionSchema
        $null = New-EwiGitCommit -Repository $root -Message "chore: complete publish $publishIdValue" -RelativePaths @("work/$WorkstreamId/workstream.json")
        return [pscustomobject][ordered]@{
            status = 'completed'
            publish_id = $publishIdValue
            files = @($transaction.manifest).Count
            build_status = 'unavailable'
            user_baselines = @($privateUpdates | ForEach-Object { [pscustomobject]@{ source_id = $_.source_id; commit = $_.new_baseline; ref = $_.baseline_ref } })
            recovery_path = $recoveryRelative
        }
    }
    catch {
        [IO.File]::WriteAllBytes($lockedPlan.workstream_path, $workstreamOriginal)
        $null = Invoke-EwiGit -Repository $root -ArgumentList @('reset', '--', "work/$WorkstreamId/workstream.json") -AllowFailure
        foreach ($update in @($privateUpdates)) {
            $worktreeRef = $lockedPlan.workstream.agent.refs.PSObject.Properties[$update.source_id]
            if ($null -ne $worktreeRef) {
                $worktree = Join-EwiContainedPath -Root $root -RelativePath ([string]$worktreeRef.Value.worktree)
                $null = Invoke-EwiGit -Repository $worktree -ArgumentList @('reset', '--hard', [string]$lockedPlan.head_commits[$update.source_id]) -AllowFailure
            }
            $null = Invoke-EwiGit -Repository $update.integration -ArgumentList @('reset', '--hard', $update.old_baseline) -AllowFailure
            $null = Invoke-EwiGit -Repository $update.integration -ArgumentList @('update-ref', '-d', $update.baseline_ref) -AllowFailure
            $null = Invoke-EwiGit -Repository $update.integration -ArgumentList @('update-ref', '-d', $update.publish_ref) -AllowFailure
        }
        $transaction.state = 'apply_failed'
        $transaction.file_publish_status = 'failed'
        $transaction.updated_at = Get-EwiTimestamp
        $transaction.message = $_.Exception.Message
        $rolledBack = Restore-TransactionFiles -Transaction $transaction -UpdateState
        if (-not $rolledBack) {
            $transaction.state = 'recovery_required'
            $transaction.message = "Automatic rollback could not prove a safe restore. Original error: $($_.Exception.Message)"
        }
        Write-EwiJsonAtomic -Path $transactionPathValue -Value $transaction -SchemaPath $transactionSchema
        $null = Write-PublishOperationEvidence -Transaction $transaction -TransactionPath $transactionPathValue -Kind recovery -Status $(if ($rolledBack) { 'failed' } else { 'blocked' }) -Summary $(if ($rolledBack) { 'The publish apply failed and all affected user files were restored.' } else { 'The publish apply failed and automatic rollback could not prove a safe restoration.' })
        throw
    }
}

$finalTransaction = Read-EwiJson -Path $transactionPathValue -SchemaPath $transactionSchema
$evidence = Write-PublishOperationEvidence -Transaction $finalTransaction -TransactionPath $transactionPathValue -Kind publish -Status passed -Summary $(if ($result.status -eq 'awaiting-user-build') { 'Published files were verified; the transaction is waiting for the required user-authority build.' } else { 'Published files and the resulting user baseline were verified.' })
$result | Add-Member -NotePropertyName evidence -NotePropertyValue $evidence
$result | ConvertTo-Json -Depth 12
