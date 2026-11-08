using System.Collections.Immutable;
using System.Text.Json;
using Domenia.Ad;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Core.Poste;
using Domenia.Inventory;
using Domenia.Store;

namespace Domenia.Tests;

internal static class PosteDetailPersistenceTests
{
    private static WmiInstance Row(params (string Key, object? Value)[] values) => new(values.ToDictionary(v => v.Key, v => v.Value));
    private static FleetCachePatch Patch(Guid id, PosteDetailSnapshot value) => FleetCachePatch.Empty with
    { WorkstationDetails = ImmutableDictionary<Guid, ImmutableDictionary<string, PosteDetailMemory>>.Empty.Add(id,
        ImmutableDictionary<string, PosteDetailMemory>.Empty.Add(value.Family, new(value, null))) };
    private static PosteDetailSnapshot Explorer(DateTimeOffset at, string text = "valeur") => new("wmi", at, "PC1", true, 1, 0, 0, 0)
    {
        Wmi = new("PC1", @"root\cimv2", "Win32_OperatingSystem", null, 25, false,
            [new("Caption", "string", false, "")], [[text]], "Répondu", "SELECT Caption FROM Win32_OperatingSystem", 5),
    };

    [Test]
    public static void Projection_is_bounded_reports_every_loss_and_removes_sensitive_columns_and_metadata()
    {
        var raw = Explorer(Fixtures.Now) with { OriginalRows = 500 };
        raw = raw with { Wmi = raw.Wmi! with
        {
            Schema = [new("Caption", "string", false, ""), new("Password", "string", false, "")],
            Instances = Enumerable.Range(0, 500).Select(i => ImmutableArray.Create<string?>(i + new string('é', 1000), "DO_NOT_STORE")).ToImmutableArray(),
            Status = "password=DO_NOT_STORE", Where = "Caption='DO_NOT_STORE'",
        } };
        var projected = PosteDetailCache.Project(raw);
        Check.True(PosteDetailCache.Bytes(projected) <= PosteDetailCache.MaxBytes, "enveloppe entière au plus 96 Kio");
        Check.True(projected.OmittedRows > 0 && projected.Rows + projected.OmittedRows == 500, "aucune ligne disparue sans compteur");
        Check.False(projected.Complete, "une projection bornée ne se dit pas complète");
        Check.True(projected.SecretsRemoved >= 2, "colonne sensible et message libre nettoyés");
        Check.False(JsonSerializer.Serialize(projected).Contains("DO_NOT_STORE", StringComparison.Ordinal), "aucun contenu sensible dans les octets persistables");
        Check.Equal(1, projected.Wmi!.Schema.Length, "colonnes et valeurs réindexées ensemble");
        Check.True(projected.Wmi.Instances.All(r => r.Length == 1), "aucun décalage de colonnes");
        PosteDetailCache.Validate(new(projected, null), "wmi", Fixtures.Now);
        var tooLong = PosteDetailCache.Project(Explorer(Fixtures.Now, new string('é', 8193)));
        Check.True(tooLong.OmittedCells > 0, "borne de 16 Kio UTF-8, pas seize mille caractères");
        Check.False(tooLong.Complete, "valeur entière écartée, pas de texte tronqué présenté comme complet");
    }

