using System.Collections.Immutable;
using System.Security.Principal;
using System.Text.Json.Nodes;
using Domenia.Ad;
using Domenia.Core;
using Domenia.Store;

namespace Domenia.Tests;

internal static class DirectoryObservedFieldTests
{
    private static readonly ScopeSelection Scope = new(Fixtures.Root, "Domaine de la base de test", true);

    [Test]
    public static async Task Native_computer_facts_are_complete_and_visible_after_cold_read_without_the_full_projection()
    {
        using var folder = new TemporaryFolder(); var clock = TestClock.Fixed();
        var database = new DomeniaDatabase(folder.File("facts.db"), Fixtures.Root, clock); await database.InitializeAsync(default);
        var computer = Fixtures.Computer("PC1") with { OperatingSystemVersion = "10.0 (26100)", WhenCreated = Fixtures.Now.AddYears(-1),
            PasswordLastSet = AdValues.ToFileTime(Fixtures.Now.AddDays(-6)), Laps = LapsKind.Windows, LapsExpiration = AdValues.ToFileTime(Fixtures.Now.AddDays(4)) };
        var captured = Fixtures.Snapshot(computers: [computer]);
        await database.SaveDirectoryAsync(Guid.NewGuid().ToString("D"), captured, Scope, "DC1", default);
        using (var read = new SqliteDatabase(database.Path, true))
        {
            var row = read.Query("SELECT os_version,when_created,pwd_last_set,laps_kind,laps_expiry,read_at FROM ad_computer_facts WHERE object_guid=?1;", computer.ObjectGuid.ToString("D")).Single();
            Check.Equal(computer.OperatingSystemVersion, row["os_version"] as string, "version du système réellement dans la table");
            Check.Equal(computer.WhenCreated, DateTimeOffset.Parse((string)row["when_created"]!), "création UTC");
            Check.Equal(AdValues.FromFileTime(computer.PasswordLastSet), DateTimeOffset.Parse((string)row["pwd_last_set"]!), "dernier changement de mot de passe machine, sans valeur de mot de passe");
            Check.Equal("windows", row["laps_kind"] as string, "type fermé");
            Check.Equal(AdValues.FromFileTime(computer.LapsExpiration), DateTimeOffset.Parse((string)row["laps_expiry"]!), "expiration LAPS");
            Check.Equal(captured.ReadAt, DateTimeOffset.Parse((string)row["read_at"]!), "date du relevé réellement enregistré, pas celle de l’écriture");
        }
        using (var edit = new SqliteDatabase(database.Path, false)) edit.Script("DROP TABLE domenia_v2_objects;");
        var request = ShellAutomation.Validate("postes", Fixtures.Postes, [], [], 100, "Json").Request!;
        var answer = await DomeniaDatabase.ReadAutomationAsync(database.Path, request, null, clock, default);
        Check.Equal(computer.OperatingSystemVersion, answer.Items.Single()!["Systeme"]!.GetValue<string>(), "table utilisable même sans payload typé");
        Check.Equal(AdValues.FromFileTime(computer.PasswordLastSet), DateTimeOffset.Parse(answer.Items.Single()!["MotDePasseMachineDefini"]!.GetValue<string>()), "colonne promise non vide");
    }

