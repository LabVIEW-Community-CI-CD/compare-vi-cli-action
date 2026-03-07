using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

internal static class HistoryCliBridge
{
    private const string SchemaVersion = "1.0.0";

    public static int RunCompareRange(string[] args, int tailStart, JsonSerializerOptions serializerOptions)
    {
        const string schema = "comparevi-cli/compare-range@v1";
        const string lane = "compare-range";
        const string command = "compare range";

        if (!ValidateCommandOptions(
                args,
                startIndex: tailStart,
                valueOptions: new[] { "--base", "--head", "--repo", "--vi", "--vi-list", "--mode", "--max-pairs", "--timeout", "--out-dir", "--exit-code", "--failure-class" },
                flagOptions: new[] { "--dry-run", "--diff", "--non-interactive", "--headless" },
                out var optionError))
        {
            Console.Error.WriteLine(optionError);
            return 2;
        }

        if (!TryReadOption(args, tailStart, "--base", out var baseRef) || string.IsNullOrWhiteSpace(baseRef))
        {
            Console.Error.WriteLine("Missing required option: --base <ref>");
            return 2;
        }

        if (!TryReadOption(args, tailStart, "--head", out var headRef) || string.IsNullOrWhiteSpace(headRef))
        {
            Console.Error.WriteLine("Missing required option: --head <ref>");
            return 2;
        }

        if (!TryReadNullableIntOption(args, tailStart, "--max-pairs", out var maxPairs, out optionError))
        {
            Console.Error.WriteLine(optionError);
            return 2;
        }

        if (!TryReadNullableIntOption(args, tailStart, "--timeout", out var timeoutSeconds, out optionError))
        {
            Console.Error.WriteLine(optionError);
            return 2;
        }

        var outDir = ResolveOutputDirectory(args, tailStart);
        var headless = HasFlag(args, tailStart, "--headless");
        var nonInteractive = HasFlag(args, tailStart, "--non-interactive");
        var artifacts = BuildArtifactPaths(lane, outDir);
        var runLog = new StringBuilder();
        runLog.AppendLine($"[{DateTimeOffset.UtcNow:O}] comparevi-cli {command} real execution started.");

        try
        {
            if (nonInteractive && !headless)
            {
                return EmitPolicyFailure(schema, lane, command, outDir, artifacts, headless, nonInteractive, runLog, serializerOptions);
            }

            var repoPath = ResolveRepoPath(args, tailStart);
            var modeValues = NormalizeModeList(ReadOptionValueList(args, tailStart, "--mode"));
            var filters = NormalizeTargetFilters(args, tailStart, repoPath);
            var scriptsRoot = ResolveScriptsRoot(repoPath);
            var diffManifestScript = ResolveToolScriptPath(scriptsRoot, "Get-PRVIDiffManifest.ps1");
            var invokeHistoryScript = ResolveToolScriptPath(scriptsRoot, "Invoke-PRVIHistory.ps1");
            var invokeScriptPath = ResolveOptionalInvokeScriptPath(repoPath);
            var backendRoot = PrepareBackendRoot(outDir);
            var manifestPath = Path.Combine(backendRoot, "vi-diff-manifest.json");
            var backendResultsRoot = Path.Combine(backendRoot, "history");
            var backendSummaryPath = Path.Combine(backendRoot, "vi-history-backend-summary.json");

            var diffArgs = new List<string>
            {
                "-BaseRef", baseRef!,
                "-HeadRef", headRef!,
                "-OutputPath", manifestPath
            };
            EnsureScriptSucceeded(
                InvokePwshScript(diffManifestScript, repoPath, diffArgs, scriptsRoot, runLog),
                command,
                "diff-manifest");

            var manifest = LoadJsonObject(manifestPath, "diff manifest");
            EnsureManifestSchema(manifest, "vi-diff-manifest@v1", manifestPath);
            manifest = FilterDiffManifest(manifest, filters);
            WriteJsonToFile(manifest, manifestPath, serializerOptions);

            JsonObject backendSummary;
            if (GetArray(manifest, "pairs").Count == 0)
            {
                Directory.CreateDirectory(backendResultsRoot);
                backendSummary = CreateEmptyHistorySummary(manifestPath, backendResultsRoot, maxPairs, modeValues);
                WriteJsonToFile(backendSummary, backendSummaryPath, serializerOptions);
            }
            else
            {
                Directory.CreateDirectory(backendResultsRoot);
                var historyArgs = new List<string>
                {
                    "-ManifestPath", manifestPath,
                    "-ResultsRoot", backendResultsRoot,
                    "-SummaryPath", backendSummaryPath,
                    "-StartRef", headRef!,
                    "-EndRef", baseRef!
                };
                AddOptionalIntArgument(historyArgs, "-MaxPairs", NormalizePositiveInt(maxPairs));
                AddOptionalIntArgument(historyArgs, "-CompareTimeoutSeconds", NormalizePositiveInt(timeoutSeconds));
                AddOptionalArrayArgument(historyArgs, "-Mode", modeValues);
                AddOptionalPathArgument(historyArgs, "-InvokeScriptPath", invokeScriptPath);
                EnsureScriptSucceeded(
                    InvokePwshScript(invokeHistoryScript, repoPath, historyArgs, scriptsRoot, runLog),
                    command,
                    "history-run");
                backendSummary = LoadJsonObject(backendSummaryPath, "history summary");
                EnsureManifestSchema(backendSummary, "pr-vi-history-summary@v1", backendSummaryPath);
            }

            var payload = BuildHistoryLanePayload(
                schema: schema,
                lane: lane,
                command: command,
                outDir: outDir,
                artifacts: artifacts,
                headless: headless,
                nonInteractive: nonInteractive,
                backendSummary: backendSummary,
                backendSummaryPath: backendSummaryPath,
                backendResultsRoot: backendResultsRoot,
                runLog: runLog,
                serializerOptions: serializerOptions,
                extraFields: new JsonObject
                {
                    ["repoPath"] = repoPath,
                    ["base"] = baseRef,
                    ["head"] = headRef,
                    ["manifestPath"] = manifestPath,
                    ["maxPairs"] = NormalizePositiveInt(maxPairs),
                    ["timeoutSeconds"] = NormalizePositiveInt(timeoutSeconds),
                    ["mode"] = modeValues.Count > 0 ? new JsonArray(modeValues.Select(v => (JsonNode?)v).ToArray()) : null,
                    ["truncated"] = DetermineHistoryTruncation(backendSummary)
                });

            Console.WriteLine(payload.ToJsonString(serializerOptions));
            return 0;
        }
        catch (CliFailureException ex)
        {
            return EmitFailurePayload(schema, lane, command, outDir, artifacts, headless, nonInteractive, ex, runLog, serializerOptions);
        }
    }

