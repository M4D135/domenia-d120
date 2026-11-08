using System.Security.Principal;
using System.Text;
using Domenia.Ad;
using Domenia.Core;
using Domenia.Store;

namespace Domenia.Tests;

internal static class DirectoryValueTests
{
    [Test]
    public static void Invalid_utf8_sequences_remain_visible_and_truncation_never_splits_a_surrogate_pair()
    {
        Check.Equal(@"\xE0\x80\x80", AdText.DecodeUtf8(new byte[] { 0xE0, 0x80, 0x80 }), "encodage trop long refusé sans perdre d’octet");
        Check.Equal(@"\xED\xA0\x80", AdText.DecodeUtf8(new byte[] { 0xED, 0xA0, 0x80 }), "substitut Unicode invalide conservé en octets visibles");
        Check.Equal(@"\xF4\x90\x80\x80", AdText.DecodeUtf8(new byte[] { 0xF4, 0x90, 0x80, 0x80 }), "point au-delà d’Unicode conservé");
        Check.Equal("😀", AdText.DecodeUtf8(Encoding.UTF8.GetBytes("😀")), "un point valide hors BMP reste intact");
        Check.Equal("a…", AdText.Flat("a😀b", 3), "la coupe ne laisse pas un demi-caractère");
        Check.Equal("a", AdText.Flat("a ", 1), "les blancs terminaux ne provoquent pas de fausse coupe");
        Check.Equal("ab…", AdText.Flat("abc" + new string('x', 100_000), 3), "la préparation d’une ligne est bornée");
    }

    // A free text as an operator writes it in the directory: longer than any display bound, two lines, a tab, doubled and edge spaces.
    internal static readonly string LongText = "  Poste de l’accueil, salle 12 :  " + new string('a', 180) + "\r\n\tRemis à neuf le 3 juin ; " + new string('b', 120) + "  ";

    [Test]
    public static void An_invalid_octet_is_shown_visible_by_the_display_helper_and_the_data_path_keeps_its_decoding()
    {
        Check.Equal("René Chervès", AdText.DecodeUtf8(Encoding.UTF8.GetBytes("René Chervès")), "un texte UTF-8 valide est décodé comme avant");
        Check.Equal("€", AdText.DecodeUtf8(new byte[] { 0xE2, 0x82, 0xAC }), "une séquence valide de trois octets est décodée");
        Check.Equal(@"a\xFFb", AdText.DecodeUtf8(new byte[] { 0x61, 0xFF, 0x62 }), "à l’affichage, un octet invalide reste visible sous sa forme « \\xFF »");
        Check.Equal(@"\xE9", AdText.DecodeUtf8(new byte[] { 0xE9 }), "un octet qui annonçait une séquence et ne la poursuit pas reste visible");
        Check.Equal(@"\xC3", AdText.DecodeUtf8(new byte[] { 0xC3 }), "un octet de tête tronqué n’est pas remplacé en silence");
        Check.Equal("", AdText.DecodeUtf8([]), "aucun octet lu est une ligne vide");
        var entry = new AdEntry("CN=PC-01," + Fixtures.Postes, new Dictionary<string, IReadOnlyList<object>>
        {
            ["description"] = [new byte[] { 0x61, 0xFF, 0x62 }],
            ["memberOf"] = [new byte[] { 0x61 }, new byte[] { 0xFE }],
        });
        Check.Equal(Encoding.UTF8.GetString(new byte[] { 0x61, 0xFF, 0x62 }), entry.String("description"),
            "la donnée lue via AdEntry n’est pas réécrite en texte « \\xFF » qui pourrait repartir vers l’annuaire");
        Check.Equal(@"a\xFFb", entry.DisplayString("description"), "l’affichage rend l’octet invalide visible sans changer la donnée");
        Check.Equal((byte)0xFF, ((byte[])entry.Raw("description")[0])[1], "l’octet brut reste intact");
        Check.Equal(2, entry.Strings("memberOf").Count, "chaque valeur multi-valuée est rendue");
    }

    [Test]
    public static void Flat_text_is_a_display_value_bounded_at_240_characters()
    {
        Check.Equal(AdText.Flat(LongText), SupportText.Flat(LongText), "Assistance utilise la projection d’affichage commune");
        Check.Equal(AdText.Flat(LongText), RelationRules.Flat(LongText, 240), "Relations utilise la même projection sans modifier la source");
        Check.Equal("", AdText.Flat(null), "rien d’écrit tient sur une ligne vide");
        Check.Equal("", AdText.Flat(" \t\r\n"), "des blancs seuls ne forment aucune ligne");
        Check.Equal("a b c", AdText.Flat(" a\r\nb\tc "), "blancs et retours à la ligne aplatis, bouts coupés");
        Check.Equal(new string('a', AdText.FlatMaximum), AdText.Flat(new string('a', AdText.FlatMaximum)), "à la borne, rien n’est coupé");
        var cut = AdText.Flat(new string('a', 500));
        Check.Equal(AdText.FlatMaximum, cut.Length, "une ligne affichée est bornée à 240 caractères");
        Check.True(cut.EndsWith("…", StringComparison.Ordinal), "la coupe est visible, jamais silencieuse");
        Check.Throws<ArgumentOutOfRangeException>(() => AdText.Flat("a", 0), "une borne nulle est refusée");
    }

