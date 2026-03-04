using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization.Metadata;
using System.Runtime.InteropServices;
using CompareVi.Shared;

internal static class Program
{
    private static readonly JsonSerializerOptions SerializerOptions = CreateSerializerOptions();

    private static int Main(string[] args)
    {
        try
        {
            if (args.Length == 0 || IsHelp(args[0]))
            {
                PrintHelp();
                return 0;
            }

            var cmd = args[0].ToLowerInvariant();
            switch (cmd)
            {
                case "preflight":
                    return CmdPreflight(args);
                case "version":
                    return CmdVersion();
                case "tokenize":
                    return CmdTokenize(args);
                case "procs":
                    return CmdProcs();
                case "quote":
                    return CmdQuote(args);
                case "operations":
                    return CmdOperations(args);
                case "providers":
                    return CmdProviders(args);
                case "compare":
                    return CmdCompare(args);
                case "history":
                    return CmdHistory(args);
                case "report":
                    return CmdReport(args);
                case "contracts":
                    return CmdContracts(args);
                default:
                    Console.Error.WriteLine($"Unknown command: {cmd}");
                    PrintHelp();
                    return 2;
            }
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine(ex.Message);
            return 1;
        }
    }

    private static bool IsHelp(string s) => s.Equals("-h", StringComparison.OrdinalIgnoreCase) || s.Equals("--help", StringComparison.OrdinalIgnoreCase) || s.Equals("help", StringComparison.OrdinalIgnoreCase);

    private static void PrintHelp()
    {
        Console.WriteLine("comparevi-cli — utilities for Compare VI workflows");
        Console.WriteLine();
        Console.WriteLine("Usage:");
        Console.WriteLine("  comparevi-cli version");
        Console.WriteLine("  comparevi-cli preflight [--repo <path>]");
        Console.WriteLine("  comparevi-cli tokenize --input \"arg string\"");
        Console.WriteLine("  comparevi-cli procs");
        Console.WriteLine("  comparevi-cli quote --path <path>");
        Console.WriteLine("  comparevi-cli operations [--name <operation>] [--names-only]");
        Console.WriteLine("  comparevi-cli providers [--name <provider>] [--names-only]");
        Console.WriteLine("  comparevi-cli compare single --input <file> --dry-run [--diff] [--exit-code <n>] [--failure-class <name>] [--out-dir <path>] [--non-interactive] [--headless]");
        Console.WriteLine("  comparevi-cli compare range --base <ref> --head <ref> --dry-run [--diff] [--exit-code <n>] [--failure-class <name>] [--max-pairs <n>] [--out-dir <path>] [--non-interactive] [--headless]");
        Console.WriteLine("  comparevi-cli history run --input <file> --dry-run [--diff] [--exit-code <n>] [--failure-class <name>] [--out-dir <path>] [--non-interactive] [--headless]");
        Console.WriteLine("  comparevi-cli report consolidate --input <file> --dry-run [--out-dir <path>] [--non-interactive] [--headless]");
        Console.WriteLine("  comparevi-cli contracts validate --input <file>");
    }

