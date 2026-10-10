defmodule SymphonyElixir.TestSupport.OpenCodeWorkerFixture do
  @moduledoc """
  Deterministic test fixture and harness for Symphony's OpenCode worker integration (M1).

  Provides:
  - Bounded mock worker executable building and invocation.
  - Deterministic event generation and incremental parsing for all M1 scenarios:
      * successful single-turn execution
      * multi-step execution
      * tool failure
      * malformed JSONL
      * stalled execution
      * interrupted execution
      * confirmed and unconfirmed process termination
  - Cumulative token and cost accounting verification across multi-step turns.
  - Windows Job Object containment and process termination assertions.
  - No orphaned process verification via OS tasklist probing.
  - LaunchMarker lifecycle gate verification (pre-launch record, wrapper pid refresh,
    confirmed cleanup, fail-closed unconfirmed retention).
  - Issue-to-worker routing resolution and fail-safe rollback to Codex.
  """

  alias SymphonyElixir.LaunchMarker
  alias SymphonyElixir.TestSupport.MockOpenCode
  alias SymphonyElixir.Tracker.Issue
  alias SymphonyElixir.WorkerContainment

  # ---------------------------------------------------------------------------
  # Fixture Build & Path
  # ---------------------------------------------------------------------------

  @spec ensure_built!() :: String.t()
  def ensure_built!, do: MockOpenCode.ensure_built!()

  @spec exe_path() :: String.t()
  def exe_path, do: MockOpenCode.exe_path()

  # ---------------------------------------------------------------------------
  # Event Generators (JSONL strings)
  # ---------------------------------------------------------------------------

  @spec single_turn_jsonl(keyword()) :: String.t()
  def single_turn_jsonl(opts \\ []) do
    session_id = Keyword.get(opts, :session_id, "ses_mock_single")
    tokens_in = Keyword.get(opts, :tokens_in, 100)
    tokens_out = Keyword.get(opts, :tokens_out, 200)
    reasoning = Keyword.get(opts, :reasoning, 25)
    cache_read = Keyword.get(opts, :cache_read, 50)
    cache_write = Keyword.get(opts, :cache_write, 10)
    cost = Keyword.get(opts, :cost, 0.005)

    [
      Jason.encode!(%{
        "type" => "step_start",
        "timestamp" => 1_700_000_000_000,
        "sessionID" => session_id,
        "part" => %{
          "type" => "step-start",
          "id" => "step_s1",
          "sessionID" => session_id,
          "messageID" => "msg_01"
        }
      }),
      Jason.encode!(%{
        "type" => "tool_use",
        "timestamp" => 1_700_000_000_100,
        "sessionID" => session_id,
        "part" => %{
          "type" => "tool",
          "id" => "toolu_01",
          "sessionID" => session_id,
          "messageID" => "msg_01",
          "tool" => "read",
          "callID" => "call_99",
          "state" => %{
            "status" => "completed",
            "output" => "file contents"
          }
        }
      }),
      Jason.encode!(%{
        "type" => "step_finish",
        "timestamp" => 1_700_000_000_200,
        "sessionID" => session_id,
        "part" => %{
          "type" => "step-finish",
          "id" => "step_f1",
          "sessionID" => session_id,
          "messageID" => "msg_01",
          "reason" => "stop",
          "cost" => cost,
          "tokens" => %{
            "input" => tokens_in,
            "output" => tokens_out,
            "reasoning" => reasoning,
            "cache" => %{"read" => cache_read, "write" => cache_write}
          }
        }
      })
    ]
    |> Enum.join("
")
    |> Kernel.<>("
")
  end

  @spec multi_step_jsonl(keyword()) :: String.t()
  def multi_step_jsonl(opts \\ []) do
    session_id = Keyword.get(opts, :session_id, "ses_mock_multi")

    [
      # Step 1: Intermediate step finish with "tool-calls" reason
      Jason.encode!(%{
        "type" => "step_start",
        "timestamp" => 1_700_000_000_000,
        "sessionID" => session_id,
        "part" => %{
          "type" => "step-start",
          "id" => "step_s1",
          "sessionID" => session_id,
          "messageID" => "msg_01"
        }
      }),
      Jason.encode!(%{
        "type" => "step_finish",
        "timestamp" => 1_700_000_000_100,
        "sessionID" => session_id,
        "part" => %{
          "type" => "step-finish",
          "id" => "step_f1",
          "sessionID" => session_id,
          "messageID" => "msg_01",
          "reason" => "tool-calls",
          "cost" => 0.002,
          "tokens" => %{
            "input" => 40,
            "output" => 60,
            "reasoning" => 10,
            "cache" => %{"read" => 5, "write" => 5}
          }
        }
      }),
      Jason.encode!(%{
        "type" => "tool_use",
        "timestamp" => 1_700_000_000_150,
        "sessionID" => session_id,
        "part" => %{
          "type" => "tool",
          "id" => "toolu_01",
          "sessionID" => session_id,
          "messageID" => "msg_01",
          "tool" => "read",
          "callID" => "call_99",
          "state" => %{"status" => "completed", "output" => "intermediate contents"}
        }
      }),
      # Step 2: Final terminal step finish with "stop" reason
      Jason.encode!(%{
        "type" => "step_start",
        "timestamp" => 1_700_000_000_200,
        "sessionID" => session_id,
        "part" => %{
          "type" => "step-start",
          "id" => "step_s2",
          "sessionID" => session_id,
          "messageID" => "msg_02"
        }
      }),
      Jason.encode!(%{
        "type" => "step_finish",
        "timestamp" => 1_700_000_000_300,
        "sessionID" => session_id,
        "part" => %{
          "type" => "step-finish",
          "id" => "step_f2",
          "sessionID" => session_id,
          "messageID" => "msg_02",
          "reason" => "stop",
          "cost" => 0.003,
          "tokens" => %{
            "input" => 60,
            "output" => 90,
            "reasoning" => 15,
            "cache" => %{"read" => 10, "write" => 5}
          }
        }
      })
    ]
    |> Enum.join("
")
    |> Kernel.<>("
")
  end

  @spec tool_failure_jsonl(keyword()) :: String.t()
  def tool_failure_jsonl(opts \\ []) do
    session_id = Keyword.get(opts, :session_id, "ses_mock_tool_fail")
    error_msg = Keyword.get(opts, :error, "permission denied: cannot read file")

    [
      Jason.encode!(%{
        "type" => "step_start",
        "timestamp" => 1_700_000_000_000,
        "sessionID" => session_id,
        "part" => %{
          "type" => "step-start",
          "id" => "step_s1",
          "sessionID" => session_id,
          "messageID" => "msg_err"
        }
      }),
      Jason.encode!(%{
        "type" => "tool_use",
        "timestamp" => 1_700_000_000_100,
        "sessionID" => session_id,
        "part" => %{
          "type" => "tool",
          "id" => "toolu_err",
          "sessionID" => session_id,
          "messageID" => "msg_err",
          "tool" => "read",
          "callID" => "call_err",
          "state" => %{
            "status" => "error",
            "error" => error_msg
          }
        }
      }),
      Jason.encode!(%{
        "type" => "step_finish",
        "timestamp" => 1_700_000_000_200,
        "sessionID" => session_id,
        "part" => %{
          "type" => "step-finish",
          "id" => "step_f1",
          "sessionID" => session_id,
          "messageID" => "msg_err",
          "reason" => "stop",
          "cost" => 0.005,
          "tokens" => %{
            "input" => 100,
            "output" => 200,
            "reasoning" => 25,
            "cache" => %{"read" => 50, "write" => 10}
          }
        }
      })
    ]
    |> Enum.join("
")
    |> Kernel.<>("
")
  end

  @spec malformed_jsonl(keyword()) :: String.t()
  def malformed_jsonl(opts \\ []) do
    secret = Keyword.get(opts, :secret, "sk-ant-api03-abcdefghijklmnopqrstuvwxyz LINEAR_API_KEY=lin_api_abcdefghijklmnopqrstuvwxyz")

    """
    not-json-line-corrupted-stream
    {"type":"tool_use","broken":"#{secret}
    """ <> single_turn_jsonl(opts)
  end

  # ---------------------------------------------------------------------------
  # Cumulative Token & Cost Accounting
  # ---------------------------------------------------------------------------

  @doc """
  Calculates cumulative token usage and cost across all step_finish events in JSONL text or map stream.
  """
  @spec calculate_cumulative_usage(String.t() | [map()]) :: map()
  def calculate_cumulative_usage(jsonl_or_events) when is_binary(jsonl_or_events) do
    events =
      jsonl_or_events
      |> String.split(["
", "
"], trim: true)
      |> Enum.flat_map(fn line ->
        case Jason.decode(line) do
          {:ok, map} -> [map]
          _ -> []
        end
      end)

    calculate_cumulative_usage(events)
  end

  def calculate_cumulative_usage(events) when is_list(events) do
    Enum.reduce(events, initial_usage(), fn event, acc ->
      if Map.get(event, "type") == "step_finish" do
        part = Map.get(event, "part", %{})
        tokens = Map.get(part, "tokens", %{})
        cache = Map.get(tokens, "cache", %{})
        cost = Map.get(part, "cost", 0.0)

        in_tok = Map.get(tokens, "input", 0)
        out_tok = Map.get(tokens, "output", 0)
        reas_tok = Map.get(tokens, "reasoning", 0)
        cache_r = Map.get(cache, "read", 0)
        cache_w = Map.get(cache, "write", 0)

        %{
          acc
          | input_tokens: acc.input_tokens + in_tok,
            output_tokens: acc.output_tokens + out_tok,
            reasoning_tokens: acc.reasoning_tokens + reas_tok,
            cache_read_tokens: acc.cache_read_tokens + cache_r,
            cache_write_tokens: acc.cache_write_tokens + cache_w,
            total_tokens: acc.total_tokens + in_tok + out_tok,
            cost: Float.round(acc.cost + cost, 6)
        }
      else
        acc
      end
    end)
  end

  defp initial_usage do
    %{
      input_tokens: 0,
      output_tokens: 0,
      reasoning_tokens: 0,
      cache_read_tokens: 0,
      cache_write_tokens: 0,
      total_tokens: 0,
      cost: 0.0
    }
  end

  # ---------------------------------------------------------------------------
  # Process Execution & Windows Job Object Containment
  # ---------------------------------------------------------------------------

  @doc """
  Writes control file for mock_opencode.exe.
  """
  @spec write_control_file(Path.t(), keyword()) :: Path.t()
  def write_control_file(dir, opts) do
    lines =
      Enum.map(opts, fn {k, v} -> "#{k}=#{v}" end)
      |> Enum.join("
")

    path = Path.join(dir, "opencode-mock-control.txt")
    File.write!(path, lines <> "
")
    path
  end

  @doc """
  Runs mock_opencode.exe directly via System.cmd with given options.
  """
  @spec run_mock_direct(Path.t(), [String.t()], keyword()) :: {String.t(), integer()}
  def run_mock_direct(workspace, args, opts \\ []) do
    exe = ensure_built!()
    cmd_opts = [cd: workspace, stderr_to_stdout: Keyword.get(opts, :stderr_to_stdout, true)]
    System.cmd(exe, args, cmd_opts)
  end

  @doc """
  Spawns mock_opencode.exe contained within Symphony's jobrun Windows Job Object wrapper,
  pre-recording a LaunchMarker as required by the lifecycle contract.
  """
  @spec spawn_contained_worker(keyword()) :: %{
          port: port(),
          identity: map(),
          launch_id: String.t(),
          receipt_path: String.t(),
          wrapper_pid: integer() | nil,
          workspace: String.t()
        }
  def spawn_contained_worker(opts) do
    workspace = Keyword.fetch!(opts, :workspace)
    issue_id = Keyword.get(opts, :issue_id, "ISSUE-MOCK-#{System.unique_integer([:positive])}")
    attempt_id = Keyword.get(opts, :attempt_id, 1)
    mock_args = Keyword.get(opts, :mock_args, ["--mock-mode=success"])
    authority_root = Keyword.get(opts, :authority_root)

    # 1. Prepare containment identity
    identity =
      WorkerContainment.new_identity(
        issue_id: issue_id,
        attempt_id: attempt_id,
        workspace: workspace,
        worker_host: nil
      )

    identity =
      if authority_root do
        Map.put(identity, "authority_root", authority_root)
      else
        identity
      end

    # 2. Record LaunchMarker BEFORE child process can exist (fail-closed invariant)
    marker_opts = [
      identifier: issue_id,
      attempt_id: attempt_id
    ]

    marker_opts = if authority_root, do: Keyword.put(marker_opts, :root, authority_root), else: marker_opts

    case LaunchMarker.record(identity, marker_opts) do
      :ok -> :ok
      {:error, reason} -> raise "LaunchMarker pre-launch record failed: #{inspect(reason)}"
    end

    # 3. Build containment args for jobrun.exe
    exe = ensure_built!()
    launch_args = WorkerContainment.launch_args(identity, exe, mock_args)

    helper =
      case WorkerContainment.helper_path() do
        {:ok, p} -> p
        {:error, r} -> raise "Containment helper unavailable: #{inspect(r)}"
      end

    char_args =
      Enum.map(launch_args, fn
        arg when is_binary(arg) -> String.to_charlist(arg)
        arg when is_list(arg) -> arg
      end)

    port =
      Port.open(
        {:spawn_executable, String.to_charlist(helper)},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: char_args,
          cd: String.to_charlist(workspace)
        ]
      )

    wrapper_pid =
      case :erlang.port_info(port, :os_pid) do
        {:os_pid, pid} when is_integer(pid) -> pid
        {:os_pid, pid} when is_list(pid) -> List.to_integer(pid)
        _ -> nil
      end

    # 4. Record wrapper pid in LaunchMarker
    identity = if wrapper_pid, do: Map.put(identity, "wrapper_pid", to_string(wrapper_pid)), else: identity
    _ = LaunchMarker.record_wrapper_identity(identity, marker_opts)

    %{
      port: port,
      identity: identity,
      launch_id: Map.get(identity, "launch_id"),
      receipt_path: Map.get(identity, "receipt_path"),
      wrapper_pid: wrapper_pid,
      workspace: workspace
    }
  end

  @doc """
  Stops the contained worker and confirms positive termination receipt.
  """
  @spec stop_and_confirm_worker(map(), integer()) :: map()
  def stop_and_confirm_worker(%{port: port, identity: identity}, grace_ms \\ 2000) do
    WorkerContainment.stop_and_confirm(port, identity, grace_ms)
  end

  # ---------------------------------------------------------------------------
  # Orphan & Process Liveness Probing
  # ---------------------------------------------------------------------------

  @doc """
  Probes whether an OS PID is alive using Windows tasklist.
  """
  @spec pid_alive?(integer()) :: boolean()
  def pid_alive?(pid) when is_integer(pid) do
    {output, 0} =
      System.cmd("tasklist", ["/FI", "PID eq #{pid}", "/NH", "/FO", "CSV"], stderr_to_stdout: true)

    Regex.match?(~r/"#{pid}"/, output)
  end

  @doc """
  Awaits until the given PID exits, or times out. Returns true if gone, false if still alive.
  """
  @spec await_pid_gone(integer(), integer()) :: boolean()
  def await_pid_gone(pid, timeout_ms \\ 10_000) when is_integer(pid) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await_pid_gone(pid, deadline)
  end

  defp do_await_pid_gone(pid, deadline) do
    if pid_alive?(pid) do
      if System.monotonic_time(:millisecond) >= deadline do
        false
      else
        Process.sleep(100)
        do_await_pid_gone(pid, deadline)
      end
    else
      true
    end
  end

  @doc """
  Verifies that none of the provided PIDs are alive.
  """
  @spec assert_no_orphaned_processes([integer() | nil]) :: :ok | {:orphans_detected, [integer()]}
  def assert_no_orphaned_processes(pids) when is_list(pids) do
    valid_pids = Enum.reject(pids, &is_nil/1)

    alive =
      Enum.filter(valid_pids, fn pid ->
        not await_pid_gone(pid, 3000)
      end)

    if alive == [] do
      :ok
    else
      {:orphans_detected, alive}
    end
  end

  # ---------------------------------------------------------------------------
  # Routing & Codex Rollback
  # ---------------------------------------------------------------------------

  @doc """
  Simulates issue-to-worker routing resolution:
  - If opencode is enabled (via option or issue label) -> routes to OpenCode
  - If opencode is disabled -> rolls back cleanly to Codex default route (gpt-6-astra, medium)
  """
  @spec resolve_worker_route(keyword(), Issue.t() | nil) :: %{
          worker_type: :opencode | :codex,
          model: String.t(),
          reasoning_effort: String.t(),
          route_source: :default | :explicit_override
        }
  def resolve_worker_route(opts \\ [], issue \\ nil) do
    opencode_enabled = Keyword.get(opts, :opencode_enabled, false)
    issue_labels = if issue, do: issue.labels || [], else: []

    has_opencode_label? =
      Enum.any?(issue_labels, fn label ->
        is_binary(label) and String.downcase(String.trim(label)) in ["worker:opencode", "harness:opencode"]
      end)

    explicit_opencode? = Keyword.get(opts, :worker) == :opencode or has_opencode_label?

    if opencode_enabled and explicit_opencode? do
      model = Keyword.get(opts, :model) || extract_label_val(issue_labels, "model") || "claude-3-5-sonnet"

      %{
        worker_type: :opencode,
        model: model,
        reasoning_effort: "none",
        route_source: :explicit_override
      }
    else
      # Rollback to Codex route
      %{
        worker_type: :codex,
        model: "gpt-6-astra",
        reasoning_effort: "medium",
        route_source: :default
      }
    end
  end

  defp extract_label_val(labels, prefix) do
    prefix_lower = String.downcase(prefix) <> ":"

    Enum.find_value(labels, fn label ->
      if is_binary(label) and String.starts_with?(String.downcase(label), prefix_lower) do
        String.slice(label, String.length(prefix_lower)..-1//1) |> String.trim()
      end
    end)
  end
end

