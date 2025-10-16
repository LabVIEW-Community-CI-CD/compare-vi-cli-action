using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;
using System.Text.Json.Nodes;
using CompareVi.Shared;

internal static class Program
{
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
                    return CmdOperations();
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
        Console.WriteLine("  comparevi-cli operations");
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
        Console.WriteLine(JsonSerializer.Serialize(obj, new JsonSerializerOptions { WriteIndented = true }));
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
        Console.WriteLine(JsonSerializer.Serialize(obj, new JsonSerializerOptions { WriteIndented = true }));
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
        Console.WriteLine(JsonSerializer.Serialize(obj, new JsonSerializerOptions { WriteIndented = true }));
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
        Console.WriteLine(JsonSerializer.Serialize(obj, new JsonSerializerOptions { WriteIndented = true }));
        return 0;
    }

    private static int CmdOperations()
    {
        var root = OperationCatalog.LoadRaw();
        if (root.TryGetPropertyValue("operations", out var operationsNode) && operationsNode is JsonArray operationsArray)
        {
            var payload = new JsonObject
            {
                ["schema"] = "comparevi-cli/operations@v1",
                ["operationCount"] = operationsArray.Count,
                ["operations"] = operationsArray.DeepClone()
            };
            Console.WriteLine(payload.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
            return 0;
        }

        throw new InvalidDataException("Embedded operations spec is missing an operations array.");
    }
}
