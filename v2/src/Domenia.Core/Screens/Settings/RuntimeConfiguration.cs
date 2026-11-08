using System.Text.Json;
using Domenia.Core.Poste;

namespace Domenia.Core;

/// <summary>One immutable startup interpretation. Unknown content is not retained; typed readers receive the same bounded
/// values that the settings report displays. Preferences remain a separate, explicit per-user override.</summary>
public sealed record RuntimeConfiguration(ConfigurationReport Report, FicheConfiguration Fiche, PosteConfiguration Poste,
    ShellPolicy Shell, SyncSettings Sync, JsonElement Search)
{
    public AccountsConfiguration Accounts { get; init; } = AccountsConfiguration.Defaults;
    public static RuntimeConfiguration Default { get; } = Read(null, "Défauts de la session");
    public static RuntimeConfiguration Read(byte[]? bytes, string label)
    {
        var report = ConfigurationRules.Read(bytes, label);
        var values = new Dictionary<string, Dictionary<string, JsonElement>>(StringComparer.OrdinalIgnoreCase);
        if (report.FileState == "read" && bytes is not null)
        {
            var span = bytes.AsSpan();
            if (span.StartsWith("\uFEFF"u8)) span = span[3..];
            using var original = JsonDocument.Parse(span.ToArray());
            foreach (var section in original.RootElement.EnumerateObject().Where(p => p.Value.ValueKind == JsonValueKind.Object))
                values[section.Name] = section.Value.EnumerateObject().ToDictionary(p => p.Name, p => p.Value.Clone(), StringComparer.OrdinalIgnoreCase);
        }
        foreach (var section in report.Sections)
        {
            if (!values.TryGetValue(section.Id, out var entries)) values[section.Id] = entries = new(StringComparer.OrdinalIgnoreCase);
            foreach (var entry in section.Entries.Where(e => e.Source != "default"))
            {
                var definition = ConfigurationRules.Catalog.Single(d => d.Section == entry.Section && d.Key == entry.Key);
                entries[entry.Key] = definition.Kind switch
                {
                    ConfigValueKind.Boolean => JsonSerializer.SerializeToElement(entry.Value == "true"),
                    ConfigValueKind.Integer => JsonSerializer.SerializeToElement(long.Parse(entry.Value, System.Globalization.CultureInfo.InvariantCulture)),
                    _ => JsonSerializer.SerializeToElement(entry.Value),
                };
            }
        }
        var normalized = JsonSerializer.SerializeToUtf8Bytes(values);
        if (normalized.Length > LegacyConfiguration.MaxBytes) return Read([0xFF], label);
        var search = JsonSerializer.SerializeToElement(values.Where(p => new[] { "UI", "Streaming", "GuiElementPolicy", "Features", "Browser" }.Contains(p.Key, StringComparer.OrdinalIgnoreCase))
            .ToDictionary(p => p.Key, p => p.Value));
        var fiche = FicheConfiguration.Parse(normalized);
        var poste = PosteConfiguration.Parse(normalized) with { SecurityLogDays = ConfigurationRules.Integer(report, "UserMachineLink", "SecurityLogDays", 14) };
        var sync = SyncSettings.Parse(normalized);
        var state = report.FileState switch { "absent" => ConfigurationFileState.Absent, "invalid" => ConfigurationFileState.Invalid, _ => ConfigurationFileState.Read };
        var accounts = state == ConfigurationFileState.Read ? AccountsConfiguration.Parse(normalized)
            : state == ConfigurationFileState.Invalid ? AccountsConfiguration.Unusable("configuration non exploitable") : AccountsConfiguration.Defaults;
        return new(report, fiche with { State = state, Problem = report.Problem }, poste with { State = state, Problem = report.Problem },
            ShellPolicies.Parse(normalized) with { Problem = report.Problem, Source = report.FileState == "read" ? "configuration" : "défaut" },
            sync with { State = state, Problem = report.Problem, Keys = [.. sync.Keys.Where(key => report.Sections.SelectMany(s => s.Entries).Any(e => e.Section == "Index" && e.Key == key && e.Source is "file" or "clamped"))] }, search)
        { Accounts = accounts };
    }
    public int Integer(string section, string key, int fallback) => ConfigurationRules.Integer(Report, section, key, fallback);
    public bool Flag(string section, string key, bool fallback) => ConfigurationRules.Boolean(Report, section, key, fallback);
}

/// <summary>Composition-only injection; not a screen capability or a bridge operation.</summary>
public interface IRuntimeConfigurationConsumer { void Configure(RuntimeConfiguration configuration); }
