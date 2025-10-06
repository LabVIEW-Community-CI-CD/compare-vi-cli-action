#Requires -Version 7.0
param(
  [switch]$Pack
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$proj = Join-Path $PSScriptRoot '..' | Join-Path -ChildPath 'src/CompareVi.Shared/CompareVi.Shared.csproj'
if (-not (Test-Path $proj)) { throw "Project not found: $proj" }

dotnet --info | Out-Host
dotnet restore $proj
dotnet build -c Release $proj --no-restore
if ($Pack) {
  $out = Join-Path $PSScriptRoot '..' | Join-Path -ChildPath 'artifacts'
  if (-not (Test-Path $out)) { New-Item -ItemType Directory -Force -Path $out | Out-Null }
  dotnet pack -c Release $proj -o $out --no-build
  Get-ChildItem $out -Filter *.nupkg | Select-Object -Expand FullName
}

