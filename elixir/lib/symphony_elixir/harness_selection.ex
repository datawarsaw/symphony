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

    * `opencode.enabled` is exactly `true`. The schema rejects an explicit
      null, and any section that is not the literal `true` - disabled,
      defaulted, or otherwise - keeps Codex;
    * the section passes the `OpenCode` schema: a non-blank `provider` and
      `model`, at least one allowed tool, a timeout inside the supported budget,
      and no unrestricted or unknown tool;
    * the issue identifier is listed in `allowed_issues`.

  An empty or missing `allowed_issues` list authorizes no issue, so an enabled
  section without one never reaches OpenCode. There is no provider fallback and
  no alternate OpenCode provider: the only alternative to OpenCode is the
  default Codex harness.

  Decisions:

    * `{:opencode, :opencode_selected}` - run the OpenCode harness;
    * `{:codex, :opencode_disabled}` - no section, or the section is disabled;
    * `{:codex, :issue_not_authorized}` - an enabled, valid section that does
      not list this issue;
    * `{:codex, :invalid_opencode_config}` - an invalid section for an issue it
      does not list, which was never an OpenCode candidate;
    * `{:error, :invalid_opencode_config}` - an invalid section that still lists
      this issue. Codex is not a silent substitute for an intended OpenCode
      pilot, so the caller must fail closed and surface the configuration.

  This module classifies intent only. Wiring the decision into dispatch is a
  separate, later step; the caller keeps ownership of the dispatch, retry,
  containment, and worker-lifecycle gates.
  """

  alias SymphonyElixir.Config.Schema.OpenCode
  alias SymphonyElixir.Tracker.Issue

  @type harness :: :codex | :opencode

  @type reason ::
          :opencode_disabled
          | :issue_not_authorized
          | :invalid_opencode_config

  @type decision ::
          {:opencode, :opencode_selected}
          | {:codex, reason()}
          | {:error, :invalid_opencode_config}

  @doc """
  Selects the harness for an issue under the supplied OpenCode pilot settings.

  Returns `{:opencode, :opencode_selected}` only when the pilot is enabled
  with the literal `true`, validates, and the issue is authorized. A section
  whose `enabled` is not exactly `true` - disabled, defaulted, or an explicit
  null the schema rejects - never selects OpenCode. Otherwise it returns
  `{:codex, reason}`, so a caller can branch on the first element and normally
  needs no fallback path. One case returns `{:error, :invalid_opencode_config}`:
  an explicitly authorized issue whose section is invalid, where Codex is not a
  safe substitute and the caller must fail closed instead of launching.

  `settings` is the validated `opencode` schema section, a plain map with the
  same keys, or `nil`. Maps and already-built structs are both re-validated
  through the schema, so a hand-built struct cannot skip the tool or timeout
  checks.
  """
  @spec select(Issue.t() | nil, OpenCode.t() | map() | nil) :: decision()
  def select(issue, settings) do
    case normalize(settings) do
      {:ok, %OpenCode{enabled: true} = opencode} ->
        select_authorized(opencode, issue)

      {:ok, %OpenCode{}} ->
        {:codex, :opencode_disabled}

      :disabled ->
        {:codex, :opencode_disabled}

      :invalid ->
        invalid_config_decision(settings, issue)
    end
  end

  defp normalize(nil), do: :disabled

  defp normalize(settings) when is_map(settings) do
    case OpenCode.validate(settings) do
      {:ok, %OpenCode{} = opencode} -> {:ok, opencode}
      {:error, _changeset} -> :invalid
    end
  end

  defp normalize(_settings), do: :invalid

  defp select_authorized(%OpenCode{} = opencode, issue) do
    case issue_identifier(issue) do
      {:ok, identifier} ->
        if authorized_issue?(identifier, opencode.allowed_issues) do
          {:opencode, :opencode_selected}
        else
          {:codex, :issue_not_authorized}
        end

      {:error, :issue_not_authorized} ->
        {:codex, :issue_not_authorized}
    end
  end

  # An invalid section must not silently fall back to Codex while it still
  # names this issue: that is an intended OpenCode pilot with a broken
  # configuration, and the caller has to surface it.
  defp invalid_config_decision(settings, issue) do
    case issue_identifier(issue) do
      {:ok, identifier} ->
        if authorized_issue?(identifier, raw_allowed_issues(settings)) do
          {:error, :invalid_opencode_config}
        else
          {:codex, :invalid_opencode_config}
        end

      {:error, :issue_not_authorized} ->
        {:codex, :invalid_opencode_config}
    end
  end

  defp raw_allowed_issues(settings) when is_map(settings) do
    case Map.get(settings, :allowed_issues) || Map.get(settings, "allowed_issues") do
      issues when is_list(issues) -> issues
      _other -> []
    end
  end

  defp raw_allowed_issues(_settings), do: []

  defp authorized_issue?(identifier, allowed) when is_list(allowed) do
    Enum.any?(allowed, fn candidate ->
      nonblank?(candidate) and normalize_name(candidate) == identifier
    end)
  end

  defp authorized_issue?(_identifier, _allowed), do: false

  defp issue_identifier(%Issue{identifier: identifier}) do
    if nonblank?(identifier) do
      {:ok, normalize_name(identifier)}
    else
      {:error, :issue_not_authorized}
    end
  end

  defp issue_identifier(_issue), do: {:error, :issue_not_authorized}

  defp normalize_name(value), do: value |> to_string() |> String.trim() |> String.downcase()

  defp nonblank?(value), do: is_binary(value) and String.trim(value) != ""
end
