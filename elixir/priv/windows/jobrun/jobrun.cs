// jobrun.exe — Windows Job Object worker containment wrapper (MIC-223).
//
// One worker launch -> one Job Object -> stop kills that Job -> the whole
// process tree is positively confirmed dead before the wrapper exits, so the
// runtime may treat the workspace as worker-free. The load-bearing invariant
// lives on the Elixir side: NO WORKSPACE REUSE UNTIL TERMINATED_CONFIRMED.
//
// Usage:
//   jobrun [--grace-ms N] [--drain-wait-ms N] [--receipt path] [--launch-id id] -- <child.exe> <args...>
//
// Contract:
//   - child executable must be an absolute path; no PATH search happens here;
//   - the Job has JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE and no breakaway flags,
//     so breakaway is denied for every process in the tree;
//   - the child is created suspended, assigned to the Job before its first
//     instruction, then resumed, so no descendant can exist outside the Job;
//   - stdin/stdout/stderr handles pass through untouched; this wrapper never
//     writes to stdout (stderr carries failure diagnostics only), so the
//     AppServer JSON-RPC stream stays clean;
//   - stdin EOF (the observable effect of Port.close) starts a bounded
//     cooperative grace interval; if the tree is still alive afterwards the
//     Job is hard-terminated with TerminateJobObject;
//   - before exiting, the wrapper positively verifies ActiveProcesses == 0
//     through QueryInformationJobObject and records it in the receipt;
//   - termination evidence is written to --receipt as one JSON object;
//     --launch-id is echoed into the receipt so the runtime can bind receipt
//     files to persisted worker identities;
//   - exit codes are transport only, never lifecycle semantics:
//       child's exit code   root exited and the tree drained
//       253                 the Job had to be terminated
//       254                 wrapper failure (bad args, spawn failure)
//
// Security posture: no elevation, no foreign-PID OpenProcess termination, no
// named Job objects, no PATH lookup, environment and current directory are
// inherited from the caller (the Elixir port already applied cd/env policy).
//
// Build (in-box compiler, no installs, no package restore):
//   %WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe /nologo /optimize+ /out:jobrun.exe jobrun.cs

using System;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

static class JobRun
{
    const int EXIT_JOB_TERMINATED = 253;
    const int EXIT_WRAPPER_ERROR = 254;

    const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000;
    const int JobObjectExtendedLimitInformation = 9;
    const int JobObjectBasicAccountingInformation = 1;
    const uint CREATE_SUSPENDED = 0x00000004;
    const int STARTF_USESTDHANDLES = 0x00000100;
    const uint FILE_TYPE_PIPE = 3;
    const uint JOB_TERMINATED_EXITCODE = 0xF291;
    const uint WAIT_OBJECT_0 = 0;
    const long HARD_TERMINATE_DRAIN_MS = 10000;

    static string receiptPath;
    static string launchId = "";

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr CreateJobObjectW(IntPtr lpJobAttributes, string lpName);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetInformationJobObject(IntPtr hJob, int infoClass,
        ref JOBOBJECT_EXTENDED_LIMIT_INFORMATION lpInfo, int cbLen);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool QueryInformationJobObject(IntPtr hJob, int infoClass,
        out JOBOBJECT_BASIC_ACCOUNTING_INFORMATION lpInfo, int cbLen, out int lpReturnLength);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool AssignProcessToJobObject(IntPtr hJob, IntPtr hProcess);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool TerminateJobObject(IntPtr hJob, uint uExitCode);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool CreateProcessW(string lpApplicationName, string lpCommandLine,
        IntPtr lpProcessAttributes, IntPtr lpThreadAttributes, bool bInheritHandles,
        uint dwCreationFlags, IntPtr lpEnvironment, string lpCurrentDirectory,
        ref STARTUPINFO lpStartupInfo, out PROCESS_INFORMATION lpProcessInformation);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CloseHandle(IntPtr hObject);
    [DllImport("kernel32.dll")]
    static extern uint ResumeThread(IntPtr hThread);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern uint WaitForSingleObject(IntPtr hHandle, uint dwMilliseconds);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetExitCodeProcess(IntPtr hProcess, out uint lpExitCode);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetProcessTimes(IntPtr hProcess, out long lpCreationTime,
        out long lpExitTime, out long lpKernelTime, out long lpUserTime);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool PeekNamedPipe(IntPtr hNamedPipe, IntPtr lpBuffer, uint nBufferSize,
        IntPtr lpBytesRead, out uint lpTotalBytesAvail, IntPtr lpBytesLeftThisMessage);
    [DllImport("kernel32.dll")]
    static extern uint GetFileType(IntPtr hFile);
    [DllImport("kernel32.dll")]
    static extern IntPtr GetStdHandle(int nStdHandle);
    [DllImport("kernel32.dll")]
    static extern ulong GetTickCount64();

