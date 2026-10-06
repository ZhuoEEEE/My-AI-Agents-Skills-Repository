[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $WorkspaceRoot,
    [string[]] $UserSourcePath = @(),
    [string] $LegacyWorkspaceRoot,
    [string] $SourceDefinitionsJson,
    [string] $CopyMappingsJson,
    [string[]] $KnownActiveWorkspaceRoot = @(),
    [string[]] $LegacyRuleFile = @(),
    [ValidateSet('archive', 'preserve-only')] [string] $LegacyRuleDisposition = 'archive',
    [bool] $RegisterLegacyWorkspace = $true,
    [switch] $PolicyUpgrade
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$modulePath = Join-Path $PSScriptRoot 'lib/workspace-common.psm1'
Import-Module $modulePath -Force
$sourceAssets = Join-Path $PSScriptRoot '../assets'
$sourceReferences = Join-Path $PSScriptRoot '../references'
$schemaRoot = if (Test-Path -LiteralPath (Join-Path $sourceAssets 'schemas') -PathType Container) { Join-Path $sourceAssets 'schemas' } else { Join-Path $PSScriptRoot '../schemas' }

function Get-ExistingAncestor {
    param([Parameter(Mandatory)] [string] $Path)

    $candidate = [IO.Path]::GetFullPath($Path)
    while (-not (Test-Path -LiteralPath $candidate)) {
        $parent = Split-Path -Parent $candidate
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $candidate) {
            throw "No readable parent exists for candidate path: $Path"
        }
        $candidate = $parent
    }
    return Resolve-EwiPath $candidate
}

function Get-OuterGitRoot {
    param([Parameter(Mandatory)] [string] $Path)

    $ancestor = Get-ExistingAncestor $Path
    $probe = Invoke-EwiProcess -Executable 'git' -ArgumentList @('-C', $ancestor, 'rev-parse', '--show-toplevel') -WorkingDirectory $ancestor -AllowFailure
    if ($probe.ExitCode -ne 0) { return $null }
    return Resolve-EwiPath $probe.StdOut.Trim()
}

