defmodule SymphonyElixir.RepositoryRouter do
  @moduledoc """
  Resolves an issue's explicitly labelled repository target against the workflow allowlist.

  Repository discovery is intentionally not supported. Once routing is enabled, every dispatched
  issue must carry exactly one label with the configured prefix (for example,
  `repo:symphony-runtime`).
  """

  alias SymphonyElixir.Config.Schema.Routing
  alias SymphonyElixir.Tracker.Issue

  defmodule Route do
    @moduledoc false

    @enforce_keys [:target, :source_path, :default_branch]
    defstruct [:target, :source_path, :remote, :default_branch]

    @type t :: %__MODULE__{
            target: String.t(),
            source_path: Path.t(),
            remote: String.t() | nil,
            default_branch: String.t()
          }
  end

  @spec validate_config(Routing.t()) :: :ok | {:error, {:invalid_repository_routing, term()}}
  def validate_config(%Routing{targets: targets, target_label_prefix: prefix, default_branch: branch})
      when is_map(targets) and is_binary(prefix) and is_binary(branch) do
    cond do
      targets == %{} ->
        :ok

      String.trim(prefix) == "" ->
        {:error, {:invalid_repository_routing, :blank_target_label_prefix}}

      String.trim(branch) == "" ->
        {:error, {:invalid_repository_routing, :blank_default_branch}}

      true ->
        validate_targets(targets)
    end
  end

  @spec resolve(Issue.t(), Routing.t()) :: {:ok, Route.t() | nil} | {:error, term()}
  def resolve(%Issue{} = issue, %Routing{targets: targets} = routing) when is_map(targets) do
    case targets do
      targets when map_size(targets) == 0 ->
        {:ok, nil}

      _ ->
        resolve_target(issue.labels, routing)
    end
  end

  defp validate_targets(targets) do
    Enum.reduce_while(targets, :ok, fn {target, config}, :ok ->
      source_path = value(config, "source_path")

      cond do
        not valid_target?(target) ->
          {:halt, {:error, {:invalid_repository_routing, {:invalid_target, target}}}}

        not nonblank_string?(source_path) ->
          {:halt, {:error, {:invalid_repository_routing, {:missing_source_path, target}}}}

        not valid_optional_string?(value(config, "remote")) ->
          {:halt, {:error, {:invalid_repository_routing, {:invalid_remote, target}}}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp resolve_target(labels, %Routing{targets: targets, target_label_prefix: prefix, default_branch: branch}) do
    matching_targets =
      labels
      |> List.wrap()
      |> Enum.map(&normalize_label/1)
      |> Enum.filter(&String.starts_with?(&1, normalize_label(prefix)))
      |> Enum.map(&String.replace_prefix(&1, normalize_label(prefix), ""))
      |> Enum.uniq()

    case matching_targets do
      [] ->
        {:error, :missing_repository_target}

      [target] ->
        case Map.fetch(targets, target) do
          {:ok, config} ->
            {:ok,
             %Route{
               target: target,
               source_path: value(config, "source_path"),
               remote: value(config, "remote"),
               default_branch: branch
             }}

          :error ->
            {:error, {:unsupported_repository_target, target}}
        end

      targets ->
        {:error, {:ambiguous_repository_target, targets}}
    end
  end

  defp value(config, "source_path") when is_map(config),
    do: Map.get(config, "source_path") || Map.get(config, :source_path)

  defp value(config, "remote") when is_map(config), do: Map.get(config, "remote") || Map.get(config, :remote)
  defp value(_config, _key), do: nil

  defp valid_target?(target), do: nonblank_string?(target) and target == normalize_label(target)
  defp valid_optional_string?(nil), do: true
  defp valid_optional_string?(value), do: nonblank_string?(value)
  defp nonblank_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp normalize_label(label) when is_binary(label), do: label |> String.trim() |> String.downcase()
  defp normalize_label(_label), do: ""
end
