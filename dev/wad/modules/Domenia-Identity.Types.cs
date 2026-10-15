// Immutable identities shared by Fiche, Relations, Assistance and the intervention plans.
// C# 5 only: this file is compiled by the Windows PowerShell 5.1 Add-Type compiler.
using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;

namespace Domenia
{
    // One selected directory object, as read under one account, one session and one search generation.
    public sealed class SelectionIdentity
    {
        private readonly string domain;
        private readonly string guid;
        private readonly string sid;
        private readonly string type;
        private readonly string dn;
        private readonly string name;
        private readonly string login;
        private readonly string reader;
        private readonly long epoch;
        private readonly long generation;

        public SelectionIdentity(string domain, string guid, string sid, string type, string dn, string name, string login, string reader, long epoch, long generation)
        {
            if (string.IsNullOrWhiteSpace(domain)) throw new ArgumentException("Domaine requis.", "domain");
            if (string.IsNullOrWhiteSpace(type)) throw new ArgumentException("Type requis.", "type");
            // The Guid property of this class hides the System.Guid type inside its members.
            System.Guid parsed;
            if (!System.Guid.TryParse(guid ?? string.Empty, out parsed) || parsed == System.Guid.Empty) throw new ArgumentException("GUID requis.", "guid");
            this.domain = domain.Trim();
            this.guid = parsed.ToString("D");
            this.sid = (sid ?? string.Empty).Trim();
            this.type = type.Trim();
            this.dn = dn ?? string.Empty;
            this.name = name ?? string.Empty;
            this.login = login ?? string.Empty;
            this.reader = reader ?? string.Empty;
            this.epoch = epoch;
            this.generation = generation;
        }

        public string Domain { get { return domain; } }
        public string Guid { get { return guid; } }
        public string Sid { get { return sid; } }
        public string Type { get { return type; } }
        public string DN { get { return dn; } }
        public string Name { get { return name; } }
        public string Login { get { return login; } }
        public string Reader { get { return reader; } }
        public long Epoch { get { return epoch; } }
        public long Generation { get { return generation; } }

        // Object identity only: a label, a DN or a login never takes part in it.
        public string Key { get { return (domain + "|" + guid).ToLowerInvariant(); } }

        public bool SameObject(SelectionIdentity other)
        {
            return other != null && string.Equals(Key, other.Key, StringComparison.Ordinal);
        }

        public bool SameContext(SelectionIdentity other)
        {
            return SameObject(other)
                && string.Equals(type, other.type, StringComparison.OrdinalIgnoreCase)
                && string.Equals(reader, other.reader, StringComparison.Ordinal)
                && epoch == other.epoch
                && generation == other.generation;
        }

        public override string ToString() { return type + " : " + name; }
    }

    public sealed class PlanChange
    {
        private readonly string attribute;
        private readonly string kind;
        private readonly string before;
        private readonly string after;

        public PlanChange(string attribute, string kind, string before, string after)
        {
            if (string.IsNullOrWhiteSpace(attribute)) throw new ArgumentException("Attribut requis.", "attribute");
            this.attribute = attribute.Trim();
            this.kind = string.IsNullOrWhiteSpace(kind) ? "Replace" : kind.Trim();
            this.before = before ?? string.Empty;
            this.after = after ?? string.Empty;
        }

        public string Attribute { get { return attribute; } }
        public string Kind { get { return kind; } }
        public string Before { get { return before; } }
        public string After { get { return after; } }
        internal string Canonical { get { return attribute.ToLowerInvariant() + "\u001f" + kind + "\u001f" + before + "\u001f" + after; } }
    }

    // What the operator confirmed. Nothing in it can change after the confirmation screen.
    public sealed class InterventionPlan
    {
        private readonly string id;
        private readonly string operation;
        private readonly SelectionIdentity target;
        private readonly string server;
        private readonly string account;
        private readonly ReadOnlyCollection<PlanChange> changes;
        private readonly ReadOnlyCollection<string> effects;
        private readonly DateTime createdUtc;
        private readonly string fingerprint;
        private readonly bool simulation;

