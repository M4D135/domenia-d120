using System.Collections.Immutable;
using System.Security;
using System.Text.Json;
using Domenia.Bridge;
using Domenia.Core;
using Domenia.Simulation;

namespace Domenia.Tests;

/// <summary>Account of the workstation operations (MAC-001 to MAC-003, docs/ops/schema.md § 10 to 16). Written now, run at the end.</summary>
internal static class MachineAccountTests
{
    private const string Nbsp = " ";
    private static readonly ImmutableArray<MachineAccountPause?> NoPause = [];

    private static MachineAccountRules.CascadeInput Input(
        string? temporaryLocal = null, string? temporary = null, string? typed = null, string? remote = null, string? connection = null,
        bool target = false, ImmutableArray<MachineAccountPause?>? pauses = null) =>
        new(temporaryLocal, temporary, typed, remote, connection, @"EXAMPLE\j.martin", target, true, pauses ?? NoPause);

    [Test]
    public static void Labels_keep_the_words_of_Domenia_1()
    {
        var windows = MachineAccountRules.Label(MachineAccountSource.Windows, @"EXAMPLE\j.martin");
        Check.Equal("session Windows", windows.Short, "pastille courte");
        Check.Equal(@"session Windows (EXAMPLE\j.martin)", windows.Long, "phrase longue");
        Check.Equal("Compte poste" + Nbsp + ": session Windows ▾", windows.Pill, "texte de la pastille");
        var typed = MachineAccountRules.Label(MachineAccountSource.Typed, @"EXAMPLE\adm-j.martin");
        Check.Equal(@"EXAMPLE\adm-j.martin", typed.Short, "nom seul dans la pastille");
        Check.Equal(@"EXAMPLE\adm-j.martin (compte poste saisi, en mémoire seulement)", typed.Long, "origine entre parenthèses");
        var nameless = MachineAccountRules.Label(MachineAccountSource.Remote, null);
        Check.Equal("compte Postes de la page Comptes", nameless.Short, "sans nom : l’origine");
        Check.Equal("Opérations poste" + Nbsp + ": " + typed.Long + ".", MachineAccountRules.Sentence(typed), "phrase « Opérations poste »");
    }

