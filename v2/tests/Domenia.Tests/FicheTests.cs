using System.Collections.Immutable;
using System.Text.Json;
using Domenia.Bridge;
using Domenia.Core;
using Domenia.Simulation;

namespace Domenia.Tests;

/// <summary>
/// The « Fiche » screen: pure rules (rights, membership paths, group delta, logon hours, masking, generated password, raw write
/// rule) and the operations of the module over the simulation, with the writes run end to end on the overlay.
/// </summary>
internal static class FicheTests
{
    private const string Root = "DC=example,DC=local";

    private static string Args(object value) => JsonSerializer.Serialize(value);

    private static DirectoryUser Camille(SimulatedBridge bridge) =>
        bridge.Source.CurrentDirectory.Users.Single(u => u.DisplayName == "Camille Bernard");

    private static DirectoryGroup Group(SimulatedBridge bridge, string name) =>
        bridge.Source.CurrentDirectory.Groups.Single(g => g.Name == name);

    private static string ParentOf(string dn) => dn[(dn.IndexOf(',', StringComparison.Ordinal) + 1)..];

    private static async Task<JsonElement> ResultAsync(SimulatedBridge bridge, string operation, object args) =>
        SimulatedBridge.Json(await bridge.CallAsync(operation, Args(args)));

    private static async Task<string?> ErrorAsync(SimulatedBridge bridge, string operation, object args)
    {
        var response = await bridge.CallAsync(operation, Args(args));
        return response.Kind == "result" ? null : response.Error?.Code;
    }

    /// <summary>Plans, confirms (with the typed name when the plan asks for it) and runs one write; returns the receipt.</summary>
    private static async Task<JsonElement> WriteAsync(SimulatedBridge bridge, string plan, object args)
    {
        var planned = await ResultAsync(bridge, plan, args);
        var confirmation = planned.GetProperty("plan").GetProperty("confirmation");
        var typedName = confirmation.GetProperty("typedNameRequired").GetBoolean() ? confirmation.GetProperty("typedName").GetString() : null;
        return await ResultAsync(bridge, "write.execute", new
        {
            planId = planned.GetProperty("plan").GetProperty("id").GetString(),
            token = planned.GetProperty("token").GetString(),
            typedName,
        });
    }

    private static string[] Strings(JsonElement array, string property) =>
        [.. array.EnumerateArray().Select(e => e.GetProperty(property).GetString() ?? "")];

    // ---------------------------------------------------------------- pure rules

    [Test]
    public static void Rights_read_the_specific_bits_and_a_deny_wins()
    {
        static FicheRights Estimate(params FicheAce[] aces) =>
            FicheDiagnostics.Rights(new FicheSecurityReading(true, null, "Admins du domaine", 4, [.. aces], Fixtures.Now), TestClock.Paris);
        static string State(FicheRights rights, string id) => rights.Rows.Single(r => r.Id == id).State;

        // GenericRead carries ReadControl (0x20000), like GenericWrite: it must never read as a write right (bug of Domenia 1).
        var readOnly = Estimate(new FicheAce(false, "Utilisateurs authentifiés", 0x20094, false, null));
        Check.Equal("allowed", State(readOnly, "read"), "lecture autorisée");
        Check.Equal("unknown", State(readOnly, "edit"), "GenericRead n’autorise pas la modification");
        Check.Equal("unknown", State(readOnly, "group"), "ni les groupes");
        Check.Equal("unknown", State(readOnly, "move"), "ni le déplacement");

        var support = Estimate(new FicheAce(false, "GG-Support-N2", 0x20 | 0x100, true, "OU=Utilisateurs"), new FicheAce(true, "GG-Support-N2", 0x10000, false, null));
        Check.Equal("allowed", State(support, "edit"), "WriteProperty autorise la modification");
        Check.Equal("allowed", State(support, "password"), "droit étendu de réinitialisation");
        Check.Equal("denied", State(support, "delete"), "le refus explicite l’emporte");
        Check.Equal("denied", State(support, "move"), "déplacer exige Delete, refusé ici");
        Check.Contains("Refuser · GG-Support-N2", support.Rows.Single(r => r.Id == "delete").Ace, "l’entrée décisive est nommée");
        Check.Contains("hérité de OU=Utilisateurs", support.Rows.Single(r => r.Id == "edit").Ace, "héritage indiqué");

        var full = Estimate(new FicheAce(false, "GG-Admins-Postes", 0xF01FF, false, null));
        Check.True(full.Rows.All(r => r.State == "allowed"), "contrôle total : tout est autorisé");

        var unavailable = FicheDiagnostics.Rights(new FicheSecurityReading(false, "Accès refusé.", "", 0, [], Fixtures.Now), TestClock.Paris);
        Check.False(unavailable.Available, "ACL illisible");
        Check.True(unavailable.Rows.All(r => r.State == "unknown"), "tout reste indéterminé, rien n’est verrouillé");
    }

    [Test]
    public static void Membership_paths_are_bounded_and_survive_cycles()
    {
        var edges = new Dictionary<string, ImmutableArray<string>>(StringComparer.OrdinalIgnoreCase)
        {
            ["U"] = ["G1"],
            ["G1"] = ["G2"],
            ["G2"] = ["G1", "G3"],
        };
        var path = FicheMemberships.FindPath(edges, "U", "g3");
        Check.True(path.Found, "chemin trouvé, casse ignorée");
        Check.True(path.Path.SequenceEqual(["U", "G1", "G2", "G3"]), "chemin complet : " + string.Join(" > ", path.Path));
        Check.False(path.Direct, "appartenance indirecte");
        Check.True(path.CycleSeen, "le cycle G1 ↔ G2 est vu sans boucler");
        Check.True(FicheMemberships.FindPath(edges, "U", "G1").Direct, "appartenance directe");
        Check.False(FicheMemberships.FindPath(edges, "U", "G9").Found, "groupe inatteignable");
        var limited = FicheMemberships.FindPath(edges, "U", "G3", maxDepth: 2);
        Check.False(limited.Found, "au-delà de la profondeur bornée");
        Check.True(limited.Truncated, "la limite est dite");
    }

    [Test]
    public static void A_group_delta_never_writes_the_full_list()
    {
        const string Member = "CN=Camille,OU=People," + Root;
        string[] current = ["CN=A,OU=Groupes," + Root, "CN=B,OU=Groupes," + Root];
        string[] add = ["CN=A,OU=Groupes," + Root, "CN=C,OU=Groupes," + Root, "CN=D,OU=Groupes," + Root];
        string[] remove = ["CN=B,OU=Groupes," + Root, "CN=D,OU=Groupes," + Root, "CN=E,OU=Groupes," + Root];
        var delta = FicheMemberships.Delta(current, add, remove, Member);
        Check.False(delta.WritesFullList, "jamais la liste complète");
        Check.True(delta.Steps.Select(s => s.Action + " " + s.GroupName).SequenceEqual(["add A", "add C", "remove B", "remove E"]), "étapes : " + string.Join(", ", delta.Steps.Select(s => s.Label)));
        Check.True(delta.Notes.Any(n => n.StartsWith("D", StringComparison.Ordinal) && n.Contains("ignorée", StringComparison.Ordinal)), "ajout et retrait à la fois : ignoré");
        Check.True(delta.Notes.Any(n => n.StartsWith("A", StringComparison.Ordinal) && n.Contains("déjà membre", StringComparison.Ordinal)), "déjà membre : revérifié");
        Check.True(delta.Notes.Any(n => n.StartsWith("E", StringComparison.Ordinal) && n.Contains("non membre", StringComparison.Ordinal)), "non membre : revérifié");
        Check.True(delta.Steps.All(s => s.MemberDn == Member), "un plan par groupe pour ce membre");
    }

