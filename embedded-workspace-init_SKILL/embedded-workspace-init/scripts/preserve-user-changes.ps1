[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $WorkspaceRoot,
    [string] $RepositoryRelative = '.',
    [Parameter(Mandatory)] [string[]] $RelativePaths,
    [string] $ExpectedPlanDigest,
    [switch] $Apply,
    [int] $MutexTimeoutSeconds = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/workspace-common.psm1') -Force
$context = Assert-EwiActiveWorkspace $WorkspaceRoot
$root = $context.root
$repositoryPath = Assert-EwiRelativePath $RepositoryRelative -AllowDot
$repository = Join-EwiContainedPath -Root $root -RelativePath $repositoryPath -AllowDot
$paths = @($RelativePaths | ForEach-Object { Assert-EwiRelativePath $_ } | Sort-Object -Unique)
if ($paths.Count -eq 0) { throw 'Explicit user-changed file paths are required.' }

function Get-ChangePlan {
    $current = Assert-EwiActiveWorkspace $root
    $allowed = $repositoryPath -eq '.'
    if (-not $allowed) {
        $targets = Read-EwiJson -Path (Join-Path $root 'workspace-management/config/targets.json') -SchemaPath (Join-Path $root 'workspace-management/schemas/targets.schema.json')
        foreach ($source in $targets.sources.PSObject.Properties) {
            if ($repositoryPath -eq $source.Value.integration_path) { $allowed = $true }
        }
        if ($repositoryPath -match '^work/([^/]+)/sources/([^/]+)$') {
            $workstreamPath = Join-Path $root "work/$($Matches[1])/workstream.json"
            $sourceId = $Matches[2]
            $workstream = Read-EwiJson -Path $workstreamPath -SchemaPath (Join-Path $root 'workspace-management/schemas/workstream.schema.json')
            if ($null -ne $workstream.agent.refs.PSObject.Properties[$sourceId]) { $allowed = $true }
        }
    }
    if (-not $allowed) { throw 'Repository is not registered Agent-managed content.' }
    if ((Get-EwiPathIdentity (Get-EwiGitRoot $repository)) -ne (Get-EwiPathIdentity $repository)) { throw 'Repository root mismatch.' }
    if ((Invoke-EwiGit $repository @('ls-files', '--unmerged')).StdOut) { throw 'Resolve the existing Git conflict before preservation.' }
    $head = (Invoke-EwiGit $repository @('rev-parse', 'HEAD')).StdOut.Trim()
    $branch = (Invoke-EwiGit $repository @('symbolic-ref', '-q', 'HEAD') -AllowFailure).StdOut.Trim()
    $records = @()
    foreach ($path in $paths) {
        $full = Join-EwiContainedPath -Root $repository -RelativePath $path
        $literal = ":(literal)$path"
        if ($repositoryPath -eq '.' -and $path -match '^(?:\.git(?:/|$)|sources/|reference-projects/[^/]+/project/|work/[^/]+/(?:sources|reference-copies)/|workspace-management/(?:sync-state|evidence|recovery|ide-workspaces)/)') { throw "Path belongs to another Git or runtime boundary: $path" }
        $baselineEntry = (Invoke-EwiGit $repository @('ls-tree', '-z', $head, '--', $literal)).StdOut
        $indexEntry = (Invoke-EwiGit $repository @('ls-files', '--stage', '-z', '--', $literal)).StdOut
        $tracked = [bool]$baselineEntry
        if (($baselineEntry -and $baselineEntry -notmatch '^100(?:644|755) blob ') -or ($indexEntry -and $indexEntry -notmatch '^100(?:644|755) [0-9a-f]+ 0\t')) { throw "Only regular Git files are supported: $path" }
        $exists = Test-Path -LiteralPath $full -PathType Leaf
        if ((Test-Path -LiteralPath $full) -and -not $exists) { throw "Only regular files are supported: $path" }
        if (-not $tracked -and -not $exists -and -not $indexEntry) { throw "User-changed path does not exist: $path" }
        if (-not $tracked -and -not $indexEntry -and (Invoke-EwiGit $repository @('check-ignore', '-q', '--', $path) -AllowFailure).ExitCode -eq 0) { throw "Ignored content requires separate recovery classification: $path" }
        $hash = $null
        if ($exists) {
            $item = Get-Item -LiteralPath $full -Force
            if ((Get-EwiSensitiveClassification $item) -ne 'none' -or (Test-EwiAmbiguousLicenseFile $item)) { throw "Sensitive or ambiguous file cannot enter preservation Git: $path" }
            $hash = Get-EwiSha256 $full
        }
        $changed = -not $tracked -or [bool](Invoke-EwiGit $repository @('diff', 'HEAD', '--name-only', '--', $literal)).StdOut -or
            [bool](Invoke-EwiGit $repository @('diff', '--cached', 'HEAD', '--name-only', '--', $literal)).StdOut
        if (-not $changed) { throw "Path has no saved user change: $path" }
        $records += [pscustomobject][ordered]@{ path = $path; tracked = $tracked; exists = $exists; sha256 = $hash; index_entry = $indexEntry }
    }
    return [pscustomobject][ordered]@{ repository = $repositoryPath; head = $head; branch = $branch; files = @($records) }
}

$plan = Get-ChangePlan
$digest = Get-EwiTextSha256 (ConvertTo-EwiCanonicalJson $plan)
if (-not $Apply) {
    [pscustomobject]@{ status = 'planned'; plan_digest = $digest; plan = $plan } | ConvertTo-Json -Depth 20
    return
}
if ($ExpectedPlanDigest -ne $digest) { throw 'User changes differ from the reviewed preservation plan.' }

$result = Invoke-EwiLocked -WorkspaceRoot $root -TimeoutSeconds $MutexTimeoutSeconds -ScriptBlock {
    $lockedPlan = Get-ChangePlan
    if ((Get-EwiTextSha256 (ConvertTo-EwiCanonicalJson $lockedPlan)) -ne $ExpectedPlanDigest) { throw 'User changes changed after lock acquisition.' }
    $id = New-EwiEvidenceId 'user-changes'
    $preservationRef = "refs/heads/preserved-user/$id"
    $gitDirectory = (Invoke-EwiGit $repository @('rev-parse', '--absolute-git-dir')).StdOut.Trim()
    $indexPath = Join-Path $gitDirectory "$id.index"
    $indexEnvironment = @{ GIT_INDEX_FILE = $indexPath }
    try {
        $null = Invoke-EwiGit $repository @('read-tree', $plan.head) -Environment $indexEnvironment
        foreach ($file in $plan.files) {
            if ($file.index_entry) {
                $entry = $file.index_entry -split ' ', 3
                $null = Invoke-EwiGit $repository @('update-index', '--add', '--cacheinfo', $entry[0], $entry[1], $file.path) -Environment $indexEnvironment
            }
            else { $null = Invoke-EwiGit $repository @('update-index', '--force-remove', '--', $file.path) -Environment $indexEnvironment }
        }
        $indexTree = (Invoke-EwiGit $repository @('write-tree') -Environment $indexEnvironment).StdOut.Trim()
        $indexCommit = (Invoke-EwiGit $repository @('-c', 'user.name=Embedded Workspace Agent', '-c', 'user.email=embedded-workspace-init@local.invalid', 'commit-tree', $indexTree, '-p', $plan.head, '-m', "Preserve selected staging state: $id")).StdOut.Trim()
        foreach ($file in $plan.files) {
            $path = [string]$file.path
            if ($file.exists) {
                $full = Join-EwiContainedPath -Root $repository -RelativePath $path
                if ((Get-EwiSha256 $full) -ne $file.sha256) { throw "File changed before capture: $path" }
                $blob = (Invoke-EwiGit $repository @('hash-object', '-w', '--no-filters', '--', $full)).StdOut.Trim()
                $mode = if ($file.index_entry) { ($file.index_entry -split ' ', 3)[0] } else { '100644' }
                $null = Invoke-EwiGit $repository @('update-index', '--add', '--cacheinfo', $mode, $blob, $path) -Environment $indexEnvironment
                if ((Get-EwiSha256 $full) -ne $file.sha256) { throw "File changed during capture: $path" }
            }
            else { $null = Invoke-EwiGit $repository @('update-index', '--force-remove', '--', $path) -Environment $indexEnvironment }
        }
        $tree = (Invoke-EwiGit $repository @('write-tree') -Environment $indexEnvironment).StdOut.Trim()
        $commit = (Invoke-EwiGit $repository @('-c', 'user.name=Embedded Workspace Agent', '-c', 'user.email=embedded-workspace-init@local.invalid', 'commit-tree', $tree, '-p', $indexCommit, '-m', "Preserve direct user edits: $id")).StdOut.Trim()
        $null = Invoke-EwiGit $repository @('update-ref', $preservationRef, $commit, ('0' * 40))
        foreach ($file in $plan.files) {
            if ($file.exists) {
                $full = Join-EwiContainedPath -Root $repository -RelativePath $file.path
                $blob = (Invoke-EwiGit $repository @('hash-object', '--no-filters', '--', $full)).StdOut.Trim()
                $savedBlob = (Invoke-EwiGit $repository @('rev-parse', "$commit`:$($file.path)")).StdOut.Trim()
                if ($blob -ne $savedBlob) { throw "Preservation verification failed: $($file.path)" }
            }
        }
        if ((Get-EwiTextSha256 (ConvertTo-EwiCanonicalJson (Get-ChangePlan))) -ne $ExpectedPlanDigest) { throw "Files changed before restore; preserved branch: $preservationRef" }
        foreach ($file in $plan.files) {
            $full = Join-EwiContainedPath -Root $repository -RelativePath $file.path
            $currentHash = if (Test-Path -LiteralPath $full -PathType Leaf) { Get-EwiSha256 $full } else { $null }
            if ($currentHash -ne $file.sha256) { throw "File changed before restore; preserved branch: $preservationRef" }
            if ($file.tracked) { $null = Invoke-EwiGit $repository @('restore', "--source=$($plan.head)", '--staged', '--worktree', '--', ":(literal)$($file.path)") }
            else {
                $null = Invoke-EwiGit $repository @('update-index', '--force-remove', '--', $file.path)
                if ($file.exists) { [IO.File]::Delete($full) }
            }
        }
        if ((Invoke-EwiGit $repository (@('diff', 'HEAD', '--name-only', '--') + @($paths | ForEach-Object { ":(literal)$_" }))).StdOut) { throw "Restore verification failed; preserved branch: $preservationRef" }
        if ((Invoke-EwiGit $repository @('rev-parse', 'HEAD')).StdOut.Trim() -ne $plan.head) { throw 'Agent HEAD changed during preservation.' }
        $details = [pscustomobject][ordered]@{ repository = $repositoryPath; preserved_branch = $preservationRef; preserved_commit = $commit; preserved_index_commit = $indexCommit; restored_to = $plan.head; paths = $paths }
        $evidence = Write-EwiEvidence -WorkspaceRoot $root -EvidenceId $id -Kind recovery -Subject ([pscustomobject]@{ workspace = $root }) -Result ([pscustomobject]@{ status = 'passed'; summary = 'Direct internal user edits preserved before restoring the Agent baseline.'; details = $details })
        return [pscustomobject]@{ status = 'restored'; details = $details; evidence = [IO.Path]::GetRelativePath($root, $evidence).Replace('\', '/') }
    }
    finally { if (Test-Path -LiteralPath $indexPath) { [IO.File]::Delete($indexPath) } }
}
$result | ConvertTo-Json -Depth 20
