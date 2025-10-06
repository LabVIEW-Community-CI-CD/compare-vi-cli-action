using System;
using System.Runtime.InteropServices;

namespace CompareVi.Shared
{
    public static class PathUtils
    {
        public static bool IsWindows => RuntimeInformation.IsOSPlatform(OSPlatform.Windows);

        // Convert forward slashes to backslashes for drive-letter or UNC prefixes
        public static string NormalizeWindowsPath(string s)
        {
            if (!IsWindows) return s;
            if (string.IsNullOrEmpty(s)) return s;
            if (s.Length >= 3 && char.IsLetter(s[0]) && s[1] == ':' && s[2] == '/')
                return s.Replace('/', '\\');
            if (s.Length >= 2 && s[0] == '/' && s[1] == '/')
                return s.Replace('/', '\\');
            return s;
        }

        public static string Quote(string? s)
        {
            if (string.IsNullOrEmpty(s)) return "\"\"";
            return (s.Contains(' ') || s.Contains('"')) ? $"\"{s.Replace("\"", "\\\"")}\"" : s;
        }
    }
}

