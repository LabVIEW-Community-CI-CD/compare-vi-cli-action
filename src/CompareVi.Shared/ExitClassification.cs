namespace CompareVi.Shared
{
    public sealed class ExitClassificationResult
    {
        public string ResultClass { get; init; } = "failure-tool";
        public bool IsDiff { get; init; }
        public string GateOutcome { get; init; } = "fail";
        public string FailureClass { get; init; } = "cli/tool";
    }

    public static class ExitClassification
    {
        public static ExitClassificationResult Classify(int exitCode, bool hasDiffEvidence = false, string? declaredFailureClass = null)
        {
            var normalizedFailureClass = NormalizeFailureClass(declaredFailureClass);
            if (!string.Equals(normalizedFailureClass, "none", System.StringComparison.Ordinal))
            {
                return normalizedFailureClass switch
                {
                    "runtime-determinism" => Fail("failure-runtime", normalizedFailureClass),
                    "timeout" => Fail("failure-timeout", normalizedFailureClass),
                    "preflight" => Fail("failure-preflight", normalizedFailureClass),
                    _ => Fail("failure-tool", normalizedFailureClass)
                };
            }

            if (exitCode == 124)
            {
                return Fail("failure-timeout", "timeout");
            }

            if (hasDiffEvidence || exitCode == 1)
            {
                return Pass(diff: true, resultClass: "success-diff");
            }

            if (exitCode == 0)
            {
                return Pass(diff: false, resultClass: "success-no-diff");
            }

            return Fail("failure-tool", "cli/tool");
        }

        private static ExitClassificationResult Pass(bool diff, string resultClass)
        {
            return new ExitClassificationResult
            {
                ResultClass = resultClass,
                IsDiff = diff,
                GateOutcome = "pass",
                FailureClass = "none"
            };
        }

        private static ExitClassificationResult Fail(string resultClass, string failureClass)
        {
            return new ExitClassificationResult
            {
                ResultClass = resultClass,
                IsDiff = false,
                GateOutcome = "fail",
                FailureClass = failureClass
            };
        }

        private static string NormalizeFailureClass(string? failureClass)
        {
            if (string.IsNullOrWhiteSpace(failureClass))
            {
                return "none";
            }

            var normalized = failureClass.Trim().ToLowerInvariant();
            return normalized switch
            {
                "none" => "none",
                "runtime" => "runtime-determinism",
                "runtime-determinism" => "runtime-determinism",
                "timeout" => "timeout",
                "preflight" => "preflight",
                "startup-connectivity" => "startup-connectivity",
                "cli/tool" => "cli/tool",
                _ => normalized
            };
        }
    }
}