function Normalize-SourceDefinitions {
    param(
        [string] $DefinitionsJson,
        [string[]] $Paths
    )

    $definitions = @()
    if (-not [string]::IsNullOrWhiteSpace($DefinitionsJson)) {
        $definitions = @($DefinitionsJson | ConvertFrom-Json -Depth 30 -ErrorAction Stop)
    }
    else {
        $used = @{}
        foreach ($path in $Paths) {
            $real = Resolve-EwiPath $path
            $base = ConvertTo-EwiId ([IO.Path]::GetFileName($real))
            $id = $base
            $suffix = 2
            while ($used.ContainsKey($id)) {
                $id = "$base-$suffix"
                $suffix++
            }
            $used[$id] = $true
            $definitions += [pscustomobject][ordered]@{
                id = $id
                origin = 'user-imported'
                user_source = 'configured'
                mappings = @(
                    [pscustomobject][ordered]@{
                        id = $id
                        source_path = $real
                        integration_subpath = '.'
                    }
                )
            }
        }
    }

    $normalized = [Collections.Generic.List[object]]::new()
    $sourceIds = @{}
    $mappingIds = @{}
    foreach ($definition in $definitions) {
        $id = [string]$definition.id
        if ($id -notmatch '^[a-z0-9][a-z0-9-]{0,63}$' -or $sourceIds.ContainsKey($id)) {
            throw "Invalid or duplicate source id: $id"
        }
        $sourceIds[$id] = $true
        $origin = [string]$definition.origin
        if ($origin -notin @('user-imported', 'agent-created', 'reference-promoted')) {
            throw "Invalid source origin for '$id': $origin"
        }
        $userSource = [string]$definition.user_source
        if ($userSource -notin @('configured', 'none')) {
            throw "Invalid user_source for '$id': $userSource"
        }
        $mappings = [Collections.Generic.List[object]]::new()
        foreach ($mapping in @($definition.mappings)) {
            $mappingId = [string]$mapping.id
            if ($mappingId -notmatch '^[a-z0-9][a-z0-9-]{0,63}$' -or $mappingIds.ContainsKey($mappingId)) {
                throw "Invalid or duplicate mapping id: $mappingId"
            }
            $mappingIds[$mappingId] = $true
            $relative = Assert-EwiRelativePath -Path ([string]$mapping.integration_subpath) -AllowDot
            $sourcePath = Resolve-EwiPath ([string]$mapping.source_path)
            $mappings.Add([pscustomobject][ordered]@{
                id = $mappingId
                source_path = $sourcePath
                integration_subpath = $relative
            })
        }
        if ($userSource -eq 'configured' -and $mappings.Count -eq 0) {
            throw "User-backed source '$id' requires at least one mapping."
        }
        if ($userSource -eq 'none' -and $mappings.Count -ne 0) {
            throw "Source '$id' has user_source none and must not contain mappings."
        }
        if ($origin -eq 'agent-created' -and $userSource -ne 'none') {
            throw "Agent-created source '$id' cannot have a user authority mapping."
        }
        if ($origin -eq 'reference-promoted' -and $userSource -ne 'none') {
            throw "Reference-promoted source '$id' must be created without a user authority mapping; add one later through a separately approved mapping migration."
        }
        for ($left = 0; $left -lt $mappings.Count; $left++) {
            for ($right = $left + 1; $right -lt $mappings.Count; $right++) {
                $a = $mappings[$left].integration_subpath
                $b = $mappings[$right].integration_subpath
                $aPrefix = if ($a -eq '.') { '' } else { $a.TrimEnd('/') + '/' }
                $bPrefix = if ($b -eq '.') { '' } else { $b.TrimEnd('/') + '/' }
                if ($a -eq $b -or $a.StartsWith($bPrefix, [StringComparison]::OrdinalIgnoreCase) -or
                    $b.StartsWith($aPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                    throw "Overlapping integration subpaths in '$id': '$a' and '$b'."
                }
            }
        }
        $normalized.Add([pscustomobject][ordered]@{
            id = $id
            origin = $origin
            user_source = $userSource
            mappings = @($mappings)
        })
    }
    return @($normalized)
}

$workspace = Resolve-EwiPath -Path $WorkspaceRoot -AllowMissing
$workspaceExists = Test-Path -LiteralPath $workspace -PathType Container
$blockers = [Collections.Generic.List[string]]::new()
$warnings = [Collections.Generic.List[string]]::new()
$route = 'new-empty'
$existingState = $null

if (Test-Path -LiteralPath $workspace -PathType Leaf) {
    $blockers.Add("Workspace candidate is a file: $workspace")
}
elseif ($workspaceExists) {
    $children = @(Get-ChildItem -LiteralPath $workspace -Force -ErrorAction Stop)
    $workspaceConfig = Join-Path $workspace 'workspace-management/config/workspace.json'
    if (Test-Path -LiteralPath $workspaceConfig -PathType Leaf) {
        try {
            $schema = Join-Path $schemaRoot 'workspace.schema.json'
            $existing = Read-EwiJson -Path $workspaceConfig -SchemaPath $schema
            $existingState = $existing.workspace_state
            $route = if ($PolicyUpgrade) { 'policy-upgrade' } else { [string]$existing.workspace_state }
        }
        catch {
            $route = 'nonempty-unmanaged'
            $blockers.Add("Existing workspace configuration is invalid: $($_.Exception.Message)")
        }
    }
    elseif ($children.Count -gt 0) {
        $route = 'nonempty-unmanaged'
    }
}

$outerGit = Get-OuterGitRoot $workspace
if ($null -ne $outerGit -and (Get-EwiPathIdentity $outerGit) -ne (Get-EwiPathIdentity $workspace -AllowMissing)) {
    $blockers.Add("Candidate is nested inside an outer Git worktree: $outerGit")
}

$sourceDefinitions = @(Normalize-SourceDefinitions -DefinitionsJson $SourceDefinitionsJson -Paths $UserSourcePath)
$allMappings = @($sourceDefinitions | ForEach-Object { @($_.mappings) })
foreach ($mapping in $allMappings) {
    if (Test-EwiPathWithin -Path $workspace -Parent $mapping.source_path -AllowEqual -AllowMissing) {
        $route = 'inside-user-source'
        $blockers.Add("Workspace candidate is inside user source '$($mapping.id)'; choose a separate external empty root.")
    }
    elseif (Test-EwiPathWithin -Path $mapping.source_path -Parent $workspace -AllowEqual -AllowMissing) {
        $route = 'contains-user-source'
        $blockers.Add("Workspace candidate contains user source '$($mapping.id)'; choose a separate external empty root.")
    }
}
foreach ($knownRootValue in $KnownActiveWorkspaceRoot) {
    try {
        $knownRoot = Resolve-EwiPath $knownRootValue
        if ((Get-EwiPathIdentity $knownRoot) -eq (Get-EwiPathIdentity $workspace -AllowMissing)) { continue }
        $knownWorkspace = Read-EwiJson -Path (Join-Path $knownRoot 'workspace-management/config/workspace.json') -SchemaPath (Join-Path $schemaRoot 'workspace.schema.json')
        $knownLocal = Read-EwiJson -Path (Join-Path $knownRoot 'workspace-management/config/targets.local.json') -SchemaPath (Join-Path $schemaRoot 'targets-local.schema.json')
        if ($knownWorkspace.workspace_state -ne 'active') { continue }
        foreach ($knownSourceProperty in $knownLocal.sources.PSObject.Properties) {
            foreach ($knownMappingProperty in $knownSourceProperty.Value.mappings.PSObject.Properties) {
                foreach ($mapping in $allMappings) {
                    try {
                        Assert-EwiPathsSeparated -First $mapping.source_path -Second ([string]$knownMappingProperty.Value.source_path) -FirstLabel "user source '$($mapping.id)'" -SecondLabel "authority owned by active workspace '$knownRoot'"
                    }
                    catch { $blockers.Add($_.Exception.Message) }
                }
            }
        }
    }
    catch {
        $blockers.Add("Known active workspace could not be verified: $knownRootValue :: $($_.Exception.Message)")
    }
}
for ($left = 0; $left -lt $allMappings.Count; $left++) {
    for ($right = $left + 1; $right -lt $allMappings.Count; $right++) {
        try {
            Assert-EwiPathsSeparated `
                -First $allMappings[$left].source_path `
                -Second $allMappings[$right].source_path `
                -FirstLabel "user source '$($allMappings[$left].id)'" `
                -SecondLabel "user source '$($allMappings[$right].id)'"
        }
        catch {
            $blockers.Add($_.Exception.Message)
        }
    }
}
$sourcePlans = [Collections.Generic.List[object]]::new()
foreach ($definition in $sourceDefinitions) {
    $mappingPlans = [Collections.Generic.List[object]]::new()
    foreach ($mapping in $definition.mappings) {
        try {
            Assert-EwiPathsSeparated -First $workspace -Second $mapping.source_path -FirstLabel 'workspace root' -SecondLabel "user source '$($mapping.id)'" -AllowMissing
            $inventory = Get-EwiFileInventory -Root $mapping.source_path -MappingId $mapping.id
            if (-not $inventory.scan_complete) {
                $blockers.Add("Source scan is incomplete for '$($mapping.id)'; links or read errors require review.")
            }
            if ($inventory.git_topology.Count -gt 0) {
                $blockers.Add("Source '$($mapping.id)' contains a linked-worktree or nested Git topology: $([string]::Join(', ', $inventory.git_topology))")
            }
            if ($inventory.sensitive.Count -gt 0) {
                $blockers.Add("Source '$($mapping.id)' contains files requiring sensitive-content review: $([string]::Join(', ', $inventory.sensitive))")
            }
            if ($inventory.pending.Count -gt 0) {
                $blockers.Add("Source '$($mapping.id)' contains ambiguous license or activation files requiring confirmation: $([string]::Join(', ', $inventory.pending))")
            }
            foreach ($warning in @($inventory.warnings)) {
                $warnings.Add("Source '$($mapping.id)': $warning")
            }
            $gitMarker = Join-Path $mapping.source_path '.git'
            $lfs = @()
            $attributes = Join-Path $mapping.source_path '.gitattributes'
            if (Test-Path -LiteralPath $attributes -PathType Leaf) {
                $lfs = @(Select-String -LiteralPath $attributes -Pattern 'filter=lfs' -SimpleMatch -ErrorAction Stop)
            }
            $submodules = Test-Path -LiteralPath (Join-Path $mapping.source_path '.gitmodules') -PathType Leaf
            if ($submodules -or $lfs.Count -gt 0) {
                $blockers.Add("Source '$($mapping.id)' contains submodule or Git LFS metadata and is unsupported in version 1.")
            }
            $mappingPlans.Add([pscustomobject][ordered]@{
                id = $mapping.id
                source_path = $mapping.source_path
                integration_subpath = $mapping.integration_subpath
                file_count = @($inventory.files).Count
                inventory_digest = Get-EwiInventoryDigest $inventory
                excluded = @($inventory.excluded)
                sensitive = @($inventory.sensitive)
                pending = @($inventory.pending)
                warnings = @($inventory.warnings)
                git_topology = @($inventory.git_topology)
                links = @($inventory.links)
                git_present = (Test-Path -LiteralPath $gitMarker)
            })
        }
        catch {
            $blockers.Add("Source '$($mapping.id)' could not be planned: $($_.Exception.Message)")
        }
    }
    $sourcePlans.Add([pscustomobject][ordered]@{
        id = $definition.id
        origin = $definition.origin
        user_source = $definition.user_source
        mappings = @($mappingPlans)
    })
}

$legacyPlan = $null
$policyUpgradePlan = $null
if (-not [string]::IsNullOrWhiteSpace($LegacyWorkspaceRoot)) {
    try {
        $legacy = Resolve-EwiPath $LegacyWorkspaceRoot
        Assert-EwiPathsSeparated -First $workspace -Second $legacy -FirstLabel 'new workspace' -SecondLabel 'legacy workspace' -AllowMissing
        $legacyInventory = Get-EwiFileInventory -Root $legacy -MappingId 'legacy'
        if (-not $legacyInventory.scan_complete -or $legacyInventory.git_topology.Count -gt 0 -or $legacyInventory.sensitive.Count -gt 0 -or $legacyInventory.pending.Count -gt 0) {
            $blockers.Add('Legacy workspace contains unresolved links, read errors, or sensitive files.')
        }
        $requestedRuleFiles = @('AGENTS.md', 'AGENTS.override.md') + @($LegacyRuleFile | ForEach-Object { Assert-EwiRelativePath -Path $_ })
        $legacyRuleFiles = @($requestedRuleFiles | Sort-Object -Unique | Where-Object {
            Test-Path -LiteralPath (Join-Path $legacy $_) -PathType Leaf
        })
        $copyMappings = @(if ($CopyMappingsJson) { $CopyMappingsJson | ConvertFrom-Json -Depth 20 -ErrorAction Stop })
        if (@($copyMappings).Count -eq 0) {
            $warnings.Add('No explicit legacy copy mappings were supplied; migration cannot be applied until every retained item is classified.')
        }
        $normalizedCopyMappings = [Collections.Generic.List[object]]::new()
        foreach ($copyMapping in $copyMappings) {
            $sourceRelative = Assert-EwiRelativePath -Path ([string]$copyMapping.source_relative) -AllowDot
            $action = if ($copyMapping.PSObject.Properties.Name -contains 'action') { [string]$copyMapping.action } else { 'copy' }
            if ($action -notin @('copy', 'preserve-only')) { throw "Unsupported migration mapping action: $action" }
            $destinationRelative = $null
            if ($action -eq 'copy') {
                if (-not ($copyMapping.PSObject.Properties.Name -contains 'destination_relative')) { throw "Copy mapping lacks a destination: $sourceRelative" }
                $destinationRelative = Assert-EwiRelativePath -Path ([string]$copyMapping.destination_relative)
                if ($destinationRelative -match '^(?:AGENTS(?:\.override)?\.md|README\.md|USER_GUIDE\.md|\.gitignore)$' -or
                    $destinationRelative -match '^workspace-management/(?:config|guides|schemas|tools|templates|sync-state)(?:/|$)' -or
                    $destinationRelative -match '^sources/[^/]+/integration(?:/|$)' -or
                    $destinationRelative -match '^work/[^/]+/sources(?:/|$)') {
                    throw "Migration mapping targets a protected managed boundary: $destinationRelative"
                }
                foreach ($ruleFile in $legacyRuleFiles) {
                    if ($sourceRelative -eq '.' -or $ruleFile -eq $sourceRelative -or $ruleFile.StartsWith($sourceRelative.TrimEnd('/') + '/', [StringComparison]::OrdinalIgnoreCase)) {
                        $blockers.Add("Legacy copy mapping '$sourceRelative' includes active rule file '$ruleFile'; classify non-rule content separately.")
                    }
                }
            }
            $normalizedCopyMappings.Add([pscustomobject][ordered]@{
                source_relative = $sourceRelative
                action = $action
                destination_relative = $destinationRelative
                classification = if ($copyMapping.PSObject.Properties.Name -contains 'classification') { [string]$copyMapping.classification } else { 'other' }
            })
        }
        for ($left = 0; $left -lt $normalizedCopyMappings.Count; $left++) {
            for ($right = $left + 1; $right -lt $normalizedCopyMappings.Count; $right++) {
                $a = $normalizedCopyMappings[$left].source_relative
                $b = $normalizedCopyMappings[$right].source_relative
                if ($a -eq '.' -or $b -eq '.' -or $a -eq $b -or $a.StartsWith($b.TrimEnd('/') + '/') -or $b.StartsWith($a.TrimEnd('/') + '/')) {
                    $blockers.Add("Legacy mappings overlap: '$a' and '$b'.")
                }
                $destinationA = $normalizedCopyMappings[$left].destination_relative
                $destinationB = $normalizedCopyMappings[$right].destination_relative
                if ($destinationA -and $destinationB -and
                    ($destinationA -eq $destinationB -or $destinationA.StartsWith($destinationB.TrimEnd('/') + '/') -or $destinationB.StartsWith($destinationA.TrimEnd('/') + '/'))) {
                    $blockers.Add("Legacy migration destinations overlap: '$destinationA' and '$destinationB'.")
                }
            }
        }
        foreach ($file in @($legacyInventory.files)) {
            if ($file.path -in $legacyRuleFiles) { continue }
            $owners = @($normalizedCopyMappings | Where-Object {
                $_.source_relative -eq '.' -or $file.path -eq $_.source_relative -or
                $file.path.StartsWith($_.source_relative.TrimEnd('/') + '/', [StringComparison]::OrdinalIgnoreCase)
            })
            if ($owners.Count -ne 1) { $blockers.Add("Legacy file requires exactly one copy/preserve classification: $($file.path)") }
        }
        $legacyPlan = [pscustomobject][ordered]@{
            root = $legacy
            inventory_digest = Get-EwiInventoryDigest $legacyInventory
            file_count = @($legacyInventory.files).Count
            rule_files = @($legacyRuleFiles)
            rule_disposition = $LegacyRuleDisposition
            register_as_history = $RegisterLegacyWorkspace
            copy_mappings = @($normalizedCopyMappings)
        }
        $route = 'legacy-migration'
    }
    catch {
        $blockers.Add("Legacy workspace could not be planned: $($_.Exception.Message)")
    }
}

if ($route -eq 'nonempty-unmanaged' -and $null -eq $legacyPlan) {
    $blockers.Add('A nonempty unmanaged candidate requires a separate empty destination and an explicit legacy migration plan.')
}
if ($route -eq 'policy-upgrade') {
    try {
        if (-not (Test-Path -LiteralPath $sourceAssets -PathType Container) -or -not (Test-Path -LiteralPath $sourceReferences -PathType Container)) {
            throw 'Policy upgrades must run from the installed skill so canonical assets and references are available.'
        }
        $assets = Resolve-EwiPath $sourceAssets
        $references = Resolve-EwiPath $sourceReferences
        $canonical = [ordered]@{
            'AGENTS.md' = Join-Path $assets 'AGENTS.md'
            'README.md' = Join-Path $assets 'README.md'
            'USER_GUIDE.md' = Join-Path $assets 'USER_GUIDE.md'
            '.gitignore' = Join-Path $assets 'gitignore'
        }
        foreach ($guideName in @('lifecycle-and-migration.md', 'sources-targets-and-git.md', 'workstreams-and-concurrency.md', 'synchronization-and-recovery.md', 'build-and-hardware.md', 'references-and-project-knowledge.md', 'configuration-schema.md')) {
            $canonical["workspace-management/guides/$guideName"] = Join-Path $references $guideName
        }
        foreach ($schemaFile in Get-ChildItem -LiteralPath (Join-Path $assets 'schemas') -Filter '*.json' -File) {
            $canonical["workspace-management/schemas/$($schemaFile.Name)"] = $schemaFile.FullName
        }
        $canonical['workspace-management/tools/lib/workspace-common.psm1'] = $modulePath
        foreach ($name in @('plan-migration.ps1', 'preserve-user-changes.ps1', 'detect-targets.ps1', 'import-reference.ps1', 'promote-reference.ps1', 'create-reference-copy.ps1', 'import-sources.ps1', 'add-source.ps1', 'migrate-source-mappings.ps1', 'set-user-git.ps1', 'new-workstream.ps1', 'update-workstream.ps1', 'pin-workstream-dependency.ps1', 'set-build-config.ps1', 'invoke-build.ps1', 'publish-workstream.ps1')) {
            $canonical["workspace-management/tools/$name"] = Join-Path $PSScriptRoot $name
        }
        $operations = [Collections.Generic.List[object]]::new()
        foreach ($relative in $canonical.Keys) {
            $deployed = Join-Path $workspace $relative
            $currentHash = if (Test-Path -LiteralPath $deployed -PathType Leaf) { Get-EwiSha256 $deployed } else { $null }
            $targetHash = Get-EwiSha256 $canonical[$relative]
            if ($currentHash -eq $targetHash) { continue }
            $operations.Add([pscustomobject][ordered]@{
                path = $relative
                action = if ($null -eq $currentHash) { 'add' } else { 'replace' }
                current_hash = $currentHash
                target_hash = $targetHash
            })
        }
        $localStateMigration = $false
        $sourceStateMigrations = [Collections.Generic.List[object]]::new()
        $localStatePath = Join-Path $workspace 'workspace-management/config/targets.local.json'
        if (Test-Path -LiteralPath $localStatePath -PathType Leaf) {
            $rawLocal = Get-Content -Raw -LiteralPath $localStatePath | ConvertFrom-Json -Depth 40 -ErrorAction Stop
            foreach ($sourceProperty in $rawLocal.sources.PSObject.Properties) {
                foreach ($mappingProperty in $sourceProperty.Value.mappings.PSObject.Properties) {
                    if ($null -eq $mappingProperty.Value.PSObject.Properties['user_git']) { $localStateMigration = $true }
                }
            }
            $rawTargets = Read-EwiJson -Path (Join-Path $workspace 'workspace-management/config/targets.json') -SchemaPath (Join-Path $schemaRoot 'targets.schema.json')
            foreach ($sourceProperty in $rawTargets.sources.PSObject.Properties) {
                if ($sourceProperty.Value.user_source -ne 'configured') { continue }
                $localSource = $rawLocal.sources.PSObject.Properties[$sourceProperty.Name]
                $statePath = Join-Path $workspace "workspace-management/sync-state/sources/$($sourceProperty.Name).json"
                if ($null -eq $localSource -or -not (Test-Path -LiteralPath $statePath -PathType Leaf)) { continue }
                $state = Read-EwiJson -Path $statePath -SchemaPath (Join-Path $schemaRoot 'source-sync-state.schema.json')
                $targetDigest = Get-EwiMappingDigest -Mappings @($sourceProperty.Value.mappings) -LocalMappings $localSource.Value.mappings
                if ($state.mapping_digest -ne $targetDigest) {
                    $sourceStateMigrations.Add([pscustomobject][ordered]@{ source_id = $sourceProperty.Name; state_hash = Get-EwiSha256 $statePath; target_mapping_digest = $targetDigest })
                }
            }
        }
        $policyUpgradePlan = [pscustomobject][ordered]@{
            current_workspace_schema = [int]$existing.workspace_schema
            target_workspace_schema = 1
            current_policy_version = [int]$existing.policy_version
            target_policy_version = 1
            operations = @($operations.ToArray())
            local_state_migration = if ($localStateMigration) { 'add-deferred-user-git' } else { $null }
            source_state_migrations = @($sourceStateMigrations.ToArray())
            snapshot_root = 'workspace-management/recovery/<upgrade-id>'
            archive_root = 'workspace-management/history/policy-upgrades/<upgrade-id>'
            validation = @('canonical hashes', 'JSON schemas', 'root identity', 'management Git boundary', 'source-private Git unchanged')
            rollback = 'restore every original managed/local file and management Git HEAD; leave sources and user Git unchanged'
        }
        if ($operations.Count -eq 0 -and -not $localStateMigration -and $sourceStateMigrations.Count -eq 0) { $warnings.Add('The workspace already matches policy version 1; no upgrade operation is required.') }
    }
    catch { $blockers.Add("Policy upgrade could not be planned: $($_.Exception.Message)") }
}

$payload = [pscustomobject][ordered]@{
    schema = 1
    route = $route
    workspace_root = $workspace
    workspace_existed = [bool]$workspaceExists
    existing_state = $existingState
    source_definitions = @($sourcePlans)
    legacy = $legacyPlan
    policy_upgrade = $policyUpgradePlan
    constraints = @(
        'local-windows-only',
        'pure-layout-only',
        'real-paths-disjoint',
        'user-sources-read-only',
        'single-active-workspace-per-authority',
        'no-implicit-user-git'
    )
}
$payloadJson = ConvertTo-EwiCanonicalJson $payload
$payloadBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payloadJson))
$approvalDigest = Get-EwiTextSha256 $payloadJson
$legacyCanApply = if ($route -eq 'legacy-migration') { $null -ne $legacyPlan -and @($legacyPlan.copy_mappings).Count -gt 0 } else { $true }
$policyCanApply = if ($route -eq 'policy-upgrade') {
    $null -ne $policyUpgradePlan -and (@($policyUpgradePlan.operations).Count -gt 0 -or $null -ne $policyUpgradePlan.local_state_migration -or @($policyUpgradePlan.source_state_migrations).Count -gt 0)
}
else { $true }
[object[]]$policyOperationSummary = @()
if ($null -ne $policyUpgradePlan) { $policyOperationSummary = @($policyUpgradePlan.operations | Where-Object { $null -ne $_ }) }
[object[]]$sourceStateMigrationSummary = @()
if ($null -ne $policyUpgradePlan) { $sourceStateMigrationSummary = @($policyUpgradePlan.source_state_migrations | Where-Object { $null -ne $_ }) }

