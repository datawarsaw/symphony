defmodule SymphonyElixir.WorkerContainment do
  @moduledoc """
  MIC-223 Windows worker containment: identity, termination receipts, and the
  positive-death verdict for locally launched workers.

  Load-bearing invariant:

  ```
  NO WORKSPACE REUSE UNTIL TERMINATED_CONFIRMED
  ```

  One worker launch maps to one anonymous Job Object (`KILL_ON_JOB_CLOSE`,
  breakaway denied, child assigned before first instruction) owned by the
  `jobrun` wrapper under `priv/windows/jobrun`. `Port.close` only breaks the
  wrapper's stdin; the wrapper grants a bounded cooperative grace interval and
  then hard-terminates the Job, and positively verifies `ActiveProcesses == 0`
  through job accounting before it exits. The wrapper records the outcome as a
  JSON termination receipt; a missing, malformed, or unproven receipt is
  `TERMINATION_UNCONFIRMED` and must fail closed (no workspace cleanup, no
  workspace reuse, no redispatch against the same mutable workspace).

  `ROOT_EXITED` is never treated as death: only the receipt's `tree_drained`
  evidence (job accounting, not PID checks) yields `TERMINATED_CONFIRMED`.
  PID-only identities stay under `SymphonyElixir.WorkerFence`, which remains
  the fail-closed liveness authority; this module supplies it with the
  receipt-backed evidence path for persisted identities.

  Non-Windows and remote (SSH) worker launches are out of scope and keep their
  previous behavior: they produce `:NOT_APPLICABLE` confirmations, which the
  runtime treats as "gate not applicable", never as confirmed death.
  """

  require Logger

  alias SymphonyElixir.Config

  @schema_version 1
  @confirmed_reasons MapSet.new(["NATURAL_EXIT", "COOPERATIVE_EXIT", "HARD_JOB_TERMINATION"])
  # grace + hard-terminate drain budget (helper caps its own drain at 10s) + slack.
  @hard_terminate_budget_ms 20_000

  @type status :: :TERMINATED_CONFIRMED | :TERMINATION_UNCONFIRMED | :NOT_APPLICABLE

  @type confirmation :: %{
          required(:status) => status(),
          optional(:receipt) => map() | nil,
          optional(:exit_code) => non_neg_integer() | nil,
          optional(:reason) => term()
        }

  # ---------------------------------------------------------------------------
  # Configuration
  # ---------------------------------------------------------------------------

  @doc """
  Containment applies only to local Windows worker launches. Remote (SSH)
  workers and non-Windows hosts keep their previous behavior.
  """
  @spec containment_active?() :: boolean()
  def containment_active? do
    match?({:win32, _}, :os.type()) and Config.settings!().codex.worker_containment_enabled
  end

  @spec grace_ms() :: pos_integer()
  def grace_ms, do: Config.settings!().codex.worker_termination_grace_ms

  @doc """
  Directory holding one termination receipt per launch. Mirrors the RetryStore
  convention: durable state lives under `<workspace_root>/.symphony-state` so
  receipts survive per-workspace cleanup and runtime restarts.
  """
  @spec receipt_dir() :: String.t()
  def receipt_dir do
    override = Application.get_env(:symphony_elixir, :worker_termination_receipt_root)

    case override do
      root when is_binary(root) and root != "" -> root
      _ -> Path.join([Config.local_workspace_root(), ".symphony-state", "worker-terminations"])
    end
  end

  # ---------------------------------------------------------------------------
  # Helper binary: deterministic in-box build + hash verification
  # ---------------------------------------------------------------------------

  @spec helper_source_dir() :: String.t()
  def helper_source_dir, do: Application.app_dir(:symphony_elixir, "priv/windows/jobrun")

  @doc """
  Verified path of the `jobrun` helper executable, or a visible error. The
  helper is never committed; a checkout builds it once via `mix jobrun.build`
  and the SHA-256 recorded next to the binary must match at every launch.
  """
  @spec helper_path() :: {:ok, String.t()} | {:error, term()}
  def helper_path do
    override = Application.get_env(:symphony_elixir, :jobrun_helper_path)
    exe = if is_binary(override) and override != "", do: override, else: Path.join(helper_source_dir(), "jobrun.exe")

    cond do
      not File.exists?(exe) ->
        {:error, {:jobrun_helper_missing, exe}}

      not File.regular?(exe) ->
        {:error, {:jobrun_helper_missing, exe}}

      true ->
        verify_helper_hash(exe)
    end
  end

  defp verify_helper_hash(exe) do
    sha_path = exe <> ".sha256"

    case File.read(sha_path) do
      {:ok, recorded} ->
        actual = exe_hash(exe)
        expected = recorded |> String.trim() |> String.downcase()

        if actual == expected do
          {:ok, exe}
        else
          {:error, {:jobrun_helper_hash_mismatch, exe, expected, actual}}
        end

      {:error, _} ->
        {:error, {:jobrun_helper_unverified, exe}}
    end
  end

  @doc """
  Builds the helper from checked-in source with the in-box `csc.exe` and
  records its SHA-256. No package restore, no network, no elevation.
  """
  @spec build_helper() :: {:ok, %{exe: String.t(), sha256: String.t()}} | {:error, term()}
  def build_helper do
    dir = helper_source_dir()
    src = Path.join(dir, "jobrun.cs")
    exe = Path.join(dir, "jobrun.exe")

    with {:ok, csc} <- find_csc(),
         :ok <- compile(csc, src, exe) do
      sha256 = exe_hash(exe)
      File.write!(exe <> ".sha256", sha256)
      {:ok, %{exe: exe, sha256: sha256}}
    end
  end

  @doc """
  Builds the helper if the current checkout does not yet carry a verified one.
  Used by the test suite so containment paths are exercised deterministically.
  """
  @spec ensure_helper_built() :: :ok | {:error, term()}
  def ensure_helper_built do
    case helper_path() do
      {:ok, _exe} ->
        :ok

      {:error, {:jobrun_helper_missing, _exe}} ->
        build_helper()
        |> case do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp find_csc do
    windir = System.get_env("WINDIR") || "C:\\Windows"

    candidates = [
      Path.join([windir, "Microsoft.NET", "Framework64", "v4.0.30319", "csc.exe"]),
      Path.join([windir, "Microsoft.NET", "Framework", "v4.0.30319", "csc.exe"])
    ]

    Enum.find_value(candidates, fn candidate ->
      if File.exists?(candidate), do: {:ok, candidate}, else: nil
    end) || {:error, :csc_not_found}
  end

  defp compile(csc, src, exe) do
    # The in-box csc.exe misparses forward-slash paths as option separators;
    # feed it Windows-style backslash paths.
    csc_args = ["/nologo", "/optimize+", "/target:exe", "/out:" <> backslash(exe), backslash(src)]

    case System.cmd(csc, csc_args, stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      {output, status} ->
        {:error, {:jobrun_compile_failed, status, output}}
    end
  end

  defp backslash(path) when is_binary(path), do: String.replace(path, "/", "\\")

  defp exe_hash(exe) do
    case File.read(exe) do
      {:ok, binary} -> Base.encode16(:crypto.hash(:sha256, binary), case: :lower)
      {:error, reason} -> raise "jobrun helper unreadable: #{inspect(reason)}"
    end
  end

  # ---------------------------------------------------------------------------
  # Worker identity (Phase 4 contract)
  # ---------------------------------------------------------------------------

  @doc """
  Bounded worker identity for one launch. String-keyed so it round-trips
  through the RetryStore JSON records unchanged. `root_pid`/`root_creation_time`
  stay nil until the termination receipt supplies them; PID fields are evidence
  mirrors only and never authoritative.
  """
  @spec new_identity(keyword()) :: map()
  def new_identity(opts) do
    launch_id =
      "#{System.system_time(:millisecond)}-#{:erlang.unique_integer([:positive])}"

    %{
      "schema_version" => @schema_version,
      "launch_id" => launch_id,
      "issue_id" => opts[:issue_id],
      "attempt_id" => opts[:attempt_id],
      "workspace" => opts[:workspace],
      "worker_host" => opts[:worker_host],
      "root_pid" => nil,
      "root_creation_time" => nil,
      "receipt_path" => Path.join(receipt_dir(), launch_id <> ".json")
    }
  end

  @doc """
  argv vector for the wrapper port: `[opts] -- <child.exe> <child args...>`.
  The child executable is passed through as an absolute path (the helper
  refuses relative paths), so the existing Git Bash `-lc` contract is kept.
  """
  @spec launch_args(map(), String.t(), [String.t() | charlist()]) :: [String.t() | charlist()]
  def launch_args(identity, child_executable, child_args) do
    options = [
      "--grace-ms",
      Integer.to_string(grace_ms()),
      "--receipt",
      identity["receipt_path"],
      "--launch-id",
      identity["launch_id"] || "",
      "--"
    ]

    Enum.map(options ++ [child_executable | child_args], fn
      arg when is_binary(arg) -> String.to_charlist(arg)
      arg when is_list(arg) -> arg
    end)
  end

  @doc """
  Merges receipt evidence (root pid/creation time, terminal reason) into the
  identity for durable persistence. The receipt file itself stays the primary
  evidence; this mirror is convenience only.
  """
  @spec merge_receipt(map(), map()) :: map()
  def merge_receipt(identity, receipt) do
    identity
    |> Map.put("root_pid", receipt["root_pid"] || identity["root_pid"])
    |> Map.put("root_creation_time", receipt["root_creation_time"] || identity["root_creation_time"])
    |> Map.put("terminal_reason", receipt["terminal_reason"])
    |> Map.put("tree_drained", receipt["tree_drained"])
  end

  # ---------------------------------------------------------------------------
  # Stop + positive-death confirmation (Phase 7/8)
  # ---------------------------------------------------------------------------

  @doc """
  Closes the port (stdin EOF to the wrapper), then waits a bounded interval
  for the wrapper to finish and records the receipt verdict.

  The port cannot be used after `Port.close` (the BEAM tears the driver down
  immediately and never delivers `exit_status` for an explicitly closed port,
  proven on OTP 28/Windows), so wrapper completion is observed through the
  wrapper OS pid captured at launch and the receipt file. Returns a
  confirmation; `:TERMINATION_UNCONFIRMED` means the runtime could NOT prove
  tree death and callers must fail closed. Never raises.
  """
  @spec stop_and_confirm(port(), map() | nil, pos_integer()) :: confirmation()
  def stop_and_confirm(port, identity, grace_ms_value)

  def stop_and_confirm(port, identity, grace_ms_value) when is_port(port) do
    os_pid = wrapper_os_pid(identity)
    Port.close(port)
    deadline = System.monotonic_time(:millisecond) + grace_ms_value + @hard_terminate_budget_ms

    case await_wrapper_completion(os_pid, identity, deadline) do
      :completed -> confirm_from_receipt(identity)
      :timeout -> %{status: :TERMINATION_UNCONFIRMED, receipt: nil, exit_code: nil, reason: :termination_wait_timeout}
    end
  end

  defp wrapper_os_pid(%{"wrapper_pid" => raw}) when is_binary(raw) do
    case Integer.parse(raw) do
      {pid, ""} when pid > 0 -> pid
      _ -> nil
    end
  end

  defp wrapper_os_pid(_identity), do: nil

  # Wrapper completion = the wrapper process is gone, or its receipt has
  # appeared (the wrapper writes the receipt just before exiting).
  defp await_wrapper_completion(os_pid, identity, deadline) do
    cond do
      receipt_readable?(identity) ->
        :completed

      wrapper_gone?(os_pid) ->
        # Give the wrapper a moment to flush the receipt after process exit.
        :completed

      System.monotonic_time(:millisecond) >= deadline ->
        :timeout

      true ->
        Process.sleep(150)
        await_wrapper_completion(os_pid, identity, deadline)
    end
  end

  defp receipt_readable?(%{"receipt_path" => path}) when is_binary(path) do
    match?({:ok, _}, parse_receipt(path))
  end

  defp receipt_readable?(_identity), do: false

  defp wrapper_gone?(nil), do: false

  defp wrapper_gone?(os_pid) when is_integer(os_pid) do
    {output, 0} =
      System.cmd("tasklist", ["/FI", "PID eq #{os_pid}", "/NH", "/FO", "CSV"], stderr_to_stdout: true)

    not Regex.match?(~r/"#{os_pid}"/, output)
  end

  defp confirm_from_receipt(nil) do
    %{status: :TERMINATION_UNCONFIRMED, receipt: nil, exit_code: nil, reason: :no_worker_identity}
  end

  defp confirm_from_receipt(identity) do
    case parse_receipt(identity["receipt_path"]) do
      {:ok, receipt} ->
        case classify_receipt(receipt) do
          :TERMINATED_CONFIRMED ->
            %{
              status: :TERMINATED_CONFIRMED,
              receipt: receipt,
              exit_code: receipt["child_exit_code"],
              reason: receipt["terminal_reason"]
            }

          :TERMINATION_UNCONFIRMED ->
            %{
              status: :TERMINATION_UNCONFIRMED,
              receipt: receipt,
              exit_code: receipt["child_exit_code"],
              reason: :receipt_not_proven
            }
        end

      {:error, reason} ->
        %{status: :TERMINATION_UNCONFIRMED, receipt: nil, exit_code: nil, reason: reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Termination receipt parsing/classification (Phase 3/18)
  # ---------------------------------------------------------------------------

  @doc """
  Parses and validates a wrapper receipt. Any structural deviation (missing
  file, bad JSON, wrong schema, absent invariants) is an error: callers must
  treat it as TERMINATION_UNCONFIRMED, never as evidence of death.
  """
  @spec parse_receipt(String.t() | nil) :: {:ok, map()} | {:error, term()}
  def parse_receipt(nil), do: {:error, :receipt_path_missing}

  def parse_receipt(path) when is_binary(path) do
    case File.read(path) do
      {:ok, raw} ->
        with {:ok, json} <- Jason.decode(raw),
             :ok <- validate_receipt_shape(json) do
          {:ok, json}
        else
          {:error, reason} -> {:error, {:malformed_receipt, reason}}
        end

      {:error, reason} ->
        {:error, {:receipt_unreadable, reason}}
    end
  end

  defp validate_receipt_shape(%{
         "schema_version" => 1,
         "launch_id" => launch_id,
         "tree_drained" => tree_drained,
         "terminal_reason" => terminal_reason,
         "termination_mode" => termination_mode
       })
       when is_binary(launch_id) and is_boolean(tree_drained) and is_binary(terminal_reason) and
              is_binary(termination_mode) do
    :ok
  end

  defp validate_receipt_shape(_other), do: {:error, :invalid_receipt_shape}

  @doc """
  The positive-death gate over receipt evidence. Only a receipt that proves the
  tree drained (job accounting ActiveProcesses == 0) with a conclusive
  terminal reason yields `:TERMINATED_CONFIRMED`.
  """
  @spec classify_receipt(map()) :: status()
  def classify_receipt(%{"tree_drained" => true, "terminal_reason" => reason}) do
    if MapSet.member?(@confirmed_reasons, reason) do
      :TERMINATED_CONFIRMED
    else
      :TERMINATION_UNCONFIRMED
    end
  end

  def classify_receipt(_other), do: :TERMINATION_UNCONFIRMED

  @doc """
  Receipt-backed verification of a persisted worker identity, used by the
  WorkerFence during restart reconciliation. The receipt file must live inside
  the managed receipt directory, parse as a valid receipt, prove the drain, and
  carry the identity's launch id. Anything else is UNKNOWN (fail closed).
  """
  @spec verify_identity_receipt(term()) :: SymphonyElixir.WorkerFence.verdict()
  def verify_identity_receipt(%{"receipt_path" => path, "launch_id" => launch_id})
      when is_binary(path) and is_binary(launch_id) do
    if receipt_under_managed_dir?(path) do
      case parse_receipt(path) do
        {:ok, receipt} ->
          if receipt["launch_id"] == launch_id and classify_receipt(receipt) == :TERMINATED_CONFIRMED do
            {:ok, :dead}
          else
            {:error, :unknown}
          end

        {:error, _reason} ->
          {:error, :unknown}
      end
    else
      Logger.warning("Worker identity receipt path outside managed receipt dir; failing closed")
      {:error, :unknown}
    end
  end

  def verify_identity_receipt(_other), do: {:error, :unknown}

  defp receipt_under_managed_dir?(path) do
    managed = receipt_dir() |> Path.expand() |> normalize_path()
    candidate = path |> Path.expand() |> normalize_path()
    String.starts_with?(candidate, managed <> "\\") or String.starts_with?(candidate, managed <> "/")
  end

  defp normalize_path(path) do
    case :os.type() do
      {:win32, _} -> String.replace(String.downcase(path), "/", "\\")
      _ -> path
    end
  end

  # ---------------------------------------------------------------------------
  # Gate verdicts shared by the Orchestrator retry/cleanup decisions
  # ---------------------------------------------------------------------------

  @doc """
  May the runtime proceed with workspace reuse / redispatch / cleanup after the
  previous worker on this workspace ended? `nil` confirmations (remote workers,
  non-Windows hosts, containment disabled) are gate-NOT-APPLICABLE and keep the
  previous behavior; only explicit `:TERMINATION_UNCONFIRMED` evidence blocks.
  """
  @spec reuse_gate(confirmation() | nil) :: :allowed | {:blocked, :worker_termination_unconfirmed}
  def reuse_gate(nil), do: :allowed

  def reuse_gate(%{status: status}) do
    case status do
      :TERMINATION_UNCONFIRMED -> {:blocked, :worker_termination_unconfirmed}
      _ -> :allowed
    end
  end

  def reuse_gate(_other), do: :allowed
end