    public static int RunHistoryRun(string[] args, int tailStart, JsonSerializerOptions serializerOptions)
    {
        const string schema = "comparevi-cli/history-run@v1";
        const string lane = "history-run";
        const string command = "history run";

        if (!ValidateCommandOptions(
                args,
                startIndex: tailStart,
                valueOptions: new[] { "--input", "--in", "--repo", "--mode", "--max-pairs", "--timeout", "--out-dir", "--exit-code", "--failure-class" },
                flagOptions: new[] { "--dry-run", "--diff", "--non-interactive", "--headless" },
                out var optionError))
        {
            Console.Error.WriteLine(optionError);
            return 2;
        }

        var inputValue = ReadInputPathAlias(args, tailStart);
        if (string.IsNullOrWhiteSpace(inputValue))
        {
            Console.Error.WriteLine("Missing required option: --input <file>");
            return 2;
        }

        if (!TryReadNullableIntOption(args, tailStart, "--max-pairs", out var maxPairs, out optionError))
        {
            Console.Error.WriteLine(optionError);
            return 2;
        }

        if (!TryReadNullableIntOption(args, tailStart, "--timeout", out var timeoutSeconds, out optionError))
        {
            Console.Error.WriteLine(optionError);
            return 2;
        }

        var outDir = ResolveOutputDirectory(args, tailStart);
        var headless = HasFlag(args, tailStart, "--headless");
        var nonInteractive = HasFlag(args, tailStart, "--non-interactive");
        var artifacts = BuildArtifactPaths(lane, outDir);
        var runLog = new StringBuilder();
        runLog.AppendLine($"[{DateTimeOffset.UtcNow:O}] comparevi-cli {command} real execution started.");

        try
        {
            if (nonInteractive && !headless)
            {
                return EmitPolicyFailure(schema, lane, command, outDir, artifacts, headless, nonInteractive, runLog, serializerOptions);
            }

            var repoPath = ResolveRepoPath(args, tailStart);
            var scriptsRoot = ResolveScriptsRoot(repoPath);
            var invokeHistoryScript = ResolveToolScriptPath(scriptsRoot, "Invoke-PRVIHistory.ps1");
            var invokeScriptPath = ResolveOptionalInvokeScriptPath(repoPath);
            var modeValues = NormalizeModeList(ReadOptionValueList(args, tailStart, "--mode"));
            var inputPath = ResolvePathFromRepo(inputValue!, repoPath);
            var backendRoot = PrepareBackendRoot(outDir);
            var backendResultsRoot = Path.Combine(backendRoot, "history");
            var backendSummaryPath = Path.Combine(backendRoot, "vi-history-backend-summary.json");

            if (!File.Exists(inputPath))
            {
                throw CreatePreflightFailure($"Input manifest file not found: {inputPath}", "input-missing");
            }

            var manifest = LoadJsonObject(inputPath, "history manifest");
            EnsureManifestSchema(manifest, "vi-diff-manifest@v1", inputPath);

            JsonObject backendSummary;
            if (GetArray(manifest, "pairs").Count == 0)
            {
                Directory.CreateDirectory(backendResultsRoot);
                backendSummary = CreateEmptyHistorySummary(inputPath, backendResultsRoot, maxPairs, modeValues);
                WriteJsonToFile(backendSummary, backendSummaryPath, serializerOptions);
            }
            else
            {
                Directory.CreateDirectory(backendResultsRoot);
                var historyArgs = new List<string>
                {
                    "-ManifestPath", inputPath,
                    "-ResultsRoot", backendResultsRoot,
                    "-SummaryPath", backendSummaryPath
                };
                AddOptionalIntArgument(historyArgs, "-MaxPairs", NormalizePositiveInt(maxPairs));
                AddOptionalIntArgument(historyArgs, "-CompareTimeoutSeconds", NormalizePositiveInt(timeoutSeconds));
                AddOptionalArrayArgument(historyArgs, "-Mode", modeValues);
                AddOptionalPathArgument(historyArgs, "-InvokeScriptPath", invokeScriptPath);
                EnsureScriptSucceeded(
                    InvokePwshScript(invokeHistoryScript, repoPath, historyArgs, scriptsRoot, runLog),
                    command,
                    "history-run");
                backendSummary = LoadJsonObject(backendSummaryPath, "history summary");
                EnsureManifestSchema(backendSummary, "pr-vi-history-summary@v1", backendSummaryPath);
            }

            var payload = BuildHistoryLanePayload(
                schema: schema,
                lane: lane,
                command: command,
                outDir: outDir,
                artifacts: artifacts,
                headless: headless,
                nonInteractive: nonInteractive,
                backendSummary: backendSummary,
                backendSummaryPath: backendSummaryPath,
                backendResultsRoot: backendResultsRoot,
                runLog: runLog,
                serializerOptions: serializerOptions,
                extraFields: new JsonObject
                {
                    ["repoPath"] = repoPath,
                    ["inputPath"] = inputPath,
                    ["maxPairs"] = NormalizePositiveInt(maxPairs),
                    ["timeoutSeconds"] = NormalizePositiveInt(timeoutSeconds),
                    ["mode"] = modeValues.Count > 0 ? new JsonArray(modeValues.Select(v => (JsonNode?)v).ToArray()) : null,
                    ["truncated"] = DetermineHistoryTruncation(backendSummary)
                });

            Console.WriteLine(payload.ToJsonString(serializerOptions));
            return 0;
        }
        catch (CliFailureException ex)
        {
            return EmitFailurePayload(schema, lane, command, outDir, artifacts, headless, nonInteractive, ex, runLog, serializerOptions);
        }
    }

    public static int RunReportConsolidate(string[] args, int tailStart, JsonSerializerOptions serializerOptions)
    {
        const string schema = "comparevi-cli/report-consolidate@v1";
        const string lane = "report-consolidate";
        const string command = "report consolidate";

        if (!ValidateCommandOptions(
                args,
                startIndex: tailStart,
                valueOptions: new[] { "--input", "--in", "--repo", "--out-dir" },
                flagOptions: new[] { "--dry-run", "--non-interactive", "--headless" },
                out var optionError))
        {
            Console.Error.WriteLine(optionError);
            return 2;
        }

        var inputValue = ReadInputPathAlias(args, tailStart);
        if (string.IsNullOrWhiteSpace(inputValue))
        {
            Console.Error.WriteLine("Missing required option: --input <file>");
            return 2;
        }

        var outDir = ResolveOutputDirectory(args, tailStart);
        var headless = HasFlag(args, tailStart, "--headless");
        var nonInteractive = HasFlag(args, tailStart, "--non-interactive");
        var artifacts = BuildArtifactPaths(lane, outDir);
        var runLog = new StringBuilder();
        runLog.AppendLine($"[{DateTimeOffset.UtcNow:O}] comparevi-cli {command} real execution started.");

        try
        {
            if (nonInteractive && !headless)
            {
                return EmitPolicyFailure(schema, lane, command, outDir, artifacts, headless, nonInteractive, runLog, serializerOptions);
            }

            var repoPath = ResolveRepoPath(args, tailStart);
            var scriptsRoot = ResolveScriptsRoot(repoPath);
            var renderScript = ResolveToolScriptPath(scriptsRoot, "Render-VIHistoryReport.ps1");
            var extractScript = ResolveToolScriptPath(scriptsRoot, "Extract-VIHistoryReportImages.ps1");
            var inputPath = ResolvePathFromRepo(inputValue!, repoPath);

            if (!File.Exists(inputPath))
            {
                throw CreatePreflightFailure($"Input manifest file not found: {inputPath}", "input-missing");
            }

            var backendRoot = PrepareBackendRoot(outDir);
            var sourceManifest = LoadJsonObject(inputPath, "report manifest");
            var sourceSchema = GetOptionalString(sourceManifest, "schema") ?? string.Empty;
            var suiteManifestPath = sourceSchema switch
            {
                "vi-compare/history-suite@v1" => inputPath,
                "vi-compare/history@v1" => CreateReportWrapperManifest(sourceManifest, inputPath, backendRoot, serializerOptions),
                _ => throw CreatePreflightFailure(
                    $"Unsupported report manifest schema '{sourceSchema}' at {inputPath}.",
                    "report-schema-unsupported")
            };

            var historyContextPath = ResolveSiblingHistoryContextPath(suiteManifestPath);
            var renderArgs = new List<string>
            {
                "-ManifestPath", suiteManifestPath,
                "-OutputDir", outDir,
                "-MarkdownPath", artifacts.SummaryMarkdownPath,
                "-HtmlPath", artifacts.ReportHtmlPath,
                "-EmitHtml"
            };
            AddOptionalPathArgument(renderArgs, "-HistoryContextPath", historyContextPath);
            EnsureScriptSucceeded(
                InvokePwshScript(renderScript, repoPath, renderArgs, scriptsRoot, runLog),
                command,
                "render-report");

            JsonObject imageIndex;
            if (File.Exists(artifacts.ReportHtmlPath))
            {
                var extractArgs = new List<string>
                {
                    "-ReportPath", artifacts.ReportHtmlPath,
                    "-OutputDir", Path.Combine(outDir, "previews"),
                    "-IndexPath", artifacts.ImageIndexPath
                };
                EnsureScriptSucceeded(
                    InvokePwshScript(extractScript, repoPath, extractArgs, scriptsRoot, runLog),
                    command,
                    "extract-images");
                imageIndex = BuildCliImageIndexFromReportExtract(artifacts.ImageIndexPath);
            }
            else
            {
                imageIndex = CreateEmptyCliImageIndex();
            }

            var suiteManifest = LoadJsonObject(suiteManifestPath, "history suite manifest");
            var itemsEnvelope = BuildItemsFromSuiteManifest(suiteManifest);
            var diffCount = GetNestedInt(suiteManifest, "stats", "diffs");
            var isDiff = diffCount > 0;
            var payload = new JsonObject
            {
                ["schema"] = schema,
                ["schemaVersion"] = SchemaVersion,
                ["schemaCompatibility"] = BuildSchemaCompatibility(),
                ["lane"] = lane,
                ["command"] = command,
                ["generatedAtUtc"] = DateTimeOffset.UtcNow.ToString("O"),
                ["repoPath"] = repoPath,
                ["inputPath"] = inputPath,
                ["sourceSchema"] = sourceSchema,
                ["suiteManifestPath"] = suiteManifestPath,
                ["headless"] = headless,
                ["nonInteractive"] = nonInteractive,
                ["outDir"] = outDir,
                ["artifacts"] = CreateArtifactObject(artifacts),
                ["summaryJsonPath"] = artifacts.SummaryJsonPath,
                ["summaryMarkdownPath"] = artifacts.SummaryMarkdownPath,
                ["reportHtmlPath"] = artifacts.ReportHtmlPath,
                ["consolidatedReportPath"] = artifacts.ReportHtmlPath,
                ["imageIndexPath"] = artifacts.ImageIndexPath,
                ["runLogPath"] = artifacts.RunLogPath,
                ["manifest"] = suiteManifest.DeepClone(),
                ["items"] = itemsEnvelope.Items,
                ["timing"] = itemsEnvelope.Timing,
                ["timingSummary"] = itemsEnvelope.TimingSummary,
                ["imageIndex"] = imageIndex,
                ["outcome"] = new JsonObject
                {
                    ["class"] = "pass",
                    ["kind"] = isDiff ? "diff" : "no_diff"
                },
                ["resultClass"] = isDiff ? "success-diff" : "success-no-diff",
                ["isDiff"] = isDiff,
                ["gateOutcome"] = "pass",
                ["failureClass"] = "none"
            };

            MaterializeCliArtifacts(
                payload,
                artifacts,
                imageIndex,
                runLog,
                serializerOptions,
                markdownSourcePath: artifacts.SummaryMarkdownPath,
                htmlSourcePath: artifacts.ReportHtmlPath);

            Console.WriteLine(payload.ToJsonString(serializerOptions));
            return 0;
        }
        catch (CliFailureException ex)
        {
            return EmitFailurePayload(schema, lane, command, outDir, artifacts, headless, nonInteractive, ex, runLog, serializerOptions);
        }
    }

