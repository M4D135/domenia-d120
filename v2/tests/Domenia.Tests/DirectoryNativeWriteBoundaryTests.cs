using System.Collections.Immutable;
using System.DirectoryServices.Protocols;
using System.Globalization;
using System.Reflection;
using System.Runtime.Loader;
using System.Security.AccessControl;
using System.Security.Principal;
using Domenia.Ad;
using Domenia.Core;

namespace Domenia.Tests;

internal static class DirectoryNativeWriteBoundaryTests
{
    internal static DirectoryResponse Response(Type type, int code, string diagnostic = "diagnostic serveur privé") => (DirectoryResponse)Activator.CreateInstance(type,
        BindingFlags.Instance | BindingFlags.NonPublic, null,
        ["", Array.Empty<DirectoryControl>(), (ResultCode)code, diagnostic, Array.Empty<Uri>()], CultureInfo.InvariantCulture)!;

    internal static DomeniaOperationException Refusal(int code) => (DomeniaOperationException)AdConnection.MapMutationFailure("modify",
        new DirectoryOperationException(Response(typeof(ModifyResponse), code)));

    [Test]
    public static async Task Real_response_types_codes_and_native_send_count_limit_a_negative_outcome_to_one_atomic_request()
    {
        foreach (var (operation, type) in new[] { ("modify", typeof(ModifyResponse)), ("add", typeof(AddResponse)),
            ("delete", typeof(DeleteResponse)), ("rename", typeof(ModifyDNResponse)) })
        {
            var failure = AdConnection.MapMutationFailure(operation, new DirectoryOperationException(Response(type, 50)));
            Check.True(failure is DomeniaOperationException { DirectoryResultCode: 50 }, "réponse native typée du serveur");
            using var attempt = DirectoryWriteEvidence.BeginAttempt();
            Check.False(attempt.IsProvenRejection(failure), "pas de preuve d’envoi inventée");
            await Task.Run(DirectoryWriteEvidence.Sent);
            Check.True(attempt.IsProvenRejection(failure), "une requête atomique refusée");
            await Task.Run(DirectoryWriteEvidence.Sent);
            Check.False(attempt.IsProvenRejection(failure), "le refus suivant ne prouve pas l’échec de la première requête");
            Check.False(failure.ToString().Contains("diagnostic serveur privé", StringComparison.Ordinal), "diagnostic brut absent");
        }
        foreach (var code in new[] { 0, 5, 6, 10, 14, 80, 81, 85, 999 })
            Check.True(AdConnection.MapMutationFailure("modify", new DirectoryOperationException(Response(typeof(ModifyResponse), code))) is AdWriteOutcomeUnknownException, "aucune preuve pour code " + code);
        Check.True(AdConnection.MapMutationFailure("modify", new DirectoryOperationException(Response(typeof(SearchResponse), 50))) is AdWriteOutcomeUnknownException, "une recherche refusée ne prouve pas une mutation refusée");
        Check.True(AdConnection.MapMutationFailure("modify", new LdapException(50)) is AdWriteOutcomeUnknownException, "code client sans réponse");
        var locked = (DomeniaOperationException)AdConnection.MapMutationFailure("modify", new DirectoryOperationException(Response(typeof(ModifyResponse), 49, "80090308: LdapErr: DSID-0C09044E, comment: AcceptSecurityContext error, data 775, v4563, private details")));
        Check.Equal("locked", locked.Data["authenticationKind"] as string, "pause compte conservée dans le diagnostic fermé");
        Check.Equal("LDAP 49 / 0x775", locked.Data["authenticationCode"] as string, "sous-code conservé sans message serveur");
        Check.False(locked.ToString().Contains("private details", StringComparison.Ordinal), "diagnostic serveur non publié");
        var traces = new List<string>();
        AdConnection.TechnicalTrace += traces.Add;
        try
        {
            foreach (var code in new[] { 16, 20 })
            {
                traces.Clear();
                var failure = Refusal(code);
                Check.Equal(WriteErrors.Stale, failure.Code, "conflit de valeur du serveur");
                Check.Equal(code, failure.DirectoryResultCode, "code de la réponse conservé");
                Check.Equal("LDAP modify" + FrenchText.Colon + " code " + code.ToString(CultureInfo.InvariantCulture),
                    traces.Single(), "une seule trace fermée sans DN ni diagnostic brut");
            }
        }
        finally { AdConnection.TechnicalTrace -= traces.Add; }
    }

