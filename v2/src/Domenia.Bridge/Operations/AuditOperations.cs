using System.Collections.Immutable;
using System.Text.Json;
using Domenia.Core;

namespace Domenia.Bridge;

/// <summary>
/// « Audit AD » screen (docs/ops/audit.md): security findings of the domain, controllers, identities of an OU, and the reads
/// on one object (password policy, nested groups, delegations, GPO, workstation identity, relations). Read only: no write
/// operation, no plan. Network reads (NetworkRead) leave only on the operator's gesture, bounded, and are served by the
/// fictitious directory in simulation; the local estimates (Local) reuse what was read, never the directory.
/// </summary>
public sealed class AuditOperations : IOperationModule
{
    public const int MaxSearchLength = 100;
    public const int MaxIdLength = 64;
    public const int MaxSidLength = 184;

    /// <summary>Sanity bound of the « controllers » array; the rule of 10 controllers at most is the audit's own (audit.controllersInvalid).</summary>
    public const int MaxControllerItems = 100;

    private static readonly string[] DnArguments = ["dn"];
    private static readonly string[] TextArguments = ["text"];
    private static readonly string[] IdArguments = ["id"];
    private static readonly string[] ControllersArguments = ["controllers"];
    private static readonly string[] CompareArguments = ["dn", "controllers"];
    private static readonly string[] GroupArguments = ["dn", "groupDn"];
    private static readonly string[] SidArguments = ["dn", "sid"];
    private static readonly string[] HistoryArguments = ["dn", "limit"];
    private static readonly string[] ScanArguments = ["dn", "subtree"];

    public string Screen => "audit";

    public IEnumerable<OperationDefinition> CreateOperations(EngineContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        var audit = AuditService.From(context);

        OperationDefinition Network(string name, Func<JsonElement, CancellationToken, Task<object?>> run, string description) =>
            new(name, OperationClass.NetworkRead, (args, _, ct) => run(args, ct), description, ServedInSimulation: true);

        OperationDefinition LocalRead(string name, Func<JsonElement, CancellationToken, Task<object?>> run, string description) =>
            new(name, OperationClass.LocalRead, (args, _, ct) => run(args, ct), description);

        OperationDefinition Local(string name, Func<JsonElement, CancellationToken, Task<object?>> run, string description) =>
            new(name, OperationClass.Local, (args, _, ct) =>
            {
                ct.ThrowIfCancellationRequested();
                return run(args, ct);
            }, description);

        return
        [
            LocalRead("audit.target", async (args, ct) => await audit.TargetViewAsync(Dn(args), ct).ConfigureAwait(false),
                "Objet audité d’un DN (index local) et lectures qui le concernent, avec le motif sinon."),
            LocalRead("audit.objects.search", async (args, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, TextArguments);
                var text = BridgeArguments.GetString(values, "text");
                if (text.Length > MaxSearchLength)
                {
                    throw BridgeArguments.Invalid(FrenchText.Quote("text") + " doit faire au plus " + FrenchText.Integer(MaxSearchLength) + " caractères.");
                }
                return await audit.SearchAsync(text, ct).ConfigureAwait(false);
            }, "Au plus 20 objets dont le nom, le compte ou le nom DNS contient le texte (index local)."),
            LocalRead("audit.suggestions", async (args, ct) =>
            {
                BridgeArguments.RequireNone(args);
                return await audit.SuggestionsAsync(ct).ConfigureAwait(false);
            }, "Objets proposés avant toute recherche (compte de la session, OU de travail, racine, Admins du domaine par son RID), vérifiés dans l’index local."),

            Local("audit.catalogue", (args, _) =>
            {
                BridgeArguments.RequireNone(args);
                return Task.FromResult<object?>(AuditFindings.Checks());
            }, "Contrôles de l’analyse du domaine, avec leur gravité quand ils trouvent un écart ; aucune lecture."),
            Network("audit.overview", async (args, ct) =>
            {
                BridgeArguments.RequireNone(args);
                return await audit.OverviewAsync(ct).ConfigureAwait(false);
            }, "Vue du domaine section par section et constats de sécurité par gravité, après le geste « Analyser le domaine »."),
            Local("audit.finding.objects", async (args, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, IdArguments);
                var id = BridgeArguments.GetString(values, "id");
                if (id.Length is 0 or > MaxIdLength)
                {
                    throw BridgeArguments.Invalid(FrenchText.Quote("id") + " doit être un identifiant de constat.");
                }
                return await audit.FindingObjectsAsync(id, ct).ConfigureAwait(false);
            }, "Objets d’un constat lus par la dernière analyse, sans relecture."),
            LocalRead("audit.localTotals", async (args, ct) =>
            {
                BridgeArguments.RequireNone(args);
                return await audit.LocalTotalsAsync(ct).ConfigureAwait(false);
            }, "Totaux de la copie locale par type, avec sa date ; jamais un dénombrement de l’annuaire."),

