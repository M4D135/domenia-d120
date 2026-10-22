using System.Text;
using System.Text.Json;
using Domenia.Bridge;
using Domenia.Core;

namespace Domenia.Tests;

/// <summary>Pure rules of the shell (docs/SHELL.md, docs/ops/shell.md): texts, CSV, secrets, automation, preferences.</summary>
internal static class ShellTests
{
    private const string Nbsp = FrenchText.Nbsp;
    private const string Root = "DC=example,DC=local";

    private static JsonElement Json(string text) => JsonDocument.Parse(text).RootElement.Clone();

    // ---------- Texts of the top bar and the window (TRV-049, TRV-050, TRV-053) ----------

    [Test]
    public static void Counter_is_empty_at_zero_and_stops_at_99_plus()
    {
        Check.Equal("", ShellTexts.Counter(0), "zéro");
        Check.Equal("", ShellTexts.Counter(-4), "négatif");
        Check.Equal("1", ShellTexts.Counter(1), "un");
        Check.Equal("99", ShellTexts.Counter(99), "99");
        Check.Equal("99+", ShellTexts.Counter(100), "100");
        Check.Equal("99+", ShellTexts.Counter(12_000), "beaucoup");
    }

    [Test]
    public static void Window_title_names_the_screen_and_marks_directory_writes_only()
    {
        Check.Equal("Domenia", ShellTexts.WindowTitle(null, "Domenia", false, AppMode.Simulation), "sans écran");
        Check.Equal("Fiche · Camille Martin — Domenia", ShellTexts.WindowTitle("Fiche · Camille Martin", "Domenia", false, AppMode.Directory), "écran et cible");
        Check.Equal("Accueil — Domenia  " + ShellTexts.WriteActiveMark, ShellTexts.WindowTitle("Accueil", "Domenia", true, AppMode.Directory), "écriture admise en mode annuaire");
        Check.Equal("Accueil — Domenia", ShellTexts.WindowTitle("Accueil", "Domenia", true, AppMode.Simulation), "jamais la marque en simulation");
        Check.Equal("Fiche · a b — Domenia", ShellTexts.WindowTitle("Fiche ·\r\n a\t\u0007b", "Domenia", false, AppMode.Directory), "caractères de contrôle aplatis");
    }

    [Test]
    public static void Flat_line_collapses_spaces_and_cuts_with_an_ellipsis()
    {
        Check.Equal("", ShellTexts.FlatLine("   ", 10), "blanc");
        Check.Equal("a b c", ShellTexts.FlatLine("  a \n b\t\tc ", 10), "espaces réduits");
        var cut = ShellTexts.FlatLine(new string('x', 200), 160);
        Check.Equal(160, cut.Length, "longueur bornée");
        Check.True(cut.EndsWith('…'), "points de suspension");
    }

    [Test]
    public static void Activity_detail_tells_reads_and_receipts_in_one_sentence()
    {
        Check.Equal("Aucune opération en cours" + Nbsp + "; aucun reçu à vérifier.", ShellTexts.ActivityDetail(new TaskCounters(0, 0), new ShellReceiptCounts(true, 3, 0, 0)), "rien");
        Check.Equal("2 lectures en cours, 1 lecture en attente" + Nbsp + "; 1 reçu à vérifier.", ShellTexts.ActivityDetail(new TaskCounters(2, 1), new ShellReceiptCounts(true, 5, 1, 0)), "travail et reçu");
        Check.Contains("illisibles pour l’instant", ShellTexts.ActivityDetail(new TaskCounters(0, 0), new ShellReceiptCounts(false, 0, 0, 0)), "reçus illisibles");
    }

    [Test]
    public static void Guide_chapters_follow_the_screens_and_fall_back_to_landmarks()
    {
        var home = GuideChapters.For("accueil");
        Check.Equal("technicien", home.Guide, "guide de l’Accueil");
        Check.Equal(5, home.Chapter, "chapitre de l’Accueil");
        Check.Equal("Domenia-2-Guide-technicien.pdf", home.Files[0], "guide de Domenia 2 d’abord");
        Check.Equal("Domenia-1.0-Guide-technicien.pdf", home.Files[1], "puis celui de Domenia 1");
        Check.Contains("chapitre 5" + Nbsp + ": Voir et explorer", home.Text, "texte du chapitre");
        Check.Equal(20, GuideChapters.For("operations").Chapter, "Opérations");
        var unknown = GuideChapters.For("inconnu");
        Check.Equal(9, unknown.Chapter, "Repères");
        Check.Equal("Repères", unknown.Title, "titre de repli");
        Check.True(GuideChapters.IsPageName("fiche-droits"), "nom d’écran");
        Check.False(GuideChapters.IsPageName("Fiche"), "majuscule refusée");
        Check.False(GuideChapters.IsPageName("../x"), "chemin refusé");
        Check.False(GuideChapters.IsPageName(new string('a', 31)), "trop long");
    }

