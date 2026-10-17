[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $WorkspaceRoot,
    [switch] $Apply,
    [string[]] $ImportSourceId = @(),
    [int] $MutexTimeoutSeconds = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/workspace-common.psm1') -Force

$context = Assert-EwiActiveWorkspace -WorkspaceRoot $WorkspaceRoot -AllowLegacyPolicy
$root = $context.root
$assets = Resolve-EwiPath (Join-Path $PSScriptRoot '../assets')
$references = Resolve-EwiPath (Join-Path $PSScriptRoot '../references')
$guideNames = @(
    'lifecycle-and-migration.md',
    'sources-targets-and-git.md',
    'workstreams-and-concurrency.md',
    'synchronization-and-recovery.md',
    'build-and-hardware.md',
    'references-and-project-knowledge.md',
    'configuration-schema.md'
)
$upgradeReasons = [Collections.Generic.List[string]]::new()
$validationErrors = [Collections.Generic.List[string]]::new()

if ($context.workspace.workspace_schema -ne 2 -or $context.workspace.policy_version -ne 2) {
    $upgradeReasons.Add("Unsupported current versions: schema=$($context.workspace.workspace_schema), policy=$($context.workspace.policy_version).")
}
if ((Test-Path -LiteralPath (Join-Path $root 'AGENTS.override.md')) -or (Test-Path -LiteralPath (Join-Path $root '.worktreeinclude'))) {
    $validationErrors.Add('A forbidden root override or .worktreeinclude exists.')
}

$canonical = [ordered]@{
    'work/README.md' = Join-Path $assets 'work-README.md'
    'AGENTS.md' = Join-Path $assets 'AGENTS.md'
    'README.md' = Join-Path $assets 'README.md'
    'USER_GUIDE.md' = Join-Path $assets 'USER_GUIDE.md'
    '.gitignore' = Join-Path $assets 'gitignore'
}
foreach ($guideName in $guideNames) {
    $canonical["workspace-management/guides/$guideName"] = Join-Path $references $guideName
}
foreach ($schema in Get-ChildItem -LiteralPath (Join-Path $assets 'schemas') -Filter '*.json' -File) {
    $canonical["workspace-management/schemas/$($schema.Name)"] = $schema.FullName
}
$canonical['workspace-management/tools/lib/project-copy-functions.ps1'] = Join-Path $PSScriptRoot 'lib/project-copy-functions.ps1'
$canonical['workspace-management/templates/workstream.json'] = Join-Path $assets 'workstream.json'
$canonical['workspace-management/templates/workstream-README.md'] = Join-Path $assets 'workstream-README.md'
$canonical['workspace-management/tools/lib/workspace-common.psm1'] = Join-Path $PSScriptRoot 'lib/workspace-common.psm1'
foreach ($name in @('plan-migration.ps1', 'detect-targets.ps1', 'import-reference.ps1', 'promote-reference.ps1', 'create-reference-copy.ps1', 'import-sources.ps1', 'add-source.ps1', 'migrate-source-mappings.ps1', 'set-user-git.ps1', 'set-source-project.ps1', 'manage-project-copy.ps1', 'new-workstream.ps1', 'update-workstream.ps1', 'pin-workstream-dependency.ps1', 'set-build-config.ps1', 'invoke-build.ps1', 'publish-workstream.ps1')) {
    $canonical["workspace-management/tools/$name"] = Join-Path $PSScriptRoot $name
}
foreach ($relative in $canonical.Keys) {
    $deployed = Join-Path $root $relative
    if (-not (Test-Path -LiteralPath $deployed -PathType Leaf)) {
        $upgradeReasons.Add("Missing managed file: $relative")
    }
    elseif ((Get-EwiSha256 $deployed) -ne (Get-EwiSha256 $canonical[$relative])) {
        $upgradeReasons.Add("Managed file differs from policy version 2: $relative")
    }
}

foreach ($pair in @(
    @('workspace-management/config/workspace.json', 'workspace-management/schemas/workspace.schema.json'),
    @('workspace-management/config/targets.json', 'workspace-management/schemas/targets.schema.json'),
    @('workspace-management/config/targets.local.json', 'workspace-management/schemas/targets-local.schema.json')
)) {
    try { $null = Read-EwiJson -Path (Join-Path $root $pair[0]) -SchemaPath (Join-Path $root $pair[1]) }
    catch { $validationErrors.Add($_.Exception.Message) }
}

$targetReportText = & (Join-Path $PSScriptRoot 'detect-targets.ps1') -WorkspaceRoot $root | Out-String
$targetReport = $targetReportText | ConvertFrom-Json -Depth 20
$sourceReports = [Collections.Generic.List[object]]::new()
foreach ($sourceId in $ImportSourceId) {
    $text = & (Join-Path $PSScriptRoot 'import-sources.ps1') -WorkspaceRoot $root -SourceId $sourceId | Out-String
    $sourceReports.Add(($text | ConvertFrom-Json -Depth 30))
}

if (-not $Apply) {
    [pscustomobject][ordered]@{
        status = 'report-only'
        workspace_root = $root
        upgrade_required = ($upgradeReasons.Count -gt 0)
        upgrade_reasons = @($upgradeReasons)
        validation_errors = @($validationErrors)
        target_report = $targetReport
        source_reports = @($sourceReports)
        changed = $false
    } | ConvertTo-Json -Depth 20
    return
}
if ($upgradeReasons.Count -gt 0 -or $validationErrors.Count -gt 0) {
    throw 'Refresh requires a read-only controlled-upgrade plan; no refresh changes were applied.'
}

$targetApplyText = & (Join-Path $PSScriptRoot 'detect-targets.ps1') -WorkspaceRoot $root -Apply -MutexTimeoutSeconds $MutexTimeoutSeconds | Out-String
$targetApply = $targetApplyText | ConvertFrom-Json -Depth 20
$sourceApply = [Collections.Generic.List[object]]::new()
foreach ($sourceReport in $sourceReports) {
    if (-not $sourceReport.can_apply -or @($sourceReport.changes).Count -eq 0) {
        $sourceApply.Add($sourceReport)
        continue
    }
    $text = & (Join-Path $PSScriptRoot 'import-sources.ps1') -WorkspaceRoot $root -SourceId $sourceReport.source_id -Apply -MutexTimeoutSeconds $MutexTimeoutSeconds | Out-String
    $sourceApply.Add(($text | ConvertFrom-Json -Depth 30))
}

[pscustomobject][ordered]@{
    status = 'refreshed'
    workspace_root = $root
    target_result = $targetApply
    source_results = @($sourceApply)
    changed = ($targetApply.changed -or @($sourceApply | Where-Object status -eq 'imported').Count -gt 0)
} | ConvertTo-Json -Depth 20
