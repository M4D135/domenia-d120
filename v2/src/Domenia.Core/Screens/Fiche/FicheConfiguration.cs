using System.Collections.Immutable;
using System.Globalization;
using System.Text.Json;

namespace Domenia.Core;

/// <summary>
/// Settings of Domenia.config.json that the « Fiche » screen applies (Domenia 1 Get-CfgValue « Security » and « CallSheet »):
/// raw attribute writes, deletion of containers, typed confirmations, forced password change, length of the generated
/// password, memory and clipboard delays of a secret, and the ticket template of the call sheet. A null value means « not in
/// the file »: the default of Domenia 1 applies (<see cref="FicheSecurityPolicy.From"/>). Never holds the content of the file
/// beyond these values.
/// </summary>
public sealed record FicheConfiguration(
    ConfigurationFileState State,
    string? Problem,
    bool? AllowRawAttributeWrite,
    bool? BlockSensitiveRawAttributes,
    bool? AllowContainerDelete,
    bool? RequireTypedDeleteConfirmation,
    bool? RequireTypedHighRiskConfirmation,
    bool? ForcePasswordChangeOnReset,
    int? GeneratedPasswordLength,
    bool GeneratedPasswordLengthBounded,
    int? SecretMemorySeconds,
    int? AutoClearSecretClipboardSeconds,
    string? TicketTemplate,
    ImmutableArray<string> Warnings)
{
    public const int MinPasswordLength = 14;
    public const int MaxPasswordLength = 64;

    /// <summary>No file: every default of Domenia 1.</summary>
    public static FicheConfiguration Absent { get; } = new(ConfigurationFileState.Absent, null, null, null, null, null, null, null, null, false, null, null, null, []);

    /// <summary>Unusable file (JSON error, too large, duplicate names): ignored as a whole, the defaults apply.</summary>
    public static FicheConfiguration Invalid(string problem) => Absent with { State = ConfigurationFileState.Invalid, Problem = problem };

    /// <summary>
    /// Reads the JSON of Domenia 1 (UTF-8, byte order mark tolerated) with the rules of <see cref="LegacyConfiguration.Parse"/>:
    /// names case insensitive, a name present twice in different case makes the file unreadable. Booleans must be JSON booleans
    /// (« "true" » is ignored with a warning, never read as true); numbers are brought back into their bounds (14 to 64 for the
    /// generated password). CallSheet.TicketTemplate is a text or an array of lines. Pure: no file access.
    /// </summary>
    public static FicheConfiguration Parse(ReadOnlySpan<byte> utf8)
    {
        if (utf8.Length > LegacyConfiguration.MaxBytes)
        {
            return Invalid("fichier de plus de 1 Mo");
        }
        if (utf8.StartsWith("﻿"u8))
        {
            utf8 = utf8[3..];
        }
        try
        {
            using var document = JsonDocument.Parse(utf8.ToArray(), new JsonDocumentOptions { CommentHandling = JsonCommentHandling.Disallow, AllowTrailingCommas = false });
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object)
            {
                return Invalid("objet JSON attendu");
            }
            var warnings = new List<string>();
            var result = Absent with { State = ConfigurationFileState.Read };
            switch (Section(root, "Security", out var security))
            {
                case Lookup.Duplicate:
                    return Invalid("section Security en double");
                case Lookup.Found when security.ValueKind == JsonValueKind.Object:
                    if (!ReadSecurity(security, warnings, ref result, out var duplicate))
                    {
                        return Invalid("clé Security." + duplicate + " en double");
                    }
                    break;
            }
            switch (Section(root, "CallSheet", out var callSheet))
            {
                case Lookup.Duplicate:
                    return Invalid("section CallSheet en double");
                case Lookup.Found when callSheet.ValueKind == JsonValueKind.Object:
                    switch (Section(callSheet, "TicketTemplate", out var template))
                    {
                        case Lookup.Duplicate:
                            return Invalid("clé CallSheet.TicketTemplate en double");
                        case Lookup.Found:
                            result = result with { TicketTemplate = TemplateText(template) };
                            break;
                    }
                    break;
            }
            return result with { Warnings = [.. warnings] };
        }
        catch (JsonException)
        {
            // The parser message may quote the file: only a fixed reason is kept.
            return Invalid("JSON illisible");
        }
    }

    private enum Lookup
    {
        Absent,
        Found,
        Duplicate,
    }

    private static Lookup Section(JsonElement element, string name, out JsonElement value)
    {
        value = default;
        var found = false;
        foreach (var property in element.EnumerateObject())
        {
            if (!string.Equals(property.Name, name, StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }
            if (found)
            {
                return Lookup.Duplicate;
            }
            value = property.Value;
            found = true;
        }
        return found ? Lookup.Found : Lookup.Absent;
    }

    private static bool ReadSecurity(JsonElement security, List<string> warnings, ref FicheConfiguration result, out string duplicate)
    {
        duplicate = "";
        bool? Bool(JsonElement section, string key, ref string dup, out bool twice)
        {
            twice = false;
            switch (Section(section, key, out var value))
            {
                case Lookup.Duplicate:
                    twice = true;
                    dup = key;
                    return null;
                case Lookup.Found when value.ValueKind is JsonValueKind.True or JsonValueKind.False:
                    return value.ValueKind == JsonValueKind.True;
                case Lookup.Found when value.ValueKind != JsonValueKind.Null:
                    warnings.Add("Security." + key + " ignoré" + FrenchText.Colon + "valeur non booléenne (true ou false attendu).");
                    return null;
                default:
                    return null;
            }
        }
        int? Number(JsonElement section, string key, int min, int max, ref string dup, out bool twice, out bool bounded)
        {
            twice = false;
            bounded = false;
            switch (Section(section, key, out var value))
            {
                case Lookup.Duplicate:
                    twice = true;
                    dup = key;
                    return null;
                case Lookup.Found when value.ValueKind == JsonValueKind.Number && value.TryGetInt64(out var number):
                    var clamped = (int)Math.Clamp(number, min, max);
                    if (clamped != number)
                    {
                        bounded = true;
                        warnings.Add("Security." + key + " ramené dans ses bornes (" + FrenchText.Integer(min) + " à " + FrenchText.Integer(max) + ").");
                    }
                    return clamped;
                case Lookup.Found when value.ValueKind != JsonValueKind.Null:
                    warnings.Add("Security." + key + " ignoré" + FrenchText.Colon + "nombre entier attendu.");
                    return null;
                default:
                    return null;
            }
        }
        var raw = Bool(security, "AllowRawAttributeWrite", ref duplicate, out var t1);
        var block = Bool(security, "BlockSensitiveRawAttributes", ref duplicate, out var t2);
        var container = Bool(security, "AllowContainerDelete", ref duplicate, out var t3);
        var typedDelete = Bool(security, "RequireTypedDeleteConfirmation", ref duplicate, out var t4);
        var typedRisk = Bool(security, "RequireTypedHighRiskConfirmation", ref duplicate, out var t5);
        var force = Bool(security, "ForcePasswordChangeOnReset", ref duplicate, out var t6);
        var length = Number(security, "GeneratedPasswordLength", MinPasswordLength, MaxPasswordLength, ref duplicate, out var t7, out var lengthBounded);
        var memory = Number(security, "SecretMemorySeconds", 30, 3600, ref duplicate, out var t8, out _);
        var clipboard = Number(security, "AutoClearSecretClipboardSeconds", 5, 300, ref duplicate, out var t9, out _);
        if (t1 || t2 || t3 || t4 || t5 || t6 || t7 || t8 || t9)
        {
            return false;
        }
        result = result with
        {
            AllowRawAttributeWrite = raw,
            BlockSensitiveRawAttributes = block,
            AllowContainerDelete = container,
            RequireTypedDeleteConfirmation = typedDelete,
            RequireTypedHighRiskConfirmation = typedRisk,
            ForcePasswordChangeOnReset = force,
            GeneratedPasswordLength = length,
            GeneratedPasswordLengthBounded = lengthBounded,
            SecretMemorySeconds = memory,
            AutoClearSecretClipboardSeconds = clipboard,
        };
        return true;
    }

    // A text, or an array of lines joined by line breaks (Resolve-DomeniaCallSheetTemplate); any other value is kept as written,
    // so the template rule refuses it with its reason instead of silently ignoring it.
    private static string? TemplateText(JsonElement value) => value.ValueKind switch
    {
        JsonValueKind.Null => null,
        JsonValueKind.String => value.GetString(),
        JsonValueKind.Array => string.Join("\n", value.EnumerateArray().Select(line => line.ValueKind == JsonValueKind.String ? line.GetString() : line.GetRawText())),
        _ => value.GetRawText(),
    };
}

