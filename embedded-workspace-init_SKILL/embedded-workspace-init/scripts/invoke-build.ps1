[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $WorkspaceRoot,
    [Parameter(Mandatory)] [ValidatePattern('^[a-z0-9][a-z0-9-]{0,63}$')] [string] $TargetId,
    [Parameter(Mandatory)] [ValidatePattern('^[a-z0-9][a-z0-9-]{0,63}$')] [string] $BuildId,
    [ValidateSet('agent-copy', 'user-authority')] [string] $BuildContext = 'agent-copy',
    [string] $WorkstreamId,
    [string] $PublishId,
    [switch] $AllowCandidate,
    [int] $MutexTimeoutSeconds = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/workspace-common.psm1') -Force

$context = Assert-EwiActiveWorkspace -WorkspaceRoot $WorkspaceRoot
$root = $context.root
$targetsPath = Join-Path $root 'workspace-management/config/targets.json'
$localPath = Join-Path $root 'workspace-management/config/targets.local.json'
$targetsSchema = Join-Path $root 'workspace-management/schemas/targets.schema.json'
$targets = Read-EwiJson -Path $targetsPath -SchemaPath $targetsSchema
$local = Read-EwiJson -Path $localPath -SchemaPath (Join-Path $root 'workspace-management/schemas/targets-local.schema.json')
$targetProperty = $targets.targets.PSObject.Properties[$TargetId]
if ($null -eq $targetProperty) { throw "Unknown target: $TargetId" }
$target = $targetProperty.Value
$buildProperty = $target.builds.PSObject.Properties[$BuildId]
if ($null -eq $buildProperty) { throw "Unknown build id '$BuildId' for target '$TargetId'." }
$build = $buildProperty.Value
if ($build.command_state -in @('unavailable', 'unconfirmed', 'stale')) {
    throw "Build command state does not permit execution: $($build.command_state)"
}
if ($build.command_state -eq 'candidate' -and -not $AllowCandidate) {
    throw 'Candidate command requires explicit -AllowCandidate after hook and write-boundary review.'
}
$toolProperty = $local.tools.PSObject.Properties[[string]$build.command.tool]
if ($null -eq $toolProperty) { throw "Tool id is not locally registered: $($build.command.tool)" }
$executable = Resolve-EwiPath ([string]$toolProperty.Value.executable)
$toolVersionProperty = $toolProperty.Value.PSObject.Properties['version']
$toolVersion = if ($null -eq $toolVersionProperty) { $null } else { $toolVersionProperty.Value }
if ($build.command_state -ne 'unavailable' -and [string]::IsNullOrWhiteSpace([string]$toolVersion)) { throw "Runnable tool '$($build.command.tool)' requires a recorded version." }
$hardwareExecutables = @('dfu-util', 'jlink', 'jlinkexe', 'jlinkcommander', 'openocd', 'pyocd', 'st-flash', 'stm32programmer-cli')
$executableName = [IO.Path]::GetFileNameWithoutExtension($executable).ToLowerInvariant()
$hardwareActions = @('burn', 'erase', 'efuse', 'flash', 'lock', 'otp', 'program', 'protect', 'upload')
$requestedHardwareActions = @($build.command.args | ForEach-Object { ([string]$_).Trim().TrimStart('-').ToLowerInvariant() } | Where-Object { $_ -in $hardwareActions })
if ($executableName -in $hardwareExecutables -or $requestedHardwareActions.Count -gt 0) {
    throw 'Registered build commands cannot execute flash, erase, program, protection, or other hardware actions.'
}

function Resolve-UserTargetRoot {
    param($Target, $Source, $LocalSource)

    $targetPath = (Assert-EwiRelativePath -Path ([string]$Target.path) -AllowDot).Replace('\', '/')
    $matches = [Collections.Generic.List[string]]::new()
    foreach ($mapping in @($Source.mappings)) {
        $subpath = ([string]$mapping.integration_subpath).Replace('\', '/').TrimEnd('/')
        $relative = $null
        if ($subpath -eq '.') { $relative = $targetPath }
        elseif ($targetPath -eq $subpath) { $relative = '.' }
        elseif ($targetPath.StartsWith($subpath + '/', [StringComparison]::OrdinalIgnoreCase)) { $relative = $targetPath.Substring($subpath.Length + 1) }
        if ($null -ne $relative) {
            $localMapping = $LocalSource.mappings.PSObject.Properties[[string]$mapping.mapping_id]
            if ($null -eq $localMapping) { throw "Missing local mapping: $($mapping.mapping_id)" }
            $matches.Add((Join-EwiContainedPath -Root ([string]$localMapping.Value.source_path) -RelativePath $relative -AllowDot))
        }
    }
    if ($matches.Count -ne 1) { throw "Target '$TargetId' does not resolve to exactly one authority mapping." }
    return $matches[0]
}

function Resolve-ManifestAuthorityFile {
    param($TargetsObject, $LocalObject, $ManifestItem)
    $manifestSource = $TargetsObject.sources.PSObject.Properties[[string]$ManifestItem.source_id]
    $manifestLocalSource = $LocalObject.sources.PSObject.Properties[[string]$ManifestItem.source_id]
    if ($null -eq $manifestSource -or $null -eq $manifestLocalSource) { throw "Publish manifest source is no longer configured: $($ManifestItem.source_id)" }
    $mapping = @($manifestSource.Value.mappings | Where-Object mapping_id -eq $ManifestItem.mapping_id)
    if ($mapping.Count -ne 1) { throw "Publish manifest mapping is no longer unique: $($ManifestItem.mapping_id)" }
    $localMapping = $manifestLocalSource.Value.mappings.PSObject.Properties[[string]$ManifestItem.mapping_id]
    if ($null -eq $localMapping) { throw "Publish manifest local mapping is missing: $($ManifestItem.mapping_id)" }
    return Join-EwiContainedPath -Root ([string]$localMapping.Value.source_path) -RelativePath ([string]$ManifestItem.relative_path) -AllowDot
}

$source = $targets.sources.PSObject.Properties[[string]$target.source].Value
if ($BuildContext -eq 'agent-copy') {
    if ([string]::IsNullOrWhiteSpace($WorkstreamId)) { throw 'agent-copy build requires -WorkstreamId.' }
    $workstreamPath = Join-Path $root "work/$WorkstreamId/workstream.json"
    $workstream = Read-EwiJson -Path $workstreamPath -SchemaPath (Join-Path $root 'workspace-management/schemas/workstream.schema.json')
    Assert-EwiSourceCopyReady $root ([string]$target.source)
    Assert-EwiTargetMounted $workstream $source $target
    foreach ($argument in @($build.command.args)) {
        $argumentText = [string]$argument
        if ((Test-Path -LiteralPath $argument -PathType Leaf) -and [IO.Path]::GetExtension($argument) -in @('.txt','.ps1','.json','.cmd','.bat') -and (Get-Item -LiteralPath $argument).Length -lt 1MB) { $argumentText += [IO.File]::ReadAllText($argument) }
        $normalized = $argumentText.Replace('\','/').Replace('/tools/../','/')
        foreach ($match in [regex]::Matches($normalized, '(?i)/work/(\d{8}-[a-z0-9-]+-[a-f0-9]{4})/')) {
            if ($match.Groups[1].Value -ne $WorkstreamId) { throw 'Build command references another task; configure a command for the selected engineering copy.' }
        }
    }
    $sourceRef = $workstream.agent.refs.PSObject.Properties[[string]$target.source]
    if ($null -eq $sourceRef) { throw "Workstream does not mount source '$($target.source)'." }
    $sourceRoot = Join-EwiContainedPath -Root $root -RelativePath ([string]$sourceRef.Value.worktree)
    $targetRoot = Join-EwiContainedPath -Root $sourceRoot -RelativePath ([string]$target.path) -AllowDot
}
else {
    if ([string]::IsNullOrWhiteSpace($PublishId)) { throw 'user-authority build requires a frozen -PublishId.' }
    $transactionPath = Join-Path $root "workspace-management/sync-state/transactions/$PublishId.json"
    $transaction = Read-EwiJson -Path $transactionPath -SchemaPath (Join-Path $root 'workspace-management/schemas/publish-transaction.schema.json')
    if ($transaction.state -notin @('file_verified', 'verification_failed', 'side_effect_review_required')) {
        throw "User-authority build requires a file-verified publish transaction; current state is '$($transaction.state)'."
    }
    if ($null -eq $transaction.head_commits.PSObject.Properties[[string]$target.source]) {
        throw "Publish transaction does not contain target source '$($target.source)'."
    }
    foreach ($manifestItem in @($transaction.manifest)) {
        $manifestFile = Resolve-ManifestAuthorityFile -TargetsObject $targets -LocalObject $local -ManifestItem $manifestItem
        $manifestHash = if (Test-Path -LiteralPath $manifestFile -PathType Leaf) { Get-EwiSha256 $manifestFile } else { $null }
        if ($manifestHash -ne $manifestItem.expected_hash) {
            throw "User file changed after publish verification: $($manifestItem.source_id)/$($manifestItem.mapping_id)/$($manifestItem.relative_path)"
        }
    }
    $transactionHash = Get-EwiSha256 $transactionPath
    $localSource = $local.sources.PSObject.Properties[[string]$target.source]
    if ($null -eq $localSource) { throw "Source has no local authority mapping: $($target.source)" }
    $targetRoot = Resolve-UserTargetRoot -Target $target -Source $source -LocalSource $localSource.Value
    $WorkstreamId = $transaction.workstream_id
}

$cwd = Join-EwiContainedPath -Root $targetRoot -RelativePath ([string]$build.cwd) -AllowDot
foreach ($declaredPath in @($build.output_paths) + @($build.generated_write_paths) + @($build.outputs)) {
    $literalPrefix = ([string]$declaredPath -split '[*?\[]', 2)[0].TrimEnd([char[]]@('/', '\'))
    if ($literalPrefix) { $null = Join-EwiContainedPath -Root $targetRoot -RelativePath $literalPrefix -AllowDot }
}

function Get-ProjectFactHash {
    param([AllowNull()] [string] $RelativePath)
    if ([string]::IsNullOrWhiteSpace($RelativePath)) { return $null }
    $file = Join-EwiContainedPath -Root $targetRoot -RelativePath $RelativePath
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return $null }
    return Get-EwiSha256 $file
}

$toolItem = Get-Item -LiteralPath $executable -ErrorAction Stop
$configurationFacts = [pscustomobject][ordered]@{
    target_id = $TargetId
    source_id = [string]$target.source
    target_path = [string]$target.path
    project_type = [string]$target.project.type
    project_entry = [string]$target.project.entry
    project_entry_hash = Get-ProjectFactHash ([string]$target.project.entry)
    generator = $target.project.generator
    generator_hash = Get-ProjectFactHash $target.project.generator
    build_id = $BuildId
    configuration = [string]$build.configuration
    cwd = [string]$build.cwd
    command = $build.command
    output_paths = @($build.output_paths)
    generated_write_paths = @($build.generated_write_paths)
    outputs = @($build.outputs)
    tool_id = [string]$build.command.tool
    tool_path = $executable
    tool_version = $toolVersion
    tool_size = [int64]$toolItem.Length
    tool_mtime_utc = $toolItem.LastWriteTimeUtc.ToString('o')
}
$configurationDigest = Get-EwiTextSha256 (ConvertTo-EwiCanonicalJson $configurationFacts)
$metadataPointer = "/targets/$TargetId/builds/$BuildId/command"
$metadataProperty = $targets.field_metadata.PSObject.Properties[$metadataPointer]
function Set-CurrentBuildStale {
    $original = [IO.File]::ReadAllBytes($targetsPath)
    try {
        $null = Invoke-EwiLocked -WorkspaceRoot $root -TimeoutSeconds $MutexTimeoutSeconds -ScriptBlock {
            $currentTargets = Read-EwiJson -Path $targetsPath -SchemaPath $targetsSchema
            $currentBuild = $currentTargets.targets.PSObject.Properties[$TargetId].Value.builds.PSObject.Properties[$BuildId].Value
            $currentMetadata = $currentTargets.field_metadata.PSObject.Properties[$metadataPointer]
            $currentBuild.command_state = 'stale'
            if ($null -eq $currentMetadata) {
                $currentTargets.field_metadata | Add-Member -NotePropertyName $metadataPointer -NotePropertyValue ([pscustomobject][ordered]@{ provenance = 'imported'; verification = 'failed'; freshness = 'stale' })
            }
            else { $currentMetadata.Value.freshness = 'stale' }
            Write-EwiJsonAtomic -Path $targetsPath -Value $currentTargets -SchemaPath $targetsSchema
            $null = New-EwiGitCommit -Repository $root -Message "chore: mark stale build $TargetId/$BuildId" -RelativePaths @('workspace-management/config/targets.json')
        }
    }
    catch {
        [IO.File]::WriteAllBytes($targetsPath, $original)
        $null = Invoke-EwiGit -Repository $root -ArgumentList @('reset', '--', 'workspace-management/config/targets.json') -AllowFailure
        throw
    }
}
if ($build.command_state -eq 'verified') {
    $metadataVerification = if ($null -eq $metadataProperty -or $null -eq $metadataProperty.Value.PSObject.Properties['verification']) { $null } else { $metadataProperty.Value.verification }
    $metadataEvidenceRef = if ($null -eq $metadataProperty -or $null -eq $metadataProperty.Value.PSObject.Properties['evidence_ref']) { $null } else { $metadataProperty.Value.evidence_ref }
    $trustFailure = $null -eq $metadataProperty -or $metadataVerification -ne 'verified' -or $metadataProperty.Value.freshness -ne 'current' -or -not $metadataEvidenceRef
    $priorEvidence = $null
    if (-not $trustFailure) {
        $priorEvidencePath = Join-EwiContainedPath -Root $root -RelativePath ([string]$metadataEvidenceRef)
        if (-not (Test-Path -LiteralPath $priorEvidencePath -PathType Leaf)) { $trustFailure = $true }
        else {
            $priorEvidence = Read-EwiJson -Path $priorEvidencePath -SchemaPath (Join-Path $root 'workspace-management/schemas/evidence.schema.json')
            if ($priorEvidence.kind -ne 'build' -or $priorEvidence.subject.target_id -ne $TargetId -or $priorEvidence.subject.build_id -ne $BuildId -or $priorEvidence.result.status -ne 'passed') { $trustFailure = $true }
        }
    }
    $priorDigestProperty = if ($null -ne $priorEvidence -and $priorEvidence.result.details) { $priorEvidence.result.details.PSObject.Properties['configuration_digest'] } else { $null }
    if ($trustFailure -or $null -eq $priorDigestProperty -or $priorDigestProperty.Value -ne $configurationDigest) {
        Set-CurrentBuildStale
        throw "Build configuration is stale for '$TargetId/$BuildId'; review and reconfirm it before execution."
    }
}
foreach ($field in @('output_paths', 'generated_write_paths')) {
    if (@($build.$field).Count -eq 0) { continue }
    $pathMetadata = $targets.field_metadata.PSObject.Properties["/targets/$TargetId/builds/$BuildId/$field"]
    if ($null -eq $pathMetadata -or $pathMetadata.Value.provenance -ne 'confirmed' -or $pathMetadata.Value.freshness -ne 'current') {
        throw "Build path classification '$field' is not confirmed and current for '$TargetId/$BuildId'."
    }
}

$before = Get-EwiFileInventory -Root $targetRoot -MappingId $TargetId -IncludeBuildDirectories
$targetsHash = Get-EwiSha256 $targetsPath
$localHash = Get-EwiSha256 $localPath

function Inventory-ByPath {
    param($Inventory)
    $map = [ordered]@{}
    foreach ($entry in @($Inventory.files)) { $map[([string]$entry.path).ToLowerInvariant()] = $entry }
    return $map
}

function Test-DeclaredPath {
    param([string] $Path, [object[]] $Patterns)
    foreach ($pattern in $Patterns) {
        $normalized = ([string]$pattern).Replace('\', '/').Replace('**', '*')
        if ($Path -like $normalized -or $Path.StartsWith($normalized.TrimEnd([char[]]@('*', '/')) + '/', [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Get-DeclaredPathPrefix {
    param([Parameter(Mandatory)] [string] $Path)

    $normalized = (Assert-EwiRelativePath -Path $Path -AllowDot).Replace('\', '/')
    $prefix = ($normalized -split '[*?\[]', 2)[0].TrimEnd('/')
    if ([string]::IsNullOrWhiteSpace($prefix)) { return '.' }
    return $prefix
}

function Test-DeclaredPathOverlap {
    param([Parameter(Mandatory)] [string] $First, [Parameter(Mandatory)] [string] $Second)

    $a = Get-DeclaredPathPrefix $First
    $b = Get-DeclaredPathPrefix $Second
    return $a -eq '.' -or $b -eq '.' -or $a -eq $b -or
        $a.StartsWith($b.TrimEnd('/') + '/', [StringComparison]::OrdinalIgnoreCase) -or
        $b.StartsWith($a.TrimEnd('/') + '/', [StringComparison]::OrdinalIgnoreCase)
}

foreach ($pathSet in @(
    [pscustomobject]@{ name = 'output_paths'; values = @($build.output_paths) },
    [pscustomobject]@{ name = 'generated_write_paths'; values = @($build.generated_write_paths) },
    [pscustomobject]@{ name = 'outputs'; values = @($build.outputs) }
)) {
    $seen = @{}
    foreach ($declaredPath in @($pathSet.values)) {
        $normalized = (Assert-EwiRelativePath -Path ([string]$declaredPath) -AllowDot).Replace('\', '/').ToLowerInvariant()
        if ($seen.ContainsKey($normalized)) { throw "Build $($pathSet.name) contains a duplicate path: $declaredPath" }
        $seen[$normalized] = $true
    }
}

foreach ($outputPath in @($build.output_paths)) {
    foreach ($generatedPath in @($build.generated_write_paths)) {
        if (Test-DeclaredPathOverlap -First ([string]$outputPath) -Second ([string]$generatedPath)) {
            throw "Build output path '$outputPath' overlaps generated-write path '$generatedPath'."
        }
    }
}
$builtCommit = if ($BuildContext -eq 'agent-copy') {
    (Invoke-EwiGit -Repository $sourceRoot -ArgumentList @('rev-parse', 'HEAD')).StdOut.Trim()
}
else {
    [string]$transaction.head_commits.PSObject.Properties[[string]$target.source].Value
}
if ($BuildContext -eq 'user-authority') {
    $allTargetOutputPaths = @($target.builds.PSObject.Properties | ForEach-Object {
        $metadata = $targets.field_metadata.PSObject.Properties["/targets/$TargetId/builds/$($_.Name)/output_paths"]
        if ($null -ne $metadata -and $metadata.Value.provenance -eq 'confirmed' -and $metadata.Value.freshness -eq 'current') { @($_.Value.output_paths) }
    })
    $transactionHash = Invoke-EwiLocked -WorkspaceRoot $root -TimeoutSeconds $MutexTimeoutSeconds -ScriptBlock {
        $currentTransaction = Read-EwiJson -Path $transactionPath -SchemaPath (Join-Path $root 'workspace-management/schemas/publish-transaction.schema.json')
        if ((Get-EwiSha256 $transactionPath) -ne $transactionHash) {
            throw 'Publish transaction changed before the user-authority build snapshot.'
        }
        $snapshotRoot = Join-EwiContainedPath -Root $root -RelativePath "$($currentTransaction.recovery_path)/pre-build/$TargetId"
        $manifestPath = Join-Path $snapshotRoot 'manifest.jsonl'
        if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
            $null = New-Item -ItemType Directory -Path (Join-Path $snapshotRoot 'files') -Force
            $snapshotEntries = [Collections.Generic.List[object]]::new()
            foreach ($entry in @($before.files)) {
                if (Test-DeclaredPath -Path ([string]$entry.path) -Patterns $allTargetOutputPaths) { continue }
                $sourceFile = Join-EwiContainedPath -Root $targetRoot -RelativePath ([string]$entry.path)
                $snapshotFile = Join-EwiContainedPath -Root (Join-Path $snapshotRoot 'files') -RelativePath ([string]$entry.path)
                $parent = Split-Path -Parent $snapshotFile
                if (-not (Test-Path -LiteralPath $parent)) { $null = New-Item -ItemType Directory -Path $parent }
                [IO.File]::Copy($sourceFile, $snapshotFile, $false)
                if ((Get-EwiSha256 $snapshotFile) -ne $entry.sha256) { throw "Pre-build snapshot hash mismatch: $($entry.path)" }
                $snapshotEntries.Add([pscustomobject][ordered]@{
                    path = [string]$entry.path
                    type = 'file'
                    size = [int64]$entry.size
                    sha256 = [string]$entry.sha256
                })
            }
            Write-EwiJsonLinesAtomic -Path $manifestPath -Records @($snapshotEntries) -SchemaPath (Join-Path $root 'workspace-management/schemas/recovery-file-record.schema.json')
        }
        $currentTransaction.build_target_id = $TargetId
        $currentTransaction.build_id = $BuildId
        $currentTransaction.build_status = 'not-run'
        $currentTransaction.updated_at = Get-EwiTimestamp
        $currentTransaction.message = 'Pre-build snapshot verified; user-authority build is running.'
        Write-EwiJsonAtomic -Path $transactionPath -Value $currentTransaction -SchemaPath (Join-Path $root 'workspace-management/schemas/publish-transaction.schema.json')
        return Get-EwiSha256 $transactionPath
    }
}

$startedAt = Get-EwiTimestamp
$processResult = Invoke-EwiProcess -Executable $executable -ArgumentList @($build.command.args) -WorkingDirectory $cwd -AllowFailure
$finishedAt = Get-EwiTimestamp
$after = Get-EwiFileInventory -Root $targetRoot -MappingId $TargetId -IncludeBuildDirectories
if (-not $after.scan_complete) { throw 'Build completed but the post-build file scan is incomplete.' }

$beforeMap = Inventory-ByPath $before
$afterMap = Inventory-ByPath $after
$changes = [Collections.Generic.List[object]]::new()
$allPaths = @($beforeMap.Keys + $afterMap.Keys | Sort-Object -Unique)
foreach ($pathKey in $allPaths) {
    $oldHash = if ($beforeMap.Contains($pathKey)) { $beforeMap[$pathKey].sha256 } else { $null }
    $newHash = if ($afterMap.Contains($pathKey)) { $afterMap[$pathKey].sha256 } else { $null }
    if ($oldHash -eq $newHash) { continue }
    $displayPath = if ($afterMap.Contains($pathKey)) { $afterMap[$pathKey].path } else { $beforeMap[$pathKey].path }
    $classification = if (Test-DeclaredPath $displayPath @($build.output_paths)) { 'output' }
        elseif (Test-DeclaredPath $displayPath @($build.generated_write_paths)) { 'generated-write' }
        else { 'review-required' }
    $changes.Add([pscustomobject][ordered]@{
        path = $displayPath
        before_hash = $oldHash
        after_hash = $newHash
        classification = $classification
    })
}

$expectedArtifacts = [Collections.Generic.List[object]]::new()
foreach ($relativeOutput in @($build.outputs)) {
    $output = Join-EwiContainedPath -Root $targetRoot -RelativePath ([string]$relativeOutput)
    if (Test-Path -LiteralPath $output -PathType Leaf) {
        $relative = (Assert-EwiRelativePath -Path ([string]$relativeOutput)).Replace('\', '/')
        $hash = Get-EwiSha256 $output
        $key = $relative.ToLowerInvariant()
        $oldHash = if ($beforeMap.Contains($key)) { $beforeMap[$key].sha256 } else { $null }
        $expectedArtifacts.Add([pscustomobject][ordered]@{
            path = $relative
            hash = $hash
            size = (Get-Item $output).Length
            updated = ($oldHash -ne $hash)
        })
    }
}
$unknownChanges = @($changes | Where-Object classification -eq 'review-required')
$generatedChanges = @($changes | Where-Object classification -eq 'generated-write')
$allArtifactsUpdated = @($build.outputs).Count -gt 0 -and
    $expectedArtifacts.Count -eq @($build.outputs).Count -and
    @($expectedArtifacts | Where-Object { -not $_.updated }).Count -eq 0
$buildPassed = $processResult.ExitCode -eq 0 -and $allArtifactsUpdated
$buildStatus = if ($buildPassed) { 'passed' } elseif ($processResult.ExitCode -eq 0 -and @($build.outputs).Count -eq 0) { 'failed' } else { 'failed' }
$sideEffectStatus = if ($unknownChanges.Count) { 'review_required' } elseif ($generatedChanges.Count) { 'declared' } else { 'clean' }

$evidenceId = "build-$TargetId-$BuildId"
$evidenceRelative = "workspace-management/evidence/$evidenceId.json"
$stateUpdate = Invoke-EwiLocked -WorkspaceRoot $root -TimeoutSeconds $MutexTimeoutSeconds -ScriptBlock {
    $null = Assert-EwiActiveWorkspace -WorkspaceRoot $root
    $evidenceDirectory = Join-Path $root 'workspace-management/evidence'
    $stdoutPath = Join-Path $evidenceDirectory "$evidenceId.stdout.log"
    $stderrPath = Join-Path $evidenceDirectory "$evidenceId.stderr.log"
    [IO.File]::WriteAllText($stdoutPath, $processResult.StdOut, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($stderrPath, $processResult.StdErr, [Text.UTF8Encoding]::new($false))
    $artifacts = @(
        [pscustomobject][ordered]@{ path = "workspace-management/evidence/$evidenceId.stdout.log"; media_type = 'text/plain'; size = (Get-Item $stdoutPath).Length; sha256 = Get-EwiSha256 $stdoutPath },
        [pscustomobject][ordered]@{ path = "workspace-management/evidence/$evidenceId.stderr.log"; media_type = 'text/plain'; size = (Get-Item $stderrPath).Length; sha256 = Get-EwiSha256 $stderrPath }
    )
    $details = [pscustomobject][ordered]@{
        started_at = $startedAt
        finished_at = $finishedAt
        execution_context = $BuildContext
        tool_id = [string]$build.command.tool
        tool_version = $toolVersion
        commit = $builtCommit
        configuration_digest = $configurationDigest
        configuration_facts = $configurationFacts
        executable = $processResult.Executable
        arguments = @($processResult.Arguments)
        cwd = $processResult.WorkingDirectory
        expected_artifacts = @($expectedArtifacts)
        changes = @($changes)
        side_effect_status = $sideEffectStatus
    }
    $summary = if ($buildPassed) { 'Build passed and updated every expected artifact set.' } else { 'Build did not meet exit-code and updated-artifact success criteria.' }
    $null = Write-EwiEvidence -WorkspaceRoot $root -EvidenceId $evidenceId -Kind 'build' -Subject ([pscustomobject][ordered]@{
        workspace = $root
        source_id = [string]$target.source
        target_id = $TargetId
        build_id = $BuildId
        workstream_id = $WorkstreamId
        publish_id = if ($BuildContext -eq 'user-authority') { $PublishId } else { $null }
        reference_id = $null
    }) -Result ([pscustomobject][ordered]@{
        status = $buildStatus
        summary = $summary
        exit_code = [int]$processResult.ExitCode
        details = $details
    }) -Artifacts $artifacts

    $configChanged = (Get-EwiSha256 $targetsPath) -ne $targetsHash -or (Get-EwiSha256 $localPath) -ne $localHash
    if (-not $configChanged -and $BuildContext -eq 'agent-copy') {
        $targetsOriginal = [IO.File]::ReadAllBytes($targetsPath)
        $sourceStatePath = Join-Path $root "workspace-management/sync-state/sources/$($target.source).json"
        $sourceStateOriginal = if (Test-Path -LiteralPath $sourceStatePath) { [IO.File]::ReadAllBytes($sourceStatePath) } else { $null }
        try {
            $currentTargets = Read-EwiJson -Path $targetsPath -SchemaPath $targetsSchema
            $currentBuild = $currentTargets.targets.PSObject.Properties[$TargetId].Value.builds.PSObject.Properties[$BuildId].Value
            if ($buildPassed -and $sideEffectStatus -ne 'review_required') { $currentBuild.command_state = 'verified' }
            $pointer = "/targets/$TargetId/builds/$BuildId/command"
            $metadata = [pscustomobject][ordered]@{
                provenance = 'detected'
                verification = if ($buildPassed -and $sideEffectStatus -ne 'review_required') { 'verified' } else { 'failed' }
                freshness = 'current'
                evidence_ref = $evidenceRelative
            }
            $existingMeta = $currentTargets.field_metadata.PSObject.Properties[$pointer]
            if ($null -eq $existingMeta) { $currentTargets.field_metadata | Add-Member -NotePropertyName $pointer -NotePropertyValue $metadata }
            else { $existingMeta.Value = $metadata }
            Write-EwiJsonAtomic -Path $targetsPath -Value $currentTargets -SchemaPath $targetsSchema

            if ($buildPassed -and $sideEffectStatus -ne 'review_required' -and $null -ne $sourceStateOriginal) {
                $sourceState = Read-EwiJson -Path $sourceStatePath -SchemaPath (Join-Path $root 'workspace-management/schemas/source-sync-state.schema.json')
                $worktreeStatus = (Invoke-EwiGit -Repository $sourceRoot -ArgumentList @('status', '--porcelain=v1')).StdOut
                $commit = if ($sideEffectStatus -eq 'clean' -or [string]::IsNullOrWhiteSpace($worktreeStatus)) { (Invoke-EwiGit -Repository $sourceRoot -ArgumentList @('rev-parse', 'HEAD')).StdOut.Trim() } else { $null }
                $key = "$TargetId/$BuildId"
                $baseline = [pscustomobject][ordered]@{ last_successful_build_commit = $commit; evidence_ref = $evidenceRelative }
                $existingBaseline = $sourceState.build_baselines.PSObject.Properties[$key]
                if ($null -eq $existingBaseline) { $sourceState.build_baselines | Add-Member -NotePropertyName $key -NotePropertyValue $baseline }
                else { $existingBaseline.Value = $baseline }
                Write-EwiJsonAtomic -Path $sourceStatePath -Value $sourceState -SchemaPath (Join-Path $root 'workspace-management/schemas/source-sync-state.schema.json')
            }
            $null = New-EwiGitCommit -Repository $root -Message "chore: record build configuration for $TargetId/$BuildId" -RelativePaths @('workspace-management/config/targets.json')
        }
        catch {
            [IO.File]::WriteAllBytes($targetsPath, $targetsOriginal)
            if ($null -ne $sourceStateOriginal) { [IO.File]::WriteAllBytes($sourceStatePath, $sourceStateOriginal) }
            $null = Invoke-EwiGit -Repository $root -ArgumentList @('reset', '--', 'workspace-management/config/targets.json') -AllowFailure
            throw
        }
    }
    $transactionState = $null
    if ($BuildContext -eq 'user-authority') {
        if ((Get-EwiSha256 $transactionPath) -ne $transactionHash) {
            throw 'Publish transaction changed during the user-authority build; result was recorded as evidence only.'
        }
        $currentTransaction = Read-EwiJson -Path $transactionPath -SchemaPath (Join-Path $root 'workspace-management/schemas/publish-transaction.schema.json')
        $currentTransaction.build_status = $buildStatus
        $currentTransaction.side_effect_status = $sideEffectStatus
        $currentTransaction.side_effects = @($changes)
        $currentTransaction.build_target_id = $TargetId
        $currentTransaction.build_id = $BuildId
        $currentTransaction.build_evidence_ref = $evidenceRelative
        $currentTransaction.updated_at = Get-EwiTimestamp
        if ($sideEffectStatus -eq 'review_required') {
            $currentTransaction.state = 'side_effect_review_required'
            $currentTransaction.message = 'The user build changed unclassified project files. Classify or restore them before retry/finalize.'
        }
        elseif (-not $buildPassed) {
            $currentTransaction.state = 'verification_failed'
            $currentTransaction.message = 'Published files remain in place, the build failed, and the user must choose rollback or explicit unverified acceptance.'
        }
        else {
            $currentTransaction.state = 'file_verified'
            $currentTransaction.message = 'User-authority build passed. Finalize the publish transaction to advance user and build baselines.'
        }
        Write-EwiJsonAtomic -Path $transactionPath -Value $currentTransaction -SchemaPath (Join-Path $root 'workspace-management/schemas/publish-transaction.schema.json')
        $transactionState = $currentTransaction.state
        $transactionRelative = [IO.Path]::GetRelativePath($root, $transactionPath).Replace('\', '/')
        $transactionArtifact = [pscustomobject][ordered]@{
            path = $transactionRelative
            media_type = 'application/json'
            size = (Get-Item -LiteralPath $transactionPath).Length
            sha256 = Get-EwiSha256 $transactionPath
        }
        $publishEvidenceStatus = if ($currentTransaction.state -eq 'verification_failed') { 'failed' } elseif ($currentTransaction.state -eq 'side_effect_review_required') { 'blocked' } else { 'passed' }
        $null = Write-EwiEvidence -WorkspaceRoot $root -EvidenceId $PublishId -Kind publish `
            -Subject ([pscustomobject][ordered]@{ workspace = $root; source_id = [string]$target.source; target_id = $TargetId; build_id = $BuildId; workstream_id = $WorkstreamId; publish_id = $PublishId; reference_id = $null }) `
            -Result ([pscustomobject][ordered]@{ status = $publishEvidenceStatus; summary = $currentTransaction.message; exit_code = [int]$processResult.ExitCode; details = [pscustomobject][ordered]@{ transaction_state = $currentTransaction.state; file_publish_status = $currentTransaction.file_publish_status; build_status = $currentTransaction.build_status; side_effect_status = $currentTransaction.side_effect_status } }) `
            -Artifacts @($transactionArtifact)
    }
    return [pscustomobject][ordered]@{
        configuration_updated = (-not $configChanged -and $BuildContext -eq 'agent-copy')
        configuration_changed_during_build = $configChanged
        transaction_state = $transactionState
    }
}

[pscustomobject][ordered]@{
    status = $buildStatus
    target_id = $TargetId
    build_id = $BuildId
    execution_context = $BuildContext
    exit_code = $processResult.ExitCode
    expected_artifacts = @($expectedArtifacts)
    file_changes = @($changes)
    side_effect_status = $sideEffectStatus
    evidence = $evidenceRelative
    state_update = $stateUpdate
    hardware_verified = $false
} | ConvertTo-Json -Depth 15