    // ---------- CSV (TRV-054, TRV-055) ----------

    [Test]
    public static void Formula_like_cells_get_a_leading_apostrophe()
    {
        Check.Equal("'=1+1", ShellCsv.Neutralize("=1+1"), "égal");
        Check.Equal("'+33 6", ShellCsv.Neutralize("+33 6"), "plus");
        Check.Equal("'-2+3", ShellCsv.Neutralize("-2+3"), "moins suivi d’une formule");
        Check.Equal("'-cmd|' /C calc'!A0", ShellCsv.Neutralize("-cmd|' /C calc'!A0"), "moins d’une injection");
        Check.Equal("'@SOMME(A1)", ShellCsv.Neutralize("@SOMME(A1)"), "arobase");
        Check.Equal("'＝HYPERLINK()", ShellCsv.Neutralize("＝HYPERLINK()"), "pleine chasse");
        Check.Equal("'  =x", ShellCsv.Neutralize("  =x"), "après des blancs");
        Check.Equal("'\tx", ShellCsv.Neutralize("\tx"), "tabulation en tête");
        Check.Equal("Camille", ShellCsv.Neutralize("Camille"), "texte ordinaire");
        Check.Equal("", ShellCsv.Neutralize(null), "null");
    }

    [Test]
    public static void Numbers_keep_their_sign_without_an_apostrophe()
    {
        Check.Equal("-5", ShellCsv.Neutralize("-5"), "entier négatif");
        Check.Equal("−12,5", ShellCsv.Neutralize("−12,5"), "signe moins typographique et virgule");
        Check.Equal("-1\u202F234,50", ShellCsv.Neutralize("-1\u202F234,50"), "milliers à espace fine");
        Check.Equal("-3.25", ShellCsv.Neutralize("-3.25"), "point décimal");
        Check.True(ShellCsv.IsNumber("1 234"), "milliers à espace");
        Check.False(ShellCsv.IsNumber("1 23"), "groupe de deux chiffres : pas un nombre");
        Check.False(ShellCsv.IsNumber("-5 "), "blanc final : pas un nombre");
        Check.Equal("'-5 ", ShellCsv.Neutralize("-5 "), "blanc final : neutralisé");
        Check.False(ShellCsv.IsNumber("+5"), "plus : jamais un nombre pour la neutralisation");
        Check.Equal("-5", ShellHostArguments.Cell(System.Text.Json.JsonDocument.Parse("-5").RootElement), "nombre de la page : texte « -5 »");
        var csv = ShellCsv.Build(["Écart"], [["-5"]]);
        Check.Contains("\r\n-5\r\n", csv.Text, "nombre négatif écrit tel quel");
    }

    [Test]
    public static void Rebuild_writes_a_page_csv_with_the_engine_rules()
    {
        var text = "\uFEFFNom;Note;Code\n\"Martin, C\";\" =1+1\";\"＝HYPERLINK()\"\nDurand;\"ligne 1\nligne 2\";password=Secret42\n";
        var doc = ShellCsv.Rebuild(text)!;
        Check.NotNull(doc, "relu");
        Check.Equal(2, doc.Rows, "lignes comptées par enregistrement (une cellule sur deux lignes)");
        Check.Contains("' =1+1", doc.Text, "formule après un blanc neutralisée");
        Check.Contains("'＝HYPERLINK()", doc.Text, "forme pleine chasse neutralisée");
        Check.False(doc.Text.Contains("Secret42", StringComparison.Ordinal), "secret masqué cellule par cellule");
        Check.Equal(1, doc.Masked, "une valeur masquée");
        Check.True(doc.Text.StartsWith("Nom;Note;Code\r\n", StringComparison.Ordinal), "en-tête, CRLF, BOM retiré");
        Check.Contains("\"ligne 1\nligne 2\"", doc.Text, "saut de ligne cité");
        var wide = string.Join(";", Enumerable.Range(0, ShellCsv.MaxExportColumns + 1).Select(i => "c" + i.ToString(System.Globalization.CultureInfo.InvariantCulture)));
        Check.Null(ShellCsv.Rebuild(wide + "\n"), "trop de colonnes : refusé, jamais tronqué en silence");
        Check.Equal(0, ShellCsv.Rebuild("")!.Rows, "texte vide : document vide");
        var bounded = ShellCsv.Parse("a;b\n1;2\n3;4\n", 1, 10);
        Check.Equal(1, bounded.Rows.Length, "bornes explicites : lignes");
        Check.True(bounded.Truncated, "bornes explicites : troncature signalée");
    }