            Network("audit.dc.list", async (args, ct) =>
            {
                BridgeArguments.RequireNone(args);
                return await audit.ControllersAsync(ct).ConfigureAwait(false);
            }, "Contrôleurs du domaine (100 au plus) et émulateur PDC."),
            Network("audit.dc.probe", async (args, ct) =>
                await audit.ProbeAsync(Controllers(BridgeArguments.ReadObject(args, ControllersArguments)), ct).ConfigureAwait(false),
                "Diagnostic de 1 à 10 contrôleurs : DNS, LDAP 389, Kerberos 88, heure, synchronisation et réplication entrante."),
            Network("audit.dc.services", async (args, ct) =>
                await audit.ServicesAsync(Controllers(BridgeArguments.ReadObject(args, ControllersArguments)), ct).ConfigureAwait(false),
                "Services de l’annuaire de 1 à 10 contrôleurs lus par CIM (droits d’administration, confirmation de la page)."),
            Network("audit.dc.compare", async (args, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, CompareArguments);
                var dn = BridgeArguments.RequireDistinguishedName(BridgeArguments.GetString(values, "dn"), "dn");
                return await audit.CompareAsync(dn, Controllers(values), ct).ConfigureAwait(false);
            }, "Un objet lu sur chaque contrôleur choisi, avec version, date et contrôleur d’origine de chaque attribut."),

            Network("audit.object.policy", async (args, ct) => await audit.PolicyAsync(Dn(args), ct).ConfigureAwait(false),
                "Stratégie de mot de passe applicable à un compte utilisateur (msDS-ResultantPSO, domaine, échéance)."),
            Network("audit.object.groups", async (args, ct) => await audit.GroupsAsync(Dn(args), ct).ConfigureAwait(false),
                "Appartenances directes et imbriquées, cycles, groupe principal : 2 000 groupes, 16 niveaux au plus."),
            Local("audit.object.groupPath", async (args, ct) =>
            {
                var (dn, group) = GroupArgs(args);
                return await audit.GroupPathAsync(dn, group, ct).ConfigureAwait(false);
            }, "Plus court chemin d’appartenance dans les groupes déjà lus, sans relecture."),
            Network("audit.object.membership", async (args, ct) =>
            {
                var (dn, group) = GroupArgs(args);
                return await audit.MembershipAsync(dn, group, ct).ConfigureAwait(false);
            }, "Appartenance directe ou imbriquée confirmée par le contrôleur pour un groupe."),
            Network("audit.object.acl", async (args, ct) => await audit.DelegationsAsync(Dn(args), ct).ConfigureAwait(false),
                "Propriétaire et liste de contrôle d’accès (sans SACL), 1 000 entrées au plus."),
            Local("audit.object.estimate", async (args, ct) =>
            {
                var (dn, sid) = SidArgs(args);
                return await audit.EstimateAsync(dn, sid, ct).ConfigureAwait(false);
            }, "Estimation de neuf droits pour un bénéficiaire, sur les entrées déjà lues."),
            Network("audit.object.tokenGroups", async (args, ct) =>
            {
                var (dn, sid) = SidArgs(args);
                return await audit.TokenGroupsAsync(dn, sid, ct).ConfigureAwait(false);
            }, "Groupes de sécurité transitifs (tokenGroups) d’un bénéficiaire du domaine, puis estimation affinée."),
            Network("audit.object.gpoLinks", async (args, ct) => await audit.GpoLinksAsync(Dn(args), ct).ConfigureAwait(false),
                "gPLink et gPOptions de chaque OU au-dessus de l’objet et du domaine, noms et états des GPO."),
            Network("audit.object.gpoApplied", async (args, ct) => await audit.AppliedPoliciesAsync(Dn(args), ct).ConfigureAwait(false),
                "Dernier résultat GPO appliqué sur un poste (RSoP par CIM), confronté aux liens lus."),
            Network("audit.object.machineIdentity", async (args, ct) => await audit.MachineIdentityAsync(Dn(args), ct).ConfigureAwait(false),
                "Identité d’un poste vue par l’annuaire, le DNS (direct et inverse) et le poste lui-même."),
            LocalRead("audit.object.relations", async (args, ct) => await audit.RelationsAsync(Dn(args), ct).ConfigureAwait(false),
                "Affectation déclarée, dernière session observée et historique d’un utilisateur ou d’un poste (mémoire locale)."),
            LocalRead("audit.object.history", async (args, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, HistoryArguments);
                var dn = BridgeArguments.RequireDistinguishedName(BridgeArguments.GetString(values, "dn"), "dn");
                var limit = AuditService.HistoryLimit;
                if (values.TryGetValue("limit", out var raw) && raw.ValueKind != JsonValueKind.Null)
                {
                    if (raw.ValueKind != JsonValueKind.Number || !raw.TryGetInt32(out limit) || limit is < 1 or > AuditService.MaxHistoryLimit)
                    {
                        throw BridgeArguments.Invalid(FrenchText.Quote("limit") + " doit être un entier de 1 à " + FrenchText.Integer(AuditService.MaxHistoryLimit) + " ou null.");
                    }
                }
                return await audit.HistoryAsync(dn, limit, ct).ConfigureAwait(false);
            }, "Historique enregistré des associations d’un utilisateur ou d’un poste, base locale seulement (200 lignes par défaut)."),

            Network("audit.identities.scan", async (args, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, ScanArguments);
                var dn = BridgeArguments.RequireDistinguishedName(BridgeArguments.GetString(values, "dn"), "dn");
                var subtree = BridgeArguments.GetBoolean(values, "subtree");
                return await audit.IdentitiesAsync(dn, subtree, ct).ConfigureAwait(false);
            }, "Doublons, noms DNS partagés et noms recyclés des utilisateurs et postes d’une OU (5 000 objets), jamais le domaine entier."),
        ];
    }

    private static string Dn(JsonElement args)
    {
        var values = BridgeArguments.ReadObject(args, DnArguments);
        return BridgeArguments.RequireDistinguishedName(BridgeArguments.GetString(values, "dn"), "dn");
    }

    private static (string Dn, string GroupDn) GroupArgs(JsonElement args)
    {
        var values = BridgeArguments.ReadObject(args, GroupArguments);
        var dn = BridgeArguments.RequireDistinguishedName(BridgeArguments.GetString(values, "dn"), "dn");
        var group = BridgeArguments.RequireDistinguishedName(BridgeArguments.GetString(values, "groupDn"), "groupDn");
        return (dn, group);
    }

    private static (string Dn, string Sid) SidArgs(JsonElement args)
    {
        var values = BridgeArguments.ReadObject(args, SidArguments);
        var dn = BridgeArguments.RequireDistinguishedName(BridgeArguments.GetString(values, "dn"), "dn");
        var sid = BridgeArguments.GetString(values, "sid");
        if (sid.Length is < 5 or > MaxSidLength || !sid.StartsWith("S-1-", StringComparison.Ordinal) || !sid.Skip(4).All(c => char.IsAsciiDigit(c) || c == '-'))
        {
            throw BridgeArguments.Invalid(FrenchText.Quote("sid") + " doit être un identifiant de sécurité (S-1-…).");
        }
        return (dn, sid);
    }

    /// <summary>
    /// « controllers »: an array of texts (100 items at most, 254 characters each), else arguments.invalid. The rules of the
    /// audit decide the rest with audit.controllersInvalid (docs/ops/audit.md § 3): none chosen, more than 10, an invalid name,
    /// or a host that is not a controller of the last list of the domain.
    /// </summary>
    private static ImmutableArray<string> Controllers(IReadOnlyDictionary<string, JsonElement> values)
    {
        const string Message = " doit être un tableau de noms de contrôleurs.";
        if (!values.TryGetValue("controllers", out var raw) || raw.ValueKind != JsonValueKind.Array || raw.GetArrayLength() > MaxControllerItems)
        {
            throw BridgeArguments.Invalid(FrenchText.Quote("controllers") + Message);
        }
        var names = ImmutableArray.CreateBuilder<string>();
        foreach (var item in raw.EnumerateArray())
        {
            if (item.ValueKind != JsonValueKind.String || item.GetString() is not { Length: <= 254 } name)
            {
                throw BridgeArguments.Invalid(FrenchText.Quote("controllers") + Message);
            }
            names.Add(name);
        }
        return names.ToImmutable();
    }
}
