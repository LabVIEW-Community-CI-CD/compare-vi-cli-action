using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace CompareVi.Shared.Cli;

public sealed record CliCompareQueue(
    [property: JsonPropertyName("schema")] string Schema,
    [property: JsonPropertyName("generatedAt")] string? GeneratedAt,
    [property: JsonPropertyName("updatedAt")] string? UpdatedAt,
    [property: JsonPropertyName("cases")] IReadOnlyList<CliCompareQueueCase> Cases)
{
    public const string ExpectedSchema = "cli-compare-queue/v1";

    private static readonly JsonSerializerOptions SerializerOptions = new()
    {
        PropertyNameCaseInsensitive = false,
        ReadCommentHandling = JsonCommentHandling.Skip,
        AllowTrailingCommas = true,
    };

    public static CliCompareQueue Load(string path)
    {
        using var stream = File.OpenRead(path);
        var queue = JsonSerializer.Deserialize<CliCompareQueue>(stream, SerializerOptions)
                    ?? throw new InvalidDataException($"Failed to deserialize CLI compare queue from '{path}'.");
        queue.Validate(path);
        return queue;
    }

    public void Validate(string? source = null)
    {
        if (!string.Equals(Schema, ExpectedSchema, StringComparison.Ordinal))
        {
            throw new InvalidDataException($"Queue schema mismatch: expected '{ExpectedSchema}' but found '{Schema}'.");
        }

        if (Cases is null || Cases.Count == 0)
        {
            throw new InvalidDataException("Queue must contain at least one case.");
        }

        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var caseItem in Cases)
        {
            caseItem.Validate(source ?? "queue");
            if (!seen.Add(caseItem.Id))
            {
                throw new InvalidDataException($"Duplicate CLI compare case id '{caseItem.Id}'.");
            }
        }
    }

    public IEnumerable<CliCompareQueueCase> EnabledCases() => Cases.Where(static c => !c.Disabled.GetValueOrDefault());
}

public sealed record CliCompareQueueCase(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("name")] string Name,
    [property: JsonPropertyName("base")] string Base,
    [property: JsonPropertyName("head")] string Head,
    [property: JsonPropertyName("tags")] IReadOnlyList<string>? Tags,
    [property: JsonPropertyName("expected")] CliCompareCaseExpectation Expected,
    [property: JsonPropertyName("cli")] CliCompareCliOptions? Cli,
    [property: JsonPropertyName("overrides")] CliCompareOverrides? Overrides,
    [property: JsonPropertyName("notes")] string? Notes,
    [property: JsonPropertyName("disabled")] bool? Disabled)
{
    public void Validate(string context)
    {
        if (string.IsNullOrWhiteSpace(Id))
        {
            throw new InvalidDataException($"Case in {context} is missing an id.");
        }

        if (string.IsNullOrWhiteSpace(Base))
        {
            throw new InvalidDataException($"Case '{Id}' is missing a base path.");
        }

        if (string.IsNullOrWhiteSpace(Head))
        {
            throw new InvalidDataException($"Case '{Id}' is missing a head path.");
        }

        Expected?.Validate(Id);
        Cli?.Validate(Id);
    }
}

public sealed record CliCompareCaseExpectation(
    [property: JsonPropertyName("diff")] string Diff,
    [property: JsonPropertyName("exitCodes")] IReadOnlyList<int>? ExitCodes)
{
    private static readonly HashSet<string> AllowedDiff = new(StringComparer.Ordinal)
    {
        "true",
        "false",
        "unknown",
    };

    public void Validate(string caseId)
    {
        if (!AllowedDiff.Contains(Diff))
        {
            throw new InvalidDataException($"Case '{caseId}' has unsupported diff expectation '{Diff}'.");
        }
    }
}

public sealed record CliCompareCliOptions(
    [property: JsonPropertyName("format")] string? Format,
    [property: JsonPropertyName("extraArgs")] IReadOnlyList<string>? ExtraArgs)
{
    private static readonly HashSet<string> AllowedFormats = new(StringComparer.OrdinalIgnoreCase)
    {
        "XML",
        "HTML",
        "TXT",
        "DOCX",
    };

    public void Validate(string caseId)
    {
        if (!string.IsNullOrWhiteSpace(Format) && !AllowedFormats.Contains(Format))
        {
            throw new InvalidDataException($"Case '{caseId}' uses unsupported CLI format '{Format}'.");
        }
    }
}

public sealed record CliCompareOverrides([property: JsonPropertyName("labviewCliPath")] string? LabviewCliPath);

