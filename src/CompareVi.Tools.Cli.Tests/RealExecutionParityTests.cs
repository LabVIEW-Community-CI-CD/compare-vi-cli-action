#nullable enable
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text.Json.Nodes;
using Xunit;

namespace CompareVi.Tools.Cli.Tests
{
    public sealed class RealExecutionParityTests
    {
        private static readonly string RepoRoot = ResolveRepoRoot();
        private static readonly string CliProjectPath = Path.Combine(RepoRoot, "src", "CompareVi.Tools.Cli", "CompareVi.Tools.Cli.csproj");
        private static readonly string CliDllPath = Path.Combine(RepoRoot, "src", "CompareVi.Tools.Cli", "bin", "Debug", "net8.0", "comparevi-cli.dll");
        private static readonly string GetManifestScriptPath = Path.Combine(RepoRoot, "tools", "Get-PRVIDiffManifest.ps1");
        private static readonly string InvokeHistoryScriptPath = Path.Combine(RepoRoot, "tools", "Invoke-PRVIHistory.ps1");
        private static readonly string CompareHistoryScriptPath = Path.Combine(RepoRoot, "tools", "Compare-VIHistory.ps1");
        private static readonly string StubCompareScriptPath = Path.Combine(RepoRoot, "tests", "stubs", "Invoke-LVCompare.stub.ps1");

        static RealExecutionParityTests()
        {
            var build = RunProcess(
                "dotnet",
                RepoRoot,
                new[] { "build", CliProjectPath, "-c", "Debug", "--nologo" });
            Assert.True(build.ExitCode == 0, $"CLI build failed: {build.StdErr}{Environment.NewLine}{build.StdOut}");
            Assert.True(File.Exists(CliDllPath), $"Expected CLI output at {CliDllPath}");
        }

        [Fact]
        public void CompareRange_RealExecution_MatchesInvokePrViHistory()
        {
            using var temp = new TemporaryDirectory();
            var repo = CreateGitRepo(temp.Root);
            var manifestPath = Path.Combine(temp.Root, "direct", "vi-diff-manifest.json");
            var directResultsRoot = Path.Combine(temp.Root, "direct", "history");
            var directSummaryPath = Path.Combine(temp.Root, "direct", "vi-history-summary.json");
            var cliOutDir = Path.Combine(temp.Root, "cli-range");
            var env = CreateBaseEnvironment();

            var manifestRun = RunPwsh(
                repo.Root,
                GetManifestScriptPath,
                env,
                "-BaseRef", repo.BaseCommit,
                "-HeadRef", repo.HeadCommit,
                "-OutputPath", manifestPath);
            Assert.Equal(0, manifestRun.ExitCode);
            Assert.True(File.Exists(manifestPath));

            var directRun = RunPwsh(
                repo.Root,
                InvokeHistoryScriptPath,
                env,
                "-ManifestPath", manifestPath,
                "-ResultsRoot", directResultsRoot,
                "-SummaryPath", directSummaryPath,
                "-StartRef", repo.HeadCommit,
                "-EndRef", repo.BaseCommit,
                "-MaxPairs", "1",
                "-InvokeScriptPath", StubCompareScriptPath);
            Assert.Equal(0, directRun.ExitCode);
            Assert.True(File.Exists(directSummaryPath));

            var cliRun = RunCli(
                RepoRoot,
                CreateCliEnvironment(),
                "compare", "range",
                "--repo", repo.Root,
                "--base", repo.BaseCommit,
                "--head", repo.HeadCommit,
                "--max-pairs", "1",
                "--out-dir", cliOutDir);
            Assert.Equal(0, cliRun.ExitCode);

            var directSummary = ParseJsonObject(File.ReadAllText(directSummaryPath));
            var cliSummary = ParseJsonObject(cliRun.StdOut);

            Assert.Equal("comparevi-cli/compare-range@v1", cliSummary["schema"]!.GetValue<string>());
            Assert.Equal("success-diff", cliSummary["resultClass"]!.GetValue<string>());
            Assert.True(cliSummary["truncated"]!.GetValue<bool>());
            Assert.Equal(
                GetNestedInt(directSummary, "totals", "comparisons"),
                GetNestedInt(cliSummary, "totals", "comparisons"));
            Assert.Equal(
                GetNestedInt(directSummary, "totals", "diffs"),
                GetNestedInt(cliSummary, "totals", "diffs"));
            Assert.Equal(
                directSummary["targets"]!.AsArray().Count,
                cliSummary["targets"]!.AsArray().Count);
            Assert.Equal(
                directSummary["pairTimeline"]!.AsArray().Count,
                cliSummary["pairTimeline"]!.AsArray().Count);
            Assert.True(File.Exists(cliSummary["manifestPath"]!.GetValue<string>()));
            Assert.True(File.Exists(cliSummary["summaryJsonPath"]!.GetValue<string>()));
            Assert.True(File.Exists(cliSummary["summaryMarkdownPath"]!.GetValue<string>()));
            Assert.True(File.Exists(cliSummary["reportHtmlPath"]!.GetValue<string>()));
            Assert.True(File.Exists(cliSummary["imageIndexPath"]!.GetValue<string>()));
            Assert.True(cliSummary["imageIndex"]!["images"]!.AsArray().Count >= 1);
        }

