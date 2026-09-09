defmodule SymphonyElixir.Codex.WorkerEnvironmentTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Codex.WorkerEnvironment
  alias SymphonyElixir.PathSafety

  @windows {:win32, :nt}

  # A restricted Windows token can be unable to create a symlink at all. Probe
  # once at compile time so the containment fixture reports an explicit skip
  # instead of passing without exercising the escape check.
  @symlink_skip_reason (fn ->
                          root =
                            Path.join(
                              System.tmp_dir!(),
                              "symphony-elixir-symlink-probe-#{System.unique_integer([:positive])}"
                            )

                          link = root <> "-link"
                          File.mkdir_p!(root)

                          result =
                            case File.ln_s(root, link) do
                              :ok ->
                                false

                              {:error, reason} when reason in [:eperm, :eacces, :enotsup] ->
                                "host cannot create symlinks (#{inspect(reason)})"

                              {:error, reason} ->
                                raise "unexpected symlink capability probe failure: #{inspect(reason)}"
                            end

                          File.rm_rf!(link)
                          File.rm_rf!(root)
                          result
                        end).()

  test "prepares contained writable BEAM paths for Windows workers" do
    test_root = temporary_directory("worker-environment")
    on_exit(fn -> File.rm_rf(test_root) end)
    workspace = Path.join(test_root, "workspace")
    File.mkdir_p!(workspace)

    assert {:ok, environment} = WorkerEnvironment.prepare(workspace, @windows)
    assert {:ok, canonical_workspace} = PathSafety.canonicalize(workspace)

    assert environment ==
             Enum.map(
               [
                 {"MIX_BUILD_PATH", ".mix_build"},
                 {"MIX_DEPS_PATH", ".mix_deps"},
                 {"HEX_HOME", ".hex"},
                 {"MIX_HOME", ".mix"},
                 {"ELIXIR_MAKE_CACHE_DIR", ".elixir_make"},
                 {"REBAR_CACHE_DIR", ".rebar_cache"},
                 {"REBAR_GLOBAL_CONFIG_DIR", ".rebar_config"},
                 {"TMPDIR", ".tmp"},
                 {"TEMP", ".tmp"},
                 {"TMP", ".tmp"}
               ],
               fn {name, directory} ->
                 {String.to_charlist(name), String.to_charlist(Path.join(canonical_workspace, directory))}
               end
             )

    for {_name, path} <- environment do
      assert File.dir?(to_string(path))
      assert Path.relative_to(to_string(path), canonical_workspace) != to_string(path)
    end

    assert File.ls!(workspace) |> Enum.sort() ==
             [".elixir_make", ".hex", ".mix", ".mix_build", ".mix_deps", ".rebar_cache", ".rebar_config", ".tmp"]
  end

  test "does not write environment directories for non-Windows workers" do
    test_root = temporary_directory("worker-environment-non-windows")
    on_exit(fn -> File.rm_rf(test_root) end)
    workspace = Path.join(test_root, "missing-workspace")

    assert {:ok, []} = WorkerEnvironment.prepare(workspace, {:unix, :linux})
    refute File.exists?(workspace)
  end

  test "reports the environment variable and path when a directory collides with a file" do
    test_root = temporary_directory("worker-environment-collision")
    on_exit(fn -> File.rm_rf(test_root) end)
    workspace = Path.join(test_root, "workspace")
    collision = Path.join(workspace, ".mix_build")
    File.mkdir_p!(workspace)
    File.write!(collision, "not a directory")
    assert {:ok, canonical_collision} = PathSafety.canonicalize(collision)

    assert {:error, {:workspace_beam_environment_failed, "MIX_BUILD_PATH", ^canonical_collision, reason}} =
             WorkerEnvironment.prepare(workspace, @windows)

    assert reason in [:eexist, :enotdir]
  end

  test "reports the workspace when the worker workspace is not a directory" do
    test_root = temporary_directory("worker-environment-missing-workspace")
    on_exit(fn -> File.rm_rf(test_root) end)
    workspace = Path.join(test_root, "workspace")
    File.mkdir_p!(test_root)
    assert {:ok, canonical_workspace} = PathSafety.canonicalize(workspace)

    assert {:error, {:workspace_beam_environment_failed, "workspace", ^canonical_workspace, :not_a_directory}} =
             WorkerEnvironment.prepare(workspace, @windows)
  end

  test "reports an invalid workspace value for Windows workers" do
    assert {:error, {:workspace_beam_environment_failed, "workspace", ":not_a_path", :invalid_workspace}} =
             WorkerEnvironment.prepare(:not_a_path, @windows)
  end

  @tag skip: if(:os.type() == {:win32, :nt}, do: false, else: "Windows-only path component limit")
  test "reports the workspace path and reason when a Windows path component is overlong" do
    test_root = temporary_directory("worker-environment-overlong")
    on_exit(fn -> File.rm_rf(test_root) end)
    File.mkdir_p!(test_root)
    workspace = Path.join(test_root, String.duplicate("a", 300))

    assert {:error, {:workspace_beam_environment_failed, "workspace", path, :enametoolong}} =
             WorkerEnvironment.prepare(workspace, @windows)

    assert String.contains?(path, String.duplicate("a", 300))
  end

  @tag skip: @symlink_skip_reason
  test "rejects a linked BEAM directory that escapes the workspace" do
    test_root = temporary_directory("worker-environment-symlink")
    on_exit(fn -> File.rm_rf(test_root) end)
    workspace = Path.join(test_root, "workspace")
    outside = Path.join(test_root, "outside")
    escaped_path = Path.join(workspace, ".mix_build")
    File.mkdir_p!(workspace)
    File.mkdir_p!(outside)

    File.ln_s!(outside, escaped_path)
    assert {:ok, canonical_outside} = PathSafety.canonicalize(outside)

    assert {:error, {:workspace_beam_environment_failed, "MIX_BUILD_PATH", ^canonical_outside, :outside_workspace}} =
             WorkerEnvironment.prepare(workspace, @windows)
  end

  defp temporary_directory(name) do
    Path.join(System.tmp_dir!(), "symphony-elixir-#{name}-#{System.unique_integer([:positive])}")
  end
end