    [StructLayout(LayoutKind.Sequential)]
    struct JOBOBJECT_BASIC_LIMIT_INFORMATION
    {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public IntPtr MinimumWorkingSetSize;
        public IntPtr MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public IntPtr Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct IO_COUNTERS
    {
        public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount;
        public ulong ReadTransferCount, WriteTransferCount, OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
    {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public IntPtr ProcessMemoryLimit;
        public IntPtr JobMemoryLimit;
        public IntPtr PeakProcessMemoryUsed;
        public IntPtr PeakJobMemoryUsed;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct JOBOBJECT_BASIC_ACCOUNTING_INFORMATION
    {
        public long TotalUserTime;
        public long TotalKernelTime;
        public long ThisPeriodTotalUserTime;
        public long ThisPeriodTotalKernelTime;
        public uint TotalPageFaultCount;
        public uint TotalProcesses;
        public uint ActiveProcesses;
        public uint TotalTerminatedProcesses;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct STARTUPINFO
    {
        public int cb;
        public string lpReserved;
        public string lpDesktop;
        public string lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow, cbReserved2;
        public IntPtr lpReserved2;
        public IntPtr hStdInput, hStdOutput, hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct PROCESS_INFORMATION
    {
        public IntPtr hProcess, hThread;
        public int dwProcessId, dwThreadId;
    }

    static int Main(string[] argsRaw)
    {
        long startedAtMs = (long)GetTickCount64();
        long graceMs = 5000, drainWaitMs = 3000;

        int i = 0;
        for (; i < argsRaw.Length; i++)
        {
            string a = argsRaw[i];
            if (a == "--") { i++; break; }
            if (a == "--grace-ms" && i + 1 < argsRaw.Length) { graceMs = ParseNonNegative(argsRaw[++i], graceMs); continue; }
            if (a == "--drain-wait-ms" && i + 1 < argsRaw.Length) { drainWaitMs = ParseNonNegative(argsRaw[++i], drainWaitMs); continue; }
            if (a == "--receipt" && i + 1 < argsRaw.Length) { receiptPath = argsRaw[++i]; continue; }
            if (a == "--launch-id" && i + 1 < argsRaw.Length) { launchId = argsRaw[++i]; continue; }
            Console.Error.WriteLine("jobrun: unknown option: " + a);
            WriteReceipt("WRAPPER_FAILURE", "wrapper_failure", false, -1, -1, 0, startedAtMs, -1, -1, -1);
            return EXIT_WRAPPER_ERROR;
        }
        if (i >= argsRaw.Length)
        {
            Console.Error.WriteLine("jobrun: usage: jobrun [options] -- <child.exe> <args...>");
            WriteReceipt("WRAPPER_FAILURE", "wrapper_failure", false, -1, -1, 0, startedAtMs, -1, -1, -1);
            return EXIT_WRAPPER_ERROR;
        }

        string childExe = argsRaw[i];
        var rest = new string[argsRaw.Length - i - 1];
        Array.Copy(argsRaw, i + 1, rest, 0, rest.Length);

        if (!Path.IsPathRooted(childExe))
        {
            Console.Error.WriteLine("jobrun: child executable must be an absolute path: " + childExe);
            WriteReceipt("WRAPPER_FAILURE", "wrapper_failure", false, -1, -1, 0, startedAtMs, -1, -1, -1);
            return EXIT_WRAPPER_ERROR;
        }

        // Anonymous Job, KILL_ON_JOB_CLOSE only. Breakaway is impossible: neither
        // JOB_OBJECT_LIMIT_BREAKAWAY_OK nor JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK is set.
        IntPtr hJob = CreateJobObjectW(IntPtr.Zero, null);
        if (hJob == IntPtr.Zero)
        {
            Console.Error.WriteLine("jobrun: CreateJobObject failed err=" + Marshal.GetLastWin32Error());
            WriteReceipt("WRAPPER_FAILURE", "wrapper_failure", false, -1, -1, 0, startedAtMs, -1, -1, -1);
            return EXIT_WRAPPER_ERROR;
        }

        var limits = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
        limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        if (!SetInformationJobObject(hJob, JobObjectExtendedLimitInformation, ref limits,
            Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION))))
        {
            Console.Error.WriteLine("jobrun: SetInformationJobObject failed err=" + Marshal.GetLastWin32Error());
            WriteReceipt("WRAPPER_FAILURE", "wrapper_failure", false, -1, -1, 0, startedAtMs, -1, -1, -1);
            return EXIT_WRAPPER_ERROR;
        }

        // The child inherits this wrapper's stdio handles, environment and current
        // directory (lpEnvironment/lpCurrentDirectory are NULL). The Elixir port owns
        // the cd/env policy; nothing is re-derived or searched here.
        var si = new STARTUPINFO();
        si.cb = Marshal.SizeOf(typeof(STARTUPINFO));
        si.dwFlags = STARTF_USESTDHANDLES;
        si.hStdInput = GetStdHandle(-10);
        si.hStdOutput = GetStdHandle(-11);
        si.hStdError = GetStdHandle(-12);
        var cmd = new StringBuilder(Quote(childExe));
        foreach (string a in rest) cmd.Append(' ').Append(Quote(a));

        PROCESS_INFORMATION pi;
        bool ok = CreateProcessW(childExe, cmd.ToString(), IntPtr.Zero, IntPtr.Zero,
            true, CREATE_SUSPENDED, IntPtr.Zero, null, ref si, out pi);
        if (!ok)
        {
            int err = Marshal.GetLastWin32Error();
            Console.Error.WriteLine("jobrun: CreateProcess failed err=" + err + " exe=" + childExe);
            WriteReceipt("WRAPPER_FAILURE", "spawn_failed", false, -1, -1, 0, startedAtMs, -1, -1, -1);
            CloseHandle(hJob);
            return EXIT_WRAPPER_ERROR;
        }
        if (!AssignProcessToJobObject(hJob, pi.hProcess))
        {
            int err = Marshal.GetLastWin32Error();
            Console.Error.WriteLine("jobrun: AssignProcessToJobObject failed err=" + err);
            // KILL_ON_JOB_CLOSE never took effect for this child; fail closed.
            TerminateJobObject(hJob, JOB_TERMINATED_EXITCODE);
            WriteReceipt("WRAPPER_FAILURE", "assign_failed", false, -1, -1, 0, startedAtMs, -1, -1, -1);
            CloseHandle(pi.hProcess); CloseHandle(pi.hThread); CloseHandle(hJob);
            return EXIT_WRAPPER_ERROR;
        }
        ResumeThread(pi.hThread);
        CloseHandle(pi.hThread);
        IntPtr hChild = pi.hProcess;

        long rootCreationFT;
        long ignoreFT;
        if (!GetProcessTimes(hChild, out rootCreationFT, out ignoreFT, out ignoreFT, out ignoreFT))
            rootCreationFT = 0;

        IntPtr hStdin = GetStdHandle(-10);
        bool monitorEof = hStdin != IntPtr.Zero && hStdin != (IntPtr)(-1) && GetFileType(hStdin) == FILE_TYPE_PIPE;

        // Wait loop: root exit or stdin EOF. Anonymous pipe handles are always signaled,
        // so EOF is detected by PeekNamedPipe failure (broken pipe), never by handle
        // signaled state, and no data bytes are ever consumed.
        while (true)
        {
            uint w = WaitForSingleObject(hChild, 100);
            if (w == WAIT_OBJECT_0)
            {
                uint rootCode;
                GetExitCodeProcess(hChild, out rootCode);
                long rootExitedAtMs = (long)GetTickCount64();
                // Root exit is not tree death: orphaned descendants may still hold the
                // workspace. Bounded drain, then hard terminate, then positive evidence.
                bool drained = WaitDrained(hJob, drainWaitMs);
                long drainedAtMs = (long)GetTickCount64();
                if (!drained)
                {
                    TerminateJobObject(hJob, JOB_TERMINATED_EXITCODE);
                    drained = WaitDrained(hJob, HARD_TERMINATE_DRAIN_MS);
                    drainedAtMs = (long)GetTickCount64();
                }
                string reason = drained ? "NATURAL_EXIT" : "TERMINATION_UNCONFIRMED";
                WriteReceipt(reason, "natural_exit", drained, unchecked((int)rootCode),
                    pi.dwProcessId, rootCreationFT, startedAtMs, -1, rootExitedAtMs, drainedAtMs);
                Finish(hJob, hChild);
                return unchecked((int)rootCode);
            }
            if (monitorEof && CheckEof(hStdin))
            {
                long requestedAtMs = (long)GetTickCount64();
                // Cooperative grace: the app-server may react to stdin EOF itself.
                bool drained = WaitDrained(hJob, graceMs);
                uint rootCode;
                GetExitCodeProcess(hChild, out rootCode);
                bool rootGone = WaitForSingleObject(hChild, 0) == WAIT_OBJECT_0;
                long drainedAtMs = (long)GetTickCount64();
                if (!drained)
                {
                    TerminateJobObject(hJob, JOB_TERMINATED_EXITCODE);
                    drained = WaitDrained(hJob, HARD_TERMINATE_DRAIN_MS);
                    drainedAtMs = (long)GetTickCount64();
                }
                int transportCode;
                string reason;
                string mode;
                if (rootGone && drained)
                {
                    transportCode = unchecked((int)rootCode);
                    reason = "COOPERATIVE_EXIT";
                    mode = "stdin_eof_grace";
                }
                else
                {
                    transportCode = EXIT_JOB_TERMINATED;
                    reason = drained ? "HARD_JOB_TERMINATION" : "TERMINATION_UNCONFIRMED";
                    mode = "stdin_eof_terminate";
                }
                WriteReceipt(reason, mode, drained, rootGone ? unchecked((int)rootCode) : -1,
                    pi.dwProcessId, rootCreationFT, startedAtMs, requestedAtMs, rootGone ? drainedAtMs : -1, drainedAtMs);
                Finish(hJob, hChild);
                return transportCode;
            }
            // WAIT_TIMEOUT: loop again.
        }
    }

    static long ParseNonNegative(string raw, long fallback)
    {
        long parsed;
        if (long.TryParse(raw, NumberStyles.Integer, CultureInfo.InvariantCulture, out parsed) && parsed >= 0)
            return parsed;
        return fallback;
    }

    // Positive tree-drain evidence: ActiveProcesses == 0 via job accounting.
    static bool WaitDrained(IntPtr hJob, long timeoutMs)
    {
        long deadline = (long)GetTickCount64() + timeoutMs;
        while ((long)GetTickCount64() < deadline)
        {
            JOBOBJECT_BASIC_ACCOUNTING_INFORMATION acct;
            int retLen;
            if (!QueryInformationJobObject(hJob, JobObjectBasicAccountingInformation,
                out acct, Marshal.SizeOf(typeof(JOBOBJECT_BASIC_ACCOUNTING_INFORMATION)), out retLen))
                return false;
            if (acct.ActiveProcesses == 0)
                return true;
            System.Threading.Thread.Sleep(20);
        }
        return false;
    }

    // EOF = PeekNamedPipe fails with a broken-pipe class error. Never consumes data.
    static bool CheckEof(IntPtr hStdin)
    {
        uint avail;
        if (!PeekNamedPipe(hStdin, IntPtr.Zero, 0, IntPtr.Zero, out avail, IntPtr.Zero))
        {
            int err = Marshal.GetLastWin32Error();
            return err == 109 /*ERROR_BROKEN_PIPE*/ || err == 233 /*ERROR_PIPE_NOT_CONNECTED*/ || err == 232 /*ERROR_NO_DATA*/;
        }
        return false;
    }

    // Deterministic handle closure order: job last, so KILL_ON_JOB_CLOSE has no window.
    static void Finish(IntPtr hJob, IntPtr hChild)
    {
        if (hChild != IntPtr.Zero) CloseHandle(hChild);
        CloseHandle(hJob);
    }

    // One JSON object per launch. Written best-effort: a receipt write failure must
    // never mask the real transport exit code, and a missing/unparseable receipt is
    // treated as TERMINATION_UNCONFIRMED (fail closed) by the runtime.
    static void WriteReceipt(string terminalReason, string terminationMode, bool treeDrained,
        int childExitCode, long rootPid, long rootCreationFT, long startedAtMs, long requestedAtMs,
        long rootExitedAtMs, long drainedAtMs)
    {
        if (receiptPath == null) return;
        try
        {
            string dir = Path.GetDirectoryName(Path.GetFullPath(receiptPath));
            if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);

            var sb = new StringBuilder(512);
            sb.Append('{');
            AppendField(sb, "schema_version", "1", true);
            AppendField(sb, "launch_id", launchId, false);
            AppendField(sb, "wrapper_pid", System.Diagnostics.Process.GetCurrentProcess().Id.ToString(CultureInfo.InvariantCulture), true);
            AppendField(sb, "root_pid", rootPid < 0 ? null : rootPid.ToString(CultureInfo.InvariantCulture), true);
            AppendField(sb, "root_creation_time", rootCreationFT <= 0 ? null : FileTimeIsoUtc(rootCreationFT), false);
            AppendField(sb, "started_at", IsoUtc(startedAtMs), false);
            AppendField(sb, "termination_requested_at", requestedAtMs < 0 ? null : IsoUtc(requestedAtMs), false);
            AppendField(sb, "root_exited_at", rootExitedAtMs < 0 ? null : IsoUtc(rootExitedAtMs), false);
            AppendField(sb, "tree_drained_at", drainedAtMs < 0 ? null : IsoUtc(drainedAtMs), false);
            AppendField(sb, "termination_mode", terminationMode, false);
            AppendField(sb, "tree_drained", treeDrained ? "true" : "false", true);
            AppendField(sb, "child_exit_code", childExitCode < 0 ? null : childExitCode.ToString(CultureInfo.InvariantCulture), true);
            AppendField(sb, "wrapper_status", "ok", false);
            AppendField(sb, "terminal_reason", terminalReason, false);
            sb.Append('}');

            string tmp = receiptPath + "." + Guid.NewGuid().ToString("N") + ".tmp";
            File.WriteAllText(tmp, sb.ToString());
            if (File.Exists(receiptPath)) File.Delete(receiptPath);
            File.Move(tmp, receiptPath);
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine("jobrun: receipt write failed: " + ex.Message);
        }
    }

    static string IsoUtc(long tickMs)
    {
        DateTime dt = DateTime.UtcNow.AddMilliseconds(tickMs - (long)GetTickCount64());
        return dt.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", CultureInfo.InvariantCulture);
    }

    static string FileTimeIsoUtc(long fileTime)
    {
        return DateTime.FromFileTimeUtc(fileTime).ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", CultureInfo.InvariantCulture);
    }

    static void AppendField(StringBuilder sb, string name, string value, bool raw)
    {
        if (value == null) return;
        if (sb[sb.Length - 1] != '{') sb.Append(',');
        sb.Append('"').Append(name).Append("\":");
        if (raw) sb.Append(value);
        else sb.Append('"').Append(EscapeJson(value)).Append('"');
    }

    static string EscapeJson(string value)
    {
        var sb = new StringBuilder(value.Length + 8);
        foreach (char c in value)
        {
            switch (c)
            {
                case '"': sb.Append("\\\""); break;
                case '\\': sb.Append("\\\\"); break;
                case '\b': sb.Append("\\b"); break;
                case '\f': sb.Append("\\f"); break;
                case '\n': sb.Append("\\n"); break;
                case '\r': sb.Append("\\r"); break;
                case '\t': sb.Append("\\t"); break;
                default:
                    if (c < ' ') sb.Append("\\u").Append(((int)c).ToString("x4", CultureInfo.InvariantCulture));
                    else sb.Append(c);
                    break;
            }
        }
        return sb.ToString();
    }

    // Safe Windows argument quoting per the standard MSVCRT rules.
    static string Quote(string arg)
    {
        if (arg.Length > 0 && arg.IndexOf(' ') < 0 && arg.IndexOf('\t') < 0 && arg.IndexOf('"') < 0)
            return arg;
        var sb = new StringBuilder();
        sb.Append('"');
        int backslashes = 0;
        for (int i = 0; i < arg.Length; i++)
        {
            char c = arg[i];
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
