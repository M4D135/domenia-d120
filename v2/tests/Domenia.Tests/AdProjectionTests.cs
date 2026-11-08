using Domenia.Ad;
using Domenia.Core;

namespace Domenia.Tests;

internal static class AdProjectionTests
{
    [Test]
    public static void The_live_index_composes_named_projections_without_changing_requested_attributes()
    {
        static void Same(IReadOnlyList<string> actual, string expected)
        {
            var names = expected.Split(',');
            Check.Equal(names.Length, actual.Count, "aucun attribut ajouté ni retiré du contrat existant");
            Check.True(names.ToHashSet(StringComparer.OrdinalIgnoreCase).SetEquals(actual), "chaque attribut requis pour les écrans reste demandé");
        }
        Same(AdDirectoryMapper.OuAttributes, "name,ou,distinguishedName,objectGUID,objectClass,description,managedBy,whenCreated,whenChanged,uSNChanged");
        Same(AdDirectoryMapper.UserAttributes, "name,cn,sAMAccountName,userPrincipalName,displayName,givenName,sn,mail,description,department,title,physicalDeliveryOfficeName,telephoneNumber,manager,employeeID,distinguishedName,objectGUID,objectSid,objectClass,objectCategory,userAccountControl,msDS-User-Account-Control-Computed,lockoutTime,badPwdCount,pwdLastSet,msDS-UserPasswordExpiryTimeComputed,lastLogonTimestamp,accountExpires,whenCreated,whenChanged,uSNChanged,memberOf,primaryGroupID,adminCount");
        Same(AdDirectoryMapper.ComputerAttributes, "name,cn,dNSHostName,sAMAccountName,distinguishedName,objectGUID,objectSid,description,location,managedBy,operatingSystem,operatingSystemVersion,userAccountControl,lastLogonTimestamp,pwdLastSet,whenCreated,whenChanged,uSNChanged,msLAPS-PasswordExpirationTime,ms-Mcs-AdmPwdExpirationTime,memberOf,primaryGroupID");
        Same(AdDirectoryMapper.GroupAttributes, "name,cn,sAMAccountName,distinguishedName,objectGUID,objectSid,groupType,member,memberOf,adminCount,description,managedBy,mail,whenCreated,whenChanged,uSNChanged");
        Same(AdDirectoryMapper.ContactAttributes, "name,cn,objectGUID,distinguishedName,objectClass,objectCategory,displayName,givenName,sn,mail,description,title,department,physicalDeliveryOfficeName,telephoneNumber,manager,memberOf,whenCreated,whenChanged,uSNChanged");
    }

    [Test]
    public static void Named_projections_follow_the_purpose_and_are_never_empty()
    {
        foreach (var purpose in Enum.GetValues<AdProjectionPurpose>())
        {
            var attributes = AdProjection.Attributes(purpose);
            Check.True(attributes.Length > 0, "aucune projection vide, " + purpose + " : la lecture serait refusée");
            Check.Equal(attributes.Length, attributes.Distinct(StringComparer.OrdinalIgnoreCase).Count(), "aucun attribut demandé deux fois pour " + purpose);
        }
        Check.Throws<ArgumentOutOfRangeException>(() => AdProjection.Attributes((AdProjectionPurpose)999), "un but inconnu n’envoie pas une projection de présence par défaut");
        Check.Equal(19, AdProjection.List.Length, "la projection List est les dix-neuf attributs d’une liste");
        Check.True(AdProjection.List.Contains("uSNChanged", StringComparer.OrdinalIgnoreCase), "uSNChanged est demandé pour suivre les changements");
        Check.True(AdProjection.IsMinimal(AdProjection.Identity), "identité : rien de lourd");
        Check.True(AdProjection.IsMinimal(AdProjection.List), "liste : rien de lourd");
        Check.True(AdProjection.IsMinimal(AdProjection.Presence), "présence : rien de lourd");
        Check.False(AdProjection.IsMinimal(AdProjection.Groups), "l’appartenance est le but des groupes : member et memberOf y sont demandés");
        Check.False(AdProjection.IsMinimal(AdProjection.Security), "le descripteur et tokenGroups sont le but de la sécurité");
        Check.Equal("member,memberOf", string.Join(',', AdProjection.Heavy(AdProjection.Groups)), "les deux listes lourdes sont nommées");
        Check.Equal("nTSecurityDescriptor,tokenGroups", string.Join(',', AdProjection.Heavy(AdProjection.Security)), "le descripteur et les jetons sont nommés");
    }

