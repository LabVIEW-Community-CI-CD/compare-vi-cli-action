#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not ('CompareVI.ProcessInvokeHelper' -as [type])) {
  Add-Type -TypeDefinition @"
using System;
using System.Diagnostics;
using System.Text;
using System.Threading;

namespace CompareVI {
  public sealed class ProcessInvokeResult {
    public bool TimedOut { get; set; }
    public int? ExitCode { get; set; }
    public string[] Stdout { get; set; } = Array.Empty<string>();
    public string[] Stderr { get; set; } = Array.Empty<string>();
    public string Command { get; set; } = "";
    public string Exception { get; set; } = "";
  }

  public static class ProcessInvokeHelper {
    private static string[] SplitLines(string value) {
      if (string.IsNullOrEmpty(value)) {
        return Array.Empty<string>();
      }

      return value
        .Replace("\r\n", "\n")
        .Replace('\r', '\n')
        .Split(new[] { '\n' }, StringSplitOptions.RemoveEmptyEntries);
    }

    public static ProcessInvokeResult Run(string filePath, string[] arguments, int timeoutSeconds) {
      var safeTimeoutSeconds = Math.Max(5, timeoutSeconds);
      var result = new ProcessInvokeResult();

      using var stdoutClosed = new ManualResetEventSlim(false);
      using var stderrClosed = new ManualResetEventSlim(false);
      var stdout = new StringBuilder();
      var stderr = new StringBuilder();

      var psi = new ProcessStartInfo {
        FileName = filePath,
        UseShellExecute = false,
        RedirectStandardOutput = true,
        RedirectStandardError = true,
        CreateNoWindow = true
      };

      if (arguments != null) {
        foreach (var argument in arguments) {
          psi.ArgumentList.Add(argument ?? string.Empty);
        }
      }

      result.Command = psi.FileName + (psi.ArgumentList.Count > 0 ? " " + string.Join(" ", psi.ArgumentList) : string.Empty);

      using var process = new Process {
        StartInfo = psi,
        EnableRaisingEvents = true
      };

      process.OutputDataReceived += (_, eventArgs) => {
        if (eventArgs.Data == null) {
          stdoutClosed.Set();
          return;
        }

        lock (stdout) {
          stdout.AppendLine(eventArgs.Data);
        }
      };

      process.ErrorDataReceived += (_, eventArgs) => {
        if (eventArgs.Data == null) {
          stderrClosed.Set();
          return;
        }

        lock (stderr) {
          stderr.AppendLine(eventArgs.Data);
        }
      };

      try {
        if (!process.Start()) {
          result.Exception = "Process failed to start.";
          return result;
        }

        process.BeginOutputReadLine();
        process.BeginErrorReadLine();

        if (!process.WaitForExit(safeTimeoutSeconds * 1000)) {
          result.TimedOut = true;
          try {
            process.Kill(true);
          } catch {
          }
        }

        try {
          process.WaitForExit();
        } catch {
        }

        stdoutClosed.Wait(2000);
        stderrClosed.Wait(2000);

        if (!result.TimedOut) {
          result.ExitCode = process.ExitCode;
        }
      } catch (Exception ex) {
        result.Exception = ex.Message;
        try {
          if (!process.HasExited) {
            process.Kill(true);
          }
        } catch {
        }
      }

      result.Stdout = SplitLines(stdout.ToString());
      result.Stderr = SplitLines(stderr.ToString());
      return result;
    }
  }
}
"@ -Language CSharp
}

function Invoke-ProcessWithTimeoutCore {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$FilePath,
    [string[]]$Arguments = @(),
    [int]$TimeoutSeconds = 45
  )

  return [CompareVI.ProcessInvokeHelper]::Run(
    [string]$FilePath,
    [string[]]@($Arguments),
    [Math]::Max(5, [int]$TimeoutSeconds)
  )
}