    [Test]
    public static void Typed_accounts_need_an_accepted_form()
    {
        Check.Equal(@"EXAMPLE\adm-j.martin", MachineAccountRules.NormalizeAccount(@"  EXAMPLE\adm-j.martin "), "DOMAINE\\nom");
        Check.Equal(@"PC-PAR-0042\Administrateur", MachineAccountRules.NormalizeAccount(@"PC-PAR-0042\Administrateur"), "POSTE\\nom");
        Check.Equal(@".\admin", MachineAccountRules.NormalizeAccount(@".\admin"), ".\\nom");
        Check.Equal("adm@example.local", MachineAccountRules.NormalizeAccount("adm@example.local"), "UPN");
        Check.Null(MachineAccountRules.NormalizeAccount("admin"), "nom nu refusé");
        Check.Null(MachineAccountRules.NormalizeAccount(@"EXAMPLE\"), "nom vide refusé");
        Check.Null(MachineAccountRules.NormalizeAccount(@"EXAMPLE\a*b"), "caractère interdit");
        Check.Null(MachineAccountRules.NormalizeAccount(new string('a', 300) + @"\x"), "trop long");
        Check.Equal("PC-PAR-0001", MachineAccountRules.MachineKey(" pc-par-0001.example.local "), "clé du poste");
        Check.Null(MachineAccountRules.MachineKey("pc par"), "nom de poste invalide");
        Check.Equal(@"PC-1\admin", MachineAccountRules.ForTarget(@".\admin", "pc-1"), "« .\\ » complété par le poste");
        Check.Equal(@"EXAMPLE\x", MachineAccountRules.ForTarget(@"EXAMPLE\x", "pc-1"), "autre forme inchangée");
    }

    [Test]
    public static void Trial_verdicts_follow_Domenia_1()
    {
        (MachineTrialVerdict, string) V(string outcome, string? error = null, string? category = null, string? caption = null)
        {
            var (verdict, text, _) = MachineAccountRules.Verdict(outcome, error, category, "PC-1", "le compte", caption);
            return (verdict, text);
        }
        Check.Equal(MachineTrialVerdict.AdminOk, V("Observed").Item1, "succès explicite");
        Check.Equal("Accès administrateur OK sur PC-1 avec le compte. Système" + Nbsp + ": Windows 11.", V("Observed", caption: "Windows 11").Item2, "texte avec le système");
        Check.Equal(MachineTrialVerdict.Rejected, V("AuthRejected").Item1, "identifiants refusés");
        Check.Equal(MachineTrialVerdict.Rejected, V("Observed", "x", "CredentialsRejected").Item1, "catégorie identifiants");
        Check.Equal(MachineTrialVerdict.AccountState, V("Failed", "x", "AccountState").Item1, "compte restreint");
        Check.Equal(MachineTrialVerdict.Rejected, V("AuthRejected", "x", "AccountState").Item1, "un refus d’identifiants passe avant l’état du compte, comme Domenia 1");
        Check.Equal(MachineTrialVerdict.Denied, V("Denied").Item1, "accès refusé");
        Check.Equal(MachineTrialVerdict.Unreachable, V("Timeout").Item1, "délai");
        Check.Equal(MachineTrialVerdict.Unreachable, V("Unavailable", "Le serveur RPC n’est pas disponible.").Item1, "RPC");
        Check.Equal(MachineTrialVerdict.Unknown, V("Observed", "erreur étrange").Item1, "jamais un succès avec une erreur");
        Check.Contains("Essai non concluant sur PC-1" + Nbsp + ": ", V("Unavailable", "erreur étrange").Item2, "texte non concluant");
    }

    [Test]
    public static void Cascade_lights_the_first_configured_level()
    {
        var (levels, inUse) = MachineAccountRules.Cascade(Input());
        Check.Equal(6, levels.Length, "six niveaux");
        Check.Equal(MachineAccountSource.Windows, inUse.Source, "session Windows par défaut");
        Check.Equal(6, inUse.Rank, "niveau 6");
        Check.Equal(MachineLevelState.NotApplicable, levels[0].State, "niveau du poste : aucun poste choisi");
        Check.Equal(MachineLevelState.Empty, levels[2].State, "aucun compte saisi");
        Check.Contains("Simulation", levels[4].Detail, "connexion : pas d’identifiants en simulation");

        var (typedLevels, typedInUse) = MachineAccountRules.Cascade(Input(typed: @"EXAMPLE\adm-j.martin", remote: @"EXAMPLE\svc-postes", target: true));
        Check.Equal(MachineAccountSource.Typed, typedInUse.Source, "le compte saisi passe avant le compte Postes");
        Check.Equal(MachineLevelState.Active, typedLevels[2].State, "saisi en service");
        Check.Equal(MachineLevelState.Available, typedLevels[3].State, "compte Postes disponible, non utilisé");
        Check.Equal(MachineLevelState.Available, typedLevels[5].State, "session Windows disponible");
        Check.Equal(MachineLevelState.Empty, typedLevels[0].State, "poste choisi, aucun compte local");

        var local = MachineAccountRules.Cascade(Input(temporaryLocal: @"PC-1\admin", typed: @"EXAMPLE\x", target: true)).InUse;
        Check.Equal(MachineAccountSource.TemporaryLocal, local.Source, "le compte local du poste passe en premier");

        ImmutableArray<MachineAccountPause?> pauses = [null, null, new(@"EXAMPLE\x", TestClock.Reference, "Identifiants refusés."), null, null, null];
        var paused = MachineAccountRules.Cascade(Input(typed: @"EXAMPLE\x", pauses: pauses));
        Check.True(paused.InUse.Paused, "en pause après un refus");
        Check.Equal(Tone.Warn, paused.InUse.Tone, "ton d’avertissement");
        Check.True(paused.Levels[2].Paused, "niveau marqué");
        Check.Contains("En pause après un refus", paused.InUse.Tip, "infobulle");
        var samePlaceOnly = MachineAccountRules.Cascade(Input(typed: @"EXAMPLE\x", remote: @"EXAMPLE\x", pauses: pauses));
        Check.False(samePlaceOnly.Levels[3].Paused, "le compte Postes de même nom n’est pas en pause : la pause suit la place, pas le nom");

        var leased = MachineAccountRules.Cascade(Input(temporary: @"EXAMPLE\tmp") with { TemporaryLease = "encore 12 min sans utilisation" });
        Check.Contains("Bail" + Nbsp + ": encore 12 min sans utilisation.", leased.Levels[1].Detail, "bail du compte temporaire dans son niveau");
    }

    [Test]
    public static void Leases_follow_Domenia_1()
    {
        const string key = @"dc=example,dc=local|example\j.martin|windowssession";
        var now = TestClock.Reference;
        var idle = MachineAccountRules.NewLease(MachineLeaseMode.Inactivity, 30, key, now);
        Check.True(MachineAccountRules.CheckLease(idle, key, now.AddMinutes(30)).Usable, "30 min tout juste : encore utilisable");
        var expired = MachineAccountRules.CheckLease(idle, key, now.AddMinutes(31));
        Check.False(expired.Usable, "31 min sans utilisation : expiré");
        Check.Equal("Compte expiré après 30 min sans utilisation.", expired.Reason, "raison");
        Check.False(MachineAccountRules.CheckLease(idle, @"dc=autre,dc=local|example\j.martin|windowssession", now).Usable, "autre domaine : inutilisable");
        Check.Equal("encore 30 min sans utilisation", MachineAccountRules.LeaseRemaining(idle, key, now).Text, "temps restant");
        Check.Equal("encore 1 min sans utilisation", MachineAccountRules.LeaseRemaining(idle, key, now.AddMinutes(29.5)).Text, "arrondi à la minute supérieure");
        Check.Equal("expiré" + Nbsp + ": oublié au prochain contrôle", MachineAccountRules.LeaseRemaining(idle, key, now.AddMinutes(40)).Text, "expiré");
        var used = MachineAccountRules.UseLease(idle, now.AddMinutes(20));
        Check.True(MachineAccountRules.CheckLease(used, key, now.AddMinutes(45)).Usable, "une utilisation prolonge le bail");
        var once = MachineAccountRules.NewLease(MachineLeaseMode.OneShot, 30, key, now);
        Check.Equal("une seule utilisation", MachineAccountRules.LeaseRemaining(once, key, now).Text, "usage unique");
        Check.False(MachineAccountRules.CheckLease(MachineAccountRules.UseLease(once, now), key, now).Usable, "usage unique dépensé");
        var session = MachineAccountRules.NewLease(MachineLeaseMode.Session, 30, key, now);
        Check.True(MachineAccountRules.CheckLease(session, key, now.AddDays(2)).Usable, "bail de session : sans délai");
        Check.Equal(480, MachineAccountRules.NewLease(MachineLeaseMode.Inactivity, 9000, key, now).InactivityMinutes, "480 min au plus");
        Check.Equal(1, MachineAccountRules.NewLease(MachineLeaseMode.Inactivity, 0, key, now).InactivityMinutes, "1 min au moins");
    }

    [Test]
    public static void Secrets_take_their_own_account()
    {
        var none = MachineAccountRules.SecretsCascade(null, null, @"EXAMPLE\j.martin", NoPause);
        Check.Equal(@"EXAMPLE\j.martin", none.Account, "compte de l’annuaire");
        Check.Equal(MachineLevelState.Active, none.Levels[2].State, "dernier niveau en service");
        var secrets = MachineAccountRules.SecretsCascade(null, @"EXAMPLE\lecteur-laps", @"EXAMPLE\j.martin", NoPause);
        Check.Equal(@"EXAMPLE\lecteur-laps", secrets.Account, "compte Secrets");
        Check.Equal(MachineLevelState.Available, secrets.Levels[2].State, "annuaire disponible, non utilisé");
    }

    [Test]
    public static async Task State_in_simulation_names_the_session_and_asks_no_password()
    {
        var bridge = new SimulatedBridge();
        var json = SimulatedBridge.Json(await bridge.CallAsync("machine.account.state", "{}"));
        Check.Equal("windows", json.GetProperty("inUse").GetProperty("source").GetString(), "session Windows");
        Check.Equal(@"EXAMPLE\" + SimulationProfile.SessionLogin, json.GetProperty("inUse").GetProperty("account").GetString(), "compte de la session fictive, jamais le compte Windows réel");
        Check.False(json.GetProperty("credentialRequired").GetBoolean(), "aucun mot de passe en simulation");
        Check.Equal(6, json.GetProperty("levels").GetArrayLength(), "six niveaux");
        Check.Equal(3, json.GetProperty("confidentialReads").GetProperty("levels").GetArrayLength(), "trois niveaux pour les secrets");
        Check.Equal(JsonValueKind.Null, json.GetProperty("typed").ValueKind, "aucun compte saisi");
        AssertNoSecretName(json);
    }

    [Test]
    public static async Task Typed_account_lives_in_memory_and_moves_the_generation()
    {
        var bridge = new SimulatedBridge();
        var refused = await bridge.CallAsync("machine.account.use", "{\"account\":\"EXAMPLE\\\\adm-j.martin\",\"password\":\"Secret123!\"}");
        Check.Equal(MachineErrors.PasswordRefused, refused.Error!.Code, "aucun mot de passe en simulation");
        Check.False(bridge.Log.Lines.Any(l => l.Contains("Secret123", StringComparison.Ordinal)), "le mot de passe n’est jamais journalisé");
        var invalid = await bridge.CallAsync("machine.account.use", "{\"account\":\"admin\",\"password\":null}");
        Check.Equal(MachineErrors.AccountInvalid, invalid.Error!.Code, "forme refusée");
        var empty = await bridge.CallAsync("machine.account.use", "{\"account\":\"  \",\"password\":null}");
        Check.Equal(MachineErrors.AccountEmpty, empty.Error!.Code, "compte vide");

        var used = SimulatedBridge.Json(await bridge.CallAsync("machine.account.use", "{\"account\":\"EXAMPLE\\\\adm-j.martin\",\"password\":null}"));
        Check.Equal("typed", used.GetProperty("inUse").GetProperty("source").GetString(), "compte saisi en service");
        Check.Equal(3, used.GetProperty("inUse").GetProperty("rank").GetInt32(), "niveau 3");
        Check.Equal(1, used.GetProperty("generation").GetInt64(), "nouvelle génération");
        Check.False(used.GetProperty("typed").GetProperty("withCredential").GetBoolean(), "aucun mot de passe gardé en simulation");
        Check.True(bridge.Context.Journal.Snapshot().Any(j => j.Label.StartsWith("Compte poste saisi", StringComparison.Ordinal) && !j.Label.Contains("adm-j.martin", StringComparison.Ordinal)), "journal sans le nom");
        AssertNoSecretName(used);

        var forgotten = SimulatedBridge.Json(await bridge.CallAsync("machine.account.forget", "{}"));
        Check.Equal("windows", forgotten.GetProperty("inUse").GetProperty("source").GetString(), "retour au compte configuré");
        Check.Equal(2, forgotten.GetProperty("generation").GetInt64(), "génération suivante");
        var again = SimulatedBridge.Json(await bridge.CallAsync("machine.account.forget", "{}"));
        Check.Equal(2, again.GetProperty("generation").GetInt64(), "oublier deux fois ne change rien");
    }

    [Test]
    public static async Task Trial_reads_the_fictitious_directory_and_pauses_a_refused_account()
    {
        var bridge = new SimulatedBridge();
        var missing = await bridge.CallAsync("machine.account.trial", "{}");
        Check.Equal(MachineErrors.TargetMissing, missing.Error!.Code, "un poste est exigé");
        var unknown = await bridge.CallAsync("machine.account.trial", "{\"target\":\"PC-INEXISTANT\"}");
        Check.Equal(MachineErrors.TargetUnknown, unknown.Error!.Code, "poste introuvable");

        // j.martin (GG-Support-N2, imbriqué dans GG-Admins-Postes) n’administre pas les serveurs ; la session signe avec adm-j.martin.
        var server = SimulatedBridge.Json(await bridge.CallAsync("machine.account.trial", "{\"target\":\"SRV-FIC-01\",\"account\":\"EXAMPLE\\\\j.martin\",\"password\":null}"));
        Check.Equal("denied", server.GetProperty("trial").GetProperty("verdict").GetString(), "serveur : accès refusé");
        Check.True(server.GetProperty("trial").GetProperty("simulated").GetBoolean(), "essai simulé");
        Check.Equal("SRV-FIC-01", server.GetProperty("state").GetProperty("target").GetProperty("name").GetString(), "poste de l’état");

        var admin = SimulatedBridge.Json(await bridge.CallAsync("machine.account.trial", "{\"target\":\"SRV-FIC-01\",\"account\":\"EXAMPLE\\\\Administrateur\",\"password\":null}"));
        Check.Equal("adminOk", admin.GetProperty("trial").GetProperty("verdict").GetString(), "administrateur du domaine : accès OK");
        Check.True(admin.GetProperty("trial").GetProperty("candidate").GetBoolean(), "compte à valider");
        Check.Equal("windows", admin.GetProperty("state").GetProperty("inUse").GetProperty("source").GetString(), "un compte à valider n’entre pas en service");

        var rejected = SimulatedBridge.Json(await bridge.CallAsync("machine.account.trial", "{\"target\":\"SRV-FIC-01\",\"account\":\"EXAMPLE\\\\licorne\",\"password\":null}"));
        Check.Equal("rejected", rejected.GetProperty("trial").GetProperty("verdict").GetString(), "compte inconnu : identifiants refusés");
        Check.False(rejected.GetProperty("state").GetProperty("inUse").GetProperty("paused").GetBoolean(), "un compte à valider refusé ne met rien en pause");
        SimulatedBridge.Json(await bridge.CallAsync("machine.account.use", "{\"account\":\"EXAMPLE\\\\licorne\",\"password\":null}"));
        var inService = SimulatedBridge.Json(await bridge.CallAsync("machine.account.trial", "{\"target\":\"SRV-FIC-01\"}"));
        Check.Equal("rejected", inService.GetProperty("trial").GetProperty("verdict").GetString(), "compte en service refusé");
        var state = SimulatedBridge.Json(await bridge.CallAsync("machine.account.state", "{}"));
        Check.True(state.GetProperty("inUse").GetProperty("paused").GetBoolean(), "le compte refusé est en pause");

        var otherLocal = SimulatedBridge.Json(await bridge.CallAsync("machine.account.trial", "{\"target\":\"SRV-FIC-01\",\"account\":\"SRV-FIC-02\\\\admin\",\"password\":null}"));
        Check.Equal("rejected", otherLocal.GetProperty("trial").GetProperty("verdict").GetString(), "compte local d’un autre poste");
        var local = SimulatedBridge.Json(await bridge.CallAsync("machine.account.trial", "{\"target\":\"SRV-FIC-01\",\"account\":\".\\\\admin\",\"password\":null}"));
        Check.Equal("adminOk", local.GetProperty("trial").GetProperty("verdict").GetString(), "« .\\ » : compte local du poste");
        Check.True(state.GetProperty("trials").GetArrayLength() >= 3, "essais de la session gardés");
        Check.True(bridge.Context.Journal.Snapshot().Any(j => j.Label.StartsWith("Essai du compte poste sur SRV-FIC-01", StringComparison.Ordinal)), "journal des opérations");
    }

    [Test]
    public static async Task Workstation_search_finds_by_part_of_the_name()
    {
        var bridge = new SimulatedBridge();
        var found = SimulatedBridge.Json(await bridge.CallAsync("machine.workstations.search", "{\"text\":\"srv-fic\"}"));
        Check.Equal(4, found.GetArrayLength(), "quatre serveurs de fichiers");
        Check.Equal("SRV-FIC-01", found[0].GetProperty("name").GetString(), "ordre des noms");
        Check.Contains("Serveurs", found[0].GetProperty("path").GetString(), "chemin lisible");
        var none = SimulatedBridge.Json(await bridge.CallAsync("machine.workstations.search", "{\"text\":\"   \"}"));
        Check.Equal(0, none.GetArrayLength(), "texte vide : rien");
        var tooLong = await bridge.CallAsync("machine.workstations.search", "{\"text\":\"" + new string('a', 65) + "\"}");
        Check.Equal("arguments.invalid", tooLong.Error!.Code, "64 caractères au plus");
    }

    [Test]
    public static void Service_keeps_passwords_as_read_only_secure_strings()
    {
        var bridge = new SimulatedBridge();
        var service = MachineAccountService.From(bridge.Context);
        Check.True(ReferenceEquals(service, MachineAccountService.From(bridge.Context)), "service partagé");
        using var password = new SecureString();
        foreach (var c in "abc")
        {
            password.AppendChar(c);
        }
        service.UseRemote(@"EXAMPLE\svc-postes", password.Copy());
        var session = bridge.Source.GetSessionAsync(CancellationToken.None).GetAwaiter().GetResult();
        Check.Equal(MachineAccountSource.Remote, service.Resolve(session, null).Source, "compte Postes en service");
        using (var credential = service.CredentialFor(session, null))
        {
            Check.Equal(@"EXAMPLE\svc-postes", credential.Account, "nom du compte");
            Check.Equal(MachineAccountSource.Remote, credential.Source, "source");
            Check.NotNull(credential.Password, "copie du mot de passe");
            Check.True(credential.Password!.IsReadOnly(), "copie en lecture seule");
            Check.Equal(3, credential.Password.Length, "longueur conservée");
            Check.Contains("remote#", credential.Place, "place du compte dans la règle");
        }
        service.AcceptTemporary(session, "PC-1", @"PC-1\admin", null);
        Check.Equal(MachineAccountSource.TemporaryLocal, service.Resolve(session, "pc-1.example.local").Source, "compte local du poste pour ce poste");
        Check.Equal(MachineAccountSource.Remote, service.Resolve(session, "PC-2").Source, "un autre poste garde le compte Postes");
        using (var local = service.CredentialFor(session, "PC-1"))
        {
            Check.Equal(@"PC-1\admin", local.Account, "compte local");
        }
        service.ClearRemote();
        service.ForgetTemporary("PC-1");
        Check.Equal(MachineAccountSource.Windows, service.Resolve(session, "PC-1").Source, "retour à la session Windows");
    }

    [Test]
    public static async Task Trial_is_refused_in_directory_mode_while_the_workstation_reads_are_not_wired()
    {
        var source = new UnavailableDirectorySource("cnamts.local", () => @"CNAMTS\degun");
        var decision = ModeResolver.Resolve([], null, () => new DomainJoinInfo(DomainJoinState.Joined, "cnamts.local"));
        using var context = new EngineContext(decision, source, new MemoryPreferenceStore(), TestClock.Fixed(), new RecordingJournal(), ScreenReaders.None);
        var registry = OperationModules.CreateRegistry(context, [new MachineOperations()]);
        var sent = new List<BridgeResponse>();
        var dispatcher = new BridgeDispatcher(registry, sent.Add, AdmissionGuards.For(AppMode.Directory));
        await dispatcher.HandleAsync("""{"id":"m1","op":"machine.account.trial","args":{"target":"PC-1"}}""", CancellationToken.None);
        Check.Equal(DomeniaErrors.SourceUnavailable, sent.Single().Error!.Code, "source indisponible");
        await dispatcher.HandleAsync("""{"id":"m2","op":"machine.account.use","args":{"account":"CNAMTS\\adm","password":null}}""", CancellationToken.None);
        Check.Equal(MachineErrors.PasswordMissing, sent.Last().Error!.Code, "mode annuaire : mot de passe exigé");
        await dispatcher.HandleAsync("""{"id":"m3","op":"machine.account.use","args":{"account":"CNAMTS\\adm","password":"x"}}""", CancellationToken.None);
        Check.Equal("result", sent.Last().Kind, "compte gardé en mémoire");
        using var document = JsonDocument.Parse(JsonSerializer.Serialize(sent.Last().Data, BridgeJson.Options));
        Check.True(document.RootElement.GetProperty("typed").GetProperty("withCredential").GetBoolean(), "mot de passe gardé côté moteur");
        Check.False(document.RootElement.GetRawText().Contains("\"x\"", StringComparison.Ordinal), "le mot de passe ne revient jamais");
    }

    [Test]
    public static async Task Pauses_follow_the_place_and_refuse_the_next_operation()
    {
        var bridge = new SimulatedBridge();
        var service = MachineAccountService.From(bridge.Context);
        var session = await bridge.Source.GetSessionAsync(CancellationToken.None);

        // A candidate refused with the name of the account in service never pauses it.
        SimulatedBridge.Json(await bridge.CallAsync("machine.account.use", "{\"account\":\"SRV-FIC-02\\\\admin\",\"password\":null}"));
        var candidate = SimulatedBridge.Json(await bridge.CallAsync("machine.account.trial", "{\"target\":\"SRV-FIC-01\",\"account\":\"SRV-FIC-02\\\\admin\",\"password\":null}"));
        Check.Equal("rejected", candidate.GetProperty("trial").GetProperty("verdict").GetString(), "compte local d’un autre poste : refusé");
        Check.False(candidate.GetProperty("state").GetProperty("inUse").GetProperty("paused").GetBoolean(), "le compte en service de même nom reste hors pause");

        // The account in service refused: paused, and the next operation with it is refused (the trial may still validate it).
        var refused = SimulatedBridge.Json(await bridge.CallAsync("machine.account.trial", "{\"target\":\"SRV-FIC-01\"}"));
        Check.Equal("rejected", refused.GetProperty("trial").GetProperty("verdict").GetString(), "compte en service refusé");
        Check.True(refused.GetProperty("state").GetProperty("inUse").GetProperty("paused").GetBoolean(), "en pause après le refus");
        var paused = Check.Throws<DomeniaOperationException>(() => service.CredentialFor(session, "SRV-FIC-01"), "opération refusée pendant la pause");
        Check.Equal(MachineErrors.AccountPaused, paused.Code, "code machine.accountPaused");
        string place;
        using (var forTrial = service.CredentialFor(session, "SRV-FIC-01", forTrial: true))
        {
            Check.Equal(@"SRV-FIC-02\admin", forTrial.Account, "l’essai peut partir avec le compte en pause");
            place = forTrial.Place;
        }

        // A candidate validated with the same name (another password) does not release the account in service.
        var success = new MachineTrialResult(
            MachineTrialVerdict.AdminOk, true, "Accès administrateur OK.", Tone.Ok, "SRV-FIC-02", @"SRV-FIC-02\admin", "compte à valider", null, true, true, TestClock.Reference);
        service.RecordTrial(success, null, @"SRV-FIC-02\admin");
        Check.True(service.Build(session, null, null).InUse.Paused, "un compte à valider réussi ne lève pas la pause du compte en service");

        // The account in service validated by a trial: released.
        service.RecordTrial(success with { Candidate = false }, place, @"SRV-FIC-02\admin");
        Check.False(service.Build(session, null, null).InUse.Paused, "pause levée par l’essai réussi du compte en service");

        // A new account typed with a refused name is a new place: it starts without pause.
        SimulatedBridge.Json(await bridge.CallAsync("machine.account.use", "{\"account\":\"EXAMPLE\\\\licorne\",\"password\":null}"));
        SimulatedBridge.Json(await bridge.CallAsync("machine.account.trial", "{\"target\":\"SRV-FIC-01\"}"));
        var again = SimulatedBridge.Json(await bridge.CallAsync("machine.account.use", "{\"account\":\"EXAMPLE\\\\licorne\",\"password\":null}"));
        Check.False(again.GetProperty("inUse").GetProperty("paused").GetBoolean(), "nouvelle saisie : nouvelle place, sans pause");
    }

    [Test]
    public static async Task Temporary_accounts_keep_a_lease_bound_to_the_session()
    {
        var bridge = new SimulatedBridge();
        var service = MachineAccountService.From(bridge.Context);
        var session = await bridge.Source.GetSessionAsync(CancellationToken.None);

        service.AcceptTemporary(session, null, @"EXAMPLE\tmp-postes", null);
        var state = service.Build(session, null, null);
        Check.Equal(MachineAccountSource.Temporary, state.InUse.Source, "compte temporaire en service");
        Check.Contains("encore 30 min sans utilisation", state.Levels[1].Detail, "temps restant du bail");
        bridge.Clock.Advance(TimeSpan.FromMinutes(20));
        using (service.CredentialFor(session, null))
        {
            // A use by an operation extends the lease.
        }
        bridge.Clock.Advance(TimeSpan.FromMinutes(25));
        Check.Equal(MachineAccountSource.Temporary, service.Resolve(session, null).Source, "prolongé par l’utilisation");
        bridge.Clock.Advance(TimeSpan.FromMinutes(31));
        Check.Equal(MachineAccountSource.Windows, service.Resolve(session, null).Source, "31 min sans utilisation : oublié");
        Check.True(bridge.Context.Journal.Snapshot().Any(j => j.Label.StartsWith("Compte temporaire oublié", StringComparison.Ordinal) && !j.Label.Contains("tmp-postes", StringComparison.Ordinal)), "journal sans le nom");

        service.AcceptTemporary(session, null, @"EXAMPLE\une-fois", null, MachineLeaseMode.OneShot);
        using (var once = service.CredentialFor(session, null))
        {
            Check.Equal(@"EXAMPLE\une-fois", once.Account, "usage unique : première utilisation");
        }
        Check.Equal(MachineAccountSource.Windows, service.Resolve(session, null).Source, "usage unique dépensé");

        service.AcceptTemporary(session, "PC-1", @"PC-1\admin", null, MachineLeaseMode.Session);
        var otherDomain = session with { Domain = new DomainIdentity("autre.local", "AUTRE", "DC=autre,DC=local") };
        Check.Equal(MachineAccountSource.Windows, service.Resolve(otherDomain, "PC-1").Source, "jamais pour un autre domaine");
        Check.Equal(MachineAccountSource.Windows, service.Resolve(session, "PC-1").Source, "oublié au contrôle : il ne revient pas");
    }

    [Test]
    public static async Task Watch_answers_when_the_account_changes()
    {
        var bridge = new SimulatedBridge();
        var first = SimulatedBridge.Json(await bridge.CallAsync("machine.account.watch", "{\"since\":null}"));
        Check.True(first.GetProperty("changed").GetBoolean(), "sans valeur connue : réponse immédiate");
        Check.Equal("windows", first.GetProperty("inUse").GetProperty("source").GetString(), "pastille de la session Windows");
        Check.Contains("Opérations poste", first.GetProperty("sentence").GetString(), "phrase de Domenia 1");
        var version = first.GetProperty("version").GetInt64();
        var state = SimulatedBridge.Json(await bridge.CallAsync("machine.account.state", "{}"));
        Check.Equal(version, state.GetProperty("version").GetInt64(), "même compteur que l’état");

        var waiting = bridge.CallAsync("machine.account.watch", "{\"since\":" + version.ToString(System.Globalization.CultureInfo.InvariantCulture) + "}");
        await Task.Delay(50);
        Check.False(waiting.IsCompleted, "aucun changement : la veille attend");
        SimulatedBridge.Json(await bridge.CallAsync("machine.account.use", "{\"account\":\"EXAMPLE\\\\adm-j.martin\",\"password\":null}"));
        var done = await Task.WhenAny(waiting, Task.Delay(5000));
        Check.True(ReferenceEquals(done, waiting), "le changement réveille la veille");
        var changed = SimulatedBridge.Json(await waiting);
        Check.True(changed.GetProperty("changed").GetBoolean(), "changement signalé");
        Check.Equal("typed", changed.GetProperty("inUse").GetProperty("source").GetString(), "nouvelle pastille");
        AssertNoSecretName(changed);

        var invalid = await bridge.CallAsync("machine.account.watch", "{\"since\":-1}");
        Check.Equal("arguments.invalid", invalid.Error!.Code, "compteur négatif refusé");
    }

    private static void AssertNoSecretName(JsonElement element)
    {
        switch (element.ValueKind)
        {
            case JsonValueKind.Object:
                foreach (var property in element.EnumerateObject())
                {
                    foreach (var word in new[] { "password", "pwd", "secret" })
                    {
                        Check.False(property.Name.Contains(word, StringComparison.OrdinalIgnoreCase), "nom de propriété JSON : " + property.Name);
                    }
                    AssertNoSecretName(property.Value);
                }
                break;
            case JsonValueKind.Array:
                foreach (var item in element.EnumerateArray())
                {
                    AssertNoSecretName(item);
                }
                break;
            default:
                break;
        }
    }
}