    [Test]
    public static void Cells_are_quoted_only_when_needed()
    {
        Check.Equal("abc", ShellCsv.Quote("abc"), "rien à citer");
        Check.Equal("\"a;b\"", ShellCsv.Quote("a;b"), "séparateur");
        Check.Equal("\"dit \"\"bonjour\"\"\"", ShellCsv.Quote("dit \"bonjour\""), "guillemets doublés");
        Check.Equal("\"l1\nl2\"", ShellCsv.Quote("l1\nl2"), "saut de ligne");
    }

    [Test]
    public static void Build_withholds_secret_columns_and_masks_secret_looking_text()
    {
        var csv = ShellCsv.Build(
            ["Nom", "unicodePwd", "Note", "Code"],
            [["Camille Martin", "Hunter2", "password=Secret42", "=1+1"], ["Paul Durand", "", "RAS", null]],
            new HashSet<int> { 3 });
        Check.Equal(2, csv.Rows, "lignes");
        Check.True(csv.Withheld.SequenceEqual(["unicodePwd", "Code"]), "colonnes retenues : " + string.Join(",", csv.Withheld));
        Check.Equal(3, csv.Masked, "valeurs masquées (deux secrets retenus, un texte masqué)");
        Check.False(csv.Text.Contains("Hunter2", StringComparison.Ordinal), "colonne secrète jamais écrite");
        Check.False(csv.Text.Contains("Secret42", StringComparison.Ordinal), "texte secret jamais écrit");
        Check.Contains("password=***", csv.Text, "forme masquée");
        Check.Contains(ShellSecrets.WithheldValue, csv.Text, "valeur retenue annoncée");
        var lines = csv.Text.Split("\r\n");
        Check.Equal("Nom;unicodePwd;Note;Code", lines[0], "en-tête");
        Check.Equal(4, lines.Length, "CRLF après chaque ligne");
        Check.Equal("", lines[^1], "fin de fichier");
    }

    [Test]
    public static void Export_file_names_keep_safe_characters_and_the_minute()
    {
        var at = new DateTime(2026, 10, 22, 9, 5, 0, DateTimeKind.Local);
        Check.Equal("Domenia-OU-Postes-Lyon-20261022-0905.csv", ShellCsv.FileName("OU Postes / Lyon", at), "sujet nettoyé");
        Check.Equal("Domenia-Sécurité-20261022-0905.json", ShellCsv.FileName("Sécurité", at, "json"), "accents gardés");
        Check.Equal("Domenia-export-20261022-0905.csv", ShellCsv.FileName(" /// ", at), "sujet vide");
        Check.True(ShellCsv.FileName(new string('a', 300), at).Length <= "Domenia-".Length + 60 + "-20261022-0905.csv".Length, "sujet borné");
    }

    [Test]
    public static void Delimiter_is_detected_from_the_first_line()
    {
        Check.Equal(';', ShellCsv.DetectDelimiter("Nom;Poste;OU"), "point-virgule");
        Check.Equal(',', ShellCsv.DetectDelimiter("Name,Computer"), "virgule");
        Check.Equal(';', ShellCsv.DetectDelimiter("Nom;Prénom, initiale;OU"), "plus de points-virgules");
        Check.Equal(',', ShellCsv.DetectDelimiter(""), "ligne vide");
    }

    [Test]
    public static void Parse_reads_quoted_cells_and_reports_left_out_rows()
    {
        var table = ShellCsv.Parse("Nom;Poste\r\n\"Martin; C\";PC-01\r\n\r\nDupont;\"PC \"\"2\"\"\"\r\n");
        Check.Equal(';', table.Delimiter, "séparateur");
        Check.True(table.Headers.SequenceEqual(["Nom", "Poste"]), "en-têtes");
        Check.Equal(2, table.Rows.Length, "lignes (ligne vide ignorée)");
        Check.Equal("Martin; C", table.Rows[0][0], "séparateur cité");
        Check.Equal("PC \"2\"", table.Rows[1][1], "guillemets doublés");
        Check.False(table.Truncated, "complet");

        var big = new StringBuilder("A,B\n");
        for (var i = 0; i < ShellCsv.MaxReadRows + 2; i++)
        {
            big.Append("x,").Append(i.ToString(System.Globalization.CultureInfo.InvariantCulture)).Append('\n');
        }
        var bounded = ShellCsv.Parse(big.ToString());
        Check.Equal(ShellCsv.MaxReadRows, bounded.Rows.Length, "lignes bornées");
        Check.Equal(ShellCsv.MaxReadRows + 2, bounded.Total, "total annoncé");
        Check.True(bounded.Truncated, "troncature signalée");
    }

