using System.Text.Json;

namespace MacConnectViewer.Services;

public sealed class AllowListStore
{
    private readonly string _path;
    private readonly HashSet<string> _names;

    public AllowListStore(string? path = null)
    {
        if (path is null)
        {
            var directory = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                "MacConnect");
            Directory.CreateDirectory(directory);
            path = Path.Combine(directory, "allowed.json");
        }

        _path = path;
        _names = Load();
    }

    public bool Allows(string macName)
    {
        lock (_names)
        {
            return _names.Contains(Normalize(macName));
        }
    }

    public void Remember(string macName)
    {
        lock (_names)
        {
            if (_names.Add(Normalize(macName)))
            {
                Save();
            }
        }
    }

    private HashSet<string> Load()
    {
        try
        {
            if (!File.Exists(_path))
            {
                return new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            }

            var names = JsonSerializer.Deserialize<List<string>>(File.ReadAllText(_path)) ?? [];
            return new HashSet<string>(names.Select(Normalize), StringComparer.OrdinalIgnoreCase);
        }
        catch (Exception ex)
        {
            ViewerLog.Write($"Could not read the allow list: {ex.Message}");
            return new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        }
    }

    private void Save()
    {
        var json = JsonSerializer.Serialize(_names.OrderBy(name => name).ToList(), new JsonSerializerOptions { WriteIndented = true });
        File.WriteAllText(_path, json);
    }

    private static string Normalize(string name) => name.Trim();
}