$output = [pscustomobject][ordered]@{
    schema = 1
    operation = 'workspace-plan'
    generated_at = Get-EwiTimestamp
    route = $route
    can_apply = ($blockers.Count -eq 0 -and $legacyCanApply -and $policyCanApply)
    approval_required = ($route -in @('legacy-migration', 'policy-upgrade', 'nonempty-unmanaged', 'inside-user-source', 'contains-user-source'))
    approval_digest = $approvalDigest
    plan_base64 = $payloadBase64
    summary = [pscustomobject][ordered]@{
        workspace_root = $workspace
        external_root_required = ($route -in @('inside-user-source', 'contains-user-source'))
        external_root_requirement = if ($route -in @('inside-user-source', 'contains-user-source')) { 'Choose a user-selected empty local directory that is real-path disjoint from every authority path.' } else { $null }
        source_groups = $sourcePlans.Count
        legacy_workspace = if ($null -eq $legacyPlan) { $null } else { $legacyPlan.root }
        policy_upgrade_operations = $policyOperationSummary
        local_state_migration = if ($null -eq $policyUpgradePlan) { $null } else { $policyUpgradePlan.local_state_migration }
        source_state_migrations = $sourceStateMigrationSummary
        blockers = @($blockers)
        warnings = @($warnings)
    }
}

ConvertTo-Json -InputObject $output -Depth 30
