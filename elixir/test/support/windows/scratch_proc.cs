// scratch_proc.exe — harmless scratch process-tree worker (MIC-223 test support).
// NEVER used against production Codex workers; tests only.
//
// Adapted from the MIC-223 PoC scratch helper. File-evidence model: writes
// <scratch>\<id>.started, appends a heartbeat every 250 ms to
// <scratch>\<id>.heartbeat, exits gracefully (code 0) when <scratch>\<id>.stop
// appears, self-exits after --lifetime seconds as a safety fallback.
//
// Options:
//   --id ID             unique run marker (also file prefix)
//   --scratch DIR       evidence directory (default: current directory)
//   --lifetime SEC      safety self-exit (default 25)
//   --exit-code N       exit code on lifetime expiry (default 0)
//   --spawn-chain a>b>c spawn child a, which spawns b, which spawns c
//   --chatty N          write N fixed-length lines to stdout first
//   --try-breakaway     attempt CreateProcess(CREATE_BREAKAWAY_FROM_JOB)
//   --stdin-exit        exit 0 as soon as stdin reaches EOF (cooperative
//                       Port.close reaction, like a real app-server)
//   --stop-file NAME    override stop-file name (shared signal across a tree)
//
// Build: %WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe /nologo /optimize+ /out:scratch_proc.exe scratch_proc.cs

using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