    [Test]
    public static void Logon_hours_are_read_in_local_time()
    {
        var all = FicheCallSheets.LogonHours(new string('F', 42), true, 120, Fixtures.Now);
        Check.True(all.Unrestricted, "toutes les heures");
        Check.Equal(true, all.AllowedNow, "autorisé maintenant");
        Check.Equal("UTC+02:00", all.Offset, "décalage affiché");
        var never = FicheCallSheets.LogonHours(new string('0', 42), true, 120, Fixtures.Now);
        Check.True(never.Never, "aucune heure");
        Check.Equal(false, never.AllowedNow, "refusé maintenant");
        Check.Equal("error", FicheCallSheets.LogonHours("FF-FF", true, 120, Fixtures.Now).State, "valeur tronquée : illisible");
        Check.Equal("notRead", FicheCallSheets.LogonHours(null, false, 120, Fixtures.Now).State, "absente d’une lecture partielle : non lue");
        Check.True(FicheCallSheets.LogonHours(null, true, 120, Fixtures.Now).Unrestricted, "absente d’une lecture complète : aucune restriction");
        Check.NotNull(FicheCallSheets.ParseLogonHours(string.Join('-', Enumerable.Repeat("FF", 21))), "forme FF-FF-…");
    }

    [Test]
    public static void Secrets_are_masked_in_copied_texts()
    {
        Check.Equal("password=***", SecretMask.Protect("password=Hiver2026!"), "clé = valeur");
        Check.Contains("\"token\":\"***\"", SecretMask.Protect("{\"token\":\"abc.def\"}"), "membre JSON");
        Check.Equal("net use -p ***", SecretMask.Protect("net use -p Secret1"), "commutateur de ligne de commande");
        Check.Equal("Authorization: Bearer ***", SecretMask.Protect("Authorization: Bearer eyJhbGciOi"), "en-tête d’autorisation");
        Check.Equal("Expire le 12/11/2026", SecretMask.Protect("Expire le 12/11/2026"), "texte ordinaire inchangé");
        Check.Equal("", SecretMask.Protect(null), "rien à masquer");
    }

    [Test]
    public static void Generated_passwords_follow_the_rules_without_being_exposed()
    {
        for (var i = 0; i < 20; i++)
        {
            using var password = TemporaryPassword.Generate(16);
            Check.True(password.IsReadOnly(), "mot de passe figé");
            Check.True(TemporaryPassword.Complies(password, 16), "16 caractères, quatre classes, aucun caractère ambigu");
        }
        using var floor = TemporaryPassword.Generate(4);
        Check.Equal(14, floor.Length, "jamais moins de 14 caractères");
    }

    [Test]
    public static void The_raw_write_rule_refuses_sensitive_and_operational_attributes()
    {
        var simulation = FicheSecurityPolicy.Simulation;
        Check.True(FicheAttributeRules.RawWriteAllowed("description", simulation).Allowed, "attribut ordinaire admis en simulation");
        Check.False(FicheAttributeRules.RawWriteAllowed("description", FicheSecurityPolicy.Default).Allowed, "écriture brute désactivée par défaut (Domenia 1)");
        Check.False(FicheAttributeRules.RawWriteAllowed("unicodePwd", simulation).Allowed, "mot de passe refusé");
        Check.False(FicheAttributeRules.RawWriteAllowed("ms-Mcs-AdmPwd", simulation).Allowed, "mot de passe LAPS refusé");
        Check.False(FicheAttributeRules.RawWriteAllowed("objectGUID", simulation).Allowed, "attribut tenu par l’annuaire refusé");
        Check.False(FicheAttributeRules.RawWriteAllowed("bad name;", simulation).Allowed, "nom invalide refusé");
        Check.True(FicheAttributeRules.IsSensitive("unicodePwd"), "unicodePwd sensible");
    }

    [Test]
    public static void Readable_paths_and_dn_comparison()
    {
        Check.Equal("example.local › Utilisateurs › Lyon", FicheValues.ReadablePath("CN=Camille,OU=Lyon,OU=Utilisateurs," + Root), "chemin lisible sans l’objet");
        Check.Equal("example.local › Utilisateurs › Lyon › Camille", FicheValues.ReadablePath("CN=Camille,OU=Lyon,OU=Utilisateurs," + Root, includeSelf: true), "avec l’objet");
        Check.True(FicheValues.SameDn("cn=camille,ou=lyon," + Root.ToLowerInvariant(), "CN=Camille,OU=Lyon," + Root), "casse ignorée");
        Check.False(FicheValues.SameDn("CN=Camille", null), "absent : jamais égal");
    }

    // ---------------------------------------------------------------- reads over the simulation

    [Test]
    public static async Task A_fiche_is_resolved_and_read_with_its_whole_contract()
    {
        var bridge = new SimulatedBridge();
        var camille = Camille(bridge);
        var found = await ResultAsync(bridge, "fiche.resolve", new { text = camille.SamAccountName });
        Check.Equal(camille.DistinguishedName, found.GetProperty("dn").GetString(), "identifiant résolu dans la base locale");
        Check.Equal(FicheErrors.NotFound, await ErrorAsync(bridge, "fiche.resolve", new { text = "personne-inconnue" }), "rien d’exact : recherche globale proposée");

        var sheet = await ResultAsync(bridge, "fiche.read", new { dn = camille.DistinguishedName });
        string[] fields = [.. sheet.EnumerateObject().Select(p => p.Name)];
        Check.True(fields.SequenceEqual(["identity", "origin", "states", "band", "sections", "edit", "account", "counts", "freshness", "manager", "linked", "presence",
            "actions", "tabs", "landing", "summary", "support", "signature", "settings"]), "champs de la fiche : " + string.Join(", ", fields));
        var identity = sheet.GetProperty("identity");
        Check.Equal("user", identity.GetProperty("kind").GetString(), "type");
        Check.Equal(camille.ObjectGuid.ToString("D"), identity.GetProperty("guid").GetString(), "GUID");
        Check.Equal("example.local › Utilisateurs › Lyon › Commercial", identity.GetProperty("path").GetString(), "chemin lisible");
        Check.True(Strings(sheet.GetProperty("tabs"), "id").SequenceEqual(["general", "compte", "groupes", "relations", "droits", "attributs", "historique", "appel"]), "onglets d’un utilisateur");
        Check.True(Strings(sheet.GetProperty("states"), "id").Contains("locked"), "Camille est verrouillée dans le monde simulé");
        Check.True(sheet.GetProperty("band").GetProperty("unlock").GetBoolean(), "bandeau : déverrouiller");

        var preview = await ResultAsync(bridge, "fiche.preview", new { dn = camille.DistinguishedName });
        Check.True(preview.GetProperty("origin").GetProperty("preview").GetBoolean(), "aperçu de la base locale marqué");

        var attributes = await ResultAsync(bridge, "fiche.attributes", new { dn = camille.DistinguishedName });
        string[] names = Strings(attributes.GetProperty("rows"), "name");
        Check.True(names.Contains("sAMAccountName") && names.Contains("userAccountControl"), "attributs bruts lus");
        Check.False(names.Any(FicheAttributeRules.IsSensitive), "aucun attribut sensible affiché");
        Check.True(attributes.GetProperty("rawWrite").GetProperty("allowed").GetBoolean(), "écriture brute ouverte en simulation");

        Check.Equal(FicheErrors.Unknown, await ErrorAsync(bridge, "fiche.read", new { dn = "CN=Absent,OU=Nulle part," + Root }), "objet absent");
        Check.Equal(DomeniaErrors.ArgumentsInvalid, await ErrorAsync(bridge, "fiche.read", new { dn = "pas un DN" }), "DN mal formé");
    }