        [Fact]
        public void HistoryRun_RealExecution_MatchesInvokePrViHistory()
        {
            using var temp = new TemporaryDirectory();
            var repo = CreateGitRepo(temp.Root);
            var manifestPath = Path.Combine(temp.Root, "history-run", "vi-diff-manifest.json");
            var directResultsRoot = Path.Combine(temp.Root, "history-run", "direct");
            var directSummaryPath = Path.Combine(temp.Root, "history-run", "vi-history-summary.json");
            var cliOutDir = Path.Combine(temp.Root, "history-run", "cli");
            var env = CreateBaseEnvironment();

            var manifestRun = RunPwsh(
                repo.Root,
                GetManifestScriptPath,
                env,
                "-BaseRef", repo.BaseCommit,
                "-HeadRef", repo.HeadCommit,
                "-OutputPath", manifestPath);
            Assert.Equal(0, manifestRun.ExitCode);

            var directRun = RunPwsh(
                repo.Root,
                InvokeHistoryScriptPath,
                env,
                "-ManifestPath", manifestPath,
                "-ResultsRoot", directResultsRoot,
                "-SummaryPath", directSummaryPath,
                "-MaxPairs", "1",
                "-InvokeScriptPath", StubCompareScriptPath);
            Assert.Equal(0, directRun.ExitCode);
            Assert.True(File.Exists(directSummaryPath));

            var cliRun = RunCli(
                RepoRoot,
                CreateCliEnvironment(),
                "history", "run",
                "--repo", repo.Root,
                "--input", manifestPath,
                "--max-pairs", "1",
                "--out-dir", cliOutDir);
            Assert.Equal(0, cliRun.ExitCode);

            var directSummary = ParseJsonObject(File.ReadAllText(directSummaryPath));
            var cliSummary = ParseJsonObject(cliRun.StdOut);

            Assert.Equal("comparevi-cli/history-run@v1", cliSummary["schema"]!.GetValue<string>());
            Assert.Equal("success-diff", cliSummary["resultClass"]!.GetValue<string>());
            Assert.Equal(
                GetNestedInt(directSummary, "totals", "comparisons"),
                GetNestedInt(cliSummary, "totals", "comparisons"));
            Assert.Equal(
                GetNestedInt(directSummary, "totals", "diffs"),
                GetNestedInt(cliSummary, "totals", "diffs"));
            Assert.Equal(
                directSummary["targets"]!.AsArray().Count,
                cliSummary["targets"]!.AsArray().Count);
            Assert.Equal(
                directSummary["pairTimeline"]!.AsArray().Count,
                cliSummary["pairTimeline"]!.AsArray().Count);
            Assert.Equal(Path.GetFullPath(manifestPath), cliSummary["inputPath"]!.GetValue<string>());
            Assert.True(File.Exists(cliSummary["summaryJsonPath"]!.GetValue<string>()));
            Assert.True(File.Exists(cliSummary["reportHtmlPath"]!.GetValue<string>()));
            Assert.True(File.Exists(cliSummary["imageIndexPath"]!.GetValue<string>()));
        }