    // ---------- Secrets (TRV-061, TRV-203) ----------

    [Test]
    public static void Protect_masks_every_known_form_of_secret()
    {
        Check.Equal("password=***", ShellSecrets.Protect("password=Secret123"), "clé=valeur");
        Check.Equal("mot de passe : ***", ShellSecrets.Protect("mot de passe : abc"), "forme française");
        Check.Equal("En-tête Bearer ***", ShellSecrets.Protect("En-tête Bearer abc.def-ghi"), "jeton porteur");
        Check.Equal("{\"pwd\":\"***\"}", ShellSecrets.Protect("{\"pwd\":\"x y\"}"), "membre JSON");
        Check.Equal("clé [clé de récupération masquée]", ShellSecrets.Protect("clé 123456-123456-123456-123456-123456-123456-123456-123456"), "clé BitLocker");
        Check.Equal("net use -Password ***", ShellSecrets.Protect("net use -Password Hunter2"), "option de ligne de commande");
        Check.Equal("Poste PC-01 en ligne", ShellSecrets.Protect("Poste PC-01 en ligne"), "texte ordinaire intact");
        Check.Equal("", ShellSecrets.Protect(null), "null");
        Check.False(ShellSecrets.MayHoldSecret("Poste PC-01 en ligne"), "pré-test négatif");
        Check.True(ShellSecrets.MayHoldSecret("token: x"), "pré-test positif");
    }

    [Test]
    public static void Secret_attributes_and_sensitive_options_are_recognised()
    {
        Check.True(ShellSecrets.IsSecretAttribute("unicodePwd "), "unicodePwd");
        Check.True(ShellSecrets.IsSecretAttribute("ms-Mcs-AdmPwd"), "LAPS hérité");
        Check.True(ShellSecrets.IsSecretAttribute("msLAPS-Password"), "LAPS Windows");
        Check.True(ShellSecrets.IsSecretAttribute("msFVE-RecoveryPassword"), "BitLocker");
        Check.False(ShellSecrets.IsSecretAttribute("cn"), "cn");
        Check.False(ShellSecrets.IsSecretAttribute("pwdLastSet"), "date du mot de passe : pas un secret");
        Check.True(ShellSecrets.IsSensitiveOption("NewPassword", null, false, false), "nom en casse chameau");
        Check.True(ShellSecrets.IsSensitiveOption("x", "Clé de récupération", false, false), "libellé français");
        Check.True(ShellSecrets.IsSensitiveOption("x", "y", true, false), "marquée par l’appelant");
        Check.False(ShellSecrets.IsSensitiveOption("MustChangePassword", "Changer le mot de passe", false, true), "oui/non visible");
        Check.False(ShellSecrets.IsSensitiveOption("Description", "Description", false, false), "option ordinaire");
    }

    // ---------- Interface automatisable (TRV-067 to TRV-069) ----------

    [Test]
    public static void Automation_contract_is_versioned_and_bounded()
    {
        var c = ShellAutomation.Contract;
        Check.Equal(ShellAutomation.ContractName, c.Contract, "nom du contrat");
        Check.True(c.Commands.Select(x => x.Name).SequenceEqual(["version", "etat", "postes", "observations", "associations", "requetes", "dossier"]), "commandes");
        Check.True(c.ExitCodes.Select(x => x.Code).SequenceEqual([0, 2, 3, 4, 5]), "codes de sortie");
        Check.Equal(5000, c.Limits.MaxRows, "lignes au plus");
        Check.Equal(500, c.Limits.MaxNames, "noms au plus");
        Check.True(c.Commands.Where(x => x.Name is "postes" or "observations" or "associations" or "dossier").All(x => x.Perimeter), "périmètre exigé");
    }

