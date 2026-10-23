using System.Text.Json;
using Domenia.Core;
using Domenia.Core.Poste;

namespace Domenia.Bridge;

/// <summary>Local operations (authorizations, commands, suite tools, dsregcmd, BIOS references) and plans of the console.</summary>
public sealed partial class PosteOperations
{
    private static IEnumerable<OperationDefinition> LocalOperations(EngineContext context, PosteSession session, ScreenReaders readers)
    {
        DateTimeOffset Now() => context.Clock.GetUtcNow();

        ConsentKind Kind(IReadOnlyDictionary<string, JsonElement> values) => BridgeArguments.GetString(values, "kind") switch
        {
            "intervention" => ConsentKind.Intervention,
            "readFallback" => ConsentKind.ReadFallback,
            _ => throw BridgeArguments.Invalid(FrenchText.Quote("kind") + " doit valoir intervention ou readFallback."),
        };

        async Task<string> NameAsync(string dn, CancellationToken ct)
        {
            var console = await readers.Require<IPosteReader>().OpenAsync(dn, PosteHealthPolicy.Default, session.State(dn, Now()), ct).ConfigureAwait(false);
            return console.Computer.Name;
        }

        yield return new OperationDefinition("poste.consent.grant", OperationClass.Local, async (args, _, ct) =>
        {
            var dn = Dn(args, ["kind", "minutes"]);
            var kind = Kind(dn.Values);
            var minutes = OptionalInt(dn.Values, "minutes", PosteSession.MinMinutes, PosteSession.MaxMinutes) ?? PosteSession.DefaultMinutes;
            await BindSessionAsync(context, session, ct).ConfigureAwait(false);
            var console = await readers.Require<IPosteReader>().OpenAsync(dn.Dn, PosteHealthPolicy.Default, session.State(dn.Dn, Now()), ct).ConfigureAwait(false);
            var name = console.Computer.Name;
            // An uncertain write on this workstation holds every authorization back (Domenia 1 PST-010, PST-011).
            if (await PendingWriteAsync(context, console.Computer.Guid, ct).ConfigureAwait(false))
            {
                session.NoteRefusal(kind, name, "Une écriture sur ce poste reste « à vérifier ».", Now());
                throw new DomeniaOperationException(PosteErrors.Pending, PosteErrors.PendingMessage);
            }
            session.Grant(kind, dn.Dn, name, minutes, Now(), console.Computer.Guid);
            context.Journal.Add(new JournalEntry(Now(), (kind == ConsentKind.Intervention ? "Intervention autorisée sur " : "Lecture de repli autorisée sur ") + name + " (" + FrenchText.Count(minutes, "minute", "minutes") + ")", Tone.Info));
            return new { consent = session.State(dn.Dn, Now()), history = session.History(Now()) };
        }, "Autorise pour 1 à 15 min (5 par défaut), sur ce seul poste, l’intervention ou une seule lecture de repli ; refusé pendant une écriture à vérifier ; ne lance rien.");

        yield return new OperationDefinition("poste.consent.revoke", OperationClass.Local, (args, _, _) =>
        {
            var dn = Dn(args, ["kind"]);
            var kind = Kind(dn.Values);
            var removed = session.Revoke(kind, dn.Dn, Now());
            if (removed)
            {
                context.Journal.Add(new JournalEntry(Now(), kind == ConsentKind.Intervention ? "Autorisation d’intervention retirée" : "Lecture de repli retirée", Tone.Info));
            }
            return Task.FromResult<object?>(new { removed, consent = session.State(dn.Dn, Now()), history = session.History(Now()) });
        }, "Retire tout de suite une autorisation de la session.");

        yield return new OperationDefinition("poste.consent.history", OperationClass.Local, (args, _, _) =>
        {
            BridgeArguments.RequireNone(args);
            return Task.FromResult<object?>(session.History(Now()));
        }, "Journal des autorisations accordées, retirées, expirées ou utilisées dans la session.");

        yield return new OperationDefinition("poste.commands", OperationClass.LocalRead, async (args, _, ct) =>
        {
            var dn = Dn(args, []);
            var reader = readers.Require<IPosteReader>();
            var console = await reader.OpenAsync(dn.Dn, PosteHealthPolicy.Default, session.State(dn.Dn, Now()), ct).ConfigureAwait(false);
            return PosteRemote.Commands(console.Computer.DnsName ?? console.Computer.Name, reader.Options.OperationsAccount);
        }, "Commandes à coller dans la console du technicien (Enter-PSSession, Invoke-Command, mstsc, chemin UNC) ; jamais un mot de passe.");

        yield return new OperationDefinition("poste.suite.plan", OperationClass.LocalRead, async (args, _, ct) =>
        {
            var dn = Dn(args, ["tool"]);
            var tool = BridgeArguments.GetString(dn.Values, "tool");
            var reader = readers.Require<IPosteReader>();
            var definition = reader.Options.SuiteTools.FirstOrDefault(t => t.Id == tool) ?? throw BridgeArguments.Invalid(FrenchText.Quote("tool") + " doit valoir pesto ou filpro.");
            var console = await reader.OpenAsync(dn.Dn, PosteHealthPolicy.Default, session.State(dn.Dn, Now()), ct).ConfigureAwait(false);
            var info = await context.Directory.GetSessionAsync(ct).ConfigureAwait(false);
            var plan = PosteRemote.Suite(definition.Label, null, SuiteContext(console, info), explicitGesture: true);
            var launcher = readers.Find<IPosteToolLauncher>() is not null;
            var text = !definition.Configured ? definition.Reason
                : launcher ? "Ouverture par le poste d’administration après contrôle du contrat (suite-contract.json) et de l’empreinte de l’outil."
                : "Aucun lanceur dans cet affichage : le plan reste consultable, rien n’est lancé.";
            return new { tool = definition, plan, launched = false, canLaunch = definition.Configured && launcher, text };
        }, "Plan d’ouverture de Pesto ou FILPRO avec le contexte du poste (champs déclarés et validés seulement) ; rien n’est lancé.");

        // Local base in simulation; in directory mode the fallback search under the root is a directory read (docs/ops/poste.md § 8.1).
        var groupsClass = context.Mode == AppMode.Simulation ? OperationClass.LocalRead : OperationClass.NetworkRead;
        yield return new OperationDefinition("poste.groups.search", groupsClass, async (args, _, ct) =>
        {
            var values = ReadOptionalObject(args, ["text"]);
            var text = BridgeArguments.GetOptionalString(values, "text");
            if (text?.Length > MaxTextLength)
            {
                throw BridgeArguments.Invalid(FrenchText.Quote("text") + " doit faire au plus " + FrenchText.Integer(MaxTextLength) + " caractères.");
            }
            return await readers.Require<IPosteReader>().GroupsAsync(text, ct).ConfigureAwait(false);
        }, "Groupes de l’annuaire dont le nom contient le texte (50 au plus), pour choisir une appartenance\u00A0; base locale d’abord.");

        yield return new OperationDefinition("poste.dsreg.analyze", OperationClass.Local, async (args, _, ct) =>
        {
            var dn = Dn(args, ["text", "collectedAs", "endUser"]);
            var text = BridgeArguments.GetString(dn.Values, "text");
            if (text.Length > MaxDsregLength * 2)
            {
                throw BridgeArguments.Invalid(FrenchText.Quote("text") + " doit faire au plus 128 Kio.");
            }
            var collected = BridgeArguments.GetOptionalString(dn.Values, "collectedAs") switch
            {
                "endUser" => DsregCollector.EndUserSession,
                "admin" => DsregCollector.AdministrativeAccount,
                null or "unknown" => DsregCollector.Unknown,
                _ => throw BridgeArguments.Invalid(FrenchText.Quote("collectedAs") + " doit valoir endUser, admin ou unknown."),
            };
            var endUser = BridgeArguments.GetOptionalString(dn.Values, "endUser");
            if (endUser?.Length > 256)
            {
                throw BridgeArguments.Invalid(FrenchText.Quote("endUser") + " doit faire au plus 256 caractères.");
            }
            var name = await NameAsync(dn.Dn, ct).ConfigureAwait(false);
            return PosteDsreg.Analyze(text, collected, endUser, name, Now());
        }, "Analyse un texte dsregcmd /status collé (128 Kio au plus) : jonction, SSO selon la session de collecte ; rien n’est exécuté ni réparé.");

        yield return new OperationDefinition("poste.bios.reference", OperationClass.LocalWrite, async (args, _, ct) =>
        {
            var dn = Dn(args, ["action"]);
            var action = BridgeArguments.GetString(dn.Values, "action");
            if (action is not ("approve" or "remove"))
            {
                throw BridgeArguments.Invalid(FrenchText.Quote("action") + " doit valoir approve ou remove.");
            }
            var reader = readers.Require<IPosteReader>();
            var store = await reader.ProbeStoreAsync(dn.Dn, ct).ConfigureAwait(false);
            var system = store.Data?.System;
            var bios = store.Data?.Bios;
            if (system is null || bios is null)
            {
                throw new DomeniaOperationException(PosteErrors.Refused, "BIOS ou modèle non relevé pour ce poste : actualisez les sondes avant d’approuver une version.");
            }
            var book = await BiosBookAsync(context, ct).ConfigureAwait(false);
            try
            {
                book = action == "approve"
                    ? BiosReferences.Approve(book, new BiosReference(system.Manufacturer, system.Model, bios.Version, Now()))
                    : BiosReferences.Remove(book, system.Manufacturer, system.Model);
            }
            catch (Exception ex) when (ex is ArgumentException or InvalidOperationException)
            {
                throw new DomeniaOperationException(PosteErrors.Refused, "Référence BIOS refusée : modèle et version de 1 à 128 caractères, 500 modèles au plus.");
            }
            await SaveBiosBookAsync(context, book, ct).ConfigureAwait(false);
            context.Journal.Add(new JournalEntry(Now(), (action == "approve" ? "Version BIOS approuvée pour " : "Référence BIOS retirée pour ") + system.Manufacturer + " " + system.Model, Tone.Info));
            return PosteReadings.Build(store, PosteHealthPolicy.Default, book, Now(), context.Clock.LocalTimeZone);
        }, "Approuve la version BIOS du poste pour son modèle, ou retire la référence (réglage local du domaine, aucune action sur le poste).");
    }

