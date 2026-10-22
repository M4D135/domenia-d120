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
            "actions", "tabs", "landing", "summary", "support", "signature"]), "champs de la fiche : " + string.Join(", ", fields));
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

        var planned = await ResultAsync(bridge, "fiche.resetPassword.plan", new { dn = camille.DistinguishedName, mustChange = true, unlock = true });
        var text = planned.GetRawText();
        Check.False(text.Contains("unicodePwd\":\"", StringComparison.Ordinal), "aucune valeur de mot de passe dans le plan");
        var receipt = await WriteAsync(bridge, "fiche.resetPassword.plan", new { dn = camille.DistinguishedName, mustChange = true, unlock = true });
        Check.Equal("applied", receipt.GetProperty("result").GetString(), "réinitialisation appliquée");
        var after = Camille(bridge);
        Check.Equal(0L, after.PasswordLastSet, "changement imposé à la prochaine ouverture");
        Check.Equal(0L, after.LockoutTime, "déverrouillé ensuite");
        Check.False(bridge.Log.Lines.Any(l => l.Contains("unicodePwd=", StringComparison.OrdinalIgnoreCase)), "aucun secret journalisé");
    }
}