    [Test]
    public static async Task Groups_members_and_contacts_are_typed_from_the_local_base()
    {
        var bridge = new SimulatedBridge();
        var camille = Camille(bridge);
        var groups = await ResultAsync(bridge, "fiche.groups", new { dn = camille.DistinguishedName });
        Check.Equal(camille.MemberOf.Length, groups.GetProperty("total").GetInt32(), "groupes directs = memberOf");
        Check.Equal(513, groups.GetProperty("primary").GetProperty("rid").GetInt32(), "groupe principal hors memberOf");
        var nested = await ResultAsync(bridge, "fiche.groups.nested", new { dn = camille.DistinguishedName });
        foreach (var row in nested.GetProperty("rows").EnumerateArray())
        {
            Check.True(row.GetProperty("depth").GetInt32() >= 2, "imbriqué : niveau 2 ou plus");
            Check.False(string.IsNullOrEmpty(row.GetProperty("via").GetString()), "groupe direct « via » indiqué");
        }

        var support = Group(bridge, "GG-Support-N2");
        var members = await ResultAsync(bridge, "fiche.members", new { dn = support.DistinguishedName });
        Check.Equal("members", members.GetProperty("mode").GetString(), "membres d’un groupe");
        Check.Equal(support.Members.Length, members.GetProperty("total").GetInt32(), "membres directs");

        var distribution = bridge.Source.CurrentDirectory.OrganizationalUnits.Single(o => o.Name == "Distribution").DistinguishedName;
        var content = await ResultAsync(bridge, "fiche.members", new { dn = distribution });
        Check.Equal("children", content.GetProperty("mode").GetString(), "contenu d’une OU");
        var contacts = content.GetProperty("counts").EnumerateArray().Single(c => c.GetProperty("type").GetString() == "contact");
        Check.Equal(18, contacts.GetProperty("count").GetInt32(), "contacts de la simulation");
        var contactDn = content.GetProperty("rows").EnumerateArray().First(r => r.GetProperty("type").GetString() == "contact").GetProperty("dn").GetString();
        var contact = await ResultAsync(bridge, "fiche.read", new { dn = contactDn });
        Check.Equal("contact", contact.GetProperty("identity").GetProperty("kind").GetString(), "fiche d’un contact");
        Check.Equal(JsonValueKind.Null, contact.GetProperty("account").ValueKind, "un contact n’a pas de compte");

        Check.Equal(FicheErrors.NotApplicable, await ErrorAsync(bridge, "fiche.members", new { dn = camille.DistinguishedName }), "un utilisateur n’a pas de membres");
        Check.Equal(FicheErrors.NotApplicable, await ErrorAsync(bridge, "fiche.compare", new { dn = support.DistinguishedName, other = camille.SamAccountName }), "comparaison : deux utilisateurs");
    }

    [Test]
    public static async Task Why_member_names_the_chain()
    {
        var bridge = new SimulatedBridge();
        var camille = Camille(bridge);
        var nested = await ResultAsync(bridge, "fiche.groups.nested", new { dn = camille.DistinguishedName });
        var row = nested.GetProperty("rows").EnumerateArray().FirstOrDefault();
        if (row.ValueKind != JsonValueKind.Object)
        {
            return;
        }
        var why = await ResultAsync(bridge, "fiche.groups.why", new { dn = camille.DistinguishedName, group = row.GetProperty("dn").GetString() });
        Check.Equal(true, why.GetProperty("member").GetBoolean(), "membre par imbrication");
        Check.True(why.GetProperty("path").GetArrayLength() >= 3, "chemin objet → groupe direct → groupe");
    }

    [Test]
    public static async Task The_call_sheet_needs_no_network_and_masks_the_ticket()
    {
        var bridge = new SimulatedBridge();
        var camille = Camille(bridge);
        var sheet = await ResultAsync(bridge, "fiche.callSheet", new { dn = camille.DistinguishedName });
        Check.Equal(camille.SamAccountName, sheet.GetProperty("subject").GetProperty("login").GetString(), "identifiant");
        Check.False(sheet.GetProperty("reads").GetProperty("lockouts").GetBoolean(), "aucune lecture réseau implicite");
        Check.Contains(camille.SamAccountName, sheet.GetProperty("ticket").GetString(), "ticket prêt à coller");
        var read = await ResultAsync(bridge, "fiche.callSheet.read", new { dn = camille.DistinguishedName, read = "lockouts" });
        Check.True(read.GetProperty("reads").GetProperty("lockouts").GetBoolean(), "lecture 4740 faite sur geste");
        Check.Equal(DomeniaErrors.ArgumentsInvalid, await ErrorAsync(bridge, "fiche.callSheet.read", new { dn = camille.DistinguishedName, read = "tout" }), "lecture inconnue refusée");
    }

    [Test]
    public static async Task Recent_fiches_are_kept_locally_and_bounded()
    {
        var bridge = new SimulatedBridge();
        foreach (var user in bridge.Source.CurrentDirectory.Users.Take(14))
        {
            await ResultAsync(bridge, "fiche.recent.add", new { dn = user.DistinguishedName });
        }
        var recent = await ResultAsync(bridge, "fiche.recent", new { });
        Check.Equal(12, recent.GetArrayLength(), "douze fiches au plus");
        Check.Equal(bridge.Source.CurrentDirectory.Users[13].DistinguishedName, recent[0].GetProperty("dn").GetString(), "la plus récente d’abord");
        Check.Equal(0, (await ResultAsync(bridge, "fiche.recent.clear", new { })).GetArrayLength(), "liste effacée");
    }

    // ---------------------------------------------------------------- writes, end to end on the overlay

    [Test]
    public static async Task Plans_write_nothing_and_an_update_is_read_back()
    {
        var bridge = new SimulatedBridge();
        var camille = Camille(bridge);
        var planned = await ResultAsync(bridge, "fiche.update.plan", new { dn = camille.DistinguishedName, fields = new Dictionary<string, string?> { ["description"] = "Référente CRM" } });
        Check.Equal(0L, bridge.Source.Overlay.Version, "le plan n’écrit rien");
        var change = planned.GetProperty("plan").GetProperty("changes").EnumerateArray().Single();
        Check.Equal("description", change.GetProperty("attribute").GetString(), "seul le champ modifié part");

        var receipt = await WriteAsync(bridge, "fiche.update.plan", new { dn = camille.DistinguishedName, fields = new Dictionary<string, string?> { ["description"] = "Référente CRM" } });
        Check.Equal("applied", receipt.GetProperty("result").GetString(), "écriture appliquée");
        Check.Equal("verified", receipt.GetProperty("verification").GetString(), "relue conforme");
        Check.Equal("Référente CRM", Camille(bridge).Description, "la surcouche porte la valeur");
        var attributes = await ResultAsync(bridge, "fiche.attributes", new { dn = camille.DistinguishedName });
        var description = attributes.GetProperty("rows").EnumerateArray().Single(r => r.GetProperty("name").GetString() == "description");
        Check.Equal("Référente CRM", description.GetProperty("display").GetString(), "relue par la fiche");
        var history = await ResultAsync(bridge, "fiche.history", new { dn = camille.DistinguishedName });
        Check.Equal(1, history.GetProperty("receipts").GetInt32(), "le reçu apparaît dans l’historique de l’objet");

        Check.Equal(WriteErrors.NothingToDo, await ErrorAsync(bridge, "fiche.update.plan", new { dn = camille.DistinguishedName, fields = new Dictionary<string, string?> { ["description"] = "Référente CRM" } }),
            "valeur déjà en place : rien à écrire");
    }

