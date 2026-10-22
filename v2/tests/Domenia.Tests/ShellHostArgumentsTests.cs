using System.Text.Json;
using Domenia.Bridge;
using Domenia.Core;

namespace Domenia.Tests;

/// <summary>
/// Arguments of the host operations of the shell (ShellHostArguments, docs/ops/shell.md § 3): every refusal comes before any
/// file is touched. The host module itself (Domenia.App) only calls these rules. Written on 22 October 2026, run at the very
/// end (decision of 21/10).
/// </summary>
internal static class ShellHostArgumentsTests
{
    private static JsonElement Json(string text) => JsonDocument.Parse(text).RootElement.Clone();

    private static string Refusal(Action action, string message) => Check.Throws<BridgeOperationException>(action, message).Code;

    [Test]
    public static void Window_chrome_takes_a_bounded_title_and_two_colours()
    {
        var ok = ShellHostArguments.Chrome(Json("""{"title":"Fiche · Camille","dark":true,"writeActive":false,"caption":"#101b2c","text":"#edf4ff"}"""));
        Check.Equal("Fiche · Camille", ok.Title, "titre");
        Check.True(ok.Dark, "sombre");
        Check.Equal("#101b2c", ok.Caption, "légende");
        var minimal = ShellHostArguments.Chrome(Json("""{"dark":false,"writeActive":false}"""));
        Check.Null(minimal.Caption, "couleurs facultatives");
        Check.Equal("argument.invalid", Refusal(() => ShellHostArguments.Chrome(Json("{\"title\":\"" + new string('x', ShellTexts.MaxTitleLength * 2 + 1) + "\",\"dark\":false,\"writeActive\":false}")), "titre trop long"), "titre borné");
        Check.Equal("argument.invalid", Refusal(() => ShellHostArguments.Chrome(Json("""{"dark":false,"writeActive":false,"caption":"Canvas"}""")), "couleur système"), "couleur #rrggbb seulement");
        Check.Equal("argument.invalid", Refusal(() => ShellHostArguments.Chrome(Json("""{"dark":false,"writeActive":false,"other":1}""")), "argument inconnu"), "argument inconnu refusé");
    }