    [Test]
    public static async Task Native_projection_survives_reopen_failed_attempt_and_observation_retention()
    {
        using var folder = new TemporaryFolder(); var pc = Fixtures.Computer("PC1"); var clock = TestClock.Fixed();
        var db = new DomeniaDatabase(folder.File("detail.db"), Fixtures.Root, clock);
        await db.InitializeAsync(default);
        await db.SaveDirectoryAsync(Guid.NewGuid().ToString("D"), Fixtures.Snapshot(computers: [pc]), new(Fixtures.Postes, "Postes", true), "DC1", default);
        var first = PosteDetailCache.Project(Explorer(Fixtures.Now.AddMinutes(-1)));
        await db.SaveFleetAsync(Patch(pc.ObjectGuid, first), default);
        var failure = PosteDetailCache.Project(Explorer(Fixtures.Now) with
        { Complete = false, OriginalRows = 0, Wmi = first.Wmi! with { Instances = [], Status = "Refusé", NoInstancesConfirmed = false } });
        await db.SaveFleetAsync(Patch(pc.ObjectGuid, failure), default);
        var cold = await new DomeniaDatabase(db.Path, Fixtures.Root, clock).ReadFleetAsync(default);
        var memory = cold.WorkstationDetails[pc.ObjectGuid]["wmi"];
        Check.Equal(Fixtures.Now, memory.Latest.At, "dernière tentative séparée et datée");
        Check.Equal(first.At, memory.Display.At, "dernières données exploitables gardent leur vraie date");
        Check.Equal("valeur", memory.Display.Wmi!.Instances.Single().Single(), "valeur relue à froid");
        Check.Contains("Dernière tentative", memory.Notice, "échec ultérieur visible avec historique");
        await db.SaveFleetAsync(Patch(pc.ObjectGuid, PosteDetailCache.Project(Explorer(Fixtures.Now.AddHours(-1), "ancien"))), default);
        Check.Equal("valeur", (await db.ReadFleetAsync(default)).WorkstationDetails[pc.ObjectGuid]["wmi"].Display.Wmi!.Instances.Single().Single(), "écriture ancienne sans rajeunissement ni perte");
        var empty = StorageFleetRetention.Transform(cold, (_, family, _) => family == "detail");
        Check.True(empty.WorkstationDetails.IsEmpty, "aucun dictionnaire de GUID vide après conservation");
        var invalid = first with { Wmi = first.Wmi! with { Schema = [new("Password", "string", false, "")] } };
        await Check.ThrowsAsync<InvalidDataException>(() => db.SaveFleetAsync(Patch(pc.ObjectGuid, invalid), default), "frontière SQL refuse un contenu non nettoyé");
        Check.Equal(memory.Latest.At, (await new DomeniaDatabase(db.Path, Fixtures.Root, clock).ReadFleetAsync(default)).WorkstationDetails[pc.ObjectGuid]["wmi"].Latest.At, "refus sans remplacement partiel");
    }

    [Test]
    public static async Task Four_families_share_the_existing_row_without_duplicate_display_payloads_or_sensitive_software_commands()
    {
        using var folder = new TemporaryFolder(); var pc = Fixtures.Computer("PC1"); var clock = TestClock.Fixed();
        var db = new DomeniaDatabase(folder.File("families.db"), Fixtures.Root, clock); await db.InitializeAsync(default);
        await db.SaveDirectoryAsync(Guid.NewGuid().ToString("D"), Fixtures.Snapshot(computers: [pc]), new(Fixtures.Postes, "Postes", true), null, default);
        ImmutableArray<SoftwareRow> softwareRows = [new("app", "Application", "1", "Éditeur", null, null, "x64", "Machine", null, null,
            "installer /password=DO_NOT_STORE", "Uninstall64", null, null)];
        var software = new SoftwareResult("PC1", Fixtures.Now, "Relevé", "Registre", true, 1, softwareRows, [], "Lu", null,
            PosteSoftware.Columns(softwareRows), PosteSoftware.Board(softwareRows, DateOnly.FromDateTime(Fixtures.Now.UtcDateTime)), []);
        var values = new[]
        {
            new PosteDetailSnapshot("software", Fixtures.Now, "PC1", true, 1, 0, 0, 0) { Software = software },
            new PosteDetailSnapshot("services", Fixtures.Now, "PC1", true, 0, 0, 0, 0) { Services = new("PC1", Fixtures.Now, 0, 0, 0, false, 0, "Aucun", [], [], []) },
            new PosteDetailSnapshot("quick", Fixtures.Now, "PC1", true, 1, 0, 0, 0) { Quick = new("PC1", Fixtures.Now,
                [PosteText.Fact("Système", "Windows", FactState.Observed, "WMI", at: Fixtures.Now)], "Répondu", true, false, "1 s", "Lecture", "Aucun") },
            Explorer(Fixtures.Now),
        };
        foreach (var value in values) await db.SaveFleetAsync(Patch(pc.ObjectGuid, PosteDetailCache.Project(value)), default);
        var cold = await new DomeniaDatabase(db.Path, Fixtures.Root, clock).ReadFleetAsync(default);
        Check.Equal(4, cold.WorkstationDetails[pc.ObjectGuid].Count, "quatre familles typées relues à froid");
        Check.Equal("Windows", cold.WorkstationDetails[pc.ObjectGuid]["quick"].Display.Quick!.Facts.Single().Value, "faits diagnostiques conservés");
        var kept = cold.WorkstationDetails[pc.ObjectGuid]["software"];
        Check.Null(kept.Display.Software!.Rows.Single().Uninstall, "aucune commande stockée");
        Check.Equal(1, kept.Display.SecretsRemoved, "champ exclu comptabilisé");
        using var sql = new SqliteDatabase(db.Path, true);
        var payload = (string)sql.Scalar("SELECT payload FROM domenia_v2_fleet_rows WHERE row_key=?1;", pc.ObjectGuid.ToString("D"))!;
        Check.False(payload.Contains("DO_NOT_STORE", StringComparison.Ordinal), "preuve sur les octets réellement inscrits");
        using var json = JsonDocument.Parse(payload);
        var details = json.RootElement.GetProperty("details");
        Check.False(details.GetProperty("software").TryGetProperty("display", out _), "projection d’affichage calculée, jamais dupliquée sur disque");
        Check.Equal(1L, (long)sql.Scalar("SELECT count(*) FROM domenia_v2_fleet_rows WHERE kind='computer';")!, "aucune table ni ligne doublant l’inventaire");
    }