        public InterventionPlan(string operation, SelectionIdentity target, string server, string account, IEnumerable<PlanChange> changes, IEnumerable<string> effects, bool simulation)
        {
            if (string.IsNullOrWhiteSpace(operation)) throw new ArgumentException("Operation requise.", "operation");
            if (target == null) throw new ArgumentNullException("target");
            this.id = System.Guid.NewGuid().ToString("N");
            this.operation = operation.Trim();
            this.target = target;
            this.server = server ?? string.Empty;
            this.account = account ?? string.Empty;
            List<PlanChange> changeList = new List<PlanChange>();
            if (changes != null) { foreach (PlanChange change in changes) { if (change != null) changeList.Add(change); } }
            List<string> effectList = new List<string>();
            if (effects != null) { foreach (string effect in effects) { if (!string.IsNullOrWhiteSpace(effect)) effectList.Add(effect); } }
            this.changes = new ReadOnlyCollection<PlanChange>(changeList);
            this.effects = new ReadOnlyCollection<string>(effectList);
            this.createdUtc = DateTime.UtcNow;
            this.simulation = simulation;
            this.fingerprint = ComputeFingerprint(this.operation, target, this.server, this.account, changeList);
        }

        public string Id { get { return id; } }
        public string Operation { get { return operation; } }
        public SelectionIdentity Target { get { return target; } }
        public string Server { get { return server; } }
        public string Account { get { return account; } }
        public ReadOnlyCollection<PlanChange> Changes { get { return changes; } }
        public ReadOnlyCollection<string> Effects { get { return effects; } }
        public DateTime CreatedUtc { get { return createdUtc; } }
        public string Fingerprint { get { return fingerprint; } }
        public bool Simulation { get { return simulation; } }

        // Same operation, same object, same server, same account and same ordered changes.
        public static string ComputeFingerprint(string operation, SelectionIdentity target, string server, string account, IEnumerable<PlanChange> changes)
        {
            StringBuilder text = new StringBuilder();
            text.Append(operation ?? string.Empty).Append('\u001e');
            text.Append(target == null ? string.Empty : target.Key).Append('\u001e');
            text.Append(target == null ? string.Empty : target.Type.ToLowerInvariant()).Append('\u001e');
            text.Append((server ?? string.Empty).ToLowerInvariant()).Append('\u001e');
            text.Append((account ?? string.Empty).ToLowerInvariant()).Append('\u001e');
            if (changes != null) { foreach (PlanChange change in changes) { if (change != null) text.Append(change.Canonical).Append('\u001e'); } }
            using (SHA256 sha = SHA256.Create())
            {
                byte[] hash = sha.ComputeHash(Encoding.UTF8.GetBytes(text.ToString()));
                StringBuilder hex = new StringBuilder(hash.Length * 2);
                foreach (byte b in hash) hex.Append(b.ToString("X2"));
                return hex.ToString();
            }
        }
    }

    // DS-18: the Windows title bar follows the theme of Domenia (DWMWA_USE_IMMERSIVE_DARK_MODE). Attribute 20 is the
    // documented value since Windows 10 20H1 and on Windows 11; Windows 10 1809 to 1909 used 19. A Windows without
    // that attribute refuses both: the bar keeps the system colours and nothing else changes. No window state is read.
    public static class WindowFrame
    {
        [DllImport("dwmapi.dll", PreserveSig = true)]
        private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);

        public static bool SetDarkTitleBar(IntPtr hwnd, bool dark)
        {
            if (hwnd == IntPtr.Zero) return false;
            int value = dark ? 1 : 0;
            try
            {
                if (DwmSetWindowAttribute(hwnd, 20, ref value, sizeof(int)) == 0) return true;
                return DwmSetWindowAttribute(hwnd, 19, ref value, sizeof(int)) == 0;
            }
            catch (DllNotFoundException) { return false; }
            catch (EntryPointNotFoundException) { return false; }
        }
    }
}