    [Test]
    public static async Task Membership_is_written_on_both_sides()
    {
        var bridge = new SimulatedBridge();
        var camille = Camille(bridge);
        var support = Group(bridge, "GG-Support-N2");
        Check.False(camille.MemberOf.Contains(support.DistinguishedName, StringComparer.OrdinalIgnoreCase), "départ : non membre");
        var receipt = await WriteAsync(bridge, "fiche.membership.plan", new { group = support.DistinguishedName, member = camille.DistinguishedName, add = true });
        Check.Equal("verified", receipt.GetProperty("verification").GetString(), "ajout relu");
        Check.True(Camille(bridge).MemberOf.Contains(support.DistinguishedName, StringComparer.OrdinalIgnoreCase), "memberOf du compte");
        Check.True(Group(bridge, "GG-Support-N2").Members.Contains(camille.DistinguishedName, StringComparer.OrdinalIgnoreCase), "member du groupe");
        var groups = await ResultAsync(bridge, "fiche.groups", new { dn = camille.DistinguishedName });
        Check.True(Strings(groups.GetProperty("rows"), "dn").Contains(support.DistinguishedName), "la fiche voit le nouveau groupe");

        await WriteAsync(bridge, "fiche.membership.plan", new { group = support.DistinguishedName, member = camille.DistinguishedName, add = false });
        Check.False(Camille(bridge).MemberOf.Contains(support.DistinguishedName, StringComparer.OrdinalIgnoreCase), "retrait relu");
    }

    [Test]
    public static async Task Account_switches_expiry_and_options_are_read_back()
    {
        var bridge = new SimulatedBridge();
        var camille = Camille(bridge);
        await WriteAsync(bridge, "fiche.enable.plan", new { dn = camille.DistinguishedName, enabled = false });
        Check.True(AdValues.IsDisabled(Camille(bridge).UserAccountControl), "compte désactivé");
        await WriteAsync(bridge, "fiche.enable.plan", new { dn = camille.DistinguishedName, enabled = true });
        Check.False(AdValues.IsDisabled(Camille(bridge).UserAccountControl), "compte réactivé");

        await WriteAsync(bridge, "fiche.expiration.plan", new { dn = camille.DistinguishedName, date = "2027-03-31" });
        var sheet = await ResultAsync(bridge, "fiche.read", new { dn = camille.DistinguishedName });
        Check.Equal("2027-03-31", sheet.GetProperty("account").GetProperty("accountExpires").GetString(), "jour local relu");
        await WriteAsync(bridge, "fiche.expiration.plan", new { dn = camille.DistinguishedName, date = (string?)null });
        sheet = await ResultAsync(bridge, "fiche.read", new { dn = camille.DistinguishedName });
        Check.True(sheet.GetProperty("account").GetProperty("accountNeverExpires").GetBoolean(), "n’expire plus");
        Check.Equal(DomeniaErrors.ArgumentsInvalid, await ErrorAsync(bridge, "fiche.expiration.plan", new { dn = camille.DistinguishedName, date = "31/03/2027" }), "date ISO exigée par le pont");

        await WriteAsync(bridge, "fiche.options.plan", new { dn = camille.DistinguishedName, options = new Dictionary<string, bool> { ["passwordNeverExpires"] = true } });
        Check.True(AdValues.HasFlag(Camille(bridge).UserAccountControl, 0x10000), "DONT_EXPIRE_PASSWORD posé, les autres bits intacts");
    }

    [Test]
    public static async Task Move_create_and_delete_follow_the_guards()
    {
        var bridge = new SimulatedBridge();
        var camille = Camille(bridge);
        var branch = ParentOf(camille.DistinguishedName);

        await WriteAsync(bridge, "fiche.createOu.plan", new { parent = branch, name = "Stagiaires" });
        var created = "OU=Stagiaires," + branch;
        Check.Equal("ou", (await ResultAsync(bridge, "fiche.read", new { dn = created })).GetProperty("identity").GetProperty("kind").GetString(), "OU créée et relue");
        Check.Equal(FicheErrors.Refused, await ErrorAsync(bridge, "fiche.createOu.plan", new { parent = branch, name = "Stagiaires" }), "doublon refusé par le plan");

        await WriteAsync(bridge, "fiche.move.plan", new { dn = camille.DistinguishedName, target = created });
        var moved = "CN=Camille Bernard," + created;
        Check.Equal(moved, Camille(bridge).DistinguishedName, "nouveau DN");
        Check.Equal(FicheErrors.Unknown, await ErrorAsync(bridge, "fiche.read", new { dn = camille.DistinguishedName }), "l’ancien DN n’existe plus");
        Check.True(Camille(bridge).MemberOf.All(g => bridge.Source.CurrentDirectory.Groups.Single(x => FicheValues.SameDn(x.DistinguishedName, g)).Members.Contains(moved, StringComparer.OrdinalIgnoreCase)),
            "les groupes suivent le nouveau DN");

        Check.Equal(FicheErrors.Protected, await ErrorAsync(bridge, "fiche.delete.plan", new { dn = created }), "suppression d’OU interdite par défaut");
        Check.Equal(FicheErrors.Protected, await ErrorAsync(bridge, "fiche.delete.plan", new { dn = "CN=Users," + Root }), "conteneur par défaut protégé");

        var planned = await ResultAsync(bridge, "fiche.delete.plan", new { dn = moved });
        Check.True(planned.GetProperty("plan").GetProperty("confirmation").GetProperty("typedNameRequired").GetBoolean(), "suppression : nom à saisir");
        var refused = await bridge.CallAsync("write.execute", Args(new { planId = planned.GetProperty("plan").GetProperty("id").GetString(), token = planned.GetProperty("token").GetString(), typedName = "autre" }));
        Check.Equal("error", refused.Kind, "mauvais nom : rien n’est supprimé");
        await WriteAsync(bridge, "fiche.delete.plan", new { dn = moved });
        Check.False(bridge.Source.CurrentDirectory.Users.Any(u => u.ObjectGuid == camille.ObjectGuid), "compte supprimé de la surcouche");
        Check.False(Group(bridge, "GG-Commercial-Lyon").Members.Contains(moved, StringComparer.OrdinalIgnoreCase), "références retirées des groupes");
    }

