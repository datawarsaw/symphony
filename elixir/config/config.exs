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
    retry_store_root:
      Path.join(System.tmp_dir!(), "symphony-elixir-retries-run-#{System.unique_integer([:positive])}")
end
