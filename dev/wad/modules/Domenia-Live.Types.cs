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
            if (!Allowed.Contains(name)) throw new ArgumentException("Unknown row field.", "name");
            value = value ?? String.Empty;
            if (String.Equals(Read(name), value, StringComparison.Ordinal)) return;
            values[name] = value;
            var handler = PropertyChanged;
            if (handler != null) handler(this, new PropertyChangedEventArgs(name));
        }
        private static readonly HashSet<string> Allowed = new HashSet<string>(StringComparer.Ordinal) {"Type","Name","Login","UPN","Mail","Description","Changed","DN","State","OS","LastLogon","Guid","Association","LinkSource","LinkConfidence","Presence","PresenceDetail","SessionDisplay","SessionState","SessionSource","SessionChecked","SessionObserved","SessionDetail","DirectoryState","DirectoryChecked","Rank","Admin"};
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
    }
}
