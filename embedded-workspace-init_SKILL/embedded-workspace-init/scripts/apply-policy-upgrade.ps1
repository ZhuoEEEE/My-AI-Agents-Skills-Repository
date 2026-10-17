[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $PlanBase64,
    [Parameter(Mandatory)] [ValidatePattern('^[0-9a-f]{64}$')] [string] $ApprovalDigest,
    [int] $MutexTimeoutSeconds = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/workspace-common.psm1') -Force

$payloadJson = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($PlanBase64))
if ((Get-EwiTextSha256 $payloadJson) -ne $ApprovalDigest) { throw 'Plan payload does not match the explicitly approved digest.' }
$plan = $payloadJson | ConvertFrom-Json -Depth 50 -ErrorAction Stop
if ($plan.schema -ne 1 -or $plan.route -ne 'policy-upgrade' -or $null -eq $plan.policy_upgrade) { throw 'The approved payload is not a version 1 policy upgrade plan.' }
$workspace = Resolve-EwiPath ([string]$plan.workspace_root)
$context = Assert-EwiActiveWorkspace -WorkspaceRoot $workspace -AllowLegacyPolicy
$stateOperations = @($plan.policy_upgrade.state_operations)
$operations = @($plan.policy_upgrade.operations) + @($stateOperations)
$sourceStateMigrations = @($plan.policy_upgrade.source_state_migrations)
if ($operations.Count -eq 0 -and $null -eq $plan.policy_upgrade.local_state_migration -and $sourceStateMigrations.Count -eq 0) { throw 'The approved policy plan contains no operation.' }

function Get-CanonicalSource {
    param([Parameter(Mandatory)] [string] $RelativePath)
    if ($RelativePath -eq 'work/README.md') { return Join-Path $PSScriptRoot '../assets/work-README.md' }
    if ($RelativePath -in @('AGENTS.md', 'README.md', 'USER_GUIDE.md')) { return Join-Path $PSScriptRoot "../assets/$RelativePath" }
    if ($RelativePath -eq 'workspace-management/tools/lib/project-copy-functions.ps1') { return Join-Path $PSScriptRoot 'lib/project-copy-functions.ps1' }
    if ($RelativePath -like 'workspace-management/templates/*') { return Join-Path $PSScriptRoot ('../assets/' + [IO.Path]::GetFileName($RelativePath)) }
    if ($RelativePath -eq '.gitignore') { return Join-Path $PSScriptRoot '../assets/gitignore' }
    if ($RelativePath -like 'workspace-management/guides/*') { return Join-Path $PSScriptRoot ('../references/' + [IO.Path]::GetFileName($RelativePath)) }
    if ($RelativePath -like 'workspace-management/schemas/*') { return Join-Path $PSScriptRoot ('../assets/schemas/' + [IO.Path]::GetFileName($RelativePath)) }
    if ($RelativePath -eq 'workspace-management/tools/lib/workspace-common.psm1') { return Join-Path $PSScriptRoot 'lib/workspace-common.psm1' }
    if ($RelativePath -like 'workspace-management/tools/*') { return Join-Path $PSScriptRoot ([IO.Path]::GetFileName($RelativePath)) }
    throw "Unsupported policy upgrade path: $RelativePath"
}

$originals = [ordered]@{}
foreach ($operation in $operations) {
    $relative = Assert-EwiRelativePath ([string]$operation.path)
    $target = Join-EwiContainedPath -Root $workspace -RelativePath $relative
    $currentHash = if (Test-Path -LiteralPath $target -PathType Leaf) { Get-EwiSha256 $target } else { $null }
    if ($currentHash -ne $operation.current_hash) { throw "Managed file changed after policy planning: $relative" }
    if ($operation.PSObject.Properties.Name -contains 'content_base64') {
        $content = [Convert]::FromBase64String($operation.content_base64)
        if ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($content)).ToLowerInvariant() -ne $operation.target_hash) { throw 'State migration content hash mismatch.' }
    } else {
        $canonical = Resolve-EwiPath (Get-CanonicalSource $relative)
        if ((Get-EwiSha256 $canonical) -ne $operation.target_hash) { throw "Canonical policy file changed after planning: $relative" }
    }
    $originals[$relative] = if ($null -eq $currentHash) { $null } else { [IO.File]::ReadAllBytes($target) }
}

