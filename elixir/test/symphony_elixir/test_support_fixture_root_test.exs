defmodule SymphonyElixir.TestSupportFixtureRootTest do
  # Focused coverage for the cross-BEAM fixture-root helper: uniqueness of
  # successive draws, the exclusive-create ownership primitive, Windows-safe
  # naming, and composition with the delivered cleanup authority. Cross-BEAM
  # uniqueness itself is validated by multi-BEAM probe runs, not here.
  use ExUnit.Case, async: true

  alias SymphonyElixir.TestSupport

  @draws 128

  test "creates an existing directory under the system temp root, named after the prefix" do
    root = TestSupport.create_temp_fixture_root!("symphony-elixir-workflow-helper-test")
    on_exit(fn -> TestSupport.remove_temp_fixture_root!(root) end)

    assert File.dir?(root)

    # Path.expand/1 lowercases the Windows drive letter while raw path pieces
    # keep the TEMP dir's casing, so compare both sides normalized.
    assert root |> Path.dirname() |> Path.expand() |> String.downcase() ==
             System.tmp_dir!() |> Path.expand() |> String.downcase()

    basename = Path.basename(root)
    assert basename =~ ~r/^symphony-elixir-workflow-helper-test-[A-Za-z0-9_-]{16}$/
  end

  test "successive draws never repeat a path" do
    roots =
      for _ <- 1..@draws do
        root = TestSupport.create_temp_fixture_root!("symphony-elixir-helper-draw-stress")
        on_exit(fn -> TestSupport.remove_temp_fixture_root!(root) end)
        root
      end

    assert length(roots) == @draws
    assert Enum.uniq(roots) == roots
  end

  test "the drawn path is exclusively owned: a second creator loses with :eexist" do
    root = TestSupport.create_temp_fixture_root!("symphony-elixir-helper-ownership")
    on_exit(fn -> TestSupport.remove_temp_fixture_root!(root) end)

    # File.mkdir/1 is the ownership-establishing operation behind the helper:
    # exactly one creator can succeed for a given path, so the helper's
    # success proves it created that exact root and a racing BEAM redraws.
    assert File.mkdir(root) == {:error, :eexist}
  end

  test "a prefix with spaces and non-ASCII characters stays portable on this host" do
    root = TestSupport.create_temp_fixture_root!("symphony helper ünïcode fixture")
    on_exit(fn -> TestSupport.remove_temp_fixture_root!(root) end)

    assert File.dir?(root)
    assert File.write!(Path.join(root, "probe.txt"), "ok")
  end

  test "cleanup stays ownership-scoped: the owned root goes, a foreign sibling survives" do
    owned = TestSupport.create_temp_fixture_root!("symphony-elixir-helper-owned")
    on_exit(fn -> TestSupport.remove_temp_fixture_root!(owned) end)

    foreign = Path.join(System.tmp_dir!(), "symphony-elixir-helper-foreign-sentinel")
    File.mkdir_p!(foreign)
    on_exit(fn -> TestSupport.remove_temp_fixture_root!(foreign) end)

    File.write!(Path.join(owned, "owned-sentinel.txt"), "owned\n")
    foreign_sentinel = Path.join(foreign, "foreign-sentinel.txt")
    File.write!(foreign_sentinel, "not mine\n")

    :ok = TestSupport.remove_temp_fixture_root!(owned)

    refute File.exists?(owned)
    assert File.read!(foreign_sentinel) == "not mine\n"
  end
end
