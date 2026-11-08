using Domenia.Ad;
using Domenia.Core;
using Domenia.Core.Poste;

namespace Domenia.Tests;

internal static partial class AdFicheWriteTests
{
    [Test]
    public static async Task Editing_another_field_keeps_a_long_multiline_description_exact_in_the_directory_and_the_local_projection()
    {
        using var ldap = new Connection(); using var source = Source(ldap);
        ldap.Objects[Dn]["objectClass"] = ["top", "computer"]; ldap.Objects[Dn]["userAccountControl"] = ["4096"]; ldap.Objects[Dn]["sAMAccountName"] = ["PC-ORIG$"];
        ldap.Objects[Dn]["description"] = [DirectoryValueTests.LongText];
        ldap.Objects[Dn]["location"] = ["Ancien bureau"];
        using var writers = WriteExecutors.Discover(source, [typeof(AdDirectorySource).Assembly]);
        var writer = writers.Require<IPosteProfileExecutor>();
        var plan = Seal(await writer.PlanAsync(Dn, null, "Nouveau bureau", null, CancellationToken.None));
        Check.False(plan.Changes.Any(c => c.Attribute == "description"), "la description n’est pas dans le plan : elle n’est pas réécrite");
        await writer.ExecuteAsync(plan, CancellationToken.None);
        Check.Equal(VerificationState.Verified, (await writer.VerifyAsync(plan, CancellationToken.None)).State, "postcondition réelle");
        Check.False(ldap.Changes.Any(c => string.Equals(c.Attribute, "description", StringComparison.OrdinalIgnoreCase)), "aucune modification envoyée sur la description");
        Check.Equal(DirectoryValueTests.LongText, (string)ldap.Objects[Dn]["description"].Single(), "l’annuaire garde la description exacte");
        var local = source.CurrentDirectory!.Computers.Single();
        Check.Equal(DirectoryValueTests.LongText, local.Description, "la projection locale relue garde la description exacte, deux lignes et blancs compris");
        Check.Equal("Nouveau bureau", local.Location, "le champ modifié est bien relu");
    }
}
