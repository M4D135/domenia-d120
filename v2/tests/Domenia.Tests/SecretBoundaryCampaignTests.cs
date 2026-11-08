using Domenia.Core;
using Domenia.Store;

namespace Domenia.Tests;

internal static class SecretBoundaryCampaignTests
{
    [Test]
    public static void One_marker_campaign_crosses_real_journal_trace_csv_capture_and_ticket_boundaries()
    {
        const string marker = "L03-NO-LEAK-123";
        const string payload = "password=" + marker;
        using var folder = new TemporaryFolder(); var path = folder.File("campaign.log");
        var technical = new RotatingTechnicalJournal(path, null, TestClock.Fixed());
        technical.Enqueue("INFO", payload); technical.Enqueue("TRACE", payload); technical.Flush();
        var journal = new OperationJournal(); journal.Add(new(TestClock.Reference, payload, Tone.Info));
        var properties = new Dictionary<string, IReadOnlyList<object?>>(StringComparer.OrdinalIgnoreCase)
        { ["displayName"] = [payload], ["unicodePwd"] = [marker], ["unexpectedSecretField"] = [marker] };
        var capture = SupportSnapshots.Create(properties, "DC=fixture,DC=local", "CN=User,DC=fixture,DC=local", "User", "user", SnapshotSource.Live, TestClock.Reference, TestClock.Reference);
        var outputs = new Dictionary<string, string>
        {
            ["journal and trace on disk"] = File.ReadAllText(path),
            ["journal shown in the application"] = journal.Snapshot().Single().Label,
            ["receipt"] = ReceiptReviews.Mask(payload),
            ["CSV"] = ShellCsv.Build(["Note", "unicodePwd"], [[payload, marker]]).Text,
            ["support capture"] = CaptureFiles.Export(capture),
            ["call sheet ticket"] = FicheCallSheets.Ticket("Note: {note}", new Dictionary<string, string> { ["note"] = payload }).Text,
            ["support copy"] = SupportSecretMask.Protect(payload),
        };
        foreach (var output in outputs)
        {
            Check.False(output.Value.Contains(marker, StringComparison.Ordinal), "marqueur absent du puits réel : " + output.Key);
            Check.True(output.Value.Length > 0, "le puits a produit un résultat contrôlé : " + output.Key);
        }
        Check.Equal("password=***", journal.Snapshot().Single().Label, "masquage appliqué à l’entrée du journal en mémoire");
        Check.Equal("Note: password=***", outputs["call sheet ticket"], "vraie substitution du champ avant protection du ticket");
    }

    [Test]
    public static void Cheap_secret_precheck_preserves_every_supported_grammar_and_bounds_large_text()
    {
        foreach (var text in new[] { "Bearer TOKEN", "Basic ABC=", "\"p\":\"MARKER\"", "password=MARKER", "-rp MARKER", "/P MARKER", "api_key=MARKER", "mot de passe=MARKER",
            "123456-123456-123456-123456-123456-123456-123456-123456" })
            Check.True(SecretTextHints.MayHoldSecret(text), "aucune grammaire de masquage ignorée");
        Check.False(SecretTextHints.MayHoldSecret("OU=Finance,DC=exemple,DC=local"), "texte ordinaire sans cinq regex");
        Check.Equal("[texte masqué]", SupportSecretMask.Protect(new string('x', SecretTextHints.MaximumTextLength + 1)), "entrée excessive retenue entière");
        Check.Equal("[texte masqué]", ReceiptReviews.Mask(new string('x', SecretTextHints.MaximumTextLength + 1)), "même borne dans les reçus");
    }

    [Test]
    public static void Positive_projection_excludes_unknown_and_secret_attributes_even_if_a_caller_requests_them()
    {
        var source = new Dictionary<string, IReadOnlyList<object?>>
        { ["displayName"] = ["User"], ["unicodePwd"] = ["private"], ["unreviewedField"] = ["untrusted"], ["memberOf;range=0-9"] = ["CN=Group"] };
        var fields = AllowedFieldProjection.Select(source, ["displayName", "unicodePwd", "memberOf"], allowRanges: true);
        Check.Equal(2, fields.Count, "seule la liste blanche non secrète est projetée");
        Check.False(fields.ContainsKey("unicodePwd") || fields.ContainsKey("unreviewedField"), "aucun champ inconnu ni secret même explicitement demandé");
        Check.True(fields.ContainsKey("memberOf;range=0-9"), "la provenance partielle de l’attribut est préservée");
        Check.Equal(4, source.Count, "source d’origine intacte");
        source["DISPLAYNAME"] = ["Other"];
        Check.Throws<InvalidDataException>(() => AllowedFieldProjection.Select(source, ["displayName"]), "attribut ambigu refusé avant export");
    }

    [Test]
    public static void Clipboard_expiry_and_close_never_erase_a_later_copy_even_when_its_text_is_identical()
    {
        using var ownership = new SecretClipboardOwnership("synthetic secret", 41);
        Check.True(ownership.Matches("synthetic secret", 41), "copie détenue reconnue");
        Check.False(ownership.Matches("synthetic secret", 42), "recopie identique de l’utilisateur préservée");
        Check.False(ownership.Matches("other contents", 41), "autre contenu préservé même avec séquence inattendue");
        ownership.Dispose();
        Check.False(ownership.Matches("synthetic secret", 41), "aucun ancien propriétaire après fermeture");
        using var unknown = new SecretClipboardOwnership("synthetic secret", 0);
        Check.False(unknown.Matches("synthetic secret", 0), "séquence inconnue n’autorise aucun effacement");
    }
}