    [Test]
    public static void Automation_requests_are_validated_like_the_command_line()
    {
        var (version, _, code) = ShellAutomation.Validate("Version", null, null, null, 0, null);
        Check.Equal(0, code, "version acceptée");
        Check.Equal("version", version!.Command, "commande normalisée");
        Check.Equal("Json", version.Format, "format par défaut");
        Check.Equal(1000, version.Limit, "limite par défaut");

        var (_, missing, missingCode) = ShellAutomation.Validate("postes", null, null, null, 0, null);
        Check.Equal(4, missingCode, "périmètre exigé");
        Check.Contains("Aucune commande ne parcourt tout le domaine", missing, "motif");

        var (byOu, _, _) = ShellAutomation.Validate("postes", " OU=Postes , DC=example,DC=local ", null, null, 0, "csv");
        Check.Equal("OU", byOu!.Perimeter.Kind, "périmètre OU");
        Check.Equal("OU=Postes,DC=example,DC=local", byOu.Perimeter.OrganizationalUnit, "OU normalisée");
        Check.Equal("Csv", byOu.Format, "format CSV");

        var (byNames, _, _) = ShellAutomation.Validate("postes", null, ["PC-01.example.local", "pc-01$", "PC-02"], null, 0, null);
        Check.True(byNames!.Perimeter.Computers.SequenceEqual(["pc-01", "pc-02"]), "noms courts, uniques, en minuscules");

        Check.Equal(2, ShellAutomation.Validate("postes", Root, ["PC-01"], null, 0, null).ExitCode, "un seul périmètre");
        Check.Equal(2, ShellAutomation.Validate("postes", null, null, ["{zzz}"], 0, null).ExitCode, "GUID invalide");
        Check.Equal(2, ShellAutomation.Validate("postes", null, ["pc 01"], null, 0, null).ExitCode, "nom invalide");
        Check.Equal(2, ShellAutomation.Validate("postes", Root, null, null, 5001, null).ExitCode, "limite dépassée");
        Check.Equal(2, ShellAutomation.Validate("version", null, null, null, 0, "Csv").ExitCode, "format non pris en charge");
        Check.Equal(2, ShellAutomation.Validate("supprimer", null, null, null, 0, null).ExitCode, "commande inconnue");
        Check.Equal(2, ShellAutomation.Validate("postes", "CN=PC-01,OU=Postes,DC=example,DC=local", null, null, 0, null).ExitCode, "un objet n’est pas un périmètre");
        var many = Enumerable.Range(0, 501).Select(i => "pc" + i.ToString(System.Globalization.CultureInfo.InvariantCulture)).ToList<string?>();
        Check.Equal(2, ShellAutomation.Validate("postes", null, many, null, 0, null).ExitCode, "500 noms au plus");
    }

    [Test]
    public static void Automation_csv_is_neutralized_and_quoted()
    {
        var csv = ShellAutomation.ComputerCsv([new AutomationComputerRow("=PC", null, "00000000-0000-0000-0000-000000000001", "CN=PC,DC=x", true, "Windows 11", null)]);
        var lines = csv.Split("\r\n");
        Check.Equal("\"Guid\";\"Nom\";\"DNS\";\"DN\";\"Etat\";\"Systeme\";\"DerniereConnexion\"", lines[0], "en-tête");
        Check.Contains("\"'=PC\"", lines[1], "formule neutralisée");
        Check.Contains("\"Activé\"", lines[1], "état en clair");
    }

    // ---------- Preferences of the interface (TRV-062, TRV-095, TRV-245, TRV-313) ----------