    [Test]
    public static async Task Closing_nested_attempts_out_of_order_never_attributes_a_send_to_a_closed_action()
    {
        var failure = Refusal(50);
        using var outer = DirectoryWriteEvidence.BeginAttempt();
        using var middle = DirectoryWriteEvidence.BeginAttempt();
        using var inner = DirectoryWriteEvidence.BeginAttempt();
        DirectoryWriteEvidence.Sent();
        Check.True(outer.IsProvenRejection(failure) && middle.IsProvenRejection(failure) && inner.IsProvenRejection(failure), "envoi imbriqué vu par les trois actions ouvertes");
        middle.Dispose();
        DirectoryWriteEvidence.Sent();
        Check.Equal(2, inner.Sends, "fermer le parent ne ferme pas son enfant actif");
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var captured = Task.Run(async () => { await release.Task; DirectoryWriteEvidence.Sent(); });
        inner.Dispose();
        release.SetResult();
        await captured;
        Check.Equal(3, outer.Sends, "le flux capturé atteint le parent ouvert");
        Check.Equal(1, middle.Sends, "parent fermé non réactivé");
        Check.Equal(2, inner.Sends, "enfant fermé non réactivé");
        Check.False(outer.IsProvenRejection(failure) || middle.IsProvenRejection(failure) || inner.IsProvenRejection(failure), "aucune preuve négative après plusieurs contacts ou fermeture");
        DirectoryWriteEvidence.Sent();
        Check.Equal(4, outer.Sends, "restauration directe du parent toujours ouvert");
    }

    [Test]
    public static void Read_proof_uses_the_actual_DACL_and_refuses_denies_inherit_only_object_and_conditional_allows()
    {
        AdEntry Entry(byte[]? bytes) => new(Fixtures.People, bytes is null ? new Dictionary<string, IReadOnlyList<object>>()
            : new Dictionary<string, IReadOnlyList<object>> { ["nTSecurityDescriptor"] = [bytes] });
        Check.True(AdWriteReadProof.AllowsGeneralRead(Entry(AdWriteFixtureProof.Descriptor())), "AU lecture générale explicitement accordée");
        Check.True(AdWriteReadProof.AllowsGeneralRead(Entry(AdWriteFixtureProof.Descriptor("O:SYG:SYD:(A;;RP;;;WD)"))), "Everyone lecture générale");
        foreach (var sddl in new[] { "O:SYG:SYD:", "O:SYG:SYD:(A;IO;RP;;;AU)", "O:SYG:SYD:(D;;RP;;;WD)(A;;RP;;;AU)",
            "O:SYG:SYD:(OA;;RP;bf967918-0de6-11d0-a285-00aa003049e2;;AU)", "O:SYG:SYD:(A;;WP;;;AU)" })
            Check.False(AdWriteReadProof.AllowsGeneralRead(Entry(AdWriteFixtureProof.Descriptor(sddl))), "ACL spécialisée ou refus non assimilé à lecture générale");
        foreach (var flags in new[] { ObjectAceFlags.None, ObjectAceFlags.InheritedObjectAceTypePresent })
        {
            var generalAcl = new RawAcl(4, 1);
            generalAcl.InsertAce(0, new ObjectAce(AceFlags.None, AceQualifier.AccessAllowed, 0x10, new SecurityIdentifier("S-1-5-11"),
                flags, Guid.Empty, Guid.Parse("bf967aba-0de6-11d0-a285-00aa003049e2"), false, []));
            var generalSd = new RawSecurityDescriptor(ControlFlags.DiscretionaryAclPresent | ControlFlags.SelfRelative, null, null, null, generalAcl);
            var generalBytes = new byte[generalSd.BinaryLength]; generalSd.GetBinaryForm(generalBytes, 0);
            Check.True(AdWriteReadProof.AllowsGeneralRead(Entry(generalBytes)), "ObjectAce effective sans restriction de propriété");
        }
        foreach (var (qualifier, aceFlags, objectFlags, callback) in new[]
        {
            (AceQualifier.AccessDenied, AceFlags.None, ObjectAceFlags.ObjectAceTypePresent, false),
            (AceQualifier.AccessAllowed, AceFlags.None, ObjectAceFlags.None, true),
            (AceQualifier.AccessAllowed, AceFlags.InheritOnly | AceFlags.ContainerInherit, ObjectAceFlags.InheritedObjectAceTypePresent, false),
        })
        {
            var objectAcl = new RawAcl(4, 2);
            var reader = new SecurityIdentifier("S-1-5-11");
            if (qualifier == AceQualifier.AccessDenied)
                objectAcl.InsertAce(0, new CommonAce(AceFlags.None, AceQualifier.AccessAllowed, 0x10, reader, false, []));
            objectAcl.InsertAce(0, new ObjectAce(aceFlags, qualifier, 0x10, reader, objectFlags,
                Guid.Parse("bf967918-0de6-11d0-a285-00aa003049e2"), Guid.Empty, callback, []));
            var descriptor = new RawSecurityDescriptor(ControlFlags.DiscretionaryAclPresent | ControlFlags.SelfRelative, null, null, null, objectAcl);
            var bytes = new byte[descriptor.BinaryLength]; descriptor.GetBinaryForm(bytes, 0);
            Check.False(AdWriteReadProof.AllowsGeneralRead(Entry(bytes)), "refus sur propriété, condition ou héritage seul ne prouvent pas la lecture");
        }
        Check.False(AdWriteReadProof.AllowsGeneralRead(Entry(null)), "descripteur absent");
        Check.False(AdWriteReadProof.AllowsGeneralRead(Entry([1, 2, 3])), "descripteur illisible");
        var acl = new RawAcl(2, 1);
        acl.InsertAce(0, new CommonAce(AceFlags.None, AceQualifier.AccessAllowed, 0x10, new SecurityIdentifier("S-1-5-11"), true, []));
        var sd = new RawSecurityDescriptor(ControlFlags.DiscretionaryAclPresent | ControlFlags.SelfRelative, null, null, null, acl);
        var binary = new byte[sd.BinaryLength]; sd.GetBinaryForm(binary, 0);
        Check.False(AdWriteReadProof.AllowsGeneralRead(Entry(binary)), "condition jamais évaluée approximativement");
    }

