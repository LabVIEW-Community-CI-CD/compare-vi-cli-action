using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json.Nodes;

namespace CompareVi.Shared
{
    public sealed record OperationParameterSpec(
        string Id,
        string? Type,
        bool Required,
        IReadOnlyList<string> Env,
        JsonNode? DefaultValue,
        string? Description)
    {
        public JsonNode? CloneDefault() => DefaultValue?.DeepClone();
    }

    public sealed record OperationSpecEntry(
        string Name,
        IReadOnlyList<OperationParameterSpec> Parameters)
    {
        public OperationParameterSpec? FindParameter(string id) =>
            Parameters.FirstOrDefault(p => string.Equals(p.Id, id, StringComparison.OrdinalIgnoreCase));
    }

    public sealed record OperationCatalogDocument(IReadOnlyList<OperationSpecEntry> Operations)
    {
        public int OperationCount => Operations.Count;

        public OperationSpecEntry? Find(string name) =>
            Operations.FirstOrDefault(op => string.Equals(op.Name, name, StringComparison.OrdinalIgnoreCase));

        internal static OperationCatalogDocument FromJson(JsonObject root)
        {
            if (!root.TryGetPropertyValue("operations", out var operationsNode) || operationsNode is not JsonArray operationsArray)
            {
                throw new InvalidDataException("Operation spec is missing an 'operations' array.");
            }

            var operations = new List<OperationSpecEntry>(operationsArray.Count);
            foreach (var item in operationsArray)
            {
                if (item is not JsonObject obj)
                {
                    continue;
                }

                if (!obj.TryGetPropertyValue("name", out var nameNode) || nameNode is not JsonValue nameValue ||
                    !nameValue.TryGetValue(out string? name) || string.IsNullOrWhiteSpace(name))
                {
                    continue;
                }

                var parameters = new List<OperationParameterSpec>();
                if (obj.TryGetPropertyValue("parameters", out var parametersNode) && parametersNode is JsonArray parametersArray)
                {
                    foreach (var paramNode in parametersArray)
                    {
                        if (paramNode is not JsonObject paramObj)
                        {
                            continue;
                        }

                        if (!paramObj.TryGetPropertyValue("id", out var idNode) || idNode is not JsonValue idValue ||
                            !idValue.TryGetValue(out string? id) || string.IsNullOrWhiteSpace(id))
                        {
                            continue;
                        }

                        string? type = null;
                        if (paramObj.TryGetPropertyValue("type", out var typeNode) && typeNode is JsonValue typeValue)
                        {
                            typeValue.TryGetValue(out type);
                        }

                        bool required = false;
                        if (paramObj.TryGetPropertyValue("required", out var requiredNode) && requiredNode is JsonValue requiredValue)
                        {
                            requiredValue.TryGetValue(out required);
                        }

                        var env = new List<string>();
                        if (paramObj.TryGetPropertyValue("env", out var envNode) && envNode is JsonArray envArray)
                        {
                            foreach (var envEntry in envArray)
                            {
                                if (envEntry is JsonValue envValue && envValue.TryGetValue(out string? envString) &&
                                    !string.IsNullOrWhiteSpace(envString))
                                {
                                    env.Add(envString);
                                }
                            }
                        }

                        JsonNode? defaultValue = null;
                        if (paramObj.TryGetPropertyValue("default", out var defaultNode) && defaultNode is not null)
                        {
                            defaultValue = defaultNode.DeepClone();
                        }

                        string? description = null;
                        if (paramObj.TryGetPropertyValue("description", out var descNode) && descNode is JsonValue descValue)
                        {
                            descValue.TryGetValue(out description);
                        }

                        parameters.Add(new OperationParameterSpec(id!, type, required, env, defaultValue, description));
                    }
                }

                operations.Add(new OperationSpecEntry(name!, parameters));
            }

            return new OperationCatalogDocument(operations);
        }
    }

    public static class OperationCatalog
    {
        private const string ResourceName = "CompareVi.Shared.Operations.operations.json";

        public static JsonObject LoadRaw()
        {
            using var stream = typeof(OperationCatalog).Assembly.GetManifestResourceStream(ResourceName)
                ?? throw new InvalidOperationException($"Embedded operations spec '{ResourceName}' not found.");

            if (JsonNode.Parse(stream) is not JsonObject root)
            {
                throw new InvalidDataException("Embedded operations spec is not a JSON object.");
            }

            return (JsonObject)root.DeepClone();
        }

        public static OperationCatalogDocument Load()
        {
            var raw = LoadRaw();
            return OperationCatalogDocument.FromJson(raw);
        }
    }
}