    [Test]
    public static async Task Partial_user_read_keeps_unread_fields_composite_and_their_original_dates_then_explicit_empty_clears_them()
    {
        using var folder = new TemporaryFolder(); var clock = TestClock.Fixed();
        var database = new DomeniaDatabase(folder.File("fields.db"), Fixtures.Root, clock); await database.InitializeAsync(default);
        var user = Fixtures.User("Alice") with { Department = "Comptabilité", Title = "Comptable", Description = "À conserver",
            LastLogonTimestamp = AdValues.ToFileTime(Fixtures.Now.AddDays(-1)), MemberOf = ["CN=Equipe," + Fixtures.Root] };
        await Save(user, "DC1");
        var first = Raw(); clock.Advance(TimeSpan.FromMinutes(1));
        var partial = AdDirectoryMapper.User(Entry(user, new() { ["department"] = ["Finance"] }))!;
        Check.False(partial.ObservedAttributes!.Value.Contains("title"), "attribut non demandé distinct d’une valeur vide");
        await Save(partial, "DC2");
        var restored = (await new DomeniaDatabase(database.Path, Fixtures.Root, clock).ReadDirectoryAsync(default, true))!.Users.Single();
        Check.Equal("Finance", restored.Department, "champ réellement lu mis à jour");
        Check.Equal("Comptable", restored.Title, "autre moitié conservée dans le modèle typé");
        Check.Equal(user.Description, restored.Description, "description non lue conservée");
        Check.True(restored.MemberOf.SequenceEqual(user.MemberOf), "appartenances non demandées conservées");
        Check.Equal(user.LastLogonTimestamp, restored.LastLogonTimestamp, "date non lue conservée");
        var second = Raw();
        Check.Equal("Comptabilité / Comptable", second.Record["Extra"]!.GetValue<string>(), "résumé pas recomposé avec une moitié non lue");
        foreach (var field in new[] { "Description", "Extra", "LastLogon" })
        {
            Check.Equal(first.Times[field]!.GetValue<string>(), second.Times[field]!.GetValue<string>(), "date du champ non lue conservée : " + field);
            Check.Equal("DC1", second.Record["FieldSources"]![field]!.GetValue<string>(), "origine originale conservée : " + field);
        }
        clock.Advance(TimeSpan.FromMinutes(1));
        var empty = AdDirectoryMapper.User(Entry(user, [], ["objectGUID", "objectSid", "description", "department", "title"]))!;
        await Save(empty, "DC3"); var last = Raw();
        Check.Null(last.Record["Description"], "vide réellement demandé efface l’ancien champ");
        Check.Equal("", last.Record["Extra"]!.GetValue<string>(), "deux moitiés relues vides : résumé vidé");
        Check.Equal("DC3", last.Record["FieldSources"]!["Description"]!.GetValue<string>(), "nouvelle provenance");
        Check.Equal(clock.GetUtcNow(), DateTimeOffset.Parse(last.Times["Extra"]!.GetValue<string>()), "date de la relecture réelle");

        async Task Save(DirectoryUser value, string controller) => await database.SaveDirectoryAsync(Guid.NewGuid().ToString("D"),
            Fixtures.Snapshot(users: [value], readAt: clock.GetUtcNow()), Scope, controller, default);
        (JsonObject Record, JsonObject Times) Raw()
        {
            using var read = new SqliteDatabase(database.Path, true);
            var row = read.Query("SELECT payload,field_times FROM domenia_directory_data WHERE object_guid=?1;", user.ObjectGuid.ToString("D")).Single();
            return (JsonNode.Parse((string)row["payload"]!)!.AsObject(), JsonNode.Parse((string)row["field_times"]!)!.AsObject());
        }
    }

