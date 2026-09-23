defmodule SymphonyElixir.LaunchDiagnostics do
  @moduledoc """
  Read-only operator projection of the hardening-critical durable launch
  state: the per-issue launch marker, the termination receipt its stored
  identity points at, and the resume/cleanup fence verdict over that
  evidence.

  This module is observability only. It owns no state, holds no authority,
  and performs only reads (`File.read` through the existing stores). It can
  never clear a marker, repair or reinterpret durable state, or change a
  fence decision:

  - Marker and fence verdicts are produced by the authoritative
    implementations themselves (`LaunchMarker.read/2`,
    `LaunchMarker.reuse_gate/2`, `WorkerFence.confirm_termination_receipt/1`,
    `WorkerContainment.parse_receipt/1`) — this module only reshapes their
    results and never duplicates their policy.
  - The store root is resolved exactly as the runtime's fences resolve it
    (`:launch_marker_root` override, then the boot-pinned runtime authority
    root, then live configuration), so the projected fence verdict is the
    verdict the runtime's own gate would compute from the same store.
  - Evidence is classified `ABSENT`, `VALID`, `INVALID`, or `UNREADABLE`;
    anything unreadable or unproven is displayed fail-closed (a blocked or
    unknown fence) and never as safe. A diagnostic failure of the projection
    itself renders as fence `UNKNOWN` (`diagnostic_unavailable`), never as
    allowed.

  See `docs/launch_diagnostics.md` for the operator-facing field reference.
  """

  alias SymphonyElixir.{LaunchMarker, RuntimeLease, WorkerContainment, WorkerFence}

  @type diagnostics :: map()

  @doc """
  Read-only diagnostics for one issue's launch marker, termination receipt,
  and resume/cleanup fence verdict.

  Options accept `:root` to pin the marker/receipt store (same contract as
  `LaunchMarker`); absent an explicit root, the boot-pinned runtime authority
  root is used when a holder holds authority, else live configuration — the
  same resolution the runtime's fences use. Never mutates the filesystem.
  """
  @spec issue_diagnostics(term(), keyword()) :: diagnostics()
  def issue_diagnostics(issue_id, opts \\ []) when is_list(opts) do
    do_issue_diagnostics(issue_id, opts)
  rescue
    _error ->
      # The projection must never take the status endpoint down and must
      # never render its own failure as a safe state: report the evidence
      # unreadable and the fence unknown (fail-closed display).
      %{
        marker: %{status: "UNREADABLE"},
        receipt: nil,
        fence: %{decision: "UNKNOWN", reason: "diagnostic_unavailable"},
        store_root: nil
      }
  end

  defp do_issue_diagnostics(issue_id, opts) do
    opts = Keyword.merge([root: holder_authority_root()], opts)
    {marker_status, marker} = classify_marker(issue_id, opts)

    %{
      marker: marker_payload(issue_id, marker_status, marker),
      receipt: receipt_payload(marker_status, marker),
      fence: fence_payload(issue_id, opts),
      store_root: LaunchMarker.root(opts)
    }
  end

  # Marker evidence: the durable record that names the launch which last
  # owned the issue's workspace.
  defp classify_marker(issue_id, opts) do
    case LaunchMarker.read(issue_id, opts) do
      {:ok, marker} -> {:valid, marker}
      {:error, :not_found} -> {:absent, nil}
      {:error, :corrupt} -> {:invalid, nil}
      {:error, _unreadable} -> {:unreadable, nil}
    end
  end

  defp marker_payload(_issue_id, :absent, _marker), do: %{status: "ABSENT"}

  defp marker_payload(_issue_id, :invalid, _marker), do: %{status: "INVALID"}
  defp marker_payload(_issue_id, :unreadable, _marker), do: %{status: "UNREADABLE"}

  defp marker_payload(_issue_id, :valid, marker) do
    identity = Map.get(marker, "worker_identity") || %{}

    %{
      status: "VALID",
      launch_id: Map.get(marker, "launch_id"),
      identifier: Map.get(marker, "identifier"),
      attempt_id: Map.get(marker, "attempt_id"),
      workspace_key: Map.get(marker, "workspace_key"),
      started_at: Map.get(marker, "started_at"),
      identity_authority_root: Map.get(identity, "authority_root")
    }
  end

  # Receipt evidence: the termination receipt the stored identity points at.
  # Projected only when a readable marker names it; `launch_id_matches_marker`
  # and `verdict` are exactly the checks `WorkerContainment.verify_identity_receipt/1`
  # performs, reported separately so an operator can see which check failed.
  defp receipt_payload(status, _marker) when status in [:absent, :invalid, :unreadable], do: nil

  defp receipt_payload(:valid, marker) do
    identity = Map.get(marker, "worker_identity")

    case WorkerContainment.parse_receipt(receipt_path(identity)) do
      {:ok, receipt} ->
        receipt_valid_payload(identity, receipt)

      {:error, {:receipt_unreadable, :enoent}} ->
        %{status: "ABSENT", verdict: verdict_string(WorkerFence.confirm_termination_receipt(identity))}

      {:error, {:receipt_unreadable, _reason}} ->
        %{status: "UNREADABLE", verdict: verdict_string(WorkerFence.confirm_termination_receipt(identity))}

      {:error, {:malformed_receipt, _reason}} ->
        %{status: "INVALID", verdict: verdict_string(WorkerFence.confirm_termination_receipt(identity))}

      {:error, :receipt_path_missing} ->
        %{status: "ABSENT", verdict: verdict_string(WorkerFence.confirm_termination_receipt(identity))}
    end
  end

  defp receipt_valid_payload(identity, receipt) do
    %{
      status: "VALID",
      launch_id: Map.get(receipt, "launch_id"),
      launch_id_matches_marker: Map.get(receipt, "launch_id") == identity["launch_id"],
      tree_drained: Map.get(receipt, "tree_drained"),
      terminal_reason: Map.get(receipt, "terminal_reason"),
      verdict: verdict_string(WorkerFence.confirm_termination_receipt(identity))
    }
  end

  defp receipt_path(identity) when is_map(identity), do: Map.get(identity, "receipt_path")
  defp receipt_path(_other), do: nil

  # The fence verdict is recomputed by the authoritative gate itself
  # (`LaunchMarker.reuse_gate/2`, the same call the dispatch and cleanup
  # fences make), so this projection can never drift from runtime policy.
  defp fence_payload(issue_id, opts) do
    case LaunchMarker.reuse_gate(issue_id, opts) do
      :allowed -> %{decision: "ALLOWED", reason: nil}
      {:blocked, reason} -> %{decision: "BLOCKED", reason: Atom.to_string(reason)}
    end
  end

  # The receipt-backed fence path never positively proves ALIVE (only the
  # pid-liveness path can); anything not positively DEAD displays as UNKNOWN,
  # which keeps the projection fail-closed even if the verdict type widens.
  defp verdict_string({:ok, :dead}), do: "DEAD"
  defp verdict_string(_not_positively_dead), do: "UNKNOWN"

  # The boot-pinned authority root when a holder holds it, else nil — letting
  # LaunchMarker's own resolution order apply (override, pinned root,
  # configured root), identical to the runtime's fence root resolution.
  defp holder_authority_root do
    case RuntimeLease.authority_root() do
      {:ok, root} -> root
      {:error, _no_authority} -> nil
    end
  end
end