    /// <summary>True when a receipt of this mode is still « à vérifier » for the workstation (by GUID).</summary>
    private static async Task<bool> PendingWriteAsync(EngineContext context, Guid computer, CancellationToken cancellationToken)
    {
        ReceiptLog log;
        try
        {
            log = await context.Receipts.ReadAllAsync(cancellationToken).ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            // Receipts unreadable for now: nothing is granted while an uncertain write cannot be ruled out (fail closed).
            context.Log.Warning($"Reçus illisibles avant une autorisation du poste : {ex.GetType().Name}.");
            return true;
        }
        var id = computer.ToString("D");
        return log.Receipts.Any(r => WriteReceipts.IsPending(r) && string.Equals(r.Plan.Target.ObjectGuid, id, StringComparison.OrdinalIgnoreCase));
    }

    private static IEnumerable<OperationDefinition> PlanOperations(EngineContext context, OperationClass planClass, ScreenReaders readers)
    {
        var writers = context.Writers;
        var circuit = WriteCircuit.From(context);

        async Task<object?> Seal(Task<WritePlanDraft> draft, CancellationToken ct) =>
            await circuit.PlanAsync(await draft.ConfigureAwait(false), ct).ConfigureAwait(false);

        yield return new OperationDefinition("poste.account.plan", planClass, (args, _, ct) =>
        {
            var dn = Dn(args, ["enable"]);
            var enable = BridgeArguments.GetBoolean(dn.Values, "enable");
            return Seal(writers.Require<IPosteAccountStateExecutor>().PlanAsync(dn.Dn, enable, ct), ct);
        }, "Plan de l’activation ou de la désactivation du compte ordinateur ; rien n’est écrit.");

        yield return new OperationDefinition("poste.profile.plan", planClass, (args, _, ct) =>
        {
            var dn = Dn(args, ["description", "location", "managedBy"]);
            var managedBy = BridgeArguments.GetOptionalString(dn.Values, "managedBy");
            if (!string.IsNullOrWhiteSpace(managedBy))
            {
                BridgeArguments.RequireDistinguishedName(managedBy, "managedBy");
            }
            return Seal(writers.Require<IPosteProfileExecutor>().PlanAsync(dn.Dn, BridgeArguments.GetOptionalString(dn.Values, "description"), BridgeArguments.GetOptionalString(dn.Values, "location"), managedBy, ct), ct);
        }, "Plan de l’enregistrement de la fiche du poste (description, emplacement, géré par) ; rien n’est écrit.");

        yield return new OperationDefinition("poste.rename.plan", planClass, (args, _, ct) =>
        {
            var dn = Dn(args, ["name"]);
            var name = BridgeArguments.GetString(dn.Values, "name");
            if (name.Length is 0 or > PosteDirectoryWrites.MaxObjectName)
            {
                throw BridgeArguments.Invalid(FrenchText.Quote("name") + " doit faire de 1 à 63 caractères.");
            }
            return Seal(writers.Require<IPosteRenameExecutor>().PlanAsync(dn.Dn, name, ct), ct);
        }, "Plan du renommage de l’objet ordinateur dans l’annuaire (CN seulement : nom de compte, nom DNS et nom Windows inchangés) ; rien n’est écrit.");

        yield return new OperationDefinition("poste.group.plan", planClass, (args, _, ct) =>
        {
            var dn = Dn(args, ["group", "add"]);
            var group = BridgeArguments.RequireDistinguishedName(BridgeArguments.GetString(dn.Values, "group"), "group");
            return Seal(writers.Require<IPosteGroupExecutor>().PlanAsync(dn.Dn, group, BridgeArguments.GetBoolean(dn.Values, "add"), ct), ct);
        }, "Plan de l’ajout du poste à un groupe ou de son retrait ; rien n’est écrit.");

        yield return new OperationDefinition("poste.move.plan", planClass, (args, _, ct) =>
        {
            var dn = Dn(args, ["ou"]);
            var ou = BridgeArguments.RequireDistinguishedName(BridgeArguments.GetString(dn.Values, "ou"), "ou");
            return Seal(writers.Require<IPosteMoveExecutor>().PlanAsync(dn.Dn, ou, ct), ct);
        }, "Plan du déplacement du poste vers une autre OU ; rien n’est écrit.");

        yield return new OperationDefinition("poste.restart.plan", planClass, (args, _, ct) =>
        {
            var dn = Dn(args, ["mode", "minutes", "message"]);
            var mode = BridgeArguments.GetString(dn.Values, "mode");
            var minutes = OptionalInt(dn.Values, "minutes", 1, 60);
            var message = BridgeArguments.GetOptionalString(dn.Values, "message");
            if (message?.Length > 2000)
            {
                throw BridgeArguments.Invalid(FrenchText.Quote("message") + " est trop long.");
            }
            var reader = readers.Require<IPosteReader>();
            var name = PosteText.ShortName(DistinguishedName.Parse(dn.Dn)[0].Value);
            var (check, request) = PosteRemote.Restart(name, mode, minutes, message, reader.Options.UseWinRm);
            if (!check.Valid || request is null)
            {
                throw new DomeniaOperationException(PosteErrors.Refused, check.Reason);
            }
            return Seal(writers.Require<IPosteRestartExecutor>().PlanAsync(dn.Dn, request, ct), ct);
        }, "Plan du redémarrage (différé avec message par WinRM, ou immédiat), sessions lues d’abord ; rien n’est envoyé.");

        yield return new OperationDefinition("poste.restartCancel.plan", planClass, (args, _, ct) =>
            Seal(writers.Require<IPosteRestartCancelExecutor>().PlanAsync(Dn(args, []).Dn, ct), ct),
            "Plan de l’annulation d’un redémarrage différé encore en attente (shutdown /a) ; rien n’est envoyé.");

        yield return new OperationDefinition("poste.gpupdate.plan", planClass, (args, _, ct) =>
        {
            var dn = Dn(args, []);
            if (!readers.Require<IPosteReader>().Options.UseWinRm)
            {
                throw new DomeniaOperationException(PosteErrors.Refused, "Actualisation des stratégies indisponible : WinRM est désactivé par la configuration (Remote.UseWinRM). Rien n’est préparé.");
            }
            return Seal(writers.Require<IPosteGpUpdateExecutor>().PlanAsync(dn.Dn, ct), ct);
        }, "Plan de l’actualisation des stratégies (gpupdate /force par WinRM) ; rien n’est envoyé.");

        yield return new OperationDefinition("poste.service.plan", planClass, (args, _, ct) =>
        {
            var dn = Dn(args, ["name", "action"]);
            var name = BridgeArguments.GetString(dn.Values, "name");
            if (!PosteServices.IsValidName(name))
            {
                throw BridgeArguments.Invalid(FrenchText.Quote("name") + " doit être un nom de service valide.");
            }
            var action = BridgeArguments.GetString(dn.Values, "action");
            if (action is not ("start" or "restart" or "stop"))
            {
                throw BridgeArguments.Invalid(FrenchText.Quote("action") + " doit valoir start, restart ou stop.");
            }
            return Seal(writers.Require<IPosteServiceExecutor>().PlanAsync(dn.Dn, name, action, ct), ct);
        }, "Plan du démarrage, du redémarrage ou de l’arrêt d’un service (type de démarrage jamais modifié) ; rien n’est envoyé.");

        yield return new OperationDefinition("poste.run.plan", planClass, (args, _, ct) =>
        {
            var dn = Dn(args, ["mode", "command", "arguments", "user", "elevated"]);
            var name = PosteText.ShortName(DistinguishedName.Parse(dn.Dn)[0].Value);
            var (check, request) = PosteRemote.Run(name, BridgeArguments.GetString(dn.Values, "mode"), BridgeArguments.GetString(dn.Values, "command"),
                BridgeArguments.GetOptionalString(dn.Values, "arguments"), BridgeArguments.GetOptionalString(dn.Values, "user"), OptionalBool(dn.Values, "elevated") ?? true);
            if (!check.Valid || request is null)
            {
                throw new DomeniaOperationException(PosteErrors.Refused, check.Reason);
            }
            return Seal(writers.Require<IPosteRunExecutor>().PlanAsync(dn.Dn, request, ct), ct);
        }, "Plan de l’exécution d’un programme du poste par une tâche planifiée unique (autorisation d’intervention requise) ; rien n’est envoyé.");

        yield return new OperationDefinition("poste.wake.plan", planClass, (args, _, ct) =>
            Seal(writers.Require<IPosteWakeExecutor>().PlanAsync(Dn(args, []).Dn, ct), ct),
            "Plan du réveil du poste (Wake-on-LAN, un seul poste, sous-réseau autorisé) ; rien n’est envoyé.");
    }
}
