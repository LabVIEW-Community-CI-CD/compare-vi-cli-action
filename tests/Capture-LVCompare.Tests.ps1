Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Capture-LVCompare.ps1' -Tag 'Unit' {
  BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:CaptureScript = Join-Path $repoRoot 'scripts' 'Capture-LVCompare.ps1'
    Test-Path -LiteralPath $script:CaptureScript | Should -BeTrue
  }

  AfterEach {
    Remove-Item Env:LVCOMPARE_PATH -ErrorAction SilentlyContinue
    Remove-Item Env:LABVIEW_PATH -ErrorAction SilentlyContinue
  }

  It 'writes lvPath/flags/diffDetected fields on success' {
    $work = Join-Path $TestDrive 'capture-success'
    $null = New-Item -ItemType Directory -Path $work

    $stubPath = Join-Path $work 'lvcompare-success.exe'
    $source = @"
using System;
using System.Threading;
public static class LVStubSuccess {
  public static int Main(string[] args) {
    int exitCode = 0;
    int sleepSeconds = 0;
    for (int i = 0; i < args.Length; i++) {
      var arg = args[i];
      if (string.Equals(arg, "--sleep", StringComparison.OrdinalIgnoreCase) && i + 1 < args.Length) {
        int.TryParse(args[++i], out sleepSeconds);
        continue;
      }
      if (string.Equals(arg, "--exit", StringComparison.OrdinalIgnoreCase) && i + 1 < args.Length) {
        int.TryParse(args[++i], out exitCode);
        continue;
      }
    }
    Console.WriteLine("stub-run");
    if (sleepSeconds > 0) {
      Thread.Sleep(sleepSeconds * 1000);
    }
    return exitCode;
  }
}
"@;
    $csPath = Join-Path $work 'stub-success.cs'
    Set-Content -LiteralPath $csPath -Value $source
    $csc = Join-Path ${env:WINDIR} 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if (-not (Test-Path $csc)) { $csc = Join-Path ${env:WINDIR} 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
    & $csc /nologo /target:exe /out:$stubPath $csPath | Out-Null
    $fakeLabVIEW = Join-Path $work 'LabVIEW.exe'
    Set-Content -LiteralPath $fakeLabVIEW -Value '' -Encoding ascii

    $baseVi = Join-Path $work 'base.vi'
    $headVi = Join-Path $work 'head.vi'
    Set-Content -LiteralPath $baseVi -Value 'base'
    Set-Content -LiteralPath $headVi -Value 'head'

    $outputDir = Join-Path $work 'results'

    $env:LVCOMPARE_PATH = $stubPath
    $lvArgs = @('-lvpath',$fakeLabVIEW,'-nobdcosm','-nofppos','-noattr')

    & $script:CaptureScript -Base $baseVi -Head $headVi -OutputDir $outputDir -TimeoutSeconds 10 -KillOnTimeout -LvArgs $lvArgs -RenderReport | Out-Null

    $capturePath = Join-Path $outputDir 'lvcompare-capture.json'
    Test-Path -LiteralPath $capturePath | Should -BeTrue

    $cap = Get-Content -LiteralPath $capturePath -Raw | ConvertFrom-Json
    $cap.lvPath | Should -Be $fakeLabVIEW
    $cap.flags | Should -Contain '-nobdcosm'
    $cap.flags | Should -Contain '-nofppos'
    $cap.flags | Should -Contain '-noattr'
    $cap.diffDetected | Should -BeFalse
    $cap.PSObject.Properties.Name | Should -Not -Contain 'timedOut'

    $stdoutPath = Join-Path $outputDir 'lvcompare-stdout.txt'
    (Get-Content -LiteralPath $stdoutPath -Raw).Trim() | Should -Be 'stub-run'

    $stagingReport = Join-Path (Join-Path (Join-Path $outputDir '_staging') 'compare') 'compare-report.html'
    Test-Path -LiteralPath $stagingReport | Should -BeTrue
  }

  It 'marks timedOut when process exceeds timeout' {
    $work = Join-Path $TestDrive 'capture-timeout'
    $null = New-Item -ItemType Directory -Path $work

    $stubPath = Join-Path $work 'lvcompare-timeout.exe'
    $source = @"
using System;
using System.Threading;
public static class LVStubTimeout {
  public static int Main(string[] args) {
    int exitCode = 0;
    int sleepSeconds = 0;
    for (int i = 0; i < args.Length; i++) {
      var arg = args[i];
      if (string.Equals(arg, "--sleep", StringComparison.OrdinalIgnoreCase) && i + 1 < args.Length) {
        int.TryParse(args[++i], out sleepSeconds);
        continue;
      }
      if (string.Equals(arg, "--exit", StringComparison.OrdinalIgnoreCase) && i + 1 < args.Length) {
        int.TryParse(args[++i], out exitCode);
        continue;
      }
    }
    Console.WriteLine("stub-run");
    if (sleepSeconds > 0) {
      Thread.Sleep(sleepSeconds * 1000);
    }
    return exitCode;
  }
}
"@;
    $csPath = Join-Path $work 'stub-timeout.cs'
    Set-Content -LiteralPath $csPath -Value $source
    $csc = Join-Path ${env:WINDIR} 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if (-not (Test-Path $csc)) { $csc = Join-Path ${env:WINDIR} 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
    & $csc /nologo /target:exe /out:$stubPath $csPath | Out-Null
    $fakeLabVIEW = Join-Path $work 'LabVIEW.exe'
    Set-Content -LiteralPath $fakeLabVIEW -Value '' -Encoding ascii

    $baseVi = Join-Path $work 'base.vi'
    $headVi = Join-Path $work 'head.vi'
    Set-Content -LiteralPath $baseVi -Value 'base'
    Set-Content -LiteralPath $headVi -Value 'head'

    $outputDir = Join-Path $work 'results'

    $env:LVCOMPARE_PATH = $stubPath
    $lvArgs = @('-lvpath',$fakeLabVIEW,'-nobdcosm','-nofppos','-noattr','--sleep','5')

    & $script:CaptureScript -Base $baseVi -Head $headVi -OutputDir $outputDir -TimeoutSeconds 1 -KillOnTimeout -LvArgs $lvArgs -RenderReport | Out-Null

    $capturePath = Join-Path $outputDir 'lvcompare-capture.json'
    Test-Path -LiteralPath $capturePath | Should -BeTrue

    $cap = Get-Content -LiteralPath $capturePath -Raw | ConvertFrom-Json
    $cap.timedOut | Should -BeTrue
    $cap.flags | Should -Contain '-nobdcosm'
    $cap.diffDetected | Should -BeNullOrEmpty
    $cap.args | Should -Contain '--sleep'

    $stagingReport = Join-Path (Join-Path (Join-Path $outputDir '_staging') 'compare') 'compare-report.html'
    Test-Path -LiteralPath $stagingReport | Should -BeTrue
  }
}