    [Test]
    public static void Interface_choices_are_a_closed_and_bounded_list()
    {
        var merged = ShellInterfaceRules.MergeInterface(
            Json("""{"theme":"light","navWidth":240,"helpTips":true}"""),
            Json("""{"theme":"dark","navWidth":999,"unknown":1,"helpTips":null,"profile":"expert","recentPages":["#/shell?onglet=aide","#/../x","#/shell?onglet=aide","#/fiche?dn=x"],"recentCommands":["page:accueil","Bad Id"]}"""));
        Check.Equal("dark", merged.GetProperty("theme").GetString(), "thème changé");
        Check.Equal(240, merged.GetProperty("navWidth").GetInt32(), "largeur hors bornes refusée, ancienne gardée");
        Check.False(merged.TryGetProperty("unknown", out _), "champ inconnu ignoré");
        Check.False(merged.TryGetProperty("helpTips", out _), "null retire le champ");
        Check.Equal("expert", merged.GetProperty("profile").GetString(), "profil");
        Check.Equal(1, merged.GetProperty("recentPages").GetArrayLength(), "adresses valides, uniques et sans objet de l’annuaire");
        Check.Equal(1, merged.GetProperty("recentCommands").GetArrayLength(), "identifiants valides");
        Check.True(ShellInterfaceRules.IsRecentPage("#/parametres?section=stockage"), "onglet d’écran gardé");
        Check.True(ShellInterfaceRules.IsRecentPage("#/accueil"), "écran seul gardé");
        Check.False(ShellInterfaceRules.IsRecentPage("#/fiche?dn=CN%3DCamille"), "DN : session seulement, jamais enregistré");
        Check.False(ShellInterfaceRules.IsRecentPage("#/rechercher?q=martin"), "texte saisi : session seulement");
        Check.False(ShellInterfaceRules.IsRecentPage("#/rechercher?OU=x"), "paramètre d’OU, casse ignorée");
        Check.False(ShellInterfaceRules.IsRecentPage("#/poste?vue=x%3dy"), "« = » encodé refusé");
        Check.False(ShellInterfaceRules.IsRecentPage("#/fiche?dn=Camille Martin"), "espace refusé");
        Check.False(ShellInterfaceRules.IsRecentPage("https://exemple"), "adresse externe refusée");
    }

    [Test]
    public static void Layout_maps_refuse_bad_keys_and_values_too_large()
    {
        var merged = ShellInterfaceRules.MergeMap(
            Json("""{"grid:old":{"w":1},"grid:gone":{"w":2}}"""),
            Json("{\"grid:new\":{\"w\":3},\"grid:gone\":null,\"bad key\":{},\"grid:big\":{\"x\":\"" + new string('a', 20_000) + "\"}}"),
            ShellInterfaceRules.IsLayoutKey, ShellInterfaceRules.MaxLayouts, ShellInterfaceRules.MaxLayoutBytes, ShellInterfaceRules.MaxLayoutsBytes, out var refused);
        Check.Equal(2, refused, "clé invalide et valeur trop grande refusées");
        Check.True(merged.TryGetProperty("grid:old", out _), "ancienne disposition gardée");
        Check.True(merged.TryGetProperty("grid:new", out _), "nouvelle disposition");
        Check.False(merged.TryGetProperty("grid:gone", out _), "null retire la disposition");
        Check.True(ShellInterfaceRules.IsBoardKey("interface"), "nom de tableau");
        Check.False(ShellInterfaceRules.IsBoardKey("Interface"), "majuscule refusée");
    }

    [Test]
    public static void Favourite_ous_stay_inside_the_domain_without_the_root()
    {
        var favourites = ShellInterfaceRules.NormalizeFavourites(
            ["OU=Postes," + Root, Root, "OU=Ailleurs,DC=autre,DC=local", "ou=postes,dc=example,dc=local", "pas un DN", null, "OU=Paris,OU=Postes," + Root],
            Root);
        Check.True(favourites.SequenceEqual(["OU=Postes," + Root, "OU=Paris,OU=Postes," + Root]), "favoris : " + string.Join(" | ", favourites));
        var many = Enumerable.Range(0, 30).Select(i => "OU=S" + i.ToString(System.Globalization.CultureInfo.InvariantCulture) + "," + Root).ToList<string?>();
        Check.Equal(ShellInterfaceRules.MaxFavourites, ShellInterfaceRules.NormalizeFavourites(many, Root).Length, "20 au plus");
        var key = ShellInterfaceRules.FavouritesKey(Root);
        Check.True(key.StartsWith(ShellInterfaceRules.FavouritesPrefix, StringComparison.Ordinal), "préfixe");
        Check.False(key.Contains("example", StringComparison.OrdinalIgnoreCase), "aucun nom de domaine dans la clé");
        Check.Equal(key, ShellInterfaceRules.FavouritesKey("DC=EXAMPLE,DC=LOCAL"), "clé sans casse");
    }

    // ---------- Window frame and interface policy (TRV-011, TRV-167, TRV-180) ----------

    [Test]
    public static void Color_ref_accepts_exactly_six_hexadecimal_digits()
    {
        Check.Equal(0x00332211, ShellTexts.ColorRef("#112233"), "rouge, vert, bleu inversés (COLORREF)");
        Check.Equal(0x00FFFFFF, ShellTexts.ColorRef("#FFFFFF"), "majuscules");
        Check.Null(ShellTexts.ColorRef("#fff"), "forme courte refusée");
        Check.Null(ShellTexts.ColorRef("#11223344"), "alpha refusé");
        Check.Null(ShellTexts.ColorRef("# 12345"), "blanc refusé");
        Check.Null(ShellTexts.ColorRef("#12345g"), "chiffre non hexadécimal");
        Check.Null(ShellTexts.ColorRef("Canvas"), "couleur système refusée");
        Check.Null(ShellTexts.ColorRef(null), "null");
    }

