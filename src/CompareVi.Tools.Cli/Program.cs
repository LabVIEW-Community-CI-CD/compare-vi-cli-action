using System.Text.Json;
using System.Text.Json.Serialization;

namespace CompareVi.Tools.Cli;

internal static class Program
{
    private static int Main(string[] args)
    {
        if (args.Length >= 2 && string.Equals(args[0], "compare", StringComparison.OrdinalIgnoreCase)
            && string.Equals(args[1], "parse", StringComparison.OrdinalIgnoreCase))
        {
            return CompareParse(args.Skip(2).ToArray());
        }

        PrintUsage();
        return 2;
    }

    private static int CompareParse(string[] args)
    {
        string searchDir = ".";
        string outPath = "compare-outcome.json";

        for (int i = 0; i < args.Length; i++)
        {
            var a = args[i];
            if (a == "--search" && i + 1 < args.Length) { searchDir = args[++i]; continue; }
            if (a == "--out" && i + 1 < args.Length) { outPath = args[++i]; continue; }
            if (a == "-h" || a == "--help") { PrintCompareParseUsage(); return 0; }
        }

        try
        {
            var searchAbs = Path.GetFullPath(searchDir);
            var capturePath = FindLatest(searchAbs, "lvcompare-capture.json");
            var execPath = FindLatest(searchAbs, "compare-exec.json");

            var payload = new OutcomePayload
            {
                source = "missing",
                file = null,
                diff = null,
                exitCode = null,
                durationMs = null,
                cliPath = null,
                command = null,
                stdoutPath = null,
                stdoutLen = null,
                stderrPath = null,
                stderrLen = null,
                reportPath = null,
                captureJson = capturePath,
                capture = new OutcomeNode { status = capturePath != null ? "present" : "missing", reason = capturePath != null ? null : "no_capture_json", path = capturePath },
                compareExec = new OutcomeNode { status = execPath != null ? "present" : "missing", reason = execPath != null ? null : "no_exec_json", path = execPath },
            };

            if (!string.IsNullOrEmpty(capturePath) && File.Exists(capturePath))
            {
                try
                {
                    using var s = File.OpenRead(capturePath);
                    using var doc = JsonDocument.Parse(s);
                    payload.capture!.status = "ok";
                    payload.capture.reason = null;
                    payload.source = "capture";
                    payload.file = capturePath;
                    if (doc.RootElement.TryGetProperty("exitCode", out var exitEl) && exitEl.TryGetInt32(out var ec))
                        payload.exitCode = ec;
                    if (doc.RootElement.TryGetProperty("seconds", out var secEl) && secEl.TryGetDouble(out var secs))
                        payload.durationMs = Math.Round(secs * 1000.0, 3);
                    if (doc.RootElement.TryGetProperty("command", out var cmdEl))
                        payload.command = cmdEl.GetString();
                    if (doc.RootElement.TryGetProperty("cliPath", out var cliEl))
                        payload.cliPath = cliEl.GetString();
                    if (payload.exitCode.HasValue)
                        payload.diff = payload.exitCode.Value == 1;

                    var capDir = Path.GetDirectoryName(capturePath) ?? searchAbs;
                    var stdoutCandidate = Path.Combine(capDir, "lvcompare-stdout.txt");
                    var stderrCandidate = Path.Combine(capDir, "lvcompare-stderr.txt");
                    if (File.Exists(stdoutCandidate)) payload.stdoutPath = stdoutCandidate;
                    if (File.Exists(stderrCandidate)) payload.stderrPath = stderrCandidate;
                    var reportStaging = Path.Combine(capDir, Path.Combine("_staging", Path.Combine("compare", "compare-report.html")));
                    var reportCandidate = Path.Combine(capDir, "compare-report.html");
                    if (File.Exists(reportStaging)) payload.reportPath = reportStaging;
                    else if (File.Exists(reportCandidate)) payload.reportPath = reportCandidate;

                    if (doc.RootElement.TryGetProperty("stdoutLen", out var sl) && sl.TryGetInt32(out var sLen)) payload.stdoutLen = sLen;
                    if (doc.RootElement.TryGetProperty("stderrLen", out var elen) && elen.TryGetInt32(out var eLen)) payload.stderrLen = eLen;
                }
                catch (Exception ex)
                {
                    payload.capture!.status = "error";
                    payload.capture.reason = "parse_error";
                    payload.capture.error = ex.Message;
                }
            }

            if (!string.IsNullOrEmpty(execPath) && File.Exists(execPath))
            {
                try
                {
                    using var s = File.OpenRead(execPath);
                    using var doc = JsonDocument.Parse(s);
                    payload.compareExec!.status = "ok";
                    payload.compareExec.path = execPath;
                    payload.compareExec.reason = null;
                    if (doc.RootElement.TryGetProperty("exitCode", out var exitEl) && exitEl.TryGetInt32(out var ec))
                        payload.compareExec.exitCode = ec;
                    if (doc.RootElement.TryGetProperty("diff", out var diffEl) && diffEl.ValueKind == JsonValueKind.True || (diffEl.ValueKind == JsonValueKind.False))
                        payload.compareExec.diff = diffEl.GetBoolean();

                    double? durMs = null;
                    if (doc.RootElement.TryGetProperty("durationMs", out var dms) && dms.TryGetDouble(out var dmsVal)) durMs = dmsVal;
                    else if (doc.RootElement.TryGetProperty("duration_s", out var ds) && ds.TryGetDouble(out var dsVal)) durMs = Math.Round(dsVal * 1000.0, 3);

                    if (string.Equals(payload.source, "compare-exec", StringComparison.Ordinal))
                    {
                        payload.file = execPath;
                        payload.exitCode = payload.compareExec.exitCode ?? payload.exitCode;
                        payload.diff = payload.compareExec.diff ?? payload.diff;
                        payload.durationMs = durMs ?? payload.durationMs;
                    }
                    else if (string.Equals(payload.source, "capture", StringComparison.Ordinal))
                    {
                        if (!payload.exitCode.HasValue && payload.compareExec.exitCode.HasValue) payload.exitCode = payload.compareExec.exitCode;
                        if (!payload.diff.HasValue && payload.compareExec.diff.HasValue) payload.diff = payload.compareExec.diff;
                        if (!payload.durationMs.HasValue && durMs.HasValue) payload.durationMs = durMs;
                    }
                    else
                    {
                        payload.source = "compare-exec";
                        payload.file = execPath;
                        payload.exitCode = payload.compareExec.exitCode ?? payload.exitCode;
                        payload.diff = payload.compareExec.diff ?? payload.diff;
                        payload.durationMs = durMs ?? payload.durationMs;
                    }

                    if (doc.RootElement.TryGetProperty("cliPath", out var cliEl)) payload.cliPath = cliEl.GetString() ?? payload.cliPath;
                    if (doc.RootElement.TryGetProperty("command", out var cmdEl)) payload.command = cmdEl.GetString() ?? payload.command;
                }
                catch (Exception ex)
                {
                    payload.compareExec!.status = "error";
                    payload.compareExec.reason = "parse_error";
                    payload.compareExec.error = ex.Message;
                }
            }

            var shouldFail = false;
            if (payload.source == "missing" && string.IsNullOrEmpty(capturePath) && string.IsNullOrEmpty(execPath)) shouldFail = true;
            if (payload.compareExec!.status is "missing" or "error") shouldFail = true;
            if (string.Equals(payload.compareExec.reason, "parse_error", StringComparison.Ordinal)) shouldFail = true;
            if (string.Equals(payload.compareExec.reason, "missing_report", StringComparison.Ordinal)) shouldFail = true;
            if (string.Equals(payload.capture!.status, "error", StringComparison.Ordinal) && string.Equals(payload.capture.reason, "parse_error", StringComparison.Ordinal)) shouldFail = true;

            var outAbs = Path.GetFullPath(outPath);
            Directory.CreateDirectory(Path.GetDirectoryName(outAbs) ?? ".");
            var json = JsonSerializer.Serialize(payload, new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.CamelCase, DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull, WriteIndented = true });
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

    private static string? FindLatest(string root, string fileName)
    {
        try
        {
            var files = Directory.EnumerateFiles(root, fileName, new EnumerationOptions { RecurseSubdirectories = true, MatchCasing = MatchCasing.CaseInsensitive }).ToArray();
            if (files.Length == 0) return null;
            return files.Select(p => new FileInfo(p)).OrderByDescending(fi => fi.LastWriteTimeUtc).First().FullName;
        }
        catch { return null; }
    }

    private static void PrintUsage()
    {
        Console.WriteLine("CompareVi.Tools.Cli");
        Console.WriteLine("Commands:");
        Console.WriteLine("  compare parse --search <dir> --out <path>");
    }

    private static void PrintCompareParseUsage()
    {
        Console.WriteLine("Usage: compare parse --search <dir> --out <path>");
        Console.WriteLine("Search for lvcompare-capture.json and compare-exec.json under <dir>, produce a merged outcome JSON.");
    }
}

internal sealed class OutcomePayload
{
    public string? source { get; set; }
    public string? file { get; set; }
    public bool? diff { get; set; }
    public int? exitCode { get; set; }
    public double? durationMs { get; set; }
    public string? cliPath { get; set; }
    public string? command { get; set; }
    public string? stdoutPath { get; set; }
    public int? stdoutLen { get; set; }
    public string? stderrPath { get; set; }
    public int? stderrLen { get; set; }
    public string? reportPath { get; set; }
    public string? captureJson { get; set; }
    public OutcomeNode? capture { get; set; }
    public OutcomeNode? compareExec { get; set; }
}

internal sealed class OutcomeNode
{
    public string? status { get; set; }
    public string? reason { get; set; }
    public string? path { get; set; }
    public string? error { get; set; }
    public int? exitCode { get; set; }
    public bool? diff { get; set; }
}

