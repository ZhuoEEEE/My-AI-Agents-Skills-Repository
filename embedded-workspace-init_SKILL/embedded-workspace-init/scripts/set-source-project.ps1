[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $WorkspaceRoot,
    [Parameter(Mandatory)] [string] $SourceId,
    [Parameter(Mandatory)] [ValidatePattern('^[a-z0-9][a-z0-9-]{0,63}$')] [string] $ProjectId,
    [Parameter(Mandatory)] [string] $ProjectRoot,
    [string[]] $SharedPath = @(),
    [string[]] $TargetId = @(),
    [switch] $Apply,
    [string] $ExpectedPlanDigest,
    [int] $MutexTimeoutSeconds = 30
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/workspace-common.psm1') -Force
$root = (Assert-EwiActiveWorkspace $WorkspaceRoot).root
$path = Join-Path $root 'workspace-management/config/targets.json'
$schema = Join-Path $root 'workspace-management/schemas/targets.schema.json'
$targets = Read-EwiJson $path -SchemaPath $schema
$sourceProperty = $targets.sources.PSObject.Properties[$SourceId]
if ($null -eq $sourceProperty) { throw "Unknown source: $SourceId" }
$source = $sourceProperty.Value
$ProjectRoot = Assert-EwiRelativePath $ProjectRoot -AllowDot
$SharedPath = @($SharedPath | ForEach-Object { Assert-EwiRelativePath $_ -AllowDot } | Sort-Object -Unique)
$integration = Join-EwiContainedPath -Root $root -RelativePath $source.integration_path
$head = (Invoke-EwiGit $integration @('rev-parse', 'HEAD')).StdOut.Trim()
if ($ProjectRoot -ne '.' -and (Invoke-EwiGit $integration @('cat-file','-t',"$($head):$ProjectRoot")).StdOut.Trim() -ne 'tree') { throw 'Engineering project root must be a complete directory, not an individual file.' }
foreach ($selected in @($ProjectRoot) + $SharedPath) {
    $null = Join-EwiContainedPath -Root $integration -RelativePath $selected -AllowDot
    if ($selected -ne '.') { $null = Invoke-EwiGit $integration @('cat-file', '-e', "$($head):$selected") }
}
foreach ($project in $source.projects.PSObject.Properties | Where-Object Name -ne $ProjectId) {
    $existing = [string]$project.Value.root
    if ($ProjectRoot -eq '.' -or $existing -eq '.' -or $ProjectRoot -eq $existing -or $ProjectRoot.StartsWith($existing + '/', [StringComparison]::OrdinalIgnoreCase) -or $existing.StartsWith($ProjectRoot + '/', [StringComparison]::OrdinalIgnoreCase)) { throw 'Engineering project roots cannot overlap.' }
}
$definition = [pscustomobject][ordered]@{ root = $ProjectRoot; shared_paths = @($SharedPath) }
$current = $source.projects.PSObject.Properties[$ProjectId]
$changed = $null -eq $current -or -not (Test-EwiJsonEquivalent $current.Value $definition)
if ($null -eq $current) { $source.projects | Add-Member -NotePropertyName $ProjectId -NotePropertyValue $definition } else { $current.Value = $definition }
foreach ($id in $TargetId) {
    $target = $targets.targets.PSObject.Properties[$id]
    if ($null -eq $target -or $target.Value.source -ne $SourceId -or (Get-EwiProjectOwner $source $target.Value.path) -ne $ProjectId) { throw "Target does not belong to the selected engineering root: $id" }
    if ($null -eq $target.Value.PSObject.Properties['project_id']) { $target.Value | Add-Member -NotePropertyName project_id -NotePropertyValue $ProjectId; $changed = $true }
    elseif ($target.Value.project_id -ne $ProjectId) { $target.Value.project_id = $ProjectId; $changed = $true }
}
$fileHash = Get-EwiSha256 $path
$digest = Get-EwiTextSha256 (ConvertTo-EwiCanonicalJson ([ordered]@{ path_hash = $fileHash; source_head = $head; source = $SourceId; project = $ProjectId; definition = $definition; target_ids = @($TargetId | Sort-Object) }))
$report = [pscustomobject][ordered]@{ status = 'report-only'; changed = $changed; can_apply = $true; plan_digest = $digest; source_id = $SourceId; project_id = $ProjectId; definition = $definition }
if (-not $Apply -or -not $changed) { if (-not $changed) { $report.status = 'unchanged' }; $report | ConvertTo-Json -Depth 20; return }
if ($ExpectedPlanDigest -ne $digest) { throw 'Engineering project plan is stale; rerun the read-only plan.' }
Invoke-EwiLocked $root -TimeoutSeconds $MutexTimeoutSeconds -ScriptBlock {
    $null = Assert-EwiActiveWorkspace $root
    if ((Get-EwiSha256 $path) -ne $fileHash -or (Invoke-EwiGit $integration @('rev-parse', 'HEAD')).StdOut.Trim() -ne $head) { throw 'Engineering definition changed after planning.' }
    $before = [IO.File]::ReadAllBytes($path)
    try {
        Write-EwiJsonAtomic $path $targets -SchemaPath $schema
        $commit = New-EwiGitCommit $root -Message "chore: register engineering project $SourceId/$ProjectId" -RelativePaths @('workspace-management/config/targets.json')
        $report.status = 'configured'
        $report | Add-Member -NotePropertyName management_commit -NotePropertyValue $commit
        $report | ConvertTo-Json -Depth 20
    }
    catch { [IO.File]::WriteAllBytes($path, $before); $null = Invoke-EwiGit $root @('reset', '--', 'workspace-management/config/targets.json') -AllowFailure; throw }
}
