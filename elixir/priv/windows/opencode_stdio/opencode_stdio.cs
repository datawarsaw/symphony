using System;
using System.Diagnostics;
using System.IO;
using System.Text;

// Launches a child with stdin already at EOF and stderr diverted to a file.
// The host stdin stays open so a Job wrapper can still observe Port.close as
// a stop signal. The child itself does not share that pipe.
static class OpenCodeStdioHost
{
    static int Main(string[] args)
    {
        string stderrPath = null;
        int i = 0;
        for (; i < args.Length; i++)
        {
            string arg = args[i];
            if (arg == "--stderr" && i + 1 < args.Length)
            {
                stderrPath = args[++i];
                continue;
            }
            if (arg == "--")
            {
                i++;
                break;
            }
            return Fail(stderrPath, "unknown option: " + arg);
        }

        if (i >= args.Length)
            return Fail(stderrPath, "missing child executable");

        string child = args[i++];
        var rest = new string[args.Length - i];
        Array.Copy(args, i, rest, 0, rest.Length);

        if (!Path.IsPathRooted(child))
            return Fail(stderrPath, "child executable must be absolute: " + child);

        try
        {
            var psi = new ProcessStartInfo();
            psi.FileName = child;
            psi.Arguments = JoinArguments(rest);
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.RedirectStandardInput = true;
            psi.RedirectStandardOutput = false;
            psi.RedirectStandardError = true;

            Process process = Process.Start(psi);
            process.StandardInput.Close();
            string stderr = process.StandardError.ReadToEnd();
            process.WaitForExit();
            WriteStderr(stderrPath, stderr ?? "");
            return process.ExitCode;
        }
        catch (Exception ex)
        {
            return Fail(stderrPath, "spawn failed: " + ex.Message);
        }
    }

    static int Fail(string stderrPath, string message)
    {
        WriteStderr(stderrPath, message + Environment.NewLine);
        return 2;
    }

    static void WriteStderr(string stderrPath, string text)
    {
        try
        {
            if (string.IsNullOrEmpty(stderrPath)) return;
            string dir = Path.GetDirectoryName(stderrPath);
            if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
            File.WriteAllText(stderrPath, text ?? "", new UTF8Encoding(false));
        }
        catch
        {
        }
    }

    static string JoinArguments(string[] args)
    {
        var sb = new StringBuilder();
        for (int n = 0; n < args.Length; n++)
        {
            if (n > 0) sb.Append(' ');
            sb.Append(Quote(args[n] ?? ""));
        }
        return sb.ToString();
    }

    static string Quote(string arg)
    {
        if (arg.Length > 0 && arg.IndexOf(' ') < 0 && arg.IndexOf('\t') < 0 && arg.IndexOf('"') < 0)
            return arg;
        var sb = new StringBuilder();
        sb.Append('"');
        int backslashes = 0;
        for (int n = 0; n < arg.Length; n++)
        {
            char c = arg[n];
            if (c == '\\') { backslashes++; continue; }
            if (c == '"')
            {
                sb.Append('\\', backslashes * 2 + 1);
                sb.Append('"');
            }
            else
            {
                sb.Append('\\', backslashes);
                sb.Append(c);
            }
            backslashes = 0;
        }
        sb.Append('\\', backslashes * 2);
        sb.Append('"');
        return sb.ToString();
    }
}