        [Fact]
        public void ReportConsolidate_RealExecution_RendersWrappedSingleModeManifest()
        {
            using var temp = new TemporaryDirectory();
            var repo = CreateGitRepo(temp.Root);
            var historyResultsRoot = Path.Combine(temp.Root, "report-source");
            var modeManifestPath = Path.Combine(historyResultsRoot, "default", "manifest.json");
            var cliOutDir = Path.Combine(temp.Root, "report-cli");
            var env = CreateBaseEnvironment();

            var compareRun = RunPwsh(
                repo.Root,
                CompareHistoryScriptPath,
                env,
                "-TargetPath", repo.TargetRelativePath,
                "-StartRef", repo.HeadCommit,
                "-EndRef", repo.BaseCommit,
                "-ResultsDir", historyResultsRoot,
                "-MaxPairs", "1",
                "-RenderReport",
                "-ReportFormat", "html",
                "-InvokeScriptPath", StubCompareScriptPath);
            Assert.Equal(0, compareRun.ExitCode);
            Assert.True(File.Exists(modeManifestPath));
            var modeManifest = ParseJsonObject(File.ReadAllText(modeManifestPath));

            var cliRun = RunCli(
                RepoRoot,
                CreateCliEnvironment(),
                "report", "consolidate",
                "--repo", repo.Root,
                "--input", modeManifestPath,
                "--out-dir", cliOutDir);
            Assert.Equal(0, cliRun.ExitCode);

            var cliSummary = ParseJsonObject(cliRun.StdOut);
            Assert.Equal("comparevi-cli/report-consolidate@v1", cliSummary["schema"]!.GetValue<string>());
            Assert.Equal("vi-compare/history@v1", cliSummary["sourceSchema"]!.GetValue<string>());
            Assert.Equal("success-diff", cliSummary["resultClass"]!.GetValue<string>());
            Assert.True(File.Exists(cliSummary["summaryJsonPath"]!.GetValue<string>()));
            Assert.True(File.Exists(cliSummary["summaryMarkdownPath"]!.GetValue<string>()));
            Assert.True(File.Exists(cliSummary["reportHtmlPath"]!.GetValue<string>()));
            Assert.True(File.Exists(cliSummary["imageIndexPath"]!.GetValue<string>()));
            Assert.Single(cliSummary["manifest"]!["modes"]!.AsArray());
            Assert.Equal(modeManifest["comparisons"]!.AsArray().Count, cliSummary["items"]!.AsArray().Count);
        }

        private static RepoFixture CreateGitRepo(string root)
        {
            var repoRoot = Path.Combine(root, "repo");
            Directory.CreateDirectory(repoRoot);

            RunAndAssert("git", repoRoot, null, "init", "--quiet");
            RunAndAssert("git", repoRoot, null, "config", "user.name", "Test Bot");
            RunAndAssert("git", repoRoot, null, "config", "user.email", "bot@example.com");

            var targetRelativePath = Path.Combine("Fixtures", "Demo.vi");
            var targetPath = Path.Combine(repoRoot, targetRelativePath);
            Directory.CreateDirectory(Path.GetDirectoryName(targetPath)!);
            File.WriteAllText(targetPath, "vi-v1");
            RunAndAssert("git", repoRoot, null, "add", ".");
            RunAndAssert("git", repoRoot, null, "commit", "--quiet", "-m", "base commit");
            var baseCommit = RunProcess("git", repoRoot, new[] { "rev-parse", "HEAD" }).StdOut.Trim();

            File.WriteAllText(targetPath, "vi-v2");
            RunAndAssert("git", repoRoot, null, "add", ".");
            RunAndAssert("git", repoRoot, null, "commit", "--quiet", "-m", "mid commit");

            File.WriteAllText(targetPath, "vi-v3");
            RunAndAssert("git", repoRoot, null, "add", ".");
            RunAndAssert("git", repoRoot, null, "commit", "--quiet", "-m", "head commit");
            var headCommit = RunProcess("git", repoRoot, new[] { "rev-parse", "HEAD" }).StdOut.Trim();

            return new RepoFixture(repoRoot, targetRelativePath.Replace('\\', '/'), baseCommit, headCommit);
        }

