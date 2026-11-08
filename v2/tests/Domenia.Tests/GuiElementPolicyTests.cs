using System.Text;
using System.Text.Json;
using Domenia.Core;
using Domenia.Store;

namespace Domenia.Tests;

internal static class GuiElementPolicyTests
{
    private static byte[] Utf8(string text) => Encoding.UTF8.GetBytes(text);
    private static ShellPolicy Policy(string controls) => ShellPolicies.Parse(Utf8("{\"GuiElementPolicy\":" + controls + "}"));

    [Test]
    public static void Screen_controls_are_known_and_search_restrictions_accumulate()
    {
        const string names = "TabFicheRights TabFicheAttributes TabPosteDiagnostic TabPosteProbes TabPosteActions TabPosteSecrets TabPosteWmi TabQueryWmi BtnHomeEdit BtnHomeAdd BtnHomeRefresh BtnSearchRun BtnSearchVerify BtnSearchExport BtnSearchRefresh BtnFicheRefresh BtnPostePresence BtnPosteInventory BtnQueryCollect BtnWriteExample BtnSectionScopeFollow";
        Check.True(names.Split(' ').All(GuiElementPolicies.IsKnownElement), "contrôles fermés raccordés aux écrans");
        using var config = JsonDocument.Parse("""{"GuiElementPolicy":{"BtnSearchVerify":"Hidden","BtnSearchExport":"Default","BtnSearchRefresh":"Disabled"},"UI":{"Elements":{"rechercher.verify":"Disabled","rechercher.export":"Hidden","rechercher.refresh":"Default"}}}""");
        var policy = SearchPolicyRules.Read(config.RootElement, null);
        Check.True(policy.HiddenActions.SequenceEqual(["rechercher.export", "rechercher.verify", "rechercher.verifyMenu"]), "masquage prioritaire indépendamment de la source");
        Check.True(policy.DisabledActions.SequenceEqual(["rechercher.refresh"]), "Default ne lève jamais une restriction");
    }

    [Test]
    public static void Gui_only_configuration_reaches_shell_without_an_expert_section()
    {
        var policy = Policy("""{"BtnThemeToggle":"Hidden","BtnLogin":"Disabled"}""");
        Check.Null(policy.Problem, "document lisible");
        Check.True(policy.ExpertAllowed, "défaut Expert conservé");
        Check.Equal("configuration", policy.Source, "provenance du tableau GUI");
        Check.Equal("Hidden", GuiElementPolicies.Mode(policy.GuiPolicy, "btnthemetoggle"), "shell qualifié sans casse");
        Check.False(GuiElementPolicies.Allows(policy.GuiPolicy, "BtnLogin"), "validation native restreinte");
    }

    [Test]
    public static void Settings_and_shell_share_aliases_without_granting_permissions()
    {
        var bytes = Utf8("""{"UI":{"AllowExpertProfile":false},"GuiElementPolicy":{"BtnThemeToggle":" grisé ","BtnLogin":"masqué","BtnIndexBackup":"Visible"}}""");
        var policy = ShellPolicies.Parse(bytes);
        var report = ConfigurationRules.Read(bytes, "configuration de test");
        Check.True(policy.GuiPolicy.SequenceEqual(report.GuiPolicy), "même codec dans le rapport et le shell");
        Check.False(policy.ExpertAllowed, "Visible ne lève pas une autre politique");
        Check.Equal("Disabled", GuiElementPolicies.Mode(policy.GuiPolicy, "BtnThemeToggle"), "alias grisé");
        Check.Equal("Hidden", GuiElementPolicies.Mode(policy.GuiPolicy, "BtnLogin"), "alias masqué");
        Check.Equal("Default", GuiElementPolicies.Mode(policy.GuiPolicy, "BtnIndexBackup"), "Visible signifie aucune restriction supplémentaire");
    }

    [Test]
    public static void Duplicate_control_names_cannot_choose_the_last_policy()
    {
        var policy = Policy("""{"BtnLogin":"Hidden","btnlogin":"Visible","BtnThemeToggle":"Disabled"}""");
        Check.Equal(2, policy.GuiPolicy.Count(e => !e.Valid), "les deux occurrences sont refusées");
        Check.Equal("Default", GuiElementPolicies.Mode(policy.GuiPolicy, "BtnLogin"), "aucune occurrence arbitraire");
        Check.Equal("Disabled", GuiElementPolicies.Mode(policy.GuiPolicy, "BtnThemeToggle"), "autre contrôle indépendant");
    }

