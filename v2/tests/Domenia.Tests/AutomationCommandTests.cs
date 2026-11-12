using System.Globalization;
using System.Text;
using System.Text.Json;
using Domenia.App;
using Domenia.Core;

namespace Domenia.Tests;

internal static class AutomationCommandTests
{
    [Test]
    public static void Closed_grammar_refuses_mutations_network_modes_and_ambiguous_perimeters_before_host_callbacks()
    {
        string[][] commands =
        [
            ["reboot", "--base", @"C:\absente.db"],
            ["postes", "--base", @"C:\absente.db", "--postes", "PC1", "--serveur", "DC1"],
            ["postes", "--base", @"C:\absente.db", "--postes", "PC1", "--simulation"],
            ["postes", "--base", @"C:\absente.db", "--postes", "PC1", "--portable-config-export", @"C:\sortie.json"],
            ["postes", "--base", @"C:\absente.db", "--postes", "PC1", "--ou", Fixtures.Postes],
            ["postes", "--base", @"C:\absente.db", "--postes", "PC1", "--limite", "5001"],
            ["etat", "--base", @"C:\absente.db", "--postes", "PC1"],
            ["observations", "--base", @"C:\absente.db", "--postes", "PC1", "--famille", "Laps"],
            ["version", "--base", @"C:\absente.db"],
            ["postes", "--base", @"C:\absente.db", "--postes", "PC1", "-Computers", "PC2"],
        ];
        foreach (var command in commands)
        {
            using var output = new StringWriter(CultureInfo.InvariantCulture);
            var touched = false;
            var code = AutomationHostCommand.Run(command, output, TextWriter.Null, null,
                () => { touched = true; return false; }, TestClock.Fixed(), () => { touched = true; return new MemoryStream(); });
            Check.Equal(2, code, "refus de la grammaire fermée");
            Check.False(touched, "aucune configuration ni vérification native atteinte");
        }
        Check.Equal(4, AutomationCommandLine.Parse(["postes", "--base", @"C:\absente.db"]).ExitCode, "périmètre explicite requis");
        Check.False(AutomationCommandLine.IsRequested(["dossier"]), "route du dossier conservée");
        // Recette des binaires publiés 2.1.6 : « livraison apercu » répondait « Commande inconnue » depuis 2.0.8.
        Check.False(AutomationCommandLine.IsRequested(["livraison", "apercu", @"C:\Domenia"]), "maintenance du paquet conservée");
        Check.False(AutomationCommandLine.IsRequested(["livraison", "restaurer", @"C:\Domenia", "transaction", "confirmation"]), "restauration conservée");
        Check.True(AutomationCommandLine.IsRequested(["Livraison"]), "route exacte seulement, grammaire fermée inchangée");
    }

    [Test]
    public static void Explicit_simulation_refuses_real_base_and_output_before_configuration_or_package()
    {
        using var folder = new TemporaryFolder(); using var output = new StringWriter(CultureInfo.InvariantCulture);
        var touched = false;
        var code = AutomationHostCommand.Run(["etat", "--base", folder.File("inexistante.db"), "--sortie", folder.File("sortie.json")],
            output, TextWriter.Null, "1", () => { touched = true; return false; }, TestClock.Fixed(), () => { touched = true; return new MemoryStream(); });
        Check.Equal(4, code, "refus du réel dans la démonstration"); Check.False(touched, "aucun accès de configuration ni manifeste");
        Check.Equal(0, Directory.GetFileSystemEntries(folder.Path).Length, "aucun fichier ni profil créé");
        var configCode = AutomationHostCommand.Run(["etat", "--base", folder.File("inexistante.db")], output, TextWriter.Null,
            null, () => true, TestClock.Fixed(), () => { touched = true; return new MemoryStream(); });
        Check.Equal(4, configCode, "DemoProvider honoré"); Check.False(touched, "manifeste non atteint après DemoProvider");
        Check.Equal(4, AutomationHostCommand.Run(["version", "--sortie", folder.File("version.json")], output, TextWriter.Null,
            "1", () => false, TestClock.Fixed(), () => throw new InvalidOperationException("chemin réel interdit en démonstration")), "même version ne peut écrire une sortie réelle en démonstration");
    }

