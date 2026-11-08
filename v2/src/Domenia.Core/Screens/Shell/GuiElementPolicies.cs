using System.Collections.Immutable;
using System.Text.Json;

namespace Domenia.Core;

/// <summary>Presentation restrictions only. They never grant directory rights, bypass a plan, or disable physical cancellation.</summary>
public static class GuiElementPolicies
{
    public const int MaxEntries = 512;
    public const int MaxElementLength = 96;
    private static readonly HashSet<string> KnownElements = new(
        ("TabFicheRights TabFicheAttributes TabPosteDiagnostic TabPosteProbes TabPosteActions TabPosteSecrets TabPosteWmi TabQueryWmi BtnHomeEdit BtnHomeAdd BtnHomeRefresh BtnSearchRun BtnSearchVerify BtnSearchExport BtnSearchRefresh BtnFicheRefresh BtnPostePresence BtnPosteInventory BtnQueryCollect BtnWriteExample BtnSectionScopeFollow BtnSuiteLoginTheme BtnCopyLoginDiag BtnCancel BtnCancelTask BtnCollectionFreshnessReset BtnCollectionWindowApply BtnGlobalSearch BtnGuardLegacyImport BtnGuardStoreResume BtnIndexBackup BtnIndexBackupTo BtnIndexCopyPath BtnIndexOpenFolder BtnLogin BtnLoginOtherAccount BtnLoginVaultUse BtnLoginVaultForget BtnRevealLogin BtnRootOuChoose BtnRootOuReset BtnStorageIntegrity BtnStorageMove BtnStoragePolicySave BtnStoragePurge BtnStoragePurgePreview BtnStorageRestore BtnStorageResume BtnStorageRetentionApply BtnStorageRetentionPreview BtnStorageRollback BtnStorageUsage BtnThemeToggle BtnUiZoomIn BtnUiZoomOut BtnUiZoomReset BtnUxHelpGuide BtnUxHelpToggle BtnUxNavAccount BtnUxSidebarToggle BtnUxSubjectClear ChkRemember ChkStorageAutoBackup ChkSuiteLogWrap ChkUiLogErrorsOnly ChkUiLogFollow CmbCollectionCache CmbCollectionConcurrency CmbCollectionProfile CmbCollectionWidgetMax CmbCollectionWmiRetries CmbCollectionWmiRetryDelay CmbSuiteDensity CmbSuiteLogSize LblLoginError LblStatus LogPanel LstUiProfile PwdLogin TxtCollectionWindow TxtGlobalSearch TxtLogin UxHelpBadge").Split(' '), StringComparer.OrdinalIgnoreCase);
    public static bool IsKnownElement(string name) => KnownElements.Contains(name);


    public static ImmutableArray<GuiPolicyEntry> Parse(JsonElement section)
    {
        if (section.ValueKind != JsonValueKind.Object)
        { return [Invalid("GuiElementPolicy", "Table de contrôles attendue ; politique non appliquée.")]; }
        return Parse(section.EnumerateObject().Select(p => new KeyValuePair<string, JsonElement>(p.Name, p.Value)));
    }

    public static ImmutableArray<GuiPolicyEntry> Parse(IEnumerable<KeyValuePair<string, JsonElement>> values)
    {
        var rows = values.Take(MaxEntries + 1).ToArray();
        if (rows.Length > MaxEntries)
        { return [Invalid("GuiElementPolicy", "Plus de 512 contrôles ; politique non appliquée.")]; }
        var duplicates = rows.GroupBy(p => p.Key, StringComparer.OrdinalIgnoreCase).Where(g => g.Count() > 1).Select(g => g.Key).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var result = ImmutableArray.CreateBuilder<GuiPolicyEntry>();
        foreach (var pair in rows.OrderBy(p => p.Key, StringComparer.OrdinalIgnoreCase))
        {
            if (pair.Key.Length is 0 or > MaxElementLength || !char.IsAsciiLetter(pair.Key[0]) || !pair.Key.All(c => char.IsAsciiLetterOrDigit(c) || c == '_'))
            { result.Add(Invalid("Contrôle invalide", "Identifiant de contrôle non borné ou invalide ; ignoré.")); continue; }
            if (duplicates.Contains(pair.Key))
            { result.Add(Invalid(pair.Key, "Identifiant de contrôle en double ; ignoré.")); continue; }
            var mode = pair.Value.ValueKind == JsonValueKind.String ? Normalize(pair.Value.GetString()) : null;
            result.Add(mode is null ? Invalid(pair.Key, "Valeur inconnue ; ignorée et journalisée, sans reprendre son contenu.")
                : new(pair.Key, mode, true, !IsKnownElement(pair.Key) ? "Contrôle sans correspondance dans cette interface ; ignoré et journalisé." : mode switch
                {
                    "Hidden" => "Masqué par l’administrateur.",
                    "Disabled" => "Grisé par l’administrateur ; droits et lecture seule restent prioritaires.",
                    _ => "Aucune restriction supplémentaire ; Visible ne force jamais l’activation ni la visibilité d’un contrôle non disponible.",
                }));
        }
        return result.ToImmutable();
    }

    public static string? Normalize(string? value) => value?.Trim().ToUpperInvariant() switch
    {
        "" or "DEFAULT" or "VISIBLE" or "ENABLED" or "SHOW" => "Default",
        "HIDDEN" or "HIDE" or "COLLAPSED" or "MASQUE" or "MASQUÉ" => "Hidden",
        "DISABLED" or "DISABLE" or "GRAYED" or "GREYED" or "GRISE" or "GRISÉ" => "Disabled",
        _ => null,
    };

    public static string Mode(IEnumerable<GuiPolicyEntry> entries, string element, bool cancellation = false)
    {
        // Even an administrator's visual policy cannot trap the operator in an active native operation.
        if (cancellation) { return "Default"; }
        return entries.FirstOrDefault(e => e.Valid && e.Element.Equals(element, StringComparison.OrdinalIgnoreCase))?.Policy ?? "Default";
    }

    public static bool Allows(IEnumerable<GuiPolicyEntry> entries, string element, bool cancellation = false)
        => Mode(entries, element, cancellation) is not ("Hidden" or "Disabled");

    private static GuiPolicyEntry Invalid(string element, string message) => new(element, "Unknown", false, message);
}