    [Test]
    public static async Task Raw_writes_apply_the_rule_twice_and_resets_keep_the_secret_out()
    {
        var bridge = new SimulatedBridge();
        var camille = Camille(bridge);
        Check.Equal(FicheErrors.Refused, await ErrorAsync(bridge, "fiche.rawAttribute.plan", new { dn = camille.DistinguishedName, attribute = "unicodePwd", value = "x" }), "mot de passe refusé avant le plan");
        Check.Equal(FicheErrors.Refused, await ErrorAsync(bridge, "fiche.rawAttribute.plan", new { dn = camille.DistinguishedName, attribute = "objectGUID", value = "x" }), "attribut opérationnel refusé");
        await WriteAsync(bridge, "fiche.rawAttribute.plan", new { dn = camille.DistinguishedName, attribute = "info", value = "Rappeler après 14 h" });
        var attributes = await ResultAsync(bridge, "fiche.attributes", new { dn = camille.DistinguishedName });
        Check.True(attributes.GetProperty("rows").EnumerateArray().Any(r => r.GetProperty("name").GetString() == "info" && r.GetProperty("display").GetString() == "Rappeler après 14 h"), "valeur brute relue");

        // Without the secure window of the host (tests, headless runs), a reset is refused: no password ever goes through the page.
        Check.Equal(FicheErrors.Refused, await ErrorAsync(bridge, "fiche.resetPassword.plan", new { dn = camille.DistinguishedName, mustChange = true, unlock = true }), "pas de fenêtre sécurisée : refus");
    }

    // ---------------------------------------------------------------- round 2: configuration, secure window, ranges, postcondition

    private static readonly System.Reflection.Assembly TestAssembly = typeof(FicheTests).Assembly;

    private static SimulatedBridge WithWindow() => new(readers: [TestAssembly]);

    [Test]
    public static void Security_settings_of_the_configuration_are_read_strictly_and_bounded()
    {
        var read = FicheConfiguration.Parse("""
            { "security": { "AllowRawAttributeWrite": true, "GeneratedPasswordLength": 80, "ForcePasswordChangeOnReset": "false" },
              "CallSheet": { "TicketTemplate": [ "Appel de {NomAffiche}", "{Compte}" ] } }
            """u8);
        Check.Equal(ConfigurationFileState.Read, read.State, "fichier lu, noms sans casse");
        Check.Equal(true, read.AllowRawAttributeWrite, "écriture brute demandée");
        Check.Equal(64, read.GeneratedPasswordLength, "longueur ramenée à 64");
        Check.True(read.GeneratedPasswordLengthBounded, "bornage signalé");
        Check.Null(read.ForcePasswordChangeOnReset, "« false » texte ignoré, jamais lu comme booléen");
        Check.True(read.Warnings.Length >= 2, "valeurs ignorées ou bornées signalées");
        Check.Equal("Appel de {NomAffiche}\n{Compte}", read.TicketTemplate, "modèle en lignes");
        Check.Equal(ConfigurationFileState.Invalid, FicheConfiguration.Parse("""{ "Security": {}, "security": {} }"""u8).State, "section en double : fichier ignoré");
        Check.Equal(ConfigurationFileState.Invalid, FicheConfiguration.Parse("""{ "Security": { "AllowContainerDelete": true, "allowcontainerdelete": false } }"""u8).State, "clé en double");
        Check.Equal(ConfigurationFileState.Invalid, FicheConfiguration.Parse("{"u8).State, "JSON illisible");

        var directory = FicheSecurityPolicy.From(FicheConfiguration.Absent, AppMode.Directory);
        Check.False(directory.AllowRawAttributeWrite, "mode annuaire : écriture brute fermée par défaut (Domenia 1)");
        Check.True(directory.ForcePasswordChangeOnReset && directory.RequireTypedDeleteConfirmation, "défauts de Domenia 1");
        Check.True(FicheSecurityPolicy.From(FicheConfiguration.Absent, AppMode.Simulation).AllowRawAttributeWrite, "simulation : ouverte sur l’annuaire fictif");
        var closed = FicheConfiguration.Absent with { AllowRawAttributeWrite = false };
        Check.False(FicheSecurityPolicy.From(closed, AppMode.Simulation).AllowRawAttributeWrite, "le fichier l’emporte, même en simulation");
        var provenance = FicheSecurityPolicy.Describe(read, AppMode.Directory);
        Check.Equal("file", provenance.Single(s => s.Key == "AllowRawAttributeWrite").Source, "provenance : fichier");
        Check.Equal("fileBounded", provenance.Single(s => s.Key == "GeneratedPasswordLength").Source, "provenance : fichier borné");
        Check.Equal("default", provenance.Single(s => s.Key == "AllowContainerDelete").Source, "provenance : défaut");
    }

    [Test]
    public static void The_ticket_template_is_resolved_like_Domenia_1()
    {
        Check.Equal("Défaut", FicheCallSheets.ResolveTemplate(null).Source, "sans modèle");
        Check.Equal("Défaut", FicheCallSheets.ResolveTemplate("   ").Source, "modèle vide : défaut sans message");
        Check.Null(FicheCallSheets.ResolveTemplate("   ").Warning, "aucun avertissement pour un modèle vide");
        Check.Equal("Configuration", FicheCallSheets.ResolveTemplate("Appel de {NomAffiche}\r\n{Compte}").Source, "modèle configuré");
        Check.Contains("4", FicheCallSheets.ResolveTemplate("{Compte}" + new string('x', 4000)).Warning, "trop long : refusé avec son motif");
        Check.Contains("aucun champ", FicheCallSheets.ResolveTemplate("Texte fixe").Warning, "sans champ connu");
        Check.Contains("contrôle", FicheCallSheets.ResolveTemplate("{Compte}\u0007").Warning, "caractère de contrôle");
        var placeholders = FicheCallSheets.Placeholders;
        Check.True(placeholders.All(p => FicheCallSheets.DefaultTemplate.Contains("{" + p + "}", StringComparison.Ordinal)), "le modèle par défaut contient tous les champs");
    }

    [Test]
    public static void Freshness_follows_the_usage_profile_and_a_failed_attempt_never_rejuvenates()
    {
        using var stored = JsonDocument.Parse("""{ "profile": "troubleshooting", "freshness": { "troubleshooting": { "presence": 45 } } }""");
        var table = FicheFreshnessTable.Read(stored.RootElement);
        Check.Equal(45, table.Presence, "durée personnalisée du profil");
        Check.Equal(300, table.Attributes, "les autres durées du profil");
        Check.True(table.Custom, "durées personnalisées signalées");
        Check.Equal(900, FicheFreshnessTable.Read(null).Attributes, "Standard sans réglage");
        var observed = Fixtures.Now - TimeSpan.FromMinutes(10);
        var attempt = Fixtures.Now - TimeSpan.FromMinutes(1);
        var presence = FicheDiagnostics.Freshness("presence", observed, attempt, Fixtures.Now, TestClock.Paris, table);
        Check.Equal("stale", presence.State, "10 min > 45 s : à relire");
        Check.Equal(observed, presence.ObservedAt, "la tentative ne rajeunit pas l’observation");
        Check.Equal(attempt, presence.LastAttempt, "dernière tentative montrée");
        Check.Equal("historical", FicheDiagnostics.Freshness("history", observed, null, Fixtures.Now, TestClock.Paris).State, "historique sans expiration");
        Check.Equal("unknown", FicheDiagnostics.Freshness("console", null, attempt, Fixtures.Now, TestClock.Paris).State, "jamais observé reste inconnu");
    }