/// <summary>One setting in force and where it comes from (« Domenia.config.json », « défaut de Domenia 1 », « simulation »).</summary>
public sealed record FicheSettingView(string Key, string Label, string Value, string Source, string SourceLabel);

/// <summary>
/// Security settings of the fiche (Domenia 1 Security.* of Domenia.config.json): raw attribute writes, deletion of
/// containers, typed confirmations, forced password change, generated password length, memory and clipboard delays of a
/// secret. <see cref="Default"/> holds the defaults of Domenia 1. <see cref="From"/> builds the policy in force from the
/// configuration file; in simulation (in-memory overlay, no real effect, decision of David of 21/10) a raw attribute write
/// that the file does not mention is allowed so that the editor can be tried, and the provenance says so. The block list of
/// sensitive attributes always applies.
/// </summary>
public sealed record FicheSecurityPolicy(
    bool AllowRawAttributeWrite,
    bool BlockSensitiveRawAttributes,
    bool AllowContainerDelete,
    bool RequireTypedDeleteConfirmation,
    bool RequireTypedHighRiskConfirmation,
    bool ForcePasswordChangeOnReset,
    int GeneratedPasswordLength,
    int SecretMemorySeconds = 300,
    int ClipboardClearSeconds = 30)
{
    public static FicheSecurityPolicy Default { get; } = new(false, true, false, true, true, true, 16);

    /// <summary>The policy of the simulation when the configuration file says nothing.</summary>
    public static FicheSecurityPolicy Simulation { get; } = Default with { AllowRawAttributeWrite = true };

    /// <summary>The policy in force for this mode and this configuration (defaults of Domenia 1 for what the file does not set).</summary>
    public static FicheSecurityPolicy From(FicheConfiguration configuration, AppMode mode)
    {
        ArgumentNullException.ThrowIfNull(configuration);
        var simulation = mode == AppMode.Simulation;
        return new FicheSecurityPolicy(
            configuration.AllowRawAttributeWrite ?? simulation,
            configuration.BlockSensitiveRawAttributes ?? Default.BlockSensitiveRawAttributes,
            configuration.AllowContainerDelete ?? Default.AllowContainerDelete,
            configuration.RequireTypedDeleteConfirmation ?? Default.RequireTypedDeleteConfirmation,
            configuration.RequireTypedHighRiskConfirmation ?? Default.RequireTypedHighRiskConfirmation,
            configuration.ForcePasswordChangeOnReset ?? Default.ForcePasswordChangeOnReset,
            configuration.GeneratedPasswordLength ?? Default.GeneratedPasswordLength,
            configuration.SecretMemorySeconds ?? Default.SecretMemorySeconds,
            configuration.AutoClearSecretClipboardSeconds ?? Default.ClipboardClearSeconds);
    }

    /// <summary>The policy for a mode with no configuration file (tests, readers without the Store assembly).</summary>
    public static FicheSecurityPolicy For(AppMode mode) => From(FicheConfiguration.Absent, mode);

    /// <summary>Each setting in force with its provenance (improvement of FIC-001: the page says why a write is open or closed).</summary>
    public static ImmutableArray<FicheSettingView> Describe(FicheConfiguration configuration, AppMode mode)
    {
        ArgumentNullException.ThrowIfNull(configuration);
        var policy = From(configuration, mode);
        static string YesNo(bool value) => value ? "Oui" : "Non";
        FicheSettingView View(string key, string label, string value, bool fromFile, bool bounded = false, bool simulated = false)
        {
            var (source, sourceLabel) = fromFile
                ? bounded ? ("fileBounded", "Domenia.config.json, ramené dans ses bornes") : ("file", "Domenia.config.json")
                : simulated ? ("simulation", "Simulation" + FrenchText.Colon + "autorisée sur l’annuaire fictif (refusée par défaut en mode annuaire)")
                : ("default", "Valeur par défaut de Domenia 1");
            return new FicheSettingView(key, label, value, source, sourceLabel);
        }
        return
        [
            View("AllowRawAttributeWrite", "Écriture brute d’un attribut", YesNo(policy.AllowRawAttributeWrite), configuration.AllowRawAttributeWrite is not null,
                simulated: configuration.AllowRawAttributeWrite is null && mode == AppMode.Simulation),
            View("BlockSensitiveRawAttributes", "Liste de blocage des attributs sensibles", YesNo(policy.BlockSensitiveRawAttributes), configuration.BlockSensitiveRawAttributes is not null),
            View("AllowContainerDelete", "Suppression d’une OU ou d’un conteneur", YesNo(policy.AllowContainerDelete), configuration.AllowContainerDelete is not null),
            View("RequireTypedDeleteConfirmation", "Nom saisi avant une suppression", YesNo(policy.RequireTypedDeleteConfirmation), configuration.RequireTypedDeleteConfirmation is not null),
            View("RequireTypedHighRiskConfirmation", "Nom saisi avant une écriture à risque", YesNo(policy.RequireTypedHighRiskConfirmation), configuration.RequireTypedHighRiskConfirmation is not null),
            View("ForcePasswordChangeOnReset", "Changement imposé après une réinitialisation", YesNo(policy.ForcePasswordChangeOnReset), configuration.ForcePasswordChangeOnReset is not null),
            View("GeneratedPasswordLength", "Longueur du mot de passe généré", FrenchText.Count(policy.GeneratedPasswordLength, "caractère", "caractères"),
                configuration.GeneratedPasswordLength is not null, configuration.GeneratedPasswordLengthBounded),
            View("AutoClearSecretClipboardSeconds", "Effacement du presse-papiers après une copie", FrenchText.Integer(policy.ClipboardClearSeconds) + NoBreak + "s",
                configuration.AutoClearSecretClipboardSeconds is not null),
        ];
    }

    private const string NoBreak = " ";

    /// <summary>Text of the provenance of the whole file, for the journal and the page (« Domenia.config.json lu », « absent »…).</summary>
    public static string FileText(FicheConfiguration configuration)
    {
        ArgumentNullException.ThrowIfNull(configuration);
        return configuration.State switch
        {
            ConfigurationFileState.Read => "Domenia.config.json lu" + (configuration.Warnings.IsEmpty ? "." : " (" + FrenchText.Count(configuration.Warnings.Length, "valeur ignorée", "valeurs ignorées") + ")."),
            ConfigurationFileState.Invalid => "Domenia.config.json ignoré (" + (configuration.Problem ?? "illisible") + ")" + FrenchText.Colon + "valeurs par défaut de Domenia 1.",
            _ => "Domenia.config.json absent" + FrenchText.Colon + "valeurs par défaut de Domenia 1.",
        };
    }
}

