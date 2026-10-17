# Engineering checkout state is separate from source-group Git and synchronization identity.
function Get-EwiSourceRefHead {
    param([string] $Repository, $Ref)
    $branch = Invoke-EwiGit -Repository $Repository -ArgumentList @('rev-parse', '--verify', "refs/heads/$($Ref.branch)") -AllowFailure
    if ($branch.ExitCode -eq 0) { return $branch.StdOut.Trim() }
    if ($Ref.head_commit) { return [string]$Ref.head_commit }
    return [string]$Ref.task_base_commit
}

function Assert-EwiSourceCopyReady {
    param([string] $WorkspaceRoot, [string] $SourceId)
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $WorkspaceRoot 'work') -Filter 'workstream.json' -File -Recurse -Depth 2) {
        $manifest = Read-EwiJson $file.FullName
        $ref = $manifest.agent.refs.PSObject.Properties[$SourceId]
        if ($null -ne $ref -and $null -ne $ref.Value.PSObject.Properties['checkout_state'] -and $ref.Value.checkout_state -eq 'recovery-required') {
            throw "Engineering copy recovery_required blocks source '$SourceId': $($manifest.id)"
        }
    }
}

function New-EwiSourceRef {
    param([string] $WorkspaceRoot, $Source, [string] $WorkstreamId, [string] $SourceId)
    Assert-EwiSourceCopyReady -WorkspaceRoot $WorkspaceRoot -SourceId $SourceId
    $integration = Join-EwiContainedPath -Root $WorkspaceRoot -RelativePath ([string]$Source.integration_path)
    $head = (Invoke-EwiGit -Repository $integration -ArgumentList @('rev-parse', 'HEAD')).StdOut.Trim()
    $baseline = $null
    $state = Join-Path $WorkspaceRoot "workspace-management/sync-state/sources/$SourceId.json"
    if (Test-Path -LiteralPath $state) { $baseline = (Read-EwiJson $state).user_baseline_commit }
    return [pscustomobject][ordered]@{
        branch = "workstream/$WorkstreamId"; worktree = "work/$WorkstreamId/sources/$SourceId"
        mapping_revision = [int]$Source.mapping_revision; user_baseline_commit = $baseline
        task_base_commit = $head; head_commit = $null; checkout_state = 'none'; projects = [pscustomobject]@{}
    }
}

function Get-EwiProjectOwner {
    param($Source, [string] $RelativePath)
    $candidate = (Assert-EwiRelativePath $RelativePath -AllowDot).ToLowerInvariant()
    $matches = @($Source.projects.PSObject.Properties | Where-Object {
        $prefix = ([string]$_.Value.root).ToLowerInvariant().TrimEnd('/')
        $prefix -eq '.' -or $candidate -eq $prefix -or $candidate.StartsWith($prefix + '/')
    } | Sort-Object { $_.Value.root.Length } -Descending)
    if ($matches.Count -eq 0) { return $null }
    return $matches[0].Name
}