    private static bool ValidateCommandOptions(
        string[] args,
        int startIndex,
        IEnumerable<string> valueOptions,
        IEnumerable<string> flagOptions,
        out string? error)
    {
        var valueSet = new HashSet<string>(valueOptions, StringComparer.OrdinalIgnoreCase);
        var flagSet = new HashSet<string>(flagOptions, StringComparer.OrdinalIgnoreCase);

        for (var i = startIndex; i < args.Length; i++)
        {
            var token = args[i];
            if (!token.StartsWith("--", StringComparison.Ordinal))
            {
                error = $"Unexpected argument: {token}";
                return false;
            }

            if (valueSet.Contains(token))
            {
                if (i + 1 >= args.Length || args[i + 1].StartsWith("--", StringComparison.Ordinal))
                {
                    error = $"Missing value for option: {token}";
                    return false;
                }

                i++;
                continue;
            }

            if (flagSet.Contains(token))
            {
                continue;
            }

            error = $"Unknown option: {token}";
            return false;
        }

        error = null;
        return true;
    }

    private static bool TryReadOption(string[] args, int startIndex, string option, out string? value)
    {
        for (var i = startIndex; i < args.Length; i++)
        {
            if (args[i].Equals(option, StringComparison.OrdinalIgnoreCase) && i + 1 < args.Length)
            {
                value = args[i + 1];
                return true;
            }
        }

        value = null;
        return false;
    }

