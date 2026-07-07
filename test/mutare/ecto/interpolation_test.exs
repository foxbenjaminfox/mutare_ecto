defmodule Mutare.Ecto.InterpolationTest do
  use ExUnit.Case, async: true

  import Mutare.Ecto.TestSupport

  # Interpolation (`^expr`) across the **whole query surface** — the cross-product of "where a
  # pin can appear" × "who owns it". The island sub-contract inside a hosted condition has its
  # own file (`subcontract_test.exs`); this one pins everything *around* it:
  #
  #   * a pin in a **non-hosted** clause position (`limit:`, `order_by:`, a shorthand pair
  #     value, a `from`/`join` source) is whole-value raw — the plugin's catalogs stop at it and
  #     core keeps DSL data raw, so its inline interior is nobody's (a pinned *variable* is
  #     mutated upstream where it is bound, as always);
  #   * a pinned **source** never blocks the machinery around it — the hosted condition still
  #     weaves, and the whole-`from` rewrites re-emit the pin byte-for-byte;
  #   * a bare pin as a **boolean operand** of a hosted condition rides the weave raw while the
  #     condition's own structure (and its other islands) mutate normally.
  #
  # Everything asserts through the public transform (`diffs`/`ecto_diffs`/`metamutant`), with
  # core's builtins in the run so "raw" means *nobody* mutates it — not merely "not the plugin".

  @with_core [mutators: [:all, {Mutare.Ecto, repo: MyApp.Repo}]]

  # Every diff (any family) whose original or mutated rendering touches `substring`.
  defp diffs_touching(src, substring) do
    for {mutator, original, mutated} <- diffs(src, @with_core),
        String.contains?(original, substring) or String.contains?(mutated, substring),
        do: {mutator, original, mutated}
  end

  describe "a pin in a non-hosted clause position is whole-value raw" do
    test "a pinned limit/offset interior is nobody's — even with core in the run" do
      # The plugin's Bound bump targets a *written* integer (query_test pins that half); the
      # pin's inline interior is likewise untouched by core, whose DSL routing keeps every
      # non-hosted `from` value raw. Only the clause drop mentions it — re-emitted verbatim.
      src = """
      defmodule M do
        import Ecto.Query
        def q(n), do: from(u in User, limit: ^(n + 1), select: u.id)
      end
      """

      refute Enum.any?(diffs(src, @with_core), fn {_m, _o, mutated} ->
               mutated =~ "n - 1" or mutated =~ "n + 2" or mutated =~ "n + 0"
             end)

      # The whole-`from` bound drop still fires around the raw pin — now reported clause-level as
      # the delete of the limit value, which re-emits the pin verbatim as its `original`.
      assert {"^(n + 1)", ""} in ecto_diffs(src, @with_core)

      assert_compiles(src, @with_core)
    end

    test "pinned order_by/group_by values are whole-value raw" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(ord, cols), do: from(u in User, group_by: ^(cols ++ [:x]), order_by: ^(ord ++ [:y]), select: u.id)
      end
      """

      # No family rewrites either interior: no `--`/list mutants of the appends, no literal
      # mutants of the atoms inside them.
      refute Enum.any?(diffs(src, @with_core), fn {_m, _o, mutated} ->
               (mutated =~ "cols" or mutated =~ "ord") and
                 mutated not in ["nil", ":mutare"] and
                 mutated !=
                   "from(u in User, group_by: ^(cols ++ [:x]), order_by: ^(ord ++ [:y]), select: u.id)" and
                 not (mutated =~ "group_by: ^(cols ++ [:x])" and
                        mutated =~ "order_by: ^(ord ++ [:y])")
             end)

      assert_compiles(src, @with_core)
    end

    test "a pinned shorthand pair value stays raw while a scalar sibling interpolates" do
      # The per-pair routing (`{:keyword, …}`): a *scalar* shorthand value is `:interpolated`
      # (core's literal families mutate it, `^`-pinned by core's delivery), while a pinned or
      # compound value is `:skip` — its interior is nobody's. Both halves in one clause list.
      src = """
      defmodule M do
        import Ecto.Query
        def q(n), do: from(User, where: [age: ^(n + 1), active: true], select: [:id])
      end
      """

      mutateds = for {_m, _o, mutated} <- diffs(src, @with_core), do: mutated

      # The scalar sibling is core's (`true` → `false`)…
      assert "false" in mutateds
      # …the pinned value's interior is not (no bump of `n + 1`).
      refute Enum.any?(mutateds, &(&1 =~ "n + 2" or &1 =~ "n - 1" or &1 =~ "n + 0"))
      # …and the select field-name atoms stay structural, not sentinel-swapped.
      refute Enum.any?(mutateds, &(&1 =~ ":mutare]"))

      assert_compiles(src, @with_core)
    end
  end

  describe "a pinned source never blocks the machinery around it" do
    test "a composed plain-variable source still hosts its where and re-emits verbatim" do
      # A `from` source takes no `^` (Ecto rejects `from(u in ^base)` — a composed query is
      # written plain: `from u in base`), so this is the source shape a dynamic `from` uses.
      src = """
      defmodule M do
        import Ecto.Query
        def q(base, min), do: from(u in base, where: u.age > ^(min + 1), select: u.id)
      end
      """

      # The hosted condition mutates normally — the plugin's comparison swap and the relayed
      # island — with the opaque source untouched around them.
      assert {"u.age > ^(min + 1)", "u.age >= ^(min + 1)"} in ecto_diffs(src, @with_core)

      assert {:arithmetic, "u.age > ^(min + 1)", "u.age > ^(min - 1)"} in diffs_touching(
               src,
               "min - 1"
             )

      # The whole-`from` filter drop fires around the opaque source, now reported clause-level as
      # the delete of the condition value.
      assert {"u.age > ^(min + 1)", ""} in ecto_diffs(src, @with_core)

      assert_compiles(src, @with_core)
    end

    test "a fragment(...) source's pins are raw while the where still hosts" do
      # The one legal pin-carrying `from` source: a fragment source. Its pins are *source*
      # data (never a hosted condition), so `lo + 1` is nobody's — while the `where:` on the
      # fragment-sourced binding hosts and relays its island exactly as over a schema.
      src = """
      defmodule M do
        import Ecto.Query
        def q(lo, min) do
          from(f in fragment("generate_series(?::integer, 100) as x", ^(lo + 1)),
            where: f.x > ^(min + 1),
            select: f.x
          )
        end
      end
      """

      assert {"f.x > ^(min + 1)", "f.x >= ^(min + 1)"} in ecto_diffs(src, @with_core)

      assert {:arithmetic, "f.x > ^(min + 1)", "f.x > ^(min - 1)"} in diffs_touching(
               src,
               "min - 1"
             )

      # The source pin's interior is untouched by every family.
      refute Enum.any?(diffs(src, @with_core), fn {_m, _o, mutated} ->
               mutated =~ "lo - 1" or mutated =~ "lo + 2" or mutated =~ "lo + 0"
             end)

      assert_compiles(src, @with_core)
    end

    test "left_join: p in ^sub with a hosted on: — the weave and the join-type swap coexist" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(sub, min), do: from(u in User, left_join: p in ^sub, on: p.views > ^(min + 1), select: u.id)
      end
      """

      ecto = ecto_diffs(src, @with_core)

      # The on-condition hosts (its own swap + the relayed island)…
      assert {"p.views > ^(min + 1)", "p.views >= ^(min + 1)"} in ecto

      assert {:arithmetic, "p.views > ^(min + 1)", "p.views > ^(min - 1)"} in diffs_touching(
               src,
               "min - 1"
             )

      # …while the whole-`from` join-type swap (narrowing `left_join`→`inner_join`) fires around
      # the pinned source, now reported clause-level as the join key only.
      assert {"left_join:", "inner_join:"} in ecto

      assert_compiles(src, @with_core)
    end
  end

  describe "a bare pin as a boolean operand of a hosted condition" do
    test "rides the weave raw while the condition's structure and islands mutate" do
      # `^flag` is a legal boolean operand in Ecto — the host re-emits it inside the woven
      # dynamic. The connective and comparison swaps fire, the sibling pin's island relays,
      # and the flag pin itself is never rewritten (a bare variable, mutated where bound).
      src = """
      defmodule M do
        import Ecto.Query
        def q(flag, n), do: from(u in User, where: u.age > ^(n + 1) or ^flag, select: u.id)
      end
      """

      original = "u.age > ^(n + 1) or ^flag"
      ecto = ecto_diffs(src, @with_core)

      assert {original, "u.age > ^(n + 1) and ^flag"} in ecto
      assert {original, "u.age >= ^(n + 1) or ^flag"} in ecto

      assert {:arithmetic, original, "u.age > ^(n - 1) or ^flag"} in diffs_touching(
               src,
               "n - 1"
             )

      # Every condition-level mutant carries the flag pin verbatim — except the filter drop,
      # which (now reported clause-level, its `original` the condition itself) legitimately
      # deletes the whole where to `""`.
      assert Enum.all?(diffs(src, @with_core), fn {_m, o, mutated} ->
               o != original or mutated == "" or mutated =~ "^flag"
             end)

      assert_compiles(src, @with_core)
    end
  end

  describe "bindings and islands compose" do
    test "a join-referencing where re-declares [u, p] and relays both islands single-point" do
      # Integration of the two host halves: the binding accumulation (`Host.Bindings`) and the
      # island sub-contract. The woven dynamic re-declares the accumulated binding list, and
      # each pin relays independently — the sibling pin verbatim in every relayed mutant.
      src = """
      defmodule M do
        import Ecto.Query
        def q(lo, hi) do
          from(u in User,
            join: p in Post,
            on: p.user_id == u.id,
            where: u.age > ^(lo + 1) and p.views < ^(hi - 1),
            select: u.id
          )
        end
      end
      """

      original = "u.age > ^(lo + 1) and p.views < ^(hi - 1)"
      islands = diffs_touching(src, "lo") ++ diffs_touching(src, "hi")

      assert Enum.any?(islands, fn {m, o, mutated} ->
               m == :arithmetic and o == original and
                 mutated == "u.age > ^(lo - 1) and p.views < ^(hi - 1)"
             end)

      assert Enum.any?(islands, fn {m, o, mutated} ->
               m == :arithmetic and o == original and
                 mutated == "u.age > ^(lo + 1) and p.views < ^(hi + 1)"
             end)

      refute Enum.any?(islands, fn {_m, _o, mutated} ->
               mutated =~ "lo - 1" and mutated =~ "hi + 1"
             end)

      # The weave re-declares the accumulated bindings for the where's dynamic.
      assert metamutant(src, @with_core) =~ "dynamic([u, p]"

      assert_compiles(src, @with_core)
    end
  end
end