$localPath = Join-Path $workspace 'workspace-management/config/targets.local.json'
$localOriginal = [IO.File]::ReadAllBytes($localPath)
$sourceStateOriginals = [ordered]@{}
foreach ($migration in $sourceStateMigrations) {
    $statePath = Join-Path $workspace "workspace-management/sync-state/sources/$($migration.source_id).json"
    if ((Get-EwiSha256 $statePath) -ne $migration.state_hash) { throw "Source state changed after policy planning: $($migration.source_id)" }
    $sourceStateOriginals[[string]$migration.source_id] = [IO.File]::ReadAllBytes($statePath)
}
$oldHead = (Invoke-EwiGit -Repository $workspace -ArgumentList @('rev-parse', 'HEAD')).StdOut.Trim()
$sourceFacts = [Collections.Generic.List[object]]::new()
$targets = Read-EwiJson -Path (Join-Path $workspace 'workspace-management/config/targets.json') -SchemaPath (Join-Path $workspace 'workspace-management/schemas/targets.schema.json')
foreach ($sourceProperty in $targets.sources.PSObject.Properties) {
    $integration = Join-EwiContainedPath -Root $workspace -RelativePath ([string]$sourceProperty.Value.integration_path)
    $sourceFacts.Add([pscustomobject][ordered]@{
        source_id = $sourceProperty.Name
        head = (Invoke-EwiGit -Repository $integration -ArgumentList @('rev-parse', 'HEAD')).StdOut.Trim()
        status = (Invoke-EwiGit -Repository $integration -ArgumentList @('status', '--porcelain=v1')).StdOut
    })
}

