defmodule SymphonyElixir.Codex.WorkerRouting do
  @moduledoc """
  Resolves model and reasoning effort for normal Symphony implementation workers.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.Tracker.Issue

  @default_model "gpt-6-astra"
  @default_reasoning_effort "medium"

  @type route_source :: :default | :explicit_override

  @type route :: %{
          model: String.t(),
          reasoning_effort: String.t(),
          model_source: route_source(),
          reasoning_source: route_source(),
          route_source: route_source()
        }

  @type selection_evidence :: %{
          model: String.t(),
          reasoning_effort: String.t()
        }

  @spec default_model() :: String.t()
  def default_model, do: @default_model

  @spec default_reasoning_effort() :: String.t()
  def default_reasoning_effort, do: @default_reasoning_effort

  @spec resolve(keyword() | map(), Issue.t() | nil) :: route()
  def resolve(opts \\ [], issue \\ nil) do
    opts_map = if is_list(opts), do: Map.new(opts), else: opts

    {model, model_source} = resolve_model(opts_map, issue)
    {reasoning, reasoning_source} = resolve_reasoning_effort(opts_map, issue)

    route_source =
      if model_source == :explicit_override or reasoning_source == :explicit_override do
        :explicit_override
      else
        :default
      end

    %{
      model: model,
      reasoning_effort: reasoning,
      model_source: model_source,
      reasoning_source: reasoning_source,
      route_source: route_source
    }
  end

  @spec thread_overrides(route()) :: map()
  def thread_overrides(%{model: model, reasoning_effort: reasoning}) do
    %{
      "model" => model,
      "config" => %{
        "model_reasoning_effort" => reasoning
      }
    }
  end

  @spec validate_selection(map(), route()) ::
          {:ok, selection_evidence()} | {:error, term()}
  def validate_selection(response, %{model: expected_model, model_source: :explicit_override} = _route)
      when is_map(response) do
    actual_model = response["model"] || get_in(response, ["thread", "model"])

    if is_binary(actual_model) and actual_model != expected_model do
      {:error, {:model_override_unfulfilled, expected: expected_model, actual: actual_model}}
    else
      actual_reasoning =
        response["reasoningEffort"] || get_in(response, ["thread", "reasoningEffort"]) ||
          response["reasoning_effort"] || get_in(response, ["thread", "reasoning_effort"])

      {:ok, %{model: actual_model || expected_model, reasoning_effort: actual_reasoning || "medium"}}
    end
  end

  def validate_selection(response, %{model: expected_model, reasoning_effort: expected_reasoning})
      when is_map(response) do
    actual_model = response["model"] || get_in(response, ["thread", "model"]) || expected_model

    actual_reasoning =
      response["reasoningEffort"] || get_in(response, ["thread", "reasoningEffort"]) ||
        response["reasoning_effort"] || get_in(response, ["thread", "reasoning_effort"]) ||
        expected_reasoning

    {:ok, %{model: actual_model, reasoning_effort: actual_reasoning}}
  end

  def validate_selection(_other, _route), do: {:error, :invalid_thread_start_response}

  @spec parse_model_from_command(String.t() | nil) :: String.t() | nil
  def parse_model_from_command(command) when is_binary(command) do
    cond do
      match = Regex.run(~r/(?:--config|-c)\s+['"]?model="?([a-zA-Z0-9_.-]+)"?['"]?/, command) ->
        Enum.at(match, 1)

      match = Regex.run(~r/(?:--model|-m)\s+['"]?([a-zA-Z0-9_.-]+)['"]?/, command) ->
        Enum.at(match, 1)

      true ->
        nil
    end
  end

  def parse_model_from_command(_), do: nil

  @spec parse_reasoning_from_command(String.t() | nil) :: String.t() | nil
  def parse_reasoning_from_command(command) when is_binary(command) do
    case Regex.run(~r/(?:--config|-c)\s+['"]?model_reasoning_effort="?([a-zA-Z0-9_.-]+)"?['"]?/, command) do
      [_, effort] -> effort
      _ -> nil
    end
  end

  def parse_reasoning_from_command(_), do: nil

  defp resolve_model(opts, issue) do
    cond do
      explicit_opt = get_nonblank(opts, [:model, "model"]) ->
        {explicit_opt, :explicit_override}

      explicit_label = issue_label_value(issue, "model") ->
        {explicit_label, :explicit_override}

      true ->
        {configured_default_model(), :default}
    end
  end

  defp resolve_reasoning_effort(opts, issue) do
    cond do
      explicit_opt = get_nonblank(opts, [:reasoning_effort, "reasoning_effort", :reasoning, "reasoning"]) ->
        {explicit_opt, :explicit_override}

      explicit_label = issue_label_value(issue, "reasoning") ->
        {explicit_label, :explicit_override}

      true ->
        {configured_default_reasoning_effort(), :default}
    end
  end

  defp configured_default_model do
    case Config.settings() do
      {:ok, %{codex: %{default_model: model, command: command}}} ->
        cond do
          nonblank_string?(model) and model != @default_model ->
            model

          parsed_model = parse_model_from_command(command) ->
            parsed_model

          nonblank_string?(model) ->
            model

          true ->
            @default_model
        end

      _ ->
        @default_model
    end
  rescue
    _ -> @default_model
  end

  defp configured_default_reasoning_effort do
    case Config.settings() do
      {:ok, %{codex: %{default_reasoning_effort: effort, command: command}}} ->
        cond do
          nonblank_string?(effort) and effort != @default_reasoning_effort ->
            effort

          parsed_effort = parse_reasoning_from_command(command) ->
            parsed_effort

          nonblank_string?(effort) ->
            effort

          true ->
            @default_reasoning_effort
        end

      _ ->
        @default_reasoning_effort
    end
  rescue
    _ -> @default_reasoning_effort
  end

  defp issue_label_value(%Issue{labels: labels}, prefix) when is_list(labels) do
    prefix_lower = String.downcase(prefix) <> ":"

    Enum.find_value(labels, fn label ->
      if is_binary(label) do
        trimmed = String.trim(label)

        if String.starts_with?(String.downcase(trimmed), prefix_lower) do
          value = String.slice(trimmed, String.length(prefix_lower)..-1//1) |> String.trim()
          if value != "", do: value, else: nil
        end
      end
    end)
  end

  defp issue_label_value(_issue, _prefix), do: nil

  defp get_nonblank(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(map, key) do
        val when is_binary(val) ->
          trimmed = String.trim(val)
          if trimmed != "", do: trimmed, else: nil

        _ ->
          nil
      end
    end)
  end

  defp nonblank_string?(val), do: is_binary(val) and String.trim(val) != ""
end
