using System.Reflection;

namespace CompareVi.Shared.Cli;

public static class CliCompareSchemas
{
    private const string ResourcePrefix = "CompareVi.Shared.Schemas.";

    public static string ReadEmbeddedSchema(string fileName)
    {
        var resourceName = ResourcePrefix + fileName;
        var assembly = Assembly.GetExecutingAssembly();
        using var stream = assembly.GetManifestResourceStream(resourceName)
            ?? throw new InvalidOperationException($"Embedded schema '{resourceName}' was not found.");
        using var reader = new StreamReader(stream);
        return reader.ReadToEnd();
    }

    public static string ReadQueueSchema() => ReadEmbeddedSchema("cli-compare-queue.schema.json");

    public static string ReadQueueSummarySchema() => ReadEmbeddedSchema("cli-compare-queue-summary.schema.json");
}