    [Test]
    public static async Task Real_services_reader_commits_before_return_and_cold_local_view_never_contacts_a_provider()
    {
        using var folder = new TemporaryFolder(); var pc = Fixtures.Computer("PC1"); var clock = TestClock.Fixed();
        var db = new DomeniaDatabase(folder.File("services.db"), Fixtures.Root, clock); await db.InitializeAsync(default);
        await db.SaveDirectoryAsync(Guid.NewGuid().ToString("D"), Fixtures.Snapshot(computers: [pc]), new(Fixtures.Postes, "Postes", true), "DC1", default);
        using (var ldap = new AdBoundaryTests.RecordingAdConnection { SearchAnswer = q => q.BaseDn == pc.DistinguishedName ? [AdPosteNetworkTests.Entry(pc)] : [] })
        using (var source = new AdDirectorySource("test.local", () => @"TEST\operator", clock, connection: ldap, localStore: new SqliteDirectoryCache(db))
            { SessionCredentialCopy = AdBoundaryTests.NativeSessionCredential, AdministrationOverride = AdBoundaryTests.NativeAdministrator })
        {
            var reader = new AdPosteReader(source) { InventoryReaderOverride = _ => new(clock)
            { SessionFactory = (host, budget, token) => new(host, budget, clock, cancellationToken: token)
            { ReadOverride = (_, query, _) => query.Contains("Win32_ComputerSystem", StringComparison.Ordinal) ? [Row(("Name", "PC1"), ("DNSHostName", "PC1"), ("Domain", "test.local"))]
                : query.Contains("Win32_Service", StringComparison.Ordinal) ? [Row(("Name", "Spooler"), ("DisplayName", "Impression"), ("State", "Running"), ("StartMode", "Auto"))] : [] } } };
            var result = await reader.ServicesAsync(pc.DistinguishedName, default);
            Check.Equal("Spooler", result.Rows.Single().Name, "véritable projection des instances CIM");
            var written = await new DomeniaDatabase(db.Path, Fixtures.Root, clock).ReadFleetAsync(default);
            Check.Equal("Spooler", written.WorkstationDetails[pc.ObjectGuid]["services"].Display.Services!.Rows.Single().Name, "écriture native avant retour");
            Check.True(written.Inventories.IsEmpty && written.WorkstationProbes.IsEmpty, "aucune copie d’inventaire ou de sondes");
        }
        using var coldLdap = new AdBoundaryTests.RecordingAdConnection { SearchAnswer = _ => throw new InvalidOperationException("Lecture locale sans LDAP") };
        using var coldSource = new AdDirectorySource("test.local", () => @"TEST\operator", clock, connection: coldLdap,
            localStore: new SqliteDirectoryCache(new DomeniaDatabase(db.Path, Fixtures.Root, clock)));
        var localReader = new AdPosteReader(coldSource) { InventoryReaderOverride = _ => throw new InvalidOperationException("Lecture locale sans WMI") };
        var view = await localReader.CachedDetailAsync(pc.DistinguishedName, "services", default) ?? throw new TestFailureException("détail absent après réouverture");
        Check.Equal("Spooler", view.Display.Services!.Rows.Single().Name, "historique consultable après redémarrage");
        Check.False(view.Display.Services.Rows.Single().CanRestart, "un cache ne permet pas une écriture sur un état ancien");
        Check.Equal(0, coldLdap.Calls, "consultation sans aucune requête réseau");
    }
}
