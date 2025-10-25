Describe 'Dispatch-VIHistoryWorkflow.ps1' {
  BeforeAll {
    $script:SourceScriptPath = (Resolve-Path (Join-Path $PSScriptRoot '..' 'scripts' 'Dispatch-VIHistoryWorkflow.ps1')).Path
    $script:OriginalLocation = Get-Location
  }

    BeforeEach {
      $script:TestRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString())
      $scriptsDir = Join-Path $script:TestRoot 'scripts'
      New-Item -ItemType Directory -Path $scriptsDir -Force | Out-Null
      Copy-Item -LiteralPath $script:SourceScriptPath -Destination $scriptsDir -Force

    $handoffDir = Join-Path $script:TestRoot 'tests' 'results' '_agent' 'handoff'
    New-Item -ItemType Directory -Path $handoffDir -Force | Out-Null

    Set-Location $script:TestRoot

    function global:git {
      param(
        [Parameter(ValueFromRemainingArguments = $true)]
        [object[]]$Args
      )

      if ($Args.Count -ge 2 -and $Args[0] -eq 'rev-parse' -and $Args[1] -eq '--abbrev-ref') {
        Set-Variable -Name LASTEXITCODE -Scope Global -Value 0
        return 'feature/test'
      }

      Set-Variable -Name LASTEXITCODE -Scope Global -Value 0
      return ''
    }
  }

  AfterEach {
    Remove-Item function:gh -ErrorAction SilentlyContinue
    Remove-Item function:git -ErrorAction SilentlyContinue
    $global:DispatchTest_GhCalls = $null
    $global:DispatchTest_RunListResponses = $null
    $global:DispatchTest_RunListIndex = $null
    Set-Location $script:OriginalLocation
  }

  Context 'gh run metadata capture' {
    It 'captures run id and writes handoff json on success' {
      $global:DispatchTest_GhCalls = New-Object System.Collections.ArrayList
      $runListResponse = @'
[{
  "databaseId": 18805767432,
  "url": "https://example.com/run/18805767432",
  "headBranch": "develop",
  "status": "pending",
  "createdAt": "2025-10-25T16:44:06Z",
  "displayTitle": "Manual VI Compare (refs)"
}]
'@

      function global:gh {
        param(
          [Parameter(ValueFromRemainingArguments = $true)]
          [object[]]$Args
        )
        [void]$global:DispatchTest_GhCalls.Add(@($Args))

        if ($Args[0] -eq 'workflow' -and $Args[1] -eq 'run') {
          Set-Variable -Name LASTEXITCODE -Scope Global -Value 0
          return "workflow dispatched"
        }

        if ($Args[0] -eq 'run' -and $Args[1] -eq 'list') {
          Set-Variable -Name LASTEXITCODE -Scope Global -Value 0
          return $runListResponse
        }

        Set-Variable -Name LASTEXITCODE -Scope Global -Value 0
        return ''
      }

      $scriptPath = Join-Path $script:TestRoot 'scripts' 'Dispatch-VIHistoryWorkflow.ps1'
      & $scriptPath -ViPath 'VI1.vi' -CompareRef 'develop' -NotifyIssue '317'

      $handoffPath = Join-Path $script:TestRoot 'tests' 'results' '_agent' 'handoff' 'vi-history-run.json'
      Test-Path -LiteralPath $handoffPath -PathType Leaf | Should -BeTrue

      $handoff = Get-Content -LiteralPath $handoffPath -Raw | ConvertFrom-Json -Depth 6
      $handoff.schema | Should -Be 'vi-history/dispatch@v1'
      $handoff.workflow | Should -Be 'vi-compare-refs.yml'
      $handoff.inputs.viPath | Should -Be 'VI1.vi'
      $handoff.inputs.compareRef | Should -Be 'develop'
      $handoff.run.id | Should -Be 18805767432
      $handoff.run.url | Should -Be 'https://example.com/run/18805767432'

      $runListCalls = $global:DispatchTest_GhCalls | Where-Object { $_[0] -eq 'run' -and $_[1] -eq 'list' }
      $runListCalls.Count | Should -BeGreaterThan 0
    }

    It 'retries run list until metadata appears' {
      $global:DispatchTest_GhCalls = New-Object System.Collections.ArrayList
      $global:DispatchTest_RunListResponses = @('', '[]', @'
[{
  "databaseId": 123,
  "url": "https://example.com/run/123",
  "headBranch": "feature/branch",
  "status": "completed",
  "createdAt": "2025-10-25T16:50:00Z",
  "displayTitle": "Manual VI Compare (refs)"
}]
'@)
      $global:DispatchTest_RunListIndex = 0

      function global:gh {
        param(
          [Parameter(ValueFromRemainingArguments = $true)]
          [object[]]$Args
        )
        [void]$global:DispatchTest_GhCalls.Add(@($Args))

        if ($Args[0] -eq 'workflow' -and $Args[1] -eq 'run') {
          Set-Variable -Name LASTEXITCODE -Scope Global -Value 0
          return "workflow dispatched"
        }

        if ($Args[0] -eq 'run' -and $Args[1] -eq 'list') {
          $index = $global:DispatchTest_RunListIndex
          if ($index -ge $global:DispatchTest_RunListResponses.Count) {
            $index = $global:DispatchTest_RunListResponses.Count - 1
          }
          $response = $global:DispatchTest_RunListResponses[$index]
          $global:DispatchTest_RunListIndex++
          Set-Variable -Name LASTEXITCODE -Scope Global -Value 0
          return $response
        }

        Set-Variable -Name LASTEXITCODE -Scope Global -Value 0
        return ''
      }

      $scriptPath = Join-Path $script:TestRoot 'scripts' 'Dispatch-VIHistoryWorkflow.ps1'
      & $scriptPath -ViPath 'Sample.vi' -CompareRef 'feature/branch' -NotifyIssue '999'

      $handoffPath = Join-Path $script:TestRoot 'tests' 'results' '_agent' 'handoff' 'vi-history-run.json'
      Test-Path -LiteralPath $handoffPath -PathType Leaf | Should -BeTrue

      $handoff = Get-Content -LiteralPath $handoffPath -Raw | ConvertFrom-Json -Depth 6
      $handoff.inputs.compareRef | Should -Be 'feature/branch'
      $handoff.run.id | Should -Be 123
      $handoff.run.status | Should -Be 'completed'

      $runListCalls = $global:DispatchTest_GhCalls | Where-Object { $_[0] -eq 'run' -and $_[1] -eq 'list' }
      $runListCalls.Count | Should -Be 3
    }

    It 'falls back without writing metadata when run list stays empty' {
      $global:DispatchTest_GhCalls = New-Object System.Collections.ArrayList

      function global:gh {
        param(
          [Parameter(ValueFromRemainingArguments = $true)]
          [object[]]$Args
        )
        [void]$global:DispatchTest_GhCalls.Add(@($Args))

        if ($Args[0] -eq 'workflow' -and $Args[1] -eq 'run') {
          Set-Variable -Name LASTEXITCODE -Scope Global -Value 0
          return "workflow dispatched"
        }

        if ($Args[0] -eq 'run' -and $Args[1] -eq 'list') {
          Set-Variable -Name LASTEXITCODE -Scope Global -Value 0
          return ''
        }

        Set-Variable -Name LASTEXITCODE -Scope Global -Value 0
        return ''
      }

      $scriptPath = Join-Path $script:TestRoot 'scripts' 'Dispatch-VIHistoryWorkflow.ps1'
      & $scriptPath -ViPath 'Missing.vi' -CompareRef '' -NotifyIssue ''

      $handoffPath = Join-Path $script:TestRoot 'tests' 'results' '_agent' 'handoff' 'vi-history-run.json'
      Test-Path -LiteralPath $handoffPath -PathType Leaf | Should -BeFalse

      $runListCalls = $global:DispatchTest_GhCalls | Where-Object { $_[0] -eq 'run' -and $_[1] -eq 'list' }
      $runListCalls.Count | Should -Be 3
    }
  }
}
