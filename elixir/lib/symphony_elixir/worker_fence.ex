defmodule SymphonyElixir.WorkerFence do
  @moduledoc """
  Conservative liveness fence for MIC-195 Slice A startup recovery.

  MIC-223 Windows/OTP 28.5 probes established that `Port.close` does not kill
  the worker process tree and BEAM death does not kill the worker process
  tree, so a surviving worker may still write to the workspace after Symphony
  restarts.

  Final invariant: UNKNOWN -> no cleanup + no redispatch. Only positively
  proven DEAD permits replacement dispatch or destructive cleanup. Missing,
  malformed, or unverifiable identities are UNKNOWN and fail closed; absence
  of an identity is never evidence of death.

  Two positively-proven evidence paths exist:

  - `:never_spawned` — explicit evidence that `Port.open` never succeeded for
    the workspace.
  - MIC-223 termination receipts — a persisted worker identity carrying a
    `receipt_path` into the managed receipt directory is verified against the
    wrapper's structured termination receipt (job accounting tree-drain
    evidence bound to the identity's launch id) via
    `confirm_termination_receipt/1`. Malformed or unproven receipts stay
    UNKNOWN. Serialized pid-only identities from an earlier boot cannot be
    positively verified (a stale pid is indistinguishable from a genuinely
    exited worker) and remain UNKNOWN.
  """

  alias SymphonyElixir.WorkerContainment

  @type verdict() :: {:ok, :dead} | {:error, :alive} | {:error, :unknown}

  @spec confirm_dead(term()) :: verdict()
  def confirm_dead(nil), do: {:error, :unknown}
  def confirm_dead(""), do: {:error, :unknown}

  def confirm_dead(pid) when is_pid(pid) do
    case pid_alive?(pid) do
      {:ok, true} -> {:error, :alive}
      {:ok, false} -> {:ok, :dead}
      :error -> {:error, :unknown}
    end
  end

  def confirm_dead(_other), do: {:error, :unknown}

  @doc """
  Verifies a persisted MIC-223 worker identity against its termination
  receipt. Only a receipt inside the managed receipt directory that parses,
  proves `tree_drained`, matches the identity's launch id, and carries a
  conclusive terminal reason is positively DEAD; every other outcome is
  UNKNOWN and fails closed.
  """
  @spec confirm_termination_receipt(term()) :: verdict()
  def confirm_termination_receipt(identity) do
    WorkerContainment.verify_identity_receipt(identity)
  end

  @doc """
  Only explicit evidence that `Port.open` never succeeded for the workspace
  proves no worker tree exists, so redispatch is safe. Callers must pass the
  `:never_spawned` token only when they hold that evidence; every other value,
  including absent identities, is UNKNOWN and fails closed.
  """
  @spec confirm_never_spawned(term()) :: verdict()
  def confirm_never_spawned(:never_spawned), do: {:ok, :dead}
  def confirm_never_spawned(_other), do: {:error, :unknown}

  @spec pid_alive?(pid()) :: {:ok, boolean()} | :error
  defp pid_alive?(pid) do
    {:ok, Process.alive?(pid)}
  rescue
    _ -> :error
  end
end
