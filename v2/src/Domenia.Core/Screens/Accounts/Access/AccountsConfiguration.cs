using System.Text.Json;

namespace Domenia.Core;

/// <summary>
/// Settings of Domenia.config.json that bound the Comptes screen (Domenia 1, same names and defaults):
/// Security.ForcePasswordChangeOnReset (FIC-014, « Changement obligatoire » checked by default), Security.AlternateCredentialIdleMinutes
/// (CPT-004, default lease of a temporary account, 1 to 480) and Remote.UseCim, Remote.UseWinRM, Remote.UsePsExecFallback,
/// Remote.UseTaskFallback (CPT-020, transport policy). Names only, never a secret. A password shown in clear is hidden again
/// after <see cref="RevealSeconds"/> (Domenia 1 Show-DomeniaSecretPeek, 5 s: a parameter, not a setting).
/// </summary>
public sealed record AccountsConfiguration(
    ConfigurationFileState State,
    bool ForcePasswordChangeOnReset,
    int AlternateCredentialIdleMinutes,
    TransportSettings Transports,
    string Source)
{
    /// <summary>Seconds a password stays shown in clear before it is hidden again (Domenia 1 TRV-219: 5 s by default).</summary>
    public const int RevealSeconds = 5;

    private const string DefaultsSource = "Réglages par défaut de Domenia 1 (Domenia.config.json absent)";

    /// <summary>Defaults of Domenia 1 (no file, or a file that cannot be used).</summary>
    public static AccountsConfiguration Defaults { get; } = new(
        ConfigurationFileState.Absent, true, CredentialRules.DefaultLeaseMinutes, TransportSettings.Defaults, DefaultsSource);

    /// <summary>
    /// Reads the JSON of Domenia 1 (UTF-8, byte order mark tolerated) with its rules: names case insensitive, a name present
    /// twice in different case makes the file unusable (defaults, said), a boolean is a JSON boolean, a whole number out of its
    /// bounds is brought back into them, any other value keeps the default. Pure: no file access, never quotes the file.
    /// </summary>
    public static AccountsConfiguration Parse(ReadOnlySpan<byte> utf8)
    {
        if (utf8.Length > LegacyConfiguration.MaxBytes)
        {
            return Unusable("fichier de plus de 1 Mo");
        }
        if (utf8.StartsWith("\uFEFF"u8))
        {
            utf8 = utf8[3..];
        }
        try
        {
            using var document = JsonDocument.Parse(utf8.ToArray(), new JsonDocumentOptions { CommentHandling = JsonCommentHandling.Disallow, AllowTrailingCommas = false });
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object)
            {
                return Unusable("objet JSON attendu");
            }
            if (!Section(root, "Security", out var security) || !Section(root, "Remote", out var remote))
            {
                return Unusable("section en double");
            }
            bool? force = null, cim = null, winrm = null, psexec = null, task = null;
            int? idle = null;
            if (!Bool(security, "ForcePasswordChangeOnReset", ref force) || !Int(security, "AlternateCredentialIdleMinutes", ref idle)
                || !Bool(remote, "UseCim", ref cim) || !Bool(remote, "UseWinRM", ref winrm)
                || !Bool(remote, "UsePsExecFallback", ref psexec) || !Bool(remote, "UseTaskFallback", ref task))
            {
                return Unusable("clé en double");
            }
            var anyRemote = cim is not null || winrm is not null || psexec is not null || task is not null;
            var defaults = TransportSettings.Defaults;
            var transports = anyRemote
                ? new TransportSettings(cim ?? defaults.UseCim, winrm ?? defaults.UseWinRm, psexec ?? defaults.UsePsExecFallback, task ?? defaults.UseTaskFallback,
                    "Domenia.config.json (section Remote\u00A0; valeurs absentes\u00A0: défauts de Domenia 1)")
                : defaults with { Source = "Défauts de Domenia 1 (Domenia.config.json lu, section Remote absente)" };
            return new AccountsConfiguration(
                ConfigurationFileState.Read,
                force ?? true,
                Math.Clamp(idle ?? CredentialRules.DefaultLeaseMinutes, CredentialRules.MinLeaseMinutes, CredentialRules.MaxLeaseMinutes),
                transports,
                "Domenia.config.json");
        }
        catch (JsonException)
        {
            return Unusable("JSON illisible");
        }
    }

    /// <summary>Defaults of Domenia 1 for a file that cannot be used, with the short reason (never its content).</summary>
    public static AccountsConfiguration Unusable(string reason) => Defaults with
    {
        State = ConfigurationFileState.Invalid,
        Transports = TransportSettings.Defaults with { Source = "Défauts de Domenia 1 (Domenia.config.json ignoré" + FrenchText.Colon + reason + ")" },
        Source = "Défauts de Domenia 1 (Domenia.config.json ignoré" + FrenchText.Colon + reason + ")",
    };

    /// <summary>The section if present and unique; false only for a duplicate name.</summary>
    private static bool Section(JsonElement root, string name, out JsonElement value)
    {
        value = default;
        var found = false;
        foreach (var property in root.EnumerateObject())
        {
            if (!string.Equals(property.Name, name, StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }
            if (found)
            {
                return false;
            }
            value = property.Value;
            found = true;
        }
        return true;
    }

    private static bool Find(JsonElement section, string name, out JsonElement value, out bool duplicate)
    {
        value = default;
        duplicate = false;
        if (section.ValueKind != JsonValueKind.Object)
        {
            return false;
        }
        var found = false;
        foreach (var property in section.EnumerateObject())
        {
            if (!string.Equals(property.Name, name, StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }
            if (found)
            {
                duplicate = true;
                return false;
            }
            value = property.Value;
            found = true;
        }
        return found;
    }

    private static bool Bool(JsonElement section, string name, ref bool? result)
    {
        if (Find(section, name, out var value, out var duplicate))
        {
            result = value.ValueKind switch
            {
                JsonValueKind.True => true,
                JsonValueKind.False => false,
                _ => result,
            };
        }
        return !duplicate;
    }

    private static bool Int(JsonElement section, string name, ref int? result)
    {
        if (Find(section, name, out var value, out var duplicate) && value.ValueKind == JsonValueKind.Number)
        {
            if (value.TryGetInt32(out var number))
            {
                result = number;
            }
            else if (value.TryGetDouble(out var real) && !double.IsNaN(real))
            {
                result = real > int.MaxValue ? int.MaxValue : real < int.MinValue ? int.MinValue : (int)Math.Round(real);
            }
        }
        return !duplicate;
    }
}

/// <summary>
/// The settings of Domenia.config.json read for the Comptes screen (Domenia.Store, next to the executable). Read once, off the
/// UI thread, at the first use; never the network. Without it (tests), <see cref="AccountsConfiguration.Defaults"/> apply.
/// </summary>
public interface IAccountsConfigurationReader : IScreenReader
{
    /// <summary>The settings in force (defaults when the file is absent or unusable, which is said in their source).</summary>
    Task<AccountsConfiguration> CurrentAsync(CancellationToken cancellationToken);
}
