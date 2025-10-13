using CompareVi.Shared.Cli;
using FluentAssertions;
using Xunit;

namespace CompareVi.Shared.Tests;

public class CliCompareQueueSummaryTests
{
    [Fact]
    public void LoadSampleSummary()
    {
        var summaryPath = TestHelpers.ResolveRepoPath("tests/cli-compare/queue-summary.sample.json");
        var summary = CliCompareQueueSummary.Load(summaryPath);

        summary.Schema.Should().Be(CliCompareQueueSummary.ExpectedSchema);
        summary.Cases.Should().HaveCount(1);
        summary.Cases[0].Status.Should().Be("passed");
    }

    [Fact]
    public void EmbeddedSummarySchemaMatchesGeneratedFile()
    {
        var embedded = CliCompareSchemas.ReadQueueSummarySchema();
        var generatedPath = TestHelpers.ResolveRepoPath("docs/schema/generated/cli-compare-queue-summary.schema.json");
        var generated = File.ReadAllText(generatedPath);

        embedded.Should().Be(generated);
    }
}