/// <summary>
/// Freshness durations of the usage profile (Domenia 1 Resolve-DomeniaFreshnessTable, Parameters « Collecte »): profile chosen
/// by the operator in the local preferences (« settings.collection »), then the durations changed for that profile. Only the
/// families the fiche shows are kept (presence, console, attributes); the identity keeps 24 h and the history never expires.
/// Unreadable values are ignored: the Standard profile applies to them.
/// </summary>
public sealed record FicheFreshnessTable(string Profile, string ProfileLabel, int Attributes, int Presence, int Console, bool Custom)
{
    public const string PreferenceKey = "settings.collection";

    public static FicheFreshnessTable Standard { get; } = new("standard", "Standard", 900, 120, 300, false);

    private static readonly ImmutableDictionary<string, FicheFreshnessTable> Profiles = new Dictionary<string, FicheFreshnessTable>(StringComparer.Ordinal)
    {
        ["standard"] = Standard,
        ["slowNetwork"] = new("slowNetwork", "Réseau lent ou site distant", 3600, 600, 900, false),
        ["troubleshooting"] = new("troubleshooting", "Dépannage en direct", 300, 30, 60, false),
    }.ToImmutableDictionary(StringComparer.Ordinal);

    /// <summary>Durations from the stored collection settings (null: Standard).</summary>
    public static FicheFreshnessTable Read(JsonElement? stored)
    {
        if (stored is not JsonElement root || root.ValueKind != JsonValueKind.Object)
        {
            return Standard;
        }
        var profile = root.TryGetProperty("profile", out var p) && p.ValueKind == JsonValueKind.String && p.GetString() is string id && Profiles.ContainsKey(id) ? id : "standard";
        var table = Profiles[profile];
        if (!root.TryGetProperty("freshness", out var freshness) || freshness.ValueKind != JsonValueKind.Object
            || !freshness.TryGetProperty(profile, out var custom) || custom.ValueKind != JsonValueKind.Object)
        {
            return table;
        }
        int Pick(string family, int fallback, ref bool changed)
        {
            if (custom.TryGetProperty(family, out var value) && value.ValueKind == JsonValueKind.Number && value.TryGetInt32(out var seconds) && seconds is >= 0 and <= 604800)
            {
                changed |= seconds != fallback;
                return seconds;
            }
            return fallback;
        }
        var changed = false;
        var attributes = Pick("attributes", table.Attributes, ref changed);
        var presence = Pick("presence", table.Presence, ref changed);
        var console = Pick("console", table.Console, ref changed);
        return table with { Attributes = attributes, Presence = presence, Console = console, Custom = changed };
    }