    [Test]
    public static void Unknown_values_and_selector_like_names_are_never_echoed_or_applied()
    {
        const string secretLike = "arbitrary-private-value-852";
        var policy = Policy("{\"BtnLogin\":\"" + secretLike + "\",\"body button\":\"Hidden\",\"FutureButton\":\"Disabled\"}");
        Check.Equal(2, policy.GuiPolicy.Count(e => !e.Valid), "mode et identifiant invalides");
        Check.False(JsonSerializer.Serialize(policy).Contains(secretLike, StringComparison.Ordinal), "valeur inconnue non réémise");
        Check.False(JsonSerializer.Serialize(policy).Contains("body button", StringComparison.Ordinal), "aucun sélecteur arbitraire");
        Check.False(GuiElementPolicies.IsKnownElement("FutureButton"), "nom futur signalé comme non raccordé");
        Check.Equal("Default", GuiElementPolicies.Mode(policy.GuiPolicy, "BtnLogin"), "mode inconnu ignoré");
    }

    [Test]
    public static void Gui_table_is_bounded_and_not_silently_truncated()
    {
        var table = Enumerable.Range(0, GuiElementPolicies.MaxEntries + 1).ToDictionary(i => "Button" + i, _ => "Hidden");
        var rejected = Policy(JsonSerializer.Serialize(table));
        Check.Equal(1, rejected.GuiPolicy.Length, "refus du tableau entier");
        Check.False(rejected.GuiPolicy[0].Valid, "refus explicite");
        Check.Contains("512", rejected.GuiPolicy[0].Text, "borne indiquée");
        table.Remove("Button512");
        var accepted = Policy(JsonSerializer.Serialize(table));
        Check.Equal(512, accepted.GuiPolicy.Length, "borne exacte acceptée");
        Check.True(accepted.GuiPolicy.All(e => e.Valid), "valeurs syntaxiquement qualifiées");
    }

    [Test]
    public static void Duplicate_sections_are_reported_without_applying_an_arbitrary_policy()
    {
        var policy = ShellPolicies.Parse(Utf8("""{"GuiElementPolicy":{"BtnLogin":"Hidden"},"guielementpolicy":{"BtnLogin":"Visible"}}"""));
        Check.Contains("double", policy.Problem!, "ambiguïté déclarée");
        Check.True(policy.GuiPolicy.IsEmpty, "pas d’arbitrage implicite");
    }

    [Test]
    public static void Native_and_physical_cancellation_remain_available_under_hidden_policy()
    {
        var policy = Policy("""{"BtnCancel":"Hidden","BtnCancelTask":"Disabled","BtnLogin":"Hidden"}""");
        Check.False(GuiElementPolicies.Allows(policy.GuiPolicy, "BtnLogin"), "témoin de la restriction active");
        Check.True(GuiElementPolicies.Allows(policy.GuiPolicy, "BtnCancel", cancellation: true), "annulation native disponible");
        Check.True(GuiElementPolicies.Allows(policy.GuiPolicy, "BtnCancelTask", cancellation: true), "arrêt physique disponible");
    }

    [Test]
    public static void Real_local_configuration_is_read_without_modifying_it()
    {
        using var folder = new TemporaryFolder();
        var path = folder.File(LegacyConfiguration.FileName);
        var bytes = Utf8("\uFEFF" + """{"GuiElementPolicy":{"BtnLogin":"Disabled","BtnThemeToggle":"Hidden"}}""");
        File.WriteAllBytes(path, bytes);
        var policy = ShellPolicyFile.Read(folder.Path);
        Check.Null(policy.Problem, "lecture locale réussie");
        Check.Equal("Disabled", GuiElementPolicies.Mode(policy.GuiPolicy, "BtnLogin"), "login réellement chargé");
        Check.Equal("Hidden", GuiElementPolicies.Mode(policy.GuiPolicy, "BtnThemeToggle"), "shell réellement chargé");
        Check.True(bytes.SequenceEqual(File.ReadAllBytes(path)), "octets conservés");
    }

    [Test]
    public static void Missing_invalid_and_oversized_local_policies_are_distinguished()
    {
        using var folder = new TemporaryFolder();
        Check.Null(ShellPolicyFile.Read(folder.Path).Problem, "absence autorisée");
        var path = folder.File(LegacyConfiguration.FileName);
        File.WriteAllText(path, "{");
        Check.Contains("JSON", ShellPolicyFile.Read(folder.Path).Problem!, "JSON illisible déclaré");
        File.WriteAllBytes(path, new byte[LegacyConfiguration.MaxBytes + 1]);
        var result = ShellPolicyFile.Read(folder.Path);
        Check.Contains("1 Mo", result.Problem!, "borne vérifiée avant parsing");
        Check.True(result.GuiPolicy.IsEmpty, "pas de politique partielle");
    }
}
