[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'fixture-project-copies.ps1')

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('ewigt-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$assertions = 0

function Assert-True {
    param([Parameter(Mandatory)] [bool] $Condition, [Parameter(Mandatory)] [string] $Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
    $script:assertions++ | Out-Null
}

function Assert-Equal {
    param($Expected, $Actual, [Parameter(Mandatory)] [string] $Message)
    if ($Expected -cne $Actual) { throw "Assertion failed: $Message. Expected '$Expected', actual '$Actual'." }
    $script:assertions++ | Out-Null
}

function Write-Utf8Text {
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [string] $Text)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) { $null = New-Item -ItemType Directory -Path $parent }
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function Get-LocalMapping {
    param([string] $Workspace, [string] $SourceId)
    $local = Get-Content -Raw -LiteralPath (Join-Path $Workspace 'workspace-management\config\targets.local.json') | ConvertFrom-Json -Depth 30
    return $local.sources.PSObject.Properties[$SourceId].Value.mappings.PSObject.Properties[$SourceId].Value
}

function Get-Plan {
    param([string] $Source, [string] $Name)
    (& (Join-Path $PSScriptRoot 'plan-migration.ps1') -WorkspaceRoot (Join-Path $testRoot $Name) -UserSourcePath $Source | Out-String) | ConvertFrom-Json -Depth 30
}

try {
    $source = Join-Path $testRoot 'source'
    $workspace = Join-Path $testRoot 'workspace'
    Write-Utf8Text -Path (Join-Path $source 'Makefile') -Text "all:`r`n"
    Write-Utf8Text -Path (Join-Path $source 'src\main.c') -Text "int main(void) { return 0; }`r`n"
    Write-Utf8Text -Path (Join-Path $source 'Debug\old.o') -Text 'old'
    Write-Utf8Text -Path (Join-Path $source 'out\old.bin') -Text 'old'
    $random = [byte[]]::new(512)
    [Security.Cryptography.RandomNumberGenerator]::Fill($random)
    $null = New-Item -ItemType Directory -Path (Join-Path $source 'lib')
    [IO.File]::WriteAllBytes((Join-Path $source 'lib\firmware.lib'), $random)
    $init = (& (Join-Path $PSScriptRoot 'init-workspace.ps1') -WorkspaceRoot $workspace -UserSourcePath $source | Out-String) | ConvertFrom-Json -Depth 30
    Assert-Equal 'active' $init.status 'the user-Git fixture must initialize'
    $mapping = Get-LocalMapping $workspace 'source'
    Assert-Equal 'deferred' $mapping.user_git.status 'no user response must remain deferred'
    Assert-True ($null -eq $mapping.user_git.repository_path) 'deferred user Git must have no repository path'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $source '.git'))) 'layout initialization must not create user Git'
    Assert-True (Test-Path -LiteralPath (Join-Path $workspace 'sources\source\integration\lib\firmware.lib')) 'high-entropy binary dependencies must not be excluded by entropy alone'

    $enablePlan = (& (Join-Path $PSScriptRoot 'set-user-git.ps1') -WorkspaceRoot $workspace -SourceId source -Decision Enable | Out-String) | ConvertFrom-Json -Depth 20
    Assert-True $enablePlan.can_apply 'a simple authority must permit an explicit user-Git choice'
    Assert-True $enablePlan.would_create_gitignore 'the plan must disclose creation of the needed ignore file'
    Assert-True $enablePlan.would_create_baseline 'the plan must disclose creation of the initial baseline'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $source '.git'))) 'user-Git report mode must write no Git metadata'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $source '.gitignore'))) 'user-Git report mode must write no ignore file'

    $disable = (& (Join-Path $PSScriptRoot 'set-user-git.ps1') -WorkspaceRoot $workspace -SourceId source -Decision Disable -Apply | Out-String) | ConvertFrom-Json -Depth 20
    Assert-Equal 'disabled' $disable.status 'an explicit refusal must be recorded'
    Assert-Equal 'disabled' (Get-LocalMapping $workspace 'source').user_git.status 'the local mapping must persist the disabled choice'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $source '.git'))) 'disabling user Git must not modify the authority'
    Assert-True (Test-Path -LiteralPath (Join-Path $workspace $disable.evidence)) 'the explicit decision must record evidence'

    $enabled = (& (Join-Path $PSScriptRoot 'set-user-git.ps1') -WorkspaceRoot $workspace -SourceId source -Decision Enable -Apply | Out-String) | ConvertFrom-Json -Depth 20
    Assert-Equal 'enabled' $enabled.status 'explicit enable must initialize user Git'
    Assert-True (Test-Path -LiteralPath (Join-Path $source '.git') -PathType Container) 'explicit enable must create user Git metadata'
    Assert-True (Test-Path -LiteralPath (Join-Path $source '.gitignore') -PathType Leaf) 'explicit enable must create the reviewed ignore file'
    Assert-Equal $enabled.baseline_commit ((& git -C $source rev-parse HEAD | Out-String).Trim()) 'the reported user baseline must be the user Git HEAD'
    Assert-Equal '' ((& git -C $source status --short | Out-String).Trim()) 'the initial user Git baseline must be clean'
    Assert-Equal '' ((& git -C $source remote | Out-String).Trim()) 'user Git initialization must configure no push remote'
    Assert-True ((& git -C $source ls-files 'src/main.c' | Out-String).Trim().Length -gt 0) 'reviewed source content must be tracked in the user baseline'
    Assert-True ((& git -C $source ls-files 'lib/firmware.lib' | Out-String).Trim().Length -gt 0) 'required binary content must be tracked in the user baseline'
    Assert-Equal '' ((& git -C $source ls-files 'Debug/old.o' 'out/old.bin' | Out-String).Trim()) 'known caches must stay out of the user baseline'
    $mapping = Get-LocalMapping $workspace 'source'
    Assert-Equal 'enabled' $mapping.user_git.status 'the enabled choice must persist in local state'
    Assert-Equal $source.Replace('\', '/') $mapping.user_git.repository_path 'local state must record the actual user Git root'

    $existing = Join-Path $testRoot 'existing-source'
    $existingWorkspace = Join-Path $testRoot 'existing-workspace'
    Write-Utf8Text -Path (Join-Path $existing 'Makefile') -Text "all:`r`n"
    Write-Utf8Text -Path (Join-Path $existing 'tracked.c') -Text "int tracked = 0;`r`n"
    $null = & git -C $existing init --initial-branch=main
    $null = & git -C $existing config user.name 'Existing User'
    $null = & git -C $existing config user.email 'existing@local.invalid'
    $null = & git -C $existing add --all
    $null = & git -C $existing commit -m baseline
    $existingHead = (& git -C $existing rev-parse HEAD | Out-String).Trim()
    Write-Utf8Text -Path (Join-Path $existing 'tracked.c') -Text "int tracked = 7;`r`n"
    Write-Utf8Text -Path (Join-Path $existing 'untracked.c') -Text "int untracked = 1;`r`n"
    $existingStatus = (& git -C $existing status --short | Out-String).Trim()
    $null = & (Join-Path $PSScriptRoot 'init-workspace.ps1') -WorkspaceRoot $existingWorkspace -UserSourcePath $existing
    $existingIntegration = Join-Path $existingWorkspace 'sources\existing-source\integration'
    Assert-Equal "int tracked = 7;`r`n" ([IO.File]::ReadAllText((Join-Path $existingIntegration 'tracked.c'))) 'saved dirty tracked content must enter the private baseline'
    Assert-True (Test-Path -LiteralPath (Join-Path $existingIntegration 'untracked.c')) 'needed untracked content must enter the private baseline'
    $existingEnable = (& (Join-Path $PSScriptRoot 'set-user-git.ps1') -WorkspaceRoot $existingWorkspace -SourceId existing-source -Decision Enable -Apply | Out-String) | ConvertFrom-Json -Depth 20
    Assert-True $existingEnable.existing_git 'the explicit choice must recognize existing user Git'
    Assert-True ($null -eq $existingEnable.baseline_commit) 'existing user Git must not receive an automatic commit'
    Assert-Equal $existingHead ((& git -C $existing rev-parse HEAD | Out-String).Trim()) 'existing user Git HEAD must remain unchanged'
    Assert-Equal $existingStatus ((& git -C $existing status --short | Out-String).Trim()) 'existing dirty and untracked user state must remain unchanged'

    $outerRepository = Join-Path $testRoot 'outer-user-repository'
    $subdirectoryAuthority = Join-Path $outerRepository 'firmware'
    $subdirectoryWorkspace = Join-Path $testRoot 'subdirectory-workspace'
    Write-Utf8Text -Path (Join-Path $subdirectoryAuthority 'Makefile') -Text "all:`r`n"
    Write-Utf8Text -Path (Join-Path $subdirectoryAuthority 'main.c') -Text "int child = 1;`r`n"
    $null = & git -C $outerRepository init --initial-branch=main
    $null = & git -C $outerRepository config user.name 'Outer User'
    $null = & git -C $outerRepository config user.email 'outer@local.invalid'
    $null = & git -C $outerRepository add --all
    $null = & git -C $outerRepository commit -m baseline
    $outerHead = (& git -C $outerRepository rev-parse HEAD | Out-String).Trim()
    $null = & (Join-Path $PSScriptRoot 'init-workspace.ps1') -WorkspaceRoot $subdirectoryWorkspace -UserSourcePath $subdirectoryAuthority
    $subdirectoryChoice = (& (Join-Path $PSScriptRoot 'set-user-git.ps1') -WorkspaceRoot $subdirectoryWorkspace -SourceId firmware -Decision Enable -Apply | Out-String) | ConvertFrom-Json -Depth 20
    Assert-True $subdirectoryChoice.existing_git 'a mapping inside an existing user repository must detect the outer Git root'
    Assert-Equal $outerRepository $subdirectoryChoice.repository_root 'the existing outer user Git boundary must be preserved'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $subdirectoryAuthority '.git'))) 'the operation must not create a nested Git repository inside the mapping'
    Assert-Equal $outerHead ((& git -C $outerRepository rev-parse HEAD | Out-String).Trim()) 'registering an outer user Git root must not auto-commit it'

    $nested = Join-Path $testRoot 'nested-source'
    Write-Utf8Text -Path (Join-Path $nested 'Makefile') -Text "all:`r`n"
    $nestedRepo = Join-Path $nested 'third-party'
    $null = New-Item -ItemType Directory -Path $nestedRepo
    $null = & git -C $nestedRepo init --initial-branch=main
    $nestedPlan = Get-Plan $nested 'nested-workspace'
    Assert-True (-not $nestedPlan.can_apply) 'nested Git topology must block source import'
    Assert-True (@($nestedPlan.summary.blockers | Where-Object { $_ -like '*nested Git topology*' }).Count -eq 1) 'nested Git topology must be reported'

    $linked = Join-Path $testRoot 'linked-source'
    Write-Utf8Text -Path (Join-Path $linked 'Makefile') -Text "all:`r`n"
    Write-Utf8Text -Path (Join-Path $linked '.git') -Text "gitdir: C:/synthetic/worktree`r`n"
    $linkedPlan = Get-Plan $linked 'linked-workspace'
    Assert-True (-not $linkedPlan.can_apply) 'a linked-worktree .git file must block source import'

    $submodule = Join-Path $testRoot 'submodule-source'
    Write-Utf8Text -Path (Join-Path $submodule 'Makefile') -Text "all:`r`n"
    Write-Utf8Text -Path (Join-Path $submodule '.gitmodules') -Text @'
