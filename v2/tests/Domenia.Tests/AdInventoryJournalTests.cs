using Domenia.Ad;
using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Inventory;

namespace Domenia.Tests;

internal static class AdInventoryJournalTests
{
    [Test]
    public static async Task Selected_workstation_reader_routes_failures_to_the_bound_application_journal_without_contact()
    {
        foreach (var mode in new[] { "dcom", "winrm" })
        {
            var journal = new RecordingJournal(); var copies = 0;
            using var ldap = new AdBoundaryTests.RecordingAdConnection();
            using var source = new AdDirectorySource("test.local", () => @"TEST\reader", TestClock.Fixed(), connection: ldap)
            { SessionCredentialCopy = () => { copies++; return new("reader", "TEST", PasswordSecrets.FromText("inventory-journal-test-fixture"), false); } };
            source.AdoptConnection(ldap, Fixtures.Domain,
                new(new(@"TEST\reader", null, null, "CN=reader," + Fixtures.People), Fixtures.Domain.DomainSid + "-1001",
                    new(RightsLevel.Unknown, "Inconnus", true, "Droits AD distincts."))
                { Administration = new(AdministrationIdentityState.Standard, "Aucune preuve d’administration.") }, source.Epoch, false);
            using var context = new EngineContext(new(AppMode.Directory, ModeReason.Argument, "Test", null, "test.local", []),
                source, new MemoryPreferenceStore(), source.Clock, journal);
            await context.Preferences.SetAsync(RemoteCollectionSettings.PreferenceKey,
                RemoteCollectionSettings.From(PosteConfiguration.Defaults with { DirectMode = mode }).ToJson(), CancellationToken.None);
            using var access = await AdWorkstationAccess.AcquireAsync(source, "PC1.test.local", CancellationToken.None, readOnly: true);
            var reader = access.InventoryReader(); // Same production factory used by Poste, relations, search and workshop.
            var before = journal.Lines.Count; var children = NativeReadProcess.Running;
            const string invalidTarget = "DO-NOT-LOG/invalid-target";
            var result = await reader.ReadAsync(invalidTarget, WorkstationReading.Quick, null, CancellationToken.None, access.Credential);
            Check.Equal("ATTENTION Lecture du poste non faite : nom de poste invalide.", journal.Lines.Skip(before).Single(),
                "l’échec du vrai lecteur arrive au journal du contexte, sans journal de test injecté dans le lecteur");
            Check.False(journal.Lines.Any(line => line.Contains(invalidTarget, StringComparison.Ordinal)), "cible arbitraire absente du journal");
            Check.True(result.Access.Length > 0 && result.Access.All(item => item.Status == SourceStatus.Error && item.Items == 0), "refus explicite avant lecture");
            Check.Equal(mode == "dcom" ? InventoryTransport.Dcom : InventoryTransport.WinRm, result.Transport, "transport sélectionné conservé");
            Check.Equal(1, copies, "une seule identité de connexion choisie, sans autre compte");
            Check.Equal(0, ldap.Calls, "aucune lecture AD implicite");
            Check.Equal(children, NativeReadProcess.Running, "aucun processus ni contact natif sur cible invalide");
        }
    }
}
