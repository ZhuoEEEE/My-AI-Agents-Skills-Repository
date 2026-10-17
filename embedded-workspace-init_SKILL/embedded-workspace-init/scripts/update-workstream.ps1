[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $WorkspaceRoot,
    [Parameter(Mandatory)] [ValidatePattern('^\d{8}-[a-z0-9][a-z0-9-]{0,47}-[a-f0-9]{4}$')] [string] $WorkstreamId,
    [string] $ScopeJson,
    [ValidateSet('active', 'paused', 'blocked', 'completed', 'abandoned')] [string] $Status,
    [Nullable[bool]] $HasUnresolvedChanges,
    [int] $MutexTimeoutSeconds = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/workspace-common.psm1') -Force

$context = Assert-EwiActiveWorkspace -WorkspaceRoot $WorkspaceRoot
$root = $context.root
$targetsPath = Join-Path $root 'workspace-management/config/targets.json'
$targetsSchema = Join-Path $root 'workspace-management/schemas/targets.schema.json'
$targets = Read-EwiJson -Path $targetsPath -SchemaPath $targetsSchema
$schema = Join-Path $root 'workspace-management/schemas/workstream.schema.json'
$path = Join-Path $root "work/$WorkstreamId/workstream.json"
$current = Read-EwiJson -Path $path -SchemaPath $schema
$plannedScope = @(if ([string]::IsNullOrWhiteSpace($ScopeJson)) { $current.scope } else { $ScopeJson | ConvertFrom-Json -Depth 30 -ErrorAction Stop })
$plannedStatus = if ([string]::IsNullOrWhiteSpace($Status)) { [string]$current.status } else { $Status }
$plannedUnresolved = if ($null -eq $HasUnresolvedChanges) { [bool]$current.has_unresolved_changes } else { [bool]$HasUnresolvedChanges }

function Test-ScopeOverlap {
    param([string] $First, [string] $Second)
    $a = (Assert-EwiRelativePath -Path $First -AllowDot).ToLowerInvariant()
    $b = (Assert-EwiRelativePath -Path $Second -AllowDot).ToLowerInvariant()
    return $a -eq '.' -or $b -eq '.' -or $a -eq $b -or $a.StartsWith($b.TrimEnd('/') + '/') -or $b.StartsWith($a.TrimEnd('/') + '/')
}

function Validate-Scope {
    param([object[]] $Scope)
    if ($Scope.Count -eq 0 -and @($current.agent.refs.PSObject.Properties).Count -gt 0) { throw 'Keep source scope for existing source history.' }
    $scopeSourceIds = @($Scope | ForEach-Object { [string]$_.source_id })
    if (@($scopeSourceIds | Sort-Object -Unique).Count -ne $scopeSourceIds.Count) { throw 'A workstream scope may contain each source exactly once.' }
    $refSourceIds = @($current.agent.refs.PSObject.Properties | ForEach-Object Name | Sort-Object)
    if (@($refSourceIds | Where-Object { $_ -notin $scopeSourceIds }).Count -gt 0) { throw 'Keep existing source refs in scope; release engineering copies separately.' }
    foreach ($entry in $Scope) {
        $source = $targets.sources.PSObject.Properties[[string]$entry.source_id]
        if ($null -eq $source) { throw "Unknown source in scope: $($entry.source_id)" }
        foreach ($targetId in @($entry.targets)) {
            if ($null -eq $targets.targets.PSObject.Properties[[string]$targetId]) { throw "Unknown target in scope: $targetId" }
            if ([string]$targets.targets.PSObject.Properties[[string]$targetId].Value.source -ne [string]$entry.source_id) { throw "Target '$targetId' does not belong to scope source '$($entry.source_id)'." }
        }
        if (@($entry.paths).Count -eq 0) { throw "Scope requires a path for source '$($entry.source_id)'." }
        foreach ($item in @($entry.paths)) {
            $item.path = Assert-EwiRelativePath -Path ([string]$item.path) -AllowDot
            if ([string]$item.access -notin @('read', 'write')) { throw "Invalid scope access: $($item.access)" }
        }
    }
}

function Get-ScopeConflicts {
    param([object[]] $Scope)
    $conflicts = [Collections.Generic.List[object]]::new()
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $root 'work') -Filter 'workstream.json' -File -Recurse -Depth 2 -ErrorAction SilentlyContinue) {
        $other = Read-EwiJson -Path $file.FullName -SchemaPath $schema
        if ($other.id -eq $WorkstreamId) { continue }
        if ($other.status -in @('completed', 'abandoned') -and -not $other.has_unresolved_changes) { continue }
        foreach ($requestedSource in $Scope) {
            foreach ($otherSource in @($other.scope | Where-Object source_id -eq $requestedSource.source_id)) {
                foreach ($requestedPath in @($requestedSource.paths | Where-Object access -eq 'write')) {
                    foreach ($otherPath in @($otherSource.paths | Where-Object access -eq 'write')) {
                        if (Test-ScopeOverlap $requestedPath.path $otherPath.path) {
                            $conflicts.Add([pscustomobject][ordered]@{ workstream_id = $other.id; source_id = $requestedSource.source_id; requested_path = $requestedPath.path; existing_path = $otherPath.path })
                        }
                    }
                }
            }
        }
    }
    return @($conflicts)
}

