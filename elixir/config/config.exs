import Config

config :phoenix, :json_library, Jason

config :symphony_elixir, SymphonyElixirWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  render_errors: [
    formats: [html: SymphonyElixirWeb.ErrorHTML, json: SymphonyElixirWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: SymphonyElixir.PubSub,
  live_view: [signing_salt: "symphony-live-view"],
  secret_key_base: String.duplicate("s", 64),
  check_origin: false,
  server: false

if config_env() == :test do
  config :symphony_elixir,
    workflow_file_path: Path.expand("../test/fixtures/startup_workflow.md", __DIR__),
    # The application-level Orchestrator boots (and recovers durable retry
    # records) before any test setup runs, so the test VM starts with its own
    # per-run retry store root; TestSupport narrows this to a per-test root
    # while each test executes. The default workspace root must never hold
    # durable retry records during tests.
    #
    # The name is keyed to the booting VM's OS pid: per-VM integer counters
    # collide across `mix test` invocations, and a run aborted before the
    # after-suite cleanup leaves residue that the next run's runtime authority
    # lease must (and does) fail closed against.
    retry_store_root: Path.join(System.tmp_dir!(), "symphony-elixir-retries-run-#{System.pid()}"),
    # The test VM's application boot is a direct entry path of the documented
    # unpinned kind (tests build runtime trees on fixture roots themselves), so
    # it starts no runtime-authority holder: the run-scoped retry root above is
    # shared suite fixture state that tests narrow, restore, and delete, and it
    # must never be load-bearing for a lease. Lease coverage lives in the
    # runtime-authority suites and the env-gated multi-BEAM startup e2e, whose
    # child BEAMs boot with this flag unset and acquire exactly as production.
    runtime_authority_app_boot: false
end
