using System.Collections.Immutable;
using System.Globalization;
using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Inventory;
using ReadState = Domenia.Core.ReadState;

namespace Domenia.Ad;

public sealed partial class AdAssistanceReader
{
    internal Func<string, string, RemoteProbeCredential, CancellationToken, Task<LockoutEventsRead>>? LockoutsOverride { get; init; }

    public async Task<StepReading> RunStepAsync(AssistanceAction action, SubjectRecord subject, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(action); ArgumentNullException.ThrowIfNull(subject);
        var declared = AssistanceRecipes.FindAction(action.Id) ?? throw new DomeniaOperationException(AssistanceErrors.StepUnknown, AssistanceErrors.StepUnknownMessage);
        if (!declared.Subjects.Contains(subject.Kind)) { throw new DomeniaOperationException(AssistanceErrors.SubjectMismatch, "Cette lecture ne concerne pas le type de sujet choisi."); }
        // An action DTO never chooses a command. The closed catalog owns both operation and label.
        action = declared;
        var epoch = source.Epoch;
        var fresh = await AdSupportObjects.ReadAsync(source, subject.Dn, subject.Guid, cancellationToken).ConfigureAwait(false); Current(epoch);
        var user = fresh.Users.SingleOrDefault(); var pc = fresh.Computers.SingleOrDefault();
        if (subject.Kind == AssistanceSubject.User ? user is null : pc is null)
        { throw new DomeniaOperationException(AssistanceErrors.SubjectUnknown, AssistanceErrors.SubjectUnknownMessage); }
        await source.RememberObjectsAsync(fresh, epoch, cancellationToken).ConfigureAwait(false);
        var target = new AuditTarget(subject.Dn, pc is null ? AuditObjectKind.User : AuditObjectKind.Computer, subject.Name, user?.SamAccountName ?? pc?.SamAccountName,
            subject.Guid, user?.Sid ?? pc?.Sid, pc?.DnsHostName, user?.PrimaryGroupId ?? pc?.PrimaryGroupId, user?.Description ?? pc?.Description);
        var audit = new AdAuditReader(source); var poste = new AdPosteReader(source); StepReading reading;
        try
        {
            switch (action.Id)
            {
                case "passwordPolicy":
                    var policy = await audit.PasswordPolicyAsync(target, cancellationToken).ConfigureAwait(false);
                    var known = policy.ResultantError is null && (policy.ResultantPso is null ? policy.Domain is not null : policy.Pso is not null);
                    reading = Result(action, policy.ReadAt, known ? Tone.Info : Tone.Warn, known ? "Stratégie applicable lue." : "Stratégie applicable non confirmée.",
                        [new("Source", policy.Pso?.Name ?? (known ? "Domaine" : "Non lue"), known ? Tone.Info : Tone.Warn),
                         new("Longueur minimale", Number(policy.Pso?.MinLength ?? (policy.ResultantPso is null ? policy.Domain?.MinLength : null)), Tone.Off),
                         new("Seuil de verrouillage", Number(policy.Pso?.LockoutThreshold ?? (policy.ResultantPso is null ? policy.Domain?.LockoutThreshold : null)), Tone.Off)], [],
                        policy.ResultantError ?? "Lecture de stratégie ; aucune modification de mot de passe."); break;
                case "groups":
                    var groups = await audit.NestedGroupsAsync(target, cancellationToken).ConfigureAwait(false);
                    Failed(groups.Nodes.IsEmpty && !groups.StartComplete, "Appartenances non lues ; aucune absence de groupe déduite.");
                    var partial = groups.Truncated || !groups.StartComplete || groups.Unread.Length > 0;
                    reading = Result(action, groups.ReadAt, partial ? Tone.Warn : Tone.Info, FrenchText.Count(groups.Nodes.Length, "groupe lu", "groupes lus"),
                        [new("Non lus", Number(groups.Unread.Length), groups.Unread.IsEmpty ? Tone.Off : Tone.Warn)],
                        [.. groups.Nodes.Select(g => new StepItem(g.Name, g.Dn, g.Partial ? Tone.Warn : Tone.Info))],
                        groups.TruncatedReason ?? "Appartenances LDAP ; elles ne démontrent pas à elles seules les droits effectifs.",
                        groups.Nodes.SelectMany(g => new[] { new KnownName(g.Name, "Groupe", "Groupe"), new KnownName(g.Dn, "Objet", "Identifiant") })); break;
                case "gpoLinks":
                    var links = await audit.GpoLinksAsync(AuditTargets.GpoContainerChain(subject.Dn, fresh.Domain.RootDn, target.Kind), cancellationToken).ConfigureAwait(false);
                    Refused(links.NamesState == ReadState.Refused || links.Containers.Any(c => c.State == ReadState.Refused));
                    Failed(!links.Containers.Any(c => c.State == ReadState.Read), "Liens GPO non lus ; aucune absence de stratégie déduite.");
                    reading = Result(action, links.ReadAt, links.NamesState == ReadState.Read && links.Containers.All(c => c.State == ReadState.Read) ? Tone.Info : Tone.Warn,
                        FrenchText.Count(links.Gpos.Length, "GPO nommée", "GPO nommées"), [], [.. links.Gpos.Select(g => new StepItem(g.Name, AuditGpoRules.StatusText(g.Flags), Tone.Info))],
                        links.NamesError ?? "Un lien de GPO ne prouve pas son application sur le poste ; lire RSoP séparément.", links.Gpos.Select(g => new KnownName(g.Name, "Objet", "GPO"))); break;
                case "gpoApplied":
                    var rsop = await audit.AppliedPoliciesAsync(target, cancellationToken).ConfigureAwait(false);
                    Refused(rsop.State == ReadState.Refused);
                    Failed(rsop.State != ReadState.Read && rsop.Gpos is null, "RSoP non lu ; aucune stratégie supposée appliquée ou absente.");
                    reading = Result(action, rsop.ReadAt, rsop.State == ReadState.Read ? Tone.Info : Tone.Warn, rsop.Message ?? "Dernier résultat RSoP reçu.", [],
                        [.. (rsop.Gpos ?? []).Select(g => new StepItem(g.Name ?? g.Guid?.ToString("D") ?? "Identité GPO non lue", g.AccessDenied == true ? "Filtrage de sécurité refusé" : "Déclaration RSoP ; ordre à vérifier", Tone.Info))],
                        rsop.LinksError ?? "Résultat du dernier traitement ; aucune actualisation de stratégie déclenchée.", (rsop.Gpos ?? []).Where(g => g.Name is not null).Select(g => new KnownName(g.Name!, "Objet", "GPO"))); break;
                case "machineIdentity":
                    var identity = await audit.MachineIdentityAsync(target, cancellationToken).ConfigureAwait(false); Refused(identity.Reported.State == ReadState.Refused);
                    reading = Result(action, identity.ReadAt, identity.Reported.State == ReadState.Read ? Tone.Info : Tone.Warn, "Identités DNS et Windows consultées.",
                        [new("Windows", identity.Reported.ComputerName ?? "Non lu", Tone.Off), new("Domaine Windows", identity.Reported.Domain ?? "Non lu", Tone.Off)],
                        [.. identity.Resolution.Addresses.Select(ip => new StepItem(ip, "Réponse DNS", Tone.Info))], identity.Reported.Message ?? identity.Resolution.Message ?? "Un nom DNS seul n’est pas une preuve d’identité Windows.",
                        identity.Resolution.Addresses.Concat(new[] { identity.Reported.ComputerName, identity.Reported.Domain }.OfType<string>()).Select(n => new KnownName(n, "Objet", "Identifiant"))); break;
                case "diagnostics":
                    var diagnostic = await poste.DiagnosticAsync(subject.Dn, null, cancellationToken).ConfigureAwait(false);
                    reading = Result(action, diagnostic.At, diagnostic.Failed > 0 || diagnostic.Inconclusive > 0 || diagnostic.NotTried > 0 ? Tone.Warn : Tone.Info, diagnostic.Verdict, [],
                        [.. diagnostic.Rows.Select(r => new StepItem(r.Label, r.StatusLabel + " · " + r.Detail, r.Status == "OK" ? Tone.Info : Tone.Warn))], diagnostic.Notice ?? "Lecture ponctuelle ; aucun service, port ou pare-feu modifié."); break;
                case "inventory": case "inventoryDeep":
                    var inventory = await poste.InventoryAsync(subject.Dn, action.Id == "inventoryDeep", PosteHealthPolicy.Default, null, cancellationToken).ConfigureAwait(false);
                    Refused(inventory.Access.Length > 0 && inventory.Access.All(a => a.Status == SourceStatus.Refused));
                    Failed(!inventory.Access.Any(a => a.Status is SourceStatus.Ok or SourceStatus.Empty) && inventory.Rows.IsEmpty, inventory.Notice ?? "Aucune source d’inventaire lue ; aucun résultat disponible.");
                    reading = Result(action, inventory.CollectedAt, inventory.Partial ? Tone.Warn : Tone.Info, inventory.Summary,
                        [.. inventory.Access.Select(a => new StepFact(a.Category, a.StatusLabel, a.Tone))], [.. inventory.Rows.Select(r => new StepItem(r.Label, r.Value, Tone.Off))],
                        inventory.Notice ?? "Valeurs reçues pendant ce relevé ; sources non lues laissées inconnues."); break;
                case "software":
                    var software = await poste.SoftwareAsync(subject.Dn, new(false, false, false), cancellationToken).ConfigureAwait(false);
                    Refused(software.Access.Length > 0 && software.Access.All(a => a.Status == SourceStatus.Refused));
                    Failed(!software.Access.Any(a => a.Status is SourceStatus.Ok or SourceStatus.Empty) && software.Rows.IsEmpty, software.Notice ?? "Aucune source logicielle lue ; zéro logiciel ne peut pas être conclu.");
                    reading = Result(action, software.ReadAt ?? Now, software.Complete ? Tone.Info : Tone.Warn, software.AccessSummary, [],
                        [.. software.Rows.Select(s => new StepItem(s.Name, s.Version, Tone.Off))], software.Notice ?? software.NotCovered ?? "Logiciels machine seulement ; aucune classe MSI réparatrice ni désinstallation exécutée."); break;
                case "sessions":
                    var sessions = await poste.SessionsAsync(subject.Dn, cancellationToken).ConfigureAwait(false);
                    Refused(sessions.ReadState == FactState.Refused);
                    Failed(sessions.ReadState != FactState.Observed && sessions.Rows.IsEmpty, "Sessions non lues ; aucune absence de session déduite.");
                    reading = Result(action, sessions.ReadAt ?? Now, sessions.Partial || sessions.ReadState != FactState.Observed ? Tone.Warn : Tone.Info, sessions.StatusText,
                        [new("Comptes non lus", Number(sessions.UnreadSessions), sessions.UnreadSessions > 0 ? Tone.Warn : Tone.Off)],
                        [.. sessions.Rows.Select(s => new StepItem(s.User, s.State + " · " + s.Protocol, Tone.Info))], "Consultation seulement ; aucune session déconnectée.", sessions.Rows.SelectMany(r => new[] { r.User, r.Login, r.ClientName }.OfType<string>().Select(n => new KnownName(n, "Compte", "Compte")))); break;
                case "lockoutEvents":
                    reading = await LockoutsAsync(action, user!, fresh.Domain, cancellationToken).ConfigureAwait(false); break;
                default: throw new DomeniaOperationException(AssistanceErrors.StepUnknown, AssistanceErrors.StepUnknownMessage);
            }
            Current(epoch);
            var after = await AdSupportObjects.ReadAsync(source, subject.Dn, subject.Guid, cancellationToken).ConfigureAwait(false);
            if (user is not null ? after.Users.SingleOrDefault()?.WhenCreated != user.WhenCreated : after.Computers.SingleOrDefault()?.WhenCreated != pc!.WhenCreated)
            { throw new DomeniaOperationException(AssistanceErrors.SubjectMismatch, "Identité du sujet modifiée pendant la lecture ; résultat écarté."); }
            Current(epoch);
            return reading with { Mentions = [.. reading.Cited, new(subject.Name, "Objet", "Objet"), new(subject.Login, "Compte", "Compte"),
                new(subject.Dn, "Objet", "Identifiant"), new(subject.Guid.ToString("D"), "Objet", "Identifiant"),
                .. new[] { pc?.DnsHostName, user?.UserPrincipalName, user?.Mail }.OfType<string>().Select(n => new KnownName(n, "Objet", "Identifiant"))] };
        }
        catch (DomeniaOperationException ex) when (AdSupportObjects.Denied(ex)) { throw new DomeniaOperationException(AssistanceErrors.ReadRefused, "Lecture refusée pour le compte sélectionné ; aucun autre compte essayé."); }
    }

