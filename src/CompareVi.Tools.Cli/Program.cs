using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization.Metadata;
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
        Console.WriteLine("  comparevi-cli tokenize --input \"arg string\"");
        Console.WriteLine("  comparevi-cli procs");
        Console.WriteLine("  comparevi-cli quote --path <path>");
        Console.WriteLine("  comparevi-cli operations [--name <operation>] [--names-only]");
        Console.WriteLine("  comparevi-cli providers [--name <provider>] [--names-only]");
        Console.WriteLine("  comparevi-cli compare single --input <file> --dry-run [--diff] [--exit-code <n>] [--failure-class <name>]");
        Console.WriteLine("  comparevi-cli history run --input <file> --dry-run [--diff] [--exit-code <n>] [--failure-class <name>]");
        Console.WriteLine("  comparevi-cli report consolidate --input <file> --dry-run");
        Console.WriteLine("  comparevi-cli contracts validate --input <file>");
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
        if (args.Length < 2 || !args[1].Equals("single", StringComparison.OrdinalIgnoreCase))
        {
            Console.Error.WriteLine("Usage: comparevi-cli compare single --input <file> --dry-run [--diff] [--exit-code <n>] [--failure-class <name>]");
            return 2;
        }

        return RunDryContractLane(
            lane: "compare-single",
            schema: "comparevi-cli/compare-single@v1",
            command: "compare single",
            args: args,
            tailStart: 2
        );
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

        if (!TryReadOption(args, 2, "--input", out var inputPath) || string.IsNullOrWhiteSpace(inputPath))
        {
            Console.Error.WriteLine("Missing required option: --input <file>");
            return 2;
        }

        var exists = File.Exists(inputPath);
        var payload = new Dictionary<string, object?>
        {
            ["schema"] = "comparevi-cli/contracts-validate@v1",
            ["command"] = "contracts validate",
            ["generatedAtUtc"] = DateTimeOffset.UtcNow.ToString("O"),
            ["inputPath"] = Path.GetFullPath(inputPath),
            ["exists"] = exists,
            ["valid"] = exists,
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
        var payload = new Dictionary<string, object?>
        {
            ["schema"] = schema,
            ["lane"] = lane,
            ["command"] = command,
            ["generatedAtUtc"] = DateTimeOffset.UtcNow.ToString("O"),
            ["inputPath"] = Path.GetFullPath(inputPath),
            ["dryRun"] = dryRun,
            ["simulatedExitCode"] = exitCode,
            ["resultClass"] = classification.ResultClass,
            ["isDiff"] = classification.IsDiff,
            ["gateOutcome"] = classification.GateOutcome,
            ["failureClass"] = classification.FailureClass
        };

        Console.WriteLine(JsonSerializer.Serialize(payload, SerializerOptions));
        return string.Equals(classification.GateOutcome, "pass", StringComparison.OrdinalIgnoreCase) ? 0 : 1;
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