function Initialize-EwiProjectDefinitions {
    param($Targets, [string] $WorkspaceRoot)
    $changed = $false
    foreach ($sourceProperty in $Targets.sources.PSObject.Properties) {
        $source = $sourceProperty.Value
        if ($null -eq $source.PSObject.Properties['projects']) {
            $source | Add-Member -NotePropertyName projects -NotePropertyValue ([pscustomobject]@{})
            $changed = $true
        }
        $integration = Join-EwiContainedPath -Root $WorkspaceRoot -RelativePath ([string]$source.integration_path)
        $inventory = Get-EwiFileInventory -Root $integration
        if (-not $inventory.scan_complete) { throw "Incomplete engineering-boundary scan: $($sourceProperty.Name)" }
        $files = @($inventory.files)
        # A CubeMX .ioc identifies the complete engineering root, including Core/Drivers/IDE files.
        $roots = @($files | Where-Object { [IO.Path]::GetExtension($_.path) -eq '.ioc' } | ForEach-Object {
            $parent = [IO.Path]::GetDirectoryName($_.path).Replace('\', '/')
            if ($parent) { $parent } else { '.' }
        } | Sort-Object -Unique)
        if ($roots.Count -eq 0) {
            $roots = @($Targets.targets.PSObject.Properties | Where-Object { $_.Value.source -eq $sourceProperty.Name -and $_.Value.project.type -in @('make','cmake','platformio','esp-idf','zephyr') } | ForEach-Object { $_.Value.path } | Sort-Object Length, { $_ })
        }
        foreach ($projectRoot in $roots) {
            if ($null -ne (Get-EwiProjectOwner -Source $source -RelativePath $projectRoot)) { continue }
            if (@($source.projects.PSObject.Properties | Where-Object { $_.Value.root.StartsWith($projectRoot.TrimEnd('/') + '/', [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) { continue }
            $id = ConvertTo-EwiId -Value $(if ($projectRoot -eq '.') { $sourceProperty.Name } else { [IO.Path]::GetFileName($projectRoot) })
            $base = $id; $suffix = 2
            while ($null -ne $source.projects.PSObject.Properties[$id]) { $id = "$base-$suffix"; $suffix++ }
            $source.projects | Add-Member -NotePropertyName $id -NotePropertyValue ([pscustomobject][ordered]@{ root = $projectRoot; shared_paths = @() })
            $changed = $true
        }
        foreach ($targetProperty in $Targets.targets.PSObject.Properties | Where-Object { $_.Value.source -eq $sourceProperty.Name }) {
            $owner = Get-EwiProjectOwner -Source $source -RelativePath ([string]$targetProperty.Value.path)
            if ($null -eq $targetProperty.Value.PSObject.Properties['project_id']) {
                $targetProperty.Value | Add-Member -NotePropertyName project_id -NotePropertyValue $owner
                $changed = $true
            }
        }
    }
    return $changed
}

function ConvertTo-EwiWorkstreamV2 {
    param($Manifest, $Targets, [string] $WorkspaceRoot)
    $Manifest.schema = 2
    foreach ($sourceProperty in $Manifest.agent.refs.PSObject.Properties) {
        $ref = $sourceProperty.Value
        if ($null -ne $ref.PSObject.Properties['checkout_state']) { continue }
        $source = $Targets.sources.PSObject.Properties[$sourceProperty.Name].Value
        $integration = Join-EwiContainedPath -Root $WorkspaceRoot -RelativePath ([string]$source.integration_path)
        $head = Get-EwiSourceRefHead -Repository $integration -Ref $ref
        $present = Test-Path -LiteralPath (Join-Path $WorkspaceRoot $ref.worktree) -PathType Container
        $ref | Add-Member -NotePropertyName checkout_state -NotePropertyValue $(if ($present) { 'legacy-full' } else { 'released' })
        $projects = [ordered]@{}
        foreach ($project in $source.projects.PSObject.Properties) {
            $exists = $project.Value.root -eq '.' -or (Invoke-EwiGit -Repository $integration -ArgumentList @('cat-file', '-e', "$($head):$($project.Value.root)") -AllowFailure).ExitCode -eq 0
            if (-not $exists) { continue }
            $projects[$project.Name] = [pscustomobject][ordered]@{
                root = $project.Value.root; shared_paths = @($project.Value.shared_paths)
                state = if ($present) { 'mounted' } else { 'released' }; frozen_commit = $head
            }
        }
        $ref | Add-Member -NotePropertyName projects -NotePropertyValue ([pscustomobject]$projects)
        if (-not $present) { $ref.head_commit = $head }
    }
    return $Manifest
}

function Test-EwiPathMounted {
    param($Ref, [string] $Path)
    if ($Ref.checkout_state -eq 'legacy-full') { return $true }
    $candidate = $Path.Replace('\', '/').ToLowerInvariant()
    foreach ($project in $Ref.projects.PSObject.Properties | Where-Object { $_.Value.state -eq 'mounted' }) {
        foreach ($selected in @($project.Value.root) + @($project.Value.shared_paths)) {
            $prefix = ([string]$selected).ToLowerInvariant().TrimEnd('/')
            if ($prefix -eq '.' -or $candidate -eq $prefix -or $candidate.StartsWith($prefix + '/')) { return $true }
        }
    }
    return $false
}

function Set-EwiProjectSelection {
    param([string] $Repository, $Projects)
    $paths = @($Projects.PSObject.Properties | Where-Object { $_.Value.state -eq 'mounted' } | ForEach-Object { $_.Value.root; $_.Value.shared_paths } | Sort-Object -Unique)
    $head = (Invoke-EwiGit -Repository $Repository -ArgumentList @('rev-parse', 'HEAD')).StdOut.Trim()
    $patterns = foreach ($path in $paths) {
        if ($path -eq '.') { '/*'; continue }
        $type = (Invoke-EwiGit -Repository $Repository -ArgumentList @('cat-file', '-t', "$($head):$path")).StdOut.Trim()
        $escaped = $path.Replace('\', '/').Replace('[', '\[').Replace(']', '\]').Replace('*', '\*').Replace('?', '\?')
        '/' + $escaped + $(if ($type -eq 'tree') { '/' } else { '' })
    }
    if (@($patterns).Count -eq 0) { $patterns = @('!/*') }
    $result = Invoke-EwiGit -Repository $Repository -ArgumentList (@('sparse-checkout', 'set', '--no-cone', '--no-sparse-index', '--') + @($patterns))
    if ($result.StdErr -match '(?i)(not up to date|not uptodate|left despite|cannot.*(remove|update)|would be overwritten)') { throw "Sparse checkout could not apply safely: $($result.StdErr)" }
}

function Assert-EwiTargetMounted {
    param($Workstream, $Source, $Target)
    $ref = $Workstream.agent.refs.PSObject.Properties[[string]$Target.source]
    if ($null -eq $ref -or $ref.Value.checkout_state -in @('none', 'released', 'recovery-required')) { throw 'Engineering project is not mounted; use manage-project-copy.ps1 Mount before building.' }
    $owner = Get-EwiProjectOwner -Source $Source -RelativePath ([string]$Target.path)
    if ($null -eq $owner -or $null -eq $ref.Value.projects.PSObject.Properties[$owner] -or $ref.Value.projects.PSObject.Properties[$owner].Value.state -ne 'mounted') {
        throw "Engineering boundary is missing or not mounted for target '$($Target.path)'."
    }
}
