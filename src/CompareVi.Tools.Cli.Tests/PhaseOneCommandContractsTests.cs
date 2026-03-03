using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text.Json.Nodes;
using Xunit;

namespace CompareVi.Tools.Cli.Tests
{
    public class PhaseOneCommandContractsTests
    {
        private static readonly string RepoRoot = ResolveRepoRoot();
        private static readonly string CliProjectPath = Path.Combine(RepoRoot, "src", "CompareVi.Tools.Cli", "CompareVi.Tools.Cli.csproj");
        private static readonly string CliDllPath = Path.Combine(RepoRoot, "src", "CompareVi.Tools.Cli", "bin", "Debug", "net8.0", "comparevi-cli.dll");

        static PhaseOneCommandContractsTests()
        {
            var build = RunProcess("dotnet", $"build \"{CliProjectPath}\" -c Debug --nologo");
            Assert.True(build.ExitCode == 0, $"CLI build failed: {build.StdErr}\n{build.StdOut}");
            Assert.True(File.Exists(CliDllPath), $"Expected CLI output at {CliDllPath}");
        }

        [Fact]
        public void CompareSingle_DryRunDiff_EmitsDiffPassContract()
        {
            var inputPath = Path.Combine(RepoRoot, "tests", "results", "_agent", "cli-phase1-compare-input.json");
            Directory.CreateDirectory(Path.GetDirectoryName(inputPath)!);
            File.WriteAllText(inputPath, "{}");

            var run = RunCli($"compare single --input \"{inputPath}\" --dry-run --diff");
            Assert.Equal(0, run.ExitCode);

            var json = JsonNode.Parse(run.StdOut)!.AsObject();
            Assert.Equal("comparevi-cli/compare-single@v1", json["schema"]!.GetValue<string>());
            Assert.Equal("compare single", json["command"]!.GetValue<string>());
            Assert.Equal("success-diff", json["resultClass"]!.GetValue<string>());
            Assert.True(json["isDiff"]!.GetValue<bool>());
            Assert.Equal("pass", json["gateOutcome"]!.GetValue<string>());
            Assert.Equal("none", json["failureClass"]!.GetValue<string>());
        }

        [Fact]
        public void HistoryRun_DryRun_EmitsHistoryContract()
        {
            var inputPath = Path.Combine(RepoRoot, "tests", "results", "_agent", "cli-phase1-history-input.json");
            Directory.CreateDirectory(Path.GetDirectoryName(inputPath)!);
            File.WriteAllText(inputPath, "{}");

            var run = RunCli($"history run --input \"{inputPath}\" --dry-run");
            Assert.Equal(0, run.ExitCode);

            var json = JsonNode.Parse(run.StdOut)!.AsObject();
            Assert.Equal("comparevi-cli/history-run@v1", json["schema"]!.GetValue<string>());
            Assert.Equal("history run", json["command"]!.GetValue<string>());
            Assert.Equal("pass", json["gateOutcome"]!.GetValue<string>());
        }

        [Fact]
        public void ReportConsolidate_DryRun_EmitsReportContract()
        {
            var inputPath = Path.Combine(RepoRoot, "tests", "results", "_agent", "cli-phase1-report-input.json");
            Directory.CreateDirectory(Path.GetDirectoryName(inputPath)!);
            File.WriteAllText(inputPath, "{}");

            var run = RunCli($"report consolidate --input \"{inputPath}\" --dry-run");
            Assert.Equal(0, run.ExitCode);

            var json = JsonNode.Parse(run.StdOut)!.AsObject();
            Assert.Equal("comparevi-cli/report-consolidate@v1", json["schema"]!.GetValue<string>());
            Assert.Equal("report consolidate", json["command"]!.GetValue<string>());
            Assert.Equal("pass", json["gateOutcome"]!.GetValue<string>());
        }

        [Fact]
        public void ContractsValidate_MissingInputFile_FailsPreflight()
        {
            var missingPath = Path.Combine(RepoRoot, "tests", "results", "_agent", "missing-input-does-not-exist.json");
            if (File.Exists(missingPath))
            {
                File.Delete(missingPath);
            }

            var run = RunCli($"contracts validate --input \"{missingPath}\"");
            Assert.Equal(1, run.ExitCode);

            var json = JsonNode.Parse(run.StdOut)!.AsObject();
            Assert.Equal("comparevi-cli/contracts-validate@v1", json["schema"]!.GetValue<string>());
            Assert.False(json["valid"]!.GetValue<bool>());
            Assert.Equal("fail", json["gateOutcome"]!.GetValue<string>());
            Assert.Equal("failure-preflight", json["resultClass"]!.GetValue<string>());
        }

        private static (int ExitCode, string StdOut, string StdErr) RunCli(string arguments)
        {
            return RunProcess("dotnet", $"\"{CliDllPath}\" {arguments}");
        }

        private static (int ExitCode, string StdOut, string StdErr) RunProcess(string fileName, string arguments)
        {
            var psi = new ProcessStartInfo
            {
                FileName = fileName,
                Arguments = arguments,
                WorkingDirectory = RepoRoot,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true
            };

            using var process = Process.Start(psi)!;
            var stdout = process.StandardOutput.ReadToEnd();
            var stderr = process.StandardError.ReadToEnd();
            process.WaitForExit();
            return (process.ExitCode, stdout, stderr);
        }

        private static string ResolveRepoRoot()
        {
            var current = AppContext.BaseDirectory;
            for (var i = 0; i < 10; i++)
            {
                var candidate = Path.GetFullPath(Path.Combine(current, string.Join(Path.DirectorySeparatorChar, Enumerable.Repeat("..", i))));
                var marker = Path.Combine(candidate, "src", "CompareVi.Tools.Cli", "CompareVi.Tools.Cli.csproj");
                if (File.Exists(marker))
                {
                    return candidate;
                }
            }

            throw new InvalidOperationException("Unable to resolve repository root for CLI tests.");
        }
    }
}