    [Test]
    public static void An_unread_field_is_neither_an_empty_before_value_nor_a_verified_clear()
    {
        var entry = FicheEntry.Create(FicheKind.User, Fixtures.IdOf("unknown-fields"), "CN=Personne," + Fixtures.People, "Personne",
            new Dictionary<string, IEnumerable<string?>> { ["description"] = ["Avant"] });
        var draft = ObjectWrites.Update(entry, new Dictionary<string, string?> { ["description"] = null }, new Dictionary<string, FicheSummary>(), "dc.test.local");
        var plan = WritePlans.Seal(draft, WritePlans.NewId(), "TEST\\test", AppMode.Directory, Fixtures.Now, TimeZoneInfo.Utc);
        var unread = entry with { Attributes = entry.Attributes.Remove("description"), KnownAttributes = [] };
        Check.False(ObjectWrites.Check(plan, unread, _ => false).Current, "refus avant envoi");
        Check.False(ObjectWrites.AlreadyApplied(plan, unread, _ => false), "pas de faux déjà fait");
        Check.Equal(VerificationState.Unknown, ObjectWrites.Verify(plan, unread, _ => false).State, "pas de faux écart ni succès après écriture");
        Check.Throws<DomeniaOperationException>(() => ObjectWrites.Update(unread, new Dictionary<string, string?> { ["description"] = "Après" }, new Dictionary<string, FicheSummary>(), null), "ancien contenu inconnu");
        var empty = entry.With(new Dictionary<string, ImmutableArray<string>> { ["description"] = [] });
        Check.True(empty.IsKnown("description"), "absence explicitement qualifiée conservée");
        var saved = System.Text.Json.JsonSerializer.Serialize(empty);
        Check.False(saved.Contains("KnownAttributes", StringComparison.OrdinalIgnoreCase), "preuve fraîche jamais transportée comme autorisation durable");
        var cold = System.Text.Json.JsonSerializer.Deserialize<FicheEntry>(saved) ?? throw new TestFailureException("fiche non relue");
        Check.False(cold.IsKnown("description"), "le cache froid ne prouve pas une absence fraîche");
        Check.Equal(VerificationState.Verified, ObjectWrites.Verify(plan, empty, _ => false).State, "vrai effacement relu");
    }

    [Test]
    public static void A_bad_change_kind_and_a_nonpositive_reference_USN_have_distinct_plan_diagnostics()
    {
        var entry = FicheEntry.Create(FicheKind.User, Fixtures.IdOf("version-ref"), "CN=Personne," + Fixtures.People, "Personne",
            new Dictionary<string, IEnumerable<string?>> { ["description"] = ["Avant"] });
        var draft = ObjectWrites.Update(entry, new Dictionary<string, string?> { ["description"] = "Après" }, new Dictionary<string, FicheSummary>(), null);
        WritePlan Seal(WriteChange change) => WritePlans.Seal(draft with { Changes = [change] }, WritePlans.NewId(),
            "TEST", AppMode.Directory, Fixtures.Now, TimeZoneInfo.Utc);
        var change = draft.Changes[0];
        Check.Contains("Nature de changement", Check.Throws<ArgumentException>(() => Seal(change with { Kind = (WriteChangeKind)999 }), "nature inconnue").Message, "nature distincte");
        foreach (var usn in new long[] { 0, -1 })
            Check.Contains("USN", Check.Throws<ArgumentException>(() => Seal(change with { ReferenceUsn = usn }), "version de référence invalide").Message, "version de référence identifiée");
        Check.Equal(1L, Seal(change with { ReferenceUsn = 1 }).Changes[0].ReferenceUsn, "version positive scellée");
    }

