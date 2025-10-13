using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace CompareVi.Tools.Cli;

internal static class CompareCommands
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        WriteIndented = true
    };

    public static int Dispatch(string[] args)
    {
        if (args.Length == 0)
        {
            PrintCompareUsage();
            return 1;
        }

        var sub = args[0].ToLowerInvariant();
        var remaining = args.Skip(1).ToArray();
        return sub switch
        {
            "parse" => CompareParse(remaining),
            "nunit" => CompareNunit(remaining),
            _ => UnknownCompareSub(sub)
        };
    }

    public static int DispatchNunit(string[] args) => CompareNunit(args);

    private static int UnknownCompareSub(string sub)
    {
        Console.Error.WriteLine($"Unknown compare subcommand '{sub}'.");
        PrintCompareUsage();
        return 2;
    }

    private static int CompareParse(string[] args)
    {
        string searchDir = ".";
        string outPath = "compare-outcome.json";

        for (int i = 0; i < args.Length; i++)
        {
            var a = args[i];
            switch (a)
            {
                case "--search":
                    if (i + 1 >= args.Length) { Console.Error.WriteLine("--search requires a value."); return 2; }
                    searchDir = args[++i];
                    break;
                case "--out":
                    if (i + 1 >= args.Length) { Console.Error.WriteLine("--out requires a value."); return 2; }
                    outPath = args[++i];
                    break;
                case "-h":
                case "--help":
                    PrintCompareParseUsage();
                    return 0;
            }
        }

        try
        {
            var searchAbs = Path.GetFullPath(string.IsNullOrWhiteSpace(searchDir) ? "." : searchDir);
            var capturePath = FindLatest(searchAbs, "lvcompare-capture.json");
            var execPath = FindLatest(searchAbs, "compare-exec.json");

            var payload = new OutcomePayload
            {
                Source = "missing",
                File = null,
                Diff = null,
                ExitCode = null,
                DurationMs = null,
                CliPath = null,
                Command = null,
                StdoutPath = null,
                StdoutLen = null,
                StderrPath = null,
                StderrLen = null,
                ReportPath = null,
                CaptureJson = capturePath,
                Capture = new OutcomeNode { Status = capturePath != null ? "present" : "missing", Reason = capturePath != null ? null : "no_capture_json", Path = capturePath },
                CompareExec = new OutcomeNode { Status = execPath != null ? "present" : "missing", Reason = execPath != null ? null : "no_exec_json", Path = execPath }
            };

            if (!string.IsNullOrEmpty(capturePath) && File.Exists(capturePath))
            {
                try
                {
                    using var s = File.OpenRead(capturePath);
                    using var doc = JsonDocument.Parse(s);
                    payload.Capture!.Status = "ok";
                    payload.Capture.Reason = null;
                    payload.Source = "capture";
                    payload.File = capturePath;
                    if (doc.RootElement.TryGetProperty("exitCode", out var exitEl) && exitEl.TryGetInt32(out var exitCode))
                        payload.ExitCode = exitCode;
                    if (doc.RootElement.TryGetProperty("seconds", out var secEl) && secEl.TryGetDouble(out var seconds))
                        payload.DurationMs = Math.Round(seconds * 1000.0, 3);
                    if (doc.RootElement.TryGetProperty("command", out var cmdEl))
                        payload.Command = cmdEl.GetString();
                    if (doc.RootElement.TryGetProperty("cliPath", out var cliEl))
                        payload.CliPath = cliEl.GetString();
                    if (payload.ExitCode.HasValue)
                        payload.Diff = payload.ExitCode.Value == 1;

                    if (doc.RootElement.TryGetProperty("stdoutLen", out var stdoutLenEl) && stdoutLenEl.TryGetInt32(out var stdoutLen))
                        payload.StdoutLen = stdoutLen;
                    if (doc.RootElement.TryGetProperty("stderrLen", out var stderrLenEl) && stderrLenEl.TryGetInt32(out var stderrLen))
                        payload.StderrLen = stderrLen;

                    var capDir = Path.GetDirectoryName(capturePath) ?? searchAbs;
                    var stdoutCandidate = Path.Combine(capDir, "lvcompare-stdout.txt");
                    var stderrCandidate = Path.Combine(capDir, "lvcompare-stderr.txt");
                    if (File.Exists(stdoutCandidate)) payload.StdoutPath = stdoutCandidate;
                    if (File.Exists(stderrCandidate)) payload.StderrPath = stderrCandidate;

                    var reportStaging = Path.Combine(capDir, Path.Combine("_staging", Path.Combine("compare", "compare-report.html")));
                    var reportCandidate = Path.Combine(capDir, "compare-report.html");
                    if (File.Exists(reportStaging)) payload.ReportPath = reportStaging;
                    else if (File.Exists(reportCandidate)) payload.ReportPath = reportCandidate;
                }
                catch (Exception ex)
                {
                    payload.Capture!.Status = "error";
                    payload.Capture.Reason = "parse_error";
                    payload.Capture.Error = ex.Message;
                }
            }

            if (!string.IsNullOrEmpty(execPath) && File.Exists(execPath))
            {
                try
                {
                    using var s = File.OpenRead(execPath);
                    using var doc = JsonDocument.Parse(s);
                    payload.CompareExec!.Status = "ok";
                    payload.CompareExec.Path = execPath;
                    payload.CompareExec.Reason = null;
                    if (doc.RootElement.TryGetProperty("exitCode", out var exitEl) && exitEl.TryGetInt32(out var exitCode))
                        payload.CompareExec.ExitCode = exitCode;
                    if (doc.RootElement.TryGetProperty("diff", out var diffEl) && diffEl.ValueKind is JsonValueKind.True or JsonValueKind.False)
                        payload.CompareExec.Diff = diffEl.GetBoolean();

                    double? durationMs = null;
                    if (doc.RootElement.TryGetProperty("durationMs", out var durationMsEl) && durationMsEl.TryGetDouble(out var durationMsVal))
                        durationMs = durationMsVal;
                    else if (doc.RootElement.TryGetProperty("duration_s", out var durationSecEl) && durationSecEl.TryGetDouble(out var durationSecVal))
                        durationMs = Math.Round(durationSecVal * 1000.0, 3);

                    if (string.Equals(payload.Source, "compare-exec", StringComparison.Ordinal))
                    {
                        payload.File = execPath;
                        payload.ExitCode = payload.CompareExec.ExitCode ?? payload.ExitCode;
                        payload.Diff = payload.CompareExec.Diff ?? payload.Diff;
                        payload.DurationMs = durationMs ?? payload.DurationMs;
                    }
                    else if (string.Equals(payload.Source, "capture", StringComparison.Ordinal))
                    {
                        if (!payload.ExitCode.HasValue && payload.CompareExec.ExitCode.HasValue)
                            payload.ExitCode = payload.CompareExec.ExitCode;
                        if (!payload.Diff.HasValue && payload.CompareExec.Diff.HasValue)
                            payload.Diff = payload.CompareExec.Diff;
                        if (!payload.DurationMs.HasValue && durationMs.HasValue)
                            payload.DurationMs = durationMs;
                    }
                    else
                    {
                        payload.Source = "compare-exec";
                        payload.File = execPath;
                        payload.ExitCode = payload.CompareExec.ExitCode ?? payload.ExitCode;
                        payload.Diff = payload.CompareExec.Diff ?? payload.Diff;
                        payload.DurationMs = durationMs ?? payload.DurationMs;
                    }

                    if (doc.RootElement.TryGetProperty("cliPath", out var cliEl))
                        payload.CliPath = cliEl.GetString() ?? payload.CliPath;
                    if (doc.RootElement.TryGetProperty("command", out var cmdEl))
                        payload.Command = cmdEl.GetString() ?? payload.Command;
                }
                catch (Exception ex)
                {
                    payload.CompareExec!.Status = "error";
                    payload.CompareExec.Reason = "parse_error";
                    payload.CompareExec.Error = ex.Message;
                }
            }

            var shouldFail = false;
            if (payload.Source == "missing" && string.IsNullOrEmpty(capturePath) && string.IsNullOrEmpty(execPath)) shouldFail = true;
            if (payload.CompareExec!.Status is "missing" or "error") shouldFail = true;
            if (string.Equals(payload.CompareExec.Reason, "parse_error", StringComparison.Ordinal)) shouldFail = true;
            if (string.Equals(payload.CompareExec.Reason, "missing_report", StringComparison.Ordinal)) shouldFail = true;
            if (string.Equals(payload.Capture!.Status, "error", StringComparison.Ordinal) && string.Equals(payload.Capture.Reason, "parse_error", StringComparison.Ordinal)) shouldFail = true;

            var outAbs = Path.GetFullPath(outPath);
            Directory.CreateDirectory(Path.GetDirectoryName(outAbs) ?? ".");
            var json = JsonSerializer.Serialize(payload, JsonOptions);
            File.WriteAllText(outAbs, json);

            Console.WriteLine($"compare-parse: wrote {outAbs}");
            if (shouldFail)
            {
                Console.Error.WriteLine("compare-parse: failure conditions detected (missing/parse_error)");
                return 1;
            }

            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"compare-parse: error: {ex.Message}");
            return 1;
        }
    }

    private static int CompareNunit(string[] args)
    {
        string? basePath = null;
        string? headPath = null;
        string outputPath = "results-nunit.xml";
        string mode = "labview-cli";
        string? reportPath = null;
        double durationSeconds = 0;
        bool diff = false;
        bool diffUnknown = false;
        int exitCode = 0;
        string? reason = null;

        for (int i = 0; i < args.Length; i++)
        {
            var a = args[i];
            switch (a)
            {
                case "--base":
                    if (i + 1 >= args.Length) { Console.Error.WriteLine("--base requires a value."); return 2; }
                    basePath = args[++i];
                    break;
                case "--head":
                    if (i + 1 >= args.Length) { Console.Error.WriteLine("--head requires a value."); return 2; }
                    headPath = args[++i];
                    break;
                case "--out":
                    if (i + 1 >= args.Length) { Console.Error.WriteLine("--out requires a value."); return 2; }
                    outputPath = args[++i];
                    break;
                case "--mode":
                    if (i + 1 >= args.Length) { Console.Error.WriteLine("--mode requires a value."); return 2; }
                    mode = args[++i];
                    break;
                case "--report":
                    if (i + 1 >= args.Length) { Console.Error.WriteLine("--report requires a value."); return 2; }
                    reportPath = args[++i];
                    break;
                case "--duration-seconds":
                    if (i + 1 >= args.Length || !double.TryParse(args[++i], out durationSeconds))
                    {
                        Console.Error.WriteLine("--duration-seconds requires a numeric value.");
                        return 2;
                    }
                    break;
                case "--duration-ms":
                    if (i + 1 >= args.Length || !double.TryParse(args[++i], out var durationMs))
                    {
                        Console.Error.WriteLine("--duration-ms requires a numeric value.");
                        return 2;
                    }
                    durationSeconds = durationMs / 1000.0;
                    break;
                case "--exit-code":
                    if (i + 1 >= args.Length || !int.TryParse(args[++i], out exitCode))
                    {
                        Console.Error.WriteLine("--exit-code requires an integer value.");
                        return 2;
                    }
                    break;
                case "--diff":
                    diff = true;
                    break;
                case "--diff-unknown":
                    diffUnknown = true;
                    break;
                case "--reason":
                    if (i + 1 >= args.Length) { Console.Error.WriteLine("--reason requires a value."); return 2; }
                    reason = args[++i];
                    break;
                case "-h":
                case "--help":
                    PrintNunitUsage();
                    return 0;
            }
        }

        if (string.IsNullOrWhiteSpace(basePath) || string.IsNullOrWhiteSpace(headPath))
        {
            Console.Error.WriteLine("--base and --head are required.");
            PrintNunitUsage();
            return 2;
        }

        try
        {
            var baseAbs = Path.GetFullPath(basePath);
            var headAbs = Path.GetFullPath(headPath);
            var outAbs = Path.GetFullPath(outputPath);
            Directory.CreateDirectory(Path.GetDirectoryName(outAbs) ?? ".");

            var timestamp = DateTimeOffset.Now.ToString("o");
            var passed = !(diff || diffUnknown || exitCode >= 2);
            var resultAttr = passed ? "Passed" : "Failed";
            var passedCount = passed ? 1 : 0;
            var failedCount = passed ? 0 : 1;
            var durationStr = durationSeconds.ToString("0.000");
            var testName = $"CLI Compare: {Path.GetFileName(baseAbs)} vs {Path.GetFileName(headAbs)}";

            var properties = new List<string>();
            if (!string.IsNullOrEmpty(reportPath))
            {
                properties.Add($"      <property name=\"reportPath\" value=\"{EscapeXml(reportPath)}\" />");
            }
            properties.Add($"      <property name=\"mode\" value=\"{EscapeXml(mode)}\" />");
            properties.Add($"      <property name=\"exitCode\" value=\"{exitCode}\" />");
            properties.Add($"      <property name=\"diffUnknown\" value=\"{diffUnknown}\" />");
            properties.Add($"      <property name=\"durationSeconds\" value=\"{durationStr}\" />");

            var failure = "";
            if (!passed)
            {
                var msg = diffUnknown
                    ? "Diff status unknown"
                    : diff
                        ? "Differences detected"
                        : exitCode >= 2 ? $"CLI failed (exit {exitCode})" : "Failed";
                if (!string.IsNullOrWhiteSpace(reason))
                {
                    msg = $"{msg} ({reason})";
                }

                failure = string.Join(Environment.NewLine, new[] { "    <failure>", $"      <message>{EscapeXml(msg)}</message>", "    </failure>" });
            }

            var xml = new StringBuilder();
            xml.AppendLine("<?xml version=\"1.0\" encoding=\"utf-8\"?>");
            xml.AppendLine($"<test-run id=\"1\" name=\"LabVIEW CLI Compare\" testcasecount=\"1\" result=\"{resultAttr}\" total=\"1\" passed=\"{passedCount}\" failed=\"{failedCount}\" start-time=\"{timestamp}\">");
            xml.AppendLine("  <test-suite type=\"TestSuite\" name=\"LabVIEW CLI Compare\" executed=\"True\" result=\"" + resultAttr + "\">");
            xml.AppendLine("    <results>");
            xml.AppendLine("      <test-case name=\"" + EscapeXml(testName) + "\" executed=\"True\" result=\"" + resultAttr + "\" duration=\"" + durationStr + "\">");
            foreach (var prop in properties) xml.AppendLine(prop);
            if (!string.IsNullOrEmpty(failure)) xml.AppendLine(failure);
            xml.AppendLine("      </test-case>");
            xml.AppendLine("    </results>");
            xml.AppendLine("  </test-suite>");
            xml.AppendLine("</test-run>");

            File.WriteAllText(outAbs, xml.ToString());
            Console.WriteLine($"compare-nunit: wrote {outAbs}");
            return passed ? 0 : 1;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"compare-nunit: error: {ex.Message}");
            return 1;
        }
    }

    private static string EscapeXml(string value)
        => string.IsNullOrEmpty(value) ? string.Empty : System.Security.SecurityElement.Escape(value) ?? value;

    private static string? FindLatest(string root, string fileName)
    {
        try
        {
            var files = Directory.EnumerateFiles(root, fileName, new EnumerationOptions
            {
                RecurseSubdirectories = true,
                MatchCasing = MatchCasing.CaseInsensitive
            }).ToArray();
            if (files.Length == 0) return null;
            return files.Select(p => new FileInfo(p)).OrderByDescending(fi => fi.LastWriteTimeUtc).First().FullName;
        }
        catch
        {
            return null;
        }
    }

    private static void PrintCompareUsage()
    {
        Console.WriteLine("Usage:");
        Console.WriteLine("  compare parse --search <dir> --out <path>");
        Console.WriteLine("  compare nunit --base <path> --head <path> [options]");
    }

    private static void PrintCompareParseUsage()
    {
        Console.WriteLine("Usage: compare parse --search <dir> --out <path>");
        Console.WriteLine("Search for compare artifacts and emit a merged outcome JSON.");
    }

    private static void PrintNunitUsage()
    {
        Console.WriteLine("Usage: compare nunit --base <path> --head <path> [options]");
        Console.WriteLine("Options:");
        Console.WriteLine("  --out <path>               Output NUnit XML file (default: results-nunit.xml)");
        Console.WriteLine("  --mode <value>             Compare mode (default: labview-cli)");
        Console.WriteLine("  --report <path>            Compare report path to embed");
        Console.WriteLine("  --duration-seconds <num>   Duration in seconds (default: 0)");
        Console.WriteLine("  --duration-ms <num>        Duration in milliseconds (alternative)");
        Console.WriteLine("  --exit-code <num>          Compare exit code (default: 0)");
        Console.WriteLine("  --diff                     Mark diff=true");
        Console.WriteLine("  --diff-unknown             Mark diffUnknown=true");
        Console.WriteLine("  --reason <text>            Optional failure reason");
    }

    private sealed class OutcomePayload
    {
        public string? Source { get; set; }
        public string? File { get; set; }
        public bool? Diff { get; set; }
        public int? ExitCode { get; set; }
        public double? DurationMs { get; set; }
        public string? CliPath { get; set; }
        public string? Command { get; set; }
        public string? StdoutPath { get; set; }
        public int? StdoutLen { get; set; }
        public string? StderrPath { get; set; }
        public int? StderrLen { get; set; }
        public string? ReportPath { get; set; }
        public string? CaptureJson { get; set; }
        public OutcomeNode? Capture { get; set; }
        public OutcomeNode? CompareExec { get; set; }
    }

    private sealed class OutcomeNode
    {
        public string? Status { get; set; }
        public string? Reason { get; set; }
        public string? Path { get; set; }
        public string? Error { get; set; }
        public int? ExitCode { get; set; }
        public bool? Diff { get; set; }
    }
}
