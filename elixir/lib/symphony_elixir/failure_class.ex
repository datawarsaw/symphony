defmodule SymphonyElixir.FailureClass do
  @moduledoc """
  Canonical failure taxonomy, normalization, and classification primitives
  for MIC-195.

  Failure classes are atoms internally with stable serialized string names.
  Classification is a pure mapping over structured failure reasons. The
  orchestrator never parses RuntimeError strings as policy: string matching
  lives here and is applied once by AgentRunner at classification time.

  The retry/park envelope (stop rules, bounded-envelope history, and failure
  backoff) lives in `SymphonyElixir.RetryPolicy`.
  """

  @type t ::
          :provider_quota
          | :provider_rate_limit
          | :provider_outage
          | :model_unavailable
          | :auth_unavailable
          | :runtime_unavailable
          | :probe_environment_error
          | :probe_infrastructure_error
          | :transient_worker_failure
          | :persistent_worker_failure

  defmodule FailureError do
    @moduledoc """
    Classified worker failure raised by AgentRunner and consumed by the orchestrator.
    """

    defexception [:message, :failure_class, :reason, :reset_in_ms]

    @impl true
    def exception(opts) when is_list(opts) do
      failure_class = Keyword.get(opts, :failure_class, :transient_worker_failure)
      reason = Keyword.get(opts, :reason)
      reset_in_ms = Keyword.get(opts, :reset_in_ms)
      default_message = "classified worker failure (" <> inspect(failure_class) <> "): " <> inspect(reason)
      message = Keyword.get(opts, :message, default_message)

      %__MODULE__{
        message: message,
        failure_class: failure_class,
        reason: reason,
        reset_in_ms: reset_in_ms
      }
    end
  end

  @classes [
    :provider_quota,
    :provider_rate_limit,
    :provider_outage,
    :model_unavailable,
    :auth_unavailable,
    :runtime_unavailable,
    :probe_environment_error,
    :probe_infrastructure_error,
    :transient_worker_failure,
    :persistent_worker_failure
  ]

  @names %{
    provider_quota: "PROVIDER_QUOTA",
    provider_rate_limit: "PROVIDER_RATE_LIMIT",
    provider_outage: "PROVIDER_OUTAGE",
    model_unavailable: "MODEL_UNAVAILABLE",
    auth_unavailable: "AUTH_UNAVAILABLE",
    runtime_unavailable: "RUNTIME_UNAVAILABLE",
    probe_environment_error: "PROBE_ENVIRONMENT_ERROR",
    probe_infrastructure_error: "PROBE_INFRASTRUCTURE_ERROR",
    transient_worker_failure: "TRANSIENT_WORKER_FAILURE",
    persistent_worker_failure: "PERSISTENT_WORKER_FAILURE"
  }

  @by_name Map.new(@names, fn {class, name} -> {name, class} end)

  @atom_table %{
    provider_quota: :provider_quota,
    provider_rate_limit: :provider_rate_limit,
    provider_outage: :provider_outage,
    model_unavailable: :model_unavailable,
    auth_unavailable: :auth_unavailable,
    runtime_unavailable: :runtime_unavailable,
    probe_environment_error: :probe_environment_error,
    probe_infrastructure_error: :probe_infrastructure_error,
    transient_worker_failure: :transient_worker_failure,
    persistent_worker_failure: :persistent_worker_failure,
    quota: :provider_quota,
    rate_limit: :provider_rate_limit,
    rate_limited: :provider_rate_limit,
    authentication: :auth_unavailable,
    unauthorized: :auth_unavailable,
    forbidden: :auth_unavailable,
    transport: :runtime_unavailable,
    turn_timeout: :runtime_unavailable,
    response_timeout: :runtime_unavailable,
    infrastructure: :probe_infrastructure_error,
    port_exit: :probe_infrastructure_error,
    local_shell_start_failed: :probe_infrastructure_error,
    ssh_failed: :probe_infrastructure_error,
    ssh_error: :probe_infrastructure_error,
    discovery_lane_unavailable: :probe_infrastructure_error,
    discovery_config_unavailable: :probe_environment_error,
    discovery_model_selection_unverified: :probe_environment_error,
    discovery_input_unavailable: :probe_environment_error,
    unsafe_discovery_mcp_configuration: :probe_environment_error,
    unsafe_discovery_path: :probe_environment_error,
    invalid_thread_payload: :probe_environment_error,
    invalid_workspace_cwd: :probe_environment_error,
    path_canonicalize_failed: :probe_environment_error,
    workspace_repository_mismatch: :probe_environment_error,
    workspace_path_unreadable: :probe_environment_error,
    turn_cancelled: :persistent_worker_failure,
    approval_required: :persistent_worker_failure,
    turn_input_required: :persistent_worker_failure,
    stale_discovery_handoff: :persistent_worker_failure,
    invalid_discovery_handoff: :persistent_worker_failure,
    invalid_discovery_evidence: :persistent_worker_failure,
    discovery_not_ready: :persistent_worker_failure,
    issue_state_refresh_failed: :persistent_worker_failure
  }

  @code_table %{
    "rate_limit_exceeded" => :provider_rate_limit,
    "rateLimitExceeded" => :provider_rate_limit,
    "rate_limit" => :provider_rate_limit,
    "insufficient_quota" => :provider_quota,
    "usageLimitExceeded" => :provider_quota,
    "quota_exceeded" => :provider_quota,
    "quota" => :provider_quota,
    "authentication_error" => :auth_unavailable,
    "unauthorized" => :auth_unavailable,
    "authentication" => :auth_unavailable,
    "model_not_found" => :model_unavailable,
    "model_unavailable" => :model_unavailable,
    "server_error" => :provider_outage,
    "internalServerError" => :provider_outage,
    "provider_outage" => :provider_outage,
    "httpConnectionFailed" => :runtime_unavailable,
    "responseStreamConnectionFailed" => :runtime_unavailable,
    "responseStreamDisconnected" => :runtime_unavailable,
    "transport" => :runtime_unavailable,
    "infrastructure" => :probe_infrastructure_error,
    "environment" => :probe_environment_error,
    "persistent" => :persistent_worker_failure
  }

  @status_table %{
    401 => :auth_unavailable,
    429 => :provider_rate_limit,
    500 => :provider_outage,
    502 => :provider_outage,
    503 => :provider_outage,
    504 => :provider_outage
  }

  @reset_keys ["reset_at", "resetAt", "reset_in_ms", "reset_after_ms", "retry_after_ms", "retryAfterMs", "retry_after", "retryAfter"]

  @doc "All ten canonical failure classes."
  @spec all() :: [t()]
  def all, do: @classes

  @doc "Stable serialized string name for a failure class."
  @spec to_name(t()) :: String.t()
  def to_name(class) when class in @classes, do: Map.fetch!(@names, class)
  def to_name(_class), do: Map.fetch!(@names, :transient_worker_failure)

  @doc "Parse a serialized string name back to a failure class."
  @spec from_name(String.t()) :: {:ok, t()} | :error
  def from_name(name) when is_binary(name) do
    case Map.fetch(@by_name, name) do
      {:ok, class} -> {:ok, class}
      :error -> :error
    end
  end

  def from_name(_name), do: :error

  @doc "Normalize an arbitrary value to a canonical failure class."
  @spec normalize_class(term()) :: t()
  def normalize_class(class) when class in @classes, do: class

  def normalize_class(class) when is_binary(class) do
    case from_name(class) do
      {:ok, parsed} -> parsed
      :error -> :transient_worker_failure
    end
  end

  def normalize_class(class) when is_atom(class) do
    Map.get(@atom_table, class, :transient_worker_failure)
  end

  def normalize_class(_class), do: :transient_worker_failure

  @doc """
  Provider reset timing in milliseconds when reliably present on the failure.
  Returns nil unless a positive integer reset is explicitly provided; never invented.
  """
  @spec reset_in_ms(term()) :: pos_integer() | nil
  def reset_in_ms(%FailureError{reset_in_ms: ms}) when is_integer(ms) and ms > 0, do: ms
  def reset_in_ms(%FailureError{}), do: nil
  def reset_in_ms(%{failure_info: info}) when is_map(info), do: reset_in_ms(info)
  def reset_in_ms({error, _stack}) when is_map(error), do: reset_in_ms(error)
  def reset_in_ms(reason) when is_map(reason), do: reset_in_map(reason)
  def reset_in_ms({tag, detail}) when is_atom(tag), do: reset_in_ms(detail)
  def reset_in_ms(_reason), do: nil

  @doc "Classify a complete failed attempt into the canonical failure class."
  @spec classify(term()) :: t()
  def classify(%FailureError{failure_class: class}), do: normalize_class(class)
  def classify({%FailureError{} = error, _stack}), do: classify(error)
  def classify({%RuntimeError{message: message}, _stack}), do: classify_string(message)
  def classify(%RuntimeError{message: message}), do: classify_string(message)
  def classify({error, _stack}) when is_map(error), do: classify(error)
  def classify(class) when is_atom(class), do: Map.get(@atom_table, class, :transient_worker_failure)

  def classify({tag, detail}) when is_atom(tag) do
    case Map.fetch(@atom_table, tag) do
      {:ok, class} -> class
      :error -> classify(detail)
    end
  end

  def classify(reason) when is_binary(reason), do: classify_string(reason)
  def classify(reason) when is_map(reason), do: classify_map(reason)
  def classify(_reason), do: :transient_worker_failure

  defp classify_map(reason) do
    class_key = Map.get(reason, :failure_class, Map.get(reason, "failure_class"))
    code = Map.get(reason, :code, Map.get(reason, "code", Map.get(reason, :type, Map.get(reason, "type"))))
    status = Map.get(reason, :httpStatusCode, Map.get(reason, "httpStatusCode", Map.get(reason, :status, Map.get(reason, "status"))))
    nested = Map.get(reason, :reason, Map.get(reason, "reason", Map.get(reason, :error, Map.get(reason, "error"))))

    cond do
      not is_nil(class_key) -> normalize_class(class_key)
      not is_nil(code) -> classify_code(code)
      not is_nil(status) -> classify_status(status)
      not is_nil(nested) -> classify(nested)
      true -> :transient_worker_failure
    end
  end

  defp classify_code(code) when is_atom(code), do: Map.get(@atom_table, code, :transient_worker_failure)
  defp classify_code(code) when is_binary(code), do: Map.get(@code_table, code, :transient_worker_failure)
  defp classify_code(code) when is_integer(code), do: classify_status(code)
  defp classify_code(_code), do: :transient_worker_failure

  defp classify_status(status) when is_integer(status) do
    Map.get(@status_table, status, :transient_worker_failure)
  end

  defp classify_status(_status), do: :transient_worker_failure

  defp classify_string(reason) when is_binary(reason) do
    normalized = String.downcase(reason)

    cond do
      contains_any?(normalized, ["quota", "usage limit", "usage_limit", "usagelimit"]) ->
        :provider_quota

      contains_any?(normalized, ["rate limit", "rate_limit", "ratelimit", "too many requests", "429"]) ->
        :provider_rate_limit

      contains_any?(normalized, ["unauthorized", "authentication", "forbidden", "auth", "401", "403", "invalid api key", "invalid_api_key"]) ->
        :auth_unavailable

      contains_any?(normalized, ["model_not_found", "model unavailable", "model_unavailable", "model not found", "model"]) ->
        :model_unavailable

      contains_any?(normalized, ["server_error", "server error", "service unavailable", "bad gateway", "gateway timeout", "provider_outage", "outage", "500", "502", "503", "504"]) ->
        :provider_outage

      contains_any?(normalized, ["timeout", "timed out", "connection", "transport", "disconnected", "turn_timeout", "response_timeout"]) ->
        :runtime_unavailable

      contains_any?(normalized, ["workspace", "environment", "invalid_thread", "discovery_config", "unsafe_discovery", "outside_workspace", "workspace_root"]) ->
        :probe_environment_error

      contains_any?(normalized, ["infrastructure", "port_exit", "shell_start", "ssh"]) ->
        :probe_infrastructure_error

      contains_any?(normalized, ["cancelled", "canceled", "persistent", "approval_required", "input_required", "invalid_discovery", "stale_discovery", "refresh_failed"]) ->
        :persistent_worker_failure

      true ->
        :transient_worker_failure
    end
  end

  defp contains_any?(haystack, needles), do: Enum.any?(needles, &String.contains?(haystack, &1))

  defp reset_in_map(reason) do
    Enum.find_value(@reset_keys, fn key ->
      case Map.get(reason, key, Map.get(reason, String.to_atom(key), nil)) do
        value when is_integer(value) and value > 0 -> value
        _ -> nil
      end
    end)
  end
end