    [Test]
    public static void Write_DNs_refuse_foreign_and_service_partitions_after_decoding_but_preserve_harmless_names()
    {
        foreach (var dn in new[] { "", Fixtures.Root, "CN=X,CN=Configuration," + Fixtures.Root,
            "CN=X,CN=Schema,CN=Configuration," + Fixtures.Root, "CN=X,DC=DomainDnsZones," + Fixtures.Root,
            "CN=X,DC=ForestDnsZones," + Fixtures.Root, "CN=X,DC=foreign,DC=local", "<GUID=" + Guid.NewGuid() + ">",
            "CN=X,CN=Configur\\61tion," + Fixtures.Root })
            Check.Throws<DomeniaOperationException>(() => DirectoryWriteTarget.Require(dn, Fixtures.Root), "partition spéciale, contexte étranger ou pseudo DN");
        DirectoryWriteTarget.Require(Fixtures.Root, Fixtures.Root, true);
        DirectoryWriteTarget.Require("CN=Configuration," + Fixtures.People, Fixtures.Root);
        DirectoryWriteTarget.Require("CN=DnsZones\\, Support/Paris," + Fixtures.People, Fixtures.Root);
    }

    [Test]
    public static async Task An_unpackaged_connection_is_lazy_and_its_first_operation_requires_the_transport_before_binding()
    {
        var isolated = new AssemblyLoadContext("AD sans répertoire de pack", isCollectible: true);
        try
        {
            using var input = File.OpenRead(typeof(AdConnection).Assembly.Location);
            var assembly = isolated.LoadFromStream(input); // No directory beside this in-memory Domenia.Ad.
            var optionsType = assembly.GetType(typeof(AdConnectionOptions).FullName!, true)!;
            var connectionType = assembly.GetType(typeof(AdConnection).FullName!, true)!;
            var options = Activator.CreateInstance(optionsType, [null, null]);
            using var connection = (IDisposable)Activator.CreateInstance(connectionType, [options])!;
            var operation = connectionType.GetMethod(nameof(AdConnection.RootDseAsync))!;
            // If the transport guard disappears the cancelled token stops before any native contact.
            var cancelled = new CancellationToken(canceled: true);
            var failure = await Check.ThrowsAsync<DomeniaOperationException>(() => (Task)operation.Invoke(connection, [cancelled])!,
                "la construction est paresseuse et la première lecture refuse le pack absent");
            Check.Equal(AdErrors.Unavailable, failure.Code, "refus de prérequis identifié avant ouverture");
        }
        finally { isolated.Unload(); }
    }

    [Test]
    public static void The_real_LDAP_and_ADSI_libraries_are_qualified_without_RSAT_or_network_contact()
    {
        var libraries = new[] { typeof(LdapConnection).Assembly, typeof(System.DirectoryServices.DirectoryEntry).Assembly };
        var managedDirectory = Path.GetDirectoryName(typeof(AdConnection).Assembly.Location)!;
        AdTransportPrerequisites.Require();
        AdTransportPrerequisites.Validate(true, true, libraries, managedDirectory, AdTransportPrerequisites.RuntimeDesktopDirectory());
        Check.Throws<DomeniaOperationException>(() => AdTransportPrerequisites.Validate(true, false, libraries, AppContext.BaseDirectory, null), "processus x86 refusé");
        Check.Throws<DomeniaOperationException>(() => AdTransportPrerequisites.Validate(false, true, libraries, AppContext.BaseDirectory, null), "hôte non Windows refusé");
        Check.Throws<DomeniaOperationException>(() => AdTransportPrerequisites.Validate(true, true, [libraries[0], libraries[0]], AppContext.BaseDirectory, null), "bibliothèque ADSI manquante");
        Check.Throws<DomeniaOperationException>(() => AdTransportPrerequisites.Validate(true, true, libraries, Path.Combine(AppContext.BaseDirectory, "autre"), null), "origine étrangère refusée");
        Check.Throws<DomeniaOperationException>(() => AdTransportPrerequisites.Validate(true, true, libraries, Path.Combine(AppContext.BaseDirectory, "autre"),
            Path.Combine(AppContext.BaseDirectory, "ailleurs")), "seul le framework du runtime courant est admis");
    }
}
