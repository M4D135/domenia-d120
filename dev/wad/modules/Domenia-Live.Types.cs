// DOMENIA live results: notifications are raised only on the WPF thread.
// No credentials, LDAP objects or WPF controls are stored in these rows.
using System;
using System.Collections.Generic;
using System.ComponentModel;
namespace Domenia.Live {
    public sealed class ResultRow : INotifyPropertyChanged {
        private readonly Dictionary<string,string> values = new Dictionary<string,string>(StringComparer.Ordinal);
        public event PropertyChangedEventHandler PropertyChanged;
        private string Read(string name) { string v; return values.TryGetValue(name, out v) ? v : String.Empty; }
        public void Set(string name, string value) {
            if (!Allowed.ContainsKey(name)) throw new ArgumentException("Unknown row field.", "name");
            value = value ?? String.Empty;
            if (String.Equals(Read(name), value, StringComparison.Ordinal)) return;
            values[name] = value;
            var handler = PropertyChanged;
            if (handler != null) handler(this, new PropertyChangedEventArgs(name));
        }
        // Dictionary (mscorlib), not HashSet (System.Core): Add-Type of Windows PowerShell 5.1 does not reference System.Core.
        private static readonly Dictionary<string,bool> Allowed = new Dictionary<string,bool>(StringComparer.Ordinal) {{"Type",true},{"Name",true},{"Login",true},{"UPN",true},{"Mail",true},{"Description",true},{"Changed",true},{"DN",true},{"State",true},{"OS",true},{"LastLogon",true},{"Guid",true},{"Association",true},{"LinkSource",true},{"LinkConfidence",true},{"Presence",true},{"PresenceDetail",true},{"SessionDisplay",true},{"SessionState",true},{"SessionSource",true},{"SessionChecked",true},{"SessionObserved",true},{"SessionDetail",true},{"DirectoryState",true},{"DirectoryChecked",true},{"Rank",true},{"Admin",true},{"PresenceState",true},{"PresenceAge",true},{"PresenceCached",true},{"ProbePending",true},{"DirectoryFresh",true}};
        public string Type { get { return Read("Type"); } set { Set("Type", value); } }
        public string Name { get { return Read("Name"); } set { Set("Name", value); } }
        public string Login { get { return Read("Login"); } set { Set("Login", value); } }
        public string UPN { get { return Read("UPN"); } set { Set("UPN", value); } }
        public string Mail { get { return Read("Mail"); } set { Set("Mail", value); } }
        public string Description { get { return Read("Description"); } set { Set("Description", value); } }
        public string Changed { get { return Read("Changed"); } set { Set("Changed", value); } }
        public string DN { get { return Read("DN"); } set { Set("DN", value); } }
        public string State { get { return Read("State"); } set { Set("State", value); } }
        public string OS { get { return Read("OS"); } set { Set("OS", value); } }
        public string LastLogon { get { return Read("LastLogon"); } set { Set("LastLogon", value); } }
        public string Guid { get { return Read("Guid"); } set { Set("Guid", value); } }
        public string Association { get { return Read("Association"); } set { Set("Association", value); } }
        public string LinkSource { get { return Read("LinkSource"); } set { Set("LinkSource", value); } }
        public string LinkConfidence { get { return Read("LinkConfidence"); } set { Set("LinkConfidence", value); } }
        public string PresenceDetail { get { return Read("PresenceDetail"); } set { Set("PresenceDetail", value); } }
        public string Presence { get { return Read("Presence"); } set { Set("Presence", value); } }
        public string SessionDisplay { get { return Read("SessionDisplay"); } set { Set("SessionDisplay", value); } }
        public string SessionState { get { return Read("SessionState"); } set { Set("SessionState", value); } }
        public string SessionSource { get { return Read("SessionSource"); } set { Set("SessionSource", value); } }
        public string SessionChecked { get { return Read("SessionChecked"); } set { Set("SessionChecked", value); } }
        public string SessionObserved { get { return Read("SessionObserved"); } set { Set("SessionObserved", value); } }
        public string SessionDetail { get { return Read("SessionDetail"); } set { Set("SessionDetail", value); } }
        public string DirectoryState { get { return Read("DirectoryState"); } set { Set("DirectoryState", value); } }
        public string DirectoryChecked { get { return Read("DirectoryChecked"); } set { Set("DirectoryChecked", value); } }
        // D034: relevance rank (0 = exact identifier) and administration-account marker; display only.
        public string Rank { get { return Read("Rank"); } set { Set("Rank", value); } }
        public string Admin { get { return Read("Admin"); } set { Set("Admin", value); } }
        // FI-16 / DS-15: presence state key (Online, NoReply, Error, Pending, Unknown, None), discreet age of the measure,
        // '1' when the value comes from an earlier session, '1' while a list survey still has to read the row (UX-12),
        // and the freshness key of the directory values (Verified, Cached, Warning). Read by the pill, the colour and the
        // presence filter; never by a write or a remote action.
        public string PresenceState { get { return Read("PresenceState"); } set { Set("PresenceState", value); } }
        public string PresenceAge { get { return Read("PresenceAge"); } set { Set("PresenceAge", value); } }
        public string PresenceCached { get { return Read("PresenceCached"); } set { Set("PresenceCached", value); } }
        public string ProbePending { get { return Read("ProbePending"); } set { Set("ProbePending", value); } }
        public string DirectoryFresh { get { return Read("DirectoryFresh"); } set { Set("DirectoryFresh", value); } }
    }
    // UX-32 / PF-12: one row of the operations panel, updated in place (state, duration) instead of rebuilding the grid,
    // so that the selection, the scroll position and the focus stay where the operator left them. W13 (point 118): the
    // rows of the "last operations" grid use it too, with their dominant step (Phase) and their trace reference.
    public sealed class OperationRow : INotifyPropertyChanged {
        private string id = String.Empty, name = String.Empty, kind = String.Empty, state = String.Empty, duration = String.Empty, detail = String.Empty, phase = String.Empty, reference = String.Empty;
        private bool canCancel, detached;
        public event PropertyChangedEventHandler PropertyChanged;
        private void Raise(string property) { var handler = PropertyChanged; if (handler != null) handler(this, new PropertyChangedEventArgs(property)); }
        private bool Change(ref string field, string value, string property) {
            value = value ?? String.Empty;
            if (String.Equals(field, value, StringComparison.Ordinal)) return false;
            field = value; Raise(property); return true;
        }
        public string Id { get { return id; } set { Change(ref id, value, "Id"); } }
        public string Name { get { return name; } set { Change(ref name, value, "Name"); } }
        public string Kind { get { return kind; } set { Change(ref kind, value, "Kind"); } }
        public string State { get { return state; } set { Change(ref state, value, "State"); } }
        public string Duration { get { return duration; } set { Change(ref duration, value, "Duration"); } }
        public string Detail { get { return detail; } set { Change(ref detail, value, "Detail"); } }
        public string Phase { get { return phase; } set { Change(ref phase, value, "Phase"); } }
        public string Reference { get { return reference; } set { Change(ref reference, value, "Reference"); } }
        public bool CanCancel { get { return canCancel; } set { if (canCancel == value) return; canCancel = value; Raise("CanCancel"); } }
        public bool Detached { get { return detached; } set { if (detached == value) return; detached = value; Raise("Detached"); } }
    }
}