    [Test]
    public static void Interface_policy_reads_allow_expert_profile_like_domenia_1()
    {
        Check.True(ShellPolicies.Parse(""u8).ExpertAllowed, "sans fichier : Expert proposé");
        Check.Equal("défaut", ShellPolicies.Parse("{}"u8).Source, "sans clé : défaut");
        var hidden = ShellPolicies.Parse("""{"ui":{"allowExpertProfile":false}}"""u8);
        Check.False(hidden.ExpertAllowed, "false masque Expert (casse des noms ignorée)");
        Check.Equal("configuration", hidden.Source, "source");
        Check.False(ShellPolicies.Parse("""{"UI":{"AllowExpertProfile":0}}"""u8).ExpertAllowed, "0 masque Expert");
        Check.True(ShellPolicies.Parse("""{"UI":{"AllowExpertProfile":"false"}}"""u8).ExpertAllowed, "le texte « false » ne masque rien (seul le booléen compte)");
        Check.True(ShellPolicies.Parse("""{"UI":{"AllowExpertProfile":true}}"""u8).ExpertAllowed, "true");
        var broken = ShellPolicies.Parse("{"u8);
        Check.True(broken.ExpertAllowed, "JSON illisible : valeur par défaut, comme Domenia 1");
        Check.Equal("JSON illisible", broken.Problem, "motif court");
        Check.True(ShellPolicies.Parse("\uFEFF{\"UI\":{}}"u8).ExpertAllowed, "BOM ignoré");
    }

    [Test]
    public static void File_names_of_the_save_mode_follow_windows_rules()
    {
        Check.True(ShellFileNames.IsSafe("Domenia-Postes-20261022-0905.csv", "csv"), "nom d’export");
        Check.True(ShellFileNames.IsSafe("Rapport du parc.json", "json"), "espaces admis");
        Check.False(ShellFileNames.IsSafe("rapport.csv", "json"), "extension de la nature");
        Check.False(ShellFileNames.IsSafe(".csv", "csv"), "extension seule");
        Check.False(ShellFileNames.IsSafe("..\\x.csv", "csv"), "dossier refusé");
        Check.False(ShellFileNames.IsSafe("a/b.csv", "csv"), "barre oblique refusée");
        Check.False(ShellFileNames.IsSafe("a:b.csv", "csv"), "deux-points refusé");
        Check.False(ShellFileNames.IsSafe("CON.csv", "csv"), "nom de périphérique refusé");
        Check.False(ShellFileNames.IsSafe("lpt1.csv", "csv"), "nom de périphérique, casse ignorée");
        Check.False(ShellFileNames.IsSafe("rapport.csv ", "csv"), "blanc final refusé");
        Check.False(ShellFileNames.IsSafe(new string('a', 117) + ".csv", "csv"), "121 caractères refusés");
        Check.False(ShellFileNames.IsSafe("a\u0007.csv", "csv"), "caractère de contrôle refusé");
        var at = new DateTimeOffset(2026, 10, 22, 9, 5, 0, 123, TimeSpan.Zero);
        var signature = new ShellFileSignature(42, at);
        Check.True(signature.Matches(42, at.AddTicks(4_000)), "moins d’une milliseconde d’écart : même fichier");
        Check.False(signature.Matches(42, at.AddMilliseconds(2)), "date changée");
        Check.False(signature.Matches(43, at), "taille changée");
    }

    // ---------- Faults and blocked time (TRV-064, TRV-056) ----------

