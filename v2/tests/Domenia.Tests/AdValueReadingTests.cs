using Domenia.Ad;
using Domenia.Core;

namespace Domenia.Tests;

/// <summary>GUID and FILETIME values read from the directory: read when readable, otherwise unread, never invented.</summary>
internal static class AdValueReadingTests
{
    [Test]
    public static void Guid_and_filetime_values_are_read_or_stay_unread_never_invented()
    {
        var id = Guid.Parse("7c9e4b4e-2d87-4c4e-9b4e-3e6a0d7a1b23");
        Check.Equal(id, AdValues.GuidFromText(id.ToString("D")), "le format « D » est lu");
        Check.Equal(id, AdValues.GuidFromText("{" + id.ToString("D").ToUpperInvariant() + "}"), "le format entre accolades est lu");
        Check.Equal(id, AdValues.GuidFromText(id.ToString("N")), "trente-deux chiffres hexadécimaux sans séparateur sont lus");
        Check.Equal(id.ToString("D"), AdValues.GuidText(id), "un GUID s’écrit dans le format « D »");
        Check.Null(AdValues.GuidFromText("pas un identifiant"), "un texte illisible reste non lu");
        Check.Null(AdValues.GuidFromText("00000000-0000-0000-0000-00000000000x"), "un hexadécimal invalide n’est pas un GUID");
        Check.Null(AdValues.GuidFromText("   "), "rien d’écrit n’est un identifiant");
        Check.Equal(Guid.Empty, AdValues.GuidFromText("00000000-0000-0000-0000-000000000000")!.Value, "le GUID nul écrit est bien le GUID nul");
        Check.Equal(id, Entry(["objectGUID"], [id.ToByteArray()]).Guid("objectGUID"), "l’identité lue en octets est convertie");
        Check.Equal(id, Entry(["objectGUID"], [id.ToString("D")]).Guid("objectGUID"), "la même identité déjà écrite en texte est convertie");
        Check.Null(Entry(["objectGUID"], ["pas un identifiant"]).Guid("objectGUID"), "identité illisible : lue comme absente, jamais comme un GUID nul");
        Check.Null(new AdEntry("CN=PC-01," + Fixtures.Postes, new Dictionary<string, IReadOnlyList<object>>()).Guid("objectGUID"), "identité absente : nulle, jamais inventée");
        Check.Null(Entry(["objectGUID"], [new byte[] { 1, 2, 3 }]).Guid("objectGUID"), "des octets de mauvaise longueur ne forment pas un GUID");
        Check.Null(AdValues.FromFileTime(0), "zéro vaut « jamais »");
        Check.Null(AdValues.FromFileTime(-1), "une valeur négative ne devient pas une date");
        Check.Null(AdValues.FromFileTime(AdValues.Never), "la plus grande valeur vaut « jamais »");
        Check.Null(AdValues.FromFileTime(null), "une valeur non lue n’est jamais une date, jamais zéro");
        Check.NotNull(AdValues.FromFileTime(AdValues.ToFileTime(Fixtures.Now)), "une date lisible est rendue");
    }

    private static AdEntry Entry(string[] names, params object[] values)
    {
        var attributes = new Dictionary<string, IReadOnlyList<object>>();
        for (var i = 0; i < names.Length; i++)
        {
            attributes[names[i]] = [values[i]];
        }
        return new AdEntry("CN=PC-01," + Fixtures.Postes, attributes);
    }
}
