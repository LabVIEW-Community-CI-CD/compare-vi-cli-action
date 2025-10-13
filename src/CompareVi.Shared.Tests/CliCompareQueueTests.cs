using CompareVi.Shared.Cli;
using FluentAssertions;
using Xunit;

namespace CompareVi.Shared.Tests;

public class CliCompareQueueTests
{
    [Fact]
    public void LoadSampleQueue()
    {
        var queuePath = TestHelpers.ResolveRepoPath("tests/cli-compare/cases.json");
        var queue = CliCompareQueue.Load(queuePath);

        queue.Schema.Should().Be(CliCompareQueue.ExpectedSchema);
        queue.Cases.Should().NotBeNullOrEmpty();
        queue.Cases[0].Expected.Diff.Should().NotBeNull();
    }

    [Fact]
    public void EmbeddedSchemaMatchesGeneratedFile()
    {
        var embedded = CliCompareSchemas.ReadQueueSchema();
        var generatedPath = TestHelpers.ResolveRepoPath("docs/schema/generated/cli-compare-queue.schema.json");
        var generated = File.ReadAllText(generatedPath);

        embedded.Should().Be(generated);
    }
}