    [Test]
    public static void Swallowed_errors_are_traced_apart_from_the_faults()
    {
        var log = new RecordingJournal();
        var clock = TestClock.Fixed();
        var tracer = new ShellFaultTracer(log, clock);
        Check.True(tracer.Report("swallowed", "accueil", 1, "board.copy"), "première trace");
        Check.False(tracer.Report("swallowed", "accueil", 1, "board.copy"), "même endroit dans la minute : compté seulement");
        Check.True(tracer.Report("swallowed", "accueil", 1, "help-panel.guide"), "autre endroit : sa propre trace");
        Check.Equal(0, tracer.Total, "jamais compté parmi les erreurs");
        Check.Equal(3, tracer.Swallowed, "erreurs ignorées comptées");
        Check.True(tracer.Report("nested", "accueil", 2), "erreur imbriquée tracée");
        Check.Equal(2, tracer.Total, "erreur imbriquée comptée");
        Check.True(log.Lines.Any(l => l.Contains("erreur volontairement ignorée (board.copy)", StringComparison.Ordinal)), "endroit du code dans la trace");
        Check.True(log.Lines.Any(l => l.Contains("pendant le traitement d’une autre", StringComparison.Ordinal)), "nature de l’erreur imbriquée");
        Check.True(ShellFaultTracer.IsPlace("board.copy"), "endroit valide");
        Check.False(ShellFaultTracer.IsPlace("mot de passe=x"), "texte libre refusé");
        Check.False(ShellFaultTracer.IsPlace(new string('a', 65)), "65 caractères refusés");
    }

    [Test]
    public static void Blocked_time_of_the_panels_is_summed_and_traced_once_a_minute()
    {
        var log = new RecordingJournal();
        var clock = TestClock.Fixed();
        var tracer = new ShellMetricTracer(log, clock);
        Check.True(tracer.Report("accueil", 1, 2500), "première ligne");
        Check.False(tracer.Report("accueil", 2, 1500), "dans la minute : additionné");
        clock.Advance(TimeSpan.FromMinutes(1));
        Check.True(tracer.Report("accueil", 1, 1000), "une minute après : nouvelle ligne");
        Check.Equal(4, tracer.Panels, "panneaux de la session");
        Check.Equal(5000L, tracer.TotalMilliseconds, "temps total");
        Check.True(log.Lines.Any(l => l.Contains("3 panneau(x) modal(aux) fermé(s) sur l’écran accueil, interface bloquée 2.5 s", StringComparison.Ordinal)), "somme de la minute écoulée");
        tracer.Report("poste", 1, 99_999_999);
        Check.Equal(5000L + ShellMetricTracer.MaxMilliseconds, tracer.TotalMilliseconds, "un panneau compte une heure au plus");
    }

    // ---------- Team layouts and exports (TRV-311, TRV-054) ----------

    [Test]
    public static void Team_layout_is_read_from_the_dashboard_section()
    {
        var text = TeamLayouts.Parse("""{"dashboard":{"defaultLayoutInterface":"[{\"Key\":\"session.mode\"}]"}}"""u8, "Interface");
        Check.Equal("Dashboard.DefaultLayoutInterface", text.Key, "clé");
        Check.Equal("[{\"Key\":\"session.mode\"}]", text.Text, "valeur texte (casse des clés ignorée)");
        Check.Null(text.Problem, "aucun problème");
        var list = TeamLayouts.Parse("\uFEFF{\"Dashboard\":{\"DefaultLayoutComputer\":[{\"Key\":\"a\"}]}}"u8, "Computer");
        Check.Equal("[{\"Key\":\"a\"}]", list.Text, "liste directe, BOM ignoré");
        Check.Null(TeamLayouts.Parse("{}"u8, "Fleet").Text, "absente");
        Check.Null(TeamLayouts.Parse("{}"u8, "Fleet").Problem, "absente sans problème");
        Check.Equal("JSON illisible", TeamLayouts.Parse("{"u8, "Fleet").Problem, "JSON cassé");
        Check.Throws<ArgumentException>(() => TeamLayouts.Parse("{}"u8, "../x"), "nom de tableau refusé");
    }

    [Test]
    public static async Task Memory_exports_never_overwrite_a_file()
    {
        var store = new MemoryExportStore(TestClock.Fixed());
        var first = await store.SaveAsync("Domenia-x-20261022-0905.csv", Encoding.UTF8.GetBytes("a"), CancellationToken.None);
        var second = await store.SaveAsync("Domenia-x-20261022-0905.csv", Encoding.UTF8.GetBytes("b"), CancellationToken.None);
        Check.Equal("Domenia-x-20261022-0905.csv", first, "premier nom");
        Check.Equal("Domenia-x-20261022-0905-2.csv", second, "nom numéroté");
        Check.False(store.Persistent, "mémoire seulement");
        Check.Equal(2, store.List(10).Length, "deux exports");
        Check.Equal("csv", ShellExportNames.KindOf(second), "nature");
        Check.True(ShellExportNames.IsExportName(second), "nom d’export");
        Check.False(ShellExportNames.IsExportName("..\\Domenia-x.csv"), "chemin refusé");
        Check.False(ShellExportNames.IsExportName("notes.txt"), "autre fichier refusé");
    }
}
