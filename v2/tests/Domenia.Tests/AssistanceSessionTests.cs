using System.Collections.Immutable;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Domenia.Bridge;
using Domenia.Core;
using Domenia.Simulation;
using Domenia.Store;

namespace Domenia.Tests;

/// <summary>Source whose session can change while the application runs: another account, another domain, a reconnection.</summary>
internal sealed class SwitchingSource(IDirectorySource inner) : IDirectorySource
{
    public long Epoch { get; set; }

    public string? Login { get; set; }

    public string? RootDn { get; set; }

    public DirectorySourceKind Kind => inner.Kind;

    public async Task<SessionSnapshot> GetSessionAsync(CancellationToken cancellationToken)
    {
        var session = await inner.GetSessionAsync(cancellationToken).ConfigureAwait(false);
        return session with
        {
            Epoch = Epoch,
            Account = session.Account with { Login = Login ?? session.Account.Login },
            Domain = RootDn is null || session.Domain is null ? session.Domain : session.Domain with { RootDn = RootDn },
        };
    }

    public Task<DirectoryState> ReadLocalAsync(CancellationToken cancellationToken) => inner.ReadLocalAsync(cancellationToken);

    public Task<DirectoryState> RefreshAsync(MeasureFamily family, ScopeSelection? scope, CancellationToken cancellationToken) => inner.RefreshAsync(family, scope, cancellationToken);
}

/// <summary>Document store that writes nothing and waits for its release (busy and timeout tests).</summary>
internal sealed class SlowDocumentStore : IDocumentStore
{
    public TaskCompletionSource Release { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);

    public bool Persistent => true;

    public string? Folder => @"C:\Exports";

