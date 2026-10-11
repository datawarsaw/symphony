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
  - Tri-state OS PID probing. A failed tasklist probe is `:unknown`, never death.
  - LaunchMarker lifecycle gate verification (pre-launch record, wrapper pid refresh,
    confirmed cleanup, fail-closed unconfirmed retention).
  - Fixture-only issue routing. This is not `DispatchRouter` selection.
  """

  alias SymphonyElixir.LaunchMarker
  alias SymphonyElixir.TestSupport.MockOpenCode
  alias SymphonyElixir.Tracker.Issue
  alias SymphonyElixir.WorkerContainment

  @raw_secret "sk-ant-api03-abcdefghijklmnopqrstuvwxyz"
  @raw_linear "lin_api_abcdefghijklmnopqrstuvwxyz"

  @type pid_liveness :: :alive | :gone | :unknown

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

    # tokens below match the v1.18.28 emitted CLI field set exactly
    # (publish-llm-event.ts builds input/output/reasoning/cache and never a
    # total). Fixtures that add "total" exercise the optional-schema case,
    # which the v1 schema permits but the CLI does not produce.
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
    secret = Keyword.get(opts, :secret, raw_secret_fixture())

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
"],
        trim: true
      )
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

        # Same contract as production accounting: the five wire categories are
        # non-overlapping, an explicit total is inclusive of all of them, and a
        # missing total is the additive sum.
        step_total =
          case Map.get(tokens, "total") do
            value when is_integer(value) and value >= 0 -> value
            _ -> in_tok + out_tok + reas_tok + cache_r + cache_w
          end

        %{
          acc
          | input_tokens: acc.input_tokens + in_tok,
            output_tokens: acc.output_tokens + out_tok,
            reasoning_tokens: acc.reasoning_tokens + reas_tok,
            cache_read_tokens: acc.cache_read_tokens + cache_r,
            cache_write_tokens: acc.cache_write_tokens + cache_w,
            total_tokens: acc.total_tokens + step_total,
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
  Tri-state OS PID probe aligned with `WorkerContainment.wrapper_liveness/1`.

  `:gone` requires a healthy tasklist answer that does not list the PID.
  A non-zero exit, a missing command, an exception, empty output, or CSV rows
  that do not carry the probed PID return `:unknown`. `:unknown` is not
  death. This function never raises.

  `probe` replaces the tasklist invocation in tests. It receives the argv
  and returns `{output, exit_code}`.
  """
  @spec pid_liveness(term(), keyword()) :: pid_liveness()
  def pid_liveness(pid, opts \\ [])

  def pid_liveness(pid, opts) when is_integer(pid) and pid > 0 and is_list(opts) do
    args = ["/FI", "PID eq #{pid}", "/NH", "/FO", "CSV"]
    probe = Keyword.get(opts, :probe, &default_tasklist_probe/1)

    probe_result =
      try do
        case probe.(args) do
          {output, 0} when is_binary(output) -> {:ok, output}
          _ -> :probe_failed
        end
      rescue
        _ -> :probe_failed
      catch
        _, _ -> :probe_failed
      end

    case probe_result do
      {:ok, output} -> classify_tasklist_output(pid, output)
      :probe_failed -> :unknown
    end
  end

  def pid_liveness(_pid, _opts), do: :unknown

  defp default_tasklist_probe(args) do
    System.cmd("tasklist", args, stderr_to_stdout: true)
  end

  # Same acceptance rule as WorkerContainment.wrapper_liveness/1: exit 0 with
  # no output, or quoted rows that are not the probed PID, is not absence.
  defp classify_tasklist_output(os_pid, output) do
    cond do
      Regex.match?(~r/"#{os_pid}"/, output) -> :alive
      output == "" -> :unknown
      String.contains?(output, "\"") -> :unknown
      true -> :gone
    end
  end

  @doc """
  Polls until tasklist positively reports the PID gone, or the timeout elapses.

  The return value is the tri-state itself. `:unknown` is never coerced to
  `:gone`.
  """
  @spec await_pid_liveness(integer(), keyword()) :: pid_liveness()
  def await_pid_liveness(pid, opts \\ []) when is_integer(pid) and is_list(opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, 10_000)
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await_pid_liveness(pid, opts, deadline)
  end

  defp do_await_pid_liveness(pid, opts, deadline) do
    case pid_liveness(pid, opts) do
      :gone ->
        :gone

      state ->
        if System.monotonic_time(:millisecond) >= deadline do
          state
        else
          Process.sleep(100)
          do_await_pid_liveness(pid, opts, deadline)
        end
    end
  end

  @doc """
  Verifies that every PID is positively gone.

  `:unknown` fails closed as `{:probe_unknown, pids}` and is not reported
  as a clean tree. Still-alive PIDs are `{:orphans_detected, pids}`.
  """
  @spec assert_no_orphaned_processes([integer() | nil], keyword()) ::
          :ok | {:orphans_detected, [integer()]} | {:probe_unknown, [integer()]}
  def assert_no_orphaned_processes(pids, opts \\ []) when is_list(pids) and is_list(opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, 3_000)
    probe_opts = Keyword.take(opts, [:probe])

    states =
      pids
      |> Enum.reject(&is_nil/1)
      |> Enum.map(fn pid ->
        {pid, await_pid_liveness(pid, Keyword.put(probe_opts, :timeout_ms, timeout_ms))}
      end)

    unknown = for {pid, :unknown} <- states, do: pid
    alive = for {pid, :alive} <- states, do: pid

    cond do
      unknown != [] -> {:probe_unknown, unknown}
      alive != [] -> {:orphans_detected, alive}
      true -> :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Routing & Codex Rollback
  # ---------------------------------------------------------------------------

  @doc """
  Fixture-only routing simulation.

  This does not call `SymphonyElixir.DispatchRouter`. On the accepted
  baseline that router materializes Codex `:primary` / `:fallback`
  selections and has no OpenCode worker type. A result from this function
  is not evidence that production selected an OpenCode worker or rolled
  back through the production router.
  """
  @spec resolve_worker_route(keyword(), Issue.t() | nil) :: %{
          authority: :fixture_only,
          production_dispatch_router: :not_consulted,
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
        authority: :fixture_only,
        production_dispatch_router: :not_consulted,
        worker_type: :opencode,
        model: model,
        reasoning_effort: "none",
        route_source: :explicit_override
      }
    else
      %{
        authority: :fixture_only,
        production_dispatch_router: :not_consulted,
        worker_type: :codex,
        model: "gpt-6-astra",
        reasoning_effort: "medium",
        route_source: :default
      }
    end
  end

  @doc """
  Raw secret literals emitted by the mock. They are fixture data, not
  evidence that a sanitizer ran.
  """
  @spec raw_secret_markers() :: %{anthropic: String.t(), linear: String.t()}
  def raw_secret_markers do
    %{anthropic: @raw_secret, linear: @raw_linear}
  end

  @spec raw_secret_fixture() :: String.t()
  def raw_secret_fixture, do: "#{@raw_secret} LINEAR_API_KEY=#{@raw_linear}"

  @doc """
  Scope label for the offline `error` mock. The process failure is
  observed here. The production no-fallback guarantee is not.
  """
  @spec process_failure_scope() :: %{observed: :process_failure, production_no_fallback: :unwired}
  def process_failure_scope do
    %{observed: :process_failure, production_no_fallback: :unwired}
  end

  @doc """
  Scope label for an interrupted mock process. Killing or exiting that
  process is not BEAM restart recovery.
  """
  @spec interruption_scope() :: %{
          kind: :simulated_process_exit,
          beam_restart_recovery: :not_exercised
        }
  def interruption_scope do
    %{kind: :simulated_process_exit, beam_restart_recovery: :not_exercised}
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
