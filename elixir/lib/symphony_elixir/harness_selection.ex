defmodule SymphonyElixir.HarnessSelection do
  @moduledoc """
  Pure harness-selection policy for the OpenCode pilot gate.

  Answers one question for an already-decided dispatch: may this issue run on
  the OpenCode harness, or does it stay on the default Codex harness?

  The policy is pure. It reads only its two arguments and returns a decision.
  It launches no process, writes no file, mutates no worker or orchestrator
  state, reads no runtime configuration, and bypasses no existing dispatch,
  retry, or containment gate. Codex is the default harness, and it is also the
  fail-closed answer for every disabled, incomplete, unauthorized, or unusable
  configuration.

  Selecting OpenCode requires all of:

    * `opencode.enabled` is `true`;
    * the section names a non-blank `provider` and `model`;
    * the section names at least one allowed tool;
    * the issue identifier is listed in `allowed_issues`.

  An empty or missing `allowed_issues` list authorizes no issue, so an enabled
  section without one never reaches OpenCode. There is no provider fallback and
  no alternate OpenCode provider: the only alternative to OpenCode is the
  default Codex harness.

  This module classifies intent only. Wiring the decision into dispatch is a
  separate, later step; the caller keeps ownership of the dispatch, retry,
  containment, and worker-lifecycle gates.
  """

  alias Ecto.Changeset
  alias SymphonyElixir.Config.Schema.OpenCode
  alias SymphonyElixir.Tracker.Issue

  @type harness :: :codex | :opencode

  @type reason ::
          :default_harness
          | :opencode_disabled
          | :opencode_incomplete
          | :issue_not_authorized
          | :invalid_opencode_config
          | :opencode_selected

  @doc """
  Selects the harness for an issue under the supplied OpenCode pilot settings.

  Returns `{:opencode, :opencode_selected}` only when the pilot is explicitly
  enabled and the issue is authorized. Every other outcome is
  `{:codex, reason}`, so a caller can branch on the first element and never
  needs a fallback path.

  `settings` is the validated `opencode` schema section, a plain map with the
  same keys, or `nil`. A plain map is normalized through the schema changeset;
  a map the schema rejects fails closed as `:invalid_opencode_config`.
  """
  @spec select(Issue.t() | nil, OpenCode.t() | map() | nil) :: {harness(), reason()}
  def select(issue, settings) do
    with {:ok, opencode} <- normalize(settings),
         :ok <- authorized(opencode, issue) do
      {:opencode, :opencode_selected}
    else
      {:error, reason} -> {:codex, reason}
    end
  end

  defp normalize(nil), do: {:error, :opencode_disabled}

  defp normalize(%OpenCode{} = opencode), do: {:ok, opencode}

  defp normalize(settings) when is_map(settings) do
    case OpenCode.changeset(%OpenCode{}, settings) |> Changeset.apply_action(:validate) do
      {:ok, %OpenCode{} = opencode} -> {:ok, opencode}
      {:error, _changeset} -> {:error, :invalid_opencode_config}
    end
  end

  defp normalize(_settings), do: {:error, :invalid_opencode_config}

  defp authorized(%OpenCode{} = opencode, issue) do
    with :ok <- ensure_enabled(opencode),
         :ok <- ensure_identity(opencode),
         :ok <- ensure_tool_allowlist(opencode),
         {:ok, identifier} <- issue_identifier(issue) do
      ensure_authorized_issue(identifier, opencode)
    end
  end

  defp ensure_enabled(%OpenCode{enabled: true}), do: :ok
  defp ensure_enabled(%OpenCode{}), do: {:error, :opencode_disabled}

  defp ensure_identity(%OpenCode{provider: provider, model: model}) do
    if nonblank?(provider) and nonblank?(model) do
      :ok
    else
      {:error, :opencode_incomplete}
    end
  end

  defp ensure_tool_allowlist(%OpenCode{allowed_tools: tools}) do
    if is_list(tools) and Enum.any?(tools, &nonblank?/1) do
      :ok
    else
      {:error, :opencode_incomplete}
    end
  end

  defp issue_identifier(%Issue{identifier: identifier}) do
    if nonblank?(identifier) do
      {:ok, normalize_name(identifier)}
    else
      {:error, :issue_not_authorized}
    end
  end

  defp issue_identifier(_issue), do: {:error, :issue_not_authorized}

  defp ensure_authorized_issue(identifier, %OpenCode{allowed_issues: allowed}) do
    if is_list(allowed) and identifier in Enum.map(allowed, &normalize_name/1) do
      :ok
    else
      {:error, :issue_not_authorized}
    end
  end

  defp normalize_name(value), do: value |> to_string() |> String.trim() |> String.downcase()

  defp nonblank?(value), do: is_binary(value) and String.trim(value) != ""
end
