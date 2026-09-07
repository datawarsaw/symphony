defmodule SymphonyElixir.Discovery.Session do
  @moduledoc "Discovery-only app-server policy and structured technical failure classification."

  @primary %{provider: "xai", model: "xai/grok-4.6", reasoning: "medium"}
  @fallback %{provider: "google-antigravity", model: "google-antigravity/gemini-3.8-flash", reasoning: "medium"}

  @spec primary() :: map()
  def primary, do: @primary
  @spec fallback() :: map()
  def fallback, do: @fallback

  @spec thread_overrides(map(), map()) :: {:ok, map()} | {:error, atom()}
  def thread_overrides(config, route) when is_map(config) do
    servers = Map.get(config, "mcp_servers", %{})

    if is_map(servers) and Enum.all?(Map.keys(servers), &Regex.match?(~r/^[a-zA-Z0-9_-]+$/, &1)) do
      disabled = Map.new(servers, fn {name, _} -> {"mcp_servers.#{name}.enabled", false} end)

      {:ok,
       %{
         "model" => route.model,
         "sandbox" => "read-only",
         "approvalPolicy" => "never",
         "approvalsReviewer" => "user",
         "ephemeral" => true,
         "dynamicTools" => [],
         "selectedCapabilityRoots" => [],
         "config" =>
           Map.merge(disabled, %{
             "features.multi_agent" => false,
             "features.apps" => false,
             "features.plugins" => false,
             "features.memories" => false,
             "features.browser" => false,
             "web_search" => "disabled",
             "model_reasoning_effort" => route.reasoning,
             "shell_environment_policy.inherit" => "none",
             "project_doc_max_bytes" => 0
           })
       }}
    else
      {:error, :unsafe_discovery_mcp_configuration}
    end
  end

  @technical_codes %{
    "rate_limit_exceeded" => :rate_limit,
    "rateLimitExceeded" => :rate_limit,
    "authentication_error" => :authentication,
    "unauthorized" => :authentication,
    "insufficient_quota" => :quota,
    "usageLimitExceeded" => :quota,
    "quota_exceeded" => :quota,
    "model_not_found" => :model_unavailable,
    "model_unavailable" => :model_unavailable,
    "server_error" => :provider_outage,
    "internalServerError" => :provider_outage,
    "httpConnectionFailed" => :transport,
    "responseStreamConnectionFailed" => :transport,
    "responseStreamDisconnected" => :transport
  }
  @http_failures %{
    401 => :authentication,
    429 => :rate_limit,
    500 => :provider_outage,
    502 => :provider_outage,
    503 => :provider_outage,
    504 => :provider_outage
  }

  @spec technical_failure(term()) :: atom() | nil
  def technical_failure(:response_timeout), do: :transport
  def technical_failure(:turn_timeout), do: :transport
  def technical_failure({:port_exit, _}), do: :infrastructure
  def technical_failure({tag, reason}) when tag in [:error, :turn_failed, :response_error], do: technical_failure(reason)
  def technical_failure(reason) when is_binary(reason), do: Map.get(@technical_codes, reason)

  def technical_failure(reason) when is_map(reason) do
    code = Map.get(reason, "code") || Map.get(reason, "type")
    status = Map.get(reason, "httpStatusCode") || Map.get(reason, "status")
    Map.get(@technical_codes, code) || Map.get(@http_failures, status) || nested_failure(reason)
  end

  def technical_failure(_), do: nil

  defp nested_failure(reason) do
    Enum.find_value(["error", "codexErrorInfo", "turn", "data"], &technical_failure(Map.get(reason, &1))) ||
      Enum.find_value(Map.keys(reason), &Map.get(@technical_codes, &1))
  end
end
