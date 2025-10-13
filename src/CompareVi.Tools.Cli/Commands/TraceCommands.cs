using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using System.Xml.Linq;

namespace CompareVi.Tools.Cli;

internal static class TraceCommands
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
            PrintTraceUsage();
            return 1;
        }

        var sub = args[0].ToLowerInvariant();
        var remaining = args.Skip(1).ToArray();
        return sub switch
        {
            "build" => Build(remaining),
            _ => UnknownTraceSub(sub)
        };
    }

    private static int UnknownTraceSub(string sub)
    {
        Console.Error.WriteLine($"Unknown trace subcommand '{sub}'.");
        PrintTraceUsage();
        return 2;
    }

    private static int Build(string[] args)
    {
        string testsPath = "tests";
        string resultsRoot = "tests/results";
        string? outDir = null;
        var includePatterns = new List<string>();
        string runId = "";
        string seed = "";
        bool renderHtml = false;

        for (int i = 0; i < args.Length; i++)
        {
            var a = args[i];
            switch (a)
            {
                case "--tests":
                    if (i + 1 >= args.Length) { Console.Error.WriteLine("--tests requires a value."); return 2; }
                    testsPath = args[++i];
                    break;
                case "--results":
                    if (i + 1 >= args.Length) { Console.Error.WriteLine("--results requires a value."); return 2; }
                    resultsRoot = args[++i];
                    break;
                case "--out-dir":
                    if (i + 1 >= args.Length) { Console.Error.WriteLine("--out-dir requires a value."); return 2; }
                    outDir = args[++i];
                    break;
                case "--include":
                    if (i + 1 >= args.Length) { Console.Error.WriteLine("--include requires a value."); return 2; }
                    includePatterns.Add(args[++i]);
                    break;
                case "--run-id":
                    if (i + 1 >= args.Length) { Console.Error.WriteLine("--run-id requires a value."); return 2; }
                    runId = args[++i];
                    break;
                case "--seed":
                    if (i + 1 >= args.Length) { Console.Error.WriteLine("--seed requires a value."); return 2; }
                    seed = args[++i];
                    break;
                case "--html":
                    renderHtml = true;
                    break;
                case "-h":
                case "--help":
                    PrintTraceBuildUsage();
                    return 0;
            }
        }

        try
        {
            var repoRoot = Directory.GetCurrentDirectory();
            var testsAbs = Path.GetFullPath(testsPath);
            var resultsAbs = Path.GetFullPath(resultsRoot);
            var outDirAbs = Path.GetFullPath(outDir ?? Path.Combine(resultsAbs, "_trace"));
            Directory.CreateDirectory(outDirAbs);

            var matrix = new TraceMatrix
            {
                Summary =
                {
                    GeneratedAt = DateTimeOffset.Now.ToString("o"),
                    RunId = runId ?? string.Empty,
                    Seed = seed ?? string.Empty
                }
            };

            var requirementCatalog = LoadRequirementCatalog(Path.Combine(repoRoot, "docs", "requirements"));
            var adrCatalog = LoadAdrCatalog(Path.Combine(repoRoot, "docs", "adr"));

            foreach (var kvp in requirementCatalog)
            {
                matrix.Requirements[kvp.Key] = new TraceRequirement
                {
                    Title = kvp.Value.Title,
                    Url = kvp.Value.Path
                };
            }

            foreach (var kvp in adrCatalog)
            {
                matrix.Adrs[kvp.Key] = new TraceAdr
                {
                    Title = kvp.Value.Title,
                    Url = kvp.Value.Path
                };
            }

            var includeRegex = includePatterns.Select(ConvertLikePatternToRegex).ToList();
            var testFiles = Directory.Exists(testsAbs)
                ? Directory.EnumerateFiles(testsAbs, "*.Tests.ps1", SearchOption.AllDirectories)
                    .Where(path => includeRegex.Count == 0 || includeRegex.Any(r => Regex.IsMatch(Path.GetFileName(path), r, RegexOptions.IgnoreCase)))
                    .OrderBy(path => path, StringComparer.OrdinalIgnoreCase)
                    .ToList()
                : new List<string>();

            var unknownRequirementIds = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

            foreach (var file in testFiles)
            {
                var relative = NormalizeRelativePath(repoRoot, file);
                var annotations = ParseAnnotations(file);
                var slug = MakeSlug(relative);
                var resultsRelative = NormalizeRelativePath(repoRoot, Path.Combine(resultsAbs, Path.Combine("pester", slug, "pester-results.xml")));
                var resultsAbsolute = Path.Combine(repoRoot, resultsRelative.Replace('/', Path.DirectorySeparatorChar));
                var stats = ParsePesterResults(resultsAbsolute);

                var testEntry = new TraceTest
                {
                    File = relative,
                    Slug = slug,
                    Status = stats.Status,
                    ReqIds = annotations.Requirements.OrderBy(x => x, StringComparer.OrdinalIgnoreCase).ToList(),
                    AdrIds = annotations.Adrs.OrderBy(x => x, StringComparer.OrdinalIgnoreCase).ToList(),
                    Passed = stats.Passed,
                    Failed = stats.Failed,
                    Skipped = stats.Skipped,
                    DurationMs = stats.DurationMs,
                    ResultsXml = resultsRelative
                };

                matrix.Tests.Add(testEntry);

                foreach (var req in testEntry.ReqIds)
                {
                    var id = req.ToUpperInvariant();
                    if (!matrix.Requirements.TryGetValue(id, out var requirement))
                    {
                        requirement = new TraceRequirement
                        {
                            Title = $"Unknown requirement ({id})",
                            Url = null
                        };
                        matrix.Requirements[id] = requirement;
                        unknownRequirementIds.Add(id);
                    }

                    if (!requirement.Tests.Contains(relative, StringComparer.OrdinalIgnoreCase))
                    {
                        requirement.Tests.Add(relative);
                    }

                    if (string.Equals(testEntry.Status, "Failed", StringComparison.OrdinalIgnoreCase)) requirement.FailCount++;
                    else if (string.Equals(testEntry.Status, "Passed", StringComparison.OrdinalIgnoreCase)) requirement.PassCount++;
                }

                foreach (var adr in testEntry.AdrIds)
                {
                    var id = adr;
                    if (!matrix.Adrs.TryGetValue(id, out var adrEntry))
                    {
                        adrEntry = new TraceAdr
                        {
                            Title = $"Unknown ADR ({id})",
                            Url = null
                        };
                        matrix.Adrs[id] = adrEntry;
                    }

                    if (!adrEntry.Tests.Contains(relative, StringComparer.OrdinalIgnoreCase))
                    {
                        adrEntry.Tests.Add(relative);
                    }
                }
            }

            matrix.Tests = matrix.Tests.OrderBy(t => t.File, StringComparer.OrdinalIgnoreCase).ToList();

            foreach (var kvp in matrix.Requirements)
            {
                var entry = kvp.Value;
                entry.Tests = entry.Tests.Distinct(StringComparer.OrdinalIgnoreCase).OrderBy(t => t, StringComparer.OrdinalIgnoreCase).ToList();
                entry.Status = entry.FailCount > 0 ? "Failed" : entry.PassCount > 0 ? "Passed" : "Unknown";
            }

            foreach (var kvp in matrix.Adrs)
            {
                var entry = kvp.Value;
                entry.Tests = entry.Tests.Distinct(StringComparer.OrdinalIgnoreCase).OrderBy(t => t, StringComparer.OrdinalIgnoreCase).ToList();
                var hasFailed = entry.Tests.Any(test => matrix.Tests.FirstOrDefault(t => string.Equals(t.File, test, StringComparison.OrdinalIgnoreCase)) is { Status: var status } && string.Equals(status, "Failed", StringComparison.OrdinalIgnoreCase));
                var hasPassed = entry.Tests.Any(test => matrix.Tests.FirstOrDefault(t => string.Equals(t.File, test, StringComparison.OrdinalIgnoreCase)) is { Status: var status } && string.Equals(status, "Passed", StringComparison.OrdinalIgnoreCase));
                entry.Status = hasFailed ? "Failed" : hasPassed ? "Passed" : "Unknown";
            }

            matrix.Summary.Files = new TraceCount
            {
                Total = matrix.Tests.Count,
                Covered = matrix.Tests.Count(t => t.ReqIds.Count > 0 || t.AdrIds.Count > 0)
            };
            matrix.Summary.Files.Uncovered = Math.Max(0, matrix.Summary.Files.Total - matrix.Summary.Files.Covered);

            matrix.Summary.Requirements = new TraceCount
            {
                Total = matrix.Requirements.Count,
                Covered = matrix.Requirements.Count(kvp => kvp.Value.Tests.Count > 0)
            };
            matrix.Summary.Requirements.Uncovered = Math.Max(0, matrix.Summary.Requirements.Total - matrix.Summary.Requirements.Covered);

            matrix.Summary.Adrs = new TraceCount
            {
                Total = matrix.Adrs.Count,
                Covered = matrix.Adrs.Count(kvp => kvp.Value.Tests.Count > 0)
            };
            matrix.Summary.Adrs.Uncovered = Math.Max(0, matrix.Summary.Adrs.Total - matrix.Summary.Adrs.Covered);

            matrix.Gaps.RequirementsWithoutTests = matrix.Requirements
                .Where(kvp => kvp.Value.Tests.Count == 0)
                .Select(kvp => kvp.Key)
                .OrderBy(id => id, StringComparer.OrdinalIgnoreCase)
                .ToList();

            matrix.Gaps.TestsWithoutRequirements = matrix.Tests
                .Where(t => t.ReqIds.Count == 0)
                .Select(t => t.File)
                .OrderBy(f => f, StringComparer.OrdinalIgnoreCase)
                .ToList();

            matrix.Gaps.AdrsWithoutTests = matrix.Adrs
                .Where(kvp => kvp.Value.Tests.Count == 0)
                .Select(kvp => kvp.Key)
                .OrderBy(id => id, StringComparer.OrdinalIgnoreCase)
                .ToList();

            matrix.Gaps.UnknownRequirementIds = unknownRequirementIds
                .OrderBy(id => id, StringComparer.OrdinalIgnoreCase)
                .ToList();

            var jsonPath = Path.Combine(outDirAbs, "trace-matrix.json");
            var json = JsonSerializer.Serialize(matrix, JsonOptions);
            File.WriteAllText(jsonPath, json);
            Console.WriteLine($"trace build: wrote {jsonPath}");

            if (renderHtml)
            {
                WriteTraceHtml(repoRoot, outDirAbs, matrix);
            }

            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"trace build: error: {ex.Message}");
            return 1;
        }
    }

    private static void WriteTraceHtml(string repoRoot, string outDirAbs, TraceMatrix matrix)
    {
        var sb = new StringBuilder();
        sb.AppendLine("<!DOCTYPE html>");
        sb.AppendLine("<html><head><meta charset=\"utf-8\"/><title>Test Traceability Matrix</title>");
        sb.AppendLine("<style>body{font-family:Segoe UI,Arial,sans-serif;font-size:14px;margin:16px;} table{border-collapse:collapse;width:100%;margin-bottom:20px;} th,td{border:1px solid #ddd;padding:6px;text-align:left;} th{background:#f5f5f5;} .chip{padding:2px 8px;border-radius:12px;color:#fff;font-size:12px;} .chip.pass{background:#2e7d32;} .chip.fail{background:#c62828;} .chip.unk{background:#6d6d6d;} .muted{color:#666;} a{color:#1769aa;text-decoration:none;} a:hover{text-decoration:underline;}</style>");
        sb.AppendLine("</head><body>");
        sb.AppendLine("<h1>Test Traceability Matrix</h1>");
        sb.AppendLine($"<p>Generated: {matrix.Summary.GeneratedAt}</p>");
        if (!string.IsNullOrEmpty(matrix.Summary.RunId)) sb.AppendLine($"<p>Run ID: <code>{matrix.Summary.RunId}</code></p>");
        if (!string.IsNullOrEmpty(matrix.Summary.Seed)) sb.AppendLine($"<p>Seed: <code>{matrix.Summary.Seed}</code></p>");

        sb.AppendLine("<h2>Requirements Coverage</h2>");
        sb.AppendLine("<table><tr><th>Requirement</th><th>Status</th><th>#Tests</th><th>Tests</th></tr>");
        var testLookup = matrix.Tests.ToDictionary(t => t.File, StringComparer.OrdinalIgnoreCase);
        foreach (var requirement in matrix.Requirements.OrderBy(kvp => kvp.Key, StringComparer.OrdinalIgnoreCase))
        {
            var entry = requirement.Value;
            var statusClass = GetStatusClass(entry.Status);
            var docLink = string.IsNullOrEmpty(entry.Url)
                ? requirement.Key
                : $"<a href=\"{NormalizeRelativePath(outDirAbs, Path.Combine(repoRoot, entry.Url.Replace('/', Path.DirectorySeparatorChar)))}\">{requirement.Key}</a>";
            var testsCell = entry.Tests.Count > 0
                ? string.Join("<br/>", entry.Tests.Select(t =>
                {
                    if (testLookup.TryGetValue(t, out var test))
                    {
                        var resultsAbs = Path.Combine(repoRoot, test.ResultsXml.Replace('/', Path.DirectorySeparatorChar));
                        if (File.Exists(resultsAbs))
                        {
                            var rel = NormalizeRelativePath(outDirAbs, resultsAbs);
                            return $"<a href=\"{rel}\">{t}</a>";
                        }
                    }
                    return t;
                }))
                : "<span class=\"muted\">-</span>";

            sb.AppendLine($"<tr><td>{docLink}</td><td><span class=\"{statusClass}\">{entry.Status}</span></td><td>{entry.Tests.Count}</td><td>{testsCell}</td></tr>");
        }
        sb.AppendLine("</table>");

        sb.AppendLine("<h2>ADR Coverage</h2>");
        sb.AppendLine("<table><tr><th>ADR</th><th>Status</th><th>#Tests</th><th>Tests</th></tr>");
        foreach (var adr in matrix.Adrs.OrderBy(kvp => kvp.Key, StringComparer.OrdinalIgnoreCase))
        {
            var entry = adr.Value;
            var statusClass = GetStatusClass(entry.Status);
            var docLink = string.IsNullOrEmpty(entry.Url)
                ? adr.Key
                : $"<a href=\"{NormalizeRelativePath(outDirAbs, Path.Combine(repoRoot, entry.Url.Replace('/', Path.DirectorySeparatorChar)))}\">{adr.Key}</a>";
            var testsCell = entry.Tests.Count > 0
                ? string.Join("<br/>", entry.Tests.Select(t =>
                {
                    if (testLookup.TryGetValue(t, out var test))
                    {
                        var resultsAbs = Path.Combine(repoRoot, test.ResultsXml.Replace('/', Path.DirectorySeparatorChar));
                        if (File.Exists(resultsAbs))
                        {
                            var rel = NormalizeRelativePath(outDirAbs, resultsAbs);
                            return $"<a href=\"{rel}\">{t}</a>";
                        }
                    }
                    return t;
                }))
                : "<span class=\"muted\">-</span>";

            sb.AppendLine($"<tr><td>{docLink}</td><td><span class=\"{statusClass}\">{entry.Status}</span></td><td>{entry.Tests.Count}</td><td>{testsCell}</td></tr>");
        }
        sb.AppendLine("</table>");

        sb.AppendLine("<h2>Tests</h2>");
        sb.AppendLine("<table><tr><th>Test File</th><th>Status</th><th>Requirements</th><th>ADRs</th></tr>");
        foreach (var test in matrix.Tests.OrderBy(t => t.File, StringComparer.OrdinalIgnoreCase))
        {
            var statusClass = GetStatusClass(test.Status);
            var reqList = test.ReqIds.Count > 0 ? string.Join("<br/>", test.ReqIds) : "<span class=\"muted\">-</span>";
            var adrList = test.AdrIds.Count > 0 ? string.Join("<br/>", test.AdrIds) : "<span class=\"muted\">-</span>";
            var resultsAbs = Path.Combine(repoRoot, test.ResultsXml.Replace('/', Path.DirectorySeparatorChar));
            var fileCell = File.Exists(resultsAbs)
                ? $"<a href=\"{NormalizeRelativePath(outDirAbs, resultsAbs)}\">{test.File}</a>"
                : test.File;
            sb.AppendLine($"<tr><td>{fileCell}</td><td><span class=\"{statusClass}\">{test.Status}</span></td><td>{reqList}</td><td>{adrList}</td></tr>");
        }
        sb.AppendLine("</table>");

        sb.AppendLine("</body></html>");
        var htmlPath = Path.Combine(outDirAbs, "trace-matrix.html");
        File.WriteAllText(htmlPath, sb.ToString());
        Console.WriteLine($"trace build: wrote {htmlPath}");
    }

    private static string GetStatusClass(string? status)
    {
        return string.Equals(status, "Passed", StringComparison.OrdinalIgnoreCase)
            ? "chip pass"
            : string.Equals(status, "Failed", StringComparison.OrdinalIgnoreCase)
                ? "chip fail"
                : "chip unk";
    }

    private static (HashSet<string> Requirements, HashSet<string> Adrs) ParseAnnotations(string file)
    {
        var req = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var adr = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        var content = File.ReadAllText(file);
        foreach (Match match in Regex.Matches(content, @"REQ:([A-Za-z0-9_-]+)", RegexOptions.IgnoreCase))
        {
            req.Add(match.Groups[1].Value.ToUpperInvariant());
        }
        foreach (Match match in Regex.Matches(content, @"ADR:([0-9]{4})", RegexOptions.IgnoreCase))
        {
            adr.Add(match.Groups[1].Value);
        }

        foreach (var line in File.ReadLines(file).Take(50))
        {
            var m = Regex.Match(line, @"#\s*trace:\s*(?<pairs>.+)", RegexOptions.IgnoreCase);
            if (!m.Success) continue;
            var pairs = m.Groups["pairs"].Value.Split(new[] { ',', ';' }, StringSplitOptions.RemoveEmptyEntries);
            foreach (var pair in pairs)
            {
                var kv = pair.Split(new[] { '=' }, 2, StringSplitOptions.RemoveEmptyEntries)
                    .Select(v => v.Trim())
                    .ToArray();
                if (kv.Length != 2) continue;
                var key = kv[0].ToLowerInvariant();
                var values = kv[1].Split(new[] { ' ', '|' }, StringSplitOptions.RemoveEmptyEntries);
                switch (key)
                {
                    case "req":
                        foreach (var value in values) req.Add(value.ToUpperInvariant());
                        break;
                    case "adr":
                        foreach (var value in values.Where(v => Regex.IsMatch(v, "^\\d{4}$", RegexOptions.CultureInvariant)))
                        {
                            adr.Add(value);
                        }
                        break;
                }
            }
        }

        return (req, adr);
    }

    private static string MakeSlug(string relativePath)
    {
        var fileName = relativePath.Replace('/', '-');
        return Regex.Replace(fileName, "[^A-Za-z0-9]+", "-").Trim('-');
    }

    private static PesterStats ParsePesterResults(string path)
    {
        if (!File.Exists(path))
        {
            return new PesterStats("Unknown", 0, 0, 0, null);
        }

        try
        {
            var doc = XDocument.Load(path);
            var testCases = doc.Descendants("test-case").ToList();
            var passed = testCases.Count(tc => string.Equals((string?)tc.Attribute("result"), "Passed", StringComparison.OrdinalIgnoreCase));
            var failed = testCases.Count(tc => string.Equals((string?)tc.Attribute("result"), "Failed", StringComparison.OrdinalIgnoreCase));
            var skipped = testCases.Count(tc => string.Equals((string?)tc.Attribute("result"), "Skipped", StringComparison.OrdinalIgnoreCase));

            double totalSeconds = 0;
            foreach (var testCase in testCases)
            {
                if (testCase.Attribute("duration") is XAttribute durationAttr && double.TryParse(durationAttr.Value, out var durationValue))
                {
                    totalSeconds += durationValue;
                }
            }
            double? durationMs = testCases.Count > 0 ? Math.Round(totalSeconds * 1000.0, 3) : null;

            var status = failed > 0 ? "Failed" : passed > 0 ? "Passed" : "Unknown";
            return new PesterStats(status, passed, failed, skipped, durationMs);
        }
        catch
        {
            return new PesterStats("Unknown", 0, 0, 0, null);
        }
    }

    private static Dictionary<string, CatalogEntry> LoadRequirementCatalog(string path)
    {
        var result = new Dictionary<string, CatalogEntry>(StringComparer.OrdinalIgnoreCase);
        if (!Directory.Exists(path)) return result;

        foreach (var file in Directory.EnumerateFiles(path, "*.md", SearchOption.TopDirectoryOnly))
        {
            var id = Path.GetFileNameWithoutExtension(file).ToUpperInvariant();
            var content = File.ReadAllText(file);
            var titleMatch = Regex.Match(content, "^\\s*#\\s+(?<title>.+)$", RegexOptions.Multiline);
            var title = titleMatch.Success ? titleMatch.Groups["title"].Value.Trim() : id;
            var relative = NormalizeRelativePath(Directory.GetCurrentDirectory(), file);
            result[id] = new CatalogEntry(title, relative);
        }

        return result;
    }

    private static Dictionary<string, CatalogEntry> LoadAdrCatalog(string path)
    {
        var result = new Dictionary<string, CatalogEntry>(StringComparer.OrdinalIgnoreCase);
        if (!Directory.Exists(path)) return result;

        foreach (var file in Directory.EnumerateFiles(path, "*.md", SearchOption.TopDirectoryOnly)
                     .Where(f => Regex.IsMatch(Path.GetFileNameWithoutExtension(f), "^\\d{4}-", RegexOptions.CultureInvariant)))
        {
            var id = Path.GetFileNameWithoutExtension(file).Substring(0, 4);
            var content = File.ReadAllText(file);
            var titleMatch = Regex.Match(content, "^\\s*#\\s+(?<title>.+)$", RegexOptions.Multiline);
            var title = titleMatch.Success ? titleMatch.Groups["title"].Value.Trim() : Path.GetFileNameWithoutExtension(file);
            var relative = NormalizeRelativePath(Directory.GetCurrentDirectory(), file);
            result[id] = new CatalogEntry(title, relative);
        }

        return result;
    }

    private static string NormalizeRelativePath(string basePath, string fullPath)
    {
        var relative = Path.GetRelativePath(basePath, fullPath);
        return relative.Replace('\\', '/');
    }

    private static string ConvertLikePatternToRegex(string pattern)
    {
        var escaped = Regex.Escape(pattern).Replace(@"\*", ".*").Replace(@"\?", ".");
        return $"^{escaped}$";
    }

    private static void PrintTraceUsage()
    {
        Console.WriteLine("Usage: trace build [options]");
    }

    private static void PrintTraceBuildUsage()
    {
        Console.WriteLine("Usage: trace build [options]");
        Console.WriteLine("Options:");
        Console.WriteLine("  --tests <path>        Tests root (default: tests)");
        Console.WriteLine("  --results <path>      Results root (default: tests/results)");
        Console.WriteLine("  --out-dir <path>      Output directory (default: <results>/_trace)");
        Console.WriteLine("  --include <pattern>   Include pattern (repeatable)");
        Console.WriteLine("  --run-id <value>      Run identifier");
        Console.WriteLine("  --seed <value>        Seed identifier");
        Console.WriteLine("  --html                Render HTML in addition to JSON");
    }

    private sealed record CatalogEntry(string Title, string Path);

    private sealed class TraceMatrix
    {
        [JsonPropertyName("schema")]
        public string Schema { get; set; } = "trace-matrix/v1";
        [JsonPropertyName("summary")]
        public TraceSummary Summary { get; set; } = new();
        [JsonPropertyName("requirements")]
        public SortedDictionary<string, TraceRequirement> Requirements { get; set; } = new(StringComparer.OrdinalIgnoreCase);
        [JsonPropertyName("adrs")]
        public SortedDictionary<string, TraceAdr> Adrs { get; set; } = new(StringComparer.OrdinalIgnoreCase);
        [JsonPropertyName("tests")]
        public List<TraceTest> Tests { get; set; } = new();
        [JsonPropertyName("gaps")]
        public TraceGaps Gaps { get; set; } = new();
    }

    private sealed class TraceSummary
    {
        [JsonPropertyName("generatedAt")]
        public string GeneratedAt { get; set; } = DateTimeOffset.Now.ToString("o");
        [JsonPropertyName("runId")]
        public string RunId { get; set; } = string.Empty;
        [JsonPropertyName("seed")]
        public string Seed { get; set; } = string.Empty;
        [JsonPropertyName("files")]
        public TraceCount Files { get; set; } = new();
        [JsonPropertyName("requirements")]
        public TraceCount Requirements { get; set; } = new();
        [JsonPropertyName("adrs")]
        public TraceCount Adrs { get; set; } = new();
    }

    private sealed class TraceCount
    {
        [JsonPropertyName("total")]
        public int Total { get; set; }
        [JsonPropertyName("covered")]
        public int Covered { get; set; }
        [JsonPropertyName("uncovered")]
        public int Uncovered { get; set; }
    }

    private sealed class TraceRequirement
    {
        [JsonPropertyName("title")]
        public string Title { get; set; } = string.Empty;
        [JsonPropertyName("url")]
        public string? Url { get; set; }
        [JsonPropertyName("tests")]
        public List<string> Tests { get; set; } = new();
        [JsonPropertyName("status")]
        public string Status { get; set; } = "Unknown";
        [JsonPropertyName("passCount")]
        public int PassCount { get; set; }
        [JsonPropertyName("failCount")]
        public int FailCount { get; set; }
    }

    private sealed class TraceAdr
    {
        [JsonPropertyName("title")]
        public string Title { get; set; } = string.Empty;
        [JsonPropertyName("url")]
        public string? Url { get; set; }
        [JsonPropertyName("tests")]
        public List<string> Tests { get; set; } = new();
        [JsonPropertyName("status")]
        public string Status { get; set; } = "Unknown";
    }

    private sealed class TraceTest
    {
        [JsonPropertyName("file")]
        public string File { get; set; } = string.Empty;
        [JsonPropertyName("slug")]
        public string Slug { get; set; } = string.Empty;
        [JsonPropertyName("status")]
        public string Status { get; set; } = "Unknown";
        [JsonPropertyName("reqIds")]
        public List<string> ReqIds { get; set; } = new();
        [JsonPropertyName("adrIds")]
        public List<string> AdrIds { get; set; } = new();
        [JsonPropertyName("passed")]
        public int Passed { get; set; }
        [JsonPropertyName("failed")]
        public int Failed { get; set; }
        [JsonPropertyName("skipped")]
        public int Skipped { get; set; }
        [JsonPropertyName("durationMs")]
        public double? DurationMs { get; set; }
        [JsonPropertyName("resultsXml")]
        public string ResultsXml { get; set; } = string.Empty;
    }

    private sealed class TraceGaps
    {
        [JsonPropertyName("requirementsWithoutTests")]
        public List<string> RequirementsWithoutTests { get; set; } = new();
        [JsonPropertyName("testsWithoutRequirements")]
        public List<string> TestsWithoutRequirements { get; set; } = new();
        [JsonPropertyName("adrsWithoutTests")]
        public List<string> AdrsWithoutTests { get; set; } = new();
        [JsonPropertyName("unknownRequirementIds")]
        public List<string> UnknownRequirementIds { get; set; } = new();
    }

    private sealed record PesterStats(string Status, int Passed, int Failed, int Skipped, double? DurationMs);
}