    [Test]
    public static void A_delta_postcondition_says_verified_partial_or_to_check()
    {
        const string member = "CN=A,OU=X," + Root;
        const string g1 = "CN=G1,OU=G," + Root;
        const string g2 = "CN=G2,OU=G," + Root;
        FicheGroupDeltaStep[] steps = [new("add", g1, "G1", member, "Ajouter à G1"), new("remove", g2, "G2", member, "Retirer de G2")];
        Check.Equal("verified", FicheMemberships.DeltaPostcondition(member, steps, [g1], Fixtures.Now).Overall, "ajout et retrait constatés");
        var partial = FicheMemberships.DeltaPostcondition(member, steps, [g1, g2], Fixtures.Now);
        Check.Equal("partial", partial.Overall, "un retrait non constaté : partiel");
        Check.Equal("failed", partial.Rows.Single(r => r.GroupDn == g2).Status, "l’étape en échec est nommée");
        Check.Equal("toCheck", FicheMemberships.DeltaPostcondition(member, steps, null, Fixtures.Now).Overall, "relecture impossible : à vérifier");
        Check.Equal("none", FicheMemberships.DeltaPostcondition(member, [], [g1], Fixtures.Now).Overall, "aucune étape");
    }

    [Test]
    public static void Why_member_uses_the_transitive_answer_when_no_path_was_read()
    {
        const string obj = "CN=A,OU=X," + Root;
        const string group = "CN=Far,OU=G," + Root;
        var graph = new FicheGroupGraph(obj, ImmutableDictionary<string, ImmutableArray<string>>.Empty.Add(obj, []), ImmutableDictionary<string, FicheGraphNode>.Empty, false, 0, null);
        var yes = FicheMemberships.Why(obj, "A", group, "Far", false, graph, false, transitive: true);
        Check.True(yes.Known && yes.Member == true && yes.Basis == "controller", "confirmé par la règle de chaînage du contrôleur");
        var no = FicheMemberships.Why(obj, "A", group, "Far", false, graph, false, transitive: false);
        Check.True(no.Known && no.Member == false, "non membre confirmé, lecture complète");
        var truncated = graph with { Truncated = true };
        var unknown = FicheMemberships.Why(obj, "A", group, "Far", false, truncated, false, transitive: null);
        Check.True(!unknown.Known && unknown.Member is null, "lecture tronquée sans réponse : indéterminé, jamais « non membre »");
    }

    [Test]
    public static void Members_read_by_ranges_keep_their_total_and_say_a_partial_read()
    {
        var dns = Enumerable.Range(0, 2100).Select(i => "CN=U" + i.ToString(System.Globalization.CultureInfo.InvariantCulture) + ",OU=X," + Root).ToList();
        var list = FicheMemberships.Members("CN=G,OU=G," + Root, "members", dns.Take(2000).ToList(), new Dictionary<string, FicheSummary>(), true, null, 2100);
        Check.Equal(2100, list.Total, "total compté par plages");
        Check.Equal(2000, list.Shown, "2 000 affichés");
        Check.Contains("affichés sur", list.Label, "« 2 000 affichés sur 2 100 »");
        var partial = FicheMemberships.Members("CN=G,OU=G," + Root, "members", dns.Take(2000).ToList(), new Dictionary<string, FicheSummary>(), false, "lecture arrêtée à 50 000 membres", 50000);
        Check.False(partial.Complete, "lecture partielle jamais présentée comme complète");
        Check.Contains("lecture partielle", partial.Label, "motif dit");
    }

    [Test]
    public static async Task Arguments_of_the_fiche_are_checked()
    {
        var bridge = new SimulatedBridge();
        var dn = Camille(bridge).DistinguishedName;
        Check.Equal(DomeniaErrors.ArgumentsInvalid, await ErrorAsync(bridge, "fiche.read", new { dn, autre = 1 }), "propriété inconnue");
        Check.Equal(DomeniaErrors.ArgumentsInvalid, await ErrorAsync(bridge, "fiche.read", new { dn, reread = "oui" }), "reread booléen");
        Check.Equal(DomeniaErrors.ArgumentsInvalid, await ErrorAsync(bridge, "fiche.lockouts", new { dn, hours = 0 }), "fenêtre de 0 h");
        Check.Equal(DomeniaErrors.ArgumentsInvalid, await ErrorAsync(bridge, "fiche.lockouts", new { dn, hours = 721 }), "fenêtre de 721 h");
        Check.Equal(DomeniaErrors.ArgumentsInvalid, await ErrorAsync(bridge, "fiche.rawAttribute.plan", new { dn, attribute = "info", value = new string('x', 4097) }), "valeur de plus de 4 096 caractères");
        Check.Equal(DomeniaErrors.ArgumentsInvalid, await ErrorAsync(bridge, "fiche.pick", new { text = "ber", kinds = new[] { "imprimante" } }), "type inconnu");
        Check.Equal(DomeniaErrors.ArgumentsInvalid, await ErrorAsync(bridge, "fiche.update.plan", new { dn, fields = new Dictionary<string, string>() }), "aucun champ");
        Check.Equal(DomeniaErrors.ArgumentsInvalid, await ErrorAsync(bridge, "fiche.move.plan", new { dn, target = ParentOf(dn), guid = "pas-un-guid" }), "GUID mal formé");
        Check.Equal(DomeniaErrors.ArgumentsInvalid, await ErrorAsync(bridge, "fiche.groups.delta.check", new { dn, steps = new[] { new { action = "remplacer", group = dn } } }), "étape inconnue");
    }

    [Test]
    public static async Task Resolve_accepts_guid_and_sid_and_refuses_another_domain()
    {
        var bridge = new SimulatedBridge();
        var camille = Camille(bridge);
        Check.Equal(camille.DistinguishedName, (await ResultAsync(bridge, "fiche.resolve", new { text = camille.ObjectGuid.ToString("B") })).GetProperty("dn").GetString(), "par GUID");
        Check.Equal(camille.DistinguishedName, (await ResultAsync(bridge, "fiche.resolve", new { text = camille.Sid })).GetProperty("dn").GetString(), "par SID");
        Check.Equal(camille.DistinguishedName, (await ResultAsync(bridge, "fiche.resolve", new { text = "EXAMPLE\\" + camille.SamAccountName })).GetProperty("dn").GetString(), "DOMAINE\\compte");
        Check.Equal(FicheErrors.NotFound, await ErrorAsync(bridge, "fiche.resolve", new { text = "AUTRE\\" + camille.SamAccountName }), "autre domaine : refusé, jamais retiré en silence");
    }

    [Test]
    public static async Task Two_reads_of_an_unchanged_object_share_their_signature_and_reread_forgets_one_object_only()
    {
        var bridge = new SimulatedBridge();
        var camille = Camille(bridge);
        var other = bridge.Source.CurrentDirectory.Users.First(u => u.ObjectGuid != camille.ObjectGuid);
        var first = await ResultAsync(bridge, "fiche.read", new { dn = camille.DistinguishedName });
        var second = await ResultAsync(bridge, "fiche.read", new { dn = camille.DistinguishedName });
        Check.Equal(first.GetProperty("signature").GetString(), second.GetProperty("signature").GetString(), "signature stable sans changement (FIC-031)");
        await ResultAsync(bridge, "fiche.read", new { dn = other.DistinguishedName });
        await ResultAsync(bridge, "fiche.read", new { dn = camille.DistinguishedName, reread = true });
        var session = FicheSession.From(bridge.Context);
        Check.NotNull(session.LastRead(other.DistinguishedName), "relire une fiche ne vide pas le cache des autres objets (FIC-039)");
        await WriteAsync(bridge, "fiche.update.plan", new { dn = camille.DistinguishedName, fields = new Dictionary<string, string?> { ["description"] = "Nouvelle description" } });
        var after = await ResultAsync(bridge, "fiche.read", new { dn = camille.DistinguishedName, reread = true });
        Check.Equal(first.GetProperty("signature").GetString(), after.GetProperty("signature").GetString(), "un champ d’affichage ne change pas la signature");
    }

