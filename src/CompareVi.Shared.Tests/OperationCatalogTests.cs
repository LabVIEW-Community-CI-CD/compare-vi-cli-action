using System.Linq;
using CompareVi.Shared;
using Xunit;

namespace CompareVi.Shared.Tests
{
    public class OperationCatalogTests
    {
        [Fact]
        public void Load_ReturnsOperations()
        {
            var catalog = OperationCatalog.Load();

            Assert.NotNull(catalog);
            Assert.True(catalog.OperationCount > 0);
            Assert.Contains(catalog.Operations, op => op.Name == "CreateComparisonReport");
        }

        [Fact]
        public void CreateComparisonReport_HasExpectedParameters()
        {
            var catalog = OperationCatalog.Load();
            var operation = catalog.Find("CreateComparisonReport");

            Assert.NotNull(operation);
            var vi1 = operation!.FindParameter("vi1");
            var vi2 = operation.FindParameter("vi2");
            var reportType = operation.FindParameter("reportType");

            Assert.NotNull(vi1);
            Assert.True(vi1!.Required);
            Assert.Equal("path", vi1.Type);
            Assert.Contains("LV_BASE_VI", vi1.Env);

            Assert.NotNull(vi2);
            Assert.True(vi2!.Required);
            Assert.Equal("path", vi2.Type);

            Assert.NotNull(reportType);
            Assert.Equal("enum", reportType!.Type);
            Assert.False(reportType.Required);
            Assert.NotNull(reportType.CloneDefault());
        }
    }
}
