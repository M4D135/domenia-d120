using System.Collections.Immutable;
using System.Text.Json;
using Domenia.Core.Queries;
using Domenia.Inventory;

namespace Domenia.Tests;

internal static class QueryInstanceChoiceTests
{
    private const string InstanceMethod = "instance:sec.bitlockervolumes:EncryptionMethod";
    private const string VolumeMethod = "probe:sec.bitlockermethodc";

    [Test]
    public static void BitLocker_instance_choices_keep_the_documented_numeric_codes_and_French_labels()
    {
        var method = QueryCatalog.Find(QueryTarget.Computer, InstanceMethod)!;
        Check.Equal(QueryFieldKind.Number, method.Kind, "les valeurs du fournisseur restent numériques");
        Check.Equal("EncryptionMethod", method.Property, "identifiant technique inchangé");
        Check.Contains("Méthode de chiffrement", method.Name, "nom lisible dans le catalogue");
        Check.Equal(9, method.Choices.Length, "huit méthodes et valeur inconnue documentée");
        Check.Equal("XTS-AES 128", QueryFormat.Raw(6, method), "code 6 proposé sans saisie technique");
        Check.Equal("XTS-AES 128", QueryFormat.Raw((uint)6, method), "uint32 CIM reconnu comme valeur numérique");
        Check.Equal("XTS-AES 256", QueryFormat.Raw(7, method), "code 7 sans diffuseur");
        Check.Equal("Non chiffré", QueryFormat.Raw(0, method), "zéro réellement lu");
        Check.Equal("Méthode inconnue", QueryFormat.Raw(uint.MaxValue, method), "inconnu explicite distinct de zéro");
        Check.Equal("", QueryFormat.Raw(null, method), "absence jamais convertie en zéro");
        Check.Equal("99", QueryFormat.Raw(99, method), "nouveau code fournisseur conservé");
        Check.Equal(QueryFieldKind.Number, method.Kind, "type uint32 numérique conservé");
        Check.Equal(QueryValueKind.Number, QueryValue.FromRaw(uint.MaxValue).Kind, "sentinelle uint32 numérique avant sérialisation");
        Check.Equal("6", JsonSerializer.Serialize(method.Choices.Single(c => c.Name == "XTS-AES 128").Value), "contrat JSON : primitive numérique");
        var protection = QueryCatalog.Find(QueryTarget.Computer, "instance:sec.bitlockervolumes:ProtectionStatus")!;
        Check.Equal("Protection inconnue", QueryFormat.Raw(2, protection), "protection inconnue distincte de protection désactivée");
        Check.Equal("Protection désactivée", QueryFormat.Raw(0, protection), "protection suspendue ne signifie pas volume déchiffré");
        var conversion = QueryCatalog.Find(QueryTarget.Computer, "instance:sec.bitlockervolumes:ConversionStatus")!;
        Check.Equal("Chiffrement suspendu", QueryFormat.Raw(4, conversion), "conversion indépendante de la méthode et de la protection");
    }

    [Test]
    public static void BitLocker_choices_are_scoped_to_the_documented_provider_and_numeric_schema()
    {
        var probe = QueryProbeCatalog.Find("sec.bitlockervolumes")!;
        Check.Equal(9, QueryInstanceChoices.Choices(probe, "EncryptionMethod", QueryFieldKind.Number).Length, "fournisseur exact reconnu");
        Check.True(QueryInstanceChoices.Choices(probe with { Namespace = "root\\cimv2" }, "EncryptionMethod", QueryFieldKind.Number).IsEmpty, "aucun code inféré pour une autre classe homonyme");
        Check.True(QueryInstanceChoices.Choices(probe with { Class = "OtherVolume" }, "EncryptionMethod", QueryFieldKind.Number).IsEmpty, "aucun code inféré par le nom de la propriété seule");
        Check.True(QueryInstanceChoices.Choices(probe, "EncryptionMethod", QueryFieldKind.Text).IsEmpty, "une déclaration texte n’est pas convertie silencieusement");
    }