    public async Task<SavedDocument> SaveFileAsync(string name, ReadOnlyMemory<byte> bytes, CancellationToken cancellationToken)
    {
        await Release.Task.WaitAsync(cancellationToken).ConfigureAwait(false);
        return new SavedDocument(true, @"C:\Exports\" + name, name, @"C:\Exports");
    }

    public Task<SavedDocument> SaveFolderAsync(string name, IReadOnlyList<DocumentFile> files, CancellationToken cancellationToken) =>
        Task.FromResult(new SavedDocument(true, @"C:\Exports\" + name, name, @"C:\Exports"));

    public Task<bool> RevealAsync(string name, CancellationToken cancellationToken) => Task.FromResult(true);
}

/// <summary>
/// Isolation of the Assistance by session (TRV-185), its scheduler, its documents (real files on a temporary folder), the
/// command line of the offline dossier, its perimeters and the pseudonyms of the documents (docs/ops/assistance.md).
/// </summary>
internal static class AssistanceSessionTests
{
    private static string Args(object value) => JsonSerializer.Serialize(value);

    private static string ErrorCode(BridgeResponse response)
    {
        Check.Equal("error", response.Kind, "erreur attendue");
        return response.Error!.Code;
    }

    private static (EngineContext Context, OperationRegistry Registry, SwitchingSource Source, SimulatedDirectorySource Simulated) Compose(FixedTimeProvider? fixedClock = null)
    {
        var clock = fixedClock ?? TestClock.Fixed();
        var simulated = new SimulatedDirectorySource(SimulationOptions.Default with { Latency = SimulationLatency.None }, clock);
        var source = new SwitchingSource(simulated);
        var context = new EngineContext(SimulatedBridge.Decision, source, new MemoryPreferenceStore(), clock, new RecordingJournal(),
            ScreenReaders.Discover(simulated, [typeof(SimulatedDirectorySource).Assembly]));
        return (context, OperationModules.CreateRegistry(context, [new AssistanceOperations()]), source, simulated);
    }

    private static async Task<BridgeResponse> CallAsync(OperationRegistry registry, string op, string args = "{}")
    {
        var responses = new List<BridgeResponse>();
        var dispatcher = new BridgeDispatcher(registry, responses.Add, AdmissionGuards.ReadOnlySimulation);
        await dispatcher.HandleAsync("{\"id\":\"t\",\"op\":\"" + op + "\",\"args\":" + args + "}", CancellationToken.None).ConfigureAwait(false);
        return responses.Single(r => r.Kind != "event");
    }

    private static JsonElement Json(BridgeResponse response) => SimulatedBridge.Json(response);

    // ---------------------------------------------------------------- TRV-185

    [Test]
    public static async Task The_workshop_never_crosses_sessions_not_even_a_reconnection_with_the_same_account()
    {
        var clock = TestClock.Fixed();
        var (context, registry, source, simulated) = Compose(clock);
        using (context)
        {
            var dn = simulated.CurrentDirectory.Users.First(u => u.SamAccountName == "c.bernard").DistinguishedName;
            context.Journal.Add(new JournalEntry(clock.GetUtcNow(), "Accès refusé (0x80070005) à WMI sur PC-ANCIEN-0001", Tone.Warn));
            await CallAsync(registry, "assistance.subject.read", Args(new { dn }));
            await CallAsync(registry, "assistance.pin.add", Args(new { dn }));
            await CallAsync(registry, "assistance.capture.take", Args(new { slot = "a", dn }));
            var first = Json(await CallAsync(registry, "assistance.workshop.get"));
            Check.Equal(1, first.GetProperty("pins").GetArrayLength(), "repère de la session");
            var token = first.GetProperty("session").GetString()!;
            Check.Equal(16, token.Length, "empreinte de session, sans rien de lisible");
            Check.False(token.Contains("bernard", StringComparison.OrdinalIgnoreCase), "aucun compte dans l’empreinte");

            Check.True(first.GetProperty("incidents").GetProperty("items").EnumerateArray().Any(i => i.GetProperty("detail").GetString()!.Contains("PC-ANCIEN-0001", StringComparison.Ordinal)), "incident de la session");
            clock.Advance(TimeSpan.FromSeconds(1));
            source.Epoch = 1;
            var reconnected = Json(await CallAsync(registry, "assistance.workshop.get"));
            Check.False(reconnected.GetProperty("incidents").GetProperty("items").EnumerateArray().Any(i => i.GetProperty("detail").GetString()!.Contains("PC-ANCIEN-0001", StringComparison.Ordinal)),
                "l’incident de l’ancienne session n’est pas recollecté");
            Check.Equal(0, reconnected.GetProperty("pins").GetArrayLength(), "reconnexion avec le même compte : atelier vidé");
            Check.Equal(JsonValueKind.Null, reconnected.GetProperty("a").ValueKind, "capture oubliée");
            Check.False(token == reconnected.GetProperty("session").GetString(), "nouvelle empreinte");
            Check.Equal(AssistanceErrors.NotRead, ErrorCode(await CallAsync(registry, "assistance.subject.analyse", Args(new { dn }))), "lecture de l’autre session oubliée");

            await CallAsync(registry, "assistance.subject.read", Args(new { dn }));
            await CallAsync(registry, "assistance.pin.add", Args(new { dn }));
            source.Login = @"EXAMPLE\autre";
            Check.Equal(0, Json(await CallAsync(registry, "assistance.workshop.get")).GetProperty("pins").GetArrayLength(), "autre compte : atelier vidé");
            await CallAsync(registry, "assistance.subject.read", Args(new { dn }));
            await CallAsync(registry, "assistance.pin.add", Args(new { dn }));
            source.RootDn = "DC=autre,DC=local";
            Check.Equal(0, Json(await CallAsync(registry, "assistance.workshop.get")).GetProperty("pins").GetArrayLength(), "autre domaine : atelier vidé");
            var poll = Json(await CallAsync(registry, "assistance.workshop.poll"));
            Check.True(poll.EnumerateObject().Select(p => p.Name).SequenceEqual(["revision", "session", "incidents", "running", "queued"]), "forme du relevé d’une seconde");
        }
    }

    [Test]
    public static async Task An_answer_started_in_another_session_is_ignored()
    {
        var (context, _, source, simulated) = Compose();
        using (context)
        {
            var workshop = SupportWorkshop.From(context);
            var started = await workshop.SyncAsync(CancellationToken.None);
            source.Epoch = 7;
            var refusal = await Check.ThrowsAsync<DomeniaOperationException>(
                () => workshop.EnsureSameSessionAsync(started, AssistanceErrors.DossierStaleMessage, CancellationToken.None), "réponse tardive");
            Check.Equal(AssistanceErrors.SessionChanged, refusal.Code, "code de la réponse ignorée");
            Check.Contains("Aucun dossier n’est créé", refusal.Message, "le dossier n’est pas écrit");
            Check.True(simulated.CurrentDirectory.Users.Length > 0, "annuaire intact");
        }
    }

    [Test]
    public static void A_pin_of_another_scope_is_refused()
    {
        var (context, _, _, simulated) = Compose();
        using (context)
        {
            var workshop = SupportWorkshop.From(context);
            workshop.SyncAsync(CancellationToken.None).GetAwaiter().GetResult();
            var user = simulated.CurrentDirectory.Users.First();
            var record = new SubjectRecord(user.DistinguishedName, user.ObjectGuid, AssistanceSubject.User, user.Cn, user.SamAccountName, "", new Dictionary<string, IReadOnlyList<object?>>(),
                true, null, [], [], [], TestClock.Reference);
            var foreign = SupportSnapshots.Create(record.Properties, "dc=autre,dc=local", record.Dn, record.Name, "user", SnapshotSource.Live, TestClock.Reference, TestClock.Reference, true);
            workshop.Remember(record, foreign);
            var refusal = Check.Throws<DomeniaOperationException>(() => workshop.Pin(record.Dn), "repère d’un autre périmètre");
            Check.Equal(AssistanceErrors.PinOtherScope, refusal.Code, "code du refus");
        }
    }

    // ---------------------------------------------------------------- scheduler

    [Test]
    public static async Task The_scheduler_reads_one_object_at_a_time_counts_and_refuses_when_full()
    {
        using var scheduler = new AssistanceScheduler();
        var gate = new TaskCompletionSource<int>(TaskCreationOptions.RunContinuationsAsynchronously);
        var first = scheduler.RunAsync("CN=A", _ => gate.Task, CancellationToken.None);
        var second = scheduler.RunAsync("cn=a", _ => Task.FromResult(2), CancellationToken.None);
        await Task.Delay(50);
        Check.Equal((1, 1), scheduler.Counts, "même objet : la seconde lecture attend la première (casse ignorée)");
        var other = await scheduler.RunAsync("CN=B", _ => Task.FromResult(3), CancellationToken.None);
        Check.Equal(3, other, "un autre objet passe pendant ce temps");
        gate.SetResult(1);
        Check.Equal(1, await first, "première lecture");
        Check.Equal(2, await second, "seconde lecture ensuite");
        Check.Equal((0, 0), scheduler.Counts, "plus rien en cours");

        var block = new TaskCompletionSource<int>(TaskCreationOptions.RunContinuationsAsynchronously);
        var waiting = Enumerable.Range(0, AssistanceScheduler.MaxRunning + AssistanceScheduler.MaxQueued)
            .Select(n => scheduler.RunAsync("CN=" + (n % 2 == 0 ? "X" : "Y" + n), _ => block.Task, CancellationToken.None)).ToList();
        await Task.Delay(50);
        var busy = await Check.ThrowsAsync<DomeniaOperationException>(() => scheduler.RunAsync("CN=Z", _ => Task.FromResult(0), CancellationToken.None), "moteur saturé");
        Check.Equal(AssistanceErrors.EngineBusy, busy.Code, "rien n’a été lancé");
        Check.Contains("Rien n’a été lancé", busy.Message, "dit à l’opérateur");
        block.SetResult(0);
        await Task.WhenAll(waiting);
        Check.Equal((0, 0), scheduler.Counts, "file vidée");
    }

    [Test]
    public static async Task Engine_state_counts_the_reads_of_the_assistance_and_the_incidents_of_the_view()
    {
        var bridge = new SimulatedBridge();
        var scheduler = AssistanceScheduler.From(bridge.Context);
        var gate = new TaskCompletionSource<int>(TaskCreationOptions.RunContinuationsAsynchronously);
        var pending = scheduler.RunAsync("CN=Lecture", _ => gate.Task, CancellationToken.None);
        var state = SimulatedBridge.Json(await bridge.CallAsync("assistance.engine.state"));
        Check.Equal(1, state.GetProperty("readsRunning").GetInt32(), "lecture de l’Assistance comptée");
        Check.Contains("1" + FrenchText.Nbsp + "lecture en cours", state.GetProperty("summary").GetString(), "phrase du panneau");
        var workshop = SimulatedBridge.Json(await bridge.CallAsync("assistance.workshop.get"));
        var items = workshop.GetProperty("incidents").GetProperty("items").EnumerateArray().ToList();
        Check.Equal(items.Count(i => i.GetProperty("tone").GetString() == "alert"), state.GetProperty("incidentErrors").GetInt32(), "mêmes erreurs que la vue Incidents");
        Check.Equal(items.Count(i => i.GetProperty("tone").GetString() == "warn"), state.GetProperty("incidentWarnings").GetInt32(), "mêmes avertissements que la vue Incidents");
        gate.SetResult(0);
        await pending;
    }

    [Test]
    public static async Task A_refusal_of_the_screen_is_journaled_and_explained_in_incidents()
    {
        // ASS-006: every refusal of an operation of the screen reaches the journal of the session, then the Incidents view.
        var bridge = new SimulatedBridge();
        var dn = bridge.Source.CurrentDirectory.Users.First().DistinguishedName;
        Check.Equal(AssistanceErrors.NotRead, ErrorCode(await bridge.CallAsync("assistance.capture.take", Args(new { slot = "a", dn }))), "capture d’une fiche non lue refusée");
        Check.True(bridge.Context.Journal.Snapshot().Any(e => e.Label.Contains("refus " + AssistanceErrors.NotRead, StringComparison.Ordinal)), "refus inscrit au journal de la session");
        var workshop = SimulatedBridge.Json(await bridge.CallAsync("assistance.workshop.get"));
        Check.True(workshop.GetProperty("incidents").GetProperty("items").EnumerateArray()
            .Any(i => (i.GetProperty("detail").GetString() ?? "").Contains(AssistanceErrors.NotRead, StringComparison.Ordinal)), "refus expliqué dans la vue Incidents");
    }

    [Test]
    public static async Task A_capture_or_a_pin_is_refused_while_the_same_object_is_read()
    {
        // Domenia 1 ASS-003, ASS-004: no capture during the load of the same object (the previous read would be frozen).
        var bridge = new SimulatedBridge();
        var dn = bridge.Source.CurrentDirectory.Users.First().DistinguishedName;
        SimulatedBridge.Json(await bridge.CallAsync("assistance.subject.read", Args(new { dn })));
        var gate = new TaskCompletionSource<int>(TaskCreationOptions.RunContinuationsAsynchronously);
        var reading = AssistanceScheduler.From(bridge.Context).RunAsync(dn, _ => gate.Task, CancellationToken.None);
        Check.Equal(AssistanceErrors.SubjectReading, ErrorCode(await bridge.CallAsync("assistance.capture.take", Args(new { slot = "a", dn }))), "capture refusée pendant la lecture");
        Check.Equal(AssistanceErrors.SubjectReading, ErrorCode(await bridge.CallAsync("assistance.pin.add", Args(new { dn }))), "repère refusé pendant la lecture");
        gate.SetResult(0);
        await reading;
        Check.Equal("result", (await bridge.CallAsync("assistance.capture.take", Args(new { slot = "a", dn }))).Kind, "capture acceptée après la lecture");
    }

    // ---------------------------------------------------------------- documents

    [Test]
    public static async Task Documents_are_new_files_never_replaced_and_leave_no_temporary_file()
    {
        var folder = Path.Combine(Path.GetTempPath(), "domenia-tests-" + Guid.NewGuid().ToString("N"));
        try
        {
            var store = new FileDocumentStore(folder, new RecordingJournal(), static (_, _) => { });
            var first = await store.SaveFileAsync("Domenia-Ticket.txt", Encoding.UTF8.GetBytes("un"), CancellationToken.None);
            var second = await store.SaveFileAsync("Domenia-Ticket.txt", Encoding.UTF8.GetBytes("deux"), CancellationToken.None);
            Check.Equal("Domenia-Ticket.txt", first.Name, "premier nom");
            Check.Equal("Domenia-Ticket-2.txt", second.Name, "nom pris : « -2 », rien n’est remplacé");
            Check.Equal("un", await File.ReadAllTextAsync(first.Path!), "premier document intact");
            var dossier = await store.SaveFolderAsync("Domenia-Diagnostic-PC-1", [new DocumentFile("etat.json", Encoding.UTF8.GetBytes("{}")), new DocumentFile("SHA256SUMS.txt", [])], CancellationToken.None);
            Check.True(File.Exists(Path.Combine(dossier.Path!, "etat.json")), "dossier écrit d’un bloc");
            Check.False(Directory.EnumerateFileSystemEntries(folder).Any(p => Path.GetFileName(p).StartsWith(".domenia-", StringComparison.Ordinal)), "aucun fichier temporaire laissé");
            Check.Throws<ArgumentException>(() => store.SaveFileAsync(@"..\evade.txt", Array.Empty<byte>(), CancellationToken.None).GetAwaiter().GetResult(), "nom avec chemin refusé");
            Check.True(await store.RevealAsync("Domenia-Ticket.txt", CancellationToken.None), "document du dossier montré");
            Check.False(await store.RevealAsync("absent.txt", CancellationToken.None), "document absent refusé");
            Check.Null(FileDocumentStore.CheckLocalFolder(folder), "dossier local admis pour la commande");
            Check.Contains("partage réseau", FileDocumentStore.CheckLocalFolder(@"\\serveur\partage"), "partage refusé");
            var link = Path.Combine(Path.GetTempPath(), "domenia-tests-lien-" + Guid.NewGuid().ToString("N"));
            try
            {
                Directory.CreateSymbolicLink(link, folder);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                link = "";
            }
            if (link.Length > 0)
            {
                // Creating a link needs the developer mode or the administration rights: without them this part is skipped.
                var linked = new FileDocumentStore(link, new RecordingJournal());
                var refusal = await Check.ThrowsAsync<DocumentStoreException>(() => linked.SaveFileAsync("x.txt", new byte[1], CancellationToken.None), "dossier lien refusé");
                Check.Contains("lien", refusal.Reason, "raison dite");
                Directory.Delete(link);
            }
        }
        finally
        {
            if (Directory.Exists(folder))
            {
                Directory.Delete(folder, recursive: true);
            }
        }
    }

    [Test]
    public static async Task One_document_at_a_time_thirty_seconds_at_most()
    {
        var store = new SlowDocumentStore();
        var documents = new AssistanceDocuments(store, TestClock.Fixed(), TimeSpan.FromMilliseconds(80));
        var first = documents.SaveTextAsync("a.txt", "texte", CancellationToken.None);
        var busy = await Check.ThrowsAsync<DomeniaOperationException>(() => documents.SaveTextAsync("b.txt", "texte", CancellationToken.None), "second document pendant le premier");
        Check.Equal(AssistanceErrors.DocumentBusy, busy.Code, "un document à la fois");
        var late = await Check.ThrowsAsync<DomeniaOperationException>(() => first, "écriture trop longue");
        Check.Equal(AssistanceErrors.DocumentTimeout, late.Code, "délai dépassé");
        store.Release.SetResult();
        var saved = await documents.SaveTextAsync("c.txt", "texte", CancellationToken.None);
        Check.True(saved.Saved, "écrit après la fin du précédent");
        Check.True(await documents.RevealAsync("c.txt", CancellationToken.None), "document de la session montré");
        var missing = await Check.ThrowsAsync<DomeniaOperationException>(() => documents.RevealAsync("autre.txt", CancellationToken.None), "document d’ailleurs");
        Check.Equal(AssistanceErrors.ExportMissing, missing.Code, "seuls les documents de la session");
        var big = await Check.ThrowsAsync<DomeniaOperationException>(() => documents.SaveTextAsync("d.txt", new string('x', AssistanceDocuments.MaxDocumentBytes + 1), CancellationToken.None), "trop gros");
        Check.Equal(AssistanceErrors.ExportTooLarge, big.Code, "1 Mio au plus");
    }

    [Test]
    public static async Task Reveal_refuses_a_name_the_session_did_not_write()
    {
        var bridge = new SimulatedBridge();
        Check.Equal(AssistanceErrors.ExportMissing, ErrorCode(await bridge.CallAsync("assistance.document.reveal", Args(new { name = "Domenia-Support.html" }))), "rien d’écrit en test");
        Check.Equal("arguments.invalid", ErrorCode(await bridge.CallAsync("assistance.document.reveal", Args(new { name = "" }))), "nom vide");
    }

    // ---------------------------------------------------------------- offline dossier: perimeters and command line

    [Test]
    public static async Task Offline_dossier_takes_an_ou_of_the_tree_or_a_list_of_names_never_a_guess()
    {
        var bridge = new SimulatedBridge();
        var site = bridge.Source.CurrentDirectory.OrganizationalUnits.First(o => o.DistinguishedName.Contains(",OU=Postes,", StringComparison.OrdinalIgnoreCase));
        var branch = SimulatedBridge.Json(await bridge.CallAsync("assistance.dossier.prepare", Args(new { scope = "branch", ou = site.DistinguishedName, sections = Array.Empty<string>() })));
        Check.Contains(site.Name, branch.GetProperty("perimeter").GetString(), "OU choisie dans l’arborescence");
        Check.Equal(AssistanceErrors.DossierPerimeter, ErrorCode(await bridge.CallAsync("assistance.dossier.prepare", Args(new { scope = "branch", ou = "OU=Inconnue,DC=example,DC=local" }))), "OU inconnue de l’index local");
        Check.Equal(AssistanceErrors.DossierPerimeter, ErrorCode(await bridge.CallAsync("assistance.dossier.prepare", Args(new { scope = "branch" }))), "aucune OU choisie");
        var computers = bridge.Source.CurrentDirectory.Computers.Take(2).Select(c => c.Name).ToArray();
        var list = SimulatedBridge.Json(await bridge.CallAsync("assistance.dossier.prepare", Args(new { scope = "list", names = new[] { computers[0], computers[1].ToLowerInvariant() + "$", "PC-INCONNU-99" } })));
        Check.Equal(1, list.GetProperty("unresolved").GetInt32(), "nom inconnu compté, jamais deviné");
        Check.Contains("2" + FrenchText.Nbsp + "postes de la liste", list.GetProperty("perimeter").GetString(), "postes reconnus");
        Check.True(list.GetProperty("files").EnumerateArray().All(f => f.GetProperty("bytes").GetInt64() >= 0 && f.GetProperty("size").GetString()!.Length > 0), "tailles en octets");
        var resolved = SimulatedBridge.Json(await bridge.CallAsync("assistance.computers.resolve", Args(new { names = new[] { computers[0], "pc-" } })));
        Check.Equal(1, resolved.GetProperty("found").GetArrayLength(), "correspondance exacte seulement");
        Check.Equal("pc-", resolved.GetProperty("unknown")[0].GetString(), "le nom partiel est inconnu");
        Check.Equal("arguments.invalid", ErrorCode(await bridge.CallAsync("assistance.computers.resolve", Args(new { names = Enumerable.Repeat("PC", 501).ToArray() }))), "500 noms au plus");
    }

    [Test]
    public static void Offline_dossier_command_line_follows_domenia_1()
    {
        var ou = OfflineDossierCommand.Parse(["dossier", "--sortie", @"D:\Diag", "--ou", "OU=Lyon,OU=Postes,DC=example,DC=local", "--sections", "observations", "--simulation"]);
        Check.True(ou.Valid, ou.Error);
        Check.True(ou.Sections.SequenceEqual(["observations"]), "section choisie");
        Check.True(ou.Remaining.SequenceEqual(["--simulation"]), "mode laissé au résolveur");
        var legacy = OfflineDossierCommand.Parse(["dossier", "-OutputPath", @"D:\Diag", "-Computers", "PC-LYO-0042.example.local,pc-lyo-0043$"]);
        Check.True(legacy.Valid && legacy.Names.SequenceEqual(["pc-lyo-0042", "pc-lyo-0043"]), "paramètres de Domenia 1, noms nettoyés");
        Check.True(legacy.Sections.SequenceEqual(OfflineDossiers.OptionalSections), "toutes les sections par défaut");
        Check.Equal(OfflineDossierCommand.Refused, OfflineDossierCommand.Parse(["dossier", "--sortie", @"D:\Diag"]).ExitCode, "sans périmètre : refus (4)");
        Check.Equal(OfflineDossierCommand.Invalid, OfflineDossierCommand.Parse(["dossier", "--ou", "OU=X,DC=a"]).ExitCode, "sans sortie : invalide (2)");
        Check.Equal(OfflineDossierCommand.Invalid, OfflineDossierCommand.Parse(["dossier", "--sortie", "x", "--ou", "OU=X,DC=a", "--postes", "PC-1"]).ExitCode, "deux périmètres");
        Check.Equal(OfflineDossierCommand.Invalid, OfflineDossierCommand.Parse(["dossier", "--sortie", "x", "--ou", "DC=example,DC=local"]).ExitCode, "tout le domaine refusé");
        Check.Equal(OfflineDossierCommand.Invalid, OfflineDossierCommand.Parse(["dossier", "--sortie", "x", "--postes", "PC 1"]).ExitCode, "nom invalide");
        Check.Equal(OfflineDossierCommand.Invalid, OfflineDossierCommand.Parse(["dossier", "--sortie", "x", "--guids", "pas-un-guid"]).ExitCode, "GUID invalide");
        Check.Equal(OfflineDossierCommand.Invalid, OfflineDossierCommand.Parse(["dossier", "--sortie", "x", "--postes", string.Join(',', Enumerable.Range(0, 501).Select(n => "pc-" + n))]).ExitCode, "500 postes au plus");
        Check.Equal(OfflineDossierCommand.BaseUnavailable, OfflineDossierCommand.Parse(["dossier", "-DatabasePath", "x"]).ExitCode, "base de Domenia 1 non lue (3)");
        Check.Equal(OfflineDossierCommand.Invalid, OfflineDossierCommand.Parse(["dossier", "--motdepasse", "x"]).ExitCode, "option inconnue");
        Check.True(OfflineDossierCommand.IsRequested(["Dossier"]) && !OfflineDossierCommand.IsRequested(["--simulation"]), "commande reconnue");
    }

    [Test]
    public static void Dossier_folder_names_and_sizes_read_like_the_other_exports()
    {
        Check.Equal("Domenia-Diagnostic-perimetre-20261021-1826", OfflineDossiers.FolderName("  ", TestClock.Reference, TestClock.Paris), "heure locale, sujet par défaut");
        Check.Equal("834" + FrenchText.Nbsp + "octets", AssistanceText.Bytes(834), "octets");
        Check.Equal("12,4" + FrenchText.Nbsp + "Kio", AssistanceText.Bytes(12_700), "kibioctets");
        Check.Equal("21/10/2026 18:26:00 (UTC+02:00)", AssistanceText.Stamp(TestClock.Reference, TestClock.Paris), "date des documents");
        Check.Equal("1" + FrenchText.Nbsp + "étape", AssistanceText.Count(1, "étape", "étapes"), "nombre lié à son nom");
        Check.Equal("a, b et c", AssistanceText.List(["a", "b", "c"]), "liste française");
        var stamp = AttributeValues.Readable("lockoutTime", AdValues.ToFileTime(TestClock.Reference).ToString(System.Globalization.CultureInfo.InvariantCulture), TestClock.Paris);
        Check.Equal("21/10/2026 18:26:00 (UTC+02:00)", stamp, "FILETIME lisible");
        Check.Equal("aucun verrouillage", AttributeValues.Readable("lockoutTime", "0", TestClock.Paris), "zéro dit");
        Check.Equal("jamais", AttributeValues.Readable("accountExpires", AdValues.Never.ToString(System.Globalization.CultureInfo.InvariantCulture), TestClock.Paris), "jamais");
        Check.Null(AttributeValues.Readable("title", "Technicien", TestClock.Paris), "pas une date");
    }

    // ---------------------------------------------------------------- pseudonyms

    private static readonly Regex ClearCommonName = new(@"CN=(?!(Utilisateur|Machine|Groupe|Objet|Compte|Identifiant|Valeur)-[0-9A-F]{6,32})", RegexOptions.CultureInvariant);

    [Test]
    public static async Task Pseudonymised_documents_leave_no_third_party_name_in_clear()
    {
        var bridge = new SimulatedBridge();
        var user = bridge.Source.CurrentDirectory.Users.First(u => u.ManagerDn is not null && u.MemberOf.Length > 0);
        var dn = user.DistinguishedName;
        await bridge.CallAsync("assistance.subject.read", Args(new { dn }));
        await bridge.CallAsync("assistance.step.run", Args(new { recipe = "logon", step = "lockouts", dn }));
        await bridge.CallAsync("assistance.step.run", Args(new { recipe = "drive", step = "groups-user", dn }));
        await bridge.CallAsync("assistance.capture.take", Args(new { slot = "a", dn }));
        await bridge.CallAsync("assistance.capture.take", Args(new { slot = "b", dn }));
        var report = SimulatedBridge.Json(await bridge.CallAsync("assistance.report.preview", Args(new { dn, pseudonymize = true, key = "cle-de-test-1" })));
        var text = report.GetProperty("text").GetString()!;
        Check.False(ClearCommonName.IsMatch(text), "aucun « CN=… » en clair dans le dossier support");
        foreach (var entry in report.GetProperty("map").EnumerateArray())
        {
            var original = entry.GetProperty("original").GetString()!;
            Check.False(text.Contains(original, StringComparison.OrdinalIgnoreCase), "nom remplacé partout : " + entry.GetProperty("kind").GetString());
        }
        var manager = SupportReport.CommonName(user.ManagerDn)!;
        Check.False(text.Contains(manager, StringComparison.OrdinalIgnoreCase), "nom du manager pseudonymisé");
        var ticket = SimulatedBridge.Json(await bridge.CallAsync("assistance.ticket.preview", Args(new { dn, pseudonymize = true, key = "cle-de-test-1" })));
        var ticketText = ticket.GetProperty("text").GetString()!;
        foreach (var entry in ticket.GetProperty("map").EnumerateArray())
        {
            Check.False(ticketText.Contains(entry.GetProperty("original").GetString()!, StringComparison.OrdinalIgnoreCase), "compte rendu : nom remplacé");
        }
        var lockouts = SupportWorkshop.From(bridge.Context).Launch(dn, "logon", "lockouts")!.Reading!;
        foreach (var mention in lockouts.Cited)
        {
            Check.False(ticketText.Contains(mention.Value, StringComparison.OrdinalIgnoreCase), "poste cité par la lecture pseudonymisé : " + mention.Kind);
        }
        Check.Equal(AssistanceErrors.KeyMissing, ErrorCode(await bridge.CallAsync("assistance.ticket.export", Args(new { dn, pseudonymize = true, key = "court" }))), "export sans clé : refus dédié");
    }

    [Test]
    public static void Remaining_common_names_are_masked_inside_a_dn_only()
    {
        var (text, map) = Pseudonyms.MaskRemainingNames("manager = CN=Cédric Carré,OU=Lyon,DC=example,DC=local ; Cédric reste un mot.", ImmutableArray<PseudonymEntry>.Empty, "cle-de-test-1");
        Check.False(text.Contains("CN=Cédric", StringComparison.Ordinal), "nom du DN remplacé");
        Check.Contains("Cédric reste un mot", text, "un mot hors d’un DN n’est pas touché");
        Check.Equal("Objet", map.Single().Kind, "famille « Objet »");
        Check.False(ClearCommonName.IsMatch(text), "plus aucun CN en clair");
    }
}
