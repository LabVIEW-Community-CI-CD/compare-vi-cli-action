using CompareVi.Shared;
using Xunit;

namespace CompareVi.Shared.Tests
{
    public class ExitClassificationTests
    {
        [Fact]
        public void Classify_ZeroExit_NoDiff_IsSuccessNoDiff()
        {
            var result = ExitClassification.Classify(0, hasDiffEvidence: false);
            Assert.Equal("success-no-diff", result.ResultClass);
            Assert.False(result.IsDiff);
            Assert.Equal("pass", result.GateOutcome);
            Assert.Equal("none", result.FailureClass);
        }

        [Fact]
        public void Classify_ExitOne_WithDiff_IsSuccessDiff()
        {
            var result = ExitClassification.Classify(1, hasDiffEvidence: true);
            Assert.Equal("success-diff", result.ResultClass);
            Assert.True(result.IsDiff);
            Assert.Equal("pass", result.GateOutcome);
            Assert.Equal("none", result.FailureClass);
        }

        [Fact]
        public void Classify_ExitOne_NoDiffDefaultsToDiffPass()
        {
            var result = ExitClassification.Classify(1, hasDiffEvidence: false);
            Assert.Equal("success-diff", result.ResultClass);
            Assert.True(result.IsDiff);
            Assert.Equal("pass", result.GateOutcome);
            Assert.Equal("none", result.FailureClass);
        }

        [Fact]
        public void Classify_TimeoutExit_IsFailureTimeout()
        {
            var result = ExitClassification.Classify(124, hasDiffEvidence: false);
            Assert.Equal("failure-timeout", result.ResultClass);
            Assert.Equal("fail", result.GateOutcome);
            Assert.Equal("timeout", result.FailureClass);
        }

        [Fact]
        public void Classify_DeclaredRuntimeFailure_IsFailureRuntime()
        {
            var result = ExitClassification.Classify(0, hasDiffEvidence: true, declaredFailureClass: "runtime");
            Assert.Equal("failure-runtime", result.ResultClass);
            Assert.Equal("fail", result.GateOutcome);
            Assert.Equal("runtime-determinism", result.FailureClass);
            Assert.False(result.IsDiff);
        }
    }
}
