# Synthetic compatibility fixtures explicitly request engineering copies before editing.
function Mount-FixtureProjectCopies {
    param([string] $WorkspaceRoot, $Workstream)
    if ($Workstream.status -ne 'created') { return }
    $manifest = Get-Content -Raw -LiteralPath (Join-Path $WorkspaceRoot "$($Workstream.path)/workstream.json") | ConvertFrom-Json -Depth 50
    foreach ($sourceProperty in $manifest.agent.refs.PSObject.Properties) {
        $targets = Get-Content -Raw -LiteralPath (Join-Path $WorkspaceRoot 'workspace-management/config/targets.json') | ConvertFrom-Json -Depth 50
        $source = $targets.sources.PSObject.Properties[$sourceProperty.Name].Value
        if (@($source.projects.PSObject.Properties).Count -eq 0) {
            $arguments = @{ WorkspaceRoot=$WorkspaceRoot;SourceId=$sourceProperty.Name;ProjectId='fixture-project';ProjectRoot='.' }
            $definition = & (Join-Path $PSScriptRoot 'set-source-project.ps1') @arguments | ConvertFrom-Json -Depth 30
            $null = & (Join-Path $PSScriptRoot 'set-source-project.ps1') @arguments -Apply -ExpectedPlanDigest $definition.plan_digest
            $ids = @('fixture-project')
        } else { $ids = @($source.projects.PSObject.Properties.Name) }
        $arguments = @{WorkspaceRoot=$WorkspaceRoot;WorkstreamId=$Workstream.workstream_id;SourceId=$sourceProperty.Name;ProjectId=$ids;Action='Mount'}
        $plan = & (Join-Path $PSScriptRoot 'manage-project-copy.ps1') @arguments | ConvertFrom-Json -Depth 50
        $null = & (Join-Path $PSScriptRoot 'manage-project-copy.ps1') @arguments -Apply -ExpectedPlanDigest $plan.plan_digest
    }
}
