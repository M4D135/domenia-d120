using System.ComponentModel;
using System.Text.Json;

namespace Domenia.App;

internal static class PackageLifecycleCommand
{
    internal static bool IsRequested(string[] args) => args.Length > 0 && args[0] == "livraison";

    internal static int Run(string source, string[] args, TextWriter output, TimeProvider clock, CancellationToken token = default,
        Func<PackageHealthRequest, CancellationToken, PackageHealthReceipt>? healthCheck = null, Func<FileStream, PackageNativeSignature>? signatureVerifier = null)
    {
        try
        {
            if (!IsRequested(args) || args.Length is < 3 or > 6 || args.Any(a => a.Length > 1024 || a.Any(char.IsControl)))
            { throw Usage(); }
            var delivery = new PackageLifecycle(source, clock) { RequireHealth = healthCheck is not null, HealthCheck = healthCheck, SignatureVerifier = signatureVerifier };
            using var stop = CancellationTokenSource.CreateLinkedTokenSource(token);
            ConsoleCancelEventHandler cancel = (_, e) => { e.Cancel = true; stop.Cancel(); };
            Console.CancelKeyPress += cancel;
            try
            {
                object result = (args[1], args.Length) switch
                {
                    ("apercu", 3) => delivery.PreviewUpdate(args[2], stop.Token),
                    ("appliquer", 4) => delivery.Update(args[2], args[3], stop.Token),
                    ("apercu-desinstallation", 3) => delivery.PreviewUninstall(args[2], stop.Token),
                    ("desinstaller", 4) => delivery.Uninstall(args[2], args[3], stop.Token),
                    ("apercu-desinstallation", 5) => delivery.PreviewUninstall(args[2], stop.Token, Options(args[3], args[4])),
                    ("desinstaller", 6) => delivery.Uninstall(args[2], args[3], stop.Token, Options(args[4], args[5])),
                    ("apercu-reprise", 4) => delivery.PreviewRecovery(args[2], args[3], false, stop.Token),
                    ("reprendre", 5) => delivery.Recover(args[2], args[3], false, args[4], stop.Token),
                    ("apercu-restauration", 4) => delivery.PreviewRecovery(args[2], args[3], true, stop.Token),
                    ("restaurer", 5) => delivery.Recover(args[2], args[3], true, args[4], stop.Token),
                    _ => throw Usage(),
                };
                output.WriteLine(JsonSerializer.Serialize(result)); output.Flush();
                return result is PackageLifecycleResult { Action: "rolledBack" } ? 3 : 0;
            }
            finally { Console.CancelKeyPress -= cancel; }
        }
        catch (Exception error) when (error is IOException or InvalidDataException or UnauthorizedAccessException or ArgumentException or JsonException or Win32Exception or OperationCanceledException)
        {
            output.WriteLine(JsonSerializer.Serialize(new { Status = "Refus ou interruption", Detail = error.Message,
                Recovery = "Conservez le dossier frère .<cible>.domenia-lifecycle et le marqueur. Relisez l’aperçu de reprise ou de restauration avec l’identifiant de transaction ; aucune reprise automatique." }));
            output.Flush(); return 2;
        }
    }

    private static PackageUninstallOptions Options(string local, string profile)
    {
        static bool Choice(string value, string prefix) => value == prefix + "supprimer" ? true : value == prefix + "conserver" ? false : throw Usage();
        return new(Choice(local, "local="), Choice(profile, "profil="));
    }
    private static ArgumentException Usage() => new("Livraison depuis un paquet vérifié distinct : livraison apercu <cible>, puis livraison appliquer <cible> <Confirmation>. "
        + "Désinstallation : apercu-desinstallation/desinstaller ; choix facultatifs ensemble local=conserver|supprimer profil=conserver|supprimer après la confirmation éventuelle. Reprise ou restauration : apercu-reprise/apercu-restauration <cible> <transaction>, puis reprendre/restaurer <cible> <transaction> <Confirmation>.");
}
