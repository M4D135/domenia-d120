using System.Collections.Immutable;
using System.Globalization;
using System.Text.RegularExpressions;

namespace Domenia.Core;

/// <summary>
/// GPO links read in AD against the result applied on the workstation (AUD-016, AUD-017; Domenia 1 ConvertFrom-DomeniaGpLink,
/// Resolve-DomeniaGpoView, Get-DomeniaRsopGpoOutcome, ConvertTo-DomeniaGpoAuditView). A linked GPO is announced applied only
/// when RSOP_GPLink gives it an applied order; an empty or partial RSoP answer is never « nothing applied ». Pure.
/// </summary>
public static partial class AuditGpoRules
{
    private const string RsopSource = "RSoP du poste (CIM root\\rsop\\computer, RSOP_GPO et RSOP_GPLink)";

    public sealed record GpLink(Guid? Guid, string GpoDn, string ContainerDn, int Position, bool LinkEnabled, bool Enforced);

    /// <summary>gPLink = « [LDAP://cn={GUID},cn=policies,cn=system,DC=…;N]… »: bit 1 of N = link disabled, bit 2 = enforced.</summary>
    public static ImmutableArray<GpLink> ParseGpLink(string? gpLink, string containerDn)
    {
        var links = ImmutableArray.CreateBuilder<GpLink>();
        if (string.IsNullOrEmpty(gpLink))
        {
            return links.ToImmutable();
        }
        var position = 0;
        foreach (Match item in GpLinkPattern().Matches(gpLink))
        {
            position++;
            var dn = item.Groups["dn"].Value;
            var guidMatch = GpoGuidPattern().Match(dn);
            Guid? guid = guidMatch.Success && Guid.TryParse(guidMatch.Groups["g"].Value, out var g) ? g : null;
            _ = int.TryParse(item.Groups["opt"].Value, NumberStyles.None, CultureInfo.InvariantCulture, out var options);
            links.Add(new GpLink(guid, dn, containerDn, position, (options & 1) == 0, (options & 2) != 0));
        }
        return links.ToImmutable();
    }

    public static string StatusText(int? flags) => flags switch
    {
        0 => "Activée",
        1 => "Paramètres utilisateur désactivés",
        2 => "Paramètres ordinateur désactivés",
        3 => "Toute la GPO désactivée",
        _ => "État non lu",
    };

    private sealed record Outcome(GpoOutcome Result, string Text, AuditFactState State);

    private static Outcome RsopOutcome(RsopGpoRead entry, IReadOnlyList<long?> orders, bool linksRead)
    {
        if (entry.AccessDenied == true)
        {
            return new(GpoOutcome.Filtered, "Non appliquée : refusée par le filtrage de sécurité selon RSoP", AuditFactState.Observed);
        }
        if (entry.FilterAllowed == false)
        {
            return new(GpoOutcome.Filtered, "Non appliquée : filtre WMI non satisfait selon RSoP", AuditFactState.Observed);
        }
        if (entry.Enabled == false)
        {
            return new(GpoOutcome.Disabled, "Non appliquée : GPO désactivée selon RSoP", AuditFactState.Observed);
        }
        if (linksRead)
        {
            if (orders.Count == 0)
            {
                return new(GpoOutcome.Unproven, "Non prouvé : présente dans RSoP sans lien enregistré (RSOP_GPLink)", AuditFactState.Unknown);
            }
            var best = -1L;
            var unreadable = 0;
            foreach (var order in orders)
            {
                if (order is long n && n >= 0)
                {
                    best = Math.Max(best, n);
                }
                else
                {
                    unreadable++;
                }
            }
            if (best > 0)
            {
                return new(GpoOutcome.Applied, "Appliquée selon RSoP du poste (ordre d’application " + FrenchText.Integer(best) + ")", AuditFactState.Observed);
            }
            return unreadable == 0
                ? new(GpoOutcome.NotApplied, "Non appliquée selon RSoP : ordre d’application nul (GPO vide, lien désactivé ou bloqué)", AuditFactState.Observed)
                : new(GpoOutcome.Unproven, "Non prouvé : ordre d’application illisible dans RSoP", AuditFactState.Unknown);
        }
        var favourable = entry.AccessDenied == false && entry.FilterAllowed == true && entry.Enabled == true;
        return favourable
            ? new(GpoOutcome.Unproven, "Non prouvé : présente dans RSoP, filtrage favorable, ordre d’application non lu", AuditFactState.Unknown)
            : new(GpoOutcome.Unproven, "Non prouvé : présente dans RSoP, filtrage non lu", AuditFactState.Unknown);
    }

