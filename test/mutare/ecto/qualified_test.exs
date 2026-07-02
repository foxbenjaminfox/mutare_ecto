defmodule Mutare.Ecto.QualifiedTest do
  use ExUnit.Case, async: true

  import Mutare.Ecto.TestSupport

  # The query DSL macros can be written three ways, all of which core's resolver recognizes and
  # hands to the plugin's `route_arguments/2`/`host/2`/`mutate/2`: **bare/imported** (`where(q, …)`),
  # **qualified** (`Ecto.Query.where(q, …)`), and **aliased** (`Q.where(q, …)`). The plugin used to
  # pattern-match only the bare atom head, so the qualified/aliased forms escaped routing entirely —
  # core then descended into the raw query fragment, splicing selector `case`s into binding-list /
  # fragment positions (poisoning the single build) and mutating SQL conditions with its own
  # two-valued families. The fix routes every form through `Mutare.Ecto.AST.QueryCall.parse/1`
  # (core's `Mutare.Calls.resolved_macro_call/1`), so the written form is transparent.
  #
  # These tests pin (1) the metamutant still compiles for the qualified/aliased forms under the full
  # mutator set — the original crash — and (2) the qualified/aliased forms produce the *same logical*
  # mutations as the bare form.

  @all [:all, {Mutare.Ecto, repo: MyApp.Repo}]

  # Strip the module qualifier so a qualified/aliased diff compares equal to its bare twin — the
  # only legitimate difference between the forms is the `Ecto.Query.`/`Q.` prefix on the rewritten
  # whole-call mutants (clause/stage drop, bound bump); the in-fragment swaps carry no prefix.
  defp normalize({original, mutated}) do
    strip = &(&1 |> String.replace("Ecto.Query.", "") |> String.replace(~r/\bQ\./, ""))
    {strip.(original), strip.(mutated)}
  end

  defp normalized_ecto_diffs(src),
    do: src |> ecto_diffs() |> Enum.map(&normalize/1) |> Enum.sort()

  defp wrap(body, header \\ "import Ecto.Query") do
    """
    defmodule Sample do
      #{header}
      def q(query \\\\ nil), do: #{body}
    end
    """
  end

  describe "the reported crash — qualified select with count(…, :distinct)" do
    test "compiles under the full mutator set (no poison from a descended fragment)" do
      # `count` is excluded from the aggregate ladder, so the only mutation is the stage drop —
      # but before the fix core descended into the qualified call, mutating `:distinct` and the
      # binding list and splicing a `case` into a binding position, which failed to compile.
      src =
        wrap(~S/from(s in "samples") |> Ecto.Query.select([source: s], count(s.id, :distinct))/)

      assert_compiles(src, mutators: @all)
    end

    test "count is not swapped; :distinct and the binding list are left untouched" do
      src =
        wrap(~S/from(s in "samples") |> Ecto.Query.select([source: s], count(s.id, :distinct))/)

      diffs = ecto_diffs(src)

      # The whole stage drop is the only ecto mutation; count/:distinct are never rewritten.
      assert Enum.all?(diffs, fn {_o, mutated} -> mutated =~ "Function.identity" end)
      refute Enum.any?(diffs, fn {_o, mutated} -> mutated =~ "avg" or mutated =~ "sum" end)
      refute Enum.any?(diffs, fn {_o, mutated} -> mutated =~ "mutare" end)
    end
  end

  describe "qualified forms route identically to bare" do
    test "where condition hosts the SQL catalog (qualified ≡ bare)" do
      bare = wrap(~S/from(s in "t") |> where([s], s.id > 1)/)
      qual = wrap(~S/from(s in "t") |> Ecto.Query.where([s], s.id > 1)/)

      # The hosted comparison/boundary swaps fire on both, and the two normalize to the same set.
      assert {"s.id > 1", "s.id >= 1"} in normalized_ecto_diffs(qual)
      assert normalized_ecto_diffs(qual) == normalized_ecto_diffs(bare)
      assert_compiles(qual, mutators: @all)
    end

    test "select aggregate swap (qualified ≡ bare)" do
      bare = wrap(~S/from(s in "t") |> select([s], sum(s.x))/)
      qual = wrap(~S/from(s in "t") |> Ecto.Query.select([s], sum(s.x))/)

      assert {"select([s], sum(s.x))", "select([s], avg(s.x))"} in normalized_ecto_diffs(qual)
      assert normalized_ecto_diffs(qual) == normalized_ecto_diffs(bare)
    end

    test "select positional binding reorder (qualified ≡ bare)" do
      bare = wrap(~S/from(s in "t", join: c in "c") |> select([s, c], {s.id, c.id})/)
      qual = wrap(~S/from(s in "t", join: c in "c") |> Ecto.Query.select([s, c], {s.id, c.id})/)

      assert {"select([s, c], {s.id, c.id})", "select([c, s], {s.id, c.id})"} in normalized_ecto_diffs(
               qual
             )

      assert normalized_ecto_diffs(qual) == normalized_ecto_diffs(bare)
    end

    test "limit bound bump + stage drop (qualified ≡ bare)" do
      bare = wrap(~S/from(s in "t") |> limit(10)/)
      qual = wrap(~S/from(s in "t") |> Ecto.Query.limit(10)/)

      assert {"limit(10)", "limit(11)"} in normalized_ecto_diffs(qual)
      assert normalized_ecto_diffs(qual) == normalized_ecto_diffs(bare)
    end

    test "whole-from rewrites on a qualified from(…) opener (qualified ≡ bare)" do
      # Bare `from` needs `import`; the qualified `Ecto.Query.from` resolves under a bare `require` —
      # both must host the `where` condition and produce the same whole-from rewrites.
      bare = wrap(~S/from(s in "t", where: s.id > 1, limit: 10)/)
      qual = wrap(~S/Ecto.Query.from(s in "t", where: s.id > 1, limit: 10)/, "require Ecto.Query")

      norm = normalized_ecto_diffs(qual)
      # filter drop and bound drop both fire on the qualified opener.
      assert {~S/from(s in "t", where: s.id > 1, limit: 10)/, ~S/from(s in "t", limit: 10)/} in norm

      assert {~S/from(s in "t", where: s.id > 1, limit: 10)/, ~S/from(s in "t", where: s.id > 1)/} in norm

      assert norm == normalized_ecto_diffs(bare)
      assert_compiles(qual, mutators: @all)
    end

    test "a qualified nested query remains reachable through an outer clause macro" do
      bare = wrap(~S/limit(from(s in "t", where: s.id > 1), 10)/)

      qual =
        wrap(
          ~S/Ecto.Query.limit(Ecto.Query.from(s in "t", where: s.id > 1), 10)/,
          "require Ecto.Query"
        )

      norm = normalized_ecto_diffs(qual)

      assert {"s.id > 1", "s.id >= 1"} in norm
      assert norm == normalized_ecto_diffs(bare)
      assert_compiles(qual, mutators: @all)
    end
  end

  describe "aliased forms route identically to bare" do
    test "aliased order_by flips its direction (aliased ≡ bare)" do
      bare = wrap(~S/from(s in "t") |> order_by([s], asc: s.id)/)

      aliased =
        wrap(
          ~S/Ecto.Query.from(s in "t") |> Q.order_by([s], asc: s.id)/,
          "alias Ecto.Query, as: Q\n  require Ecto.Query"
        )

      assert {"order_by([s], asc: s.id)", "order_by([s], desc: s.id)"} in normalized_ecto_diffs(
               aliased
             )

      assert normalized_ecto_diffs(aliased) == normalized_ecto_diffs(bare)
      assert_compiles(aliased, mutators: @all)
    end
  end

  describe "the semantic boundary holds for qualified conditions" do
    test "a qualified where is mutated by the SQL catalog, never core's two-valued families" do
      # Before the fix, the qualified condition escaped to core: `s.id > 1` became `s.id < 1` /
      # `true` / `false` (Elixir's two-valued logic). It must now be owned end-to-end by the host.
      src = wrap(~S/from(s in "t") |> Ecto.Query.where([s], s.id > 1)/)

      leaked =
        src
        |> diffs(mutators: @all)
        |> Enum.filter(fn {mutator, original, _mutated} ->
          mutator in [:relational, :conditional] and original =~ "s.id > 1"
        end)

      assert leaked == [], "core families leaked into the SQL fragment: #{inspect(leaked)}"
    end
  end

  describe "resolution safety" do
    test "a same-named local function is not treated as an Ecto.Query macro" do
      src = """
      defmodule Sample do
        def select(query, bindings, expression), do: {query, bindings, expression}
        def q(query), do: select(query, [u], sum(u.amount))
      end
      """

      assert ecto_diffs(src) == []
    end
  end
end