    [Test]
    public static void Exports_are_checked_before_anything_is_written()
    {
        var table = ShellHostArguments.Save(Json("""{"kind":"csv","name":"OU Postes","headers":["Nom","Écart"],"rows":[["PC-01",-5],["PC-02",null]],"secretColumns":[1]}"""));
        Check.Equal("csv", table.Kind, "nature");
        Check.Equal("-5", table.Rows![0][1], "nombre de la page en texte, signe gardé");
        Check.True(table.SecretColumns.SetEquals([1]), "colonne secrète");
        Check.Null(table.Target, "dossier des exports par défaut");
        var text = ShellHostArguments.Save(Json("""{"kind":"csv","name":"liste","text":"a;b\n1;2"}"""));
        Check.Equal("a;b\n1;2", text.Text, "CSV déjà construit");
        var json = ShellHostArguments.Save(Json("""{"kind":"json","name":"disposition","text":"{\"a\":1}"}"""));
        Check.Equal("json", json.Kind, "document JSON");
        var placed = ShellHostArguments.Save(Json("""{"kind":"json","name":"d","text":"{}","target":{"folder":"C:\\Users\\x\\Documents","fileName":"disposition.json","replace":{"size":12,"at":"2026-10-22T09:05:00.123Z"}}}"""));
        Check.Equal("disposition.json", placed.Target!.FileName, "emplacement choisi");
        Check.Equal(12L, placed.Target.Replace!.Size, "signature du fichier à remplacer");
        Check.Equal("argument.invalid", Refusal(() => ShellHostArguments.Save(Json("""{"kind":"xml","name":"x"}""")), "nature inconnue"), "nature fermée");
        Check.Equal("argument.invalid", Refusal(() => ShellHostArguments.Save(Json("{\"kind\":\"csv\",\"name\":\"" + new string('n', 81) + "\",\"text\":\"a\"}")), "nom trop long"), "nom de 80 caractères au plus");
        Check.Equal("argument.invalid", Refusal(() => ShellHostArguments.Save(Json("""{"kind":"json","name":"x","text":"{"}""")), "JSON invalide"), "JSON vérifié");
        Check.Equal("argument.invalid", Refusal(() => ShellHostArguments.Save(Json("""{"kind":"json","name":"x"}""")), "texte manquant"), "texte obligatoire en JSON");
        Check.Equal("argument.invalid", Refusal(() => ShellHostArguments.Save(Json("""{"kind":"csv","name":"x","text":"a","headers":["a"],"rows":[]}""")), "texte et tableau"), "une seule forme de CSV");
        Check.Equal("argument.invalid", Refusal(() => ShellHostArguments.Save(Json("""{"kind":"csv","name":"x","headers":["a"],"rows":[["1","2"]]}""")), "ligne trop longue"), "cellules bornées par les en-têtes");
        Check.Equal("argument.invalid", Refusal(() => ShellHostArguments.Save(Json("""{"kind":"csv","name":"x","headers":["a"],"rows":[[{"x":1}]]}""")), "objet dans une cellule"), "cellule simple seulement");
        Check.Equal("argument.invalid", Refusal(() => ShellHostArguments.Save(Json("""{"kind":"csv","name":"x","headers":["a"],"rows":[],"secretColumns":[3]}""")), "colonne secrète hors bornes"), "colonne secrète existante");
        Check.Equal("argument.invalid", Refusal(() => ShellHostArguments.Save(Json("""{"kind":"json","name":"x","text":"{}","target":{"folder":"Documents","fileName":"a.json"}}""")), "dossier relatif"), "chemin complet exigé");
        Check.Equal("argument.invalid", Refusal(() => ShellHostArguments.Save(Json("""{"kind":"json","name":"x","text":"{}","target":{"folder":"C:\\x","fileName":"a.csv"}}""")), "extension d’une autre nature"), "nom de la nature");
        Check.Equal("argument.invalid", Refusal(() => ShellHostArguments.Save(Json("""{"kind":"json","name":"x","text":"{}","target":{"folder":"C:\\x","fileName":"a.json","replace":{"size":1,"at":"hier"}}}""")), "date illisible"), "date ISO exigée");
        Check.True(json.SecretColumns.Count == 0, "aucune colonne secrète en JSON");
    }

    [Test]
    public static void Picker_paths_pages_and_boards_are_bounded()
    {
        Check.Equal((null as string, "all"), ShellHostArguments.Browse(Json("""{"filter":"all"}""")), "emplacements de départ");
        Check.Equal("argument.invalid", Refusal(() => ShellHostArguments.Browse(Json("""{"filter":"exe"}""")), "filtre"), "filtre fermé");
        Check.Equal("argument.invalid", Refusal(() => ShellHostArguments.Browse(Json("{\"folder\":\"" + new string('a', 1025) + "\",\"filter\":\"all\"}")), "chemin long"), "1 024 caractères au plus");
        Check.Equal("argument.invalid", Refusal(() => ShellHostArguments.Share(Json("""{"filter":"csv"}""")), "partage sans dossier"), "dossier exigé pour un partage");
        Check.Equal(("C:\\x.csv", "csv"), ShellHostArguments.Read(Json("""{"path":"C:\\x.csv","kind":"csv"}""")), "lecture");
        Check.Equal("argument.invalid", Refusal(() => ShellHostArguments.Read(Json("""{"path":"C:\\x.csv","kind":"all"}""")), "nature de lecture"), "csv ou json");
        Check.Equal("accueil", ShellHostArguments.Page(Json("""{"page":"accueil"}""")), "écran");
        Check.Equal("argument.invalid", Refusal(() => ShellHostArguments.Page(Json("""{"page":"../x"}""")), "écran invalide"), "nom d’écran");
        Check.Equal("Interface", ShellHostArguments.Board(Json("""{"board":"Interface"}""")), "tableau");
        Check.Equal("argument.invalid", Refusal(() => ShellHostArguments.Board(Json("""{"board":"interface"}""")), "tableau en minuscules"), "nom de tableau de Domenia 1");
        Check.Null(ShellHostArguments.ExportFileName(Json("""{"fileName":null}""")), "dossier seul");
        Check.Equal("argument.invalid", Refusal(() => ShellHostArguments.ExportFileName(Json("""{"fileName":"..\\notes.txt"}""")), "nom hors export"), "nom d’export seulement");
    }
}
