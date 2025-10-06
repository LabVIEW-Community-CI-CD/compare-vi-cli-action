using System;
using System.Collections.Generic;
using System.Text;

namespace CompareVi.Shared
{
    public static class ArgTokenizer
    {
        // Tokenize respecting quotes (single/double) and preserve inner spaces
        public static IReadOnlyList<string> Tokenize(string? input)
        {
            var result = new List<string>();
            if (string.IsNullOrWhiteSpace(input)) return result;

            var sb = new StringBuilder();
            bool inSingle = false, inDouble = false;
            for (int i = 0; i < input!.Length; i++)
            {
                char c = input[i];
                if (c == '\'' && !inDouble)
                {
                    inSingle = !inSingle; // toggle
                    continue; // drop quotes
                }
                if (c == '"' && !inSingle)
                {
                    inDouble = !inDouble; // toggle
                    continue; // drop quotes
                }
                if (char.IsWhiteSpace(c) && !inSingle && !inDouble)
                {
                    Flush();
                }
                else
                {
                    sb.Append(c);
                }
            }
            Flush();

            return result;

            void Flush()
            {
                if (sb.Length > 0)
                {
                    result.Add(sb.ToString());
                    sb.Clear();
                }
            }
        }

        // Split -flag=value into two tokens; normalize combined "-flag value" within one token; keep others intact
        public static IReadOnlyList<string> NormalizeFlagValuePairs(IEnumerable<string> tokens)
        {
            var result = new List<string>();
            foreach (var raw in tokens)
            {
                if (string.IsNullOrEmpty(raw)) continue;
                var tok = raw.Trim();
                var eq = tok.IndexOf('=');
                if (tok.StartsWith("-") && eq > 0)
                {
                    var flag = tok[..eq];
                    var val = tok[(eq + 1)..];
                    if (!string.IsNullOrEmpty(flag)) result.Add(flag);
                    if (!string.IsNullOrEmpty(val)) result.Add(val);
                    continue;
                }
                if (tok.StartsWith("-") && tok.Contains(' '))
                {
                    var idx = tok.IndexOf(' ');
                    if (idx > 0)
                    {
                        var flag = tok[..idx];
                        var val = tok[(idx + 1)..];
                        if (!string.IsNullOrEmpty(flag)) result.Add(flag);
                        if (!string.IsNullOrEmpty(val)) result.Add(val);
                        continue;
                    }
                }
                result.Add(tok);
            }
            return result;
        }
    }
}

