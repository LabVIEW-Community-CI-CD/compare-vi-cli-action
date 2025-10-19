Describe 'Expected environment variables (policy)' -Tag 'Unit' {
  BeforeAll {
    $script:saved = @{}
    foreach($n in 'DETECT_LEAKS','CLEAN_AFTER','UNBLOCK_GUARD','LV_SUPPRESS_UI','WATCH_CONSOLE','INVOKER_REQUIRED','LABVIEW_EXE'){
      $item = Get-Item -Path Env:$n -ErrorAction SilentlyContinue
      $script:saved[$n] = if ($item) { $item.Value } else { $null }
      Remove-Item Env:$n -ErrorAction SilentlyContinue
    }
  }
  AfterAll {
    foreach($k in $script:saved.Keys){
      if ($null -ne $script:saved[$k]) { Set-Item -Path Env:$k -Value $script:saved[$k] } else { Remove-Item Env:$k -ErrorAction SilentlyContinue }
    }
  }

  It 'defaults match workflow policy' {
    $root = (Get-Location).Path
    $cfg = & (Join-Path $root 'tools/Read-EnvSettings.ps1')
    $cfg.detectLeaks     | Should -BeTrue
    $cfg.cleanAfter      | Should -BeFalse
    $cfg.unblockGuard    | Should -BeFalse
    $cfg.suppressUi      | Should -BeFalse
    $cfg.watchConsole    | Should -BeTrue
    $cfg.invokerRequired | Should -BeFalse
    # Assert canonical path string with single backslashes
    $cfg.labviewExe | Should -Be 'C:\Program Files\National Instruments\LabVIEW 2025\LabVIEW.exe'
  }

  It 'parses boolean env vars case-insensitively' {
    $env:DETECT_LEAKS = 'false'
    $env:CLEAN_AFTER = '1'
    $env:UNBLOCK_GUARD = 'TRUE'
    $env:LV_SUPPRESS_UI = 'yes'
    $env:WATCH_CONSOLE = '0'
    $env:INVOKER_REQUIRED = 'True'
    $env:LABVIEW_EXE = 'D:\LabVIEW\LabVIEW.exe'
    $root = (Get-Location).Path
    $cfg = & (Join-Path $root 'tools/Read-EnvSettings.ps1')
    $cfg.detectLeaks     | Should -BeFalse
    $cfg.cleanAfter      | Should -BeTrue
    $cfg.unblockGuard    | Should -BeTrue
    $cfg.suppressUi      | Should -BeTrue
    $cfg.watchConsole    | Should -BeFalse
    $cfg.invokerRequired | Should -BeTrue
    $cfg.labviewExe      | Should -Be 'D:\LabVIEW\LabVIEW.exe'
  }
}