    /// <summary>Validity of a nature in seconds (0 for the history: never stale).</summary>
    public long SecondsOf(string nature) => nature switch
    {
        "identity" => 86400,
        "attributes" => Attributes,
        "presence" => Presence,
        "console" => Console,
        _ => 0,
    };

    /// <summary>« Profil Standard », « Profil Dépannage en direct (durées personnalisées) ».</summary>
    public string Text => "Profil " + ProfileLabel + (Custom ? " (durées personnalisées)" : "");

    /// <summary>« 15 min », « 2 min », « 1 h »: short duration of a validity.</summary>
    public static string Duration(long seconds)
    {
        if (seconds <= 0)
        {
            return "sans expiration";
        }
        if (seconds < 60)
        {
            return seconds.ToString(CultureInfo.InvariantCulture) + " s";
        }
        if (seconds < 3600)
        {
            return (seconds / 60).ToString(CultureInfo.InvariantCulture) + " min";
        }
        if (seconds < 86400)
        {
            return (seconds / 3600).ToString(CultureInfo.InvariantCulture) + " h";
        }
        return (seconds / 86400).ToString(CultureInfo.InvariantCulture) + " j";
    }
}

/// <summary>
/// Settings read by the fiche from Domenia.config.json next to the executable (local file, read once, never the network).
/// Served by Domenia.Store in both modes; without it, the module applies <see cref="FicheConfiguration.Absent"/>.
/// </summary>
public interface IFicheSettingsReader : IScreenReader
{
    /// <summary>Local: the settings of the fiche, read on first call and kept for the session.</summary>
    Task<FicheConfiguration> ReadAsync(CancellationToken cancellationToken);
}