    private static bool HasFlag(string[] args, int startIndex, string flag)
    {
        for (var i = startIndex; i < args.Length; i++)
        {
            if (args[i].Equals(flag, StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }
        }

        return false;
    }

    private static bool HasOption(string[] args, int startIndex, string option)
    {
        for (var i = startIndex; i < args.Length; i++)
        {
            if (args[i].Equals(option, StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }
        }

        return false;
    }

    private static bool TryReadNullableIntOption(string[] args, int startIndex, string option, out int? value, out string? error)
    {
        error = null;
        if (!HasOption(args, startIndex, option))
        {
            value = null;
            return true;
        }

        if (!TryReadOption(args, startIndex, option, out var raw) || string.IsNullOrWhiteSpace(raw) || !int.TryParse(raw, out var parsed))
        {
            value = null;
            error = $"Invalid value for option: {option} <int>";
            return false;
        }

        value = parsed;
        return true;
    }

    private static List<string> ReadOptionValueList(string[] args, int startIndex, string option)
    {
        var values = new List<string>();
        for (var i = startIndex; i < args.Length; i++)
        {
            if (!args[i].Equals(option, StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            if (i + 1 >= args.Length)
            {
                break;
            }

            var raw = args[++i];
            foreach (var candidate in raw.Split(new[] { ',', ';' }, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
            {
                if (!string.IsNullOrWhiteSpace(candidate))
                {
                    values.Add(candidate);
                }
            }
        }

        return values;
    }

    private static string? ReadInputPathAlias(string[] args, int startIndex)
    {
        if (TryReadOption(args, startIndex, "--input", out var input) && !string.IsNullOrWhiteSpace(input))
        {
            return input;
        }

        if (TryReadOption(args, startIndex, "--in", out input) && !string.IsNullOrWhiteSpace(input))
        {
            return input;
        }

        return null;
    }

    private static string ResolveOutputDirectory(string[] args, int startIndex)
    {
        if (TryReadOption(args, startIndex, "--out-dir", out var outDirValue) && !string.IsNullOrWhiteSpace(outDirValue))
        {
            return Path.GetFullPath(outDirValue!);
        }

        return Path.GetFullPath(Environment.CurrentDirectory);
    }

    private static string ResolveRepoPath(string[] args, int startIndex)
    {
        var repoPath = Environment.CurrentDirectory;
        if (TryReadOption(args, startIndex, "--repo", out var repoOption) && !string.IsNullOrWhiteSpace(repoOption))
        {
            repoPath = repoOption!;
        }

        var resolved = Path.GetFullPath(repoPath);
        if (!Directory.Exists(resolved))
        {
            throw CreatePreflightFailure($"Repository path does not exist: {resolved}", "repo-path-missing");
        }

        return resolved;
    }

    private static string ResolvePathFromRepo(string path, string repoPath)
    {
        return Path.IsPathRooted(path)
            ? Path.GetFullPath(path)
            : Path.GetFullPath(Path.Combine(repoPath, path));
    }

    private static string? NormalizeRepoRelativePath(string? value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return null;
        }

        return value.Replace('\\', '/').Trim();
    }

    private static string NormalizeTargetFilter(string value, string repoPath)
    {
        if (Path.IsPathRooted(value))
        {
            var relative = Path.GetRelativePath(repoPath, value);
            return NormalizeRepoRelativePath(relative) ?? value;
        }

        return NormalizeRepoRelativePath(value) ?? value;
    }

    private static string EscapeMarkdownCell(string value)
    {
        return value.Replace("|", "\\|", StringComparison.Ordinal);
    }

    private static JsonObject BuildSchemaCompatibility()
    {
        return new JsonObject
        {
            ["policy"] = "additive-within-major",
            ["majorVersion"] = 1
        };
    }

    private static string MapOutcomeKind(string resultClass, string failureClass)
    {
        if (string.Equals(resultClass, "success-diff", StringComparison.OrdinalIgnoreCase))
        {
            return "diff";
        }

        if (string.Equals(resultClass, "success-no-diff", StringComparison.OrdinalIgnoreCase))
        {
            return "no_diff";
        }

        return failureClass.ToLowerInvariant() switch
        {
            "preflight" => "preflight_error",
            "runtime-determinism" => "runtime_error",
            "timeout" => "timeout",
            _ => "tool_error"
        };
    }

    private static JsonObject LoadJsonObject(string path, string description)
    {
        if (!File.Exists(path))
        {
            throw CreatePreflightFailure($"{description} file not found: {path}", "json-missing");
        }

        var node = JsonNode.Parse(File.ReadAllText(path));
        if (node is not JsonObject obj)
        {
            throw CreatePreflightFailure($"{description} at {path} is not a JSON object.", "json-invalid");
        }

        return obj;
    }

    private static void WriteJsonToFile(JsonNode node, string path, JsonSerializerOptions serializerOptions)
    {
        EnsureDirectoryForFile(path);
        File.WriteAllText(path, node.ToJsonString(serializerOptions), Encoding.UTF8);
    }

    private static JsonObject GetObject(JsonObject root, string propertyName)
    {
        return root[propertyName] as JsonObject ?? new JsonObject();
    }

    private static JsonArray GetArray(JsonObject root, string propertyName)
    {
        return root[propertyName] as JsonArray ?? new JsonArray();
    }

    private static string? GetOptionalString(JsonObject root, string propertyName)
    {
        return root[propertyName]?.GetValue<string>();
    }

    private static string? GetNestedString(JsonObject root, string objectPropertyName, string propertyName)
    {
        return GetObject(root, objectPropertyName)[propertyName]?.GetValue<string>();
    }

    private static int? GetOptionalInt(JsonObject root, string propertyName)
    {
        try
        {
            return root[propertyName]?.GetValue<int>();
        }
        catch
        {
            return null;
        }
    }

    private static int GetNestedInt(JsonObject root, string objectPropertyName, string propertyName)
    {
        return GetOptionalInt(GetObject(root, objectPropertyName), propertyName) ?? 0;
    }

    private static double GetOptionalDouble(JsonObject root, string propertyName)
    {
        try
        {
            return root[propertyName]?.GetValue<double>() ?? 0;
        }
        catch
        {
            return 0;
        }
    }

    private static bool? GetOptionalBool(JsonObject root, string propertyName)
    {
        try
        {
            return root[propertyName]?.GetValue<bool>();
        }
        catch
        {
            return null;
        }
    }

    private static JsonObject CreateDiagnostic(string code, string message)
    {
        return new JsonObject
        {
            ["code"] = code,
            ["severity"] = "error",
            ["message"] = message
        };
    }

    private static CliFailureException CreatePreflightFailure(string message, string code)
    {
        return new CliFailureException("preflight", message, new List<JsonObject> { CreateDiagnostic(code, message) });
    }

    private static CliFailureException CreateToolFailure(string message, string code)
    {
        return new CliFailureException("tool", message, new List<JsonObject> { CreateDiagnostic(code, message) });
    }

    private static int EmitPolicyFailure(
        string schema,
        string lane,
        string command,
        string outDir,
        CliArtifactPaths artifacts,
        bool headless,
        bool nonInteractive,
        StringBuilder runLog,
        JsonSerializerOptions serializerOptions)
    {
        var ex = new CliFailureException(
            "preflight",
            "Non-interactive execution requires explicit --headless opt-in.",
            new List<JsonObject>
            {
                CreateDiagnostic("headless-required", "Non-interactive execution requires explicit --headless opt-in.")
            });
        return EmitFailurePayload(schema, lane, command, outDir, artifacts, headless, nonInteractive, ex, runLog, serializerOptions);
    }

    private static int EmitFailurePayload(
        string schema,
        string lane,
        string command,
        string outDir,
        CliArtifactPaths artifacts,
        bool headless,
        bool nonInteractive,
        CliFailureException ex,
        StringBuilder runLog,
        JsonSerializerOptions serializerOptions)
    {
        runLog.AppendLine($"[{DateTimeOffset.UtcNow:O}] failureClass={ex.FailureClass}");
        runLog.AppendLine(ex.Message);

        var resultClass = ex.FailureClass switch
        {
            "preflight" => "failure-preflight",
            "timeout" => "failure-timeout",
            "runtime-determinism" => "failure-runtime",
            _ => "failure-tool"
        };
        var imageIndex = CreateEmptyCliImageIndex();
        var diagnostics = new JsonArray();
        foreach (var diagnostic in ex.Diagnostics ?? Array.Empty<JsonObject>())
        {
            diagnostics.Add(diagnostic.DeepClone());
        }

        var payload = new JsonObject
        {
            ["schema"] = schema,
            ["schemaVersion"] = SchemaVersion,
            ["schemaCompatibility"] = BuildSchemaCompatibility(),
            ["lane"] = lane,
            ["command"] = command,
            ["generatedAtUtc"] = DateTimeOffset.UtcNow.ToString("O"),
            ["headless"] = headless,
            ["nonInteractive"] = nonInteractive,
            ["outDir"] = outDir,
            ["artifacts"] = CreateArtifactObject(artifacts),
            ["summaryJsonPath"] = artifacts.SummaryJsonPath,
            ["summaryMarkdownPath"] = artifacts.SummaryMarkdownPath,
            ["reportHtmlPath"] = artifacts.ReportHtmlPath,
            ["consolidatedReportPath"] = artifacts.ReportHtmlPath,
            ["imageIndexPath"] = artifacts.ImageIndexPath,
            ["runLogPath"] = artifacts.RunLogPath,
            ["imageIndex"] = imageIndex,
            ["items"] = new JsonArray(),
            ["timing"] = CreateTimingNode(DateTimeOffset.UtcNow, Array.Empty<double>()),
            ["timingSummary"] = CreateTimingSummaryNode(Array.Empty<double>()),
            ["diagnostics"] = diagnostics,
            ["outcome"] = new JsonObject
            {
                ["class"] = "fail",
                ["kind"] = MapOutcomeKind(resultClass, ex.FailureClass)
            },
            ["resultClass"] = resultClass,
            ["isDiff"] = false,
            ["gateOutcome"] = "fail",
            ["failureClass"] = ex.FailureClass
        };

        MaterializeCliArtifacts(payload, artifacts, imageIndex, runLog, serializerOptions);
        Console.WriteLine(payload.ToJsonString(serializerOptions));
        return 1;
    }

    private static JsonObject BuildHistoryLanePayload(
        string schema,
        string lane,
        string command,
        string outDir,
        CliArtifactPaths artifacts,
        bool headless,
        bool nonInteractive,
        JsonObject backendSummary,
        string backendSummaryPath,
        string backendResultsRoot,
        StringBuilder runLog,
        JsonSerializerOptions serializerOptions,
        JsonObject? extraFields)
    {
        var itemsEnvelope = BuildItemsFromPairTimeline(GetArray(backendSummary, "pairTimeline"), GetOptionalString(backendSummary, "generatedAt"));
        var imageIndex = MergeHistoryImageIndexes(backendSummary);
        var isDiff = GetNestedInt(backendSummary, "totals", "diffs") > 0;
        var payload = new JsonObject
        {
            ["schema"] = schema,
            ["schemaVersion"] = SchemaVersion,
            ["schemaCompatibility"] = BuildSchemaCompatibility(),
            ["lane"] = lane,
            ["command"] = command,
            ["generatedAtUtc"] = DateTimeOffset.UtcNow.ToString("O"),
            ["headless"] = headless,
            ["nonInteractive"] = nonInteractive,
            ["outDir"] = outDir,
            ["artifacts"] = CreateArtifactObject(artifacts),
            ["summaryJsonPath"] = artifacts.SummaryJsonPath,
            ["summaryMarkdownPath"] = artifacts.SummaryMarkdownPath,
            ["reportHtmlPath"] = artifacts.ReportHtmlPath,
            ["consolidatedReportPath"] = artifacts.ReportHtmlPath,
            ["imageIndexPath"] = artifacts.ImageIndexPath,
            ["runLogPath"] = artifacts.RunLogPath,
            ["backendSummaryPath"] = backendSummaryPath,
            ["backendResultsRoot"] = backendResultsRoot,
            ["backendSummary"] = backendSummary.DeepClone(),
            ["manifest"] = backendSummary.DeepClone(),
            ["targets"] = GetArray(backendSummary, "targets").DeepClone(),
            ["pairTimeline"] = GetArray(backendSummary, "pairTimeline").DeepClone(),
            ["totals"] = GetObject(backendSummary, "totals").DeepClone(),
            ["timing"] = itemsEnvelope.Timing,
            ["timingSummary"] = itemsEnvelope.TimingSummary,
            ["items"] = itemsEnvelope.Items,
            ["imageIndex"] = imageIndex,
            ["outcome"] = new JsonObject
            {
                ["class"] = "pass",
                ["kind"] = isDiff ? "diff" : "no_diff"
            },
            ["resultClass"] = isDiff ? "success-diff" : "success-no-diff",
            ["isDiff"] = isDiff,
            ["gateOutcome"] = "pass",
            ["failureClass"] = "none"
        };

        if (extraFields is not null)
        {
            foreach (var item in extraFields)
            {
                payload[item.Key] = item.Value?.DeepClone();
            }
        }

        var backendMarkdownPath = Path.Combine(backendResultsRoot, "history-report.md");
        var backendHtmlPath = Path.Combine(backendResultsRoot, "history-report.html");
        runLog.AppendLine($"[{DateTimeOffset.UtcNow:O}] backendSummaryPath={backendSummaryPath}");
        runLog.AppendLine($"[{DateTimeOffset.UtcNow:O}] backendResultsRoot={backendResultsRoot}");

        MaterializeCliArtifacts(payload, artifacts, imageIndex, runLog, serializerOptions, backendMarkdownPath, backendHtmlPath);
        return payload;
    }

    private static void MaterializeCliArtifacts(
        JsonObject payload,
        CliArtifactPaths artifacts,
        JsonObject imageIndex,
        StringBuilder runLog,
        JsonSerializerOptions serializerOptions,
        string? markdownSourcePath = null,
        string? htmlSourcePath = null)
    {
        WriteJsonToFile(payload, artifacts.SummaryJsonPath, serializerOptions);
        WriteTextArtifact(markdownSourcePath, artifacts.SummaryMarkdownPath, BuildFallbackMarkdown(payload));
        WriteTextArtifact(htmlSourcePath, artifacts.ReportHtmlPath, BuildFallbackHtml(payload));
        WriteJsonToFile(imageIndex, artifacts.ImageIndexPath, serializerOptions);
        File.WriteAllText(artifacts.RunLogPath, runLog.ToString(), Encoding.UTF8);
    }

    private static void WriteTextArtifact(string? sourcePath, string destinationPath, string fallbackContent)
    {
        EnsureDirectoryForFile(destinationPath);
        if (!string.IsNullOrWhiteSpace(sourcePath) && File.Exists(sourcePath))
        {
            if (!PathsEqual(sourcePath, destinationPath))
            {
                File.Copy(sourcePath, destinationPath, overwrite: true);
            }

            return;
        }

        File.WriteAllText(destinationPath, fallbackContent, Encoding.UTF8);
    }

    private static string BuildFallbackMarkdown(JsonObject payload)
    {
        var lines = new List<string>
        {
            "# comparevi-cli lane summary",
            string.Empty,
            $"- command: `{EscapeMarkdownCell(GetOptionalString(payload, "command") ?? "unknown")}`",
            $"- gateOutcome: `{EscapeMarkdownCell(GetOptionalString(payload, "gateOutcome") ?? "unknown")}`",
            $"- resultClass: `{EscapeMarkdownCell(GetOptionalString(payload, "resultClass") ?? "unknown")}`"
        };

        if (GetOptionalString(payload, "base") is string baseRef && !string.IsNullOrWhiteSpace(baseRef))
        {
            lines.Add($"- base: `{EscapeMarkdownCell(baseRef)}`");
        }

        if (GetOptionalString(payload, "head") is string headRef && !string.IsNullOrWhiteSpace(headRef))
        {
            lines.Add($"- head: `{EscapeMarkdownCell(headRef)}`");
        }

        if (GetOptionalString(payload, "inputPath") is string inputPath && !string.IsNullOrWhiteSpace(inputPath))
        {
            lines.Add($"- inputPath: `{EscapeMarkdownCell(inputPath)}`");
        }

        return string.Join(Environment.NewLine, lines) + Environment.NewLine;
    }

    private static string BuildFallbackHtml(JsonObject payload)
    {
        var command = WebUtility.HtmlEncode(GetOptionalString(payload, "command") ?? "unknown");
        var gateOutcome = WebUtility.HtmlEncode(GetOptionalString(payload, "gateOutcome") ?? "unknown");
        var resultClass = WebUtility.HtmlEncode(GetOptionalString(payload, "resultClass") ?? "unknown");

        return $@"<!DOCTYPE html>
<html lang=""en"">
<head><meta charset=""utf-8""/><title>comparevi-cli lane report</title></head>
<body>
  <h1>comparevi-cli lane report</h1>
  <ul>
    <li>command: {command}</li>
    <li>gateOutcome: {gateOutcome}</li>
    <li>resultClass: {resultClass}</li>
  </ul>
</body>
</html>";
    }

    private static JsonObject CreateArtifactObject(CliArtifactPaths artifacts)
    {
        return new JsonObject
        {
            ["summaryJsonPath"] = artifacts.SummaryJsonPath,
            ["summaryMarkdownPath"] = artifacts.SummaryMarkdownPath,
            ["reportHtmlPath"] = artifacts.ReportHtmlPath,
            ["imageIndexPath"] = artifacts.ImageIndexPath,
            ["runLogPath"] = artifacts.RunLogPath
        };
    }

    private static CliArtifactPaths BuildArtifactPaths(string lane, string outDir)
    {
        var prefix = lane switch
        {
            "compare-range" => "vi-history",
            "history-run" => "vi-history",
            "report-consolidate" => "vi-history",
            _ => lane
        };

        Directory.CreateDirectory(outDir);
        return new CliArtifactPaths(
            summaryJsonPath: Path.GetFullPath(Path.Combine(outDir, $"{prefix}-summary.json")),
            summaryMarkdownPath: Path.GetFullPath(Path.Combine(outDir, $"{prefix}-summary.md")),
            reportHtmlPath: Path.GetFullPath(Path.Combine(outDir, $"{prefix}-report.html")),
            imageIndexPath: Path.GetFullPath(Path.Combine(outDir, $"{prefix}-image-index.json")),
            runLogPath: Path.GetFullPath(Path.Combine(outDir, $"{prefix}.log")));
    }

    private static string PrepareBackendRoot(string outDir)
    {
        var backendRoot = Path.Combine(outDir, "_backend");
        Directory.CreateDirectory(backendRoot);
        return Path.GetFullPath(backendRoot);
    }

    private static List<string> NormalizeModeList(IEnumerable<string> rawValues)
    {
        var modes = new List<string>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var value in rawValues)
        {
            if (string.IsNullOrWhiteSpace(value))
            {
                continue;
            }

            var trimmed = value.Trim();
            if (seen.Add(trimmed))
            {
                modes.Add(trimmed);
            }
        }

        return modes;
    }

    private static List<string> NormalizeTargetFilters(string[] args, int startIndex, string repoPath)
    {
        var filters = new List<string>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var raw in ReadOptionValueList(args, startIndex, "--vi").Concat(ReadOptionValueList(args, startIndex, "--vi-list")))
        {
            if (string.IsNullOrWhiteSpace(raw))
            {
                continue;
            }

            var normalized = NormalizeTargetFilter(raw, repoPath);
            if (seen.Add(normalized))
            {
                filters.Add(normalized);
            }
        }

        return filters;
    }

    private static JsonObject FilterDiffManifest(JsonObject manifest, IReadOnlyCollection<string> filters)
    {
        if (filters.Count == 0)
        {
            return manifest;
        }

        var filterSet = new HashSet<string>(filters, StringComparer.OrdinalIgnoreCase);
        var selectedPairs = new JsonArray();
        foreach (var node in GetArray(manifest, "pairs"))
        {
            if (node is not JsonObject pair)
            {
                continue;
            }

            var basePath = NormalizeRepoRelativePath(GetOptionalString(pair, "basePath"));
            var headPath = NormalizeRepoRelativePath(GetOptionalString(pair, "headPath"));
            if ((basePath is not null && filterSet.Contains(basePath)) || (headPath is not null && filterSet.Contains(headPath)))
            {
                selectedPairs.Add(pair.DeepClone());
            }
        }

        var clone = manifest.DeepClone() as JsonObject ?? new JsonObject();
        clone["pairs"] = selectedPairs;
        return clone;
    }

    private static void EnsureManifestSchema(JsonObject manifest, string expectedSchema, string path)
    {
        var schema = GetOptionalString(manifest, "schema");
        if (!string.Equals(schema, expectedSchema, StringComparison.OrdinalIgnoreCase))
        {
            throw CreatePreflightFailure(
                $"Unexpected schema '{schema ?? "(missing)"}' at {path}. Expected '{expectedSchema}'.",
                "schema-mismatch");
        }
    }

    private static string ResolveScriptsRoot(string repoPath)
    {
        var candidates = new List<string>();
        AddCandidate(candidates, Environment.GetEnvironmentVariable("COMPAREVI_CLI_SCRIPTS_ROOT"));
        AddCandidate(candidates, Environment.GetEnvironmentVariable("COMPAREVI_SCRIPTS_ROOT"));
        AddCandidate(candidates, repoPath);

        var cursor = AppContext.BaseDirectory;
        while (!string.IsNullOrWhiteSpace(cursor))
        {
            AddCandidate(candidates, cursor);
            AddBundledCandidates(candidates, cursor);

            var parent = Directory.GetParent(cursor)?.FullName;
            if (string.IsNullOrWhiteSpace(parent) || string.Equals(parent, cursor, StringComparison.OrdinalIgnoreCase))
            {
                break;
            }

            cursor = parent;
        }

        foreach (var candidate in candidates.Distinct(StringComparer.OrdinalIgnoreCase))
        {
            if (TryNormalizeScriptsRoot(candidate, out var normalized))
            {
                return normalized;
            }
        }

        throw CreatePreflightFailure(
            "Unable to resolve CompareVI helper scripts. Set COMPAREVI_CLI_SCRIPTS_ROOT or COMPAREVI_SCRIPTS_ROOT.",
            "scripts-root-missing");
    }

    private static void AddCandidate(List<string> candidates, string? value)
    {
        if (!string.IsNullOrWhiteSpace(value))
        {
            candidates.Add(Path.GetFullPath(value));
        }
    }

    private static void AddBundledCandidates(List<string> candidates, string root)
    {
        if (!Directory.Exists(root))
        {
            return;
        }

        try
        {
            foreach (var directory in Directory.EnumerateDirectories(root, "CompareVI.Tools-v*"))
            {
                candidates.Add(Path.GetFullPath(directory));
            }
        }
        catch
        {
        }
    }

    private static bool TryNormalizeScriptsRoot(string candidate, out string normalized)
    {
        normalized = string.Empty;
        if (string.IsNullOrWhiteSpace(candidate))
        {
            return false;
        }

        candidate = Path.GetFullPath(candidate);
        if (Directory.Exists(candidate))
        {
            if (File.Exists(Path.Combine(candidate, "tools", "Invoke-PRVIHistory.ps1")) ||
                File.Exists(Path.Combine(candidate, "tools", "Compare-VIHistory.ps1")) ||
                File.Exists(Path.Combine(candidate, "tools", "Compare-RefsToTemp.ps1")))
            {
                normalized = candidate;
                return true;
            }

            if (File.Exists(Path.Combine(candidate, "Invoke-PRVIHistory.ps1")) ||
                File.Exists(Path.Combine(candidate, "Compare-VIHistory.ps1")) ||
                File.Exists(Path.Combine(candidate, "Compare-RefsToTemp.ps1")))
            {
                normalized = Directory.GetParent(candidate)?.FullName ?? candidate;
                return true;
            }
        }

        return false;
    }

    private static string ResolveToolScriptPath(string scriptsRoot, string scriptName)
    {
        var candidates = new[]
        {
            Path.Combine(scriptsRoot, "tools", scriptName),
            Path.Combine(scriptsRoot, scriptName)
        };
        foreach (var candidate in candidates)
        {
            if (File.Exists(candidate))
            {
                return Path.GetFullPath(candidate);
            }
        }

        throw CreatePreflightFailure($"Required helper script '{scriptName}' was not found under {scriptsRoot}.", "script-missing");
    }

    private static string? ResolveOptionalInvokeScriptPath(string repoPath)
    {
        foreach (var environmentVariable in new[]
                 {
                     "COMPAREVI_CLI_INVOKE_SCRIPT_PATH",
                     "COMPAREVI_INVOKE_SCRIPT_PATH"
                 })
        {
            var value = Environment.GetEnvironmentVariable(environmentVariable);
            if (string.IsNullOrWhiteSpace(value))
            {
                continue;
            }

            var resolved = ResolvePathFromRepo(value, repoPath);
            if (!File.Exists(resolved))
            {
                throw CreatePreflightFailure(
                    $"Invoke script override from {environmentVariable} was not found: {resolved}",
                    "invoke-script-missing");
            }

            return resolved;
        }

        return null;
    }

    private static ScriptInvocationResult InvokePwshScript(
        string scriptPath,
        string workingDirectory,
        IReadOnlyList<string> scriptArguments,
        string scriptsRoot,
        StringBuilder runLog)
    {
        var githubOutputPath = Path.Combine(Path.GetTempPath(), $"comparevi-cli-ghout-{Guid.NewGuid():N}.txt");
        try
        {
            var psi = new ProcessStartInfo
            {
                FileName = "pwsh",
                WorkingDirectory = workingDirectory,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true
            };

            psi.ArgumentList.Add("-NoLogo");
            psi.ArgumentList.Add("-NoProfile");
            psi.ArgumentList.Add("-File");
            psi.ArgumentList.Add(scriptPath);
            foreach (var argument in scriptArguments)
            {
                psi.ArgumentList.Add(argument);
            }

            psi.Environment["GITHUB_OUTPUT"] = githubOutputPath;
            psi.Environment["COMPAREVI_SCRIPTS_ROOT"] = scriptsRoot;
            psi.Environment["COMPAREVI_CLI_SCRIPTS_ROOT"] = scriptsRoot;

            runLog.AppendLine($"[{DateTimeOffset.UtcNow:O}] invoking {scriptPath}");
            runLog.AppendLine($"  cwd={workingDirectory}");
            runLog.AppendLine($"  args={string.Join(" ", scriptArguments.Select(FormatLogArgument))}");

            using var process = Process.Start(psi) ?? throw CreateToolFailure($"Failed to start PowerShell for {scriptPath}.", "pwsh-start-failed");
            var stdOut = process.StandardOutput.ReadToEnd();
            var stdErr = process.StandardError.ReadToEnd();
            process.WaitForExit();

            runLog.AppendLine($"  exit={process.ExitCode}");
            if (!string.IsNullOrWhiteSpace(stdOut))
            {
                runLog.AppendLine("  stdout:");
                runLog.AppendLine(IndentBlock(stdOut.TrimEnd()));
            }

            if (!string.IsNullOrWhiteSpace(stdErr))
            {
                runLog.AppendLine("  stderr:");
                runLog.AppendLine(IndentBlock(stdErr.TrimEnd()));
            }

            var outputs = File.Exists(githubOutputPath)
                ? ParseGitHubOutputFile(githubOutputPath)
                : new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            return new ScriptInvocationResult(process.ExitCode, stdOut, stdErr, outputs);
        }
        finally
        {
            try
            {
                if (File.Exists(githubOutputPath))
                {
                    File.Delete(githubOutputPath);
                }
            }
            catch
            {
            }
        }
    }

    private static void EnsureScriptSucceeded(ScriptInvocationResult result, string command, string phase)
    {
        if (result.ExitCode == 0)
        {
            return;
        }

        var message = new StringBuilder();
        message.Append($"{command} failed during {phase}");
        message.Append($" (exit {result.ExitCode})");
        if (!string.IsNullOrWhiteSpace(result.StdErr))
        {
            message.Append($": {result.StdErr.Trim()}");
        }
        else if (!string.IsNullOrWhiteSpace(result.StdOut))
        {
            message.Append($": {result.StdOut.Trim()}");
        }

        throw CreateToolFailure(message.ToString(), $"{phase}-failed");
    }

    private static Dictionary<string, string> ParseGitHubOutputFile(string path)
    {
        var outputs = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        var lines = File.ReadAllLines(path);
        for (var i = 0; i < lines.Length; i++)
        {
            var line = lines[i];
            if (string.IsNullOrWhiteSpace(line))
            {
                continue;
            }

            var heredocIndex = line.IndexOf("<<", StringComparison.Ordinal);
            if (heredocIndex > 0)
            {
                var key = line[..heredocIndex];
                var delimiter = line[(heredocIndex + 2)..];
                var valueBuilder = new StringBuilder();
                i++;
                while (i < lines.Length && !string.Equals(lines[i], delimiter, StringComparison.Ordinal))
                {
                    if (valueBuilder.Length > 0)
                    {
                        valueBuilder.AppendLine();
                    }

                    valueBuilder.Append(lines[i]);
                    i++;
                }

                outputs[key] = valueBuilder.ToString();
                continue;
            }

            var separatorIndex = line.IndexOf('=');
            if (separatorIndex <= 0)
            {
                continue;
            }

            outputs[line[..separatorIndex]] = line[(separatorIndex + 1)..];
        }

        return outputs;
    }

    private static JsonObject CreateEmptyHistorySummary(string manifestPath, string resultsRoot, int? maxPairs, IReadOnlyList<string> modes)
    {
        var timing = CreateBackendTimingSummary(Array.Empty<double>());
        return new JsonObject
        {
            ["schema"] = "pr-vi-history-summary@v1",
            ["generatedAt"] = DateTimeOffset.UtcNow.ToString("O"),
            ["manifest"] = manifestPath,
            ["resultsRoot"] = resultsRoot,
            ["maxPairs"] = NormalizePositiveInt(maxPairs),
            ["modes"] = modes.Count > 0 ? new JsonArray(modes.Select(v => (JsonNode?)v).ToArray()) : null,
            ["totals"] = new JsonObject
            {
                ["targets"] = 0,
                ["completed"] = 0,
                ["diffTargets"] = 0,
                ["comparisons"] = 0,
                ["diffs"] = 0,
                ["errors"] = 0,
                ["skippedEntries"] = 0,
                ["imageTargets"] = 0,
                ["extractedImages"] = 0,
                ["imageErrors"] = 0,
                ["pairRows"] = 0,
                ["diffPairRows"] = 0,
                ["durationSeconds"] = 0,
                ["durationSamples"] = 0,
                ["timing"] = timing.DeepClone(),
                ["estimatedCompareTime"] = GetObject(timing, "estimatedCompareTime").DeepClone()
            },
            ["targets"] = new JsonArray(),
            ["pairTimeline"] = new JsonArray(),
            ["timing"] = timing,
            ["estimatedCompareTime"] = GetObject(timing, "estimatedCompareTime").DeepClone(),
            ["kpi"] = new JsonObject
            {
                ["pairRows"] = 0,
                ["diffPairs"] = 0,
                ["signalDiffPairs"] = 0,
                ["noiseMasscompileDiffPairs"] = 0,
                ["noiseCosmeticDiffPairs"] = 0,
                ["previewPresentPairs"] = 0,
                ["commentTruncated"] = false,
                ["truncationReason"] = "none"
            }
        };
    }

    private static JsonObject CreateBackendTimingSummary(IReadOnlyList<double> durationsSeconds)
    {
        if (durationsSeconds.Count == 0)
        {
            return new JsonObject
            {
                ["comparisonCount"] = 0,
                ["minSeconds"] = null,
                ["medianSeconds"] = null,
                ["p95Seconds"] = null,
                ["totalSeconds"] = 0,
                ["estimatedCompareTime"] = new JsonObject
                {
                    ["seconds"] = null,
                    ["source"] = "insufficient-data",
                    ["confidence"] = "low",
                    ["note"] = "No observed compare durations were available."
                }
            };
        }

        var sorted = durationsSeconds.Where(v => v >= 0).OrderBy(v => v).ToArray();
        var total = sorted.Sum();
        var median = ComputePercentile(sorted, 0.5);
        var p95 = ComputePercentile(sorted, 0.95);
        return new JsonObject
        {
            ["comparisonCount"] = sorted.Length,
            ["minSeconds"] = Math.Round(sorted[0], 3),
            ["medianSeconds"] = Math.Round(median, 3),
            ["p95Seconds"] = Math.Round(p95, 3),
            ["totalSeconds"] = Math.Round(total, 3),
            ["estimatedCompareTime"] = new JsonObject
            {
                ["seconds"] = Math.Round(sorted.Length >= 5 ? p95 : median, 3),
                ["source"] = "observed-durations",
                ["confidence"] = sorted.Length >= 8 ? "medium" : sorted.Length >= 3 ? "low" : "very-low",
                ["note"] = "Heuristic seed based on observed per-comparison durations."
            }
        };
    }

    private static ItemsEnvelope BuildItemsFromPairTimeline(JsonArray pairTimeline, string? generatedAt)
    {
        var items = new JsonArray();
        var durationsMs = new List<double>();
        var start = ParseDateTimeOffset(generatedAt) ?? DateTimeOffset.UtcNow;
        var offsetMs = 0.0;
        var order = 1;

        foreach (var node in pairTimeline)
        {
            if (node is not JsonObject pair)
            {
                continue;
            }

            var durationMs = Math.Max(0, GetOptionalDouble(pair, "durationSeconds") * 1000.0);
            durationsMs.Add(durationMs);
            var itemStart = start.AddMilliseconds(offsetMs);
            var itemEnd = itemStart.AddMilliseconds(durationMs);
            offsetMs += durationMs;

            var targetPath = GetOptionalString(pair, "targetPath");
            var mode = GetOptionalString(pair, "mode");
            var pairIndex = GetOptionalInt(pair, "pairIndex") ?? order;
            var itemId = SanitizeItemId($"{targetPath ?? "target"}-{mode ?? "mode"}-{pairIndex}");
            items.Add(new JsonObject
            {
                ["id"] = itemId,
                ["order"] = order,
                ["targetPath"] = targetPath,
                ["mode"] = mode,
                ["pairIndex"] = pairIndex,
                ["baseRef"] = GetOptionalString(pair, "baseRef"),
                ["headRef"] = GetOptionalString(pair, "headRef"),
                ["diff"] = GetOptionalBool(pair, "diff") ?? false,
                ["classification"] = GetOptionalString(pair, "classification"),
                ["previewStatus"] = GetOptionalString(pair, "previewStatus"),
                ["reportPath"] = GetOptionalString(pair, "reportPath"),
                ["imageIndexPath"] = GetOptionalString(pair, "imageIndexPath"),
                ["timing"] = new JsonObject
                {
                    ["startUtc"] = itemStart.ToString("O"),
                    ["endUtc"] = itemEnd.ToString("O"),
                    ["durationMs"] = Math.Round(durationMs, 3)
                }
            });
            order++;
        }

        return new ItemsEnvelope(
            items,
            CreateTimingNode(start, durationsMs),
            CreateTimingSummaryNode(durationsMs));
    }

    private static ItemsEnvelope BuildItemsFromSuiteManifest(JsonObject suiteManifest)
    {
        var pairs = new JsonArray();
        foreach (var modeNode in GetArray(suiteManifest, "modes"))
        {
            if (modeNode is not JsonObject modeEntry)
            {
                continue;
            }

            var manifestPath = GetOptionalString(modeEntry, "manifestPath");
            if (string.IsNullOrWhiteSpace(manifestPath) || !File.Exists(manifestPath))
            {
                continue;
            }

            JsonObject modeManifest;
            try
            {
                modeManifest = LoadJsonObject(manifestPath, "mode manifest");
            }
            catch
            {
                continue;
            }

            foreach (var comparisonNode in GetArray(modeManifest, "comparisons"))
            {
                if (comparisonNode is not JsonObject comparison)
                {
                    continue;
                }

                var resultNode = comparison["result"] as JsonObject ?? new JsonObject();
                pairs.Add(new JsonObject
                {
                    ["targetPath"] = GetOptionalString(suiteManifest, "targetPath"),
                    ["mode"] = GetOptionalString(modeEntry, "name") ?? GetOptionalString(modeEntry, "slug") ?? "default",
                    ["pairIndex"] = GetOptionalInt(comparison, "index") ?? 0,
                    ["baseRef"] = GetNestedString(comparison, "base", "ref"),
                    ["headRef"] = GetNestedString(comparison, "head", "ref"),
                    ["diff"] = GetOptionalBool(resultNode, "diff") ?? false,
                    ["classification"] = GetOptionalBool(resultNode, "diff") == true ? "diff" : "no_diff",
                    ["durationSeconds"] = GetOptionalDouble(resultNode, "duration_s"),
                    ["reportPath"] = GetOptionalString(resultNode, "reportPath"),
                    ["previewStatus"] = "unknown"
                });
            }
        }

        return BuildItemsFromPairTimeline(pairs, GetOptionalString(suiteManifest, "generatedAt"));
    }

    private static JsonObject CreateTimingNode(DateTimeOffset start, IReadOnlyList<double> durationsMs)
    {
        var totalDurationMs = durationsMs.Sum();
        var end = start.AddMilliseconds(totalDurationMs);
        return new JsonObject
        {
            ["startUtc"] = start.ToString("O"),
            ["endUtc"] = end.ToString("O"),
            ["durationMs"] = Math.Round(totalDurationMs, 3)
        };
    }

    private static JsonObject CreateTimingSummaryNode(IReadOnlyList<double> durationsMs)
    {
        if (durationsMs.Count == 0)
        {
            return new JsonObject
            {
                ["count"] = 0,
                ["totalDurationMs"] = 0,
                ["p50Ms"] = 0,
                ["p90Ms"] = 0,
                ["p95Ms"] = 0
            };
        }

        var sorted = durationsMs.OrderBy(v => v).ToArray();
        return new JsonObject
        {
            ["count"] = sorted.Length,
            ["totalDurationMs"] = Math.Round(sorted.Sum(), 3),
            ["p50Ms"] = Math.Round(ComputePercentile(sorted, 0.5), 3),
            ["p90Ms"] = Math.Round(ComputePercentile(sorted, 0.9), 3),
            ["p95Ms"] = Math.Round(ComputePercentile(sorted, 0.95), 3)
        };
    }

    private static double ComputePercentile(IReadOnlyList<double> sortedValues, double percentile)
    {
        if (sortedValues.Count == 0)
        {
            return 0;
        }

        if (sortedValues.Count == 1)
        {
            return sortedValues[0];
        }

        var index = percentile * (sortedValues.Count - 1);
        var lowerIndex = (int)Math.Floor(index);
        var upperIndex = (int)Math.Ceiling(index);
        if (lowerIndex == upperIndex)
        {
            return sortedValues[lowerIndex];
        }

        var fraction = index - lowerIndex;
        return sortedValues[lowerIndex] + ((sortedValues[upperIndex] - sortedValues[lowerIndex]) * fraction);
    }

    private static JsonObject MergeHistoryImageIndexes(JsonObject backendSummary)
    {
        var images = new JsonArray();
        var ordinal = 0;

        foreach (var targetNode in GetArray(backendSummary, "targets"))
        {
            if (targetNode is not JsonObject target)
            {
                continue;
            }

            var targetPath = GetOptionalString(target, "repoPath") ?? GetOptionalString(target, "targetPath");
            var reportImages = target["reportImages"] as JsonObject;
            var indexPath = reportImages is null ? null : GetOptionalString(reportImages, "indexPath");
            if (string.IsNullOrWhiteSpace(indexPath) || !File.Exists(indexPath))
            {
                continue;
            }

            JsonObject index;
            try
            {
                index = LoadJsonObject(indexPath, "report image index");
            }
            catch
            {
                continue;
            }

            foreach (var imageNode in GetArray(index, "images"))
            {
                if (imageNode is not JsonObject image)
                {
                    continue;
                }

                var savedPath = GetOptionalString(image, "savedPath") ?? GetOptionalString(image, "resolvedSource") ?? GetOptionalString(image, "source");
                images.Add(new JsonObject
                {
                    ["path"] = savedPath,
                    ["compareItemId"] = SanitizeItemId($"{targetPath ?? "target"}-{ordinal:D3}"),
                    ["mediaType"] = InferMediaType(savedPath),
                    ["targetPath"] = targetPath,
                    ["sourceIndexPath"] = indexPath,
                    ["status"] = GetOptionalString(image, "status"),
                    ["fileName"] = GetOptionalString(image, "fileName"),
                    ["savedPath"] = GetOptionalString(image, "savedPath"),
                    ["sourceType"] = GetOptionalString(image, "sourceType")
                });
                ordinal++;
            }
        }

        return new JsonObject
        {
            ["schema"] = "comparevi-cli/image-index@v1",
            ["schemaVersion"] = SchemaVersion,
            ["schemaCompatibility"] = BuildSchemaCompatibility(),
            ["generatedAtUtc"] = DateTimeOffset.UtcNow.ToString("O"),
            ["images"] = images
        };
    }

    private static JsonObject BuildCliImageIndexFromReportExtract(string indexPath)
    {
        if (!File.Exists(indexPath))
        {
            return CreateEmptyCliImageIndex();
        }

        var source = LoadJsonObject(indexPath, "extracted image index");
        var images = new JsonArray();
        foreach (var imageNode in GetArray(source, "images"))
        {
            if (imageNode is not JsonObject image)
            {
                continue;
            }

            var savedPath = GetOptionalString(image, "savedPath") ?? GetOptionalString(image, "source");
            var compareItemId = GetOptionalInt(image, "index")?.ToString(CultureInfo.InvariantCulture) ?? "0";
            images.Add(new JsonObject
            {
                ["path"] = savedPath,
                ["compareItemId"] = $"report-{compareItemId}",
                ["mediaType"] = GetOptionalString(image, "mimeType") ?? InferMediaType(savedPath),
                ["status"] = GetOptionalString(image, "status"),
                ["fileName"] = GetOptionalString(image, "fileName")
            });
        }

        return new JsonObject
        {
            ["schema"] = "comparevi-cli/image-index@v1",
            ["schemaVersion"] = SchemaVersion,
            ["schemaCompatibility"] = BuildSchemaCompatibility(),
            ["generatedAtUtc"] = DateTimeOffset.UtcNow.ToString("O"),
            ["images"] = images
        };
    }

    private static JsonObject CreateEmptyCliImageIndex()
    {
        return new JsonObject
        {
            ["schema"] = "comparevi-cli/image-index@v1",
            ["schemaVersion"] = SchemaVersion,
            ["schemaCompatibility"] = BuildSchemaCompatibility(),
            ["generatedAtUtc"] = DateTimeOffset.UtcNow.ToString("O"),
            ["images"] = new JsonArray()
        };
    }

    private static string InferMediaType(string? path)
    {
        var extension = string.IsNullOrWhiteSpace(path) ? string.Empty : Path.GetExtension(path).ToLowerInvariant();
        return extension switch
        {
            ".png" => "image/png",
            ".jpg" or ".jpeg" => "image/jpeg",
            ".gif" => "image/gif",
            ".bmp" => "image/bmp",
            ".svg" => "image/svg+xml",
            _ => "application/octet-stream"
        };
    }

    private static bool DetermineHistoryTruncation(JsonObject backendSummary)
    {
        foreach (var targetNode in GetArray(backendSummary, "targets"))
        {
            if (targetNode is not JsonObject target)
            {
                continue;
            }

            var manifestPath = GetOptionalString(target, "manifest");
            if (string.IsNullOrWhiteSpace(manifestPath) || !File.Exists(manifestPath))
            {
                continue;
            }

            JsonObject targetManifest;
            try
            {
                targetManifest = LoadJsonObject(manifestPath, "target manifest");
            }
            catch
            {
                continue;
            }

            foreach (var modeNode in GetArray(targetManifest, "modes"))
            {
                if (modeNode is not JsonObject modeEntry)
                {
                    continue;
                }

                var stopReason = GetNestedString(modeEntry, "stats", "stopReason");
                if (string.Equals(stopReason, "max-pairs", StringComparison.OrdinalIgnoreCase))
                {
                    return true;
                }
            }
        }

        return false;
    }

    private static string? ResolveSiblingHistoryContextPath(string manifestPath)
    {
        var directory = Path.GetDirectoryName(manifestPath);
        if (string.IsNullOrWhiteSpace(directory))
        {
            return null;
        }

        var candidate = Path.Combine(directory, "history-context.json");
        return File.Exists(candidate) ? Path.GetFullPath(candidate) : null;
    }

    private static string CreateReportWrapperManifest(JsonObject modeManifest, string inputPath, string backendRoot, JsonSerializerOptions serializerOptions)
    {
        var wrapperPath = Path.Combine(backendRoot, "history-suite-wrapper.json");
        var modeName = GetOptionalString(modeManifest, "mode") ?? "default";
        var modeSlug = GetOptionalString(modeManifest, "slug") ?? modeName.ToLowerInvariant().Replace(' ', '-');
        var statsClone = GetObject(modeManifest, "stats").DeepClone() as JsonObject ?? new JsonObject();

        var suiteManifest = new JsonObject
        {
            ["schema"] = "vi-compare/history-suite@v1",
            ["generatedAt"] = GetOptionalString(modeManifest, "generatedAt") ?? DateTimeOffset.UtcNow.ToString("O"),
            ["targetPath"] = GetOptionalString(modeManifest, "targetPath"),
            ["requestedStartRef"] = GetOptionalString(modeManifest, "requestedStartRef"),
            ["startRef"] = GetOptionalString(modeManifest, "startRef"),
            ["endRef"] = GetOptionalString(modeManifest, "endRef"),
            ["maxPairs"] = GetOptionalInt(modeManifest, "maxPairs"),
            ["failFast"] = GetOptionalBool(modeManifest, "failFast") ?? false,
            ["failOnDiff"] = GetOptionalBool(modeManifest, "failOnDiff") ?? false,
            ["reportFormat"] = GetOptionalString(modeManifest, "reportFormat") ?? "html",
            ["resultsDir"] = GetOptionalString(modeManifest, "resultsDir") ?? Path.GetDirectoryName(inputPath),
            ["modes"] = new JsonArray
            {
                new JsonObject
                {
                    ["name"] = modeName,
                    ["slug"] = modeSlug,
                    ["reportFormat"] = GetOptionalString(modeManifest, "reportFormat") ?? "html",
                    ["flags"] = GetArray(modeManifest, "flags").DeepClone(),
                    ["manifestPath"] = inputPath,
                    ["resultsDir"] = GetOptionalString(modeManifest, "resultsDir") ?? Path.GetDirectoryName(inputPath),
                    ["stats"] = statsClone.DeepClone(),
                    ["status"] = GetOptionalString(modeManifest, "status") ?? "ok"
                }
            },
            ["stats"] = new JsonObject
            {
                ["modes"] = 1,
                ["processed"] = GetOptionalInt(statsClone, "processed") ?? 0,
                ["diffs"] = GetOptionalInt(statsClone, "diffs") ?? 0,
                ["signalDiffs"] = GetOptionalInt(statsClone, "signalDiffs") ?? 0,
                ["noiseCollapsed"] = GetOptionalInt(statsClone, "noiseCollapsed") ?? 0,
                ["errors"] = GetOptionalInt(statsClone, "errors") ?? 0,
                ["missing"] = GetOptionalInt(statsClone, "missing") ?? 0,
                ["categoryCounts"] = GetObject(statsClone, "categoryCounts").DeepClone(),
                ["bucketCounts"] = GetObject(statsClone, "bucketCounts").DeepClone()
            },
            ["status"] = GetOptionalString(modeManifest, "status") ?? "ok"
        };

        WriteJsonToFile(suiteManifest, wrapperPath, serializerOptions);
        return wrapperPath;
    }

    private static void AddOptionalIntArgument(List<string> arguments, string option, int? value)
    {
        if (value is null)
        {
            return;
        }

        arguments.Add(option);
        arguments.Add(value.Value.ToString(CultureInfo.InvariantCulture));
    }

    private static void AddOptionalArrayArgument(List<string> arguments, string option, IReadOnlyList<string> values)
    {
        if (values.Count == 0)
        {
            return;
        }

        arguments.Add(option);
        foreach (var value in values)
        {
            arguments.Add(value);
        }
    }

    private static void AddOptionalPathArgument(List<string> arguments, string option, string? path)
    {
        if (string.IsNullOrWhiteSpace(path))
        {
            return;
        }

        arguments.Add(option);
        arguments.Add(path);
    }

    private static int? NormalizePositiveInt(int? value)
    {
        return value is > 0 ? value : null;
    }

    private static string SanitizeItemId(string value)
    {
        var builder = new StringBuilder(value.Length);
        foreach (var ch in value)
        {
            builder.Append(char.IsLetterOrDigit(ch) ? ch : '-');
        }

        return builder.ToString().Trim('-');
    }

    private static string FormatLogArgument(string argument)
    {
        return argument.Contains(' ', StringComparison.Ordinal) ? $"\"{argument}\"" : argument;
    }

    private static string IndentBlock(string text)
    {
        var lines = text.Replace("\r\n", "\n", StringComparison.Ordinal).Split('\n');
        return string.Join(Environment.NewLine, lines.Select(line => $"    {line}"));
    }

    private static DateTimeOffset? ParseDateTimeOffset(string? value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return null;
        }

        return DateTimeOffset.TryParse(value, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var parsed)
            ? parsed
            : null;
    }

    private static bool PathsEqual(string left, string right)
    {
        return string.Equals(Path.GetFullPath(left), Path.GetFullPath(right), StringComparison.OrdinalIgnoreCase);
    }

    private static void EnsureDirectoryForFile(string filePath)
    {
        var directory = Path.GetDirectoryName(filePath);
        if (!string.IsNullOrWhiteSpace(directory))
        {
            Directory.CreateDirectory(directory);
        }
    }

    private sealed class ScriptInvocationResult
    {
        public ScriptInvocationResult(int exitCode, string stdOut, string stdErr, Dictionary<string, string> outputs)
        {
            ExitCode = exitCode;
            StdOut = stdOut;
            StdErr = stdErr;
            Outputs = outputs;
        }

        public int ExitCode { get; }

        public string StdOut { get; }

        public string StdErr { get; }

        public Dictionary<string, string> Outputs { get; }
    }

    private sealed class CliFailureException : Exception
    {
        public CliFailureException(string failureClass, string message, IReadOnlyList<JsonObject>? diagnostics)
            : base(message)
        {
            FailureClass = failureClass;
            Diagnostics = diagnostics;
        }

        public string FailureClass { get; }

        public IReadOnlyList<JsonObject>? Diagnostics { get; }
    }

    private sealed class CliArtifactPaths
    {
        public CliArtifactPaths(string summaryJsonPath, string summaryMarkdownPath, string reportHtmlPath, string imageIndexPath, string runLogPath)
        {
            SummaryJsonPath = summaryJsonPath;
            SummaryMarkdownPath = summaryMarkdownPath;
            ReportHtmlPath = reportHtmlPath;
            ImageIndexPath = imageIndexPath;
            RunLogPath = runLogPath;
        }

        public string SummaryJsonPath { get; }

        public string SummaryMarkdownPath { get; }

        public string ReportHtmlPath { get; }

        public string ImageIndexPath { get; }

        public string RunLogPath { get; }
    }

    private sealed class ItemsEnvelope
    {
        public ItemsEnvelope(JsonArray items, JsonObject timing, JsonObject timingSummary)
        {
            Items = items;
            Timing = timing;
            TimingSummary = timingSummary;
        }

        public JsonArray Items { get; }

        public JsonObject Timing { get; }

        public JsonObject TimingSummary { get; }
    }
}
