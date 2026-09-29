namespace MacConnectViewer.Services;

public static class ViewerLog
{
    private const long MaxBytes = 2_000_000;
    private static readonly object Gate = new();

    public static string FilePath { get; set; } = System.IO.Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "MacConnect",
        "viewer.log");

    public static void Write(string message)
    {
        var line = $"{DateTime.Now:yyyy-MM-dd HH:mm:ss} {message}";
        System.Diagnostics.Debug.WriteLine(line);
        lock (Gate)
        {
            try
            {
                var directory = System.IO.Path.GetDirectoryName(FilePath);
                if (!string.IsNullOrEmpty(directory))
                {
                    Directory.CreateDirectory(directory);
                }

                var info = new FileInfo(FilePath);
                if (info.Exists && info.Length > MaxBytes)
                {
                    File.Move(FilePath, FilePath + ".old", overwrite: true);
                }

                File.AppendAllText(FilePath, line + Environment.NewLine);
            }
            catch
            {
                // Logging must not take down the viewer.
            }
        }
    }
}