    private static int CmdPreflight(string[] args)
    {
        if (!ValidateCommandOptions(
                args,
                startIndex: 1,
                valueOptions: new[] { "--repo" },
                flagOptions: new[] { "--non-interactive" },
                out var optionError))
        {
            Console.Error.WriteLine(optionError);
            return 2;
        }

        var repoPath = Environment.CurrentDirectory;
        if (TryReadOption(args, 1, "--repo", out var repoPathValue) && !string.IsNullOrWhiteSpace(repoPathValue))
        {
            repoPath = repoPathValue;
        }

        var nonInteractive = HasFlag(args, 1, "--non-interactive");
        var resolvedRepoPath = Path.GetFullPath(repoPath);
        var repoExists = Directory.Exists(resolvedRepoPath);
        var checks = new List<Dictionary<string, object?>>
        {
            new()
            {
                ["id"] = "repo-path-exists",
                ["required"] = true,
                ["status"] = repoExists ? "pass" : "fail",
                ["detail"] = repoExists
                    ? "Repository path exists."
                    : "Repository path does not exist."
            },
            new()
            {
                ["id"] = "windows-host",
                ["required"] = true,
                ["status"] = RuntimeInformation.IsOSPlatform(OSPlatform.Windows) ? "pass" : "fail",
                ["detail"] = RuntimeInformation.IsOSPlatform(OSPlatform.Windows)
                    ? "Windows host detected."
                    : "Host OS is not Windows; host-native LabVIEW validation requires Windows."
            }
        };

        var failedPrerequisites = new List<string>();
        var diagnostics = new List<Dictionary<string, object?>>();
        if (!repoExists)
        {
            failedPrerequisites.Add("repo-path-exists");
            diagnostics.Add(new Dictionary<string, object?>
            {
                ["code"] = "repo-path-missing",
                ["severity"] = "error",
                ["message"] = "Repository path does not exist.",
                ["path"] = resolvedRepoPath
            });
        }

        if (!RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
        {
            failedPrerequisites.Add("windows-host");
            diagnostics.Add(new Dictionary<string, object?>
            {
                ["code"] = "windows-host-required",
                ["severity"] = "error",
                ["message"] = "Host-native LabVIEW validation requires Windows.",
                ["detectedOs"] = RuntimeInformation.OSDescription
            });
        }

        var preflightOk = repoExists && RuntimeInformation.IsOSPlatform(OSPlatform.Windows);
        var gateOutcome = preflightOk ? "pass" : "fail";
        var failureClass = preflightOk ? "none" : "preflight";
        var resultClass = preflightOk ? "success-no-diff" : "failure-preflight";
        var outcomeKind = MapOutcomeKind(resultClass, failureClass);

        var payload = new Dictionary<string, object?>
        {
            ["schema"] = "comparevi-cli/preflight@v1",
            ["schemaVersion"] = "1.0.0",
            ["command"] = "preflight",
            ["generatedAtUtc"] = DateTimeOffset.UtcNow.ToString("O"),
            ["repoPath"] = resolvedRepoPath,
            ["nonInteractive"] = nonInteractive,
            ["host"] = new Dictionary<string, object?>
            {
                ["framework"] = System.Runtime.InteropServices.RuntimeInformation.FrameworkDescription,
                ["os"] = System.Runtime.InteropServices.RuntimeInformation.OSDescription
            },
            ["checks"] = checks,
            ["failedPrerequisites"] = failedPrerequisites,
            ["diagnostics"] = diagnostics,
            ["outcome"] = new Dictionary<string, object?>
            {
                ["class"] = gateOutcome,
                ["kind"] = outcomeKind
            },
            ["resultClass"] = resultClass,
            ["isDiff"] = false,
            ["gateOutcome"] = gateOutcome,
            ["failureClass"] = failureClass
        };

        Console.WriteLine(JsonSerializer.Serialize(payload, SerializerOptions));
        return preflightOk ? 0 : 1;
    }

    private static int CmdVersion()
    {
        var assembly = typeof(Program).Assembly;
        var asmName = assembly.GetName();
        var infoAttr = (System.Reflection.AssemblyInformationalVersionAttribute?)Attribute.GetCustomAttribute(
            assembly, typeof(System.Reflection.AssemblyInformationalVersionAttribute));
        var obj = new Dictionary<string, object?>
        {
            ["name"] = asmName.Name,
            ["assemblyVersion"] = asmName.Version?.ToString(),
            ["informationalVersion"] = infoAttr?.InformationalVersion,
            ["framework"] = System.Runtime.InteropServices.RuntimeInformation.FrameworkDescription,
            ["os"] = System.Runtime.InteropServices.RuntimeInformation.OSDescription,
        };
        Console.WriteLine(JsonSerializer.Serialize(obj, SerializerOptions));
        return 0;
    }

    private static int CmdTokenize(string[] args)
    {
        // Expect: tokenize --input "..."
        string? input = null;
        for (int i = 1; i < args.Length; i++)
        {
            if (args[i].Equals("--input", StringComparison.OrdinalIgnoreCase) && i + 1 < args.Length)
            {
                input = args[i + 1];
                i++;
            }
        }
        var tokens = ArgTokenizer.Tokenize(input);
        var normalized = ArgTokenizer.NormalizeFlagValuePairs(tokens);
        var obj = new Dictionary<string, object?>
        {
            ["raw"] = tokens,
            ["normalized"] = normalized,
        };
        Console.WriteLine(JsonSerializer.Serialize(obj, SerializerOptions));
        return 0;
    }

    private static int CmdProcs()
    {
        var snap = ProcSnapshot.Capture();
        var obj = new Dictionary<string, object?>
        {
            ["labviewPids"] = snap.LabViewPids,
            ["lvcomparePids"] = snap.LvComparePids,
            ["labviewCliPids"] = snap.LabViewCliPids,
            ["gcliPids"] = snap.GcliPids,
        };
        Console.WriteLine(JsonSerializer.Serialize(obj, SerializerOptions));
        return 0;
    }

    private static int CmdQuote(string[] args)
    {
        string? path = null;
        for (int i = 1; i < args.Length; i++)
        {
            if (args[i].Equals("--path", StringComparison.OrdinalIgnoreCase) && i + 1 < args.Length)
            {
                path = args[i + 1];
                i++;
            }
        }
        var quoted = PathUtils.Quote(path);
        var obj = new Dictionary<string, object?>
        {
            ["input"] = path,
            ["quoted"] = quoted,
        };
        Console.WriteLine(JsonSerializer.Serialize(obj, SerializerOptions));
        return 0;
    }

    private static int CmdOperations(string[] args)
    {
        string? operationName = null;
        var namesOnly = false;
        for (int i = 1; i < args.Length; i++)
        {
            if (args[i].Equals("--name", StringComparison.OrdinalIgnoreCase) && i + 1 < args.Length)
            {
                operationName = args[i + 1];
                i++;
                continue;
            }

            if (args[i].Equals("--names", StringComparison.OrdinalIgnoreCase) ||
                args[i].Equals("--names-only", StringComparison.OrdinalIgnoreCase))
            {
                namesOnly = true;
            }
        }

        operationName = operationName?.Trim();

        if (namesOnly && !string.IsNullOrEmpty(operationName))
        {
            Console.Error.WriteLine("--names-only cannot be combined with --name.");
            return 2;
        }

        if (namesOnly)
        {
            var payload = OperationCatalogFormatter.CreateOperationNamesPayload();
            Console.WriteLine(payload.ToJsonString(SerializerOptions));
            return 0;
        }

        if (string.IsNullOrEmpty(operationName))
        {
            var payload = OperationCatalogFormatter.CreateOperationsListPayload();
            Console.WriteLine(payload.ToJsonString(SerializerOptions));
            return 0;
        }

        if (OperationCatalogFormatter.TryCreateOperationPayload(operationName!, out var operationPayload))
        {
            Console.WriteLine(operationPayload.ToJsonString(SerializerOptions));
            return 0;
        }

        Console.Error.WriteLine($"Operation '{operationName}' was not found in the operations catalog.");
        return 3;
    }

    private static int CmdProviders(string[] args)
    {
        string? providerName = null;
        var namesOnly = false;

        for (int i = 1; i < args.Length; i++)
        {
            if (args[i].Equals("--name", StringComparison.OrdinalIgnoreCase) && i + 1 < args.Length)
            {
                providerName = args[i + 1];
                i++;
                continue;
            }

            if (args[i].Equals("--names", StringComparison.OrdinalIgnoreCase) ||
                args[i].Equals("--names-only", StringComparison.OrdinalIgnoreCase))
            {
                namesOnly = true;
            }
        }

        providerName = providerName?.Trim();

        if (namesOnly && !string.IsNullOrEmpty(providerName))
        {
            Console.Error.WriteLine("--names-only cannot be combined with --name.");
            return 2;
        }

        if (namesOnly)
        {
            var payload = ProviderCatalogFormatter.CreateProviderNamesPayload();
            Console.WriteLine(payload.ToJsonString(SerializerOptions));
            return 0;
        }

        if (string.IsNullOrEmpty(providerName))
        {
            var payload = ProviderCatalogFormatter.CreateProvidersListPayload();
            Console.WriteLine(payload.ToJsonString(SerializerOptions));
            return 0;
        }

        if (ProviderCatalogFormatter.TryCreateProviderPayload(providerName!, out var providerPayload))
        {
            Console.WriteLine(providerPayload.ToJsonString(SerializerOptions));
            return 0;
        }

        Console.Error.WriteLine($"Provider '{providerName}' was not found in the providers catalog.");
        return 3;
    }

    private static int CmdCompare(string[] args)
    {
        if (args.Length < 2)
        {
            Console.Error.WriteLine("Usage: comparevi-cli compare <single|range> ...");
            return 2;
        }

        if (args[1].Equals("single", StringComparison.OrdinalIgnoreCase))
        {
            return RunDryContractLane(
                lane: "compare-single",
                schema: "comparevi-cli/compare-single@v1",
                command: "compare single",
                args: args,
                tailStart: 2
            );
        }

        if (args[1].Equals("range", StringComparison.OrdinalIgnoreCase))
        {
            return RunDryCompareRangeLane(args, 2);
        }

        Console.Error.WriteLine("Usage: comparevi-cli compare <single|range> ...");
        return 2;
    }

    private static int RunDryCompareRangeLane(string[] args, int tailStart)
    {
        if (!ValidateCommandOptions(
                args,
                startIndex: tailStart,
            valueOptions: new[] { "--base", "--head", "--exit-code", "--failure-class", "--max-pairs", "--out-dir" },
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

        var dryRun = HasFlag(args, tailStart, "--dry-run");
        if (!dryRun)
        {
            Console.Error.WriteLine("Command 'compare range' currently supports adapter-dry-run only. Pass --dry-run.");
            return 2;
        }

        var isDiff = HasFlag(args, tailStart, "--diff");
        var exitCode = TryReadIntOption(args, tailStart, "--exit-code", out var parsedExitCode)
            ? parsedExitCode
            : (isDiff ? 1 : 0);
        var declaredFailureClass = TryReadOption(args, tailStart, "--failure-class", out var failureClassValue)
            ? failureClassValue
            : null;
        var hasMaxPairs = TryReadIntOption(args, tailStart, "--max-pairs", out var maxPairs);
        if (HasOption(args, tailStart, "--max-pairs") && !hasMaxPairs)
        {
            Console.Error.WriteLine("Invalid value for option: --max-pairs <int>");
            return 2;
        }

        var classification = ExitClassification.Classify(exitCode, isDiff, declaredFailureClass);
        var nonInteractive = HasFlag(args, tailStart, "--non-interactive");
        var headless = HasFlag(args, tailStart, "--headless");

        if (nonInteractive && !headless)
        {
            var policyFailurePayload = BuildHeadlessPolicyFailurePayload(
                schema: "comparevi-cli/compare-range@v1",
                lane: "compare-range",
                command: "compare range");
            Console.WriteLine(JsonSerializer.Serialize(policyFailurePayload, SerializerOptions));
            return 1;
        }

        var outDir = ResolveOutputDirectory(args, tailStart);
        var artifacts = BuildArtifactPaths("compare-range", outDir);
        var imageIndex = BuildImageIndexPayload(classification.IsDiff);
        var timing = BuildTimingEnvelope();
        var payload = new Dictionary<string, object?>
        {
            ["schema"] = "comparevi-cli/compare-range@v1",
            ["schemaVersion"] = "1.0.0",
            ["schemaCompatibility"] = BuildSchemaCompatibility(),
            ["lane"] = "compare-range",
            ["command"] = "compare range",
            ["generatedAtUtc"] = DateTimeOffset.UtcNow.ToString("O"),
            ["base"] = baseRef,
            ["head"] = headRef,
            ["maxPairs"] = hasMaxPairs ? maxPairs : null,
            ["truncated"] = false,
            ["headless"] = headless,
            ["nonInteractive"] = nonInteractive,
            ["outDir"] = outDir,
            ["artifacts"] = artifacts,
            ["summaryJsonPath"] = artifacts["summaryJsonPath"],
            ["summaryMarkdownPath"] = artifacts["summaryMarkdownPath"],
            ["reportHtmlPath"] = artifacts["reportHtmlPath"],
            ["consolidatedReportPath"] = artifacts["reportHtmlPath"],
            ["imageIndexPath"] = artifacts["imageIndexPath"],
            ["runLogPath"] = artifacts["runLogPath"],
            ["imageIndex"] = imageIndex,
            ["items"] = timing["items"],
            ["timing"] = timing["timing"],
            ["timingSummary"] = timing["timingSummary"],
            ["dryRun"] = dryRun,
            ["simulatedExitCode"] = exitCode,
            ["outcome"] = new Dictionary<string, object?>
            {
                ["class"] = classification.GateOutcome,
                ["kind"] = MapOutcomeKind(classification.ResultClass, classification.FailureClass)
            },
            ["resultClass"] = classification.ResultClass,
            ["isDiff"] = classification.IsDiff,
            ["gateOutcome"] = classification.GateOutcome,
            ["failureClass"] = classification.FailureClass
        };

        Console.WriteLine(JsonSerializer.Serialize(payload, SerializerOptions));
        return string.Equals(classification.GateOutcome, "pass", StringComparison.OrdinalIgnoreCase) ? 0 : 1;
    }

    private static int CmdHistory(string[] args)
    {
        if (args.Length < 2 || !args[1].Equals("run", StringComparison.OrdinalIgnoreCase))
        {
            Console.Error.WriteLine("Usage: comparevi-cli history run --input <file> --dry-run [--diff] [--exit-code <n>] [--failure-class <name>]");
            return 2;
        }

        return RunDryContractLane(
            lane: "history-run",
            schema: "comparevi-cli/history-run@v1",
            command: "history run",
            args: args,
            tailStart: 2
        );
    }

    private static int CmdReport(string[] args)
    {
        if (args.Length < 2 || !args[1].Equals("consolidate", StringComparison.OrdinalIgnoreCase))
        {
            Console.Error.WriteLine("Usage: comparevi-cli report consolidate --input <file> --dry-run");
            return 2;
        }

        return RunDryContractLane(
            lane: "report-consolidate",
            schema: "comparevi-cli/report-consolidate@v1",
            command: "report consolidate",
            args: args,
            tailStart: 2
        );
    }

    private static int CmdContracts(string[] args)
    {
        if (args.Length < 2 || !args[1].Equals("validate", StringComparison.OrdinalIgnoreCase))
        {
            Console.Error.WriteLine("Usage: comparevi-cli contracts validate --input <file>");
            return 2;
        }

        if (!ValidateCommandOptions(
                args,
                startIndex: 2,
                valueOptions: new[] { "--input" },
                flagOptions: new[] { "--non-interactive" },
                out var optionError))
        {
            Console.Error.WriteLine(optionError);
            return 2;
        }

        if (!TryReadOption(args, 2, "--input", out var inputPath) || string.IsNullOrWhiteSpace(inputPath))
        {
            Console.Error.WriteLine("Missing required option: --input <file>");
            return 2;
        }

        var exists = File.Exists(inputPath);
        var payload = new Dictionary<string, object?>
        {
            ["schema"] = "comparevi-cli/contracts-validate@v1",
            ["schemaVersion"] = "1.0.0",
            ["command"] = "contracts validate",
            ["generatedAtUtc"] = DateTimeOffset.UtcNow.ToString("O"),
            ["inputPath"] = Path.GetFullPath(inputPath),
            ["exists"] = exists,
            ["valid"] = exists,
            ["outcome"] = new Dictionary<string, object?>
            {
                ["class"] = exists ? "pass" : "fail",
                ["kind"] = MapOutcomeKind(exists ? "success-no-diff" : "failure-preflight", exists ? "none" : "preflight")
            },
            ["resultClass"] = exists ? "success-no-diff" : "failure-preflight",
            ["isDiff"] = false,
            ["gateOutcome"] = exists ? "pass" : "fail",
            ["failureClass"] = exists ? "none" : "preflight"
        };

        Console.WriteLine(JsonSerializer.Serialize(payload, SerializerOptions));
        return exists ? 0 : 1;
    }

    private static int RunDryContractLane(string lane, string schema, string command, string[] args, int tailStart)
    {
        if (!ValidateCommandOptions(
                args,
                startIndex: tailStart,
            valueOptions: new[] { "--input", "--exit-code", "--failure-class", "--out-dir" },
            flagOptions: new[] { "--dry-run", "--diff", "--non-interactive", "--headless" },
                out var optionError))
        {
            Console.Error.WriteLine(optionError);
            return 2;
        }

        if (!TryReadOption(args, tailStart, "--input", out var inputPath) || string.IsNullOrWhiteSpace(inputPath))
        {
            Console.Error.WriteLine("Missing required option: --input <file>");
            return 2;
        }

        var dryRun = HasFlag(args, tailStart, "--dry-run");
        if (!dryRun)
        {
            Console.Error.WriteLine($"Command '{command}' currently supports adapter-dry-run only. Pass --dry-run.");
            return 2;
        }

        var isDiff = HasFlag(args, tailStart, "--diff");
        var exitCode = TryReadIntOption(args, tailStart, "--exit-code", out var parsedExitCode)
            ? parsedExitCode
            : (isDiff ? 1 : 0);
        var declaredFailureClass = TryReadOption(args, tailStart, "--failure-class", out var failureClassValue)
            ? failureClassValue
            : null;

        var classification = ExitClassification.Classify(exitCode, isDiff, declaredFailureClass);
        var nonInteractive = HasFlag(args, tailStart, "--non-interactive");
        var headless = HasFlag(args, tailStart, "--headless");

        if (nonInteractive && !headless)
        {
            var policyFailurePayload = BuildHeadlessPolicyFailurePayload(
                schema: schema,
                lane: lane,
                command: command);
            Console.WriteLine(JsonSerializer.Serialize(policyFailurePayload, SerializerOptions));
            return 1;
        }

        var outDir = ResolveOutputDirectory(args, tailStart);
        var artifacts = BuildArtifactPaths(lane, outDir);
        var imageIndex = BuildImageIndexPayload(classification.IsDiff);
        var timing = BuildTimingEnvelope();
        var payload = new Dictionary<string, object?>
        {
            ["schema"] = schema,
            ["schemaVersion"] = "1.0.0",
            ["schemaCompatibility"] = BuildSchemaCompatibility(),
            ["lane"] = lane,
            ["command"] = command,
            ["generatedAtUtc"] = DateTimeOffset.UtcNow.ToString("O"),
            ["inputPath"] = Path.GetFullPath(inputPath),
            ["headless"] = headless,
            ["nonInteractive"] = nonInteractive,
            ["outDir"] = outDir,
            ["artifacts"] = artifacts,
            ["summaryJsonPath"] = artifacts["summaryJsonPath"],
            ["summaryMarkdownPath"] = artifacts["summaryMarkdownPath"],
            ["reportHtmlPath"] = artifacts["reportHtmlPath"],
            ["consolidatedReportPath"] = artifacts["reportHtmlPath"],
            ["imageIndexPath"] = artifacts["imageIndexPath"],
            ["runLogPath"] = artifacts["runLogPath"],
            ["imageIndex"] = imageIndex,
            ["items"] = timing["items"],
            ["timing"] = timing["timing"],
            ["timingSummary"] = timing["timingSummary"],
            ["dryRun"] = dryRun,
            ["simulatedExitCode"] = exitCode,
            ["outcome"] = new Dictionary<string, object?>
            {
                ["class"] = classification.GateOutcome,
                ["kind"] = MapOutcomeKind(classification.ResultClass, classification.FailureClass)
            },
            ["resultClass"] = classification.ResultClass,
            ["isDiff"] = classification.IsDiff,
            ["gateOutcome"] = classification.GateOutcome,
            ["failureClass"] = classification.FailureClass
        };

        Console.WriteLine(JsonSerializer.Serialize(payload, SerializerOptions));
        return string.Equals(classification.GateOutcome, "pass", StringComparison.OrdinalIgnoreCase) ? 0 : 1;
    }

    private static Dictionary<string, object?> BuildHeadlessPolicyFailurePayload(string schema, string lane, string command)
    {
        return new Dictionary<string, object?>
        {
            ["schema"] = schema,
            ["schemaVersion"] = "1.0.0",
            ["schemaCompatibility"] = BuildSchemaCompatibility(),
            ["lane"] = lane,
            ["command"] = command,
            ["generatedAtUtc"] = DateTimeOffset.UtcNow.ToString("O"),
            ["headless"] = false,
            ["nonInteractive"] = true,
            ["diagnostics"] = new[]
            {
                new Dictionary<string, object?>
                {
                    ["code"] = "headless-required",
                    ["severity"] = "error",
                    ["message"] = "Non-interactive execution requires explicit --headless opt-in."
                }
            },
            ["outcome"] = new Dictionary<string, object?>
            {
                ["class"] = "fail",
                ["kind"] = "preflight_error"
            },
            ["resultClass"] = "failure-preflight",
            ["isDiff"] = false,
            ["gateOutcome"] = "fail",
            ["failureClass"] = "preflight"
        };
    }

    private static Dictionary<string, object?> BuildTimingEnvelope()
    {
        var start = DateTimeOffset.UtcNow;
        var end = start.AddMilliseconds(25);
        var durationMs = (end - start).TotalMilliseconds;

        return new Dictionary<string, object?>
        {
            ["items"] = new[]
            {
                new Dictionary<string, object?>
                {
                    ["id"] = "pair-0001",
                    ["order"] = 1,
                    ["timing"] = new Dictionary<string, object?>
                    {
                        ["startUtc"] = start.ToString("O"),
                        ["endUtc"] = end.ToString("O"),
                        ["durationMs"] = durationMs
                    }
                }
            },
            ["timing"] = new Dictionary<string, object?>
            {
                ["startUtc"] = start.ToString("O"),
                ["endUtc"] = end.ToString("O"),
                ["durationMs"] = durationMs
            },
            ["timingSummary"] = new Dictionary<string, object?>
            {
                ["count"] = 1,
                ["totalDurationMs"] = durationMs,
                ["p50Ms"] = durationMs,
                ["p90Ms"] = durationMs,
                ["p95Ms"] = durationMs
            }
        };
    }

    private static Dictionary<string, object?> BuildSchemaCompatibility()
    {
        return new Dictionary<string, object?>
        {
            ["policy"] = "additive-within-major",
            ["majorVersion"] = 1
        };
    }

    private static string ResolveOutputDirectory(string[] args, int startIndex)
    {
        if (TryReadOption(args, startIndex, "--out-dir", out var outDirValue) && !string.IsNullOrWhiteSpace(outDirValue))
        {
            return Path.GetFullPath(outDirValue);
        }

        return Path.GetFullPath(Environment.CurrentDirectory);
    }

    private static Dictionary<string, object?> BuildArtifactPaths(string lane, string outDir)
    {
        var prefix = lane switch
        {
            "compare-range" => "vi-history",
            "history-run" => "vi-history",
            "report-consolidate" => "vi-history",
            _ => lane
        };

        return new Dictionary<string, object?>
        {
            ["summaryJsonPath"] = Path.GetFullPath(Path.Combine(outDir, $"{prefix}-summary.json")),
            ["summaryMarkdownPath"] = Path.GetFullPath(Path.Combine(outDir, $"{prefix}-summary.md")),
            ["reportHtmlPath"] = Path.GetFullPath(Path.Combine(outDir, $"{prefix}-report.html")),
            ["imageIndexPath"] = Path.GetFullPath(Path.Combine(outDir, $"{prefix}-image-index.json")),
            ["runLogPath"] = Path.GetFullPath(Path.Combine(outDir, $"{prefix}.log"))
        };
    }

    private static Dictionary<string, object?> BuildImageIndexPayload(bool hasDiff)
    {
        var images = new List<Dictionary<string, object?>>();
        if (hasDiff)
        {
            images.Add(new Dictionary<string, object?>
            {
                ["path"] = "images/pair-0001.png",
                ["compareItemId"] = "pair-0001",
                ["mediaType"] = "image/png"
            });
        }

        return new Dictionary<string, object?>
        {
            ["schema"] = "comparevi-cli/image-index@v1",
            ["schemaVersion"] = "1.0.0",
            ["schemaCompatibility"] = BuildSchemaCompatibility(),
            ["generatedAtUtc"] = DateTimeOffset.UtcNow.ToString("O"),
            ["images"] = images
        };
    }

    private static bool HasFlag(string[] args, int startIndex, string flag)
    {
        for (int i = startIndex; i < args.Length; i++)
        {
            if (args[i].Equals(flag, StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }
        }

        return false;
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

    private static bool TryReadOption(string[] args, int startIndex, string option, out string? value)
    {
        for (int i = startIndex; i < args.Length; i++)
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

    private static bool TryReadIntOption(string[] args, int startIndex, string option, out int value)
    {
        if (TryReadOption(args, startIndex, option, out var raw) && int.TryParse(raw, out var parsed))
        {
            value = parsed;
            return true;
        }

        value = 0;
        return false;
    }

    private static bool HasOption(string[] args, int startIndex, string option)
    {
        for (int i = startIndex; i < args.Length; i++)
        {
            if (args[i].Equals(option, StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }
        }

        return false;
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

        for (int i = startIndex; i < args.Length; i++)
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

    private static JsonSerializerOptions CreateSerializerOptions()
    {
        var options = new JsonSerializerOptions
        {
            WriteIndented = true,
            TypeInfoResolver = JsonTypeInfoResolver.Combine(new DefaultJsonTypeInfoResolver()),
        };

        return options;
    }
}
