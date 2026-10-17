[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'fixture-project-copies.ps1')

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('ewiiw-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
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

function Assert-Throws {
    param([Parameter(Mandatory)] [scriptblock] $Action, [Parameter(Mandatory)] [string] $Pattern)
    try { & $Action }
    catch {
        if ($_.Exception.Message -notlike "*$Pattern*") { throw }
        $script:assertions++ | Out-Null
        return
    }
    throw "Assertion failed: expected an error containing '$Pattern'."
}

function Write-Utf8Text {
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [string] $Text)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) { $null = New-Item -ItemType Directory -Path $parent }
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function New-Fixture {
    param([Parameter(Mandatory)] [string] $Name)
    $base = Join-Path $testRoot $Name
    $source = Join-Path $base 'source'
    $workspace = Join-Path $base 'workspace'
    Write-Utf8Text -Path (Join-Path $source 'Makefile') -Text "all:`r`n`t@echo synthetic`r`n"
    Write-Utf8Text -Path (Join-Path $source 'app\a.c') -Text "line-a-1`r`nline-a-2`r`nline-a-3`r`n"
    Write-Utf8Text -Path (Join-Path $source 'app\b.c') -Text "line-b-1`r`nline-b-2`r`n"
    Write-Utf8Text -Path (Join-Path $source 'app\user.c') -Text "user-0`r`n"
    $init = (& (Join-Path $PSScriptRoot 'init-workspace.ps1') -WorkspaceRoot $workspace -UserSourcePath $source | Out-String) | ConvertFrom-Json -Depth 30
    if ($init.status -ne 'active') { throw "Fixture failed to initialize: $Name" }
    $targets = Get-Content -Raw -LiteralPath (Join-Path $workspace 'workspace-management\config\targets.json') | ConvertFrom-Json -Depth 30
    return [pscustomobject][ordered]@{
        source = $source
        workspace = $workspace
        target_id = @($targets.targets.PSObject.Properties.Name)[0]
        integration = Join-Path $workspace 'sources\source\integration'
    }
}

function New-Workstream {
    param($Fixture, [string] $Title, [string] $Path, [string] $Access = 'write')
    $scope = @([ordered]@{ source_id = 'source'; targets = @($Fixture.target_id); paths = @([ordered]@{ path = $Path; access = $Access }) }) | ConvertTo-Json -Depth 10 -Compress
    $created = (& (Join-Path $PSScriptRoot 'new-workstream.ps1') -WorkspaceRoot $Fixture.workspace -Title $Title -ScopeJson $scope | Out-String) | ConvertFrom-Json -Depth 30
    Mount-FixtureProjectCopies -WorkspaceRoot $Fixture.workspace -Workstream $created
    if ($created.status -ne 'created') { return $created }
    $manifestPath = Join-Path $Fixture.workspace "$($created.path)\workstream.json"
    $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json -Depth 30
    return [pscustomobject][ordered]@{
        status = $created.status
        id = $created.workstream_id
        path = $created.path
        manifest_path = $manifestPath
        worktree = Join-Path $Fixture.workspace $manifest.agent.refs.source.worktree
    }
}

function Commit-File {
    param($Workstream, [string] $Path, [string] $Text)
    Write-Utf8Text -Path (Join-Path $Workstream.worktree $Path) -Text $Text
    $null = & git -C $Workstream.worktree add -- $Path
    $null = & git -C $Workstream.worktree commit -m "feat: change $Path"
}

function Get-SourceState {
    param($Fixture)
    Get-Content -Raw -LiteralPath (Join-Path $Fixture.workspace 'workspace-management\sync-state\sources\source.json') | ConvertFrom-Json -Depth 30
}