    [Test]
    public static async Task The_fiche_lands_on_what_is_read_first()
    {
        var bridge = new SimulatedBridge();
        var group = Group(bridge, "GG-Commercial-Lyon");
        Check.Equal("membres", (await ResultAsync(bridge, "fiche.read", new { dn = group.DistinguishedName })).GetProperty("landing").GetString(), "un groupe s’ouvre sur ses membres");
        Check.Equal("membres", (await ResultAsync(bridge, "fiche.read", new { dn = ParentOf(group.DistinguishedName) })).GetProperty("landing").GetString(), "une OU sur son contenu");
        Check.Equal("general", (await ResultAsync(bridge, "fiche.read", new { dn = Camille(bridge).DistinguishedName })).GetProperty("landing").GetString(), "un compte sur son identité");
    }

    [Test]
    public static async Task Destinations_list_ous_and_default_containers_but_never_builtin()
    {
        var bridge = new SimulatedBridge();
        var top = await ResultAsync(bridge, "fiche.destinations", new { dn = (string?)null });
        string[] dns = Strings(top, "dn");
        Check.True(dns.Contains("CN=Users," + Root) && dns.Contains("CN=Computers," + Root), "conteneurs par défaut proposés");
        Check.False(dns.Contains("CN=Builtin," + Root), "Builtin jamais proposé");
        Check.True(top.EnumerateArray().Any(d => d.GetProperty("kind").GetString() == "ou"), "OU proposées");
    }

    [Test]
    public static async Task A_move_refuses_an_object_that_changed_while_the_picker_was_open()
    {
        var bridge = new SimulatedBridge();
        var camille = Camille(bridge);
        var target = "CN=Users," + Root;
        Check.Equal(FicheErrors.Refused, await ErrorAsync(bridge, "fiche.move.plan", new { dn = camille.DistinguishedName, target, guid = Guid.NewGuid().ToString("D") }), "GUID différent : refus");
        await WriteAsync(bridge, "fiche.move.plan", new { dn = camille.DistinguishedName, target, guid = camille.ObjectGuid.ToString("D") });
        Check.Equal("CN=Camille Bernard," + target, Camille(bridge).DistinguishedName, "déplacé vers un conteneur par défaut");
    }

    [Test]
    public static async Task A_moved_object_is_read_again_at_its_new_dn_with_the_same_guid()
    {
        // FIC-018: after an applied move the page opens RDN + destination with the GUID of the object; that read must succeed.
        var bridge = new SimulatedBridge();
        var camille = Camille(bridge);
        var target = "CN=Users," + Root;
        var receipt = await WriteAsync(bridge, "fiche.move.plan", new { dn = camille.DistinguishedName, target, guid = camille.ObjectGuid.ToString("D") });
        Check.Equal("applied", receipt.GetProperty("result").GetString(), "déplacement appliqué");
        var movedDn = camille.DistinguishedName[..camille.DistinguishedName.IndexOf(',', StringComparison.Ordinal)] + "," + target;
        var sheet = await ResultAsync(bridge, "fiche.read", new { dn = movedDn });
        var identity = sheet.GetProperty("identity");
        Check.Equal(camille.ObjectGuid.ToString("D"), identity.GetProperty("guid").GetString(), "même objet relu au nouveau DN (même GUID)");
        Check.True(FicheValues.SameDn(movedDn, identity.GetProperty("dn").GetString() ?? ""), "DN relu : RDN + destination");
        Check.True(FicheValues.SameDn(target, identity.GetProperty("parentDn").GetString() ?? ""), "parent relu : la destination");
        Check.Equal(FicheErrors.Unknown, await ErrorAsync(bridge, "fiche.read", new { dn = camille.DistinguishedName, reread = true }), "l’ancien DN est introuvable, jamais relu par erreur");
    }

    [Test]
    public static async Task Presence_readings_are_kept_under_the_guid_and_forgotten_with_the_object()
    {
        // FIC-046 and FIC-037: a ping is kept under the objectGUID of the workstation; « Relire » forgets every entry of the object
        // (GUID first, DN only to find it) and says how many were removed.
        var bridge = new SimulatedBridge();
        var computer = bridge.Source.CurrentDirectory.Computers.First(c => c.Name.StartsWith("PC-", StringComparison.Ordinal));
        await ResultAsync(bridge, "fiche.read", new { dn = computer.DistinguishedName });
        var ping = await ResultAsync(bridge, "fiche.presence", new { dn = computer.DistinguishedName });
        Check.True(FicheValues.SameDn(computer.DistinguishedName, ping.GetProperty("computerDn").GetString() ?? ""), "ping du poste ouvert");
        var session = FicheSession.From(bridge.Context);
        Check.NotNull(session.Ping(computer.ObjectGuid), "relevé rangé sous le GUID du poste");
        Check.True(session.Ping(Guid.NewGuid()) is null, "un autre GUID (poste recréé sous le même DN) n’hérite de rien");

        var removed = session.Forget(computer.DistinguishedName, computer.ObjectGuid);
        Check.True(removed >= 2, "lecture gardée et relevé de présence retirés, et comptés (" + removed + ")");
        Check.True(session.Ping(computer.ObjectGuid) is null && session.LastRead(computer.DistinguishedName) is null, "plus rien de l’objet en session");
        Check.Equal(0, session.Forget(computer.DistinguishedName, computer.ObjectGuid), "un second oubli ne retire rien");

        await ResultAsync(bridge, "fiche.presence", new { dn = computer.DistinguishedName });
        await ResultAsync(bridge, "fiche.read", new { dn = computer.DistinguishedName, reread = true });
        Check.True(session.Ping(computer.ObjectGuid) is null, "« Relire » oublie aussi le relevé de présence du poste, par son GUID");
    }

    [Test]
    public static async Task The_domain_root_opens_and_only_its_children_have_a_parent_to_open()
    {
        var bridge = new SimulatedBridge();
        static string[] Actions(JsonElement sheet) => Strings(sheet.GetProperty("actions"), "id");
        var root = await ResultAsync(bridge, "fiche.read", new { dn = Root });
        Check.Equal("container", root.GetProperty("identity").GetProperty("kind").GetString(), "la racine s’ouvre en fiche");
        Check.False(Actions(root).Contains("openParent"), "la racine n’a pas de parent dans le domaine");
        Check.True(Actions(root).Contains("setScope"), "la racine peut devenir l’OU de travail");
        Check.False(Actions(root).Contains("delete"), "la racine ne se supprime jamais");
        var users = await ResultAsync(bridge, "fiche.read", new { dn = "CN=Users," + Root });
        Check.True(Actions(users).Contains("openParent"), "un objet placé sous la racine ouvre la racine");
    }