    [Test]
    public static void A_list_asking_heavy_attributes_is_reported_not_minimal_without_inventing_anything()
    {
        Check.True(AdProjection.IsMinimal(["name", "objectGUID", "uSNChanged"]), "une liste courte est minimale");
        Check.True(AdProjection.IsMinimal(["memberOfX", "msDS-User-Account-Control-Computed"]), "un nom qui ressemble à un attribut lourd n’en est pas un");
        Check.False(AdProjection.IsMinimal([]), "une projection vide n’est jamais dite minimale : elle serait refusée");
        Check.Contains("vide", AdProjection.NonMinimalReason([])!, "la raison nomme la projection vide");
        Check.Null(AdProjection.NonMinimalReason(["name", "whenChanged"]), "une projection minimale n’a rien à signaler");
        foreach (var heavy in AdProjection.HeavyAttributes)
        {
            Check.False(AdProjection.IsMinimal(["name", heavy]), heavy + " n’est jamais minimal dans une liste");
            Check.Contains(heavy, AdProjection.NonMinimalReason(["name", heavy])!, "la raison nomme l’attribut lourd");
        }
        Check.False(AdProjection.IsMinimal(["name", "MEMBER;range=0-1499"]), "la forme à plage compte pour son attribut");
        Check.Equal("member", string.Join(',', AdProjection.Heavy(["member", "MEMBER", "MEMBER;range=0-1499"])), "un attribut lourd n’est nommé qu’une fois");
        Check.True(AdProjection.NonMinimalReason(["name", "memberOf", "tokenGroups"])!.Contains("memberOf", StringComparison.Ordinal)
            && AdProjection.NonMinimalReason(["name", "memberOf", "tokenGroups"])!.Contains("tokenGroups", StringComparison.Ordinal), "tous les attributs lourds sont cités");
    }

    [Test]
    public static async Task The_census_says_when_a_list_projection_is_not_minimal()
    {
        var traces = new List<string>();
        void Record(string text) => traces.Add(text);
        AdConnection.TechnicalTrace += Record;
        try
        {
            using var ldap = new AdBoundaryTests.RecordingAdConnection { SearchAnswer = _ => [] };
            var snapshot = await AdDirectoryReader.ReadSnapshotAsync(ldap, Fixtures.Domain, new ScopeSelection(Fixtures.Postes, "Postes", true), 10, TestClock.Fixed(), CancellationToken.None);
            Check.True(snapshot.Complete, "lire n’est pas refuser : les objets sont demandés quand même");
            Check.True(traces.Any(t => t.Contains("projection non minimale", StringComparison.Ordinal) && t.Contains("memberOf", StringComparison.Ordinal)),
                "la liste qui demande memberOf est signalée non minimale");
            Check.True(traces.Any(t => t.Contains("projection non minimale", StringComparison.Ordinal) && t.Contains("objectCategory=group", StringComparison.Ordinal)),
                "la liste des groupes est signalée pour ses deux listes lourdes");
            Check.False(traces.Any(t => t.Contains("projection non minimale", StringComparison.Ordinal) && t.Contains("organizationalUnit", StringComparison.Ordinal)),
                "la projection des OU, minimale, n’est pas signalée");
        }
        finally { AdConnection.TechnicalTrace -= Record; }
    }
}
