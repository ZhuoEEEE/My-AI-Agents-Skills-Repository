[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $WorkspaceRoot,
    [string[]] $UserSourcePath = @(),
    [string] $SourceDefinitionsJson,
    [string[]] $KnownActiveWorkspaceRoot = @(),
    [switch] $ResumeInitializing,
    [switch] $LeaveInitializing,
    [int] $MutexTimeoutSeconds = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$modulePath = Join-Path $PSScriptRoot 'lib/workspace-common.psm1'
Import-Module $modulePath -Force

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
$workspace = Resolve-EwiPath -Path $WorkspaceRoot -AllowMissing
$planText = & (Join-Path $PSScriptRoot 'plan-migration.ps1') `
    -WorkspaceRoot $workspace `
    -UserSourcePath $UserSourcePath `
    -SourceDefinitionsJson $SourceDefinitionsJson `
    -KnownActiveWorkspaceRoot $KnownActiveWorkspaceRoot | Out-String
$plan = $planText | ConvertFrom-Json -Depth 40 -ErrorAction Stop

if (-not $plan.can_apply) {
    throw "Initialization plan is blocked: $([string]::Join('; ', @($plan.summary.blockers)))"
}
if ($plan.route -eq 'active') {
    [pscustomobject][ordered]@{
        status = 'already-active'
        workspace_root = $workspace
        changed = $false
        next = 'Use refresh-workspace.ps1 for fact refreshes.'
    } | ConvertTo-Json -Depth 5
    return
}
if ($plan.route -eq 'initializing' -and -not $ResumeInitializing) {
    throw 'Workspace is already initializing. Rerun with -ResumeInitializing only after reviewing the partial state.'
}
if ($plan.route -notin @('new-empty', 'initializing')) {
    throw "init-workspace.ps1 cannot apply route '$($plan.route)'; use the approved migration or refresh flow."
}

$preflight = [Collections.Generic.List[object]]::new()
$preflightWarnings = [Collections.Generic.List[string]]::new()
$payloadJson = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([string]$plan.plan_base64))
$payload = $payloadJson | ConvertFrom-Json -Depth 40 -ErrorAction Stop
foreach ($source in @($payload.source_definitions)) {
    foreach ($mapping in @($source.mappings)) {
        $inventory = Get-EwiFileInventory -Root $mapping.source_path -MappingId $mapping.id
        if (-not $inventory.scan_complete -or @($inventory.git_topology).Count -gt 0) {
            throw "Source '$($mapping.id)' has an incomplete scan."
        }
        if (@($inventory.sensitive).Count -gt 0) {
            throw "Source '$($mapping.id)' contains unresolved sensitive files: $([string]::Join(', ', @($inventory.sensitive)))"
        }
        if (@($inventory.pending).Count -gt 0) {
            throw "Source '$($mapping.id)' contains ambiguous license or activation files: $([string]::Join(', ', @($inventory.pending)))"
        }
        foreach ($warning in @($inventory.warnings)) {
            $preflightWarnings.Add("Source '$($mapping.id)': $warning")
        }
        $preflight.Add([pscustomobject][ordered]@{
            source_id = $source.id
            mapping_id = $mapping.id
            source_path = $mapping.source_path
            integration_subpath = $mapping.integration_subpath
            inventory = $inventory
            digest = Get-EwiInventoryDigest $inventory
        })
    }
}

function Write-ManagedText {
    param(
        [Parameter(Mandatory)] [string] $Destination,
        [Parameter(Mandatory)] [string] $Content,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [Collections.Generic.List[string]] $TrackedFiles
    )

    $parent = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $parent)) {
        $null = New-Item -ItemType Directory -Path $parent
    }
    if (Test-Path -LiteralPath $Destination -PathType Leaf) {
        $existing = Get-Content -LiteralPath $Destination -Raw -Encoding UTF8
        if ($existing.TrimEnd("`r", "`n") -cne $Content.TrimEnd("`r", "`n")) {
            throw "Managed file already exists with different content: $Destination"
        }
    }
    else {
        [IO.File]::WriteAllText($Destination, $Content.TrimEnd("`r", "`n") + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    }
    $relative = [IO.Path]::GetRelativePath($workspace, $Destination).Replace('\', '/')
    if (-not $TrackedFiles.Contains($relative)) { $TrackedFiles.Add($relative) }
}

function Install-ManagedFile {
    param(
        [Parameter(Mandatory)] [string] $Source,
        [Parameter(Mandatory)] [string] $Destination,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [Collections.Generic.List[string]] $TrackedFiles
    )

    $parent = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $parent)) {
        $null = New-Item -ItemType Directory -Path $parent
    }
    if (Test-Path -LiteralPath $Destination -PathType Leaf) {
        if ((Get-EwiSha256 $Source) -ne (Get-EwiSha256 $Destination)) {
            throw "Managed file already exists with different content: $Destination"
        }
    }
    else {
        [IO.File]::WriteAllBytes($Destination, [IO.File]::ReadAllBytes($Source))
    }
    $relative = [IO.Path]::GetRelativePath($workspace, $Destination).Replace('\', '/')
    if (-not $TrackedFiles.Contains($relative)) { $TrackedFiles.Add($relative) }
}

