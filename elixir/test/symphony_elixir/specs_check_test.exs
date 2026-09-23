defmodule SymphonyElixir.SpecsCheckTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.SpecsCheck

  test "reports missing @spec for public functions" do
    dir = create_tmp_dir()

    write_module!(dir, "sample.ex", """
    defmodule Sample do
      def missing(arg), do: arg
    end
    """)

    findings = SpecsCheck.missing_public_specs([dir])

    assert Enum.map(findings, &SpecsCheck.finding_identifier/1) == ["Sample.missing/1"]
  end

  test "accepts adjacent @spec on public function" do
    dir = create_tmp_dir()

    write_module!(dir, "sample.ex", """
    defmodule Sample do
      @spec ok(term()) :: term()
      def ok(arg), do: arg
    end
    """)

    assert SpecsCheck.missing_public_specs([dir]) == []
  end

  test "accepts spec followed by standalone default-arg head and implementation" do
    dir = create_tmp_dir()

    write_module!(dir, "sample.ex", """
    defmodule Sample do
      @spec ok(term()) :: term()
      def ok(arg \\\\ :default)

      def ok(arg), do: arg
    end
    """)

    assert SpecsCheck.missing_public_specs([dir]) == []
  end

  test "accepts spec followed by standalone head with guarded multi-clause implementations" do
    dir = create_tmp_dir()

    write_module!(dir, "sample.ex", """
    defmodule Sample do
      @spec classify(atom(), keyword()) :: atom()
      def classify(kind, opts \\\\ [])

      def classify(kind, _opts) when is_atom(kind), do: :actionable
      def classify(:other, _opts), do: :observed

      def classify(kind, opts) when is_atom(kind) and is_list(opts) do
        :deterministic
      end
    end
    """)

    assert SpecsCheck.missing_public_specs([dir]) == []
  end

  test "accepts standalone default-arg head followed by its @spec and implementation" do
    dir = create_tmp_dir()

    write_module!(dir, "sample.ex", """
    defmodule Sample do
      def ok(arg \\\\ :default)

      @spec ok(term()) :: term()
      def ok(arg), do: arg
    end
    """)

    assert SpecsCheck.missing_public_specs([dir]) == []
  end

  test "finds missing @spec when the spec after a standalone head targets another function" do
    dir = create_tmp_dir()

    write_module!(dir, "sample.ex", """
    defmodule Sample do
      def orphaned(arg \\\\ :default)

      @spec different(term()) :: term()
      def orphaned(arg), do: arg
    end
    """)

    findings = SpecsCheck.missing_public_specs([dir])

    assert Enum.map(findings, &SpecsCheck.finding_identifier/1) == ["Sample.orphaned/1"]
  end

  test "finds missing @spec for a standalone head that closes the module without @spec" do
    dir = create_tmp_dir()

    write_module!(dir, "sample.ex", """
    defmodule Sample do
      @spec ok(term()) :: term()
      def ok(arg), do: arg

      def dangling(arg)
    end
    """)

    findings = SpecsCheck.missing_public_specs([dir])

    assert Enum.map(findings, &SpecsCheck.finding_identifier/1) == ["Sample.dangling/1"]
  end

  test "finds missing @spec for standalone default-arg head followed by implementation" do
    dir = create_tmp_dir()

    write_module!(dir, "sample.ex", """
    defmodule Sample do
      def missing(arg \\\\ :default)

      def missing(arg), do: arg
    end
    """)

    findings = SpecsCheck.missing_public_specs([dir])

    assert Enum.map(findings, &SpecsCheck.finding_identifier/1) == ["Sample.missing/1"]
  end

  test "finds missing @spec once when head-only and implementation clauses are unspecced" do
    dir = create_tmp_dir()

    write_module!(dir, "sample.ex", """
    defmodule Sample do
      def missing(arg)

      def missing(arg), do: arg
      def missing_other(arg), do: arg
    end
    """)

    findings = SpecsCheck.missing_public_specs([dir])

    assert Enum.map(findings, &SpecsCheck.finding_identifier/1) == [
             "Sample.missing/1",
             "Sample.missing_other/1"
           ]
  end

  test "finds @spec when the adjacent spec targets a wrong name or arity" do
    dir = create_tmp_dir()

    write_module!(dir, "sample.ex", """
    defmodule Sample do
      @spec wrong_name(term()) :: term()
      def by_name(arg), do: arg

      @spec by_arity(term()) :: term()
      def by_arity(first, second), do: {first, second}
    end
    """)

    findings = SpecsCheck.missing_public_specs([dir])

    assert Enum.map(findings, &SpecsCheck.finding_identifier/1) == [
             "Sample.by_name/1",
             "Sample.by_arity/2"
           ]
  end

  test "associates adjacent specs with their own functions across multiple pairs" do
    dir = create_tmp_dir()

    write_module!(dir, "sample.ex", """
    defmodule Sample do
      @spec first(term()) :: term()
      def first(arg), do: arg

      @spec second(term()) :: term()
      def second(arg), do: arg

      def third(arg), do: arg
    end
    """)

    findings = SpecsCheck.missing_public_specs([dir])

    assert Enum.map(findings, &SpecsCheck.finding_identifier/1) == ["Sample.third/1"]
  end

  test "allows defp without @spec" do
    dir = create_tmp_dir()

    write_module!(dir, "sample.ex", """
    defmodule Sample do
      def public do
        helper(:ok)
      end

      defp helper(value), do: value
    end
    """)

    findings = SpecsCheck.missing_public_specs([dir])

    assert Enum.map(findings, &SpecsCheck.finding_identifier/1) == ["Sample.public/0"]
  end

  test "exempts callback implementations marked with @impl" do
    dir = create_tmp_dir()

    write_module!(dir, "worker.ex", """
    defmodule Worker do
      @behaviour GenServer

      @impl true
      def init(state), do: {:ok, state}
    end
    """)

    assert SpecsCheck.missing_public_specs([dir]) == []
  end

  test "exempts standalone callback head marked with @impl" do
    dir = create_tmp_dir()

    write_module!(dir, "worker.ex", """
    defmodule Worker do
      @behaviour GenServer

      @impl true
      def handle_call(request, from, state)

      def handle_call(request, _from, state), do: {:reply, request, state}
    end
    """)

    assert SpecsCheck.missing_public_specs([dir]) == []
  end

  test "honors explicit exemptions list" do
    dir = create_tmp_dir()

    write_module!(dir, "sample.ex", """
    defmodule Sample do
      def legacy(arg), do: arg
    end
    """)

    findings = SpecsCheck.missing_public_specs([dir], exemptions: ["Sample.legacy/1"])

    assert findings == []
  end

  defp create_tmp_dir do
    unique = :erlang.unique_integer([:positive, :monotonic])
    dir = Path.join(System.tmp_dir!(), "specs-check-test-#{unique}")
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    dir
  end

  defp write_module!(dir, rel_path, source) do
    path = Path.join(dir, rel_path)
    File.write!(path, source)
  end
end