    [Test]
    public static void Version_is_machine_readable_without_resolving_a_base_or_profile_even_in_simulation()
    {
        using var output = new StringWriter(CultureInfo.InvariantCulture);
        var code = AutomationHostCommand.Run(["version"], output, TextWriter.Null, "1", () => throw new InvalidOperationException("ne doit pas être lu"),
            TestClock.Fixed(), () => new MemoryStream());
        Check.Equal(0, code, "succès du contrat local");
        using var json = JsonDocument.Parse(output.ToString());
        Check.Equal(ShellAutomation.ContractName, json.RootElement.GetProperty("Contract").GetString(), "contrat versionné exact");
        Check.Equal(7, json.RootElement.GetProperty("Items")[0].GetProperty("Commands").GetArrayLength(), "six commandes et le dossier déclarés");
        Check.True(json.RootElement.GetProperty("Source").GetProperty("Base").ValueKind == JsonValueKind.Null, "aucune base implicite");
    }

    [Test]
    public static void Manifest_refusal_stops_before_local_database_or_output_creation()
    {
        using var folder = new TemporaryFolder(); using var output = new StringWriter(CultureInfo.InvariantCulture);
        var code = AutomationHostCommand.Run(["etat", "--base", folder.File("absente.db"), "--sortie", folder.File("sortie.json")],
            output, TextWriter.Null, "0", () => throw new InvalidOperationException("variable prioritaire"), TestClock.Fixed(), () => null);
        Check.Equal(4, code, "refus du paquet");
        Check.Equal(0, Directory.GetFileSystemEntries(folder.Path).Length, "aucune ouverture créatrice");
    }

    [Test]
    public static void Local_output_is_atomic_verified_and_existing_destinations_are_preserved()
    {
        using var folder = new TemporaryFolder(); using var output = new StringWriter(CultureInfo.InvariantCulture);
        var args = new[] { "version", "--sortie", folder.File("version.json") };
        Check.Equal(0, AutomationHostCommand.Run(args, output, TextWriter.Null, "0", () => false, TestClock.Fixed(), () => new MemoryStream()), "fichier finalisé");
        var saved = File.ReadAllBytes(folder.File("version.json"));
        using var document = JsonDocument.Parse(saved);
        Check.Equal("version", document.RootElement.GetProperty("Command").GetString(), "réponse entière relue");
        Check.Equal(5, AutomationHostCommand.Run(args, TextWriter.Null, TextWriter.Null, "0", () => false, TestClock.Fixed(), () => new MemoryStream()), "refus d’écrasement");
        Check.True(saved.AsSpan().SequenceEqual(File.ReadAllBytes(folder.File("version.json"))), "sortie concurrente inchangée");
        Check.Equal(1, Directory.GetFiles(folder.Path).Length, "aucun temporaire résiduel");
        using var refused = new StringWriter(CultureInfo.InvariantCulture);
        Check.Equal(5, AutomationHostCommand.Run(["version", "--sortie", @"\\server\share\version.json"], refused, TextWriter.Null,
            "0", () => false, TestClock.Fixed(), () => new MemoryStream()), "partage refusé sans accès");
        using var refusal = JsonDocument.Parse(refused.ToString());
        Check.Equal(5, refusal.RootElement.GetProperty("ExitCode").GetInt32(), "le contrat JSON conserve le code de refus de sortie");
        Check.Contains("Destination locale refusée", refusal.RootElement.GetProperty("Error").GetString(), "motif de destination précis, sans erreur de base inventée");
    }

    [Test]
    public static void Missing_database_never_creates_database_output_or_profile()
    {
        using var folder = new TemporaryFolder();
        Check.Equal(3, AutomationHostCommand.Run(["etat", "--base", folder.File("absente.db"), "--sortie", folder.File("etat.json")],
            TextWriter.Null, TextWriter.Null, "0", () => false, TestClock.Fixed(), () => new MemoryStream()), "base absente explicitement signalée");
        Check.Equal(0, Directory.GetFileSystemEntries(folder.Path).Length, "aucune base, sauvegarde, sortie ou profil de remplacement");
    }
}
