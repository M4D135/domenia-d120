using System.Text.Json;
using Domenia.Core.Poste;
using Domenia.Inventory;

namespace Domenia.Tests;

internal static class SoftwareInventoryTests
{
    private const string SidA = "S-1-5-21-1-2-3-1001";
    private const string SidB = "S-1-5-21-1-2-3-1002";
    private static WmiWorkstationReader Reader(Func<RegistryRequest, RegistryReply> registry)
    {
        var clock = TestClock.Fixed();
        return new(clock) { SessionFactory = (host, budget, token) => new(host, budget, clock, cancellationToken: token)
        { RegistryOverride = (request, _) => registry(request), ReadOverride = (_, _, _) => [new(new Dictionary<string, object?> { ["Name"] = "PC1" })] } };
    }
    private static RegistryReply Product(RegistryRequest r) => r.Name switch
    {
        "DisplayName" => new(0, "Éditeur App"), "DisplayVersion" => new(0, "1.2"), "Publisher" => new(0, "Éditeur"),
        "InstallDate" => new(0, "20260228"), "EstimatedSize" => new(0, uint.MaxValue),
        "UninstallString" => new(0, "\"C:\\Program Files\\App\\remove.exe\" --password NEVER-PUBLISH"),
        _ => new(2, null),
    };

    [Test]
    public static async Task Software_preserves_each_key_view_and_loaded_profile_and_never_command_arguments()
    {
        var reader = Reader(r => r.Hive == InventoryRegistry.Users && r.Key == "" ? new(0, new[] { ".DEFAULT", SidA, SidB, SidA + "_Classes" })
            : r.Method == RegistryMethod.Keys ? new(0, new[] { "App", "SecondKeySameProduct" }) : Product(r));
        var result = await reader.ReadSoftwareAsync("PC1", new(true, false, false), CancellationToken.None);
        Check.Equal("PC1", result.ReportedName, "identité indépendante lue pour la validation de l’appelant");
        Check.True(result.Complete, "registres et profils demandés lus");
        Check.Equal(12, result.Entries.Length, "2 clés × 2 vues × machine et 2 profils, aucune fusion");
        Check.Equal(4, result.Entries.Count(e => e.Profile == SidA), "profil A conservé");
        Check.Equal(4, result.Entries.Count(e => e.Profile == SidB), "profil B conservé");
        var first = result.Entries[0];
        Check.Equal(new DateOnly(2026, 2, 28), first.InstallDate!.Value, "date exacte");
        Check.Equal((long)uint.MaxValue * 1024, first.SizeBytes!.Value, "taille sans débordement 32 bits");
        Check.Equal(@"C:\Program Files\App\remove.exe", first.Uninstall, "programme sans arguments");
        Check.False(JsonSerializer.Serialize(result).Contains("NEVER-PUBLISH", StringComparison.Ordinal), "arguments absents du résultat entier");
    }

    [Test]
    public static async Task Software_filters_updates_in_both_views_and_does_not_guess_an_unread_filter()
    {
        var reader = Reader(r => r.Method == RegistryMethod.Keys ? new(0, new[] { "Normal", "Update", "Child", "Component", "Unknown" })
            : r.Name == "SystemComponent" && r.Key.EndsWith("\\Component", StringComparison.Ordinal) ? new(0, 1U)
            : r.Name == "SystemComponent" && r.Key.EndsWith("\\Unknown", StringComparison.Ordinal) ? new(5, null)
            : r.Name == "ReleaseType" && r.Key.EndsWith("\\Update", StringComparison.Ordinal) ? new(0, "Security Update")
            : r.Name == "ParentKeyName" && r.Key.EndsWith("\\Child", StringComparison.Ordinal) ? new(0, "Parent") : Product(r));
        var filtered = await reader.ReadSoftwareAsync("PC1", new(false, false, false), CancellationToken.None);
        Check.Equal(2, filtered.Entries.Length, "seules les entrées dont le filtre est établi");
        Check.Equal(SourceStatus.Partial, filtered.Access.Single(a => a.Scope == "Machine").Status, "filtre illisible explicitement incomplet");
        var all = await reader.ReadSoftwareAsync("PC1", new(false, false, true), CancellationToken.None);
        Check.Equal(10, all.Entries.Length, "option mises à jour appliquée aux deux vues");
    }

    [Test]
    public static async Task Software_refused_view_and_unknown_date_are_not_a_complete_empty_inventory()
    {
        var reader = Reader(r => r.Key == InventoryRegistry.Uninstall32 ? new(5, null)
            : r.Method == RegistryMethod.Keys ? new(0, new[] { "App" })
            : r.Name == "InstallDate" ? new(0, "20260231") : Product(r));
        var result = await reader.ReadSoftwareAsync("PC1", new(false, true, false), CancellationToken.None);
        Check.Equal(1, result.Entries.Length, "vue lisible conservée");
        Check.Null(result.Entries[0].InstallDate, "date impossible non inventée");
        Check.Equal(SourceStatus.Partial, result.Access.Single(a => a.Scope == "Machine").Status, "autre vue refusée");
        Check.Equal(SourceStatus.Unavailable, result.Access.Single(a => a.Scope == "Store").Status, "Store absent non présenté vide");
        Check.False(result.Complete, "résultat incomplet");
        result = await Reader(_ => new(5, null)).ReadSoftwareAsync("PC1", new(false, false, false), CancellationToken.None);
        Check.Equal(SourceStatus.Refused, result.Access.Single(a => a.Scope == "Machine").Status, "aucune valeur lue, refus explicite");
    }

    [Test]
    public static async Task Software_key_cap_is_shared_between_views_and_loaded_profiles()
    {
        var reads = 0;
        var reader = Reader(r => r.Hive == InventoryRegistry.Users && r.Key == "" ? new(0, new[] { SidA, SidB })
            : r.Method == RegistryMethod.Keys ? new(0, Enumerable.Range(0, 201).Select(n => "App" + n).ToArray())
            : r.Name == "DisplayName" ? Display() : new(2, null));
        RegistryReply Display() { reads++; return new(0, "App"); }
        var result = await reader.ReadSoftwareAsync("PC1", new(true, false, false), CancellationToken.None);
        Check.Equal(800, reads, "400 clés machine et 400 au total pour les profils");
        Check.Equal(800, result.Entries.Length, "bornes conservées");
        Check.True(result.Access.Where(a => a.Scope != "Store").All(a => a.Status == SourceStatus.Partial), "chaque troncature annoncée");
    }

    [Test]
    public static async Task Software_authentication_failure_has_no_retry_and_cancellation_preserves_observations()
    {
        var calls = 0;
        var reader = Reader(_ => { calls++; return new(1326, null); });
        var result = await reader.ReadSoftwareAsync("PC1", new(true, false, false), CancellationToken.None);
        Check.Equal(1, calls, "une seule tentative d’identité registre");
        Check.True(result.AuthenticationRejected, "échec d’identité pour la cascade de comptes");
        using var stop = new CancellationTokenSource();
        reader = Reader(r => r.Method == RegistryMethod.Keys ? new(0, new[] { "A", "B" })
            : r.Key.EndsWith("\\B", StringComparison.Ordinal) && r.Name == "DisplayName" ? Cancel() : Product(r));
        RegistryReply Cancel() { stop.Cancel(); return new(0, "App"); }
        result = await reader.ReadSoftwareAsync("PC1", new(false, false, false), stop.Token);
        Check.Equal(1, result.Entries.Length, "première entrée déjà publiée conservée après arrêt");
        Check.False(result.Complete, "arrêt distinct d’un inventaire complet");
    }
}
