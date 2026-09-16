defmodule SymphonyElixir.Control do
  @moduledoc """
  Host-owned worker lifecycle CONTROL — the authority half of the
  STEER != CONTROL separation (MIC-10 / MIC-9).

  CONTROL is a host/operator/runtime lifecycle action that affects execution
  itself. Text intended for the currently-running worker model is STEER and
  lives in `SymphonyElixir.Steering`; a worker-facing natural-language message
  must never carry lifecycle authority, so nothing in this module reads,
  parses, or can be reached by worker/model output. Worker model output must
  not be interpreted as authorization for terminate, restart, merge, or
  deploy: the only entry points into this module are host-side function calls
  made from trusted runtime/operator code inside the BEAM (today the test and
  operator lanes; any future HTTP/CLI surface must call exactly this API and
  add its own transport authentication in front of it).

  Verbs map onto lifecycle semantics that already exist in the runtime:

    - `:terminate` — stop the worker through the orchestrator's existing
      task-level stop, whose death closes the app-server port it owns
      (stdin EOF to the MIC-223 `jobrun` wrapper for contained launches).
      Termination confirmation is never inferred from task death alone: the
      attempt's MIC-223 termination evidence (the wrapper's receipt, under
      the predeclared termination expectation) decides whether the receipt
      reports `:terminated` or `:termination_unconfirmed`, and
      `WorkerContainment.reuse_gate/2` stays the only workspace-reuse
      authority.
    - `:relaunch` — start a replacement attempt through the orchestrator's
      existing retry envelope (revalidate against the tracker, schedule with
      backoff), gated on confirmed, attempt-bound termination evidence for
      the current attempt — never on an older attempt's successful receipt.
    - `:interrupt` — cancel the in-flight turn while keeping the session and
      process. The provider protocol surface this runtime implements exposes
      no host-initiated turn interruption (only inbound `turn/cancelled`
      notifications), so `:interrupt` requests are recorded and rejected
      fail-closed as `:rejected_interrupt_not_supported` instead of being
      silently mapped onto terminate.

  Every accepted request — including rejected ones — yields a bounded
  structured receipt so an operator can answer: what was requested, against
  which attempt, did it complete, and what evidence backs the outcome. A
  `:terminate` of a managed worker replies `:termination_pending` and is
  finalized asynchronously from the attempt's termination evidence; read the
  authoritative ledger back with `receipts/1`.
  """

  require Logger

  alias SymphonyElixir.Orchestrator

  @type action :: :interrupt | :relaunch | :terminate

  @supported_actions [:interrupt, :relaunch, :terminate]
  @executable_actions [:relaunch, :terminate]

  @type target :: %{
          required(:issue_id) => String.t(),
          optional(:attempt_id) => non_neg_integer() | :current
        }

  @type outcome ::
          :termination_pending
          | :terminated
          | :termination_unconfirmed
          | :relaunch_scheduled
          | :already_scheduled
          | :rejected_worker_not_running
          | :rejected_worker_still_running
          | :rejected_stale_attempt
          | :rejected_no_terminated_attempt
          | :rejected_interrupt_not_supported

  @type receipt :: %{
          control_id: String.t(),
          action: action(),
          issue_id: String.t() | nil,
          attempt_id: non_neg_integer() | nil,
          requested_at: DateTime.t(),
          requested_by: term(),
          completed_at: DateTime.t() | nil,
          outcome: outcome() | {:invalid_request, term()},
          evidence: map()
        }

  @call_timeout_ms 15_000

  @doc """
  Verbs this contract recognizes. `:interrupt` is recognized but not
  executable on the current provider surface; see the moduledoc.
  """
  @spec supported_actions() :: [action(), ...]
  def supported_actions, do: @supported_actions

  @doc """
  Verbs the runtime can actually execute today.
  """
  @spec executable_actions() :: [action(), ...]
  def executable_actions, do: @executable_actions

  @doc """
  Requests a host-owned lifecycle action against one attempt of one issue.

  Attempt identity follows the runtime's existing attempt contract (the
  MIC-195 retry attempt: `0` is the first dispatch, `N` is retry N).
  `:current` is resolved server-side, atomically with execution, against the
  current/latest authoritative attempt — it never selects an older attempt's
  receipt.

  Returns `{:ok, receipt}` for every request that reaches the orchestrator —
  `receipt.outcome` carries the bounded result, including rejections. Shape
  failures (unknown action, malformed target) fail closed before any
  orchestrator state is touched and are not recorded, because they do not
  identify a target the ledger can describe.
  """
  @spec request(action(), term(), keyword()) :: {:ok, receipt()} | {:error, {:invalid_request, term()}}
  def request(action, target, opts \\ [])

  def request(action, target, opts) when is_atom(action) and is_map(target) and is_list(opts) do
    with :ok <- validate_action(action),
         {:ok, issue_id} <- validate_target(target) do
      request = %{
        action: action,
        issue_id: issue_id,
        attempt_id: Map.get(target, :attempt_id, :current),
        requested_by: Keyword.get(opts, :requested_by, :host_operator)
      }

      GenServer.call(server(opts), {:control_request, request}, @call_timeout_ms)
    end
  end

  def request(_action, _target, _opts), do: {:error, {:invalid_request, :malformed_request}}

  @doc """
  Reads the bounded control receipt ledger from the orchestrator.
  """
  @spec receipts(GenServer.server()) :: [receipt()] | :unavailable
  def receipts(server \\ Orchestrator) do
    if server_available?(server) do
      GenServer.call(server, :control_receipts, @call_timeout_ms)
    else
      :unavailable
    end
  end

  defp server_available?(server) when is_pid(server), do: Process.alive?(server)
  defp server_available?(server), do: Process.whereis(server) != nil

  defp validate_action(action) when action in @supported_actions, do: :ok
  defp validate_action(action), do: {:error, {:invalid_request, {:unsupported_action, action}}}

  defp validate_target(%{issue_id: issue_id} = target) when is_map(target) do
    with {:ok, _} <- validate_issue_id(issue_id),
         :ok <- validate_attempt_id(Map.get(target, :attempt_id, :current)) do
      {:ok, issue_id}
    end
  end

  defp validate_target(_target), do: {:error, {:invalid_request, :target_must_be_map_with_issue_id}}

  defp validate_issue_id(issue_id) when is_binary(issue_id) do
    if String.trim(issue_id) == "" do
      {:error, {:invalid_request, :issue_id_must_not_be_empty}}
    else
      {:ok, issue_id}
    end
  end

  defp validate_issue_id(_issue_id), do: {:error, {:invalid_request, :issue_id_must_be_binary}}

  # The runtime's attempt contract is the normalized MIC-195 retry attempt:
  # non-negative, with 0 as the first dispatch (Orchestrator.normalize_retry_attempt).
  defp validate_attempt_id(:current), do: :ok
  defp validate_attempt_id(attempt_id) when is_integer(attempt_id) and attempt_id >= 0, do: :ok
  defp validate_attempt_id(_attempt_id), do: {:error, {:invalid_request, :attempt_id_must_be_non_negative_integer_or_current}}

  defp server(opts), do: Keyword.get(opts, :server, Orchestrator)
end