[submodule "vendor"]
path = vendor
url = https://invalid.local/vendor
'@
    $submodulePlan = Get-Plan $submodule 'submodule-workspace'
    Assert-True (-not $submodulePlan.can_apply) 'submodule metadata must block source flattening'

    $lfs = Join-Path $testRoot 'lfs-source'
    Write-Utf8Text -Path (Join-Path $lfs 'Makefile') -Text "all:`r`n"
    Write-Utf8Text -Path (Join-Path $lfs '.gitattributes') -Text "*.bin filter=lfs diff=lfs merge=lfs -text`r`n"
    $lfsPlan = Get-Plan $lfs 'lfs-workspace'
    Assert-True (-not $lfsPlan.can_apply) 'Git LFS metadata must block unsupported import'

    $agentWorkspace = Join-Path $testRoot 'agent-workspace'
    $agentDefinition = @([ordered]@{ id = 'agent-source'; origin = 'agent-created'; user_source = 'none'; mappings = @() }) | ConvertTo-Json -Depth 10 -Compress
    $agentInit = (& (Join-Path $PSScriptRoot 'init-workspace.ps1') -WorkspaceRoot $agentWorkspace -SourceDefinitionsJson $agentDefinition | Out-String) | ConvertFrom-Json -Depth 30
    Assert-Equal 'active' $agentInit.status 'an agent-created source workspace must initialize'
    $agentTargets = Get-Content -Raw -LiteralPath (Join-Path $agentWorkspace 'workspace-management\config\targets.json') | ConvertFrom-Json -Depth 30
    Assert-Equal 'agent-created' $agentTargets.sources.'agent-source'.origin 'agent-created origin must be explicit'
    Assert-Equal 'none' $agentTargets.sources.'agent-source'.user_source 'agent-created source must have no user authority'
    Assert-Equal 'none' $agentTargets.sources.'agent-source'.sync_strategy 'agent-created source must have no synchronization strategy'
    Assert-Equal 0 @($agentTargets.sources.'agent-source'.mappings).Count 'agent-created source must have empty mappings'
    $agentState = Get-Content -Raw -LiteralPath (Join-Path $agentWorkspace 'workspace-management\sync-state\sources\agent-source.json') | ConvertFrom-Json -Depth 30
    Assert-True ($null -eq $agentState.user_baseline_commit -and $null -eq $agentState.user_baseline_ref) 'agent-created source must not invent a user baseline'
    $agentScope = @([ordered]@{ source_id = 'agent-source'; targets = @(); paths = @([ordered]@{ path = '.'; access = 'write' }) }) | ConvertTo-Json -Depth 10 -Compress
    $agentWorkstream = (& (Join-Path $PSScriptRoot 'new-workstream.ps1') -WorkspaceRoot $agentWorkspace -Title 'Agent source task' -ScopeJson $agentScope | Out-String) | ConvertFrom-Json -Depth 20
    Mount-FixtureProjectCopies -WorkspaceRoot $agentWorkspace -Workstream $agentWorkstream
    $agentManifest = Get-Content -Raw -LiteralPath (Join-Path $agentWorkspace "$($agentWorkstream.path)\workstream.json") | ConvertFrom-Json -Depth 30
    $agentTree = Join-Path $agentWorkspace $agentManifest.agent.refs.'agent-source'.worktree
    Write-Utf8Text -Path (Join-Path $agentTree 'main.c') -Text "int agent = 1;`r`n"
    $null = & git -C $agentTree add -- 'main.c'
    $null = & git -C $agentTree commit -m 'feat: agent source'
    $agentPublish = (& (Join-Path $PSScriptRoot 'publish-workstream.ps1') -WorkspaceRoot $agentWorkspace -WorkstreamId $agentWorkstream.workstream_id | Out-String) | ConvertFrom-Json -Depth 30
    Assert-True (-not $agentPublish.can_apply) 'agent-created sources must never publish to a user authority'
    Assert-True (@($agentPublish.blockers | Where-Object { $_ -like '*Source is not publishable*' }).Count -eq 1) 'agent-created publish refusal must be explicit'
    $agentAuthority = Join-Path $testRoot 'agent-authority'
    Write-Utf8Text -Path (Join-Path $agentAuthority 'Makefile') -Text "all:`r`n"
    Write-Utf8Text -Path (Join-Path $agentAuthority 'main.c') -Text "int authority = 1;`r`n"
    $agentMapping = @([ordered]@{ mapping_id = 'agent-map'; source_path = $agentAuthority; integration_subpath = '.' }) | ConvertTo-Json -Depth 10 -Compress
    $agentMappingPlan = (& (Join-Path $PSScriptRoot 'migrate-source-mappings.ps1') -WorkspaceRoot $agentWorkspace -SourceId agent-source -MappingsJson $agentMapping | Out-String) | ConvertFrom-Json -Depth 30
    Assert-True $agentMappingPlan.can_apply 'an agent-created source may gain authority only through controlled mapping migration'
    $agentMigration = (& (Join-Path $PSScriptRoot 'migrate-source-mappings.ps1') -WorkspaceRoot $agentWorkspace -SourceId agent-source -MappingsJson $agentMapping -ExpectedPlanDigest $agentMappingPlan.plan_digest -Apply | Out-String) | ConvertFrom-Json -Depth 30
    Assert-Equal 'migrated' $agentMigration.status 'the approved agent-source authority mapping must complete'
    $agentTargetsAfter = Get-Content -Raw -LiteralPath (Join-Path $agentWorkspace 'workspace-management\config\targets.json') | ConvertFrom-Json -Depth 30
    Assert-Equal 'agent-created' $agentTargetsAfter.sources.'agent-source'.origin 'authority mapping must preserve agent-created origin'
    Assert-Equal 'configured' $agentTargetsAfter.sources.'agent-source'.user_source 'approved mapping migration must enable configured authority'
    Assert-Equal 'three-way' $agentTargetsAfter.sources.'agent-source'.sync_strategy 'approved authority must enable three-way synchronization'
    Assert-Equal 1 $agentTargetsAfter.sources.'agent-source'.mapping_revision 'first authority mapping must establish revision one'

    [pscustomobject][ordered]@{
        status = 'passed'
        assertions = $assertions
        powershell = $PSVersionTable.PSVersion.ToString()
        git = ((& git --version | Out-String).Trim())
    } | ConvertTo-Json
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        $resolved = (Resolve-Path -LiteralPath $testRoot).Path
        $expectedParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
        if ([IO.Path]::GetDirectoryName($resolved).TrimEnd('\') -ne $expectedParent -or
            -not [IO.Path]::GetFileName($resolved).StartsWith('ewigt-')) {
            throw "Refusing to clean unexpected test path: $resolved"
        }
        Get-ChildItem -LiteralPath $resolved -Recurse -Force | ForEach-Object { $_.Attributes = 'Normal' }
        (Get-Item -LiteralPath $resolved -Force).Attributes = 'Directory'
        [IO.Directory]::Delete($resolved, $true)
    }
}
