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
        public void Preflight_DefaultRepo_EmitsPreflightContract()
        {
            var run = RunCli("preflight");
            Assert.Equal(0, run.ExitCode);

            var json = JsonNode.Parse(run.StdOut)!.AsObject();
            Assert.Equal("comparevi-cli/preflight@v1", json["schema"]!.GetValue<string>());
            Assert.Equal("1.0.0", json["schemaVersion"]!.GetValue<string>());
            Assert.Equal("preflight", json["command"]!.GetValue<string>());
            Assert.Equal("pass", json["gateOutcome"]!.GetValue<string>());
            Assert.Equal("success-no-diff", json["resultClass"]!.GetValue<string>());
            Assert.Equal("pass", json["outcome"]!["class"]!.GetValue<string>());
            Assert.Equal("no_diff", json["outcome"]!["kind"]!.GetValue<string>());
            Assert.True(json["checks"]!.AsArray().Count >= 1);
            Assert.Contains(json["checks"]!.AsArray(), check =>
                string.Equals(check!["id"]!.GetValue<string>(), "windows-host", StringComparison.OrdinalIgnoreCase));
            Assert.Empty(json["diagnostics"]!.AsArray());
        }

        [Fact]
        public void Preflight_MissingRepo_EmitsFailureDiagnostics()
        {
            var missingRepo = Path.Combine(RepoRoot, "tests", "results", "_agent", "missing-preflight-repo");
            if (Directory.Exists(missingRepo))
            {
                Directory.Delete(missingRepo, recursive: true);
            }

            var run = RunCli($"preflight --repo \"{missingRepo}\"");
            Assert.Equal(1, run.ExitCode);

            var json = JsonNode.Parse(run.StdOut)!.AsObject();
            Assert.Equal("comparevi-cli/preflight@v1", json["schema"]!.GetValue<string>());
            Assert.Equal("failure-preflight", json["resultClass"]!.GetValue<string>());
            Assert.Equal("fail", json["gateOutcome"]!.GetValue<string>());
            Assert.Equal("preflight", json["failureClass"]!.GetValue<string>());
            Assert.Equal("fail", json["outcome"]!["class"]!.GetValue<string>());
            Assert.Equal("preflight_error", json["outcome"]!["kind"]!.GetValue<string>());
            Assert.True(json["failedPrerequisites"]!.AsArray().Count >= 1);
            Assert.True(json["diagnostics"]!.AsArray().Count >= 1);
            Assert.Equal("repo-path-missing", json["diagnostics"]![0]!["code"]!.GetValue<string>());
        }

        [Fact]
        public void Preflight_UnknownOption_ReturnsInvalidUsage()
        {
            var run = RunCli("preflight --bogus");
            Assert.Equal(2, run.ExitCode);
            Assert.Contains("Unknown option: --bogus", run.StdErr);
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
            Assert.Equal("1.0.0", json["schemaVersion"]!.GetValue<string>());
            Assert.Equal("compare single", json["command"]!.GetValue<string>());
            Assert.Equal("pass", json["outcome"]!["class"]!.GetValue<string>());
            Assert.Equal("diff", json["outcome"]!["kind"]!.GetValue<string>());
            Assert.Equal("success-diff", json["resultClass"]!.GetValue<string>());
            Assert.True(json["isDiff"]!.GetValue<bool>());
            Assert.Equal("pass", json["gateOutcome"]!.GetValue<string>());
            Assert.Equal("none", json["failureClass"]!.GetValue<string>());
            Assert.Equal("1.0.0", json["imageIndex"]!["schemaVersion"]!.GetValue<string>());
            Assert.True(json["imageIndex"]!["images"]!.AsArray().Count >= 1);
        }

        [Fact]
        public void CompareRange_DryRun_EmitsRangeContract()
        {
            var outDir = Path.Combine(RepoRoot, "tests", "results", "_agent", "cli-phase1-range-out");
            var run = RunCli($"compare range --base origin/develop --head HEAD --dry-run --out-dir \"{outDir}\"");
            Assert.Equal(0, run.ExitCode);

            var json = JsonNode.Parse(run.StdOut)!.AsObject();
            Assert.Equal("comparevi-cli/compare-range@v1", json["schema"]!.GetValue<string>());
            Assert.Equal("1.0.0", json["schemaVersion"]!.GetValue<string>());
            Assert.Equal("additive-within-major", json["schemaCompatibility"]!["policy"]!.GetValue<string>());
            Assert.Equal("compare range", json["command"]!.GetValue<string>());
            Assert.Equal("origin/develop", json["base"]!.GetValue<string>());
            Assert.Equal("HEAD", json["head"]!.GetValue<string>());
            Assert.Equal("pass", json["outcome"]!["class"]!.GetValue<string>());
            Assert.Equal("no_diff", json["outcome"]!["kind"]!.GetValue<string>());
            Assert.Equal("pass", json["gateOutcome"]!.GetValue<string>());
            Assert.Equal(Path.GetFullPath(outDir), json["outDir"]!.GetValue<string>());
            Assert.EndsWith("vi-history-summary.json", json["summaryJsonPath"]!.GetValue<string>(), StringComparison.OrdinalIgnoreCase);
            Assert.EndsWith("vi-history-summary.md", json["summaryMarkdownPath"]!.GetValue<string>(), StringComparison.OrdinalIgnoreCase);
            Assert.EndsWith("vi-history-report.html", json["consolidatedReportPath"]!.GetValue<string>(), StringComparison.OrdinalIgnoreCase);
            Assert.EndsWith("vi-history-image-index.json", json["imageIndexPath"]!.GetValue<string>(), StringComparison.OrdinalIgnoreCase);
            Assert.Equal("comparevi-cli/image-index@v1", json["imageIndex"]!["schema"]!.GetValue<string>());
            Assert.Equal("1.0.0", json["imageIndex"]!["schemaVersion"]!.GetValue<string>());
            Assert.Empty(json["imageIndex"]!["images"]!.AsArray());
            Assert.True(json["items"]!.AsArray().Count >= 1);
            Assert.True(json["items"]![0]!["timing"]!["durationMs"]!.GetValue<double>() >= 0);
            Assert.True(json["timingSummary"]!["p50Ms"]!.GetValue<double>() >= 0);
            Assert.True(json["timingSummary"]!["p90Ms"]!.GetValue<double>() >= 0);
            Assert.True(json["timingSummary"]!["p95Ms"]!.GetValue<double>() >= 0);
        }

        [Fact]
        public void CompareRange_NonInteractiveWithoutHeadless_FailsPolicy()
        {
            var run = RunCli("compare range --base origin/develop --head HEAD --dry-run --non-interactive");
            Assert.Equal(1, run.ExitCode);

            var json = JsonNode.Parse(run.StdOut)!.AsObject();
            Assert.Equal("failure-preflight", json["resultClass"]!.GetValue<string>());
            Assert.Equal("preflight", json["failureClass"]!.GetValue<string>());
            Assert.Equal("fail", json["outcome"]!["class"]!.GetValue<string>());
            Assert.Equal("preflight_error", json["outcome"]!["kind"]!.GetValue<string>());
            Assert.Equal("headless-required", json["diagnostics"]![0]!["code"]!.GetValue<string>());
        }

        [Fact]
        public void CompareRange_NonInteractiveWithHeadless_Passes()
        {
            var run = RunCli("compare range --base origin/develop --head HEAD --dry-run --non-interactive --headless");
            Assert.Equal(0, run.ExitCode);

            var json = JsonNode.Parse(run.StdOut)!.AsObject();
            Assert.True(json["headless"]!.GetValue<bool>());
            Assert.True(json["nonInteractive"]!.GetValue<bool>());
            Assert.Equal("pass", json["gateOutcome"]!.GetValue<string>());
        }

        [Fact]
        public void CompareRange_UnknownOption_ReturnsInvalidUsage()
        {
            var run = RunCli("compare range --base origin/develop --head HEAD --dry-run --what");
            Assert.Equal(2, run.ExitCode);
            Assert.Contains("Unknown option: --what", run.StdErr);
        }

        [Fact]
        public void CompareRange_InvalidMaxPairs_ReturnsInvalidUsage()
        {
            var run = RunCli("compare range --base origin/develop --head HEAD --dry-run --max-pairs nope");
            Assert.Equal(2, run.ExitCode);
            Assert.Contains("Invalid value for option: --max-pairs <int>", run.StdErr);
        }

        [Fact]
        public void HistoryRun_DryRun_EmitsHistoryContract()
        {
            var inputPath = Path.Combine(RepoRoot, "tests", "results", "_agent", "cli-phase1-history-input.json");
            Directory.CreateDirectory(Path.GetDirectoryName(inputPath)!);
            File.WriteAllText(inputPath, "{}");

            var outDir = Path.Combine(RepoRoot, "tests", "results", "_agent", "cli-phase1-history-out");
            var run = RunCli($"history run --input \"{inputPath}\" --dry-run --out-dir \"{outDir}\"");
            Assert.Equal(0, run.ExitCode);

            var json = JsonNode.Parse(run.StdOut)!.AsObject();
            Assert.Equal("comparevi-cli/history-run@v1", json["schema"]!.GetValue<string>());
            Assert.Equal("1.0.0", json["schemaVersion"]!.GetValue<string>());
            Assert.Equal("history run", json["command"]!.GetValue<string>());
            Assert.Equal("pass", json["outcome"]!["class"]!.GetValue<string>());
            Assert.Equal("no_diff", json["outcome"]!["kind"]!.GetValue<string>());
            Assert.Equal("pass", json["gateOutcome"]!.GetValue<string>());
            Assert.Equal(Path.GetFullPath(outDir), json["outDir"]!.GetValue<string>());
            Assert.EndsWith("vi-history-report.html", json["consolidatedReportPath"]!.GetValue<string>(), StringComparison.OrdinalIgnoreCase);
            Assert.Equal("1.0.0", json["imageIndex"]!["schemaVersion"]!.GetValue<string>());
        }

        [Fact]
        public void ReportConsolidate_DryRun_EmitsReportContract()
        {
            var inputPath = Path.Combine(RepoRoot, "tests", "results", "_agent", "cli-phase1-report-input.json");
            Directory.CreateDirectory(Path.GetDirectoryName(inputPath)!);
            File.WriteAllText(inputPath, "{}");

            var outDir = Path.Combine(RepoRoot, "tests", "results", "_agent", "cli-phase1-report-out");
            var run = RunCli($"report consolidate --input \"{inputPath}\" --dry-run --out-dir \"{outDir}\"");
            Assert.Equal(0, run.ExitCode);

            var json = JsonNode.Parse(run.StdOut)!.AsObject();
            Assert.Equal("comparevi-cli/report-consolidate@v1", json["schema"]!.GetValue<string>());
            Assert.Equal("1.0.0", json["schemaVersion"]!.GetValue<string>());
            Assert.Equal("report consolidate", json["command"]!.GetValue<string>());
            Assert.Equal("pass", json["outcome"]!["class"]!.GetValue<string>());
            Assert.Equal("no_diff", json["outcome"]!["kind"]!.GetValue<string>());
            Assert.Equal("pass", json["gateOutcome"]!.GetValue<string>());
            Assert.Equal(Path.GetFullPath(outDir), json["outDir"]!.GetValue<string>());
            Assert.EndsWith("vi-history-image-index.json", json["imageIndexPath"]!.GetValue<string>(), StringComparison.OrdinalIgnoreCase);
            Assert.Equal("comparevi-cli/image-index@v1", json["imageIndex"]!["schema"]!.GetValue<string>());
        }

        [Fact]
        public void ReportConsolidate_UnknownOption_ReturnsInvalidUsage()
        {
            var inputPath = Path.Combine(RepoRoot, "tests", "results", "_agent", "cli-phase1-report-input.json");
            Directory.CreateDirectory(Path.GetDirectoryName(inputPath)!);
            File.WriteAllText(inputPath, "{}");

            var run = RunCli($"report consolidate --input \"{inputPath}\" --dry-run --unexpected");
            Assert.Equal(2, run.ExitCode);
            Assert.Contains("Unknown option: --unexpected", run.StdErr);
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
            Assert.Equal("1.0.0", json["schemaVersion"]!.GetValue<string>());
            Assert.False(json["valid"]!.GetValue<bool>());
            Assert.Equal("fail", json["outcome"]!["class"]!.GetValue<string>());
            Assert.Equal("preflight_error", json["outcome"]!["kind"]!.GetValue<string>());
            Assert.Equal("fail", json["gateOutcome"]!.GetValue<string>());
            Assert.Equal("failure-preflight", json["resultClass"]!.GetValue<string>());
        }

        [Fact]
        public void ContractsValidate_UnknownOption_ReturnsInvalidUsage()
        {
            var run = RunCli("contracts validate --input missing.json --extra");
            Assert.Equal(2, run.ExitCode);
            Assert.Contains("Unknown option: --extra", run.StdErr);
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
