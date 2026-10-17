defmodule Mix.Tasks.Symphony.PilotReadmit do
  @shortdoc "Operator re-admission of a single-attempt-parked pilot issue (offline, fail-closed)"

  @moduledoc """
  Explicitly authorizes exactly ONE new dispatch attempt for a pilot issue
  whose lifecycle ended in the single-attempt park
  (`stop_reason: "pilot_single_attempt"`).

      mix symphony.pilot_readmit --manifest <path> \\
        --issue MIC-306 \\
        --expected-attempt-count 1 \\
        --expected-stop-reason pilot_single_attempt \\
        --expected-last-failure-at "2026-10-13T07:28:34.420000Z" \\
        --expected-launch-id 1791876498544-5764 \\
        --confirmation "<who authorized the new attempt, and on what evidence>" \\
        [--dry-run]

  Operator procedure (run only while the Symphony runtime is STOPPED and the
  runtime authority lease has been released through runbook §8 recovery —
  `workspace-root/.symphony-state/runtime/authority.json` must be absent):

    1. Read the durable parked record
       (`<workspace-root>/.symphony-state/retries/<issue>.json`) and the
       worker-terminations receipt of the consumed attempt. Review them.
    2. Obtain explicit authorization for exactly one new attempt, and put
       its reference in `--confirmation` (recorded verbatim in the audit).
    3. Run once with `--dry-run` and confirm every precondition passes.
    4. Run without `--dry-run`. The command rewrites the parked record to
       `status: "readmitted"` and appends the audit entry under
       `<workspace-root>/.symphony-state/readmissions/`.
    5. Start the runtime through the documented bootstrap gate. The next
       armed start dispatches exactly one new attempt for the issue; the
       single-attempt policy applies to it unchanged — when it completes or
       fails, the issue parks again and only a fresh run of this command
       against the NEW parked record can re-admit it.

  Every precondition is fail-closed: the command refuses — leaving the
  durable state untouched — unless the exact expected parked record matches
  (identifier, `stop_reason`, `attempt_count`, `last_failure_at`), the park
  is the single-attempt class, no retry timer is pending, the launch fence is
  resolved, a termination receipt proving the consumed worker drained exists
  for the stated launch id, no runtime authority lease exists, and the issue
  is on the armed pilot's OpenCode allowlist. A stale command (prepared
  against an older park) can never clear a newer attempt, because the newer
  park carries a later `last_failure_at`.

  The command is offline: it contacts no tracker, decrypts no credential,
  calls no provider, launches no process, and never mutates the lease, the
  launch markers, or any workspace. It does not replace the bootstrap gate.
  """

  use Mix.Task

  alias SymphonyElixir.PilotReadmit

  @switches [
    manifest: :string,
    issue: :string,
    expected_attempt_count: :integer,
    expected_stop_reason: :string,
    expected_last_failure_at: :string,
    expected_launch_id: :string,
    confirmation: :string,
    dry_run: :boolean,
    help: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.config")

    {opts, argv, invalid} = OptionParser.parse(args, strict: @switches)

    cond do
      opts[:help] ->
        Mix.shell().info(usage())

      invalid != [] ->
        Mix.raise("symphony.pilot_readmit: unrecognized arguments: " <> inspect(invalid ++ argv))

      is_nil(opts[:manifest]) ->
        Mix.raise("symphony.pilot_readmit: --manifest <path> is required. " <> usage())

      true ->
        execute(opts)
    end
  end

  defp execute(opts) do
    case PilotReadmit.readmit(opts[:manifest], opts) do
      {:ok, receipt} ->
        print_receipt(receipt)

      {:error, reason} ->
        Mix.shell().error("symphony.pilot_readmit: REFUSED (fail-closed); durable state untouched")
        Mix.shell().error(inspect(reason, pretty: true, limit: :infinity))
        Mix.raise("symphony.pilot_readmit: refusing to re-admit the issue")
    end
  end

  defp print_receipt(receipt) do
    Mix.shell().info("symphony.pilot_readmit: issue=#{receipt.identifier} issue_id=#{receipt.issue_id}")
    Mix.shell().info("  state_root     = #{receipt.state_root}")
    Mix.shell().info("  previous       = #{inspect(receipt.previous_attempt)}")
    Mix.shell().info("  launch_id      = #{receipt.expected_launch_id}")
    Mix.shell().info("  receipt        = #{receipt.termination_receipt_path}")
    Mix.shell().info("  fence          = #{inspect(receipt.launch_fence)} verdict=#{inspect(receipt.termination_verdict)}")
    Mix.shell().info("  authorization  = #{receipt.confirmation}")

    if receipt.dry_run do
      Mix.shell().info("symphony.pilot_readmit: DRY RUN - all preconditions pass; nothing was written")
    else
      Mix.shell().info("  readmission_id = #{receipt.readmission_id}")
      Mix.shell().info("  record         = #{receipt.record_path} (status -> #{receipt.new_status})")
      Mix.shell().info("  audit          = #{receipt.audit_path}")
      Mix.shell().info("symphony.pilot_readmit: RE-ADMISSION RECORDED - the next armed start dispatches exactly one new attempt;")
      Mix.shell().info("  the single-attempt policy applies to it unchanged.")
    end
  end

  defp usage do
    "Usage: mix symphony.pilot_readmit --manifest <path> --issue <identifier> " <>
      "--expected-attempt-count <n> --expected-stop-reason pilot_single_attempt " <>
      "--expected-last-failure-at <iso8601> --expected-launch-id <id> --confirmation <text> [--dry-run]"
  end
end