    [Test]
    public static void The_mapper_keeps_every_directory_value_exactly_as_read()
    {
        Check.True(LongText.Length > AdText.FlatMaximum && LongText.Contains('\n', StringComparison.Ordinal), "le texte d’essai dépasse la borne d’affichage et tient sur deux lignes");
        var groups = new[] { "CN=Groupe A," + Fixtures.Root, "CN=Groupe B," + Fixtures.Root, "CN=Groupe C," + Fixtures.Root };
        var computer = AdDirectoryMapper.Computer(Entry("CN=PC-01," + Fixtures.Postes, "pc-01", new()
        {
            ["name"] = ["PC-01"], ["description"] = [LongText], ["location"] = ["  Bâtiment B\n2e étage  "],
            ["operatingSystem"] = ["Windows 11  Entreprise"], ["memberOf"] = [.. groups],
        }));
        Check.NotNull(computer, "un poste avec son identité est converti");
        Check.Equal(LongText, computer!.Description, "la description du poste est la valeur exacte de l’annuaire");
        Check.Equal("  Bâtiment B\n2e étage  ", computer.Location, "l’emplacement garde ses blancs et son retour à la ligne");
        Check.Equal("Windows 11  Entreprise", computer.OperatingSystem, "le système garde ses deux espaces");
        Check.Equal(string.Join('|', groups), string.Join('|', computer.MemberOf), "les valeurs multiples restent toutes, dans l’ordre lu");
        var user = AdDirectoryMapper.User(Entry("CN=Anne," + Fixtures.People, "anne", new()
        {
            ["cn"] = ["Anne"], ["sAMAccountName"] = ["anne"], ["description"] = [LongText], ["displayName"] = ["Le Gall,  Anne "],
            ["title"] = ["Cheffe\nde service"], ["mail"] = [" anne@test.local"], ["memberOf"] = [.. groups],
        }));
        Check.NotNull(user, "un utilisateur avec son identité est converti");
        Check.Equal(LongText, user!.Description, "la description de l’utilisateur est la valeur exacte");
        Check.Equal("Le Gall,  Anne ", user.DisplayName, "le nom affiché n’est ni rogné ni normalisé");
        Check.Equal("Cheffe\nde service", user.Title, "la fonction garde son retour à la ligne");
        Check.Equal(" anne@test.local", user.Mail, "le courriel n’est pas retouché par la lecture");
        Check.Equal(3, user.MemberOf.Length, "toutes les appartenances sont gardées");
        Check.Null(AdDirectoryMapper.User(Entry("CN=Bob," + Fixtures.People, "bob", new() { ["cn"] = ["Bob"] }))!.Description,
            "une description absente reste absente, jamais une chaîne vide");
    }

    [Test]
    public static async Task A_long_description_survives_the_real_read_store_and_reopen_path_unchanged()
    {
        using var folder = new TemporaryFolder(); var clock = TestClock.Fixed();
        var database = new DomeniaDatabase(folder.File("values.db"), Fixtures.Root, clock); await database.InitializeAsync(CancellationToken.None);
        var pc = Fixtures.Computer("PC1");
        var entry = AdPosteNetworkTests.Entry(pc);
        var attributes = new Dictionary<string, IReadOnlyList<object>>(StringComparer.OrdinalIgnoreCase)
        {
            ["description"] = [LongText], ["location"] = ["Salle 12\r\nArmoire 3"], ["operatingSystem"] = ["Windows 11 Entreprise"],
        };
        foreach (var name in new[] { "objectGUID", "objectSid", "objectClass", "name", "sAMAccountName", "dNSHostName", "whenCreated", "userAccountControl" })
        {
            attributes[name] = entry.Raw(name);
        }
        using var ldap = new AdBoundaryTests.RecordingAdConnection();
        ldap.SearchAnswer = q => q.Filter == AdDirectoryMapper.ComputerFilter ? [new AdEntry(pc.DistinguishedName, attributes)] : [];
        using (var source = new AdDirectorySource("test.local", () => @"TEST\operator", clock, connection: ldap, localStore: new SqliteDirectoryCache(database)))
        {
            var state = await source.RefreshAsync(MeasureFamily.Directory, DirectoryStorageReceiptTests.Scope, CancellationToken.None);
            Check.Equal(LongText, state.Directory.Computers.Single().Description, "valeur exacte dans le relevé publié");
        }
        var reopened = await new SqliteDirectoryCache(new(database.Path, Fixtures.Root, clock)).ReadAsync(CancellationToken.None);
        Check.NotNull(reopened, "la base locale est relue après réouverture");
        var stored = reopened!.Computers.Single();
        Check.Equal(LongText, stored.Description, "la description relue de SQLite est identique, retours à la ligne et blancs compris");
        Check.Equal("Salle 12\r\nArmoire 3", stored.Location, "l’emplacement relu garde son retour à la ligne");
        Check.Equal(Encoding.UTF8.GetByteCount(LongText), Encoding.UTF8.GetByteCount(stored.Description!), "même longueur en octets, rien de coupé");
    }

    private static AdEntry Entry(string dn, string seed, Dictionary<string, IReadOnlyList<object>> values)
    {
        var sid = new SecurityIdentifier(Fixtures.Domain.DomainSid + "-1201");
        var sidBytes = new byte[sid.BinaryLength];
        sid.GetBinaryForm(sidBytes, 0);
        values["objectGUID"] = [Fixtures.IdOf(seed).ToByteArray()];
        values["objectSid"] = [sidBytes];
        return new AdEntry(dn, values);
    }
}
