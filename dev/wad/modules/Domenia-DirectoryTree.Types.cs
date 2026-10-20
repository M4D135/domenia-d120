// Domenia - directory tree typed data + virtualizing panel (boulot D120, point 8).
// C# 5 only (Add-Type of Windows PowerShell 5.1). No modern C# syntax, no control stored in data.
// The DTO replaces TreeViewItem-as-data: the data is a plain observable object; WPF generated
// TreeViewItem containers carry the visual state (TemplateBinding) and are recycled by WPF.
using System;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace Domenia.Tree
{
    public class DomeniaTreeItem : INotifyPropertyChanged
    {
        private string _header = string.Empty;
        private object _tag;
        private string _favoriteStatus = string.Empty;
        private bool _isExpanded;
        private bool _isSelected;
        private bool _isEnabled = true;
        private Visibility _visibility = Visibility.Visible;
        private object _toolTip;
        private DomeniaTreeItem _parent;
        private object _childrenView;

        public event PropertyChangedEventHandler PropertyChanged;

        private void OnPropertyChanged(string name)
        {
            PropertyChangedEventHandler handler = PropertyChanged;
            if (handler != null) { handler(this, new PropertyChangedEventArgs(name)); }
        }

        public DomeniaTreeItem()
        {
            Items = new ObservableCollection<object>();
        }

        public string Header
        {
            get { return _header; }
            set { _header = value; OnPropertyChanged("Header"); }
        }

        // Tag stays the opaque PSCustomObject written by PowerShell (Name, DN, Kind, Loaded, RenderId, Loading, LoadingAt, DirectoryReadId).
        public object Tag
        {
            get { return _tag; }
            set { _tag = value; OnPropertyChanged("Tag"); }
        }

        public ObservableCollection<object> Items { get; private set; }

        public DomeniaTreeItem Parent
        {
            get { return _parent; }
            set { _parent = value; OnPropertyChanged("Parent"); }
        }

        // 'Favori' / '' - the star of the header template binds this, so it stays correct after recycling.
        public string FavoriteStatus
        {
            get { return _favoriteStatus; }
            set { _favoriteStatus = value; OnPropertyChanged("FavoriteStatus"); }
        }

        public bool IsExpanded
        {
            get { return _isExpanded; }
            set { _isExpanded = value; OnPropertyChanged("IsExpanded"); }
        }

        public bool IsSelected
        {
            get { return _isSelected; }
            set { _isSelected = value; OnPropertyChanged("IsSelected"); }
        }

        public bool IsEnabled
        {
            get { return _isEnabled; }
            set { _isEnabled = value; OnPropertyChanged("IsEnabled"); }
        }

        public Visibility Visibility
        {
            get { return _visibility; }
            set { _visibility = value; OnPropertyChanged("Visibility"); OnPropertyChanged("ChildrenView"); }
        }

        public object ToolTip
        {
            get { return _toolTip; }
            set { _toolTip = value; OnPropertyChanged("ToolTip"); }
        }

        // Optional per-node filtered child view (OU filter). Null lets WPF bind the raw Items collection.
        public object ChildrenView
        {
            get { return _childrenView; }
            set { _childrenView = value; OnPropertyChanged("ChildrenView"); }
        }

        public string Dn
        {
            get
            {
                object value = null;
                if (_tag != null)
                {
                    System.Reflection.PropertyInfo property = _tag.GetType().GetProperty("DN");
                    if (property != null) { value = property.GetValue(_tag, null); }
                }
                return value == null ? string.Empty : Convert.ToString(value);
            }
        }

        public string Kind
        {
            get
            {
                object value = null;
                if (_tag != null)
                {
                    System.Reflection.PropertyInfo property = _tag.GetType().GetProperty("Kind");
                    if (property != null) { value = property.GetValue(_tag, null); }
                }
                return value == null ? string.Empty : Convert.ToString(value);
            }
        }

        public bool Loaded
        {
            get
            {
                if (_tag == null) { return false; }
                System.Reflection.PropertyInfo property = _tag.GetType().GetProperty("Loaded");
                if (property == null) { return false; }
                object value = property.GetValue(_tag, null);
                return value is bool && (bool)value;
            }
        }

        public bool Loading
        {
            get
            {
                if (_tag == null) { return false; }
                System.Reflection.PropertyInfo property = _tag.GetType().GetProperty("Loading");
                if (property == null) { return false; }
                object value = property.GetValue(_tag, null);
                return value is bool && (bool)value;
            }
        }

        public string RenderId
        {
            get
            {
                if (_tag == null) { return string.Empty; }
                System.Reflection.PropertyInfo property = _tag.GetType().GetProperty("RenderId");
                if (property == null) { return string.Empty; }
                object value = property.GetValue(_tag, null);
                return value == null ? string.Empty : Convert.ToString(value);
            }
        }

        public string DirectoryReadId
        {
            get
            {
                if (_tag == null) { return string.Empty; }
                System.Reflection.PropertyInfo property = _tag.GetType().GetProperty("DirectoryReadId");
                if (property == null) { return string.Empty; }
                object value = property.GetValue(_tag, null);
                return value == null ? string.Empty : Convert.ToString(value);
            }
        }
    }

    //_PROGRAM: derived panel so PowerShell can call BringIndexIntoView per index of the reveal path,
    // without generating every container of the branch (no exhaustive enumeration).
    public class DomeniaVirtualizingStackPanel : VirtualizingStackPanel
    {
        public void Reveal(int childIndex)
        {
            BringIndexIntoView(childIndex);
        }
    }

    public static class DomeniaTreeSupport
    {
        public static TreeViewItem ContainerFromItem(ItemsControl owner, object item)
        {
            if (owner == null || item == null) { return null; }
            return owner.ItemContainerGenerator.ContainerFromItem(item) as TreeViewItem;
        }

        public static DomeniaVirtualizingStackPanel FindPanel(ItemsControl owner)
        {
            if (owner == null) { return null; }
            return FindPanelFromVisual(owner) as DomeniaVirtualizingStackPanel;
        }

        private static DependencyObject FindPanelFromVisual(DependencyObject root)
        {
            DomeniaVirtualizingStackPanel panel = root as DomeniaVirtualizingStackPanel;
            if (panel != null) { return panel; }
            int count = VisualTreeHelper.GetChildrenCount(root);
            for (int index = 0; index < count; index++)
            {
                DependencyObject child = VisualTreeHelper.GetChild(root, index);
                DependencyObject found = FindPanelFromVisual(child);
                if (found != null) { return found; }
            }
            return null;
        }
    }
}
