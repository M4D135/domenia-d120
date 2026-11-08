using System.Text.Json;

namespace Domenia.Core;

internal static class ConfigurationDecisionRules
{
    internal static bool Valid(JsonElement row)
    {
        if (row.ValueKind != JsonValueKind.Object || row.EnumerateObject().Count() != 7
            || row.EnumerateObject().Select(p => p.Name).Distinct(StringComparer.OrdinalIgnoreCase).Count() != 7) return false;
        string? Text(string name) => row.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;
        var id = Text("id"); var build = Text("build"); var sha = Text("sourceSha256"); var choice = Text("choice");
        if (!Hash(id) || !Hash(sha) || build is not { Length: > 0 and <= 200 } || build.Any(char.IsControl)
            || id != ConfigurationChanges.DecisionId(build, sha!) || choice is not ("applied" or "declined")
            || !row.TryGetProperty("at", out var at) || at.ValueKind != JsonValueKind.String || !at.TryGetDateTimeOffset(out _)
            || !row.TryGetProperty("backup", out var backup) || !row.TryGetProperty("backupSha256", out var backupHash)) return false;
        if (backup.ValueKind == JsonValueKind.Null) return backupHash.ValueKind == JsonValueKind.Null;
        const string prefix = "preferences.before-configuration-";
        if (choice == "declined" || backup.ValueKind != JsonValueKind.String || Text("backup") is not { } name || name.Length != prefix.Length + 32 + 5
            || !name.StartsWith(prefix, StringComparison.Ordinal) || !name.EndsWith(".json", StringComparison.Ordinal)
            || !name.AsSpan(prefix.Length, 32).ToString().All(c => c is >= '0' and <= '9' or >= 'a' and <= 'f')) return false;
        return Hash(Text("backupSha256"));
    }
    private static bool Hash(string? text) => text is { Length: 64 } && text.All(c => c is >= '0' and <= '9' or >= 'a' and <= 'f');
}
