using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;

internal static class FaceSwapStudioUpdater
{
    private const string AppName = "FaceSwap Studio";
    private static string _logPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "FaceSwap Studio",
        "updates",
        "updater.log"
    );

    [STAThread]
    private static int Main(string[] args)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_logPath));
            Dictionary<string, string> options = ParseArgs(args);
            string root = RequireOption(options, "root");
            string package = RequireOption(options, "package");
            string restart = RequireOption(options, "restart");

            root = Path.GetFullPath(root);
            package = Path.GetFullPath(package);
            restart = Path.GetFullPath(restart);

            Log("Updater started.");
            Log("Root: " + root);
            Log("Package: " + package);

            if (!Directory.Exists(root))
            {
                throw new DirectoryNotFoundException(root);
            }
            if (!File.Exists(package))
            {
                throw new FileNotFoundException("Delta package not found.", package);
            }

            string workRoot = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "FaceSwap Studio",
                "updates",
                "apply-" + DateTime.Now.ToString("yyyyMMdd-HHmmss")
            );
            string extractRoot = Path.Combine(workRoot, "extract");
            string backupRoot = Path.Combine(workRoot, "backup");
            Directory.CreateDirectory(extractRoot);
            Directory.CreateDirectory(backupRoot);

            try
            {
                StopAppProcesses(root);
                ZipFile.ExtractToDirectory(package, extractRoot);

                string manifestPath = Path.Combine(extractRoot, "delta-manifest.json");
                if (!File.Exists(manifestPath))
                {
                    throw new FileNotFoundException("delta-manifest.json was not found in package.");
                }

                Dictionary<string, object> manifest = ReadJsonObject(manifestPath);
                string fromVersion = ReadManifestString(manifest, "from_version");
                string toVersion = ReadManifestString(manifest, "to_version");
                ValidateBaseVersion(root, fromVersion);
                List<DeltaFile> files = ReadDeltaFiles(manifest);
                List<string> deletedFiles = ReadDeletedFiles(manifest);

                ValidateExtractedFiles(extractRoot, files);
                ApplyDelta(root, extractRoot, backupRoot, files, deletedFiles);
                RunRuntimeRepair(root);
                ValidateTargetVersion(root, toVersion);
                RestartLauncher(restart, root);
                Log("Update applied successfully.");
                return 0;
            }
            catch (Exception)
            {
                Log("Apply failed; attempting rollback.");
                Rollback(root, backupRoot);
                throw;
            }
        }
        catch (Exception exception)
        {
            Log("Fatal error: " + exception);
            MessageBox.Show(
                "更新失败：\n\n" + exception.Message + "\n\n日志：\n" + _logPath,
                AppName,
                MessageBoxButtons.OK,
                MessageBoxIcon.Error
            );
            return 1;
        }
    }

    private static Dictionary<string, string> ParseArgs(string[] args)
    {
        var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        for (int index = 0; index < args.Length; index++)
        {
            string arg = args[index];
            if (!arg.StartsWith("--", StringComparison.Ordinal))
            {
                continue;
            }
            string key = arg.Substring(2);
            if (index + 1 >= args.Length)
            {
                throw new ArgumentException("Missing value for " + arg);
            }
            result[key] = args[++index];
        }
        return result;
    }

    private static string RequireOption(Dictionary<string, string> options, string key)
    {
        string value;
        if (!options.TryGetValue(key, out value) || string.IsNullOrWhiteSpace(value))
        {
            throw new ArgumentException("Missing required option --" + key);
        }
        return value;
    }

    private static Dictionary<string, object> ReadJsonObject(string path)
    {
        var serializer = new JavaScriptSerializer { MaxJsonLength = int.MaxValue };
        return serializer.Deserialize<Dictionary<string, object>>(File.ReadAllText(path, Encoding.UTF8));
    }

    private static List<DeltaFile> ReadDeltaFiles(Dictionary<string, object> manifest)
    {
        var result = new List<DeltaFile>();
        object filesValue;
        if (!manifest.TryGetValue("files", out filesValue))
        {
            return result;
        }

        foreach (object item in (IEnumerable)filesValue)
        {
            var file = (Dictionary<string, object>)item;
            result.Add(new DeltaFile
            {
                Path = Convert.ToString(file["path"]),
                Sha256 = Convert.ToString(file["sha256"]),
                Size = Convert.ToInt64(file["size"])
            });
        }
        return result;
    }

    private static string ReadManifestString(Dictionary<string, object> manifest, string key)
    {
        object value;
        if (!manifest.TryGetValue(key, out value))
        {
            return string.Empty;
        }
        return Convert.ToString(value) ?? string.Empty;
    }

    private static void ValidateBaseVersion(string root, string expectedVersion)
    {
        if (string.IsNullOrWhiteSpace(expectedVersion))
        {
            return;
        }

        string actualVersion = ReadInstalledVersion(root);
        if (!actualVersion.Equals(expectedVersion, StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidDataException(
                "This update package expects version " + expectedVersion + ", but installed version is " + actualVersion + "."
            );
        }
    }

    private static void ValidateTargetVersion(string root, string expectedVersion)
    {
        if (string.IsNullOrWhiteSpace(expectedVersion))
        {
            return;
        }

        string actualVersion = ReadInstalledVersion(root);
        if (!actualVersion.Equals(expectedVersion, StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidDataException(
                "Updated version mismatch. Expected " + expectedVersion + ", got " + actualVersion + "."
            );
        }
    }

    private static string ReadInstalledVersion(string root)
    {
        string versionPath = Path.Combine(root, "VERSION");
        if (!File.Exists(versionPath))
        {
            return "0.0.0";
        }
        string version = File.ReadAllText(versionPath, Encoding.UTF8).Trim();
        return string.IsNullOrWhiteSpace(version) ? "0.0.0" : version;
    }

    private static List<string> ReadDeletedFiles(Dictionary<string, object> manifest)
    {
        var result = new List<string>();
        object deletedValue;
        if (!manifest.TryGetValue("deleted_files", out deletedValue))
        {
            return result;
        }
        foreach (object item in (IEnumerable)deletedValue)
        {
            result.Add(Convert.ToString(item));
        }
        return result;
    }

    private static void ValidateExtractedFiles(string extractRoot, List<DeltaFile> files)
    {
        foreach (DeltaFile file in files)
        {
            string source = SafeJoin(Path.Combine(extractRoot, "files"), file.Path);
            if (!File.Exists(source))
            {
                throw new FileNotFoundException("Delta file missing: " + file.Path);
            }
            FileInfo info = new FileInfo(source);
            if (info.Length != file.Size)
            {
                throw new InvalidDataException("Size mismatch: " + file.Path);
            }
            string actualHash = ComputeSha256(source);
            if (!actualHash.Equals(file.Sha256, StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidDataException("SHA256 mismatch: " + file.Path);
            }
        }
    }

    private static void ApplyDelta(string root, string extractRoot, string backupRoot, List<DeltaFile> files, List<string> deletedFiles)
    {
        var backupIndex = new List<string>();
        var createdIndex = new List<string>();

        foreach (DeltaFile file in files)
        {
            string target = SafeJoin(root, file.Path);
            if (File.Exists(target))
            {
                BackupFile(root, backupRoot, target, backupIndex);
            }
            else
            {
                createdIndex.Add(file.Path);
            }
        }

        foreach (string relativePath in deletedFiles)
        {
            string target = SafeJoin(root, relativePath);
            if (File.Exists(target))
            {
                BackupFile(root, backupRoot, target, backupIndex);
            }
        }

        File.WriteAllLines(Path.Combine(backupRoot, "backup-files.txt"), backupIndex.ToArray(), Encoding.UTF8);
        File.WriteAllLines(Path.Combine(backupRoot, "created-files.txt"), createdIndex.ToArray(), Encoding.UTF8);

        foreach (DeltaFile file in files)
        {
            string source = SafeJoin(Path.Combine(extractRoot, "files"), file.Path);
            string target = SafeJoin(root, file.Path);
            Directory.CreateDirectory(Path.GetDirectoryName(target));
            File.Copy(source, target, true);
        }

        foreach (string relativePath in deletedFiles)
        {
            string target = SafeJoin(root, relativePath);
            if (File.Exists(target))
            {
                File.Delete(target);
            }
        }

        foreach (DeltaFile file in files)
        {
            string target = SafeJoin(root, file.Path);
            string actualHash = ComputeSha256(target);
            if (!actualHash.Equals(file.Sha256, StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidDataException("Post-copy SHA256 mismatch: " + file.Path);
            }
        }
    }

    private static void BackupFile(string root, string backupRoot, string target, List<string> backupIndex)
    {
        string relative = MakeRelativePath(root, target);
        string backupPath = SafeJoin(backupRoot, relative);
        Directory.CreateDirectory(Path.GetDirectoryName(backupPath));
        File.Copy(target, backupPath, true);
        backupIndex.Add(relative.Replace('\\', '/'));
    }

    private static void Rollback(string root, string backupRoot)
    {
        try
        {
            string createdIndexPath = Path.Combine(backupRoot, "created-files.txt");
            if (File.Exists(createdIndexPath))
            {
                foreach (string relative in File.ReadAllLines(createdIndexPath, Encoding.UTF8))
                {
                    if (string.IsNullOrWhiteSpace(relative))
                    {
                        continue;
                    }
                    string target = SafeJoin(root, relative);
                    if (File.Exists(target))
                    {
                        File.Delete(target);
                    }
                }
            }

            string backupIndexPath = Path.Combine(backupRoot, "backup-files.txt");
            if (File.Exists(backupIndexPath))
            {
                foreach (string relative in File.ReadAllLines(backupIndexPath, Encoding.UTF8))
                {
                    if (string.IsNullOrWhiteSpace(relative))
                    {
                        continue;
                    }
                    string backup = SafeJoin(backupRoot, relative);
                    string target = SafeJoin(root, relative);
                    if (File.Exists(backup))
                    {
                        Directory.CreateDirectory(Path.GetDirectoryName(target));
                        File.Copy(backup, target, true);
                    }
                }
            }
        }
        catch (Exception exception)
        {
            Log("Rollback failed: " + exception);
        }
    }

    private static void StopAppProcesses(string root)
    {
        int currentPid = Process.GetCurrentProcess().Id;
        string normalizedRoot = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar) + Path.DirectorySeparatorChar;

        foreach (Process process in Process.GetProcesses())
        {
            if (process.Id == currentPid)
            {
                continue;
            }

            string path = null;
            try
            {
                path = process.MainModule.FileName;
            }
            catch
            {
                continue;
            }

            if (string.IsNullOrEmpty(path))
            {
                continue;
            }

            string normalizedPath = Path.GetFullPath(path);
            if (!normalizedPath.StartsWith(normalizedRoot, StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            try
            {
                Log("Stopping process " + process.Id + ": " + normalizedPath);
                process.Kill();
                process.WaitForExit(10000);
            }
            catch (Exception exception)
            {
                Log("Unable to stop process " + process.Id + ": " + exception.Message);
            }
        }

        Thread.Sleep(1000);
    }

    private static void RunRuntimeRepair(string root)
    {
        string repairScript = Path.Combine(root, "scripts", "repair_runtime.ps1");
        if (!File.Exists(repairScript))
        {
            Log("Runtime repair script not found; skipping.");
            return;
        }

        var startInfo = new ProcessStartInfo
        {
            FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe"),
            Arguments = "-NoProfile -ExecutionPolicy Bypass -File " + Quote(repairScript) + " -Root " + Quote(root),
            UseShellExecute = false,
            CreateNoWindow = true,
            WindowStyle = ProcessWindowStyle.Hidden
        };

        using (Process process = Process.Start(startInfo))
        {
            process.WaitForExit();
            if (process.ExitCode != 0)
            {
                throw new InvalidOperationException("Runtime repair failed with exit code " + process.ExitCode);
            }
        }
    }

    private static void RestartLauncher(string restart, string root)
    {
        if (!File.Exists(restart))
        {
            Log("Restart executable not found: " + restart);
            return;
        }

        var startInfo = new ProcessStartInfo
        {
            FileName = restart,
            WorkingDirectory = root,
            UseShellExecute = true
        };
        Process.Start(startInfo);
    }

    private static string SafeJoin(string root, string relativePath)
    {
        string normalized = relativePath.Replace('/', Path.DirectorySeparatorChar).Replace('\\', Path.DirectorySeparatorChar);
        if (Path.IsPathRooted(normalized) || normalized.Contains(".." + Path.DirectorySeparatorChar) || normalized == "..")
        {
            throw new InvalidDataException("Unsafe path in update package: " + relativePath);
        }

        string full = Path.GetFullPath(Path.Combine(root, normalized));
        string normalizedRoot = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar) + Path.DirectorySeparatorChar;
        if (!full.StartsWith(normalizedRoot, StringComparison.OrdinalIgnoreCase) && !full.Equals(normalizedRoot.TrimEnd(Path.DirectorySeparatorChar), StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidDataException("Path escapes update root: " + relativePath);
        }
        return full;
    }

    private static string MakeRelativePath(string root, string path)
    {
        Uri rootUri = new Uri(Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar) + Path.DirectorySeparatorChar);
        Uri pathUri = new Uri(Path.GetFullPath(path));
        return Uri.UnescapeDataString(rootUri.MakeRelativeUri(pathUri).ToString()).Replace('/', Path.DirectorySeparatorChar);
    }

    private static string ComputeSha256(string path)
    {
        using (SHA256 sha256 = SHA256.Create())
        using (FileStream stream = File.OpenRead(path))
        {
            byte[] hash = sha256.ComputeHash(stream);
            var builder = new StringBuilder(hash.Length * 2);
            foreach (byte value in hash)
            {
                builder.Append(value.ToString("X2"));
            }
            return builder.ToString();
        }
    }

    private static void Log(string message)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_logPath));
            File.AppendAllText(_logPath, "[" + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "] " + message + Environment.NewLine, Encoding.UTF8);
        }
        catch
        {
        }
    }

    private static string Quote(string value)
    {
        return "\"" + value.Replace("\"", "\\\"") + "\"";
    }

    private sealed class DeltaFile
    {
        public string Path;
        public string Sha256;
        public long Size;
    }
}