    private static void Failed(bool failed, string message)
    { if (failed) { throw new DomeniaOperationException(AssistanceErrors.ReadFailed, message); } }
    private static void Refused(bool refused)
    { if (refused) { throw new DomeniaOperationException(AssistanceErrors.ReadRefused, "Lecture refusée par la cible ; aucune donnée supposée et aucun nouvel essai."); } }
    private static string Number(int? value) => value?.ToString(CultureInfo.InvariantCulture) ?? "Non lu";
    private static StepReading Result(AssistanceAction action, DateTimeOffset at, Tone tone, string summary, ImmutableArray<StepFact> facts, ImmutableArray<StepItem> items, string limit, IEnumerable<KnownName>? mentions = null) =>
        new(action.Id, action.Operation, action.Label, at, tone, summary, [.. facts.Take(32)], [.. items.Take(50)], Math.Max(0, items.Length - 50), limit, [.. mentions ?? []]);

    private async Task<StepReading> LockoutsAsync(AssistanceAction action, DirectoryUser user, DomainInfo domain, CancellationToken token)
    {
        using var stop = CancellationTokenSource.CreateLinkedTokenSource(token); stop.CancelAfter(TimeSpan.FromSeconds(35));
        using var access = await AdReadAccess.AcquireAsync(source, CredentialRules.Directory, user.DistinguishedName, stop.Token).ConfigureAwait(false);
        async Task<AdEntry> One(string dn, string attribute)
        {
            var rows = await access.SearchAsync(new(dn, "(objectClass=*)", AdSearchScope.Base, [attribute]) { SizeLimit = 2, PageSize = 1, Timeout = TimeSpan.FromSeconds(5), Budget = TimeSpan.FromSeconds(5) }, stop.Token).ConfigureAwait(false);
            return rows.Count == 1 && DistinguishedName.AreEqual(rows[0].DistinguishedName, dn) ? rows[0] : throw new DomeniaOperationException(AssistanceErrors.ReadFailed, "Identité du PDC non confirmée.");
        }
        var owner = (await One(domain.RootDn, "fSMORoleOwner").ConfigureAwait(false)).String("fSMORoleOwner")
            ?? throw new DomeniaOperationException(AssistanceErrors.ReadFailed, "Rôle PDC non lisible.");
        var root = await access.RootDseAsync(stop.Token).ConfigureAwait(false);
        if (root.ConfigurationNamingContext is not { } configuration || !ScopeRules.Contains(new(configuration, "Configuration", true), owner))
        { throw new DomeniaOperationException(AssistanceErrors.ReadFailed, "Propriétaire PDC hors partition de configuration."); }
        // Configuration is read through the same selected identity and the explicitly checked partition.
        var parent = DistinguishedName.Parent(owner) ?? throw new DomeniaOperationException(AssistanceErrors.ReadFailed, "Conteneur du PDC absent.");
        var servers = await access.SearchForestAsync(new(parent, "(objectClass=server)", AdSearchScope.Base, ["dNSHostName"])
            { SizeLimit = 2, PageSize = 1, Timeout = TimeSpan.FromSeconds(5), Budget = TimeSpan.FromSeconds(5) }, stop.Token).ConfigureAwait(false);
        var host = servers.Count == 1 && DistinguishedName.AreEqual(servers[0].DistinguishedName, parent) ? servers[0].String("dNSHostName") : null;
        if (host is null || !CimQuery.IsHostName(host) || !host.EndsWith("." + domain.DnsName, StringComparison.OrdinalIgnoreCase)) { throw new DomeniaOperationException(AssistanceErrors.ReadFailed, "Nom DNS du PDC non confirmé."); }
        using var credential = access.CopyNativeCredential();
        LockoutEventsRead events;
        if (LockoutsOverride is { } read) { events = await read(host, user.Sid, credential, stop.Token).ConfigureAwait(false); }
        else
        {
            var split = credential.Account.IndexOf('\\');
            events = await new WindowsLockoutReader(source.Clock).ReadAsync(host, user.Sid, true, Now.AddDays(-7), Now, 200,
                credential.Session ? null : split < 0 ? credential.Account : credential.Account[(split + 1)..],
                credential.Session || split < 0 ? null : credential.Account[..split], credential.Password, stop.Token).ConfigureAwait(false);
        }
        access.EnsureCurrent(); if (events.State == LockoutReadState.Refused) { access.ReportNativeRefusal(false); Refused(true); }
        Failed(events.State != LockoutReadState.Read, "Journal Sécurité du PDC non lu ; aucun événement inventé et aucun nouvel essai.");
        return Result(action, Now, events.State == LockoutReadState.Read ? Tone.Info : Tone.Warn,
            events.State == LockoutReadState.Read ? FrenchText.Count(events.Events.Length, "événement 4740 reçu", "événements 4740 reçus") : "Journal Sécurité non lu.",
            [new("Contrôleur PDC", host, Tone.Info)], [.. events.Events.Select(e => new StepItem(Date(e.At), e.CallerComputer ?? "Poste appelant non renseigné", Tone.Info))],
            events.Truncated ? "200 événements atteints ; fenêtre non exhaustive." : "Sept derniers jours, SID exact ; zéro événement visible ne prouve pas l’absence historique de verrouillage.",
            new[] { host }.Concat(events.Events.Select(e => e.CallerComputer).OfType<string>()).Select(n => new KnownName(n, "Machine", "Machine")));
    }
}
