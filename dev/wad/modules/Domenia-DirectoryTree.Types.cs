// C# 5: observable directory data and access to the protected WPF panel API.
// Data nodes retain data/view state only; generated TreeViewItem containers are never retained here.
using System;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Media;
namespace Domenia.Tree {
    public sealed class DomeniaTreeItem : INotifyPropertyChanged {
        private string header = String.Empty, favoriteStatus = String.Empty;
        private object tag, toolTip;
        private bool expanded, selected, enabled = true;
        private Visibility visibility = Visibility.Visible;
        private ListCollectionView childrenView;
        public event PropertyChangedEventHandler PropertyChanged;
        public DomeniaTreeItem() {
            Items = new DomeniaTreeChildren(this);
        }
        private void Raise(string property) {
            PropertyChangedEventHandler handler = PropertyChanged;
            if (handler != null) handler(this, new PropertyChangedEventArgs(property));
        }
        public string Header { get { return header; } set { if (header == value) return; header = value; Raise("Header"); } }
        // PowerShell owns the opaque metadata (Loaded, Loading, RenderId, DirectoryReadId).
        public object Tag { get { return tag; } set { if (Object.ReferenceEquals(tag, value)) return; tag = value; Raise("Tag"); } }
        public DomeniaTreeChildren Items { get; private set; }
        public ListCollectionView ChildrenView {
            get {
                if (childrenView == null) {
                    childrenView = new ListCollectionView(Items);
                    childrenView.Filter = delegate(object value) {
                        DomeniaTreeItem child = value as DomeniaTreeItem;
                        return child == null || child.Visibility == Visibility.Visible;
                    };
                }
                return childrenView;
            }
        }
        public void RefreshChildrenView() { if (childrenView != null) childrenView.Refresh(); }
        public DomeniaTreeItem Parent { get; set; }
        public string FavoriteStatus { get { return favoriteStatus; } set { if (favoriteStatus == value) return; favoriteStatus = value; Raise("FavoriteStatus"); } }
        // One read per expansion gesture; remains true when a container is recycled/recreated.
        public bool ExpansionReadHandled { get; set; }
        // Remains attached to the logical selection until it is explicitly replaced.
        public bool ProgrammaticSelection { get; set; }
        public bool IsExpanded {
            get { return expanded; }
            set { if (expanded == value) return; expanded = value; if (!value) ExpansionReadHandled = false; Raise("IsExpanded"); }
        }
        public bool IsSelected {
            get { return selected; }
            set { if (selected == value) return; selected = value; if (!value) ProgrammaticSelection = false; Raise("IsSelected"); }
        }
        public bool IsEnabled { get { return enabled; } set { if (enabled == value) return; enabled = value; Raise("IsEnabled"); } }
        public Visibility Visibility { get { return visibility; } set { if (visibility == value) return; visibility = value; Raise("Visibility"); } }
        public object ToolTip { get { return toolTip; } set { if (Object.Equals(toolTip, value)) return; toolTip = value; Raise("ToolTip"); } }
    }
    public sealed class DomeniaTreeChildren : ObservableCollection<object> {
        private readonly DomeniaTreeItem owner;
        internal DomeniaTreeChildren(DomeniaTreeItem parent) { owner = parent; }
        private void Attach(object value) { DomeniaTreeItem node = value as DomeniaTreeItem; if (node != null) node.Parent = owner; }
        private void Detach(object value) { DomeniaTreeItem node = value as DomeniaTreeItem; if (node != null && Object.ReferenceEquals(node.Parent, owner)) node.Parent = null; }
        protected override void InsertItem(int index, object item) { Attach(item); base.InsertItem(index, item); }
        protected override void SetItem(int index, object item) { Detach(this[index]); Attach(item); base.SetItem(index, item); }
        protected override void RemoveItem(int index) { Detach(this[index]); base.RemoveItem(index); }
        protected override void ClearItems() { foreach (object item in this) Detach(item); base.ClearItems(); }
    }
    public class DomeniaVirtualizingStackPanel : VirtualizingStackPanel {
        public void Reveal(int index) { BringIndexIntoView(index); }
    }
    public static class DomeniaTreeSupport {
        public static TreeViewItem ContainerFromItem(ItemsControl owner, object item) {
            return owner == null || item == null ? null : owner.ItemContainerGenerator.ContainerFromItem(item) as TreeViewItem;
        }
        public static DomeniaVirtualizingStackPanel FindPanel(ItemsControl owner) {
            return owner == null ? null : FindPanelFromVisual(owner, owner);
        }
        private static DomeniaVirtualizingStackPanel FindPanelFromVisual(DependencyObject root, ItemsControl owner) {
            DomeniaVirtualizingStackPanel panel = root as DomeniaVirtualizingStackPanel;
            if (panel != null && Object.ReferenceEquals(ItemsControl.GetItemsOwner(panel), owner)) return panel;
            int count = VisualTreeHelper.GetChildrenCount(root);
            for (int i = 0; i < count; i++) {
                DomeniaVirtualizingStackPanel found = FindPanelFromVisual(VisualTreeHelper.GetChild(root, i), owner);
                if (found != null) return found;
            }
            return null;
        }
    }
}
