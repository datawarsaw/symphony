defmodule SymphonyElixir.OpenCode.Failure do
  @moduledoc """
  Maps OpenCode worker errors to Symphony's canonical failure taxonomy (FailureClass)
  without mutating shared classification modules.

  Canonical failure classes:
  - :provider_quota
  - :provider_rate_limit
  - :provider_outage
  - :model_unavailable
  - :auth_unavailable
  - :runtime_unavailable
  - :probe_environment_error
  - :probe_infrastructure_error
  - :transient_worker_failure
  - :persistent_worker_failure
  """

  alias SymphonyElixir.FailureClass
  alias SymphonyElixir.OpenCode.Redactor
  alias SymphonyElixir.FailureClass.FailureError

  @doc """
  Classifies an arbitrary OpenCode failure reason or error map into one of the ten
  canonical Symphony failure classes.
  """
  @spec classify(term()) :: FailureClass.t()
  def classify(%FailureError{failure_class: class}), do: FailureClass.normalize_class(class)

  def classify(%{failure_class: class}) when not is_nil(class) do
    FailureClass.normalize_class(class)
  end

  def classify(%{"failure_class" => class}) when not is_nil(class) do
    FailureClass.normalize_class(class)
  end

  def classify({:error, reason}), do: classify(reason)

  def classify(:timeout), do: :runtime_unavailable
  def classify({:timeout, _}), do: :runtime_unavailable
  def classify(:missing_provider), do: :persistent_worker_failure
  def classify(:missing_model), do: :persistent_worker_failure
  def classify(:unrestricted_permissions_forbidden), do: :persistent_worker_failure
  def classify(:invalid_model_selection), do: :persistent_worker_failure
  def classify({:invalid_model_selection, _}), do: :persistent_worker_failure
  def classify({:permission_denied, _}), do: :persistent_worker_failure
  def classify({:opencode_remote_host_ineligible, _}), do: :persistent_worker_failure

  def classify({:workspace_not_a_directory, _}), do: :probe_environment_error
  def classify({:outside_workspace, _, _}), do: :probe_environment_error
  def classify({:environment_directory_failed, _}), do: :probe_environment_error
  def classify({:config_write_failed, _}), do: :probe_environment_error
  def classify({:invalid_workspace, _}), do: :probe_environment_error

  def classify({:executable_not_found, _}), do: :probe_infrastructure_error
  def classify(:opencode_executable_not_found), do: :probe_infrastructure_error
  def classify({:opencode_executable_not_found, _}), do: :probe_infrastructure_error
  def classify(:stdio_host_unavailable), do: :probe_infrastructure_error
  def classify({:stdio_host_unavailable, _}), do: :probe_infrastructure_error
  def classify({:stdio_host_source_missing, _}), do: :probe_infrastructure_error
  def classify({:stdio_host_compile_failed, _, _}), do: :probe_infrastructure_error
  def classify(:csc_not_found), do: :probe_infrastructure_error
  def classify({:unknown_tool_permission, _}), do: :persistent_worker_failure
  def classify({:unauthorized_credential, _}), do: :persistent_worker_failure
  def classify({:incomplete_stream, _}), do: :persistent_worker_failure
  def classify({:malformed_json_line, _, _}), do: :persistent_worker_failure
  def classify(:termination_unconfirmed), do: :persistent_worker_failure
  def classify({:termination_unconfirmed, _}), do: :persistent_worker_failure
  def classify({:jobrun_helper_missing, _}), do: :probe_infrastructure_error
  def classify({:jobrun_helper_hash_mismatch, _, _, _}), do: :probe_infrastructure_error
  def classify({:jobrun_helper_unverified, _}), do: :probe_infrastructure_error
  def classify({:jobrun_compile_failed, _, _}), do: :probe_infrastructure_error
  def classify({:local_shell_start_failed, _}), do: :probe_infrastructure_error

  def classify({:terminal_reason, reason}), do: classify_finish_reason(reason)
  def classify({:finish_reason, reason}), do: classify_finish_reason(reason)

  def classify({:tool_error, _tool, error_detail}) do
    classify_text(inspect(error_detail), :persistent_worker_failure)
  end

  def classify({:error_event, error_map}) when is_map(error_map) do
    classify_error_map(error_map)
  end

  def classify({:process_exit, status}) when is_integer(status) and status != 0 do
    case status do
      254 -> :probe_infrastructure_error
      _ -> :transient_worker_failure
    end
  end

  def classify(%{} = map) do
    classify_error_map(map)
  end

  def classify(message) when is_binary(message) do
    classify_text(message, :transient_worker_failure)
  end

  def classify(_reason), do: :transient_worker_failure

  @doc """
  Constructs a structured failure information map aligned with Symphony's
  FailureClass interface.
  """
  @spec failure_info(term()) :: map()
  def failure_info(reason) do
    class = classify(reason)
    message = reason |> extract_message() |> Redactor.redact()
    reset_ms = extract_reset_in_ms(reason)

    %{
      failure_class: class,
      message: message,
      code: extract_code(reason),
      reset_after_ms: reset_ms,
      reset_in_ms: reset_ms,
      raw: Redactor.redact(reason)
    }
  end

  @doc """
  Builds a FailureError struct ready to be raised or handled by the runner.
  """
  @spec build_error(term(), keyword()) :: %FailureError{}
  def build_error(reason, opts \\ []) do
    info = failure_info(reason)
    class = Keyword.get(opts, :failure_class, info.failure_class)
    msg = Keyword.get(opts, :message, info.message)

    %FailureError{
      message: msg,
      failure_class: class,
      reason: reason,
      reset_in_ms: info.reset_in_ms
    }
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp classify_finish_reason("content-filter"), do: :persistent_worker_failure
  defp classify_finish_reason("length"), do: :transient_worker_failure
  defp classify_finish_reason("error"), do: :transient_worker_failure
  defp classify_finish_reason(_), do: :transient_worker_failure

  defp classify_error_map(map) do
    name = Map.get(map, "name") || Map.get(map, :name)
    data = Map.get(map, "data") || Map.get(map, :data) || %{}
    msg = Map.get(data, "message") || Map.get(data, :message) || Map.get(map, "message") || Map.get(map, :message)

    status =
      Map.get(map, "status") ||
        Map.get(map, :status) ||
        Map.get(data, "status") ||
        Map.get(data, :status) ||
        Map.get(data, "statusCode") ||
        Map.get(data, :statusCode) ||
        Map.get(map, "statusCode") ||
        Map.get(map, :statusCode)

    cond do
      status == 401 ->
        :auth_unavailable

      status == 403 ->
        :persistent_worker_failure

      status == 429 ->
        :provider_rate_limit

      status in [500, 502, 503, 504] ->
        :provider_outage

      name in ["AuthError", "UnauthorizedError", "ProviderAuthError"] ->
        :auth_unavailable

      name in ["ModelNotFoundError", "ModelNotFound"] ->
        :model_unavailable

      name in ["RateLimitError", "RateLimitExceeded"] ->
        :provider_rate_limit

      name in ["QuotaExceededError", "InsufficientQuotaError"] ->
        :provider_quota

      name in ["ServerError", "ProviderOutageError", "InternalServerError"] ->
        :provider_outage

      name in ["TimeoutError", "RequestTimeoutError"] ->
        :runtime_unavailable

      is_binary(msg) ->
        classify_text(msg, :transient_worker_failure)

      true ->
        :transient_worker_failure
    end
  end

  @auth_signals [
    ~r/\bunauthorized\b/,
    ~r/\bunauthenticated\b/,
    ~r/invalid api key/,
    ~r/invalid_api_key/,
    ~r/authentication failed/,
    ~r/\bauth error\b/,
    ~r/(?:http|status|error)\s+401\b/
  ]
  @permission_signals [
    ~r/permission denied/,
    ~r/permission auto-rejected/,
    ~r/auto-reject/,
    ~r/not permitted/,
    ~r/tool permission/,
    ~r/\bauto_approve\b/
  ]
  @model_signals [
    ~r/model not found/,
    ~r/model unavailable/,
    ~r/modelnotfound/,
    ~r/no such model/
  ]
  @quota_signals [~r/\bquota\b/, ~r/usage limit/, ~r/usage_limit/, ~r/usagelimit/]
  @rate_signals [
    ~r/rate limit/,
    ~r/rate_limit/,
    ~r/ratelimit/,
    ~r/too many requests/,
    ~r/(?:http|status|error)\s+429\b/
  ]
  @outage_signals [
    ~r/server error/,
    ~r/service unavailable/,
    ~r/bad gateway/,
    ~r/gateway timeout/,
    ~r/provider_outage/,
    ~r/(?:http|status|error)\s+50[0234]\b/
  ]
  @runtime_signals [
    ~r/\btimeout\b/,
    ~r/timed out/,
    ~r/connection refused/,
    ~r/connection reset/,
    ~r/transport error/
  ]
  @environment_signals [~r/outside_workspace/, ~r/workspace_not_a_directory/]
  @infrastructure_signals [~r/executable_not_found/, ~r/\bjobrun\b/, ~r/shell_start/]
  @forbidden_signals [
    ~r/\bforbidden\b/,
    ~r/(?:http|status|error)\s+403\b/
  ]

  defp classify_text(text, fallback) do
    normalized = String.downcase(text)
    auth? = signal?(normalized, @auth_signals)
    permission? = signal?(normalized, @permission_signals)

    cond do
      auth? and permission? ->
        :persistent_worker_failure

      signal?(normalized, @model_signals) ->
        :model_unavailable

      signal?(normalized, @quota_signals) ->
        :provider_quota

      signal?(normalized, @rate_signals) ->
        :provider_rate_limit

      auth? ->
        :auth_unavailable

      signal?(normalized, @outage_signals) ->
        :provider_outage

      permission? ->
        :persistent_worker_failure

      signal?(normalized, @runtime_signals) ->
        :runtime_unavailable

      signal?(normalized, @environment_signals) ->
        :probe_environment_error

      signal?(normalized, @infrastructure_signals) ->
        :probe_infrastructure_error

      signal?(normalized, @forbidden_signals) ->
        :persistent_worker_failure

      true ->
        fallback
    end
  end

  defp signal?(text, patterns), do: Enum.any?(patterns, &Regex.match?(&1, text))

  defp extract_message(reason) when is_binary(reason), do: reason
  defp extract_message(%FailureError{message: msg}), do: msg
  defp extract_message({:tool_error, tool, err}), do: "Tool #{tool} failed: #{inspect(err)}"
  defp extract_message({:malformed_json_line, line, _}), do: "Malformed JSON line: #{line}"
  defp extract_message(:timeout), do: "OpenCode worker execution timed out"
  defp extract_message({:timeout, detail}), do: "OpenCode worker execution timed out: #{inspect(detail)}"
  defp extract_message({:terminal_reason, reason}), do: "Ineligible terminal finish reason: #{reason}"
  defp extract_message({:finish_reason, reason}), do: "Ineligible finish reason: #{reason}"
  defp extract_message({:process_exit, status}), do: "OpenCode exited with status #{status}"

  defp extract_message({:opencode_remote_host_ineligible, worker_host}),
    do: "OpenCode harness is not eligible on remote worker host #{worker_host}; refused before launch"

  defp extract_message(%{} = map) do
    get_in(map, ["data", "message"]) ||
      get_in(map, [:data, :message]) ||
      Map.get(map, "message") ||
      Map.get(map, :message) ||
      inspect(map)
  end

  defp extract_message(reason), do: inspect(reason)

  defp extract_code(%{} = map) do
    Map.get(map, "code") || Map.get(map, :code) || Map.get(map, "name") || Map.get(map, :name)
  end

  defp extract_code(:timeout), do: "TIMEOUT"
  defp extract_code({:timeout, _}), do: "TIMEOUT"
  defp extract_code({:terminal_reason, reason}), do: String.upcase(to_string(reason))
  defp extract_code({:finish_reason, reason}), do: String.upcase(to_string(reason))
  defp extract_code(_), do: nil

  defp extract_reset_in_ms(%{} = map) do
    FailureClass.reset_in_ms(map)
  end

  defp extract_reset_in_ms(_), do: nil
end
