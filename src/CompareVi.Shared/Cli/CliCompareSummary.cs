using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace CompareVi.Shared.Cli;

public sealed record CliCompareQueueSummary(
    [property: JsonPropertyName("schema")] string Schema,
    [property: JsonPropertyName("generatedAt")] string GeneratedAt,
    [property: JsonPropertyName("casesPath")] string CasesPath,
    [property: JsonPropertyName("resultsRoot")] string ResultsRoot,
    [property: JsonPropertyName("selection")] CliCompareQueueSummarySelection Selection,
    [property: JsonPropertyName("cases")] IReadOnlyList<CliCompareQueueSummaryEntry> Cases,
    [property: JsonPropertyName("success")] bool Success)
{
    public const string ExpectedSchema = "cli-compare-queue-summary/v1";

    private static readonly JsonSerializerOptions SerializerOptions = new()
    {
        PropertyNameCaseInsensitive = false,
        ReadCommentHandling = JsonCommentHandling.Skip,
        AllowTrailingCommas = true,
    };

    public static CliCompareQueueSummary Load(string path)
    {
        using var stream = File.OpenRead(path);
        var summary = JsonSerializer.Deserialize<CliCompareQueueSummary>(stream, SerializerOptions)
                      ?? throw new InvalidDataException($"Failed to deserialize CLI compare queue summary from '{path}'.");
        summary.Validate(path);
        return summary;
    }

    public void Validate(string? source = null)
    {
        if (!string.Equals(Schema, ExpectedSchema, StringComparison.Ordinal))
        {
            throw new InvalidDataException($"Summary schema mismatch: expected '{ExpectedSchema}' but found '{Schema}'.");
        }

        if (Cases is null)
        {
            throw new InvalidDataException("Summary cases array is missing.");
        }

        Selection?.Validate();

        foreach (var entry in Cases)
        {
            entry.Validate();
        }
    }
}

public sealed record CliCompareQueueSummarySelection(
    [property: JsonPropertyName("filter")] string? Filter,
    [property: JsonPropertyName("indexes")] IReadOnlyList<int> Indexes)
{
    public void Validate()
    {
        if (Indexes is null || Indexes.Count == 0)
        {
            throw new InvalidDataException("Selection indexes are required.");
        }

        if (Indexes.Any(i => i < 1))
        {
            throw new InvalidDataException("Selection indexes must be >= 1.");
        }
    }
}

public sealed record CliCompareQueueSummaryEntry(
    [property: JsonPropertyName("index")] int Index,
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("name")] string Name,
    [property: JsonPropertyName("tags")] IReadOnlyList<string>? Tags,
    [property: JsonPropertyName("base")] string Base,
    [property: JsonPropertyName("head")] string Head,
    [property: JsonPropertyName("expectedDiff")] string ExpectedDiff,
    [property: JsonPropertyName("expectedExitCodes")] IReadOnlyList<int>? ExpectedExitCodes,
    [property: JsonPropertyName("status")] string Status,
    [property: JsonPropertyName("notes")] string? Notes,
    [property: JsonPropertyName("nunit")] string? NUnit,
    [property: JsonPropertyName("exec")] string? Exec,
    [property: JsonPropertyName("exitCode")] int? ExitCode,
    [property: JsonPropertyName("diff")] bool? Diff,
    [property: JsonPropertyName("diffUnknown")] bool? DiffUnknown,
    [property: JsonPropertyName("validator")] string? Validator,
    [property: JsonPropertyName("validatorMessage")] string? ValidatorMessage,
    [property: JsonPropertyName("report")] string? Report)
{
    private static readonly HashSet<string> AllowedStatuses = new(StringComparer.OrdinalIgnoreCase)
    {
        "pending",
        "passed",
        "failed",
        "error",
    };

    public void Validate()
    {
        if (Index < 1)
        {
            throw new InvalidDataException("Summary entry index must be >= 1.");
        }

        if (string.IsNullOrWhiteSpace(Id))
        {
            throw new InvalidDataException("Summary entry id is required.");
        }

        if (string.IsNullOrWhiteSpace(Status) || !AllowedStatuses.Contains(Status))
        {
            throw new InvalidDataException($"Summary entry '{Id}' has unsupported status '{Status}'.");
        }
    }
}