$result = Invoke-EwiLocked -WorkspaceRoot $workspace -TimeoutSeconds $MutexTimeoutSeconds -ScriptBlock {
    $null = Assert-EwiActiveWorkspace -WorkspaceRoot $workspace -AllowLegacyPolicy
    foreach ($operation in $operations) {
        $target = Join-EwiContainedPath -Root $workspace -RelativePath ([string]$operation.path)
        $currentHash = if (Test-Path -LiteralPath $target -PathType Leaf) { Get-EwiSha256 $target } else { $null }
        if ($currentHash -ne $operation.current_hash) { throw "Managed file changed after lock acquisition: $($operation.path)" }
        if ($operation.PSObject.Properties.Name -notcontains 'content_base64') {
            if ((Get-EwiSha256 (Get-CanonicalSource $operation.path)) -ne $operation.target_hash) { throw "Canonical policy file changed after lock acquisition: $($operation.path)" }
        }
    }
    if ((Get-EwiSha256 $localPath) -ne [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($localOriginal)).ToLowerInvariant()) { throw 'Local configuration changed after policy planning.' }
    foreach ($migration in $sourceStateMigrations) {
        $statePath = Join-Path $workspace "workspace-management/sync-state/sources/$($migration.source_id).json"
        if ((Get-EwiSha256 $statePath) -ne $migration.state_hash) { throw "Source state changed after lock acquisition: $($migration.source_id)" }
    }

    $upgradeId = 'policy-upgrade-' + [DateTimeOffset]::Now.ToString('yyyyMMddHHmmssfff') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 6)
    $recoveryRoot = Join-Path $workspace "workspace-management/recovery/$upgradeId"
    $historyRoot = Join-Path $workspace "workspace-management/history/policy-upgrades/$upgradeId"
    $archivedRootRule = $null
    $commit = $null
    try {
        $null = New-Item -ItemType Directory -Path $recoveryRoot
        foreach ($operation in $operations) {
            $relative = [string]$operation.path
            $target = Join-EwiContainedPath -Root $workspace -RelativePath $relative
            if ($null -ne $operation.current_hash) {
                $snapshot = Join-EwiContainedPath -Root $recoveryRoot -RelativePath $relative
                $parent = Split-Path -Parent $snapshot
                if (-not (Test-Path -LiteralPath $parent)) { $null = New-Item -ItemType Directory -Path $parent }
                [IO.File]::WriteAllBytes($snapshot, [byte[]]$originals[$relative])
                if ((Get-EwiSha256 $snapshot) -ne $operation.current_hash) { throw "Policy snapshot mismatch: $relative" }
            }
            $stateOperation = $operation.PSObject.Properties.Name -contains 'content_base64'
            if (-not $stateOperation) { $canonical = Resolve-EwiPath (Get-CanonicalSource $relative) }
            $parent = Split-Path -Parent $target
            if (-not (Test-Path -LiteralPath $parent)) { $null = New-Item -ItemType Directory -Path $parent }
            $temporary = Join-Path $parent ('.policy-' + [Guid]::NewGuid().ToString('N') + '.tmp')
            try {
                if ($stateOperation) {
                    $stateValue = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($operation.content_base64)) | ConvertFrom-Json -Depth 100 -DateKind String
                    Write-EwiJsonAtomic -Path $temporary -Value $stateValue -SchemaPath (Join-Path $workspace ('workspace-management/schemas/' + $operation.schema_name))
                }
                else { [IO.File]::Copy($canonical, $temporary, $true) }
                if ((Get-EwiSha256 $temporary) -ne $operation.target_hash) { throw "Canonical copy mismatch: $relative" }
                [IO.File]::Move($temporary, $target, $true)
            }
            finally { if (Test-Path -LiteralPath $temporary) { [IO.File]::Delete($temporary) } }
            if ($relative -eq 'AGENTS.md' -and $null -ne $operation.current_hash) {
                $null = New-Item -ItemType Directory -Path $historyRoot -Force
                $archiveName = "root-agents-$($operation.current_hash.Substring(0, 8)).txt"
                $archive = Join-Path $historyRoot $archiveName
                [IO.File]::WriteAllBytes($archive, [byte[]]$originals[$relative])
                $archivedRootRule = "workspace-management/history/policy-upgrades/$upgradeId/$archiveName"
            }
        }

        if ($plan.policy_upgrade.local_state_migration -eq 'add-deferred-user-git') {
            $local = Get-Content -Raw -LiteralPath $localPath | ConvertFrom-Json -Depth 50 -ErrorAction Stop
            foreach ($sourceProperty in $local.sources.PSObject.Properties) {
                foreach ($mappingProperty in $sourceProperty.Value.mappings.PSObject.Properties) {
                    if ($null -eq $mappingProperty.Value.PSObject.Properties['user_git']) {
                        $mappingProperty.Value | Add-Member -NotePropertyName user_git -NotePropertyValue ([pscustomobject][ordered]@{ status = 'deferred'; repository_path = $null })
                    }
                }
            }
            Write-EwiJsonAtomic -Path $localPath -Value $local -SchemaPath (Join-Path $workspace 'workspace-management/schemas/targets-local.schema.json')
        }
        else {
            $null = Read-EwiJson -Path $localPath -SchemaPath (Join-Path $workspace 'workspace-management/schemas/targets-local.schema.json')
        }
        foreach ($migration in $sourceStateMigrations) {
            $statePath = Join-Path $workspace "workspace-management/sync-state/sources/$($migration.source_id).json"
            $state = Read-EwiJson -Path $statePath -SchemaPath (Join-Path $workspace 'workspace-management/schemas/source-sync-state.schema.json')
            $state.mapping_digest = [string]$migration.target_mapping_digest
            Write-EwiJsonAtomic -Path $statePath -Value $state -SchemaPath (Join-Path $workspace 'workspace-management/schemas/source-sync-state.schema.json')
        }

        foreach ($operation in $operations) {
            if ((Get-EwiSha256 (Join-EwiContainedPath -Root $workspace -RelativePath ([string]$operation.path))) -ne $operation.target_hash) { throw "Policy verification failed: $($operation.path)" }
        }
        foreach ($stateOperation in $stateOperations) { $null = Read-EwiJson (Join-Path $workspace $stateOperation.path) -SchemaPath (Join-Path $workspace ('workspace-management/schemas/' + $stateOperation.schema_name)) }
        $manifestPath = Join-Path $historyRoot 'manifest.json'
        if (-not (Test-Path -LiteralPath $historyRoot)) { $null = New-Item -ItemType Directory -Path $historyRoot }
        $manifest = [pscustomobject][ordered]@{
            schema = 1
            upgrade_id = $upgradeId
            applied_at = Get-EwiTimestamp
            approval_digest = $ApprovalDigest
            old_management_head = $oldHead
            current_workspace_schema = [int]$plan.policy_upgrade.current_workspace_schema
            target_workspace_schema = [int]$plan.policy_upgrade.target_workspace_schema
            current_policy_version = [int]$plan.policy_upgrade.current_policy_version
            target_policy_version = [int]$plan.policy_upgrade.target_policy_version
            operations = @($operations | Select-Object path,action,current_hash,target_hash)
            local_state_migration = $plan.policy_upgrade.local_state_migration
            source_state_migrations = @($sourceStateMigrations)
            archived_root_rule = $archivedRootRule
        }
        Write-EwiJsonAtomic -Path $manifestPath -Value $manifest -SchemaPath (Join-Path $workspace 'workspace-management/schemas/policy-upgrade.schema.json')
        $tracked = @($operations | ForEach-Object path) + @([IO.Path]::GetRelativePath($workspace, $manifestPath).Replace('\', '/'))
        if ($archivedRootRule) { $tracked += $archivedRootRule }
        $commit = New-EwiGitCommit -Repository $workspace -Message "chore: apply $upgradeId" -RelativePaths $tracked
        if (-not $commit) { throw 'Policy upgrade did not create a management checkpoint.' }

        foreach ($fact in $sourceFacts) {
            $source = $targets.sources.PSObject.Properties[$fact.source_id].Value
            $integration = Join-EwiContainedPath -Root $workspace -RelativePath ([string]$source.integration_path)
            if ((Invoke-EwiGit -Repository $integration -ArgumentList @('rev-parse', 'HEAD')).StdOut.Trim() -ne $fact.head -or
                (Invoke-EwiGit -Repository $integration -ArgumentList @('status', '--porcelain=v1')).StdOut -cne $fact.status) {
                throw "Policy upgrade changed source-private Git: $($fact.source_id)"
            }
        }
        $evidenceId = New-EwiEvidenceId 'policy-upgrade'
        $null = Write-EwiEvidence -WorkspaceRoot $workspace -EvidenceId $evidenceId -Kind migration `
            -Subject ([pscustomobject][ordered]@{ workspace = $workspace; source_id = $null; target_id = $null; build_id = $null; workstream_id = $null; publish_id = $null; reference_id = $null }) `
            -Result ([pscustomobject][ordered]@{ status = 'passed'; summary = 'The approved policy upgrade was applied and validated.'; exit_code = 0; details = [pscustomobject][ordered]@{ upgrade_id = $upgradeId; operations = $operations.Count; management_commit = $commit } }) `
            -Artifacts @([pscustomobject][ordered]@{ path = [IO.Path]::GetRelativePath($workspace, $manifestPath).Replace('\', '/'); media_type = 'application/json'; size = (Get-Item $manifestPath).Length; sha256 = Get-EwiSha256 $manifestPath })
        return [pscustomobject][ordered]@{ status = 'upgraded'; upgrade_id = $upgradeId; operations = $operations.Count; local_state_migration = $plan.policy_upgrade.local_state_migration; management_commit = $commit; evidence = "workspace-management/evidence/$evidenceId.json" }
    }
    catch {
        $null = Invoke-EwiGit -Repository $workspace -ArgumentList @('reset', '--mixed', $oldHead) -AllowFailure
        foreach ($operation in $operations) {
            $relative = [string]$operation.path
            $target = Join-EwiContainedPath -Root $workspace -RelativePath $relative
            if ($null -eq $originals[$relative]) { if (Test-Path -LiteralPath $target) { [IO.File]::Delete($target) } }
            else { [IO.File]::WriteAllBytes($target, [byte[]]$originals[$relative]) }
            $null = Invoke-EwiGit -Repository $workspace -ArgumentList @('reset', '--', $relative) -AllowFailure
        }
        [IO.File]::WriteAllBytes($localPath, $localOriginal)
        foreach ($sourceId in $sourceStateOriginals.Keys) {
            [IO.File]::WriteAllBytes((Join-Path $workspace "workspace-management/sync-state/sources/$sourceId.json"), [byte[]]$sourceStateOriginals[$sourceId])
        }
        foreach ($path in @($historyRoot, $recoveryRoot)) {
            if (Test-Path -LiteralPath $path) {
                Get-ChildItem -LiteralPath $path -Recurse -Force | ForEach-Object { $_.Attributes = 'Normal' }
                (Get-Item -LiteralPath $path -Force).Attributes = 'Directory'
                [IO.Directory]::Delete($path, $true)
            }
        }
        $policyHistoryRoot = Join-Path $workspace 'workspace-management/history/policy-upgrades'
        if ((Test-Path -LiteralPath $policyHistoryRoot -PathType Container) -and @(Get-ChildItem -LiteralPath $policyHistoryRoot -Force).Count -eq 0) {
            [IO.Directory]::Delete($policyHistoryRoot, $false)
        }
        throw
    }
}

$result | ConvertTo-Json -Depth 20
