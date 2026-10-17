[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $WorkspaceRoot,
    [Parameter(Mandatory)] [ValidatePattern('^\d{8}-[a-z0-9][a-z0-9-]{0,47}-[a-f0-9]{4}$')] [string] $WorkstreamId,
    [Parameter(Mandatory)] [ValidatePattern('^\d{8}-[a-z0-9][a-z0-9-]{0,47}-[a-f0-9]{4}$')] [string] $DependencyWorkstreamId,
    [switch] $Apply,
    [int] $MutexTimeoutSeconds = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/workspace-common.psm1') -Force

$context = Assert-EwiActiveWorkspace -WorkspaceRoot $WorkspaceRoot
$root = $context.root
$schema = Join-Path $root 'workspace-management/schemas/workstream.schema.json'
$targetsPath = Join-Path $root 'workspace-management/config/targets.json'
$targetsSchema = Join-Path $root 'workspace-management/schemas/targets.schema.json'
$targets = Read-EwiJson -Path $targetsPath -SchemaPath $targetsSchema
$consumerPath = Join-Path $root "work/$WorkstreamId/workstream.json"
$dependencyPath = Join-Path $root "work/$DependencyWorkstreamId/workstream.json"
if (-not (Test-Path -LiteralPath $consumerPath) -or -not (Test-Path -LiteralPath $dependencyPath)) { throw 'Consumer or dependency workstream does not exist.' }
if ($WorkstreamId -eq $DependencyWorkstreamId) { throw 'A workstream cannot depend on itself.' }

function Read-Workstream {
    param([string] $Id)
    Read-EwiJson -Path (Join-Path $root "work/$Id/workstream.json") -SchemaPath $schema
}

function Test-DependencyPath {
    param([string] $StartId, [string] $SoughtId, [hashtable] $Seen)
    if ($Seen.ContainsKey($StartId)) { return $false }
    $Seen[$StartId] = $true
    $current = Read-Workstream $StartId
    foreach ($item in @($current.dependencies)) {
        if ($item.workstream_id -eq $SoughtId) { return $true }
        if (Test-DependencyPath -StartId ([string]$item.workstream_id) -SoughtId $SoughtId -Seen $Seen) { return $true }
    }
    return $false
}

function Get-ObjectNames {
    param($Object)
    if ($Object -is [Collections.IDictionary]) { return @($Object.Keys) }
    return @($Object.PSObject.Properties.Name)
}

function Get-ObjectValue {
    param($Object, [string] $Name)
    if ($Object -is [Collections.IDictionary]) { return $Object[$Name] }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

$consumer = Read-Workstream $WorkstreamId
$dependency = Read-Workstream $DependencyWorkstreamId
$blockers = [Collections.Generic.List[string]]::new()
if ($consumer.status -notin @('active', 'paused', 'blocked') -or $dependency.status -notin @('active', 'paused', 'blocked', 'completed')) {
    $blockers.Add('Consumer or dependency state does not permit pinning.')
}
if (Test-DependencyPath -StartId $DependencyWorkstreamId -SoughtId $WorkstreamId -Seen @{}) { $blockers.Add('The requested dependency would create a cycle.') }

$pinnedRefs = [ordered]@{}
foreach ($sourceId in Get-ObjectNames $dependency.agent.refs) {
    Assert-EwiSourceCopyReady $root $sourceId
    $dependencyRef = Get-ObjectValue $dependency.agent.refs $sourceId
    $consumerRef = Get-ObjectValue $consumer.agent.refs $sourceId
    $source = Get-ObjectValue $targets.sources $sourceId
    if ($null -eq $consumerRef -or $null -eq $source) {
        $blockers.Add("Consumer does not mount dependency source '$sourceId'.")
        continue
    }
    if ([int]$dependencyRef.mapping_revision -ne [int]$source.mapping_revision -or [int]$consumerRef.mapping_revision -ne [int]$source.mapping_revision) {
        $blockers.Add("Mapping revision is stale for dependency source '$sourceId'.")
        continue
    }
    $dependencyWorktree = Join-EwiContainedPath -Root $root -RelativePath ([string]$dependencyRef.worktree)
    $consumerWorktree = Join-EwiContainedPath -Root $root -RelativePath ([string]$consumerRef.worktree)
    if ($consumerRef.checkout_state -in @('none','released','recovery-required')) { $blockers.Add('Mount the consumer engineering project before pinning dependencies.'); continue }
    if ((Test-Path -LiteralPath $dependencyWorktree) -and -not [string]::IsNullOrWhiteSpace((Invoke-EwiGit -Repository $dependencyWorktree -ArgumentList @('status', '--porcelain=v1')).StdOut)) { $blockers.Add("Dependency worktree is dirty: $sourceId") }
    if (-not [string]::IsNullOrWhiteSpace((Invoke-EwiGit -Repository $consumerWorktree -ArgumentList @('status', '--porcelain=v1')).StdOut)) { $blockers.Add("Consumer worktree is dirty: $sourceId") }
    $dependencyHead = Get-EwiSourceRefHead (Join-Path $root $source.integration_path) $dependencyRef
    $consumerHead = (Invoke-EwiGit -Repository $consumerWorktree -ArgumentList @('rev-parse', 'HEAD')).StdOut.Trim()
    if ($consumerHead -ne [string]$consumerRef.task_base_commit) { $blockers.Add("Consumer already has task commits for '$sourceId'; pin dependencies before task development.") }
    $integration = Join-EwiContainedPath -Root $root -RelativePath ([string]$source.integration_path)
    foreach ($commit in @([string]$dependencyRef.task_base_commit, $dependencyHead)) {
        if ((Invoke-EwiGit -Repository $integration -ArgumentList @('cat-file', '-e', "$commit^{commit}") -AllowFailure).ExitCode -ne 0) { $blockers.Add("Dependency commit is not reachable for '$sourceId': $commit") }
    }
    $pinnedRefs[$sourceId] = [ordered]@{
        task_base_commit = [string]$dependencyRef.task_base_commit
        head_commit = $dependencyHead
        mapping_revision = [int]$dependencyRef.mapping_revision
    }
}
if ($pinnedRefs.Count -eq 0) { $blockers.Add('The dependency has no pinnable source refs.') }

$records = [Collections.Generic.List[object]]::new()
$inheritedDependencyIds = @($dependency.dependencies | ForEach-Object { [string]$_.workstream_id })
foreach ($existing in @($consumer.dependencies | Where-Object { $_.workstream_id -ne $DependencyWorkstreamId -and $_.workstream_id -notin $inheritedDependencyIds })) { $records.Add($existing) }
foreach ($inherited in @($dependency.dependencies)) { $records.Add($inherited) }
$records.Add([pscustomobject][ordered]@{ workstream_id = $DependencyWorkstreamId; refs = [pscustomobject]$pinnedRefs })
$report = [pscustomobject][ordered]@{
    status = 'report-only'
    workstream_id = $WorkstreamId
    dependency_workstream_id = $DependencyWorkstreamId
    refs = [pscustomobject]$pinnedRefs
    repin = @($consumer.dependencies | Where-Object workstream_id -eq $DependencyWorkstreamId).Count -eq 1
    blockers = @($blockers | Sort-Object -Unique)
    can_apply = ($blockers.Count -eq 0)
    changed = $false
}
if (-not $Apply) {
    $report | ConvertTo-Json -Depth 20
    return
}
if (-not $report.can_apply) { throw "Dependency pin is blocked: $([string]::Join('; ', $report.blockers))" }

$consumerHash = Get-EwiSha256 $consumerPath
$dependencyHash = Get-EwiSha256 $dependencyPath
$targetsHash = Get-EwiSha256 $targetsPath
$result = Invoke-EwiLocked -WorkspaceRoot $root -TimeoutSeconds $MutexTimeoutSeconds -ScriptBlock {
    $null = Assert-EwiActiveWorkspace -WorkspaceRoot $root
    if ((Get-EwiSha256 $consumerPath) -ne $consumerHash -or (Get-EwiSha256 $dependencyPath) -ne $dependencyHash -or (Get-EwiSha256 $targetsPath) -ne $targetsHash) { throw 'A workstream or target configuration changed after dependency planning.' }
    $null = Read-EwiJson -Path $targetsPath -SchemaPath $targetsSchema
    $currentConsumer = Read-Workstream $WorkstreamId
    $original = [IO.File]::ReadAllBytes($consumerPath)
    $updates = [Collections.Generic.List[object]]::new()
    try {
        foreach ($sourceId in Get-ObjectNames $pinnedRefs) {
            $consumerRef = Get-ObjectValue $currentConsumer.agent.refs $sourceId
            $source = Get-ObjectValue $targets.sources $sourceId
            $worktree = Join-EwiContainedPath -Root $root -RelativePath ([string]$consumerRef.worktree)
            $oldHead = (Invoke-EwiGit -Repository $worktree -ArgumentList @('rev-parse', 'HEAD')).StdOut.Trim()
            if ($oldHead -ne [string]$consumerRef.task_base_commit -or -not [string]::IsNullOrWhiteSpace((Invoke-EwiGit -Repository $worktree -ArgumentList @('status', '--porcelain=v1')).StdOut)) {
                throw "Consumer changed after dependency planning: $sourceId"
            }
            $base = if ($consumerRef.user_baseline_commit) { [string]$consumerRef.user_baseline_commit } else {
                $integration = Join-EwiContainedPath -Root $root -RelativePath ([string]$source.integration_path)
                (Invoke-EwiGit -Repository $integration -ArgumentList @('rev-parse', 'HEAD')).StdOut.Trim()
            }
            $updates.Add([pscustomobject]@{ source_id = $sourceId; worktree = $worktree; old_head = $oldHead; base = $base })
            $null = Invoke-EwiGit -Repository $worktree -ArgumentList @('reset', '--hard', $base)
            foreach ($record in @($records | Sort-Object workstream_id)) {
                $recordRef = Get-ObjectValue $record.refs $sourceId
                if ($null -eq $recordRef) { continue }
                $null = Invoke-EwiGit -Repository $worktree -ArgumentList @('merge', '--no-ff', '--no-edit', [string]$recordRef.head_commit)
            }
            $consumerRef.task_base_commit = (Invoke-EwiGit -Repository $worktree -ArgumentList @('rev-parse', 'HEAD')).StdOut.Trim()
            $consumerRef.head_commit = $null
            Set-EwiProjectSelection $worktree $consumerRef.projects
        }
        $currentConsumer.dependencies = @($records | Sort-Object workstream_id)
        $currentConsumer.updated_at = Get-EwiTimestamp
        Write-EwiJsonAtomic -Path $consumerPath -Value $currentConsumer -SchemaPath $schema
        $managementCommit = New-EwiGitCommit -Repository $root -Message "chore: pin dependency $DependencyWorkstreamId for $WorkstreamId" -RelativePaths @("work/$WorkstreamId/workstream.json")
        return [pscustomobject][ordered]@{ status = 'pinned'; workstream_id = $WorkstreamId; dependency_workstream_id = $DependencyWorkstreamId; repinned = $report.repin; refs = [pscustomobject]$pinnedRefs; management_commit = $managementCommit }
    }
    catch {
        foreach ($update in $updates) {
            $null = Invoke-EwiGit -Repository $update.worktree -ArgumentList @('merge', '--abort') -AllowFailure
            $null = Invoke-EwiGit -Repository $update.worktree -ArgumentList @('reset', '--hard', $update.old_head) -AllowFailure
        }
        [IO.File]::WriteAllBytes($consumerPath, $original)
        throw
    }
}

$result | ConvertTo-Json -Depth 20
