using System.Collections.Immutable;

namespace Domenia.Core;

/// <summary>
/// Target of the object reads (AUD-010): which read applies to which kind of object, with the reason shown when it does
/// not (Get-DomeniaAdAuditAvailability), and the readable form of the target. Pure.
/// </summary>
public static class AuditTargets
{
    public const string NoTargetReason = "Choisissez d’abord un objet : cette lecture porte sur l’objet sélectionné.";

    public static string KindLabel(AuditObjectKind kind) => kind switch
    {
        AuditObjectKind.User => "Utilisateur",
        AuditObjectKind.Computer => "Ordinateur",
        AuditObjectKind.Group => "Groupe",
        AuditObjectKind.OrganizationalUnit => "Unité d’organisation",
        AuditObjectKind.Domain => "Domaine",
        _ => "Objet",
    };

    /// <summary>Availability of every object read for a kind; null kind: no target, every read says why.</summary>
    public static AuditReadsAvailability Availability(AuditObjectKind? kind)
    {
        if (kind is not AuditObjectKind k)
        {
            var none = new AuditAvailability(false, NoTargetReason);
            return new AuditReadsAvailability(none, none, none, none, none, none, none, none);
        }
        return new AuditReadsAvailability(
            Allow(k is AuditObjectKind.User, "La stratégie de mot de passe se lit pour un compte utilisateur."),
            Allow(k is AuditObjectKind.User or AuditObjectKind.Computer or AuditObjectKind.Group, "Les appartenances se lisent pour un utilisateur, un ordinateur ou un groupe."),
            Allow(true, null),
            Allow(k is AuditObjectKind.User or AuditObjectKind.Computer or AuditObjectKind.OrganizationalUnit or AuditObjectKind.Domain, "Les liens GPO se lisent pour un utilisateur, un ordinateur, une unité d’organisation ou le domaine."),
            Allow(k is AuditObjectKind.Computer, "Le résultat appliqué se lit sur un ordinateur."),
            Allow(k is AuditObjectKind.Computer, "L’identité AD, DNS et poste se vérifie pour un ordinateur."),
            Allow(k is AuditObjectKind.User or AuditObjectKind.Computer, "Les associations concernent un utilisateur ou un ordinateur."),
            Allow(true, null));
    }

    private static AuditAvailability Allow(bool allowed, string? reason) => new(allowed, allowed ? null : reason);

    /// <summary>The read is admitted for this target; otherwise audit.notApplicable with the reason.</summary>
    public static void Require(AuditAvailability availability)
    {
        ArgumentNullException.ThrowIfNull(availability);
        if (!availability.Allowed)
        {
            throw new DomeniaOperationException(AuditErrors.NotApplicable, availability.Reason ?? NoTargetReason);
        }
    }

    public static AuditTargetView View(AuditTarget target, string dnsName)
    {
        ArgumentNullException.ThrowIfNull(target);
        return new AuditTargetView(
            target.Dn,
            target.Kind,
            KindLabel(target.Kind),
            target.Name,
            target.SamAccountName,
            target.ObjectGuid?.ToString("D"),
            target.Sid,
            target.DnsHostName,
            Path(target.Dn, dnsName),
            target.Description,
            Availability(target.Kind));
    }

    /// <summary>Readable path from the domain to the object: « example.local › Utilisateurs › Paris › Julien Martin ».</summary>
    public static string Path(string dn, string dnsName)
    {
        ArgumentNullException.ThrowIfNull(dn);
        try
        {
            var names = DistinguishedName.Parse(dn).Where(n => !string.Equals(n.Type, "DC", StringComparison.OrdinalIgnoreCase)).Select(n => n.Value).Reverse();
            return string.Join(FrenchText.PathSeparator, new[] { dnsName }.Concat(names));
        }
        catch (FormatException)
        {
            return dn;
        }
    }

    /// <summary>Containers whose gPLink applies to the object, closest first, then the domain root (Get-DomeniaGpoContainerChain).</summary>
    public static ImmutableArray<string> GpoContainerChain(string dn, string domainDn, AuditObjectKind kind)
    {
        ArgumentNullException.ThrowIfNull(dn);
        ArgumentNullException.ThrowIfNull(domainDn);
        ImmutableArray<RelativeName> parts;
        ImmutableArray<RelativeName> domain;
        try
        {
            parts = DistinguishedName.Parse(dn);
            domain = DistinguishedName.Parse(domainDn);
        }
        catch (FormatException)
        {
            return [];
        }
        if (parts.Length == 0 || domain.Length == 0)
        {
            return [];
        }
        if (DistinguishedName.AreEqual(dn, domainDn))
        {
            return [domainDn];
        }
        var chain = ImmutableArray.CreateBuilder<string>();
        var start = kind is AuditObjectKind.OrganizationalUnit or AuditObjectKind.Domain ? 0 : 1;
        for (var i = start; i < parts.Length; i++)
        {
            var candidate = DistinguishedName.Format(parts.Skip(i));
            if (DistinguishedName.AreEqual(candidate, domainDn))
            {
                chain.Add(domainDn);
                return chain.ToImmutable();
            }
            if (string.Equals(parts[i].Type, "OU", StringComparison.OrdinalIgnoreCase))
            {
                chain.Add(candidate);
            }
            if (chain.Count >= 40)
            {
                break;
            }
        }
        // The root of the domain was never reached: the object is outside the connected domain.
        return [];
    }
}

/// <summary>Error codes of the audit operations (docs/ops/audit.md).</summary>
public static class AuditErrors
{
    public const string TargetUnknown = "audit.targetUnknown";
    public const string TargetUnknownMessage = "Objet introuvable dans l’annuaire de la session : rien n’a été lu.";

    public const string NotApplicable = "audit.notApplicable";

    public const string OverviewNotRead = "audit.overviewNotRead";
    public const string OverviewNotReadMessage = "Analysez d’abord le domaine : l’exploration montre seulement les objets lus par l’analyse, sans relecture.";

    public const string FindingUnknown = "audit.findingUnknown";
    public const string FindingUnknownMessage = "Constat inconnu : rien n’a été lu.";

    public const string AclNotRead = "audit.aclNotRead";
    public const string AclNotReadMessage = "Lisez d’abord les délégations de cet objet : l’estimation porte sur les entrées lues.";

    public const string GroupsNotRead = "audit.groupsNotRead";
    public const string GroupsNotReadMessage = "Lisez d’abord les appartenances de cet objet, puis choisissez un groupe.";

    public const string TrusteeUnknown = "audit.trusteeUnknown";
    public const string TrusteeUnknownMessage = "Ce bénéficiaire ne figure dans aucune entrée lue : rien n’est estimé.";

    public const string BuiltinTrustee = "audit.builtinTrustee";
    public const string BuiltinTrusteeMessage = "Les groupes se lisent pour un compte ou un groupe d’un domaine, pas pour une identité intégrée.";

    public const string ControllersInvalid = "audit.controllersInvalid";

    public const string ScopeTooWide = "audit.scopeTooWide";
    public const string ScopeTooWideMessage = "Le domaine entier n’est pas analysé : choisissez une OU, ou décochez « Inclure les sous-OU ».";

    public const string OutsideDomain = "audit.outsideDomain";
    public const string OutsideDomainMessage = "Objet hors du domaine connecté : aucun lien à lire.";
}
