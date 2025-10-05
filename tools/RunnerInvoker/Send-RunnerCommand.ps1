#Requires -Version 7.0
param(
  [string]$Verb,
  [hashtable]$Args,
  [string]$PipeName = 'lvci.invoker',
  [int]$TimeoutSeconds = 20
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Json($o){ $o | ConvertTo-Json -Depth 8 }

$client = New-Object System.IO.Pipes.NamedPipeClientStream('.', $PipeName, [IO.Pipes.PipeDirection]::InOut, [IO.Pipes.PipeOptions]::None)
$client.Connect($TimeoutSeconds*1000)
$sr = New-Object System.IO.StreamReader($client, [Text.Encoding]::UTF8, $true, 1024, $true)
$sw = New-Object System.IO.StreamWriter($client, [Text.Encoding]::UTF8, $true, 1024, $true)
$sw.AutoFlush = $true
$req = @{ schema='invoker-cmd/v1'; id=[guid]::NewGuid().ToString(); verb=$Verb; args=$Args; context=@{} }
$sw.WriteLine((Json $req))
$line = $sr.ReadLine()
if (-not $line) { throw 'No response from invoker.' }
$resp = $line | ConvertFrom-Json
if (-not $resp.ok) { throw ("Invoker error ({0}): {1}" -f $resp.code,$resp.message) }
$resp | ConvertTo-Json -Depth 8 | Write-Output

