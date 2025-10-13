using System.IO;

namespace CompareVi.Shared.Tests;

internal static class TestHelpers
{
    public static string RepositoryRoot
    {
        get
        {
            var baseDir = AppContext.BaseDirectory;
            return Path.GetFullPath(Path.Combine(baseDir, "..", "..", "..", "..", ".."));
        }
    }

    public static string ResolveRepoPath(string relativePath)
    {
        return Path.GetFullPath(Path.Combine(RepositoryRoot, relativePath));
    }
}