static class ScratchProc
{
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool CreateProcessW(string lpApplicationName, string lpCommandLine,
        IntPtr lpProcessAttributes, IntPtr lpThreadAttributes, bool bInheritHandles,
        uint dwCreationFlags, IntPtr lpEnvironment, string lpCurrentDirectory,
        ref STARTUPINFO lpStartupInfo, out PROCESS_INFORMATION lpProcessInformation);
    [DllImport("kernel32.dll")]
    static extern uint ResumeThread(IntPtr hThread);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CloseHandle(IntPtr h);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct STARTUPINFO
    {
        public int cb;
        public string lpReserved, lpDesktop, lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow, cbReserved2;
        public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct PROCESS_INFORMATION
    {
        public IntPtr hProcess, hThread;
        public int dwProcessId, dwThreadId;
    }

    static string Self()
    {
        return System.Diagnostics.Process.GetCurrentProcess().MainModule.FileName;
    }

    static void Spawn(string scratch, string id, string chain, int lifetime, int exitCode)
    {
        var si = new STARTUPINFO();
        si.cb = Marshal.SizeOf(typeof(STARTUPINFO));
        var sb = new StringBuilder("\"" + Self() + "\" --id " + id + " --scratch \"" + scratch
            + "\" --lifetime " + lifetime + " --exit-code " + exitCode);
        if (chain.Length > 0) sb.Append(" --spawn-chain " + chain);
        PROCESS_INFORMATION pi;
        if (!CreateProcessW(null, sb.ToString(), IntPtr.Zero, IntPtr.Zero, true, 0,
            IntPtr.Zero, null, ref si, out pi))
        {
            File.AppendAllText(Path.Combine(scratch, id + ".spawnfailed"),
                "err=" + Marshal.GetLastWin32Error() + Environment.NewLine);
            return;
        }
        CloseHandle(pi.hThread);
        CloseHandle(pi.hProcess);
    }

    static int Main(string[] args)
    {
        string id = "anon", scratch = ".", stopFile = null, chain = "";
        int lifetime = 25, exitCode = 0, chatty = 0, childLifetime = -1;
        bool tryBreakaway = false, stdinExit = false;

        for (int i = 0; i < args.Length; i++)
        {
            string a = args[i];
            if (a == "--id" && i + 1 < args.Length) id = args[++i];
            else if (a == "--scratch" && i + 1 < args.Length) scratch = args[++i];
            else if (a == "--lifetime" && i + 1 < args.Length) int.TryParse(args[++i], out lifetime);
            else if (a == "--child-lifetime" && i + 1 < args.Length) int.TryParse(args[++i], out childLifetime);
            else if (a == "--exit-code" && i + 1 < args.Length) int.TryParse(args[++i], out exitCode);
            else if (a == "--spawn-chain" && i + 1 < args.Length) chain = args[++i];
            else if (a == "--chatty" && i + 1 < args.Length) int.TryParse(args[++i], out chatty);
            else if (a == "--try-breakaway") tryBreakaway = true;
            else if (a == "--stdin-exit") stdinExit = true;
            else if (a == "--stop-file" && i + 1 < args.Length) stopFile = args[++i];
        }
        if (stopFile == null) stopFile = id + ".stop";
        Directory.CreateDirectory(scratch);

        int pid = System.Diagnostics.Process.GetCurrentProcess().Id;
        long epoch = (long)(DateTime.UtcNow - new DateTime(1970, 1, 1)).TotalMilliseconds;
        File.WriteAllText(Path.Combine(scratch, id + ".started"),
            "pid=" + pid + "|epoch=" + epoch + "|chain=" + chain + Environment.NewLine);

        if (tryBreakaway)
        {
            // Attempt to escape the containing Job via the explicit breakaway flag.
            // jobrun never sets JOB_OBJECT_LIMIT_BREAKAWAY_OK, so this must fail
            // with ERROR_ACCESS_DENIED (5) for every process in the tree.
            var si = new STARTUPINFO();
            si.cb = Marshal.SizeOf(typeof(STARTUPINFO));
            var sb = new StringBuilder("\"" + Self() + "\" --id " + id + "-breakaway-child --scratch \""
                + scratch + "\" --lifetime " + lifetime);
            PROCESS_INFORMATION pi;
            bool ok = CreateProcessW(null, sb.ToString(), IntPtr.Zero, IntPtr.Zero, true,
                0x01000000 /* CREATE_BREAKAWAY_FROM_JOB */, IntPtr.Zero, null, ref si, out pi);
            if (ok)
            {
                CloseHandle(pi.hThread); CloseHandle(pi.hProcess);
                File.WriteAllText(Path.Combine(scratch, id + ".breakaway"),
                    "SUCCESS|child_pid=" + pi.dwProcessId + Environment.NewLine);
            }
            else
            {
                File.WriteAllText(Path.Combine(scratch, id + ".breakaway"),
                    "FAILED|win32_err=" + Marshal.GetLastWin32Error() + Environment.NewLine);
            }
        }

        if (chatty > 0)
        {
            var pad = new StringBuilder();
            for (int p = 0; p < 40; p++) pad.Append('x');
            var outBuf = new StringBuilder();
            for (int n = 0; n < chatty; n++)
            {
                outBuf.Append("CHATTY|").Append(id).Append('|').Append(n.ToString("D7")).Append('|').AppendLine(pad.ToString());
                if (n % 1000 == 999)
                {
                    Console.Out.Write(outBuf.ToString());
                    Console.Out.Flush();
                    outBuf.Length = 0;
                }
            }
            Console.Out.Write(outBuf.ToString());
            Console.Out.Flush();
        }

        if (chain.Length > 0)
        {
            int gt = chain.IndexOf('>');
            string head = gt < 0 ? chain : chain.Substring(0, gt);
            string rest = gt < 0 ? "" : chain.Substring(gt + 1);
            Spawn(scratch, head, rest, childLifetime > 0 ? childLifetime : lifetime, exitCode);
        }

        string stopPath = Path.Combine(scratch, stopFile);
        string hbPath = Path.Combine(scratch, id + ".heartbeat");

        if (stdinExit)
        {
            // Cooperative stdin-EOF reaction: a real app-server exits when its
            // control stream closes; the wrapper then observes a natural root
            // exit during the grace interval instead of hard-terminating.
            var eofThread = new Thread(delegate()
            {
                try { while (Console.In.ReadLine() != null) { } }
                catch { }
                File.WriteAllText(Path.Combine(scratch, id + ".exited"),
                    "reason=stdin_eof|code=0|pid=" + pid + Environment.NewLine);
                Environment.Exit(0);
            });
            eofThread.IsBackground = true;
            eofThread.Start();
        }

        var sw = System.Diagnostics.Stopwatch.StartNew();
        int tick = 0;
        while (sw.Elapsed.TotalSeconds < lifetime)
        {
            if (File.Exists(stopPath))
            {
                File.WriteAllText(Path.Combine(scratch, id + ".exited"),
                    "reason=graceful_stop_file|code=0|pid=" + pid + Environment.NewLine);
                return 0;
            }
            long now = (long)(DateTime.UtcNow - new DateTime(1970, 1, 1)).TotalMilliseconds;
            File.AppendAllText(hbPath, id + "|" + tick + "|" + now + "|" + pid + Environment.NewLine);
            tick++;
            Thread.Sleep(250);
        }
        File.WriteAllText(Path.Combine(scratch, id + ".exited"),
            "reason=lifetime|code=" + exitCode + "|pid=" + pid + Environment.NewLine);
        return exitCode;
    }
}
