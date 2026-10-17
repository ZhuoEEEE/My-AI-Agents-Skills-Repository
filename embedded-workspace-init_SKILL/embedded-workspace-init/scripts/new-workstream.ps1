[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $WorkspaceRoot,
    [Parameter(Mandatory, ParameterSetName = 'New')] [string] $Title,
    [Parameter(ParameterSetName = 'New')] [string] $ScopeJson = '[]',
    [Parameter(Mandatory, ParameterSetName = 'Reuse')] [ValidatePattern('^\d{8}-[a-z0-9][a-z0-9-]{0,47}-[a-f0-9]{4}$')] [string] $ReuseWorkstreamId,
    [string] $ConversationHostId,
    [string] $ConversationThreadId,
    [int] $MutexTimeoutSeconds = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/workspace-common.psm1') -Force

$context = Assert-EwiActiveWorkspace -WorkspaceRoot $WorkspaceRoot
$root = $context.root
$workstreamSchema = Join-Path $root 'workspace-management/schemas/workstream.schema.json'
$targetsPath = Join-Path $root 'workspace-management/config/targets.json'
$targetsSchema = Join-Path $root 'workspace-management/schemas/targets.schema.json'

function Get-ObjectNames {
    param($Object)
    if ($Object -is [Collections.IDictionary]) { return @($Object.Keys) }
    return @($Object.PSObject.Properties | ForEach-Object Name)
}

function Get-ObjectValue {
    param($Object, [string] $Name)
    if ($Object -is [Collections.IDictionary]) { return $Object[$Name] }
    return $Object.PSObject.Properties[$Name].Value
}

function Test-ScopeOverlap {
    param([string] $First, [string] $Second)
    $a = (Assert-EwiRelativePath -Path $First -AllowDot).ToLowerInvariant()
    $b = (Assert-EwiRelativePath -Path $Second -AllowDot).ToLowerInvariant()
    if ($a -eq '.' -or $b -eq '.') { return $true }
    return $a -eq $b -or $a.StartsWith($b.TrimEnd('/') + '/') -or $b.StartsWith($a.TrimEnd('/') + '/')
}

if ($PSCmdlet.ParameterSetName -eq 'Reuse') {
    $path = Join-Path $root "work/$ReuseWorkstreamId/workstream.json"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Workstream does not exist: $ReuseWorkstreamId" }
    $existing = Read-EwiJson -Path $path -SchemaPath $workstreamSchema
    if ($existing.status -notin @('active', 'paused', 'blocked')) {
        throw "Workstream '$ReuseWorkstreamId' is terminal: $($existing.status)"
    }
    [pscustomobject][ordered]@{
        status = 'reused'
        workstream_id = $ReuseWorkstreamId
        title = $existing.title
        path = "work/$ReuseWorkstreamId"
        changed = $false
    } | ConvertTo-Json -Depth 5
    return
}

$scope = @($ScopeJson | ConvertFrom-Json -Depth 20 -ErrorAction Stop)
$targets = Read-EwiJson -Path $targetsPath -SchemaPath $targetsSchema
$targetsHash = Get-EwiSha256 $targetsPath
$scopeSourceIds = @($scope | ForEach-Object { [string]$_.source_id })
if (@($scopeSourceIds | Sort-Object -Unique).Count -ne $scopeSourceIds.Count) { throw 'A workstream scope may contain each source exactly once.' }
foreach ($entry in $scope) {
    if ([string]$entry.source_id -notin (Get-ObjectNames $targets.sources)) {
        throw "Unknown source id in scope: $($entry.source_id)"
    }
    foreach ($targetId in @($entry.targets)) {
        if ([string]$targetId -notin (Get-ObjectNames $targets.targets)) { throw "Unknown target id in scope: $targetId" }
        $target = Get-ObjectValue $targets.targets ([string]$targetId)
        if ([string]$target.source -ne [string]$entry.source_id) { throw "Target '$targetId' does not belong to scope source '$($entry.source_id)'." }
    }
    if (@($entry.paths).Count -eq 0) { throw "Scope for '$($entry.source_id)' requires explicit paths." }
    foreach ($pathScope in @($entry.paths)) {
        $pathScope.path = Assert-EwiRelativePath -Path ([string]$pathScope.path) -AllowDot
        if ([string]$pathScope.access -notin @('read', 'write')) { throw "Invalid scope access: $($pathScope.access)" }
    }
}

$conflicts = [Collections.Generic.List[object]]::new()
foreach ($file in Get-ChildItem -LiteralPath (Join-Path $root 'work') -Filter 'workstream.json' -File -Recurse -Depth 2 -ErrorAction SilentlyContinue) {
    $other = Read-EwiJson -Path $file.FullName -SchemaPath $workstreamSchema
    if ($other.status -in @('completed', 'abandoned') -and -not $other.has_unresolved_changes) { continue }
    foreach ($requestedSource in $scope) {
        foreach ($otherSource in @($other.scope | Where-Object source_id -eq $requestedSource.source_id)) {
            foreach ($requestedPath in @($requestedSource.paths | Where-Object access -eq 'write')) {
                foreach ($otherPath in @($otherSource.paths | Where-Object access -eq 'write')) {
                    if (Test-ScopeOverlap $requestedPath.path $otherPath.path) {
                        $conflicts.Add([pscustomobject][ordered]@{
                            workstream_id = $other.id
                            source_id = $requestedSource.source_id
                            requested_path = $requestedPath.path
                            existing_path = $otherPath.path
                        })
                    }
                }
            }
        }
    }
}
if ($conflicts.Count -gt 0) {
    [pscustomobject][ordered]@{
        status = 'scope-conflict'
        changed = $false
        conflicts = @($conflicts)
    } | ConvertTo-Json -Depth 10
    return
}

$slug = ConvertTo-EwiId -Value $Title -MaximumLength 36 -Fallback 'task'
$workstreamId = [DateTimeOffset]::Now.ToString('yyyyMMdd') + '-' + $slug + '-' + ([Guid]::NewGuid().ToString('N').Substring(0, 4))
$workstreamRoot = Join-Path $root "work/$workstreamId"

$result = Invoke-EwiLocked -WorkspaceRoot $root -TimeoutSeconds $MutexTimeoutSeconds -ScriptBlock {
    $null = Assert-EwiActiveWorkspace -WorkspaceRoot $root
    if ((Get-EwiSha256 $targetsPath) -ne $targetsHash) { throw 'Target configuration changed after workstream planning.' }
    $null = Read-EwiJson -Path $targetsPath -SchemaPath $targetsSchema
    if (Test-Path -LiteralPath $workstreamRoot) { throw "Workstream appeared during planning: $workstreamId" }

    # Scope conflicts are re-read under the shared lock.
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $root 'work') -Filter 'workstream.json' -File -Recurse -Depth 2 -ErrorAction SilentlyContinue) {
        $other = Read-EwiJson -Path $file.FullName -SchemaPath $workstreamSchema
        if ($other.status -in @('completed', 'abandoned') -and -not $other.has_unresolved_changes) { continue }
        foreach ($requestedSource in $scope) {
            foreach ($otherSource in @($other.scope | Where-Object source_id -eq $requestedSource.source_id)) {
                foreach ($requestedPath in @($requestedSource.paths | Where-Object access -eq 'write')) {
                    foreach ($otherPath in @($otherSource.paths | Where-Object access -eq 'write')) {
                        if (Test-ScopeOverlap $requestedPath.path $otherPath.path) {
                            throw "Scope now overlaps workstream '$($other.id)' for source '$($requestedSource.source_id)'."
                        }
                    }
                }
            }
        }
    }

    $createdWorktrees = [Collections.Generic.List[object]]::new()
    try {
        foreach ($relative in @('sources', 'reference-copies', 'tools', 'artifacts')) {
            $null = New-Item -ItemType Directory -Path (Join-Path $workstreamRoot $relative) -Force
        }
        $readmeTemplate = Get-Content -LiteralPath (Join-Path $root 'workspace-management/templates/workstream-README.md') -Raw -Encoding UTF8
        $readme = $readmeTemplate.Replace('{{WORKSTREAM_TITLE}}', $Title).
            Replace('{{GOAL}}', $Title).
            Replace('{{CURRENT_STATE}}', 'Active; source worktrees are created only when an engineering operation needs them.').
            Replace('{{DECISIONS}}', 'None recorded.').
            Replace('{{CHANGES}}', 'No task changes yet.').
            Replace('{{VERIFICATION}}', 'Not run.').
            Replace('{{NEXT}}', 'Begin the scoped task.')
        [IO.File]::WriteAllText((Join-Path $workstreamRoot 'README.md'), $readme.TrimEnd() + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))

        $responsibilities = [ordered]@{
            'reference-copies/README.md' = '# Reference copies`n`nMutable reference snapshots for this workstream. Each copy owns private Git and never participates in user publish.`n'
            'tools/README.md' = '# Task tools`n`nOne-off scripts owned by this workstream. Reusable workspace tooling belongs under workspace-management/tools/.`n'
            'artifacts/README.md' = '# Task artifacts`n`nReports, exports, and concise task outputs. Raw managed evidence belongs under workspace-management/evidence/.`n'
        }
        foreach ($relative in $responsibilities.Keys) {
            [IO.File]::WriteAllText((Join-Path $workstreamRoot $relative), $responsibilities[$relative].Replace('`n', [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        }

        $refs = [ordered]@{}
        foreach ($sourceId in @($scope | ForEach-Object source_id | Sort-Object -Unique)) {
            $source = Get-ObjectValue $targets.sources $sourceId
            $refs[$sourceId] = New-EwiSourceRef -WorkspaceRoot $root -Source $source -WorkstreamId $workstreamId -SourceId $sourceId
        }

        $conversation = if ($ConversationHostId -or $ConversationThreadId) {
            [ordered]@{ host_id = $ConversationHostId; thread_id = $ConversationThreadId }
        }
        else { $null }
        $manifest = [ordered]@{
            schema = 2
            id = $workstreamId
            status = 'active'
            title = $Title
            conversation = [ordered]@{ primary = $conversation }
            scope = @($scope)
            agent = [ordered]@{ refs = $refs }
            dependencies = @()
            has_unresolved_changes = $false
            updated_at = Get-EwiTimestamp
        }
        Write-EwiJsonAtomic -Path (Join-Path $workstreamRoot 'workstream.json') -Value $manifest -SchemaPath $workstreamSchema
        $tracked = @(
            "work/$workstreamId/README.md",
            "work/$workstreamId/workstream.json",
            "work/$workstreamId/reference-copies/README.md",
            "work/$workstreamId/tools/README.md",
            "work/$workstreamId/artifacts/README.md"
        )
        $null = New-EwiGitCommit -Repository $root -Message "chore: create workstream $workstreamId" -RelativePaths $tracked
        return [pscustomobject][ordered]@{
            status = 'created'
            workstream_id = $workstreamId
            path = "work/$workstreamId"
            sources = @($refs.Keys)
        }
    }
    catch {
        foreach ($created in @($createdWorktrees | Sort-Object { $_.path.Length } -Descending)) {
            $null = Invoke-EwiGit -Repository $created.repository -ArgumentList @('worktree', 'remove', '--force', $created.path) -AllowFailure
            $null = Invoke-EwiGit -Repository $created.repository -ArgumentList @('branch', '-D', $created.branch) -AllowFailure
        }
        if (Test-Path -LiteralPath $workstreamRoot) {
            $resolved = Resolve-EwiPath $workstreamRoot
            if (-not (Test-EwiPathWithin -Path $resolved -Parent (Join-Path $root 'work'))) {
                throw 'Refusing to clean a partial workstream outside work/.'
            }
            [IO.Directory]::Delete($resolved, $true)
        }
        throw
    }
}

$result | ConvertTo-Json -Depth 10
