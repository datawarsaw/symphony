defmodule SymphonyElixir.SSHTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.SSH

  @injected_config_keys [:ssh_command_runner, :ssh_executable_resolver, :ssh_port_opener]

  setup do
    previous_config =
      Map.new(@injected_config_keys, fn key ->
        {key, Application.get_env(:symphony_elixir, key)}
      end)

    previous_ssh_config = System.get_env("SYMPHONY_SSH_CONFIG")

    System.delete_env("SYMPHONY_SSH_CONFIG")

    on_exit(fn ->
      Enum.each(previous_config, fn {key, value} -> restore_application_env(key, value) end)
      restore_env("SYMPHONY_SSH_CONFIG", previous_ssh_config)
    end)

    :ok
  end

  test "run/3 keeps bracketed IPv6 host:port targets intact" do
    install_command_runner!()

    assert {:ok, {"", 0}} = SSH.run("root@[::1]:2200", "printf ok", stderr_to_stdout: true)

    assert_receive {:ssh_command, "/injected/ssh", args, [stderr_to_stdout: true]}
    assert args == ["-T", "-p", "2200", "root@[::1]", "bash -lc 'printf ok'"]
  end

  test "run/3 leaves unbracketed IPv6-style targets unchanged" do
    install_command_runner!()

    assert {:ok, {"", 0}} = SSH.run("::1:2200", "printf ok", stderr_to_stdout: true)

    assert_receive {:ssh_command, "/injected/ssh", args, [stderr_to_stdout: true]}
    assert args == ["-T", "::1:2200", "bash -lc 'printf ok'"]
  end

  test "run/3 passes host:port targets and configured ssh file to its runner" do
    install_command_runner!()
    System.put_env("SYMPHONY_SSH_CONFIG", "/tmp/symphony-test-ssh-config")

    assert {:ok, {"", 0}} = SSH.run("localhost:2222", "echo ready", stderr_to_stdout: true)

    assert_receive {:ssh_command, "/injected/ssh", args, [stderr_to_stdout: true]}

    assert args ==
             [
               "-F",
               "/tmp/symphony-test-ssh-config",
               "-T",
               "-p",
               "2222",
               "localhost",
               "bash -lc 'echo ready'"
             ]
  end

  test "run/3 keeps the user prefix when parsing user@host:port targets" do
    install_command_runner!()

    assert {:ok, {"", 0}} = SSH.run("root@127.0.0.1:2200", "printf ok", stderr_to_stdout: true)

    assert_receive {:ssh_command, "/injected/ssh", args, [stderr_to_stdout: true]}
    assert args == ["-T", "-p", "2200", "root@127.0.0.1", "bash -lc 'printf ok'"]
  end

  test "run/3 returns an error when the injected executable resolver cannot find ssh" do
    Application.put_env(:symphony_elixir, :ssh_executable_resolver, fn "ssh" -> nil end)

    assert {:error, :ssh_not_found} = SSH.run("localhost", "printf ok")
  end

  test "start_port/3 passes binary options and arguments to its injected port opener" do
    install_port_opener!()
    System.delete_env("SYMPHONY_SSH_CONFIG")

    assert {:ok, port} = SSH.start_port("localhost", "printf ok")
    assert is_port(port)
    assert_receive {:ssh_port, {:spawn_executable, ~c"/injected/ssh"}, port_opts}

    assert Keyword.fetch!(port_opts, :args) ==
             ["-T", "localhost", "bash -lc 'printf ok'"] |> Enum.map(&String.to_charlist/1)

    assert :binary in port_opts
    assert :exit_status in port_opts
    assert :stderr_to_stdout in port_opts
    refute Keyword.has_key?(port_opts, :line)
  end

  test "start_port/3 passes line mode and parsed port to its injected port opener" do
    install_port_opener!()

    assert {:ok, port} = SSH.start_port("localhost:2222", "printf ok", line: 256)
    assert is_port(port)
    assert_receive {:ssh_port, {:spawn_executable, ~c"/injected/ssh"}, port_opts}

    assert Keyword.fetch!(port_opts, :args) ==
             ["-T", "-p", "2222", "localhost", "bash -lc 'printf ok'"]
             |> Enum.map(&String.to_charlist/1)

    assert Keyword.fetch!(port_opts, :line) == 256
  end

  test "remote_shell_command/1 escapes embedded single quotes" do
    assert SSH.remote_shell_command("printf 'hello'") ==
             "bash -lc 'printf '\"'\"'hello'\"'\"''"
  end

  defp install_command_runner! do
    test_pid = self()
    Application.put_env(:symphony_elixir, :ssh_executable_resolver, fn "ssh" -> "/injected/ssh" end)

    Application.put_env(:symphony_elixir, :ssh_command_runner, fn executable, args, opts ->
      send(test_pid, {:ssh_command, executable, args, opts})
      {"", 0}
    end)
  end

  defp install_port_opener! do
    test_pid = self()
    Application.put_env(:symphony_elixir, :ssh_executable_resolver, fn "ssh" -> "/injected/ssh" end)

    Application.put_env(:symphony_elixir, :ssh_port_opener, fn command, opts ->
      send(test_pid, {:ssh_port, command, opts})
      open_test_port!()
    end)
  end

  defp open_test_port! do
    case :os.type() do
      {:win32, _} ->
        executable = System.find_executable("cmd") || raise "cmd executable is unavailable"

        Port.open(
          {:spawn_executable, String.to_charlist(executable)},
          [:binary, args: [~c"/c", ~c"exit", ~c"0"]]
        )

      _ ->
        executable = System.find_executable("true") || raise "true executable is unavailable"
        Port.open({:spawn_executable, String.to_charlist(executable)}, [:binary])
    end
  end

  defp restore_application_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_application_env(key, value), do: Application.put_env(:symphony_elixir, key, value)

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
