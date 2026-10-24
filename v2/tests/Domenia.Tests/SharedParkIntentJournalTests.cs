using System.Globalization;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using Domenia.Core;
using Domenia.Store;

namespace Domenia.Tests;

/// <summary>Behavioural tests of the durable private journal, using local Windows temporary files and fixed UTC fixtures.</summary>
internal static class SharedParkIntentJournalTests
{
    private static readonly CancellationToken None = CancellationToken.None;
    private static readonly DateTimeOffset T0 = new(2026, 10, 24, 11, 0, 0, TimeSpan.Zero);
    private static readonly DateTimeOffset Now = T0.AddMinutes(1);
    private const string Store = "store-01";
    private const string Domain = "DC=contoso,DC=local";
    private const string BatchPath = @"\\srv01\partage\park.tsv";
    private const string BatchId = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    private const string SessionId = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    private const string PlanId = "0123456789abcdef0123456789abcdef";
    private const string SqlitePath = @"C:\ProgramData\Domenia\backups\park.sqlite";
    private const string TsvPath = @"C:\ProgramData\Domenia\backups\park.tsv";
    private static readonly string PlanFp = Sha("plan");

    private static string Sha(string value) => Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(value)));

    private static SharedParkBatch MakeBatch(int mergedRows = 10) => new(
        BatchId, SessionId, 7, BatchPath, Store, Domain, 3, 2, true, false, Sha("rows"), Sha("local"), true,
        Sha("remote"), T0, T0.AddMinutes(10), mergedRows, 1234, Sha("proposed"), 4, 6);

    private static SharedParkIntent ValidIntent(string planId = PlanId, int mergedRows = 10,
        string sqlitePath = SqlitePath, string tsvPath = TsvPath)
    {
        var batch = MakeBatch(mergedRows);
        return new(1, planId, PlanFp, batch, SharedParkIdentity.Fingerprint(batch), Now,
            new(sqlitePath, 4096, Sha("sqlite-copy")), new(tsvPath, 2048, Sha("tsv-copy")));
    }

    private static string Id(int number) => number.ToString("x32", CultureInfo.InvariantCulture);
    private static string Root(TemporaryFolder folder) => folder.File("journal");
    private static string IntentFilePath(TemporaryFolder folder, string planId = PlanId) => Path.Combine(Root(folder), planId + ".sharedparkintent");
    private static SharedParkIntentJournal Journal(TemporaryFolder folder, TimeProvider? clock = null)
        => new(Root(folder), Store, Domain, clock ?? TestClock.Fixed(Now));

    private static async Task<SharedParkIntentJournal> Seed(TemporaryFolder folder)
    {
        var journal = Journal(folder);
        await journal.CreateAsync(ValidIntent(), None);
        Check.Equal(ValidIntent(), await Journal(folder).ReadAsync(PlanId, PlanFp, None), "précondition : une vraie intention privée se relit avant altération");
        return journal;
    }

    private static void CheckBytes(byte[] expected, string path, string message)
        => Check.True(expected.SequenceEqual(File.ReadAllBytes(path)), message);

    private static string DirectoryDacl(string path)
        => new DirectoryInfo(path).GetAccessControl(AccessControlSections.Access).GetSecurityDescriptorSddlForm(AccessControlSections.Access);

    private static string FileDacl(string path)
        => new FileInfo(path).GetAccessControl(AccessControlSections.Access).GetSecurityDescriptorSddlForm(AccessControlSections.Access);

    [Test]
    public static void The_journal_fixture_is_accepted_by_the_codec_at_the_creation_clock()
    {
        var intent = ValidIntent();
        Check.True(intent.Batch.CreatedAt <= intent.RecordedAt && intent.RecordedAt <= Now && Now < intent.Batch.ExpiresAt,
            "précondition : création, enregistrement, horloge et expiration forment une fenêtre valide");
        var bytes = SharedParkIntentDocument.Encode(intent, Store, Domain, PlanId, PlanFp, Now, None);
        Check.True(bytes.Length > 0 && bytes.Length < SharedParkIntentJournal.MaxDocumentBytes, "la fixture produit un document complet borné");
        Check.Equal(intent, SharedParkIntentDocument.Decode(bytes, Store, Domain, PlanId, PlanFp, Now, None), "la fixture passe réellement le codec avant les tests du journal");
    }

    [Test]
    public static async Task A_created_intention_persists_and_is_read_back_by_a_fresh_instance_after_expiry()
    {
        using var folder = new TemporaryFolder();
        var clock = TestClock.Fixed(Now);
        var intent = ValidIntent();
        await Journal(folder, clock).CreateAsync(intent, None);
        var bytes = File.ReadAllBytes(IntentFilePath(folder));
        Check.True(bytes.Length > 0, "un vrai fichier local privé porte l’intention");
        Check.Equal(intent, await Journal(folder, clock).ReadAsync(PlanId, PlanFp, None), "une instance neuve relit l’intention à l’identique");
        clock.Advance(TimeSpan.FromMinutes(11));
        Check.True(clock.GetUtcNow() > intent.Batch.ExpiresAt, "précondition : la relecture suivante est après expiration");
        Check.Equal(intent, await Journal(folder, clock).ReadAsync(PlanId, PlanFp, None), "la preuve reste relisible après expiration, jamais un droit de rejouer");
        CheckBytes(bytes, IntentFilePath(folder), "les relectures ne modifient pas la preuve durable");
    }

    [Test]
    public static async Task A_qualified_absence_returns_null_without_creating_missing_ancestors_or_root()
    {
        using var folder = new TemporaryFolder();
        var missingParent = folder.File("absent");
        var root = Path.Combine(missingParent, "journal");
        var journal = new SharedParkIntentJournal(root, Store, Domain, TestClock.Fixed(Now));
        Check.False(Directory.Exists(missingParent), "le constructeur ne crée pas de parent");
        Check.Null(await journal.ReadAsync(PlanId, PlanFp, None), "une absence sous des ancêtres locaux qualifiés est explicite");
        Check.False(Directory.Exists(missingParent), "la relecture ne crée ni parent ni journal");
        Check.Equal(0, Directory.EnumerateFileSystemEntries(folder.Path).Count(), "aucun fichier ni dossier n’a été créé");
    }

    [Test]
    public static async Task An_unknown_valid_plan_is_absent_in_an_existing_private_journal()
    {
        using var folder = new TemporaryFolder();
        var journal = await Seed(folder);
        var bytes = File.ReadAllBytes(IntentFilePath(folder));
        Check.Null(await journal.ReadAsync(Id(1), PlanFp, None), "un autre identifiant valide sans fichier retourne null");
        Check.Equal(1, Directory.EnumerateFileSystemEntries(Root(folder)).Count(), "l’absence n’ajoute même pas de verrou");
        CheckBytes(bytes, IntentFilePath(folder), "l’intention existante reste intacte");
    }

    [Test]
    public static async Task The_same_plan_is_refused_on_recreate_even_with_identical_content_and_its_bytes_are_untouched()
    {
        using var folder = new TemporaryFolder();
        var journal = await Seed(folder);
        var bytes = File.ReadAllBytes(IntentFilePath(folder));
        await Check.ThrowsAsync<InvalidDataException>(() => journal.CreateAsync(ValidIntent(), None), "le même plan est refusé, même contenu identique");
        CheckBytes(bytes, IntentFilePath(folder), "les octets existants n’ont pas été touchés");
        Check.Equal(ValidIntent(), await Journal(folder).ReadAsync(PlanId, PlanFp, None), "l’intention originale reste relisible");
    }

    [Test]
    public static async Task The_same_plan_with_different_valid_content_is_refused_without_overwrite()
    {
        using var folder = new TemporaryFolder();
        var journal = await Seed(folder);
        var bytes = File.ReadAllBytes(IntentFilePath(folder));
        var other = ValidIntent(mergedRows: 11);
        _ = SharedParkIntentDocument.Encode(other, Store, Domain, PlanId, PlanFp, Now, None);
        await Check.ThrowsAsync<InvalidDataException>(() => journal.CreateAsync(other, None), "un contenu différent mais valide pour le même plan est refusé");
        CheckBytes(bytes, IntentFilePath(folder), "l’autre contenu n’a pas remplacé les octets");
        Check.Equal(ValidIntent(), await Journal(folder).ReadAsync(PlanId, PlanFp, None), "la première intention subsiste intégralement");
    }

    [Test]
    public static async Task Two_instances_creating_the_same_plan_admit_exactly_one_creation()
    {
        using var folder = new TemporaryFolder();
        var ready = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var a = RaceCreate(Journal(folder), ValidIntent(), ready.Task, "existe déjà");
        var b = RaceCreate(Journal(folder), ValidIntent(), ready.Task, "existe déjà");
        ready.SetResult();
        var results = await Task.WhenAll(a, b);
        Check.Equal(1, results.Count(ok => ok), "une seule création est admise pour le même plan");
        Check.Equal(ValidIntent(), await Journal(folder).ReadAsync(PlanId, PlanFp, None), "le gagnant a effectivement écrit une preuve complète");
        Check.Equal(1, Directory.EnumerateFileSystemEntries(Root(folder)).Count(), "une seule intention subsiste, aucun verrou abandonné");
    }

    [Test]
    public static async Task Two_instances_creating_distinct_plans_both_succeed_and_each_document_is_read_back()
    {
        using var folder = new TemporaryFolder();
        var ia = ValidIntent(Id(1));
        var ib = ValidIntent(Id(2), mergedRows: 11);
        await Task.WhenAll(Journal(folder).CreateAsync(ia, None), Journal(folder).CreateAsync(ib, None));
        Check.Equal(ia, await Journal(folder).ReadAsync(ia.PlanId, PlanFp, None), "la première intention se relit");
        Check.Equal(ib, await Journal(folder).ReadAsync(ib.PlanId, PlanFp, None), "la seconde intention se relit");
        Check.Equal(2, Directory.EnumerateFileSystemEntries(Root(folder)).Count(), "deux intentions distinctes coexistent");
    }

    [Test]
    public static async Task A_document_beyond_64_kib_is_refused_and_preserved()
    {
        using var folder = new TemporaryFolder();
        var journal = await Seed(folder);
        var path = IntentFilePath(folder);
        var oversized = new byte[SharedParkIntentJournal.MaxDocumentBytes + 1];
        File.WriteAllBytes(path, oversized);
        Check.Equal((long)SharedParkIntentJournal.MaxDocumentBytes + 1, new FileInfo(path).Length, "précondition : le fichier dépasse effectivement 64 Kio");
        var error = await Check.ThrowsAsync<InvalidDataException>(() => journal.ReadAsync(PlanId, PlanFp, None), "le document trop grand est refusé");
        Check.Contains("64 Kio", error.Message, "le refus vient bien de la borne avant décodage");
        await Check.ThrowsAsync<InvalidDataException>(() => journal.CreateAsync(ValidIntent(), None), "la preuve trop grande bloque aussi la recréation");
        CheckBytes(oversized, path, "le refus préserve les octets hors borne");
    }

    [Test]
    public static async Task One_hundred_twenty_eight_intentions_are_the_hard_limit_then_admission_is_refused()
    {
        using var folder = new TemporaryFolder();
        var journal = Journal(folder);
        Check.Equal(128, SharedParkIntentJournal.MaxIntentions, "la limite contractuelle est 128");
        for (var i = 0; i < 128; i++) { await journal.CreateAsync(ValidIntent(Id(i)), None); }
        Check.Equal(128, Directory.EnumerateFileSystemEntries(Root(folder)).Count(), "128 créations ont réellement abouti");
        Check.Equal(ValidIntent(Id(127)), await Journal(folder).ReadAsync(Id(127), PlanFp, None), "la 128e intention est complète");
        await Check.ThrowsAsync<InvalidDataException>(() => journal.CreateAsync(ValidIntent(Id(128)), None), "la 129e est refusée sans éviction");
        Check.False(File.Exists(IntentFilePath(folder, Id(128))), "aucun fichier partiel de la 129e intention");
        Check.Equal(128, Directory.EnumerateFileSystemEntries(Root(folder)).Count(), "le refus n’ajoute ni ne retire d’entrée");
        Check.Equal(ValidIntent(Id(0)), await journal.ReadAsync(Id(0), PlanFp, None), "la plus ancienne intention reste conservée");
    }

    [Test]
    public static async Task Two_instances_racing_for_the_last_slot_cannot_exceed_128_intentions()
    {
        using var folder = new TemporaryFolder();
        var journal = Journal(folder);
        for (var i = 0; i < 127; i++) { await journal.CreateAsync(ValidIntent(Id(i)), None); }
        Check.Equal(127, Directory.EnumerateFileSystemEntries(Root(folder)).Count(), "précondition : il reste exactement une place");
        var ready = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var candidates = new[] { ValidIntent(Id(127)), ValidIntent(Id(128)) };
        var a = RaceCreate(Journal(folder), candidates[0], ready.Task, "128");
        var b = RaceCreate(Journal(folder), candidates[1], ready.Task, "128");
        ready.SetResult();
        var results = await Task.WhenAll(a, b);
        Check.Equal(1, results.Count(ok => ok), "une seule instance obtient la dernière place");
        Check.Equal(128, Directory.EnumerateFileSystemEntries(Root(folder)).Count(), "la concurrence ne dépasse pas la limite");
        for (var i = 0; i < candidates.Length; i++)
        {
            var reread = await Journal(folder).ReadAsync(candidates[i].PlanId, PlanFp, None);
            if (results[i]) { Check.Equal(candidates[i], reread, "le gagnant est complet et relisible"); }
            else { Check.Null(reread, "le perdant n’a créé aucun document partiel"); }
        }
    }

    [Test]
    public static async Task A_corrupted_document_is_never_an_absence_and_blocks_recreation_without_repair()
    {
        using var folder = new TemporaryFolder();
        var journal = await Seed(folder);
        var path = IntentFilePath(folder);
        var bytes = File.ReadAllBytes(path);
        bytes[bytes.Length / 2] = 0xFF;
        File.WriteAllBytes(path, bytes);
        await Check.ThrowsAsync<InvalidDataException>(() => journal.ReadAsync(PlanId, PlanFp, None), "un document corrompu lève, jamais une absence");
        await Check.ThrowsAsync<InvalidDataException>(() => journal.CreateAsync(ValidIntent(), None), "un document corrompu bloque la recréation");
        CheckBytes(bytes, path, "le document corrompu est conservé exactement, sans réparation");
    }

    [Test]
    public static async Task A_partial_document_blocks_both_read_and_recreation_without_losing_its_bytes()
    {
        using var folder = new TemporaryFolder();
        var journal = await Seed(folder);
        var path = IntentFilePath(folder);
        var full = File.ReadAllBytes(path);
        var partial = full[..(full.Length / 2)];
        File.WriteAllBytes(path, partial);
        await Check.ThrowsAsync<InvalidDataException>(() => journal.ReadAsync(PlanId, PlanFp, None), "un document partiel lève, jamais une absence");
        await Check.ThrowsAsync<InvalidDataException>(() => journal.CreateAsync(ValidIntent(), None), "un fichier partiel n’est jamais recréé");
        CheckBytes(partial, path, "les octets partiels sont conservés tels quels");
    }

    [Test]
    public static async Task A_wrong_plan_fingerprint_is_refused_for_an_existing_document()
    {
        using var folder = new TemporaryFolder();
        var journal = await Seed(folder);
        await Check.ThrowsAsync<InvalidDataException>(() => journal.ReadAsync(PlanId, Sha("autre-plan"), None), "une autre empreinte de plan est refusée");
        Check.Equal(ValidIntent(), await journal.ReadAsync(PlanId, PlanFp, None), "la même preuve se relit avec l’empreinte attendue");
    }

    [Test]
    public static async Task Wrong_expected_store_or_domain_is_refused_on_read()
    {
        using var folder = new TemporaryFolder();
        var journal = await Seed(folder);
        await Check.ThrowsAsync<InvalidDataException>(() => new SharedParkIntentJournal(Root(folder), "autre-magasin", Domain, TestClock.Fixed(Now)).ReadAsync(PlanId, PlanFp, None), "un magasin inattendu est refusé");
        await Check.ThrowsAsync<InvalidDataException>(() => new SharedParkIntentJournal(Root(folder), Store, "DC=autre", TestClock.Fixed(Now)).ReadAsync(PlanId, PlanFp, None), "un domaine inattendu est refusé");
        Check.Equal(ValidIntent(), await journal.ReadAsync(PlanId, PlanFp, None), "le contexte correct relit toujours la preuve");
    }

    [Test]
    public static async Task A_pre_cancelled_token_creates_nothing_before_any_io()
    {
        using var folder = new TemporaryFolder();
        var journal = Journal(folder);
        using var cancelled = new CancellationTokenSource();
        cancelled.Cancel();
        await Check.ThrowsAsync<OperationCanceledException>(() => journal.CreateAsync(ValidIntent(), cancelled.Token), "une annulation préalable n’écrit rien");
        await Check.ThrowsAsync<OperationCanceledException>(() => journal.ReadAsync(PlanId, PlanFp, cancelled.Token), "une annulation préalable ne lit rien");
        Check.Equal(0, Directory.EnumerateFileSystemEntries(folder.Path).Count(), "aucun dossier ni fichier créé par les opérations pré-annulées");
    }

    [Test]
    public static void Invalid_local_roots_are_refused_lexically_without_touching_the_disk()
    {
        using var folder = new TemporaryFolder();
        var bad = new[]
        {
            "journal", @"\\srv\share\journal", @"\\?\C:\journal", @"C:\", folder.Path + @"\..\journal",
            folder.File("journal:hidden"), folder.File("jour\nnal"), folder.File("journal."), folder.File("NUL"), string.Empty,
        };
        foreach (var root in bad)
        {
            Check.Throws<InvalidDataException>(() => new SharedParkIntentJournal(root, Store, Domain, TestClock.Fixed(Now)), "racine invalide refusée : " + root);
        }
        Check.Equal(0, Directory.EnumerateFileSystemEntries(folder.Path).Count(), "aucune racine invalide créée");
    }

    [Test]
    public static async Task A_file_as_root_or_existing_ancestor_is_never_treated_as_absence()
    {
        using var folder = new TemporaryFolder();
        var obstruction = folder.File("fichier");
        var bytes = Encoding.UTF8.GetBytes("fichier existant à préserver");
        File.WriteAllBytes(obstruction, bytes);
        foreach (var root in new[] { obstruction, Path.Combine(obstruction, "absent", "journal") })
        {
            var journal = new SharedParkIntentJournal(root, Store, Domain, TestClock.Fixed(Now));
            await Check.ThrowsAsync<InvalidDataException>(() => journal.ReadAsync(PlanId, PlanFp, None), "un fichier dans la chaîne de dossiers n’est pas une absence");
            await Check.ThrowsAsync<InvalidDataException>(() => journal.CreateAsync(ValidIntent(), None), "aucune création sur ou sous un fichier");
            CheckBytes(bytes, obstruction, "l’obstacle fichier reste intact");
        }
        Check.Equal(1, Directory.EnumerateFileSystemEntries(folder.Path).Count(), "rien n’a été ajouté à côté de l’obstacle");
    }

    [Test]
    public static async Task A_reparse_root_or_ancestor_is_refused_on_read_and_create()
    {
        using var folder = new TemporaryFolder();
        var real = folder.File("reel");
        Directory.CreateDirectory(real);
        var link = folder.File("lien");
        Directory.CreateSymbolicLink(link, real);
        try
        {
            Check.True((File.GetAttributes(link) & FileAttributes.ReparsePoint) != 0, "précondition : le lien est un vrai reparse point");
            foreach (var root in new[] { link, Path.Combine(link, "absent", "journal") })
            {
                var journal = new SharedParkIntentJournal(root, Store, Domain, TestClock.Fixed(Now));
                await Check.ThrowsAsync<InvalidDataException>(() => journal.ReadAsync(PlanId, PlanFp, None), "le reparse point ne devient pas une absence");
                await Check.ThrowsAsync<InvalidDataException>(() => journal.CreateAsync(ValidIntent(), None), "le reparse point est refusé avant création");
            }
            Check.Equal(0, Directory.EnumerateFileSystemEntries(real).Count(), "la cible du lien reste vide");
        }
        finally { Directory.Delete(link); }
    }

    [Test]
    public static async Task The_root_and_intention_have_private_dacls_and_the_external_parent_is_unchanged()
    {
        using var folder = new TemporaryFolder();
        var parentBefore = DirectoryDacl(folder.Path);
        await Seed(folder);
        CheckPrivateAcl(new DirectoryInfo(Root(folder)).GetAccessControl(AccessControlSections.Access), directory: true);
        CheckPrivateAcl(new FileInfo(IntentFilePath(folder)).GetAccessControl(AccessControlSections.Access), directory: false);
        Check.Equal(parentBefore, DirectoryDacl(folder.Path), "la DACL du parent extérieur n’a pas été modifiée");
    }

    [Test]
    public static async Task A_preexisting_directory_with_an_incompatible_dacl_is_refused_without_reprotection()
    {
        using var folder = new TemporaryFolder();
        var root = Root(folder);
        Directory.CreateDirectory(root);
        var security = new DirectorySecurity();
        security.SetAccessRuleProtection(true, false);
        foreach (var principal in PrivatePrincipals())
        {
            security.AddAccessRule(new FileSystemAccessRule(principal, FileSystemRights.FullControl,
                InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
        }
        security.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(WellKnownSidType.WorldSid, null), FileSystemRights.Read, AccessControlType.Allow));
        new DirectoryInfo(root).SetAccessControl(security);
        Check.True(new DirectoryInfo(root).GetAccessControl(AccessControlSections.Access).AreAccessRulesProtected, "précondition : DACL protégée mais ouverte à un principal supplémentaire");
        var before = DirectoryDacl(root);
        var parentBefore = DirectoryDacl(folder.Path);
        var journal = Journal(folder);
        await Check.ThrowsAsync<IOException>(() => journal.ReadAsync(PlanId, PlanFp, None), "la protection incompatible interdit de conclure à l’absence");
        await Check.ThrowsAsync<IOException>(() => journal.CreateAsync(ValidIntent(), None), "le dossier préexistant n’est pas reprotégé silencieusement");
        Check.Equal(before, DirectoryDacl(root), "la DACL incompatible demeure strictement inchangée");
        Check.Equal(parentBefore, DirectoryDacl(folder.Path), "le parent reste inchangé");
        Check.Equal(0, Directory.EnumerateFileSystemEntries(root).Count(), "aucun verrou ni document écrit dans le dossier refusé");
    }

    [Test]
    public static async Task A_changed_root_dacl_is_rechecked_for_existing_and_absent_plans_without_mutation()
    {
        using var folder = new TemporaryFolder();
        var journal = await Seed(folder);
        var bytes = File.ReadAllBytes(IntentFilePath(folder));
        var rootInfo = new DirectoryInfo(Root(folder));
        var security = rootInfo.GetAccessControl(AccessControlSections.Access);
        security.SetAccessRuleProtection(false, true);
        rootInfo.SetAccessControl(security);
        Check.False(rootInfo.GetAccessControl(AccessControlSections.Access).AreAccessRulesProtected, "précondition : le dossier a perdu sa protection contre l’héritage");
        var before = DirectoryDacl(Root(folder));
        await Check.ThrowsAsync<IOException>(() => journal.ReadAsync(PlanId, PlanFp, None), "la DACL du root est relue même sur l’instance déjà utilisée");
        await Check.ThrowsAsync<IOException>(() => Journal(folder).ReadAsync(Id(1), PlanFp, None), "une ACL incompatible ne vaut jamais absence");
        await Check.ThrowsAsync<IOException>(() => journal.CreateAsync(ValidIntent(Id(1)), None), "une création refuse aussi le root modifié");
        Check.Equal(before, DirectoryDacl(Root(folder)), "aucune re-protection du root altéré");
        CheckBytes(bytes, IntentFilePath(folder), "la preuve reste intacte");
        Check.False(File.Exists(IntentFilePath(folder, Id(1))), "aucune nouvelle intention créée");
    }

    [Test]
    public static async Task A_changed_intention_dacl_is_rechecked_on_read_without_repair()
    {
        using var folder = new TemporaryFolder();
        var journal = await Seed(folder);
        var path = IntentFilePath(folder);
        var bytes = File.ReadAllBytes(path);
        var file = new FileInfo(path);
        var security = file.GetAccessControl(AccessControlSections.Access);
        security.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(WellKnownSidType.WorldSid, null), FileSystemRights.Read, AccessControlType.Allow));
        file.SetAccessControl(security);
        var before = FileDacl(path);
        Check.True(file.GetAccessControl(AccessControlSections.Access).GetAccessRules(true, true, typeof(SecurityIdentifier))
            .Cast<FileSystemAccessRule>().Any(rule => rule.IdentityReference.Value == new SecurityIdentifier(WellKnownSidType.WorldSid, null).Value
                && rule.AccessControlType == AccessControlType.Allow), "précondition : la DACL relue du fichier autorise bien Everyone");
        await Check.ThrowsAsync<IOException>(() => journal.ReadAsync(PlanId, PlanFp, None), "une DACL de fichier devenue publique est refusée");
        await Check.ThrowsAsync<IOException>(() => Journal(folder).ReadAsync(PlanId, PlanFp, None), "une instance neuve relit aussi la DACL du fichier");
        Check.Equal(before, FileDacl(path), "aucune réparation de la DACL fichier");
        CheckBytes(bytes, path, "aucune modification des octets du fichier refusé");
    }

    [Test]
    public static async Task Declared_backup_paths_are_never_created_or_required_by_the_journal()
    {
        using var folder = new TemporaryFolder();
        var absentDir = folder.File("copies-absentes");
        var sqlitePath = Path.Combine(absentDir, "park.sqlite");
        var tsvPath = Path.Combine(absentDir, "park.tsv");
        Check.False(Directory.Exists(absentDir), "précondition : les copies sont sous un chemin temporaire unique inexistant");
        var intent = ValidIntent(sqlitePath: sqlitePath, tsvPath: tsvPath);
        await Journal(folder).CreateAsync(intent, None);
        Check.Equal(intent, await Journal(folder).ReadAsync(PlanId, PlanFp, None), "l’intention déclarant des copies inexistantes reste relisible");
        Check.False(Directory.Exists(absentDir), "le journal n’a pas créé le dossier des copies déclarées");
        Check.False(File.Exists(sqlitePath) || File.Exists(tsvPath), "ces références ne sont pas des copies attestées");
    }

    [Test]
    public static async Task Unexpected_extension_invalid_plan_name_and_directory_entries_block_admission_without_cleanup()
    {
        foreach (var entry in new[] { "parasite.txt", "ZZ.sharedparkintent", Id(1) + ".sharedparkintent" })
        {
            using var folder = new TemporaryFolder();
            var journal = await Seed(folder);
            var original = File.ReadAllBytes(IntentFilePath(folder));
            var path = Path.Combine(Root(folder), entry);
            var isDirectory = entry.StartsWith(Id(1), StringComparison.Ordinal);
            if (isDirectory) { Directory.CreateDirectory(path); }
            else { File.WriteAllText(path, "entrée à conserver"); }
            CheckPrivateAcl(new DirectoryInfo(Root(folder)).GetAccessControl(AccessControlSections.Access), directory: true);
            await Check.ThrowsAsync<InvalidDataException>(() => journal.CreateAsync(ValidIntent(Id(2)), None), "l’entrée inattendue bloque l’admission : " + entry);
            Check.True(isDirectory ? Directory.Exists(path) : File.ReadAllText(path) == "entrée à conserver", "l’entrée parasite n’est pas supprimée ni réécrite");
            Check.False(File.Exists(IntentFilePath(folder, Id(2))), "aucune intention candidate créée");
            CheckBytes(original, IntentFilePath(folder), "l’intention valide précédente reste intacte");
        }
    }

    [Test]
    public static async Task A_reparse_intention_entry_is_refused_on_read_and_admission_without_touching_its_target()
    {
        using var folder = new TemporaryFolder();
        var journal = await Seed(folder);
        var original = File.ReadAllBytes(IntentFilePath(folder));
        var link = IntentFilePath(folder, Id(1));
        File.CreateSymbolicLink(link, IntentFilePath(folder));
        try
        {
            Check.True((File.GetAttributes(link) & FileAttributes.ReparsePoint) != 0, "précondition : le faux document est un reparse point");
            var readError = await Check.ThrowsAsync<InvalidDataException>(() => journal.ReadAsync(Id(1), PlanFp, None), "le document redirigé est refusé");
            Check.Contains("redirigé", readError.Message, "le refus vient du reparse point, avant le décodage du plan cible");
            await Check.ThrowsAsync<InvalidDataException>(() => journal.CreateAsync(ValidIntent(Id(2)), None), "une entrée redirigée bloque l’admission");
            Check.True((File.GetAttributes(link) & FileAttributes.ReparsePoint) != 0, "le lien refusé est conservé");
            Check.False(File.Exists(IntentFilePath(folder, Id(2))), "aucune intention candidate créée");
            CheckBytes(original, IntentFilePath(folder), "la cible privée du lien reste intacte");
        }
        finally { File.Delete(link); }
    }

    [Test]
    public static async Task A_preexisting_unheld_lock_is_not_adopted_stolen_or_deleted()
    {
        using var folder = new TemporaryFolder();
        var journal = await Seed(folder);
        var path = Path.Combine(Root(folder), "journal.lock");
        var bytes = Encoding.UTF8.GetBytes("verrou préexistant sans handle détenu");
        File.WriteAllBytes(path, bytes);
        var before = FileDacl(path);
        var error = await Check.ThrowsAsync<IOException>(() => journal.CreateAsync(ValidIntent(Id(1)), None), "un verrou préexistant fermé reste indisponible");
        Check.Contains("Verrou", error.Message, "le refus vient du verrou d’admission");
        CheckBytes(bytes, path, "le verrou préexistant n’a été ni volé, ni supprimé, ni tronqué");
        Check.Equal(before, FileDacl(path), "la DACL du verrou préexistant n’est pas changée");
        Check.False(File.Exists(IntentFilePath(folder, Id(1))), "aucune intention écrite malgré le verrou existant");
        Check.Equal(ValidIntent(), await journal.ReadAsync(PlanId, PlanFp, None), "la preuve précédente reste relisible");
    }

    [Test]
    public static async Task An_exclusively_held_document_is_an_io_error_and_becomes_readable_when_released()
    {
        using var folder = new TemporaryFolder();
        var journal = await Seed(folder);
        var path = IntentFilePath(folder);
        var bytes = File.ReadAllBytes(path);
        using (var held = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.None))
        {
            Check.Equal((long)bytes.Length, held.Length, "précondition : le vrai document est détenu exclusivement");
            await Check.ThrowsAsync<IOException>(() => journal.ReadAsync(PlanId, PlanFp, None), "une erreur d’ouverture ne vaut pas absence");
        }
        Check.Equal(ValidIntent(), await journal.ReadAsync(PlanId, PlanFp, None), "la preuve se relit dès que le handle est libéré");
        CheckBytes(bytes, path, "le refus d’ouverture n’a pas modifié la preuve");
    }

    [Test]
    public static async Task Invalid_plan_id_or_fingerprint_is_refused_even_when_the_root_is_absent()
    {
        using var folder = new TemporaryFolder();
        var journal = Journal(folder);
        await Check.ThrowsAsync<InvalidDataException>(() => journal.ReadAsync("ZZ", PlanFp, None), "un identifiant libre ne devient pas un chemin");
        await Check.ThrowsAsync<InvalidDataException>(() => journal.ReadAsync(PlanId, "ZZ", None), "une empreinte invalide ne devient pas une absence");
        Check.Equal(0, Directory.EnumerateFileSystemEntries(folder.Path).Count(), "les identités invalides ne créent rien");
    }

    private static async Task<bool> RaceCreate(SharedParkIntentJournal journal, SharedParkIntent intent, Task start, string refusalReason)
    {
        await start;
        try { await journal.CreateAsync(intent, None); return true; }
        catch (InvalidDataException error)
        {
            Check.Contains(refusalReason, error.Message, "le perdant est refusé pour la raison attendue");
            return false;
        }
    }

    private static SecurityIdentifier[] PrivatePrincipals()
    {
        using var identity = WindowsIdentity.GetCurrent();
        return [identity.User!, new(WellKnownSidType.LocalSystemSid, null), new(WellKnownSidType.BuiltinAdministratorsSid, null)];
    }

    private static void CheckPrivateAcl(FileSystemSecurity security, bool directory)
    {
        var expected = PrivatePrincipals().Select(p => p.Value).ToHashSet(StringComparer.Ordinal);
        var rules = security.GetAccessRules(true, true, typeof(SecurityIdentifier)).Cast<FileSystemAccessRule>().ToArray();
        var inheritance = directory ? InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit : InheritanceFlags.None;
        Check.True(security.AreAccessRulesProtected, "DACL protégée de l’héritage");
        Check.True(expected.SetEquals(rules.Select(r => r.IdentityReference.Value)) && rules.Length == expected.Count, "utilisateur, SYSTEM et Administrateurs seulement");
        Check.True(rules.All(r => !r.IsInherited && r.AccessControlType == AccessControlType.Allow && r.FileSystemRights == FileSystemRights.FullControl
            && r.InheritanceFlags == inheritance && r.PropagationFlags == PropagationFlags.None), "droits exacts relus");
    }
}