function Get-DirectoryReadme {
    param(
        [Parameter(Mandatory)] [string] $Title,
        [Parameter(Mandatory)] [string] $Purpose,
        [Parameter(Mandatory)] [string] $Owner,
        [Parameter(Mandatory)] [string] $GitStatus,
        [Parameter(Mandatory)] [string] $Cleanup
    )

    $template = Get-Content -LiteralPath (Join-Path $assets 'directory-README.md') -Raw -Encoding UTF8
    return $template.Replace('{{TITLE}}', $Title).Replace('{{PURPOSE}}', $Purpose).
        Replace('{{OWNER}}', $Owner).Replace('{{GIT_STATUS}}', $GitStatus).Replace('{{CLEANUP}}', $Cleanup)
}

function Find-InitialTargets {
    param(
        [Parameter(Mandatory)] [string] $IntegrationRoot,
        [Parameter(Mandatory)] [string] $SourceId,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $MappingInventories,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [Collections.IDictionary] $ExistingTargets
    )

    $markerTypes = [ordered]@{
        '.project' = 'stm32cubeide-or-eclipse'
        '.uvprojx' = 'keil-mdk'
        '.ewp' = 'iar-ew'
        'CMakeLists.txt' = 'cmake'
        'CMakePresets.json' = 'cmake'
        'Makefile' = 'make'
        'platformio.ini' = 'platformio'
        'sdkconfig' = 'esp-idf'
        'west.yml' = 'zephyr'
    }
    $roots = [ordered]@{}
    foreach ($mappingInventory in $MappingInventories) {
        $subpath = [string]$mappingInventory.integration_subpath
        foreach ($entry in @($mappingInventory.inventory.files)) {
            $name = [IO.Path]::GetFileName([string]$entry.path)
            $extension = [IO.Path]::GetExtension($name)
            $type = $null
            if ($markerTypes.Contains($name)) { $type = $markerTypes[$name] }
            elseif ($extension -eq '.uvprojx') { $type = 'keil-mdk' }
            elseif ($extension -eq '.ewp') { $type = 'iar-ew' }
            if ($null -eq $type) { continue }

            $relativeDirectory = [IO.Path]::GetDirectoryName([string]$entry.path)
            if ([string]::IsNullOrWhiteSpace($relativeDirectory)) { $relativeDirectory = '.' }
            $targetPath = if ($subpath -eq '.') {
                $relativeDirectory.Replace('\', '/')
            }
            elseif ($relativeDirectory -eq '.') {
                $subpath
            }
            else {
                "$subpath/$($relativeDirectory.Replace('\', '/'))"
            }
            $targetPath = Assert-EwiRelativePath -Path $targetPath -AllowDot
            if (-not $roots.Contains($targetPath)) {
                $roots[$targetPath] = [pscustomobject][ordered]@{
                    type = $type
                    entry = $name
                    generator = $null
                }
            }
        }
    }

    $results = [Collections.Generic.List[object]]::new()
    foreach ($targetPath in $roots.Keys) {
        $baseName = if ($targetPath -eq '.') { $SourceId } else { [IO.Path]::GetFileName($targetPath) }
        $baseId = ConvertTo-EwiId $baseName
        $targetId = $baseId
        $suffix = 2
        while ($ExistingTargets.Contains($targetId) -or @($results | Where-Object id -eq $targetId).Count -gt 0) {
            $targetId = "$baseId-$suffix"
            $suffix++
        }
        $targetRoot = Join-EwiContainedPath -Root $IntegrationRoot -RelativePath $targetPath -AllowDot
        $generator = @(Get-ChildItem -LiteralPath $targetRoot -Filter '*.ioc' -File -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($generator.Count -gt 0) { $roots[$targetPath].generator = $generator[0].Name }
        $mcu = $null
        if ($generator.Count -gt 0) {
            $mcuLine = Select-String -LiteralPath $generator[0].FullName -Pattern '^Mcu\.(?:Name|CPN)=' -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($null -ne $mcuLine) { $mcu = ($mcuLine.Line -split '=', 2)[1].Trim() }
        }
        $results.Add([pscustomobject][ordered]@{
            id = $targetId
            value = [pscustomobject][ordered]@{
                source = $SourceId
                path = $targetPath
                mcu = $mcu
                project = $roots[$targetPath]
                builds = [ordered]@{}
            }
        })
    }
    return @($results)
}

$result = Invoke-EwiLocked -WorkspaceRoot $workspace -TimeoutSeconds $MutexTimeoutSeconds -ScriptBlock {
    if (Test-Path -LiteralPath $workspace -PathType Leaf) {
        throw "Workspace root is a file: $workspace"
    }
    if (-not (Test-Path -LiteralPath $workspace)) {
        $null = New-Item -ItemType Directory -Path $workspace
    }
    $existingChildren = @(Get-ChildItem -LiteralPath $workspace -Force)
    $existingWorkspaceConfig = Join-Path $workspace 'workspace-management/config/workspace.json'
    if ($existingChildren.Count -gt 0 -and -not (Test-Path -LiteralPath $existingWorkspaceConfig)) {
        throw 'Workspace became nonempty before initialization; no files were claimed.'
    }

    $tracked = [Collections.Generic.List[string]]::new()
    $directories = @(
        'project-docs',
        'project-docs/decisions',
        'project-docs/versions',
        'reference-projects',
        'sources',
        'work',
        'workspace-management',
        'workspace-management/config',
        'workspace-management/guides',
        'workspace-management/schemas',
        'workspace-management/tools',
        'workspace-management/tools/lib',
        'workspace-management/templates',
        'workspace-management/templates/project-docs',
        'workspace-management/sync-state',
        'workspace-management/sync-state/sources',
        'workspace-management/sync-state/indexes',
        'workspace-management/sync-state/transactions',
        'workspace-management/evidence',
        'workspace-management/recovery',
        'workspace-management/migration',
        'workspace-management/history',
        'workspace-management/history/legacy-instructions',
        'workspace-management/ide-workspaces'
    )
    foreach ($relative in $directories) {
        $directory = Join-EwiContainedPath -Root $workspace -RelativePath $relative
        if (-not (Test-Path -LiteralPath $directory)) { $null = New-Item -ItemType Directory -Path $directory }
    }

    Install-ManagedFile -Source (Join-Path $assets 'AGENTS.md') -Destination (Join-Path $workspace 'AGENTS.md') -TrackedFiles $tracked
    Install-ManagedFile -Source (Join-Path $assets 'README.md') -Destination (Join-Path $workspace 'README.md') -TrackedFiles $tracked
    Install-ManagedFile -Source (Join-Path $assets 'USER_GUIDE.md') -Destination (Join-Path $workspace 'USER_GUIDE.md') -TrackedFiles $tracked
    Install-ManagedFile -Source (Join-Path $assets 'gitignore') -Destination (Join-Path $workspace '.gitignore') -TrackedFiles $tracked
    Install-ManagedFile -Source (Join-Path $assets 'project-docs-README.md') -Destination (Join-Path $workspace 'project-docs/README.md') -TrackedFiles $tracked

    $readmes = [ordered]@{
        'project-docs/decisions/README.md' = @('项目决策', '保存经确认且跨任务有效的可追溯决策。', 'Agent management', 'tracked', '只在决策被替代时保留旧文件并链接新决策。')
        'project-docs/versions/README.md' = @('版本边界', '保存经确认的版本目标、范围、完成标准和验证要求。', 'Agent management', 'tracked', '版本文件不可被后续版本覆盖。')
        'reference-projects/README.md' = @('参考工程', '保存简短索引和只读参考快照包装；正文位于各 project/。', 'Agent management wrappers; external reference bodies', 'wrappers tracked; bodies ignored', '只有来源可替代且用户同意时删除快照。')
        'sources/README.md' = @('源组集成副本', '每个源组拥有独立私有 Git 集成副本和可逆映射。', 'source-private Git', 'container tracked; integration ignored by root Git', '不得手工清理有基线或活动 worktree 的源组。')
        'work/README.md' = @('Workstreams', '每个逻辑任务的独立源码 worktree、状态、工具和产物。', 'workstream metadata and source-private Git', 'metadata tracked; source bodies ignored', '任务终态且无未处置成果后按确认规则清理。')
        'workspace-management/README.md' = @('工作区管理', '保存配置、指南、schema、确定性工具、同步状态、证据和恢复数据。', 'Agent management', 'mixed; see child README files', '不得绕过受管脚本删除动态状态。')
        'workspace-management/config/README.md' = @('配置', '保存可移植配置和被忽略的本机路径绑定。', 'Agent management', 'portable JSON tracked; targets.local.json ignored', '只通过受管原子写入更新。')
        'workspace-management/guides/README.md' = @('运行指南', '根 AGENTS.md 按任务类型路由到这些 canonical 指南。', 'Agent management', 'tracked', '由初始化 Skill 按哈希刷新，不维护分叉副本。')
        'workspace-management/schemas/README.md' = @('JSON Schema', '验证全部受管 JSON 状态和证据。', 'Agent management', 'tracked', 'schema 变化必须走受控策略迁移。')
        'workspace-management/tools/README.md' = @('受管工具', '执行路径、Git、同步、workstream、构建和发布机械操作。', 'Agent management', 'tracked', '普通任务不得自行改写管理协议。')
        'workspace-management/templates/README.md' = @('模板', '保存普通 Agent 后续创建真实项目资料时使用的本地模板。', 'Agent management', 'tracked', '模板变化走策略更新，不生成空项目正文。')
        'workspace-management/templates/project-docs/README.md' = @('项目知识模板', '定义产品、方案、路线、决策和版本文档的最小字段。', 'Agent management', 'tracked', '仅复制并填入真实、经确认的内容。')
        'workspace-management/sync-state/README.md' = @('同步状态', '保存源基线、文件索引和发布事务；不创建 workstream 缓存。', 'managed runtime state', 'README tracked; dynamic state ignored', '仅在已验证的导入、发布或恢复操作中更新。')
        'workspace-management/sync-state/sources/README.md' = @('源同步基线', '每个 user-imported 源组的映射摘要、可取回基线和构建基线。', 'managed runtime state', 'README tracked; JSON ignored', '源组移除也必须保留审计或经确认迁移。')
        'workspace-management/sync-state/indexes/README.md' = @('文件索引', '保存完整扫描的 JSONL 文件事实，用于候选变化和三方比较。', 'managed runtime state', 'README tracked; JSONL ignored', '不完整扫描不得替换有效索引。')
        'workspace-management/sync-state/transactions/README.md' = @('发布事务', '保存冻结清单、阶段、前置哈希和恢复状态。', 'managed runtime state', 'README tracked; transactions ignored', '非终态事务处理完成前不得删除。')
        'workspace-management/evidence/README.md' = @('验证证据', '保存结构化证据信封并引用独立原始日志或二进制报告。', 'managed runtime evidence', 'README tracked; evidence bodies ignored', '按审计和保留要求清理，不把正文提交到管理 Git。')
        'workspace-management/recovery/README.md' = @('恢复快照', '保存发布前逐文件快照、清单和回滚验证数据。', 'managed runtime recovery', 'README tracked; snapshots ignored', '事务完成且恢复保留期满足后才可清理。')
        'workspace-management/migration/README.md' = @('迁移记录', '保存实际发生的初始化迁移报告。', 'Agent management', 'tracked when created', '历史报告不可静默改写。')
        'workspace-management/history/README.md' = @('策略历史', '保存已确认的规则迁移记录和旧指令清单。', 'Agent management', 'tracked', '仅供审计；旧规则不再生效。')
        'workspace-management/history/legacy-instructions/README.md' = @('旧指令归档', '逐字节保存迁移前规则及独立 manifest。除非用户要求，否则不要加载。', 'Agent management audit', 'tracked', '不得使用可被 Codex 自动发现的活动规则文件名。')
        'workspace-management/ide-workspaces/README.md' = @('独立 IDE 工作区', '保存 Agent 副本专用 IDE workspace 状态，避免复用用户 IDE 状态。', 'local runtime state', 'README tracked; IDE state ignored', '确认无活动 IDE 使用后可重建。')
    }
    foreach ($relative in $readmes.Keys) {
        $values = $readmes[$relative]
        $content = Get-DirectoryReadme -Title $values[0] -Purpose $values[1] -Owner $values[2] -GitStatus $values[3] -Cleanup $values[4]
        Write-ManagedText -Destination (Join-Path $workspace $relative) -Content $content -TrackedFiles $tracked
    }

    foreach ($guideName in $guideNames) {
        Install-ManagedFile -Source (Join-Path $references $guideName) -Destination (Join-Path $workspace "workspace-management/guides/$guideName") -TrackedFiles $tracked
    }
    foreach ($schemaFile in Get-ChildItem -LiteralPath (Join-Path $assets 'schemas') -Filter '*.json' -File) {
        Install-ManagedFile -Source $schemaFile.FullName -Destination (Join-Path $workspace "workspace-management/schemas/$($schemaFile.Name)") -TrackedFiles $tracked
    }
    foreach ($templateName in @('product.md', 'solution.md', 'roadmap.md', 'decision.md', 'version.md')) {
        Install-ManagedFile -Source (Join-Path $assets $templateName) -Destination (Join-Path $workspace "workspace-management/templates/project-docs/$templateName") -TrackedFiles $tracked
    }
    foreach ($templateName in @(
        'reference-project-README.md',
        'reference-copy-README.md',
        'workstream-README.md',
        'workstream.json',
        'source-sync-state.json',
        'publish-transaction.json',
        'legacy-instructions-manifest.json',
        'initialization-report.md'
    )) {
        Install-ManagedFile -Source (Join-Path $assets $templateName) -Destination (Join-Path $workspace "workspace-management/templates/$templateName") -TrackedFiles $tracked
    }

    $runtimeScripts = @(
        'plan-migration.ps1',
        'preserve-user-changes.ps1',
        'detect-targets.ps1',
        'import-reference.ps1',
        'promote-reference.ps1',
        'create-reference-copy.ps1',
        'import-sources.ps1',
        'add-source.ps1',
        'migrate-source-mappings.ps1',
        'set-user-git.ps1',
        'new-workstream.ps1',
        'update-workstream.ps1',
        'pin-workstream-dependency.ps1',
        'set-build-config.ps1',
        'invoke-build.ps1',
        'publish-workstream.ps1'
    )
    Install-ManagedFile -Source $modulePath -Destination (Join-Path $workspace 'workspace-management/tools/lib/workspace-common.psm1') -TrackedFiles $tracked
    foreach ($scriptName in $runtimeScripts) {
        $sourceScript = Join-Path $PSScriptRoot $scriptName
        if (-not (Test-Path -LiteralPath $sourceScript)) { throw "Required runtime script is missing: $scriptName" }
        Install-ManagedFile -Source $sourceScript -Destination (Join-Path $workspace "workspace-management/tools/$scriptName") -TrackedFiles $tracked
    }

    $workspaceSchema = Join-Path $workspace 'workspace-management/schemas/workspace.schema.json'
    $targetsSchema = Join-Path $workspace 'workspace-management/schemas/targets.schema.json'
    $localSchema = Join-Path $workspace 'workspace-management/schemas/targets-local.schema.json'
    $sourceStateSchema = Join-Path $workspace 'workspace-management/schemas/source-sync-state.schema.json'
    $fileIndexSchema = Join-Path $workspace 'workspace-management/schemas/file-index-record.schema.json'
    $workspaceConfigPath = Join-Path $workspace 'workspace-management/config/workspace.json'
    $targetsPath = Join-Path $workspace 'workspace-management/config/targets.json'
    $localPath = Join-Path $workspace 'workspace-management/config/targets.local.json'
    $now = Get-EwiTimestamp

    if (Test-Path -LiteralPath $workspaceConfigPath) {
        $workspaceConfig = Read-EwiJson -Path $workspaceConfigPath -SchemaPath $workspaceSchema
        if ($workspaceConfig.workspace_state -ne 'initializing') {
            throw "Cannot resume workspace state '$($workspaceConfig.workspace_state)'."
        }
    }
    else {
        $workspaceConfig = [pscustomobject][ordered]@{
            workspace_schema = 1
            policy_version = 1
            workspace_state = 'initializing'
            layout_mode = 'pure'
            managed_root = '.'
            initializer = 'embedded-workspace-init'
            initialized_at = $now
            migration = [pscustomobject][ordered]@{ migrated_from = $null; migrated_at = $null }
        }
        Write-EwiJsonAtomic -Path $workspaceConfigPath -Value $workspaceConfig -SchemaPath $workspaceSchema
    }

    $targets = [ordered]@{ schema = 1; sources = [ordered]@{}; targets = [ordered]@{}; field_metadata = [ordered]@{} }
    $local = [ordered]@{
        schema = 1
        workspace = [ordered]@{ root_path = $workspace.Replace('\', '/'); execution_environment = 'local' }
        sources = [ordered]@{}
        legacy_workspaces = [ordered]@{}
        tools = [ordered]@{}
        hardware = [ordered]@{}
    }
    if (Test-Path -LiteralPath $targetsPath) { $targets = Read-EwiJson -Path $targetsPath -SchemaPath $targetsSchema }
    if (Test-Path -LiteralPath $localPath) { $local = Read-EwiJson -Path $localPath -SchemaPath $localSchema }
    if ((Get-EwiPathIdentity $local.workspace.root_path) -ne (Get-EwiPathIdentity $workspace)) {
        throw 'Existing local configuration belongs to a different real workspace root.'
    }

    $sourceResults = [Collections.Generic.List[object]]::new()
    foreach ($source in @($payload.source_definitions)) {
        $sourceId = [string]$source.id
        $existingSourceNames = if ($targets.sources -is [Collections.IDictionary]) { @($targets.sources.Keys) } else { @($targets.sources.PSObject.Properties | ForEach-Object Name) }
        if ($existingSourceNames -contains $sourceId) {
            throw "Source '$sourceId' already exists in a partial initialization; use refresh or inspect before resuming."
        }
        $integrationRelative = "sources/$sourceId/integration"
        $sourceRoot = Join-Path $workspace "sources/$sourceId"
        $integrationRoot = Join-Path $workspace $integrationRelative
        $null = New-Item -ItemType Directory -Path $sourceRoot -Force
        $null = New-Item -ItemType Directory -Path $integrationRoot -Force
        $sourceReadme = "# Source $sourceId`n`nOrigin: $($source.origin)`n`nIntegration: ``$integrationRelative```n`nThe integration directory is owned by its source-private Git. Develop in workstream linked worktrees, not here. User-backed writes occur only through explicit publish.`n"
        Write-ManagedText -Destination (Join-Path $sourceRoot 'README.md') -Content $sourceReadme -TrackedFiles $tracked

        $portableMappings = [Collections.Generic.List[object]]::new()
        $localMappings = [ordered]@{}
        $indexEntries = [Collections.Generic.List[object]]::new()
        $gitPaths = [Collections.Generic.List[string]]::new()
        $mappingInventories = [Collections.Generic.List[object]]::new()
        foreach ($mapping in @($source.mappings)) {
            $mappingId = [string]$mapping.id
            $subpath = Assert-EwiRelativePath -Path ([string]$mapping.integration_subpath) -AllowDot
            $destination = Join-EwiContainedPath -Root $integrationRoot -RelativePath $subpath -AllowDot
            $copied = Copy-EwiSnapshot -Source ([string]$mapping.source_path) -Destination $destination -MappingId $mappingId
            $currentPreflight = @($preflight | Where-Object mapping_id -eq $mappingId)
            if ($currentPreflight.Count -ne 1 -or (Get-EwiInventoryDigest $copied) -ne $currentPreflight[0].digest) {
                throw "Source '$mappingId' changed after preflight."
            }
            foreach ($entry in @($copied.files)) {
                $indexEntries.Add($entry)
                $gitRelative = if ($subpath -eq '.') { $entry.path } else { "$subpath/$($entry.path)" }
                $gitPaths.Add($gitRelative)
            }
            $portableMappings.Add([pscustomobject][ordered]@{
                mapping_id = $mappingId
                integration_subpath = $subpath
                kind = 'directory'
            })
            $localMappings[$mappingId] = [ordered]@{
                source_path = ([string]$mapping.source_path).Replace('\', '/')
                user_git = [ordered]@{ status = 'deferred'; repository_path = $null }
            }
            $mappingInventories.Add([pscustomobject][ordered]@{
                integration_subpath = $subpath
                inventory = $copied
            })
        }

        $hasUserSource = [string]$source.user_source -eq 'configured'
        $sourceValue = [ordered]@{
            origin = [string]$source.origin
            user_source = [string]$source.user_source
            integration_path = $integrationRelative
            write_policy = if ($hasUserSource) { 'explicit-publish-only' } else { 'workspace-only' }
            sync_strategy = if ($hasUserSource) { 'three-way' } else { 'none' }
            mapping_revision = if ($hasUserSource) { 1 } else { 0 }
            mappings = @($portableMappings)
        }
        if ($targets.sources -is [Collections.IDictionary]) { $targets.sources[$sourceId] = $sourceValue }
        else { $targets.sources | Add-Member -NotePropertyName $sourceId -NotePropertyValue ([pscustomobject]$sourceValue) }
        if ($local.sources -is [Collections.IDictionary]) { $local.sources[$sourceId] = [ordered]@{ mappings = $localMappings } }
        else { $local.sources | Add-Member -NotePropertyName $sourceId -NotePropertyValue ([pscustomobject][ordered]@{ mappings = $localMappings }) }

        $null = Initialize-EwiGitRepository -Repository $integrationRoot
        $commit = if ($gitPaths.Count -gt 0) {
            $baselineMessage = if ($hasUserSource) { 'chore: establish user synchronization baseline' } else { 'chore: establish source baseline' }
            New-EwiGitCommit -Repository $integrationRoot -Message $baselineMessage -RelativePaths @($gitPaths)
        }
        else {
            $existingHead = Invoke-EwiGit -Repository $integrationRoot -ArgumentList @('rev-parse', '--verify', 'HEAD') -AllowFailure
            if ($existingHead.ExitCode -eq 0) { $existingHead.StdOut.Trim() }
            else {
                $null = Invoke-EwiGit -Repository $integrationRoot -ArgumentList @('commit', '--allow-empty', '-m', 'chore: establish source baseline')
                (Invoke-EwiGit -Repository $integrationRoot -ArgumentList @('rev-parse', 'HEAD')).StdOut.Trim()
            }
        }

        $baselineId = if ($hasUserSource) { 'baseline-' + [DateTimeOffset]::Now.ToString('yyyyMMddHHmmssfff') } else { $null }
        $baselineRef = if ($hasUserSource) { "refs/agent/user-baselines/$baselineId" } else { $null }
        if ($hasUserSource) {
            $null = Invoke-EwiGit -Repository $integrationRoot -ArgumentList @('update-ref', $baselineRef, $commit)
        }
        $mappingDigest = if ($hasUserSource) { Get-EwiMappingDigest -Mappings @($portableMappings) -LocalMappings $localMappings } else { Get-EwiTextSha256 (ConvertTo-EwiCanonicalJson @()) }
        $indexRelative = "workspace-management/sync-state/indexes/$sourceId.jsonl"
        Write-EwiJsonLinesAtomic -Path (Join-Path $workspace $indexRelative) -Records @($indexEntries) -SchemaPath $fileIndexSchema
        $sourceState = [ordered]@{
            schema = 1
            source_id = $sourceId
            mapping_revision = $sourceValue.mapping_revision
            mapping_digest = $mappingDigest
            user_baseline_id = $baselineId
            user_baseline_commit = if ($hasUserSource) { $commit } else { $null }
            user_baseline_ref = $baselineRef
            captured_at = Get-EwiTimestamp
            scan_complete = $true
            file_index = "../indexes/$sourceId.jsonl"
            build_baselines = [ordered]@{}
        }
        Write-EwiJsonAtomic -Path (Join-Path $workspace "workspace-management/sync-state/sources/$sourceId.json") -Value $sourceState -SchemaPath $sourceStateSchema

        foreach ($detected in Find-InitialTargets -IntegrationRoot $integrationRoot -SourceId $sourceId -MappingInventories @($mappingInventories) -ExistingTargets $targets.targets) {
            if ($targets.targets -is [Collections.IDictionary]) { $targets.targets[$detected.id] = $detected.value }
            else { $targets.targets | Add-Member -NotePropertyName $detected.id -NotePropertyValue $detected.value }
            $pointer = "/targets/$($detected.id)/project"
            if ($targets.field_metadata -is [Collections.IDictionary]) {
                $targets.field_metadata[$pointer] = [ordered]@{ provenance = 'detected'; verification = 'unverified'; freshness = 'current' }
            }
            else {
                $targets.field_metadata | Add-Member -NotePropertyName $pointer -NotePropertyValue ([pscustomobject][ordered]@{ provenance = 'detected'; verification = 'unverified'; freshness = 'current' })
            }
        }
        $sourceResults.Add([pscustomobject][ordered]@{
            source_id = $sourceId
            files = $indexEntries.Count
            baseline_commit = $commit
            user_baseline_ref = $baselineRef
        })
    }

    Write-EwiJsonAtomic -Path $targetsPath -Value $targets -SchemaPath $targetsSchema
    Write-EwiJsonAtomic -Path $localPath -Value $local -SchemaPath $localSchema
    foreach ($relative in @('workspace-management/config/workspace.json', 'workspace-management/config/targets.json')) {
        if (-not $tracked.Contains($relative)) { $tracked.Add($relative) }
    }

    $null = Initialize-EwiGitRepository -Repository $workspace
    foreach ($guideName in $guideNames) {
        $guide = Join-Path $references $guideName
        $deployed = Join-Path $workspace "workspace-management/guides/$guideName"
        if ((Get-EwiSha256 $guide) -ne (Get-EwiSha256 $deployed)) {
            throw "Canonical guide hash mismatch: $guideName"
        }
    }
    foreach ($required in @('AGENTS.md', 'README.md', 'USER_GUIDE.md', '.gitignore')) {
        if (-not (Test-Path -LiteralPath (Join-Path $workspace $required) -PathType Leaf)) {
            throw "Required root file is missing: $required"
        }
    }
    foreach ($forbidden in @('AGENTS.override.md', '.worktreeinclude')) {
        if (Test-Path -LiteralPath (Join-Path $workspace $forbidden)) {
            throw "Forbidden root file exists: $forbidden"
        }
    }
    $null = Read-EwiJson -Path $targetsPath -SchemaPath $targetsSchema
    $null = Read-EwiJson -Path $localPath -SchemaPath $localSchema
    foreach ($item in $preflight) {
        $current = Get-EwiFileInventory -Root $item.source_path -MappingId $item.mapping_id
        if (-not $current.scan_complete -or @($current.git_topology).Count -gt 0 -or @($current.sensitive).Count -gt 0 -or @($current.pending).Count -gt 0 -or
            (Get-EwiInventoryDigest $current) -ne $item.digest) {
            throw "User source changed during initialization: $($item.source_path)"
        }
    }

    $prepareMessage = if ($LeaveInitializing) { 'chore: prepare embedded Agent workspace migration' } else { 'chore: prepare embedded Agent workspace initialization' }
    $commit = New-EwiGitCommit -Repository $workspace -Message $prepareMessage -RelativePaths @($tracked)
    $prepareCommit = (Invoke-EwiGit -Repository $workspace -ArgumentList @('rev-parse', 'HEAD')).StdOut.Trim()
    $evidenceRelative = $null
    if (-not $LeaveInitializing) {
        try {
            $workspaceConfig.workspace_state = 'active'
            Write-EwiJsonAtomic -Path $workspaceConfigPath -Value $workspaceConfig -SchemaPath $workspaceSchema
            $commit = New-EwiGitCommit -Repository $workspace -Message 'chore: activate embedded Agent workspace' -RelativePaths @('workspace-management/config/workspace.json')
            $evidenceId = New-EwiEvidenceId 'workspace-validation'
            $null = Write-EwiEvidence -WorkspaceRoot $workspace -EvidenceId $evidenceId -Kind 'workspace-validation' `
                -Subject ([pscustomobject][ordered]@{ workspace = $workspace; source_id = $null; target_id = $null; build_id = $null; workstream_id = $null; publish_id = $null; reference_id = $null }) `
                -Result ([pscustomobject][ordered]@{
                    status = 'passed'
                    summary = 'The pure embedded Agent workspace passed initialization validation and was activated.'
                    exit_code = 0
                    details = [pscustomobject][ordered]@{ management_commit = $commit; source_groups = $sourceResults.Count; targets_detected = if ($targets.targets -is [Collections.IDictionary]) { $targets.targets.Count } else { @($targets.targets.PSObject.Properties).Count } }
                }) -Artifacts @()
            $evidenceRelative = "workspace-management/evidence/$evidenceId.json"
        }
        catch {
            $null = Invoke-EwiGit -Repository $workspace -ArgumentList @('reset', '--mixed', $prepareCommit) -AllowFailure
            $workspaceConfig.workspace_state = 'initializing'
            Write-EwiJsonAtomic -Path $workspaceConfigPath -Value $workspaceConfig -SchemaPath $workspaceSchema
            $null = Invoke-EwiGit -Repository $workspace -ArgumentList @('reset', '--', 'workspace-management/config/workspace.json') -AllowFailure
            throw
        }
    }
    else {
        $evidenceId = New-EwiEvidenceId 'workspace-initializing'
        $null = Write-EwiEvidence -WorkspaceRoot $workspace -EvidenceId $evidenceId -Kind 'workspace-validation' `
            -Subject ([pscustomobject][ordered]@{ workspace = $workspace; source_id = $null; target_id = $null; build_id = $null; workstream_id = $null; publish_id = $null; reference_id = $null }) `
            -Result ([pscustomobject][ordered]@{ status = 'passed'; summary = 'The workspace preparation checkpoint was created and intentionally remains initializing.'; exit_code = 0; details = [pscustomobject][ordered]@{ management_commit = $commit } }) -Artifacts @()
        $evidenceRelative = "workspace-management/evidence/$evidenceId.json"
    }
    return [pscustomobject][ordered]@{
        status = if ($LeaveInitializing) { 'initializing' } else { 'active' }
        workspace_root = $workspace
        management_commit = $commit
        source_groups = @($sourceResults)
        targets_detected = if ($targets.targets -is [Collections.IDictionary]) { $targets.targets.Count } else { @($targets.targets.PSObject.Properties).Count }
        user_git = 'deferred'
        build_verification = 'not-run; no verified safe command was established during layout initialization'
        warnings = @($preflightWarnings)
        evidence = $evidenceRelative
    }
}

$result | ConvertTo-Json -Depth 20