    [Test]
    public static async Task Members_of_a_group_are_read_by_ranges()
    {
        var bridge = new SimulatedBridge();
        var group = Group(bridge, "GG-Commercial-Lyon");
        var members = await ResultAsync(bridge, "fiche.members", new { dn = group.DistinguishedName });
        Check.Equal(group.Members.Length, members.GetProperty("total").GetInt32(), "total compté");
        Check.True(members.GetProperty("complete").GetBoolean(), "lecture complète sous 50 000");
    }

    [Test]
    public static async Task Lockouts_reconcile_the_refusals_of_Domenia_and_the_delta_is_checked_again()
    {
        var bridge = new SimulatedBridge();
        var camille = Camille(bridge);
        var lockouts = await ResultAsync(bridge, "fiche.lockouts", new { dn = camille.DistinguishedName, hours = 720 });
        Check.True(lockouts.GetProperty("rows").GetArrayLength() > 0, "Camille a des verrouillages journalisés");
        Check.True(lockouts.GetProperty("facts").EnumerateArray().Any(f => f.GetProperty("label").GetString() == "Refus de Domenia avant un verrouillage"), "rapprochement des refus de Domenia (FIC-045)");

        var group = Group(bridge, "GG-Commercial-Lyon");
        var stepsAdd = new[] { new { action = "add", group = group.DistinguishedName } };
        var check = await ResultAsync(bridge, "fiche.groups.delta.check", new { dn = camille.DistinguishedName, steps = stepsAdd });
        Check.Equal(group.Members.Contains(camille.DistinguishedName, StringComparer.OrdinalIgnoreCase) ? "verified" : "partial", check.GetProperty("overall").GetString(), "relu sur le contrôleur");
    }

    [Test]
    public static async Task A_reset_takes_the_password_of_the_secure_window_once_and_never_shows_it()
    {
        var bridge = WithWindow();
        var camille = Camille(bridge);
        ScriptedPasswordWindow.Reset(request => new FichePasswordEntry(TemporaryPassword.Generate(request.GeneratedLength), true));
        var planned = await ResultAsync(bridge, "fiche.resetPassword.plan", new { dn = camille.DistinguishedName, mustChange = true, unlock = true, generate = true, theme = "dark" });
        Check.Equal(16, ScriptedPasswordWindow.Requests.Single().GeneratedLength, "longueur de la configuration (16 par défaut)");
        Check.Contains("généré", planned.GetRawText(), "le plan dit l’origine du mot de passe");
        Check.False(planned.GetRawText().Contains("unicodePwd\":\"", StringComparison.Ordinal), "aucune valeur dans le plan");
        var receipt = await ResultAsync(bridge, "write.execute", new
        {
            planId = planned.GetProperty("plan").GetProperty("id").GetString(),
            token = planned.GetProperty("token").GetString(),
            typedName = planned.GetProperty("plan").GetProperty("confirmation").GetProperty("typedName").GetString(),
        });
        Check.Equal("applied", receipt.GetProperty("result").GetString(), "réinitialisation appliquée");
        Check.Equal(0L, Camille(bridge).PasswordLastSet, "changement imposé");
        Check.Equal(0L, Camille(bridge).LockoutTime, "déverrouillé ensuite");
        Check.False(bridge.Log.Lines.Any(l => l.Contains("unicodePwd=", StringComparison.OrdinalIgnoreCase)), "aucun secret journalisé");

        ScriptedPasswordWindow.Reset(_ => null);
        Check.Equal(FicheErrors.Cancelled, await ErrorAsync(bridge, "fiche.resetPassword.plan", new { dn = camille.DistinguishedName, mustChange = true, unlock = false }), "fenêtre fermée : rien n’est préparé");

        var admin = bridge.Source.CurrentDirectory.Users.FirstOrDefault(u => u.AdminCount == 1);
        if (admin is not null)
        {
            ScriptedPasswordWindow.Reset(request => new FichePasswordEntry(TemporaryPassword.Generate(request.GeneratedLength), false));
            var protectedPlan = await ResultAsync(bridge, "fiche.resetPassword.plan", new { dn = admin.DistinguishedName, mustChange = true, unlock = false });
            Check.True(protectedPlan.GetProperty("plan").GetProperty("confirmation").GetProperty("typedNameRequired").GetBoolean(), "compte protégé : permis avec la saisie du nom (Domenia 1)");
        }
    }

    [Test]
    public static async Task Deleting_an_object_removes_its_local_associations()
    {
        var bridge = new SimulatedBridge();
        var camille = Camille(bridge);
        var before = await ResultAsync(bridge, "fiche.relations", new { dn = camille.DistinguishedName });
        var computer = before.GetProperty("associations").EnumerateArray().First(a => a.GetProperty("kind").GetString() == "computer").GetProperty("dn").GetString()!;
        var planned = await ResultAsync(bridge, "fiche.delete.plan", new { dn = computer });
        Check.Contains("association", planned.GetRawText(), "le plan annonce les associations locales retirées");
        await WriteAsync(bridge, "fiche.delete.plan", new { dn = computer });
        var after = await ResultAsync(bridge, "fiche.relations", new { dn = camille.DistinguishedName });
        Check.False(after.GetProperty("associations").EnumerateArray().Any(a => a.GetProperty("dn").GetString() == computer), "association retirée de la base locale");
    }

    [Test]
    public static void Directory_mode_declares_network_reads_and_refuses_the_plans()
    {
        var decision = ModeResolver.Resolve([], null, () => new DomainJoinInfo(DomainJoinState.Joined, "cnamts.local"));
        var source = new UnavailableDirectorySource("cnamts.local", () => @"CNAMTS\degun");
        using var context = new EngineContext(decision, source, new MemoryPreferenceStore(), TestClock.Fixed(), new RecordingJournal(), ScreenReaders.Discover(source, [typeof(SimulatedDirectorySource).Assembly]));
        var registry = OperationModules.CreateRegistry(context, OperationModules.Discover([typeof(FicheOperations).Assembly]));
        foreach (var name in new[] { "fiche.read", "fiche.attributes", "fiche.members", "fiche.groups", "fiche.destinations", "fiche.groups.delta.check", "fiche.lockouts", "fiche.rights" })
        {
            Check.True(registry.TryGet(name, out var definition), "déclarée : " + name);
            Check.Equal(OperationClass.NetworkRead, definition!.Class, "lecture réseau en mode annuaire : " + name);
        }
        Check.True(registry.TryGet("fiche.preview", out var preview) && preview!.Class == OperationClass.LocalRead, "l’aperçu reste local");
    }
}

/// <summary>Scripted secure window of the fiche for the tests: answers what <see cref="Reset"/> set, records the requests (never a secret).</summary>
public sealed class ScriptedPasswordWindow : IFichePasswordWindow
{
    private static readonly Lock Gate = new();
    private static Func<FichePasswordRequest, FichePasswordEntry?> answer = _ => null;
    private static readonly List<FichePasswordRequest> Seen = [];

    public ScriptedPasswordWindow(IDirectorySource source)
    {
        ArgumentNullException.ThrowIfNull(source);
    }

    public static IReadOnlyList<FichePasswordRequest> Requests
    {
        get
        {
            lock (Gate)
            {
                return [.. Seen];
            }
        }
    }

    public static void Reset(Func<FichePasswordRequest, FichePasswordEntry?> next)
    {
        lock (Gate)
        {
            answer = next;
            Seen.Clear();
        }
    }

    public Task<FichePasswordEntry?> AskAsync(FichePasswordRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        lock (Gate)
        {
            Seen.Add(request);
            return Task.FromResult(answer(request));
        }
    }
}