    [Test]
    public static async Task Partial_computer_read_keeps_independent_facts_and_one_LAPS_attribute_cannot_replace_the_pair()
    {
        using var folder = new TemporaryFolder(); var clock = TestClock.Fixed(); var database = new DomeniaDatabase(folder.File("partial.db"), Fixtures.Root, clock);
        await database.InitializeAsync(default);
        var computer = Fixtures.Computer("PC1") with { OperatingSystem = "Windows 11", OperatingSystemVersion = "26100", Location = "Atelier",
            PasswordLastSet = AdValues.ToFileTime(Fixtures.Now.AddDays(-5)), Laps = LapsKind.Legacy, LapsExpiration = AdValues.ToFileTime(Fixtures.Now.AddDays(2)) };
        await Save(computer, clock.GetUtcNow()); clock.Advance(TimeSpan.FromMinutes(1));
        var raw = new Dictionary<string, IReadOnlyList<object>> { ["objectGUID"] = [computer.ObjectGuid.ToByteArray()], ["objectSid"] = [Sid(computer.Sid)],
            ["operatingSystem"] = ["Windows suivant"], ["msLAPS-PasswordExpirationTime"] = [AdValues.ToFileTime(Fixtures.Now.AddDays(9)).ToString()] };
        await Save(AdDirectoryMapper.Computer(new(computer.DistinguishedName, raw))!, clock.GetUtcNow());
        var restored = (await database.ReadDirectoryAsync(default, true))!.Computers.Single();
        Check.Equal("Windows suivant", restored.OperatingSystem, "seul champ observé mis à jour");
        Check.Equal(computer.OperatingSystemVersion, restored.OperatingSystemVersion, "version non lue conservée");
        Check.Equal(computer.Laps, restored.Laps, "type LAPS non réattribué à une lecture incomplète du couple");
        Check.Equal(computer.LapsExpiration, restored.LapsExpiration, "expiration du même type conservée");
        using var read = new SqliteDatabase(database.Path, true);
        Check.Equal("Windows 11 / Atelier", read.Scalar("SELECT extra FROM ad_objects WHERE object_guid=?1;", computer.ObjectGuid.ToString("D")) as string, "résumé composé inchangé");
        var facts = read.Query("SELECT os_version,pwd_last_set,laps_kind,read_at FROM ad_computer_facts;").Single();
        Check.Equal("26100", facts["os_version"] as string, "fait système non perdu");
        Check.Equal("legacy", facts["laps_kind"] as string, "fait LAPS non remplacé");
        Check.Equal(Fixtures.Now, DateTimeOffset.Parse((string)facts["read_at"]!), "aucun fait relu : date inchangée");
        async Task Save(DirectoryComputer value, DateTimeOffset at) => await database.SaveDirectoryAsync(Guid.NewGuid().ToString("D"), Fixtures.Snapshot(computers: [value], readAt: at), Scope, "DC1", default);
    }

    [Test]
    public static async Task Missing_or_invalid_requested_account_status_never_manufactures_an_enabled_object()
    {
        var pc = Fixtures.Computer("PC1"); var user = Fixtures.User("Alice");
        foreach (var value in new string?[] { null, "not-a-number" })
        {
            var values = new Dictionary<string, IReadOnlyList<object>> { ["objectGUID"] = [pc.ObjectGuid.ToByteArray()], ["objectSid"] = [Sid(pc.Sid)] };
            if (value is not null) values["userAccountControl"] = [value];
            var unreadable = new AdEntry(pc.DistinguishedName, values, ["objectGUID", "objectSid", "userAccountControl"]);
            Check.Null(AdDirectoryMapper.Computer(unreadable), "état machine obligatoire demandé mais non qualifié");
            Check.Null(AdDirectoryMapper.User(Entry(user, value is null ? [] : new() { ["userAccountControl"] = [value] },
                ["objectGUID", "objectSid", "userAccountControl"])), "état utilisateur obligatoire demandé mais non qualifié");
            using var ldap = new AdBoundaryTests.RecordingAdConnection { SearchAnswer = request => request.Filter == AdDirectoryMapper.ComputerFilter ? [unreadable] : [] };
            var snapshot = await AdDirectoryReader.ReadSnapshotAsync(ldap, Fixtures.Domain, new(Fixtures.Postes, "Postes", true), 1000, TestClock.Fixed(), default);
            Check.False(snapshot.Complete, "objet non qualifié rend le recensement incomplet");
            Check.Equal(0, snapshot.Computers.Length, "aucun poste Actif fabriqué par zéro par défaut");
        }
    }

    private static AdEntry Entry(DirectoryUser user, Dictionary<string, IReadOnlyList<object>> values, IReadOnlyList<string>? requested = null)
    {
        values["objectGUID"] = [user.ObjectGuid.ToByteArray()]; values["objectSid"] = [Sid(user.Sid)];
        return new(user.DistinguishedName, values, requested);
    }
    private static byte[] Sid(string value)
    { var sid = new SecurityIdentifier(value); var bytes = new byte[sid.BinaryLength]; sid.GetBinaryForm(bytes, 0); return bytes; }
}
