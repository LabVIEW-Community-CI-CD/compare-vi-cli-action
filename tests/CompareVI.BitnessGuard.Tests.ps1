<#
  Bitness guard tests for Resolve-Cli inside CompareVI.ps1.
  Strategy: Create a minimal fake LVCompare.exe file with PE header indicating 32-bit (Machine=0x014C) at canonical path in a temp override directory added to a sandbox root via temporary redirection.
  Since the script hardcodes the canonical path, we can only test the bitness detection logic by temporarily copying the real file if present and patching bytes OR (if not present in test env) crafting a synthetic minimal PE header.
  For portability in unit tests (no real LVCompare), generate a synthetic binary with required offsets:
    * DOS stub with e_lfanew at 0x80
    * PE signature at 0x80
    * Machine field (2 bytes) set to 0x014C (I386)
  Place at canonical path inside TestDrive by constructing directory tree and temporarily shadowing Resolve-Cli to point there.
  We cannot modify the real hardcoded canonical constant easily, so we instead invoke internal function through dot-sourcing and adapting by temporarily overriding the constant via -replace in loaded content.
  Simpler: Load file text, replace canonical path string with our TestDrive path, then invoke modified function.
#>
Set-StrictMode -Version Latest

Describe 'CompareVI bitness guard' -Tag 'Unit' {
  $scriptPath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) '../scripts/CompareVI.ps1'
  $original = Get-Content $scriptPath -Raw
  It 'rejects 32-bit LVCompare.exe' {
    # Arrange synthetic 32-bit binary
    $canonDir = Join-Path $TestDrive 'Program Files/National Instruments/Shared/LabVIEW Compare'
    New-Item -ItemType Directory -Path $canonDir -Force | Out-Null
    $canonPath = Join-Path $canonDir 'LVCompare.exe'
    $bytes = New-Object byte[] 256
    # 'MZ'
    $bytes[0] = 0x4D; $bytes[1] = 0x5A
  # e_lfanew at 0x3C -> 0x80 (little-endian 4 bytes)
  $e = [BitConverter]::GetBytes(0x80)
  for ($i=0; $i -lt $e.Length; $i++) { $bytes[0x3C + $i] = $e[$i] }
    # PE\0\0 at 0x80
    $bytes[0x80] = 0x50; $bytes[0x81] = 0x45; $bytes[0x82] = 0x00; $bytes[0x83] = 0x00
    # Machine field (little endian 0x014C) at 0x84
    $bytes[0x84] = 0x4C; $bytes[0x85] = 0x01
    Set-Content -Path $canonPath -Value ([System.Convert]::ToBase64String($bytes)) -Encoding Ascii
    # For realism decode back to binary file
    [IO.File]::WriteAllBytes($canonPath, [Convert]::FromBase64String((Get-Content $canonPath -Raw)))

    # Modify script content to point canonical constant to our TestDrive path
    $esc = [Regex]::Escape('C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe')
    $patched = $original -replace $esc, $canonPath.Replace('\\','\\\\')
    $tmpScript = Join-Path $TestDrive 'CompareVI.patched.ps1'
    Set-Content -Path $tmpScript -Value $patched -Encoding utf8
    . $tmpScript
    { Resolve-Cli } | Should -Throw -ErrorId * -ErrorMessage '*32-bit LVCompare.exe*'
  }
}
