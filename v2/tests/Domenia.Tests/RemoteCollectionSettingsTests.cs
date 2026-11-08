using System.Text;
using System.Text.Json;
using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Simulation;

namespace Domenia.Tests;

internal static class RemoteCollectionSettingsTests
{
    [Test]
    public static void Transient_methods_are_off_by_default_and_malformed_preferences_never_enable_them()
    {
        var defaults = PosteConfiguration.Parse("{}"u8);
        Check.False(defaults.AllowsTransient || defaults.UseTaskFallback || defaults.UsePsExecFallback || defaults.UseWmiProcess || defaults.UseWinRmScript, "aucun lanceur implicite");
        var configured = defaults with { UseTaskFallback = true, AllowRemoteArtifacts = true };
        using var bad = JsonDocument.Parse("{\"allowRemoteArtifacts\":true,\"secret\":\"never-retain\"}");
        var value = RemoteCollectionSettings.Read(bad.RootElement, configured);
        Check.False(value.AllowRemoteArtifacts, "préférence invalide ferme l’activation");
        Check.False(value.ToJson().GetRawText().Contains("never-retain", StringComparison.Ordinal), "aucune valeur étrangère conservée");
        var valid = RemoteCollectionSettings.From(configured) with { DirectMode = "dcom", TransientMode = "automatic", AutomaticTargetLimit = 12 };
        var roundTrip = RemoteCollectionSettings.Read(valid.ToJson(), defaults);
        Check.Equal(valid, roundTrip, "aller-retour des seuls réglages fermés");
        Check.Equal(InventoryTransport.Dcom, roundTrip.Apply(defaults).SelectedCimTransport, "choix manuel fixe");
        var conflict = PosteConfiguration.Parse(Encoding.UTF8.GetBytes("{\"Remote\":{\"DirectMode\":\"winrm\",\"UseWinRM\":false}}"));
        Check.False(conflict.UseCim, "transport interdit : blocage, aucun repli DCOM");
    }

    [Test]
    public static async Task Accounts_transport_table_uses_the_saved_selection_and_distinguishes_transient_launchers()
    {
        var bridge = new SimulatedBridge(); using var context = bridge.Context;
        var settings = PosteConfiguration.Defaults with { DirectMode = "dcom", AllowRemoteArtifacts = true,
            UseWmiProcess = true, UseWinRmScript = true, TransientMethod = "wmi", TransientMode = "automatic", AutomaticTargetLimit = 7 };
        await context.Preferences.SetAsync(RemoteCollectionSettings.PreferenceKey, RemoteCollectionSettings.From(settings).ToJson(), CancellationToken.None);
        var table = SimulatedBridge.Json(await bridge.CallAsync("accounts.transports"));
        var rows = table.GetProperty("rows").EnumerateArray().ToDictionary(r => r.GetProperty("id").GetString()!);
        Check.Equal("Sélectionné", rows["cimDcom"].GetProperty("state").GetString(), "DCOM manuel effectif");
        Check.Equal("Non sélectionné", rows["cimWsman"].GetProperty("state").GetString(), "WinRM autorisé mais non choisi");
        Check.Contains("7 postes", rows["wmiProcess"].GetProperty("state").GetString(), "limite automatique effective");
        Check.Equal("Désactivé ou autre méthode sélectionnée", rows["winRmScript"].GetProperty("state").GetString(), "lanceur manuel unique");
        Check.False(table.GetProperty("consentActive").GetBoolean(), "projection locale ne crée aucune autorisation d’intervention");
    }

    [Test]
    public static async Task Automatic_authorization_is_frozen_bounded_once_only_and_revoked_on_setting_change()
    {
        var a = Guid.NewGuid(); var b = Guid.NewGuid(); var foreign = Guid.NewGuid();
        var settings = PosteConfiguration.Defaults with { AllowRemoteArtifacts = true, UseTaskFallback = true, TransientMode = "automatic", AutomaticTargetLimit = 1 };
        using (TransientReadAuthorization.Begin(settings, [a, b]))
        {
            Check.True(TransientReadAuthorization.Covers(settings, a), "première cible dans le plafond");
            Check.False(TransientReadAuthorization.Covers(settings, b), "plafond de cible strict");
            Check.False(TransientReadAuthorization.Covers(settings, foreign), "aucune expansion");
            Check.False(TransientReadAuthorization.Covers(settings with { UsePsExecFallback = true }, a), "méthodes modifiées exigent un nouveau périmètre");
            var winners = await Task.WhenAll(Enumerable.Range(0, 4).Select(_ => Task.Run(() => TransientReadAuthorization.Consume(settings, a))));
            Check.Equal(1, winners.Count(v => v), "une seule consommation concurrente");
        }
        Check.False(TransientReadAuthorization.Active, "fin de campagne ferme l’autorisation");
        using (TransientReadAuthorization.Begin(settings with { AllowRemoteArtifacts = false }, [a]))
        { Check.False(TransientReadAuthorization.Covers(settings, a), "activation obligatoire"); }
    }
}