        private static Dictionary<string, string?> CreateBaseEnvironment()
        {
            return new Dictionary<string, string?>(StringComparer.OrdinalIgnoreCase)
            {
                ["COMPAREVI_SCRIPTS_ROOT"] = RepoRoot,
                ["COMPAREVI_CLI_SCRIPTS_ROOT"] = RepoRoot
            };
        }

        private static Dictionary<string, string?> CreateCliEnvironment()
        {
            var env = CreateBaseEnvironment();
            env["COMPAREVI_CLI_INVOKE_SCRIPT_PATH"] = StubCompareScriptPath;
            return env;
        }

        private static (int ExitCode, string StdOut, string StdErr) RunCli(string workdir, IDictionary<string, string?> environment, params string[] cliArguments)
        {
            var arguments = new List<string> { CliDllPath };
            arguments.AddRange(cliArguments);
            return RunProcess("dotnet", workdir, arguments, environment);
        }

        private static (int ExitCode, string StdOut, string StdErr) RunPwsh(string workdir, string scriptPath, IDictionary<string, string?> environment, params string[] scriptArguments)
        {
            var arguments = new List<string> { "-NoLogo", "-NoProfile", "-File", scriptPath };
            arguments.AddRange(scriptArguments);
            return RunProcess("pwsh", workdir, arguments, environment);
        }

        private static void RunAndAssert(string fileName, string workdir, IDictionary<string, string?>? environment, params string[] arguments)
        {
            var result = RunProcess(fileName, workdir, arguments, environment);
            Assert.True(result.ExitCode == 0, $"Command failed: {fileName} {string.Join(" ", arguments)}{Environment.NewLine}{result.StdErr}{Environment.NewLine}{result.StdOut}");
        }

        private static (int ExitCode, string StdOut, string StdErr) RunProcess(
            string fileName,
            string workdir,
            IEnumerable<string> arguments,
            IDictionary<string, string?>? environment = null)
        {
            var psi = new ProcessStartInfo
            {
                FileName = fileName,
                WorkingDirectory = workdir,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true
            };

            foreach (var argument in arguments)
            {
                psi.ArgumentList.Add(argument);
            }

            if (environment is not null)
            {
                foreach (var entry in environment)
                {
                    if (entry.Value is null)
                    {
                        psi.Environment.Remove(entry.Key);
                    }
                    else
                    {
                        psi.Environment[entry.Key] = entry.Value;
                    }
                }
            }

            using var process = Process.Start(psi)!;
            var stdout = process.StandardOutput.ReadToEnd();
            var stderr = process.StandardError.ReadToEnd();
            process.WaitForExit();
            return (process.ExitCode, stdout, stderr);
        }

        private static JsonObject ParseJsonObject(string json)
        {
            return JsonNode.Parse(json)!.AsObject();
        }

        private static int GetNestedInt(JsonObject root, string objectProperty, string propertyName)
        {
            return root[objectProperty]![propertyName]!.GetValue<int>();
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

        private sealed class RepoFixture
        {
            public RepoFixture(string root, string targetRelativePath, string baseCommit, string headCommit)
            {
                Root = root;
                TargetRelativePath = targetRelativePath;
                BaseCommit = baseCommit;
                HeadCommit = headCommit;
            }

            public string Root { get; }

            public string TargetRelativePath { get; }

            public string BaseCommit { get; }

            public string HeadCommit { get; }
        }

        private sealed class TemporaryDirectory : IDisposable
        {
            public TemporaryDirectory()
            {
                Root = Path.Combine(Path.GetTempPath(), "comparevi-cli-tests-" + Guid.NewGuid().ToString("N"));
                Directory.CreateDirectory(Root);
            }

            public string Root { get; }

            public void Dispose()
            {
                try
                {
                    if (Directory.Exists(Root))
                    {
                        Directory.Delete(Root, recursive: true);
                    }
                }
                catch
                {
                }
            }
        }
    }
}