    [Test]
    public static void The_scalar_method_targets_C_explicitly_and_maps_the_same_provider_codes()
    {
        var probe = QueryProbeCatalog.Find("sec.bitlockermethodc")!;
        Check.Equal("DriveLetter='C:'", probe.Filter, "jamais le premier volume arbitraire du poste");
        Check.Equal("First", probe.Mode, "une valeur du volume explicitement ciblé");
        Check.Equal("EncryptionMethod", probe.Properties.Single(), "une seule propriété en lecture");
        var field = QueryCatalog.Find(QueryTarget.Computer, VolumeMethod)!;
        Check.True(field.Groupable, "répartition de postes disponible");
        Check.Equal(QueryFieldKind.Text, field.Kind, "codes convertis en libellés de répartition");
        var compiled = QueryEngine.Compile(QueryRecipe.Empty() with { Name = "Méthodes de C:", GroupBy = VolumeMethod });
        Check.Equal(VolumeMethod, compiled.Normalized.GroupBy, "répartition du scalaire compilée");
        foreach (var choice in QueryCatalog.Find(QueryTarget.Computer, InstanceMethod)!.Choices)
        {
            var instance = new ProbeInstance("C:", ImmutableDictionary<string, object?>.Empty.Add("EncryptionMethod", choice.Value.Number), []);
            var reading = new ProbeReading(probe.Id, TestClock.Reference, null, false, false, 1, true, [instance]);
            Check.Equal(choice.Name, QueryProbeCatalog.Values(probe, reading, TestClock.Reference).Single(), "même code et même libellé pour les deux parcours");
            Check.True(field.Choices.Any(c => c.Name == choice.Name && c.Value.Text == choice.Name), "choix scalaire proposé au formulaire");
        }
        var absent = new ProbeReading(probe.Id, TestClock.Reference, null, false, false, 0, true, []);
        Check.Equal(0, QueryProbeCatalog.Values(probe, absent, TestClock.Reference).Count, "volume absent ne devient jamais non chiffré");
        var missingProperty = absent with { Count = 1, Instances = [new ProbeInstance("C:", ImmutableDictionary<string, object?>.Empty, [])] };
        Check.Equal(0, QueryProbeCatalog.Values(probe, missingProperty, TestClock.Reference).Count, "propriété absente ne devient jamais une catégorie vide connue");
        var nullProperty = missingProperty with { Instances = [new ProbeInstance("C:", ImmutableDictionary<string, object?>.Empty.Add("EncryptionMethod", null), [])] };
        Check.Equal(0, QueryProbeCatalog.Values(probe, nullProperty, TestClock.Reference).Count, "propriété null ne devient jamais une catégorie vide connue");
        Check.Equal(0, QueryProbeCatalog.Values(probe, absent with { Error = "Accès refusé" }, TestClock.Reference).Count, "erreur ne devient jamais non chiffré");
    }

    [Test]
    public static void The_scalar_method_passes_runtime_read_admission_and_saved_reading_validation()
    {
        var computer = Fixtures.IdOf("bitlocker-C");
        var request = new QueryMeasureRequest([computer], false, false, false, ["sec.bitlockermethodc"]);
        var context = QueryPersonalProbes.ForRequest(request);
        var probe = context.Find(request.Probes.Single())!;
        Check.NotNull(probe, "même catalogue que le lecteur réel, sans déclaration personnelle");
        var select = QueryPersonalProbes.Select(probe, TestClock.Reference);
        var accepted = WmiWorkstationReader.CheckWorkshopSelect(probe.Namespace, select, 1);
        Check.Equal(select.CanonicalQuery, accepted.CanonicalQuery, "SELECT accepté par les gardes du lecteur WMI réel sans contact");
        Check.Equal("Win32_EncryptableVolume", accepted.ClassName, "fournisseur attendu");
        Check.Contains("'C:'", accepted.CanonicalQuery, "filtre conservé jusqu’à la commande native");
        var instance = new ProbeInstance("0", ImmutableDictionary<string, object?>.Empty.Add("EncryptionMethod", (uint)6), []);
        var reading = new ProbeReading(probe.Id, TestClock.Reference, null, false, false, 1, true, [instance]);
        var stored = new QueryComputerReadings(computer, "CN=bitlocker-C,OU=Postes,DC=test,DC=local", TestClock.Reference.AddYears(-1), [reading], []);
        QueryReadingRules.Validate(stored, TestClock.Reference);
        Check.Equal(probe, QueryReadingRules.Definition(reading), "définition retrouvée lors de la sauvegarde puis de la réévaluation");
    }
}
