defmodule Mix.Tasks.HumanAcceptanceTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.HumanAcceptance

  setup do
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    path = Path.join(System.tmp_dir!(), "acceptance-#{System.unique_integer([:positive])}.json")

    on_exit(fn ->
      Mix.shell(previous_shell)
      File.rm(path)
    end)

    {:ok, path: path}
  end

  test "preview renders a draft from a local snapshot without a tracker request", %{path: path} do
    File.write!(path, Jason.encode!(%{"schema_version" => 1, "task_type" => "frontend"}))
    HumanAcceptance.run(["--input", path])
    assert_received {:mix_shell, :info, [body]}
    assert body =~ "# [HUMAN ACCEPTANCE]"
    assert body =~ "DRAFT — NOT READY"
    assert body =~ "## USER-VISIBLE EVIDENCE"
  end

  test "invalid arguments fail before any publication" do
    for args <- [[], ["unexpected"], ["--input", "missing", "--unknown"]] do
      assert_raise Mix.Error, ~r/Expected --input/, fn -> HumanAcceptance.run(args) end
    end
  end

  test "unreadable, malformed, non-object and oversized inputs fail explicitly", %{path: path} do
    assert_raise Mix.Error, ~r/readable JSON object/, fn -> HumanAcceptance.run(["--input", path]) end

    for content <- ["{", "[]", String.duplicate(" ", 262_145)] do
      File.write!(path, content)
      assert_raise Mix.Error, ~r/readable JSON object/, fn -> HumanAcceptance.run(["--input", path]) end
    end
  end
end
