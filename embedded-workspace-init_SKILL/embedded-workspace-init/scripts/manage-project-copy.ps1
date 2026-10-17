[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $WorkspaceRoot,
    [Parameter(Mandatory)] [string] $WorkstreamId,
    [Parameter(Mandatory)] [string] $SourceId,
    [Parameter(Mandatory)] [string[]] $ProjectId,
    [Parameter(Mandatory)] [ValidateSet('Mount', 'Release')] [string] $Action,
    [switch] $Apply,
    [string] $ExpectedPlanDigest,
    [int] $MutexTimeoutSeconds = 30
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/workspace-common.psm1') -Force
$root = (Assert-EwiActiveWorkspace $WorkspaceRoot).root
$schemaRoot = Join-Path $root 'workspace-management/schemas'
$manifestPath = Join-EwiContainedPath -Root $root -RelativePath "work/$WorkstreamId/workstream.json"
$targetsPath = Join-Path $root 'workspace-management/config/targets.json'

function Get-CopyPlan {
    $manifest = Read-EwiJson $manifestPath -SchemaPath (Join-Path $schemaRoot 'workstream.schema.json')
    if ($manifest.id -ne $WorkstreamId) { throw 'Workstream identity mismatch.' }
    $targets = Read-EwiJson $targetsPath -SchemaPath (Join-Path $schemaRoot 'targets.schema.json')
    $sourceProperty = $targets.sources.PSObject.Properties[$SourceId]
    $refProperty = $manifest.agent.refs.PSObject.Properties[$SourceId]
    if ($null -eq $sourceProperty -or $null -eq $refProperty) { throw 'Declare source scope before mounting engineering copies.' }
    $source = $sourceProperty.Value; $ref = $refProperty.Value
    Assert-EwiSourceCopyReady $root $SourceId
    $integration = Join-EwiContainedPath -Root $root -RelativePath $source.integration_path
    $worktree = Join-EwiContainedPath -Root $root -RelativePath $ref.worktree
    if ((Get-EwiPathIdentity $worktree -AllowMissing) -ne (Get-EwiPathIdentity (Join-Path $root "work/$WorkstreamId/sources/$SourceId") -AllowMissing)) { throw 'Engineering worktree path mismatch.' }
    $head = Get-EwiSourceRefHead $integration $ref
    $present = Test-Path -LiteralPath (Join-Path $worktree '.git') -PathType Leaf
    if ($present) {
        $owner = (Invoke-EwiGit $worktree @('rev-parse','--path-format=absolute','--git-common-dir')).StdOut.Trim()
        $expectedOwner = (Invoke-EwiGit $integration @('rev-parse','--path-format=absolute','--git-common-dir')).StdOut.Trim()
        if ((Get-EwiPathIdentity $owner) -ne (Get-EwiPathIdentity $expectedOwner)) { throw 'Engineering worktree belongs to a different source-private repository.' }
    }
    if ($present -and (Invoke-EwiGit $worktree @('rev-parse', 'HEAD')).StdOut.Trim() -ne $head) { throw 'Engineering worktree head mismatch.' }
    $before = (ConvertTo-EwiCanonicalJson $ref.projects) | ConvertFrom-Json -Depth 50
    $selected = (ConvertTo-EwiCanonicalJson $ref.projects) | ConvertFrom-Json -Depth 50
    $blockers = [Collections.Generic.List[string]]::new()
    $changed = $false
    $projectIds = @($ProjectId | Sort-Object -Unique)
    foreach ($id in $projectIds) {
        $definition = $source.projects.PSObject.Properties[$id]
        if ($null -eq $definition) { throw "Unknown engineering project: $SourceId/$id" }
        $record = $selected.PSObject.Properties[$id]
        if ($Action -eq 'Mount') {
            if ($manifest.status -eq 'abandoned') { $blockers.Add('Abandoned tasks cannot mount engineering copies.'); continue }
            foreach ($path in @($definition.Value.root) + @($definition.Value.shared_paths)) {
                $null = Join-EwiContainedPath $integration $path -AllowDot
                if ($path -ne '.' -and (Invoke-EwiGit $integration @('cat-file', '-e', "$($head):$path") -AllowFailure).ExitCode -ne 0) { $blockers.Add("Engineering path is missing at the task commit: $path") }
            }
            if ($null -ne $record -and $record.Value.state -eq 'mounted') {
                if ($record.Value.root -ne $definition.Value.root -or -not (Test-EwiJsonEquivalent @($record.Value.shared_paths) @($definition.Value.shared_paths))) { $blockers.Add("Release the old engineering definition before changing its paths: $id") }
                continue
            }
            $value = [pscustomobject][ordered]@{ root = $definition.Value.root; shared_paths = @($definition.Value.shared_paths); state = 'mounted'; frozen_commit = $head }
            if ($null -eq $record) { $selected | Add-Member -NotePropertyName $id -NotePropertyValue $value } else { $record.Value = $value }
            $changed = $true
        }
        elseif ($null -ne $record -and $record.Value.state -eq 'mounted') {
            $record.Value.state = 'released'; $record.Value.frozen_commit = $head; $changed = $true
        }
    }
    if ($Action -eq 'Release' -and $changed -and ($manifest.status -in @('paused', 'blocked') -or $manifest.has_unresolved_changes)) { $blockers.Add('Task is paused, blocked, or has unresolved changes; retain engineering copies.') }
    $status = ''
    $extras = @()
    $trackedFiles = @()
    if ($present) {
        $status = (Invoke-EwiGit $worktree @('status', '--porcelain=v1', '-z', '--untracked-files=all') -Environment @{GIT_OPTIONAL_LOCKS='0'}).StdOut
        $indexFiles = (Invoke-EwiGit $worktree @('ls-files', '-z')).StdOut.Split([char]0, [StringSplitOptions]::RemoveEmptyEntries)
        $trackedSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($path in $indexFiles) { $null = $trackedSet.Add($path) }
        $modified = (Invoke-EwiGit $worktree @('diff', '--name-only', '-z', 'HEAD', '--')).StdOut.Split([char]0, [StringSplitOptions]::RemoveEmptyEntries)
        $outputFiles = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $outputGlobs = @()
        foreach ($target in $targets.targets.PSObject.Properties | Where-Object { $_.Value.source -eq $SourceId }) {
            foreach ($build in $target.Value.builds.PSObject.Properties) {
                $metadata = $targets.field_metadata.PSObject.Properties["/targets/$($target.Name)/builds/$($build.Name)/output_paths"]
                if ($null -eq $metadata -or $metadata.Value.provenance -ne 'confirmed' -or $metadata.Value.freshness -ne 'current') { continue }
                foreach ($output in @($build.Value.output_paths)) {
                    $path = $(if ($target.Value.path -eq '.') { [string]$output } else { "$($target.Value.path)/$output" }).Replace('\','/')
                    if ($path -match '[*?\[]') { $outputGlobs += $path.Replace('**','*') } else { $null = $outputFiles.Add($path) }
                }
            }
        }
        $removing = @($before.PSObject.Properties | Where-Object { $_.Value.state -eq 'mounted' -and $selected.PSObject.Properties[$_.Name].Value.state -eq 'released' })
        foreach ($path in $modified) {
            $retain = Test-EwiPathMounted ([pscustomobject]@{checkout_state='sparse';projects=$selected}) $path
            if ($Action -eq 'Release' -and (-not $retain -or @($removing | Where-Object { $_.Value.root -eq '.' -or $path -eq $_.Value.root -or $path.StartsWith($_.Value.root + '/', [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0)) { $blockers.Add("Uncommitted engineering change: $path") }
        }
        foreach ($file in Get-ChildItem -LiteralPath $worktree -File -Recurse -Force) {
            if ($file.Name -eq '.git' -and $file.DirectoryName -eq $worktree) { continue }
            if ($file.Name -eq '.git') { $blockers.Add('Nested Git metadata blocks engineering copy changes.'); continue }
            if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { $blockers.Add('Linked files block engineering release.'); continue }
            $relative = [IO.Path]::GetRelativePath($worktree, $file.FullName).Replace('\', '/')
            $isTracked = $trackedSet.Contains($relative)
            $isOutput = $outputFiles.Contains($relative) -or @($outputGlobs | Where-Object { $relative -like $_ }).Count -gt 0
            $item = [pscustomobject][ordered]@{ path = $relative; size = [long]$file.Length; sha256 = Get-EwiSha256 $file.FullName; tracked = $isTracked }
            $trackedFiles += $item
            if ($Action -eq 'Release' -and (-not $isTracked -or $isOutput) -and -not (Test-EwiPathMounted ([pscustomobject]@{checkout_state='sparse';projects=$selected}) $relative)) { $extras += $item }
        }
        if (@(Get-ChildItem -LiteralPath $worktree -Directory -Recurse -Force | Where-Object { $_.Name -eq '.git' -or ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 }).Count -gt 0) { $blockers.Add('Linked directories or nested Git block engineering copy changes.') }
    }
    if ($Action -eq 'Release' -and $changed) {
        foreach ($txFile in Get-ChildItem -LiteralPath (Join-Path $root 'workspace-management/sync-state/transactions') -File -Filter '*.json') {
            $tx = Read-EwiJson $txFile.FullName
            if ($tx.state -notin @('completed','conflicted','rolled_back') -and $tx.workstream_id -eq $WorkstreamId) { $blockers.Add("Pending publish/recovery transaction: $($txFile.Name)") }
        }
        # Current command configuration may reference task tools which in turn reference an engineering path.
        foreach ($target in $targets.targets.PSObject.Properties) {
            foreach ($build in $target.Value.builds.PSObject.Properties) {
                foreach ($arg in @($build.Value.command.args)) {
                    $argumentText = [string]$arg
                    if (Test-Path -LiteralPath $arg -PathType Leaf) {
                        if ((Get-Item -LiteralPath $arg).Length -lt 1MB -and [IO.Path]::GetExtension($arg) -in @('.txt','.ps1','.json','.cmd','.bat')) { $argumentText += [IO.File]::ReadAllText($arg) }
                    }
                    $normalized = $argumentText.Replace('\','/').Replace('/tools/../','/')
                    foreach ($project in $before.PSObject.Properties | Where-Object { $_.Value.state -eq 'mounted' -and $selected.PSObject.Properties[$_.Name].Value.state -eq 'released' }) {
                        $projectPath = (Join-Path $worktree $project.Value.root).Replace('\','/').TrimEnd('/')
                        if ($normalized.IndexOf($projectPath, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $blockers.Add("Registered build still references engineering copy: $($target.Name)/$($build.Name)") }
                    }
                }
            }
        }
    }
    $payload = [ordered]@{ operation = $Action; workstream = $WorkstreamId; source = $SourceId; ids = $projectIds; manifest_hash = Get-EwiSha256 $manifestPath; targets_hash = Get-EwiSha256 $targetsPath; head = $head; present = $present; status = $status; files = @($trackedFiles); projects = $selected; blockers = @($blockers | Sort-Object -Unique) }
    return [pscustomobject]@{manifest=$manifest;ref=$ref;source=$source;integration=$integration;worktree=$worktree;head=$head;present=$present;before=$before;selected=$selected;extras=@($extras);payload=$payload;digest=Get-EwiTextSha256 (ConvertTo-EwiCanonicalJson $payload);changed=$changed;blockers=@($blockers | Sort-Object -Unique)}
}

$plan = Get-CopyPlan
$report = [pscustomobject][ordered]@{ status = 'report-only'; action = $Action; workstream_id = $WorkstreamId; source_id = $SourceId; projects = @($ProjectId); changed = $plan.changed; can_apply = ($plan.blockers.Count -eq 0); blockers = @($plan.blockers); plan_digest = $plan.digest; preserve_files = @($plan.extras); released_bytes = [long]0 }
if (-not $Apply -or -not $plan.changed) { if (-not $plan.changed) { $report.status = 'unchanged' }; $report | ConvertTo-Json -Depth 50; return }
if ($ExpectedPlanDigest -ne $plan.digest) { throw 'Engineering copy plan is stale; rerun the read-only plan.' }
if (-not $report.can_apply) { throw "Engineering copy operation is blocked: $($plan.blockers -join '; ')" }

Invoke-EwiLocked $root -TimeoutSeconds $MutexTimeoutSeconds -ScriptBlock {
    $locked = Get-CopyPlan
    if ($locked.digest -ne $ExpectedPlanDigest) { throw 'Engineering copy changed after planning.' }
    $original = [IO.File]::ReadAllBytes($manifestPath)
    $created = $false; $removed = $false; $branchCreated = $false; $oldCheckoutState = $locked.ref.checkout_state
    $removedExtras = @()
    $preservation = Join-Path $root "work/$WorkstreamId/artifacts/project-copy-preserved/$SourceId/$($locked.digest.Substring(0,16))"
    try {
        foreach ($extra in $locked.extras) {
            $from = Join-EwiContainedPath $locked.worktree $extra.path
            $null = New-Item -ItemType Directory -Path $preservation -Force
            $to = Join-EwiContainedPath $preservation $extra.path
            $null = New-Item -ItemType Directory -Path (Split-Path -Parent $to) -Force
            [IO.File]::Copy($from, $to, $true)
            if ((Get-EwiSha256 $to) -ne $extra.sha256 -or (Get-EwiSha256 $from) -ne $extra.sha256) { throw 'Engineering artifact changed while preserving it.' }
        }
        foreach ($extra in $locked.extras | Where-Object { -not $_.tracked }) { [IO.File]::Delete((Join-Path $locked.worktree $extra.path)); $removedExtras += $extra }
        if ($Action -eq 'Mount' -and -not $locked.present) {
            $null = New-Item -ItemType Directory -Path (Split-Path -Parent $locked.worktree) -Force
            $branchExists = (Invoke-EwiGit $locked.integration @('show-ref','--verify',"refs/heads/$($locked.ref.branch)") -AllowFailure).ExitCode -eq 0
            $args = @('worktree', 'add', '--no-checkout')
            if ($branchExists) { $args += @($locked.worktree, $locked.ref.branch) } else { $args += @('-b', $locked.ref.branch, $locked.worktree, $locked.head); $branchCreated = $true }
            $null = Invoke-EwiGit $locked.integration $args
            $created = $true
            Set-EwiProjectSelection $locked.worktree $locked.selected
            $null = Invoke-EwiGit $locked.worktree @('read-tree', '-mu', 'HEAD')
        }
        $mounted = @($locked.selected.PSObject.Properties | Where-Object { $_.Value.state -eq 'mounted' })
        if ($mounted.Count -gt 0) {
            Set-EwiProjectSelection $locked.worktree $locked.selected
            $locked.ref.checkout_state = 'sparse'
        }
        else {
            if ($locked.present) { $null = Invoke-EwiGit $locked.integration @('worktree', 'remove', $locked.worktree); $removed = $true }
            $locked.ref.checkout_state = 'released'
        }
        $locked.ref.projects = $locked.selected
        $locked.ref.head_commit = $locked.head
        $locked.manifest.updated_at = Get-EwiTimestamp
        Write-EwiJsonAtomic $manifestPath $locked.manifest -SchemaPath (Join-Path $schemaRoot 'workstream.schema.json')
        $remainingBytes = [long]0
        if (Test-Path -LiteralPath $locked.worktree) { foreach ($file in Get-ChildItem -LiteralPath $locked.worktree -Recurse -File -Force) { $remainingBytes += $file.Length } }
        $beforeBytes = [long]0; $extraBytes = [long]0
        foreach ($file in $locked.payload.files) { $beforeBytes += $file.size }
        foreach ($file in $locked.extras) { $extraBytes += $file.size }
        $report.released_bytes = [math]::Max(0, $beforeBytes - $remainingBytes - $extraBytes)
        $commit = New-EwiGitCommit $root -Message "chore: $($Action.ToLowerInvariant()) engineering copies for $WorkstreamId/$SourceId" -RelativePaths @("work/$WorkstreamId/workstream.json")
        $report.status = if ($Action -eq 'Mount') { 'mounted' } else { 'released' }
        $report | Add-Member -NotePropertyName management_commit -NotePropertyValue $commit
        $report | Add-Member -NotePropertyName preserved_at -NotePropertyValue $(if ($locked.extras.Count) { [IO.Path]::GetRelativePath($root,$preservation).Replace('\','/') } else { $null })
        $report | ConvertTo-Json -Depth 50
    }
    catch {
        $errorRecord = $_
        try {
            if ($created) { $null = Invoke-EwiGit $locked.integration @('worktree','remove',$locked.worktree) }
            elseif ($removed) { $null = Invoke-EwiGit $locked.integration @('worktree','add','--no-checkout',$locked.worktree,$locked.ref.branch) }
            if (-not $created -and ($locked.present -or $removed)) {
                if ($oldCheckoutState -eq 'legacy-full') { $null = Invoke-EwiGit $locked.worktree @('sparse-checkout','disable') }
                else { Set-EwiProjectSelection $locked.worktree $locked.before }
                if ($removed) { $null = Invoke-EwiGit $locked.worktree @('read-tree','-mu','HEAD') }
            }
            foreach ($extra in $removedExtras) {
                $to = Join-Path $locked.worktree $extra.path
                $null = New-Item -ItemType Directory -Path (Split-Path -Parent $to) -Force
                [IO.File]::Copy((Join-Path $preservation $extra.path), $to, $true)
                if ((Get-EwiSha256 $to) -ne $extra.sha256) { throw 'Artifact rollback verification failed.' }
            }
            if ($branchCreated) { $null = Invoke-EwiGit $locked.integration @('branch','-d',$locked.ref.branch) }
            [IO.File]::WriteAllBytes($manifestPath, $original)
            $null = Invoke-EwiGit $root @('reset','--',"work/$WorkstreamId/workstream.json")
        }
        catch {
            $locked.ref.checkout_state = 'recovery-required'
            Write-EwiJsonAtomic $manifestPath $locked.manifest -SchemaPath (Join-Path $schemaRoot 'workstream.schema.json')
            throw "Engineering copy recovery_required: $($_.Exception.Message); original failure: $($errorRecord.Exception.Message)"
        }
        throw $errorRecord
    }
}
