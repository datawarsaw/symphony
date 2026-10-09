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

  def classify({:workspace_not_a_directory, _}), do: :probe_environment_error
  def classify({:outside_workspace, _, _}), do: :probe_environment_error
  def classify({:environment_directory_failed, _}), do: :probe_environment_error
  def classify({:config_write_failed, _}), do: :probe_environment_error
  def classify({:invalid_workspace, _}), do: :probe_environment_error

  def classify({:executable_not_found, _}), do: :probe_infrastructure_error
  def classify({:jobrun_helper_missing, _}), do: :probe_infrastructure_error
  def classify({:jobrun_helper_hash_mismatch, _, _, _}), do: :probe_infrastructure_error
  def classify({:jobrun_helper_unverified, _}), do: :probe_infrastructure_error
  def classify({:jobrun_compile_failed, _, _}), do: :probe_infrastructure_error
  def classify({:local_shell_start_failed, _}), do: :probe_infrastructure_error

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
    message = extract_message(reason)
    reset_ms = extract_reset_in_ms(reason)

    %{
      failure_class: class,
      message: message,
      code: extract_code(reason),
      reset_after_ms: reset_ms,
      reset_in_ms: reset_ms,
      raw: reason
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

  defp classify_error_map(map) do
    name = Map.get(map, "name") || Map.get(map, :name)
    data = Map.get(map, "data") || Map.get(map, :data) || %{}
    msg = Map.get(data, "message") || Map.get(data, :message) || Map.get(map, "message") || Map.get(map, :message)
    status = Map.get(map, "status") || Map.get(map, :status) || Map.get(data, "status")

    cond do
      status == 401 ->
        :auth_unavailable

      status == 429 ->
        :provider_rate_limit

      status in [500, 502, 503, 504] ->
        :provider_outage

      name in ["AuthError", "UnauthorizedError"] ->
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

  defp classify_text(text, fallback) do
    normalized = String.downcase(text)

    cond do
      contains_any?(normalized, ["model not found", "model unavailable", "modelnotfound", "no such model"]) ->
        :model_unavailable

      contains_any?(normalized, ["quota", "usage limit", "usage_limit", "usagelimit"]) ->
        :provider_quota

      contains_any?(normalized, ["rate limit", "rate_limit", "ratelimit", "too many requests", "429"]) ->
        :provider_rate_limit

      contains_any?(normalized, [
        "unauthorized",
        "authentication",
        "forbidden",
        "auth",
        "401",
        "403",
        "invalid api key",
        "invalid_api_key",
        "autherror"
      ]) ->
        :auth_unavailable

      contains_any?(normalized, ["server error", "service unavailable", "bad gateway", "gateway timeout", "provider_outage", "500", "502", "503", "504"]) ->
        :provider_outage

      contains_any?(normalized, ["timeout", "timed out", "connection", "transport", "disconnected"]) ->
        :runtime_unavailable

      contains_any?(normalized, ["permission", "auto-reject", "denied", "forbidden", "auto_approve"]) ->
        :persistent_worker_failure

      contains_any?(normalized, ["workspace", "environment", "outside_workspace"]) ->
        :probe_environment_error

      contains_any?(normalized, ["infrastructure", "jobrun", "shell_start", "executable_not_found"]) ->
        :probe_infrastructure_error

      true ->
        fallback
    end
  end

  defp contains_any?(haystack, needles) do
    Enum.any?(needles, &String.contains?(haystack, &1))
  end

  defp extract_message(reason) when is_binary(reason), do: reason
  defp extract_message(%FailureError{message: msg}), do: msg
  defp extract_message({:tool_error, tool, err}), do: "Tool #{tool} failed: #{inspect(err)}"
  defp extract_message({:malformed_json_line, line, _}), do: "Malformed JSON line: #{line}"
  defp extract_message({:process_exit, status}), do: "OpenCode exited with status #{status}"

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

  defp extract_code(_), do: nil

  defp extract_reset_in_ms(%{} = map) do
    FailureClass.reset_in_ms(map)
  end

  defp extract_reset_in_ms(_), do: nil
end