    private static AuditFactState StateOf(ReadState state) => state switch
    {
        ReadState.Read or ReadState.Empty => AuditFactState.Observed,
        ReadState.Refused => AuditFactState.Refused,
        ReadState.Unavailable => AuditFactState.Unavailable,
        _ => AuditFactState.Unknown,
    };

    /// <summary>The links (or none read yet) and, for a workstation, the RSoP result: one row per link, then RSoP-only GPOs.</summary>
    public static AuditGpo View(string dn, ImmutableArray<string> chain, GpoLinksRead? links, RsopRead? rsop, string? computer)
    {
        ArgumentNullException.ThrowIfNull(dn);
        var names = new Dictionary<Guid, string>();
        var flags = new Dictionary<Guid, int?>();
        foreach (var gpo in links?.Gpos ?? [])
        {
            names[gpo.Guid] = gpo.Name;
            flags[gpo.Guid] = gpo.Flags;
        }
        var rsopState = rsop is null ? AuditFactState.Unknown : StateOf(rsop.State);
        var unproven = rsop is null ? "Non prouvé : résultat RSoP non demandé"
            : rsopState switch
            {
                AuditFactState.Refused => "Non prouvé : lecture RSoP refusée",
                AuditFactState.Unavailable => "Non prouvé : RSoP injoignable",
                AuditFactState.Observed => "Non prouvé : résultat RSoP non demandé",
                _ => "Non prouvé : lecture RSoP partielle ou au statut non reconnu",
            };
        var inRsop = new Dictionary<Guid, RsopGpoRead>();
        var orders = new Dictionary<Guid, List<long?>>();
        var linksRead = false;
        if (rsop is not null && rsopState == AuditFactState.Observed)
        {
            if (rsop.Gpos is not ImmutableArray<RsopGpoRead> gpos)
            {
                rsopState = AuditFactState.Unknown;
                unproven = "Non prouvé : réponse RSoP incomplète";
            }
            else
            {
                foreach (var entry in gpos.Where(e => e.Guid is not null))
                {
                    inRsop[entry.Guid!.Value] = entry;
                }
                if (gpos.Length == 0)
                {
                    rsopState = AuditFactState.Unknown;
                    unproven = "Non prouvé : résultat RSoP vide (journalisation RSoP désactivée ou aucun traitement enregistré)";
                }
            }
        }
        if (rsop is not null && rsopState == AuditFactState.Observed && rsop.Links is ImmutableArray<RsopLinkRead> rsopLinks)
        {
            foreach (var link in rsopLinks.Where(l => l.Guid is not null))
            {
                if (!orders.TryGetValue(link.Guid!.Value, out var list))
                {
                    orders[link.Guid.Value] = list = [];
                }
                list.Add(link.AppliedOrder);
            }
            linksRead = rsopLinks.Length > 0;
        }

        var rows = ImmutableArray.CreateBuilder<AuditGpoRow>();
        var linked = new HashSet<Guid>();
        var blockedBelow = false;
        var blockUnknown = false;
        var linksComplete = true;
        var containerCount = 0;
        var linkCount = 0;
        var unidentified = 0;
        foreach (var container in links?.Containers ?? [])
        {
            containerCount++;
            if (StateOf(container.State) != AuditFactState.Observed)
            {
                // Links and inheritance flag unknown for this level, and therefore for every level above it.
                linksComplete = false;
                blockUnknown = true;
                continue;
            }
            foreach (var link in ParseGpLink(container.GpLink, container.Dn))
            {
                linkCount++;
                var expected = "Non";
                if (link.LinkEnabled)
                {
                    if (link.Enforced || !blockedBelow)
                    {
                        expected = "Oui";
                    }
                    // A known block wins; an unread lower level leaves a non-enforced link undetermined.
                    if (blockUnknown && !blockedBelow && !link.Enforced)
                    {
                        expected = "Indéterminé";
                    }
                }
                var inheritance = blockedBelow && !link.Enforced ? "Bloquée par un conteneur inférieur" : containerCount == 1 ? "Lien direct" : "Héritée";
                var outcome = new Outcome(GpoOutcome.Unproven, unproven, rsopState);
                if (link.Guid is not Guid guid)
                {
                    unidentified++;
                    outcome = new Outcome(GpoOutcome.Unproven, "Non prouvé : GPO du lien non identifiée", AuditFactState.Unknown);
                }
                else if (rsopState == AuditFactState.Observed)
                {
                    outcome = inRsop.TryGetValue(guid, out var entry)
                        ? RsopOutcome(entry, orders.TryGetValue(guid, out var o) ? o : [], linksRead)
                        : new Outcome(GpoOutcome.NotApplied, "Absente du résultat RSoP du poste", AuditFactState.Observed);
                }
                string name;
                if (link.Guid is Guid id)
                {
                    linked.Add(id);
                    name = names.TryGetValue(id, out var n) ? n : inRsop.TryGetValue(id, out var r) && !string.IsNullOrEmpty(r.Name) ? r.Name : id.ToString("D");
                }
                else
                {
                    name = link.GpoDn;
                }
                var status = link.Guid is Guid gid && flags.TryGetValue(gid, out var f) ? StatusText(f) : "État non lu";
                rows.Add(new AuditGpoRow(
                    name,
                    link.Guid?.ToString("D"),
                    LinkedToLabel(container.Dn),
                    container.Dn,
                    link.LinkEnabled ? "Activé" : "Désactivé",
                    link.Enforced ? "Oui" : "Non",
                    inheritance,
                    expected,
                    outcome.Result,
                    outcome.Text,
                    outcome.State,
                    outcome.State == AuditFactState.Observed ? RsopSource : "Liens AD (gPLink) seulement",
                    status,
                    ToneOf(outcome.Result, expected, link.LinkEnabled)));
            }
            if ((container.GpOptions & 1) != 0)
            {
                blockedBelow = true;
            }
        }
        var outside = unidentified > 0 ? "Hors liens lus (site, stratégie locale, conteneur non lu ou lien non identifié)" : "Hors liens lus (site, stratégie locale ou conteneur non lu)";
        foreach (var (guid, entry) in inRsop.OrderBy(p => p.Key))
        {
            if (linked.Contains(guid))
            {
                continue;
            }
            var outcome = RsopOutcome(entry, orders.TryGetValue(guid, out var o) ? o : [], linksRead);
            var name = names.TryGetValue(guid, out var n) ? n : entry.Name ?? guid.ToString("D");
            rows.Add(new AuditGpoRow(name, guid.ToString("D"), string.Empty, null, outside, string.Empty, string.Empty, "Indéterminé",
                outcome.Result, outcome.Text, outcome.State, RsopSource, flags.TryGetValue(guid, out var f) ? StatusText(f) : "État non lu", ToneOf(outcome.Result, "Indéterminé", true)));
        }

        var facts = ImmutableArray.CreateBuilder<AuditFact>();
        if (links is not null)
        {
            var linkLimit = "Un lien ne prouve pas l’application : filtrage de sécurité, filtre WMI, blocage d’héritage, réplication ou poste non redémarré.";
            var linkState = AuditFactState.Observed;
            if (!linksComplete)
            {
                linkState = AuditFactState.Estimated;
                linkLimit = "Certains conteneurs n’ont pas été lus : liste de liens incomplète. " + linkLimit;
            }
            if (unidentified > 0)
            {
                linkLimit = FrenchText.Count(unidentified, "lien", "liens") + " sans GPO identifiable. " + linkLimit;
            }
            facts.Add(AuditPolicyRules.Fact("Liens GPO lus dans AD", FrenchText.Count(linkCount, "lien", "liens") + " sur " + FrenchText.Count(containerCount, "conteneur", "conteneurs"), linkState, "Attributs gPLink et gPOptions", linkLimit));
        }
        var appliedValue = unproven;
        var appliedState = rsopState;
        if (rsop is not null && rsopState == AuditFactState.Observed)
        {
            if (linksRead)
            {
                appliedValue = FrenchText.Count(rows.Count(r => r.Outcome == GpoOutcome.Applied), "GPO appliquée", "GPO appliquées") + " selon RSoP";
            }
            else
            {
                appliedValue = "Application non prouvée : ordre d’application (RSOP_GPLink) non lu";
                appliedState = AuditFactState.Unknown;
            }
        }
        facts.Add(AuditPolicyRules.Fact("Résultat appliqué sur le poste", appliedValue, appliedState, RsopSource, "Résultat du dernier traitement des stratégies enregistré par le poste, pas une simulation."));
        facts.Add(AuditPolicyRules.Fact("Liens de site", "Non lus", AuditFactState.Unknown, "Sites Active Directory", "Une GPO liée au site du poste s’applique aussi ; elle n’apparaît ici que dans le résultat RSoP."));
        if (links is not null && links.NamesState is not ReadState.Read and not ReadState.Empty)
        {
            facts.Add(AuditPolicyRules.Fact("Noms des GPO", "Non lus", AuditFactState.Unavailable, "CN=Policies,CN=System", links.NamesError));
        }

        var appliedProven = rsop is not null && rsopState == AuditFactState.Observed && linksRead;
        var parts = new List<string>();
        if (links is null)
        {
            parts.Add("Liens AD non lus : lisez les liens pour les comparer au résultat.");
        }
        parts.Add(FrenchText.Count(rows.Count, "ligne", "lignes") + ".");
        if (rsop is null)
        {
            parts.Add("Résultat sur le poste non lu : seuls les liens sont présentés.");
        }
        else if (rsop.State is not ReadState.Read)
        {
            parts.Add("Résultat sur le poste non obtenu : " + rsop.Message);
        }
        else if (appliedProven)
        {
            parts.Add("Résultat appliqué lu sur " + rsop.Computer + ".");
        }
        else
        {
            parts.Add("Résultat lu sur " + rsop.Computer + " mais application non prouvée : " + (rsop.LinksError ?? unproven));
        }
        return new AuditGpo(dn, chain, rows.ToImmutable(), facts.ToImmutable(), links is not null, appliedProven, rsopState, computer,
            string.Join(" ", parts), links?.ReadAt, rsop?.ReadAt);
    }

    private static string LinkedToLabel(string dn)
    {
        try
        {
            var parts = DistinguishedName.Parse(dn);
            return parts.Length > 0 && string.Equals(parts[0].Type, "DC", StringComparison.OrdinalIgnoreCase) ? "Domaine" : AuditText.NameOf(dn);
        }
        catch (FormatException)
        {
            return dn;
        }
    }

    private static Tone ToneOf(GpoOutcome outcome, string expected, bool enabled) => outcome switch
    {
        GpoOutcome.Applied => Tone.Ok,
        GpoOutcome.Filtered or GpoOutcome.Disabled => Tone.Warn,
        GpoOutcome.NotApplied when expected == "Oui" => Tone.Alert,
        GpoOutcome.NotApplied => Tone.Off,
        _ => enabled && expected == "Oui" ? Tone.Info : Tone.Off,
    };

    [GeneratedRegex(@"\[(?i:LDAP)://(?<dn>[^;\]]+);(?<opt>\d{1,2})\]", RegexOptions.CultureInvariant)]
    private static partial Regex GpLinkPattern();

    [GeneratedRegex(@"(?i)cn=\{(?<g>[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\}", RegexOptions.CultureInvariant)]
    private static partial Regex GpoGuidPattern();
}