try {
    $parallel = New-Fixture 'parallel'
    $first = New-Workstream $parallel 'First stream' 'app/a.c'
    $second = New-Workstream $parallel 'Second stream' 'app/b.c'
    Assert-Equal 'created' $first.status 'the first disjoint workstream must be created'
    Assert-Equal 'created' $second.status 'the second disjoint workstream must be created'
    Assert-True ($first.worktree -ne $second.worktree) 'parallel workstreams must use different physical worktrees'
    Assert-True ($first.worktree -like '*\work\*\sources\source') 'a workstream source must use the fixed linked-worktree path'
    $firstManifest = Get-Content -Raw -LiteralPath $first.manifest_path | ConvertFrom-Json -Depth 30
    Assert-True ($null -eq $firstManifest.conversation.primary) 'workstream creation must not require a conversation id'
    Assert-True ($firstManifest.PSObject.Properties.Name -contains 'scope' -and $firstManifest.PSObject.Properties.Name -contains 'agent') 'workstream.json must own scope and Git baselines'
    $readme = Get-Content -Raw -LiteralPath (Join-Path $parallel.workspace "$($first.path)\README.md")
    Assert-True (-not $readme.Contains('task_base_commit')) 'the handoff README must not duplicate machine Git baseline facts'

    Commit-File $first 'app/a.c' "line-a-task`r`nline-a-2`r`nline-a-3`r`n"
    Commit-File $second 'app/b.c' "line-b-task`r`nline-b-2`r`n"
    $overlap = New-Workstream $parallel 'Overlap stream' 'app/a.c'
    Assert-Equal 'scope-conflict' $overlap.status 'overlapping write scope must be reported'
    $reader = New-Workstream $parallel 'Read stream' 'app/a.c' 'read'
    Assert-Equal 'created' $reader.status 'a read scope may coexist with a writer'
    $reuse = (& (Join-Path $PSScriptRoot 'new-workstream.ps1') -WorkspaceRoot $parallel.workspace -ReuseWorkstreamId $first.id | Out-String) | ConvertFrom-Json
    Assert-Equal 'reused' $reuse.status 'an explicit unique continuation must reuse the workstream'

    Write-Utf8Text -Path (Join-Path $parallel.source 'app\user.c') -Text "user-1`r`n"
    $importPlan = (& (Join-Path $PSScriptRoot 'import-sources.ps1') -WorkspaceRoot $parallel.workspace -SourceId source | Out-String) | ConvertFrom-Json -Depth 40
    Assert-True $importPlan.can_apply 'a user change outside active task paths must be importable'
    Assert-Equal 1 @($importPlan.changes).Count 'the import plan must contain the saved user change'
    $oldBaseline = (Get-SourceState $parallel).user_baseline_commit
    $import = (& (Join-Path $PSScriptRoot 'import-sources.ps1') -WorkspaceRoot $parallel.workspace -SourceId source -Apply | Out-String) | ConvertFrom-Json -Depth 40
    Assert-Equal 'imported' $import.status 'saved user changes must import'
    Assert-Equal 3 @($import.workstreams_rebased).Count 'all active source workstreams, including a reader, must rebase'
    Assert-True ($import.user_baseline_commit -ne $oldBaseline) 'import must create a new retrievable user baseline'
    Assert-Equal $import.user_baseline_commit ((& git -C $parallel.integration rev-parse $import.user_baseline_ref | Out-String).Trim()) 'the imported baseline ref must resolve to its commit'
    Assert-True (Test-Path -LiteralPath (Join-Path $parallel.workspace $import.evidence)) 'a mutating source import must record evidence'
    foreach ($workstream in @($first, $second, $reader)) {
        $manifest = Get-Content -Raw -LiteralPath $workstream.manifest_path | ConvertFrom-Json -Depth 30
        Assert-Equal $import.user_baseline_commit $manifest.agent.refs.source.user_baseline_commit 'each workstream must record the new user baseline'
        Assert-Equal $import.user_baseline_commit $manifest.agent.refs.source.task_base_commit 'each workstream task base must move to the imported baseline'
        Assert-Equal "user-1`r`n" ([IO.File]::ReadAllText((Join-Path $workstream.worktree 'app\user.c'))) 'each worktree must contain the imported user content'
    }
    $firstDiff = (& git -C $first.worktree diff --name-only "$($import.user_baseline_commit)..HEAD" | Out-String).Trim()
    $secondDiff = (& git -C $second.worktree diff --name-only "$($import.user_baseline_commit)..HEAD" | Out-String).Trim()
    Assert-Equal 'app/a.c' $firstDiff 'user-originated content must not remain in the first task diff'
    Assert-Equal 'app/b.c' $secondDiff 'user-originated content must not remain in the second task diff'

    Write-Utf8Text -Path (Join-Path $second.worktree 'app\local-uncommitted.c') -Text "dirty`r`n"
    Write-Utf8Text -Path (Join-Path $parallel.source 'app\new-user.c') -Text "new user`r`n"
    $dirtyPlan = (& (Join-Path $PSScriptRoot 'import-sources.ps1') -WorkspaceRoot $parallel.workspace -SourceId source | Out-String) | ConvertFrom-Json -Depth 40
    Assert-True (-not $dirtyPlan.can_apply) 'an uncommitted workstream must block import replay'
    Assert-True (@($dirtyPlan.blockers | Where-Object { $_ -like '*uncommitted changes*' }).Count -eq 1) 'the dirty workstream blocker must be explicit'

    $merge = New-Fixture 'merge'
    $mergeWorkstream = New-Workstream $merge 'Merge stream' 'app/a.c'
    Commit-File $mergeWorkstream 'app/a.c' "line-a-task`r`nline-a-2`r`nline-a-3`r`n"
    Write-Utf8Text -Path (Join-Path $merge.source 'app\a.c') -Text "line-a-1`r`nline-a-2`r`nline-a-user`r`n"
    $mergePlan = (& (Join-Path $PSScriptRoot 'import-sources.ps1') -WorkspaceRoot $merge.workspace -SourceId source | Out-String) | ConvertFrom-Json -Depth 40
    Assert-True $mergePlan.can_apply 'different text regions in one file must proceed to three-way replay'
    $mergeResult = (& (Join-Path $PSScriptRoot 'import-sources.ps1') -WorkspaceRoot $merge.workspace -SourceId source -Apply | Out-String) | ConvertFrom-Json -Depth 40
    Assert-Equal 'imported' $mergeResult.status 'different text regions must merge during rebase'
    $mergedText = [IO.File]::ReadAllText((Join-Path $mergeWorkstream.worktree 'app\a.c'))
    Assert-True ($mergedText.Contains('line-a-task') -and $mergedText.Contains('line-a-user')) 'the rebased task must contain both nonoverlapping edits'

    $conflict = New-Fixture 'conflict'
    $conflictWorkstream = New-Workstream $conflict 'Conflict stream' 'app/a.c'
    Commit-File $conflictWorkstream 'app/a.c' "line-a-task`r`nline-a-2`r`nline-a-3`r`n"
    Write-Utf8Text -Path (Join-Path $conflict.source 'app\a.c') -Text "line-a-user`r`nline-a-2`r`nline-a-3`r`n"
    $conflictStateBefore = Get-SourceState $conflict
    $conflictWorktreeHead = (& git -C $conflictWorkstream.worktree rev-parse HEAD | Out-String).Trim()
    Assert-Throws -Pattern 'Process failed' -Action {
        & (Join-Path $PSScriptRoot 'import-sources.ps1') -WorkspaceRoot $conflict.workspace -SourceId source -Apply | Out-Null
    }
    Assert-Equal $conflictStateBefore.user_baseline_commit (Get-SourceState $conflict).user_baseline_commit 'a rebase conflict must preserve the user baseline'
    Assert-Equal $conflictStateBefore.user_baseline_commit ((& git -C $conflict.integration rev-parse HEAD | Out-String).Trim()) 'a rebase conflict must restore integration HEAD'
    Assert-Equal $conflictWorktreeHead ((& git -C $conflictWorkstream.worktree rev-parse HEAD | Out-String).Trim()) 'a rebase conflict must restore the task head'
    Assert-Equal '' ((& git -C $conflictWorkstream.worktree status --short | Out-String).Trim()) 'a rebase conflict must leave no unresolved worktree state'

    $dependencyFixture = New-Fixture 'dependency'
    $dependency = New-Workstream $dependencyFixture 'Dependency stream' 'app/a.c'
    $consumer = New-Workstream $dependencyFixture 'Consumer stream' 'app/b.c'
    Commit-File $dependency 'app/a.c' "line-a-dependency-1`r`nline-a-2`r`nline-a-3`r`n"
    $pinPlan = (& (Join-Path $PSScriptRoot 'pin-workstream-dependency.ps1') -WorkspaceRoot $dependencyFixture.workspace -WorkstreamId $consumer.id -DependencyWorkstreamId $dependency.id | Out-String) | ConvertFrom-Json -Depth 30
    Assert-True $pinPlan.can_apply 'a clean consumer must be able to pin a concrete dependency head'
    $pin = (& (Join-Path $PSScriptRoot 'pin-workstream-dependency.ps1') -WorkspaceRoot $dependencyFixture.workspace -WorkstreamId $consumer.id -DependencyWorkstreamId $dependency.id -Apply | Out-String) | ConvertFrom-Json -Depth 30
    Assert-Equal 'pinned' $pin.status 'the dependency must be pinned'
    $firstPinnedHead = $pin.refs.source.head_commit
    $consumerManifest = Get-Content -Raw -LiteralPath $consumer.manifest_path | ConvertFrom-Json -Depth 30
    Assert-Equal $firstPinnedHead $consumerManifest.dependencies[0].refs.source.head_commit 'the machine manifest must store the exact dependency head'
    $null = & git -C $consumer.worktree merge-base --is-ancestor $firstPinnedHead $consumerManifest.agent.refs.source.task_base_commit
    Assert-Equal 0 $LASTEXITCODE 'the pinned head must be contained in the consumer task base'

    Commit-File $dependency 'app/a.c' "line-a-dependency-2`r`nline-a-2`r`nline-a-3`r`n"
    $consumerManifest = Get-Content -Raw -LiteralPath $consumer.manifest_path | ConvertFrom-Json -Depth 30
    Assert-Equal $firstPinnedHead $consumerManifest.dependencies[0].refs.source.head_commit 'a later dependency commit must not move the pinned record automatically'
    $movingPlan = (& (Join-Path $PSScriptRoot 'publish-workstream.ps1') -WorkspaceRoot $dependencyFixture.workspace -WorkstreamId $consumer.id | Out-String) | ConvertFrom-Json -Depth 30
    Assert-True (@($movingPlan.blockers | Where-Object { $_ -like '*Another active or unresolved workstream*' }).Count -eq 1) 'a dependency that moved past its pin must block publish'
    $repin = (& (Join-Path $PSScriptRoot 'pin-workstream-dependency.ps1') -WorkspaceRoot $dependencyFixture.workspace -WorkstreamId $consumer.id -DependencyWorkstreamId $dependency.id -Apply | Out-String) | ConvertFrom-Json -Depth 30
    Assert-True $repin.repinned 'the same command must explicitly repin a moved dependency'
    Assert-True ($repin.refs.source.head_commit -ne $firstPinnedHead) 'repin must record the new concrete dependency head'

    $cycle = (& (Join-Path $PSScriptRoot 'pin-workstream-dependency.ps1') -WorkspaceRoot $dependencyFixture.workspace -WorkstreamId $dependency.id -DependencyWorkstreamId $consumer.id | Out-String) | ConvertFrom-Json -Depth 30
    Assert-True (-not $cycle.can_apply) 'a dependency cycle must be rejected'
    Assert-True (@($cycle.blockers | Where-Object { $_ -like '*create a cycle*' }).Count -eq 1) 'cycle rejection must be explicit'

    Commit-File $consumer 'app/b.c' "line-b-consumer`r`nline-b-2`r`n"
    $lateRepin = (& (Join-Path $PSScriptRoot 'pin-workstream-dependency.ps1') -WorkspaceRoot $dependencyFixture.workspace -WorkstreamId $consumer.id -DependencyWorkstreamId $dependency.id | Out-String) | ConvertFrom-Json -Depth 30
    Assert-True (-not $lateRepin.can_apply) 'a consumer with task commits must not rebuild its dependency base'
    Assert-True (@($lateRepin.blockers | Where-Object { $_ -like '*pin dependencies before task development*' }).Count -eq 1) 'late pinning must explain the task-base boundary'

    $dependencyPublish = (& (Join-Path $PSScriptRoot 'publish-workstream.ps1') -WorkspaceRoot $dependencyFixture.workspace -WorkstreamId $consumer.id | Out-String) | ConvertFrom-Json -Depth 40
    Assert-True $dependencyPublish.can_apply 'a consumer must publish with an unchanged pinned dependency'
    Assert-Equal 'app/a.c,app/b.c' ((@($dependencyPublish.files.relative_path | Sort-Object)) -join ',') 'publish must contain only consumer changes and the pinned dependency closure'
    $dependencyResult = (& (Join-Path $PSScriptRoot 'publish-workstream.ps1') -WorkspaceRoot $dependencyFixture.workspace -WorkstreamId $consumer.id -ExpectedManifestDigest $dependencyPublish.manifest_digest -Apply | Out-String) | ConvertFrom-Json -Depth 40
    Assert-Equal 'completed' $dependencyResult.status 'the pinned dependency closure must publish successfully'
    Assert-True ([IO.File]::ReadAllText((Join-Path $dependencyFixture.source 'app\a.c')).Contains('dependency-2')) 'the pinned dependency content must reach user authority'
    Assert-True ([IO.File]::ReadAllText((Join-Path $dependencyFixture.source 'app\b.c')).Contains('consumer')) 'the consumer content must reach user authority'

    $transitive = New-Fixture 'transitive-dependency'
    $upstream = New-Workstream $transitive 'Upstream stream' 'app/a.c'
    $middle = New-Workstream $transitive 'Middle stream' 'app/b.c'
    $leaf = New-Workstream $transitive 'Leaf stream' 'app/user.c'
    Commit-File $upstream 'app/a.c' "line-a-upstream`r`nline-a-2`r`nline-a-3`r`n"
    $null = & (Join-Path $PSScriptRoot 'pin-workstream-dependency.ps1') -WorkspaceRoot $transitive.workspace -WorkstreamId $middle.id -DependencyWorkstreamId $upstream.id -Apply
    Commit-File $middle 'app/b.c' "line-b-middle`r`nline-b-2`r`n"
    $null = & (Join-Path $PSScriptRoot 'pin-workstream-dependency.ps1') -WorkspaceRoot $transitive.workspace -WorkstreamId $leaf.id -DependencyWorkstreamId $middle.id -Apply
    $leafManifest = Get-Content -Raw -LiteralPath $leaf.manifest_path | ConvertFrom-Json -Depth 30
    Assert-Equal 2 @($leafManifest.dependencies).Count 'pinning a dependency must snapshot its transitive dependency closure'
    Assert-Equal (($middle.id, $upstream.id | Sort-Object) -join ',') ((@($leafManifest.dependencies.workstream_id | Sort-Object)) -join ',') 'the flattened closure must retain the direct and transitive dependency IDs'
    Commit-File $leaf 'app/user.c' "leaf-consumer`r`n"
    $transitivePlan = (& (Join-Path $PSScriptRoot 'publish-workstream.ps1') -WorkspaceRoot $transitive.workspace -WorkstreamId $leaf.id | Out-String) | ConvertFrom-Json -Depth 40
    Assert-True $transitivePlan.can_apply 'a complete pinned transitive dependency closure must be publishable'
    Assert-Equal 'app/a.c,app/b.c,app/user.c' ((@($transitivePlan.files.relative_path | Sort-Object)) -join ',') 'publish must include changes from every level of the pinned dependency closure'
    $transitiveResult = (& (Join-Path $PSScriptRoot 'publish-workstream.ps1') -WorkspaceRoot $transitive.workspace -WorkstreamId $leaf.id -ExpectedManifestDigest $transitivePlan.manifest_digest -Apply | Out-String) | ConvertFrom-Json -Depth 40
    Assert-Equal 'completed' $transitiveResult.status 'the transitive dependency closure must publish successfully'
    Assert-True ([IO.File]::ReadAllText((Join-Path $transitive.source 'app\a.c')).Contains('upstream')) 'the transitive upstream content must reach user authority'
    Assert-True ([IO.File]::ReadAllText((Join-Path $transitive.source 'app\b.c')).Contains('middle')) 'the direct dependency content must reach user authority'
    Assert-True ([IO.File]::ReadAllText((Join-Path $transitive.source 'app\user.c')).Contains('leaf-consumer')) 'the leaf content must reach user authority'

    $lifecycle = New-Fixture 'lifecycle'
    $owner = New-Workstream $lifecycle 'Lifecycle owner' 'app/a.c'
    $neighbor = New-Workstream $lifecycle 'Lifecycle neighbor' 'app/b.c'
    $expandedScope = @([ordered]@{ source_id = 'source'; targets = @($lifecycle.target_id); paths = @([ordered]@{ path = '.'; access = 'write' }) }) | ConvertTo-Json -Depth 10 -Compress
    $expansion = (& (Join-Path $PSScriptRoot 'update-workstream.ps1') -WorkspaceRoot $lifecycle.workspace -WorkstreamId $neighbor.id -ScopeJson $expandedScope | Out-String) | ConvertFrom-Json -Depth 20
    Assert-Equal 'scope-conflict' $expansion.status 'scope expansion must recheck other active writers'
    $terminal = (& (Join-Path $PSScriptRoot 'update-workstream.ps1') -WorkspaceRoot $lifecycle.workspace -WorkstreamId $owner.id -Status completed -HasUnresolvedChanges $true | Out-String) | ConvertFrom-Json -Depth 20
    Assert-Equal 'updated' $terminal.status 'the managed lifecycle operation must update terminal state'
    $stillBlocked = New-Workstream $lifecycle 'Still blocked' 'app/a.c'
    Assert-Equal 'scope-conflict' $stillBlocked.status 'a terminal workstream with unresolved changes must retain write ownership'
    $released = (& (Join-Path $PSScriptRoot 'update-workstream.ps1') -WorkspaceRoot $lifecycle.workspace -WorkstreamId $owner.id -Status completed -HasUnresolvedChanges $false | Out-String) | ConvertFrom-Json -Depth 20
    Assert-Equal 'updated' $released.status 'clearing unresolved state must be recorded'
    $newOwner = New-Workstream $lifecycle 'New owner' 'app/a.c'
    Assert-Equal 'created' $newOwner.status 'a clean terminal workstream must release conflict ownership'

    $invalidIndex = New-Fixture 'invalid-index'
    $invalidIndexWorkstream = New-Workstream $invalidIndex 'Invalid index task' 'app/a.c'
    $invalidState = Get-SourceState $invalidIndex
    $invalidIndexPath = Join-Path $invalidIndex.workspace "workspace-management\sync-state\sources\$($invalidState.file_index)"
    $invalidLines = @([IO.File]::ReadAllLines($invalidIndexPath))
    $invalidRecord = $invalidLines[0] | ConvertFrom-Json -Depth 20
    $invalidRecord.type = 'directory'
    $invalidLines[0] = $invalidRecord | ConvertTo-Json -Depth 20 -Compress
    [IO.File]::WriteAllLines($invalidIndexPath, $invalidLines, [Text.UTF8Encoding]::new($false))
    Assert-Throws -Pattern 'schema' -Action {
        & (Join-Path $PSScriptRoot 'import-sources.ps1') -WorkspaceRoot $invalidIndex.workspace -SourceId source | Out-Null
    }
    Assert-Throws -Pattern 'schema' -Action {
        & (Join-Path $PSScriptRoot 'publish-workstream.ps1') -WorkspaceRoot $invalidIndex.workspace -WorkstreamId $invalidIndexWorkstream.id | Out-Null
    }

    $aggregate = New-Fixture 'aggregate'
    $aggregateTask = New-Workstream $aggregate 'Aggregate task' 'app/a.c'
    Commit-File $aggregateTask 'app/a.c' "line-a-task`r`nline-a-2`r`nline-a-3`r`n"
    Write-Utf8Text -Path (Join-Path $aggregate.integration 'app\b.c') -Text "aggregate-only`r`n"
    $aggregatePlan = (& (Join-Path $PSScriptRoot 'publish-workstream.ps1') -WorkspaceRoot $aggregate.workspace -WorkstreamId $aggregateTask.id | Out-String) | ConvertFrom-Json -Depth 30
    Assert-True (-not $aggregatePlan.can_apply) 'a dirty integration aggregate must not supply publish content'
    Assert-True (@($aggregatePlan.blockers | Where-Object { $_ -like '*not a clean pure user baseline*' }).Count -eq 1) 'integration aggregate rejection must be explicit'
    $null = & git -C $aggregate.integration reset --hard HEAD
    $cleanAggregatePlan = (& (Join-Path $PSScriptRoot 'publish-workstream.ps1') -WorkspaceRoot $aggregate.workspace -WorkstreamId $aggregateTask.id | Out-String) | ConvertFrom-Json -Depth 30
    Assert-Equal 1 @($cleanAggregatePlan.files).Count 'only the task worktree difference may appear after the aggregate is reset'
    Assert-Equal 'app/a.c' $cleanAggregatePlan.files[0].relative_path 'integration-only changes must never enter the publish manifest'

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
            -not [IO.Path]::GetFileName($resolved).StartsWith('ewiiw-')) {
            throw "Refusing to clean unexpected test path: $resolved"
        }
        Get-ChildItem -LiteralPath $resolved -Recurse -Force | ForEach-Object { $_.Attributes = 'Normal' }
        (Get-Item -LiteralPath $resolved -Force).Attributes = 'Directory'
        [IO.Directory]::Delete($resolved, $true)
    }
}