Validate-Scope $plannedScope
function Invoke-CompletionProjectRelease {
    $releases = @()
    $finished = Read-EwiJson -Path $path -SchemaPath $schema
    foreach ($sourceProperty in $finished.agent.refs.PSObject.Properties) {
        $ids = @($sourceProperty.Value.projects.PSObject.Properties | Where-Object { $_.Value.state -eq 'mounted' } | ForEach-Object Name)
        foreach ($id in $ids) {
            $arguments = @{ WorkspaceRoot = $root; WorkstreamId = $WorkstreamId; SourceId = $sourceProperty.Name; ProjectId = @($id); Action = 'Release' }
            $release = & (Join-Path $PSScriptRoot 'manage-project-copy.ps1') @arguments | ConvertFrom-Json -Depth 50
            if ($release.can_apply -and $release.changed) { $release = & (Join-Path $PSScriptRoot 'manage-project-copy.ps1') @arguments -Apply -ExpectedPlanDigest $release.plan_digest | ConvertFrom-Json -Depth 50 }
            $releases += $release
        }
    }
    return $releases
}
$conflicts = @(Get-ScopeConflicts $plannedScope)
if ($conflicts.Count -gt 0) {
    [pscustomobject][ordered]@{ status = 'scope-conflict'; changed = $false; conflicts = $conflicts } | ConvertTo-Json -Depth 10
    return
}
$changed = (ConvertTo-EwiCanonicalJson @($current.scope)) -cne (ConvertTo-EwiCanonicalJson @($plannedScope)) -or
    $current.status -ne $plannedStatus -or [bool]$current.has_unresolved_changes -ne $plannedUnresolved
if (-not $changed) {
    $unchanged = [pscustomobject][ordered]@{ status = 'unchanged'; workstream_id = $WorkstreamId; changed = $false }
    if ($plannedStatus -eq 'completed' -and -not $plannedUnresolved) { $unchanged | Add-Member -NotePropertyName project_releases -NotePropertyValue @(Invoke-CompletionProjectRelease) }
    $unchanged | ConvertTo-Json -Depth 50
    return
}
$initialHash = Get-EwiSha256 $path
$targetsHash = Get-EwiSha256 $targetsPath
$original = [IO.File]::ReadAllBytes($path)
$result = Invoke-EwiLocked -WorkspaceRoot $root -TimeoutSeconds $MutexTimeoutSeconds -ScriptBlock {
    $null = Assert-EwiActiveWorkspace -WorkspaceRoot $root
    if ((Get-EwiSha256 $path) -ne $initialHash -or (Get-EwiSha256 $targetsPath) -ne $targetsHash) { throw 'Workstream or target configuration changed after update planning.' }
    $null = Read-EwiJson -Path $targetsPath -SchemaPath $targetsSchema
    $lockedConflicts = @(Get-ScopeConflicts $plannedScope)
    if ($lockedConflicts.Count -gt 0) { throw 'Workstream scope began conflicting after lock acquisition.' }
    try {
        $manifest = Read-EwiJson -Path $path -SchemaPath $schema
        foreach ($entry in $plannedScope) {
            if ($null -eq $manifest.agent.refs.PSObject.Properties[[string]$entry.source_id]) {
                $ref = New-EwiSourceRef -WorkspaceRoot $root -Source $targets.sources.PSObject.Properties[[string]$entry.source_id].Value -WorkstreamId $WorkstreamId -SourceId ([string]$entry.source_id)
                $manifest.agent.refs | Add-Member -NotePropertyName ([string]$entry.source_id) -NotePropertyValue $ref
            }
        }
        foreach ($entry in $plannedScope) {
            if ($null -eq $manifest.agent.refs.PSObject.Properties[[string]$entry.source_id]) {
                $ref = New-EwiSourceRef -WorkspaceRoot $root -Source $targets.sources.PSObject.Properties[[string]$entry.source_id].Value -WorkstreamId $WorkstreamId -SourceId ([string]$entry.source_id)
                $manifest.agent.refs | Add-Member -NotePropertyName ([string]$entry.source_id) -NotePropertyValue $ref
            }
        }
        foreach ($entry in $plannedScope) {
            if ($null -eq $manifest.agent.refs.PSObject.Properties[[string]$entry.source_id]) {
                $ref = New-EwiSourceRef -WorkspaceRoot $root -Source $targets.sources.PSObject.Properties[[string]$entry.source_id].Value -WorkstreamId $WorkstreamId -SourceId ([string]$entry.source_id)
                $manifest.agent.refs | Add-Member -NotePropertyName ([string]$entry.source_id) -NotePropertyValue $ref
            }
        }
        $manifest.scope = @($plannedScope)
        $manifest.status = $plannedStatus
        $manifest.has_unresolved_changes = $plannedUnresolved
        $manifest.updated_at = Get-EwiTimestamp
        Write-EwiJsonAtomic -Path $path -Value $manifest -SchemaPath $schema
        $commit = New-EwiGitCommit -Repository $root -Message "chore: update workstream $WorkstreamId" -RelativePaths @("work/$WorkstreamId/workstream.json")
        return [pscustomobject][ordered]@{ status = 'updated'; workstream_id = $WorkstreamId; workstream_status = $plannedStatus; has_unresolved_changes = $plannedUnresolved; scope = @($plannedScope); management_commit = $commit; changed = $true }
    }
    catch {
        [IO.File]::WriteAllBytes($path, $original)
        $null = Invoke-EwiGit -Repository $root -ArgumentList @('reset', '--', "work/$WorkstreamId/workstream.json") -AllowFailure
        throw
    }
}

if ($plannedStatus -eq 'completed' -and -not $plannedUnresolved) {
    $result | Add-Member -NotePropertyName project_releases -NotePropertyValue @(Invoke-CompletionProjectRelease)
}
$result | ConvertTo-Json -Depth 50
