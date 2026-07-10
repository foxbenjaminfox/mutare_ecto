defmodule Mutare.Ecto.ConfigTest do
  use ExUnit.Case, async: true

  import Mutare.Ecto.TestSupport

  # Milestone 4 configuration: narrowing the catalog with `families:`, gating dialect-specific
  # mutations with `dialects:`, reporting a sub-family under its own name with `:as`, and covering
  # several repos by listing the plugin more than once.

  defp ecto(opts), do: [mutators: [{Mutare.Ecto, [repo: MyApp.Repo] ++ opts}]]
  defp mutated(diffs), do: Enum.map(diffs, fn {_o, m} -> m end)

  describe "families: narrows the catalog" do
    @src """
    defmodule M do
      import Ecto.Query
      def q, do: from(u in User, where: u.age > 18, select: u.id)
    end
    """

    test "a single in-fragment family keeps only its mutants" do
      # :comparison → just the boundary swap (no integer-literal bumps, no filter drop).
      assert ecto_diffs(@src, ecto(families: [:comparison])) == [{"u.age > 18", "u.age >= 18"}]

      # :integer_literal → just the literal bumps.
      lit = mutated(ecto_diffs(@src, ecto(families: [:integer_literal])))
      assert Enum.sort(lit) == Enum.sort(["u.age > 19", "u.age > 17", "u.age > 0"])
    end

    test "a single whole-from family keeps only its mutants" do
      # :filter_drop → just the where-drop (a whole-`from` rewrite, now reported at the dropped
      # clause as a clause-level DELETE), no in-fragment swaps.
      drops = ecto_diffs(@src, ecto(families: [:filter_drop]))
      assert drops == [{"u.age > 18", ""}]
    end

    test "the default selection yields every default-on family" do
      all = mutated(ecto_diffs(@src))
      assert "u.age >= 18" in all
      assert "u.age > 19" in all
      # the whole-`from` filter_drop, now a clause-level DELETE (empty mutated text)
      assert "" in all
    end
  end

  describe "string/atom/boolean literal arms are opt-in (off by default)" do
    @src """
    defmodule M do
      import Ecto.Query

      def q do
        from u in User,
          where: u.name == "ok" and u.role == :active and u.age > 18 and u.active == true,
          select: u.id
      end
    end
    """

    test "the default selection omits the string, atom, and boolean literal mutants" do
      all = mutated(ecto_diffs(@src))

      # The default-on arms still fire (the comparison swap and the integer boundary bumps)…
      assert Enum.any?(all, &(&1 =~ "u.age >= 18"))
      assert Enum.any?(all, &(&1 =~ "u.age > 19"))

      # …but the string sentinels, the atom sentinel, and the boolean flip are all withheld.
      refute Enum.any?(all, &(&1 =~ ~s|== ""| or &1 =~ ~s|== "mutare"|))
      refute Enum.any?(all, &(&1 =~ "== :mutare"))
      refute Enum.any?(all, &(&1 =~ "u.active == false"))
    end

    test "families: :all re-enables the string, atom, and boolean literal arms" do
      all = mutated(ecto_diffs(@src, ecto(families: :all)))

      assert Enum.any?(all, &(&1 =~ ~s|u.name == ""|))
      assert Enum.any?(all, &(&1 =~ ~s|u.name == "mutare"|))
      assert Enum.any?(all, &(&1 =~ "u.role == :mutare"))
      assert Enum.any?(all, &(&1 =~ "u.active == false"))
    end

    test "they can also be enabled by naming them in an explicit list" do
      strings = mutated(ecto_diffs(@src, ecto(families: [:string_literal])))
      assert Enum.any?(strings, &(&1 =~ ~s|u.name == ""|))
      refute Enum.any?(strings, &(&1 =~ "u.role == :mutare"))

      atoms = mutated(ecto_diffs(@src, ecto(families: [:atom_literal])))
      assert Enum.any?(atoms, &(&1 =~ "u.role == :mutare"))
      refute Enum.any?(atoms, &(&1 =~ ~s|u.name == ""|))

      booleans = mutated(ecto_diffs(@src, ecto(families: [:boolean_literal])))
      assert Enum.any?(booleans, &(&1 =~ "u.active == false"))
      refute Enum.any?(booleans, &(&1 =~ "u.role == :mutare"))
    end

    test "even when enabled, the structural-position guard still suppresses them" do
      # `type(u.age, :integer)` puts an atom at a structural position; with :atom_literal explicitly
      # enabled it is *still* not collapsed to :mutare (the Fragment guard wins), while an ordinary
      # in-fragment atom in the same query is.
      src = """
      defmodule M do
        import Ecto.Query

        def q do
          from u in User,
            where: u.role == :active and u.score == type(u.age, :integer),
            select: u.id
        end
      end
      """

      all = mutated(ecto_diffs(src, ecto(families: [:atom_literal])))
      assert Enum.any?(all, &(&1 =~ "u.role == :mutare"))
      refute Enum.any?(all, &(&1 =~ "type(u.age, :mutare)"))
    end
  end

  describe "default-on arms are easy to disable" do
    @src """
    defmodule M do
      import Ecto.Query
      def q, do: from(u in User, where: u.age > 18, select: u.id)
    end
    """

    test "{:default, except: [...]} drops a default-on family while keeping the rest" do
      kept = mutated(ecto_diffs(@src, ecto(families: {:default, except: [:integer_literal]})))

      # The comparison swap survives; the integer boundary bumps are gone.
      assert "u.age >= 18" in kept
      refute Enum.any?(kept, &(&1 =~ "u.age > 19"))
    end

    test "{:all, except: [...]} subtracts from the full set (opt-in arms included)" do
      src = """
      defmodule M do
        import Ecto.Query
        def q, do: from(u in User, where: u.name == "ok" and u.age > 18, select: u.id)
      end
      """

      kept = mutated(ecto_diffs(src, ecto(families: {:all, except: [:integer_literal]})))

      # `:all` re-adds the string arm; `except:` removes only the integer one.
      assert Enum.any?(kept, &(&1 =~ ~s|u.name == ""|))
      refute Enum.any?(kept, &(&1 =~ "u.age > 19"))
    end
  end

  describe "repo: scope" do
    test "query mutations do not require a configured repo" do
      src = """
      defmodule M do
        import Ecto.Query
        def q, do: from(u in User, where: u.age > 18, select: u.id)
      end
      """

      assert {"u.age > 18", "u.age >= 18"} in ecto_diffs(src,
               mutators: [{Mutare.Ecto, families: [:comparison]}]
             )
    end

    test "repo_key/1 also accepts raw opts, parsing them first (like families/1 and dialects/1)" do
      config = Mutare.Ecto.Config.parse!(repo: MyApp.Repo)
      assert Mutare.Ecto.Config.repo_key(config) == Mutare.Ecto.Config.repo_key(repo: MyApp.Repo)
      assert Mutare.Ecto.Config.repo_key(repo: MyApp.Repo) == Mutare.Calls.module_key(MyApp.Repo)
    end
  end

  describe "dialects: gates non-portable mutations" do
    test "left↔right join only under a RIGHT-capable dialect" do
      src = """
      defmodule M do
        import Ecto.Query
        def q do
          from p in Post, left_join: c in assoc(p, :comments), on: c.ok, select: p.id
        end
      end
      """

      # Portable default: left_join → inner_join only. (The join_type diff now reports the join
      # KEY only, not the `c in assoc(...)` binding.)
      portable = mutated(ecto_diffs(src, ecto(families: [:join_type])))
      assert Enum.any?(portable, &(&1 =~ "inner_join:"))
      refute Enum.any?(portable, &(&1 =~ "right_join"))

      # Postgres: adds left_join → right_join.
      pg = mutated(ecto_diffs(src, ecto(families: [:join_type], dialects: [:postgres])))
      assert Enum.any?(pg, &(&1 =~ "inner_join:"))
      assert Enum.any?(pg, &(&1 =~ "right_join:"))
    end

    test "full_join → right_join only under a RIGHT-capable dialect; → left_join is always offered" do
      src = """
      defmodule M do
        import Ecto.Query
        def q do
          from p in Post, full_join: c in assoc(p, :comments), on: c.ok, select: p.id
        end
      end
      """

      # Portable default: full_join → left_join only (never introduces a right_join). (The
      # join_type diff now reports the join KEY only, not the `c in assoc(...)` binding.)
      portable = mutated(ecto_diffs(src, ecto(families: [:join_type])))
      assert Enum.any?(portable, &(&1 =~ "left_join:"))
      refute Enum.any?(portable, &(&1 =~ "right_join"))

      # Postgres and MySQL both support RIGHT JOIN: full_join → right_join is also offered.
      for dialect <- [:postgres, :mysql] do
        flips = mutated(ecto_diffs(src, ecto(families: [:join_type], dialects: [dialect])))

        assert Enum.any?(flips, &(&1 =~ "right_join:")),
               "expected a right_join mutant under #{dialect}"
      end

      # The woven full_join branch is valid Ecto — the single build (every mutant) compiles.
      assert_compiles(src, ecto(families: [:join_type], dialects: [:postgres]))
    end
  end

  describe ":as reports a sub-family under its own name" do
    test "the recorded mutator is the :as name, not :ecto" do
      src = """
      defmodule M do
        import Ecto.Query
        def q, do: from(u in User, where: u.x == u.y, select: u.id)
      end
      """

      diffs =
        diffs(src,
          mutators: [
            {Mutare.Ecto, repo: MyApp.Repo, families: [:comparison], as: :sql_comparison}
          ]
        )

      assert {:sql_comparison, "u.x == u.y", "u.x != u.y"} in diffs
      refute Enum.any?(diffs, fn {mutator, _o, _m} -> mutator == :ecto end)
    end
  end

  describe "equivalence-sensitive families + validation" do
    test "the helper lists the data-equivalence families" do
      assert Mutare.Ecto.equivalence_sensitive_families() == [
               :comparison,
               :connective,
               :null_predicate,
               :arithmetic,
               :coalesce,
               :temporal,
               :ordering_nulls,
               :join_type
             ]

      # …and they're a subset of the full set.
      assert Mutare.Ecto.equivalence_sensitive_families() -- Mutare.Ecto.families() == []
    end

    test "the full family set is exposed" do
      # The exact set — *every* family named — so a renamed, dropped, or added family fails loudly.
      # (The old check asserted only 15 of the 26 by `in` plus a count of 26, letting the other 11
      # be silently renamed as long as the total held.)
      assert MapSet.new(Mutare.Ecto.families()) ==
               MapSet.new([
                 :comparison,
                 :connective,
                 :null_predicate,
                 :membership,
                 :arithmetic,
                 :coalesce,
                 :temporal,
                 :binding_reorder,
                 :integer_literal,
                 :float_literal,
                 :atom_literal,
                 :string_literal,
                 :boolean_literal,
                 :filter_drop,
                 :ordering,
                 :ordering_nulls,
                 :bound,
                 :join_type,
                 :combination,
                 :aggregate,
                 :query_terminal,
                 :clause_drop,
                 :persistence,
                 :on_conflict,
                 :validation_drop,
                 :hook_drop
               ])

      # …and no accidental duplicates: the list length equals the deduped-set size.
      assert length(Mutare.Ecto.families()) == 26
    end

    test "the default set is the full set minus the opt-in literal arms" do
      assert Mutare.Ecto.default_families() ==
               Mutare.Ecto.families() -- [:string_literal, :atom_literal, :boolean_literal]

      refute :string_literal in Mutare.Ecto.default_families()
      refute :atom_literal in Mutare.Ecto.default_families()
      refute :boolean_literal in Mutare.Ecto.default_families()
      assert :integer_literal in Mutare.Ecto.default_families()
      assert :float_literal in Mutare.Ecto.default_families()

      # `:default` (and an unset `families:`) resolve to that set; `:all` to the full one.
      assert Mutare.Ecto.Config.families(families: :default) == Mutare.Ecto.default_families()
      assert Mutare.Ecto.Config.families([]) == Mutare.Ecto.default_families()
      assert Mutare.Ecto.Config.families(families: :all) == Mutare.Ecto.families()
    end

    test "family_enabled?/2 also accepts a raw MapSet or keyword opts, like families/1" do
      config = Mutare.Ecto.Config.parse!(families: [:comparison])
      assert Mutare.Ecto.Config.family_enabled?(config, :comparison)
      refute Mutare.Ecto.Config.family_enabled?(config, :arithmetic)

      assert Mutare.Ecto.Config.family_enabled?(MapSet.new([:comparison]), :comparison)
      refute Mutare.Ecto.Config.family_enabled?(MapSet.new([:comparison]), :arithmetic)

      assert Mutare.Ecto.Config.family_enabled?([families: [:comparison]], :comparison)
      refute Mutare.Ecto.Config.family_enabled?([families: [:comparison]], :arithmetic)
    end

    test "an unknown family in an :except list fails loudly" do
      assert_raise ArgumentError, ~r/unknown Mutare.Ecto families in :except: \[:bogus\]/, fn ->
        Mutare.Ecto.Config.families(families: {:default, except: [:bogus]})
      end
    end

    test "an unknown option in a {:default | :all, ...} selection fails loudly" do
      assert_raise ArgumentError, ~r/the only option is :except/, fn ->
        Mutare.Ecto.Config.families(families: {:all, exclude: [:integer_literal]})
      end

      assert_raise ArgumentError, ~r/must be a keyword list with an :except family list/, fn ->
        Mutare.Ecto.Config.families(families: {:default, [:integer_literal]})
      end
    end

    test "an unknown family name fails loudly" do
      src = """
      defmodule M do
        import Ecto.Query
        def q, do: from(u in User, where: u.x == u.y)
      end
      """

      # Anchored at the start (`\A`): the message must *lead* with the "unknown families" text,
      # not bury it after the valid-families dump — this pins the `<>` operand order in validate!/1.
      assert_raise ArgumentError, ~r/\Aunknown Mutare.Ecto families: \[:bogus\]/, fn ->
        ecto_diffs(src, ecto(families: [:bogus]))
      end
    end

    test "a families: that is none of the accepted forms is rejected" do
      assert_raise ArgumentError,
                   ~r/:families must be :all, :default, a list, or \{:all \| :default, except:/,
                   fn ->
                     Mutare.Ecto.Config.families(families: :comparison)
                   end
    end

    test "unknown and malformed dialects fail deliberately" do
      assert_raise ArgumentError,
                   ~r/\Aunknown Mutare.Ecto dialects: \[:oracle\] — valid dialects are \[:postgres, :mysql, :sqlite\]\z/,
                   fn ->
                     Mutare.Ecto.Config.parse!(dialects: [:oracle])
                   end

      assert_raise ArgumentError, ~r/:dialects must be a list/, fn ->
        Mutare.Ecto.Config.parse!(dialects: :postgres)
      end
    end

    test "unknown option names fail loudly" do
      assert_raise ArgumentError,
                   ~r/\Aunknown Mutare.Ecto options: \[:familes\].*valid options are \[:repo, :families, :dialects\]/,
                   fn ->
                     Mutare.Ecto.Config.parse!(familes: [:comparison])
                   end

      # `:as` is a Mutare convention stripped before callbacks run; it is not plugin config.
      assert_raise ArgumentError, ~r/unknown Mutare.Ecto options: \[:as\]/, fn ->
        Mutare.Ecto.Config.parse!(as: :sql)
      end
    end

    test "a malformed repo and non-keyword options fail deliberately" do
      assert_raise ArgumentError, ~r/:repo must be a module atom/, fn ->
        Mutare.Ecto.Config.parse!(repo: "MyApp.Repo")
      end

      # A non-keyword list and a non-list each get their own message.
      assert_raise ArgumentError, ~r/keyword list, got a non-keyword list/, fn ->
        Mutare.Ecto.Config.parse!([:not_a_pair])
      end

      assert_raise ArgumentError, ~r/keyword list, got: 42/, fn ->
        Mutare.Ecto.Config.parse!(42)
      end
    end

    test "from_context/1 raises when the context lacks the init/1-parsed :config" do
      # Core delivers `init/1`'s parsed `%Config{}` as `context.config` on every callback path, so
      # a context missing it (or carrying raw options there) is a programming error, not an
      # implicit all-families/no-repo config.
      assert_raise ArgumentError,
                   ~r/expected a context with the init\/1-parsed :config, got: %\{\}\z/,
                   fn ->
                     Mutare.Ecto.Config.from_context(%{})
                   end

      assert_raise ArgumentError,
                   ~r/expected a context with the init\/1-parsed :config, got: %\{config: \[families: \[:comparison\]\]\}\z/,
                   fn ->
                     Mutare.Ecto.Config.from_context(%{config: [families: [:comparison]]})
                   end

      # A well-formed context resolves: the pre-parsed :config passes through.
      config = Mutare.Ecto.Config.parse!(families: [:bound])
      assert Mutare.Ecto.Config.from_context(%{config: config}) == config
    end

    test "an equivalence-sensitive mutant carries the report note; an ordinary one does not" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(roles), do: from(u in User, where: u.x == u.y and u.role in ^roles, select: u.id)
      end
      """

      %Mutare.Transform.Result{mutants: sites} =
        Mutare.transform_string(src,
          mutators: [{Mutare.Ecto, repo: MyApp.Repo}],
          expand_uses: true
        )

      # The comparison swap (== → !=) is equivalence-sensitive → the note rides onto the recorded
      # mutant (core renders it as the survivor header's trailing "— kill may require …").
      # `==`/`!=` reads the NULL-exclusion sub-case note, not the strict↔non-strict boundary one.
      comparison = Enum.find(sites, &(&1.mutated_code =~ "!=" and &1.mutator == :ecto))

      assert comparison.note ==
               "kill may require a non-NULL row — == and != differ on every concrete value but both exclude NULLs (compared as unknown), so they coincide only when every row is NULL"

      # The membership polarity flip (in → not in) is not equivalence-sensitive → no note.
      membership = Enum.find(sites, &(&1.mutated_code =~ "not in" and &1.mutator == :ecto))
      assert membership.note == nil
    end

    test "the != -> == direction reads the same NULL-exclusion note (finer tags the source operator)" do
      # `equivalence_note/2`'s `"!="` guard arm is reached only when the *written* operator is
      # `!=` (swapped to `==`) — the finer label tags the source operator, not the mutated one
      # (`u.x == u.y` above only ever exercises the `"=="` arm). Written the other way round, the
      # same NULL-exclusion note must still apply.
      src = """
      defmodule M do
        import Ecto.Query
        def q, do: from(u in User, where: u.x != u.y, select: u.id)
      end
      """

      %Mutare.Transform.Result{mutants: sites} =
        Mutare.transform_string(src,
          mutators: [{Mutare.Ecto, repo: MyApp.Repo}],
          expand_uses: true
        )

      equality = Enum.find(sites, &(&1.mutated_code =~ "u.x == u.y" and &1.mutator == :ecto))

      assert equality.note ==
               "kill may require a non-NULL row — == and != differ on every concrete value but both exclude NULLs (compared as unknown), so they coincide only when every row is NULL"
    end

    test "the two comparison sub-cases carry different notes (boundary vs NULL exclusion)" do
      # A strict↔non-strict swap and an `==`/`!=` swap survive for *opposite* data reasons — a
      # missing boundary row versus a missing non-NULL row — so each reads its own note rather than
      # one shared "three-valued logic" string.
      src = """
      defmodule M do
        import Ecto.Query
        def q, do: from(u in User, where: u.age > 18 and u.role == u.name, select: u.id)
      end
      """

      %Mutare.Transform.Result{mutants: sites} =
        Mutare.transform_string(src,
          mutators: [{Mutare.Ecto, repo: MyApp.Repo}],
          expand_uses: true
        )

      # `>` → `>=` is the strict↔non-strict boundary swap.
      boundary = Enum.find(sites, &(&1.mutated_code =~ ">=" and &1.mutator == :ecto))
      assert boundary.note =~ "a row whose value sits exactly on the bound"

      # `==` → `!=` is the NULL-exclusion sub-case — a distinct note.
      equality = Enum.find(sites, &(&1.mutated_code =~ "!=" and &1.mutator == :ecto))
      assert equality.note =~ "a non-NULL row"

      refute boundary.note == equality.note
    end

    test "the two arithmetic sub-cases carry different notes (additive vs multiplicative identity)" do
      # `+`↔`-` survive when the right operand is always 0; `*`↔`/` when it is always ±1 (or the
      # left always 0) — different fixtures, so each sub-case reads its own note, resolved from the
      # finer operator label exactly as `:comparison`'s split is.
      src = """
      defmodule M do
        import Ecto.Query
        def q(v), do: from(u in User, where: u.a + u.b > ^v and u.a * u.b < ^v, select: u.id)
      end
      """

      %Mutare.Transform.Result{mutants: sites} =
        Mutare.transform_string(src,
          mutators: [{Mutare.Ecto, repo: MyApp.Repo}],
          expand_uses: true
        )

      additive = Enum.find(sites, &(&1.mutated_code =~ "u.a - u.b" and &1.mutator == :ecto))
      assert additive.note =~ "right operand is nonzero"

      multiplicative = Enum.find(sites, &(&1.mutated_code =~ "u.a / u.b" and &1.mutator == :ecto))
      assert multiplicative.note =~ "not ±1"

      refute additive.note == multiplicative.note
    end

    test "the two coalesce sub-cases carry different notes (NULL data vs engine-default placement)" do
      # A value-position drop survives only when no NULL row exists; an ordering-position drop
      # can also survive with NULL rows present, because the engine's *default* NULL placement
      # may coincide with where the fallback ranked them (Postgres sorts NULL as larger than
      # every value, SQLite/MySQL as smaller). Each position reads its own note, resolved from
      # the finer label exactly as `:comparison`'s and `:arithmetic`'s splits are.
      src = """
      defmodule M do
        import Ecto.Query

        def q do
          from(u in User,
            order_by: [desc: coalesce(u.score, 0)],
            select: coalesce(u.score, 0)
          )
        end
      end
      """

      %Mutare.Transform.Result{mutants: sites} =
        Mutare.transform_string(src,
          mutators: [{Mutare.Ecto, repo: MyApp.Repo}],
          expand_uses: true
        )

      coalesce_sites = Enum.filter(sites, &(&1.mutator == :ecto and "coalesce" in &1.variant))
      ordering = Enum.find(coalesce_sites, &("coalesce_in_ordering" in &1.variant))
      value = Enum.find(coalesce_sites, &("coalesce_in_ordering" not in &1.variant))

      assert value.note =~ "the exact rows the default exists for"
      assert ordering.note =~ "default NULL placement"
      refute value.note == ordering.note
    end

    test "the / -> * direction reads the same multiplicative-identity note (finer tags the source operator)" do
      # Mirrors the comparison case above: the `"/"` guard arm is reached only when the *written*
      # operator is `/` (swapped to `*`) — the earlier test's `u.a * u.b` only ever exercises the
      # `"*"` arm.
      src = """
      defmodule M do
        import Ecto.Query
        def q(v), do: from(u in User, where: u.a / u.b < ^v, select: u.id)
      end
      """

      %Mutare.Transform.Result{mutants: sites} =
        Mutare.transform_string(src,
          mutators: [{Mutare.Ecto, repo: MyApp.Repo}],
          expand_uses: true
        )

      multiplicative = Enum.find(sites, &(&1.mutated_code =~ "u.a * u.b" and &1.mutator == :ecto))
      assert multiplicative.note =~ "not ±1"
    end

    test "a coalesce drop carries its NULL-data note on both delivery paths" do
      # The same family rides the host (a `where` coalesce) and the in-place `select` rewrite —
      # the note must surface on each, since either survivor may be an honest NULL-data gap.
      src = """
      defmodule M do
        import Ecto.Query

        def q(d) do
          from(u in User, where: coalesce(u.score, ^d) > 10, select: coalesce(u.rank, ^d))
        end
      end
      """

      %Mutare.Transform.Result{mutants: sites} =
        Mutare.transform_string(src,
          mutators: [{Mutare.Ecto, repo: MyApp.Repo}],
          expand_uses: true
        )

      hosted = Enum.find(sites, &(&1.mutated_code == "u.score > 10" and &1.mutator == :ecto))
      assert hosted.note =~ "NULL rows in the wrapped expression"

      # The in-place `select` rewrite now reports at the clause value: coalesce(u.rank, ^d) → u.rank.
      in_place =
        Enum.find(
          sites,
          &(&1.mutator == :ecto and &1.original_code == "coalesce(u.rank, ^d)" and
              &1.mutated_code == "u.rank")
        )

      assert in_place.note =~ "NULL rows in the wrapped expression"
    end

    test "a non-hosted ordering_nulls mutant carries the note too (mutate/2 delivery)" do
      # `:ordering_nulls` is equivalence-sensitive but delivered in place via `mutate/2`, not the
      # host. Now that core accepts a `%Mutare.Mutator.Mutation{}` on the `mutate/2` return, its note
      # rides onto the Site just like the in-fragment families' — so the advisory surfaces for *every*
      # equivalence-sensitive family, not only the hosted three.
      src = """
      defmodule M do
        import Ecto.Query
        def q, do: from(u in User, order_by: [asc_nulls_first: u.score], select: u.id)
      end
      """

      %Mutare.Transform.Result{mutants: sites} =
        Mutare.transform_string(src,
          mutators: [{Mutare.Ecto, repo: MyApp.Repo}],
          expand_uses: true
        )

      # The NULLs-placement flip (asc_nulls_first → asc_nulls_last) is the ordering_nulls mutant; the
      # direction flip (→ desc_nulls_first) is plain :ordering and carries no note.
      nulls = Enum.find(sites, &(&1.mutated_code =~ "asc_nulls_last" and &1.mutator == :ecto))

      assert nulls.note ==
               "kill may require NULL rows in the ordered column — nulls_first and nulls_last only change where NULLs sort, ordering all other rows identically"

      direction =
        Enum.find(sites, &(&1.mutated_code =~ "desc_nulls_first" and &1.mutator == :ecto))

      assert direction.note == nil
    end

    test "a join_type mutant carries the join-cardinality note (mutate/2 delivery)" do
      # `:join_type` is equivalence-sensitive for a *data* reason, not three-valued logic: the
      # LEFT↔INNER narrowing is equivalent whenever no orphan row exists (e.g. a mandatory FK). Its
      # note differs from the in-fragment families', and like `:ordering_nulls` it rides the
      # `mutate/2` whole-`from` rewrite, not the host.
      src = """
      defmodule M do
        import Ecto.Query
        def q, do: from(p in Post, left_join: c in assoc(p, :comments), on: c.ok, select: p.id)
      end
      """

      %Mutare.Transform.Result{mutants: sites} =
        Mutare.transform_string(src,
          mutators: [{Mutare.Ecto, repo: MyApp.Repo}],
          expand_uses: true
        )

      join = Enum.find(sites, &(&1.mutated_code =~ "inner_join" and &1.mutator == :ecto))

      assert join.note ==
               "kill may require an orphan row — a preserved-side row with no match (join kinds coincide when every row matches)"
    end

    test "the connective, null_predicate, and temporal notes each ride onto their own mutant" do
      # The remaining equivalence-sensitive families the other note tests don't pin: `:connective`
      # (`and`↔`or`), `:null_predicate` (`is_nil`↔`not is_nil`), and `:temporal` (`ago`↔`from_now`).
      # Each reads a *distinct* note, so a wrong family→note wiring would surface the wrong string —
      # pin a phrase unique to each.
      src = """
      defmodule M do
        import Ecto.Query

        def q do
          from(u in User,
            where: u.active and is_nil(u.score) and u.joined_at > ago(1, "day"),
            select: u.id
          )
        end
      end
      """

      %Mutare.Transform.Result{mutants: sites} =
        Mutare.transform_string(src,
          mutators: [{Mutare.Ecto, repo: MyApp.Repo}],
          expand_uses: true
        )

      connective = Enum.find(sites, &(&1.mutator == :ecto and &1.mutated_code =~ ~r/\bor\b/))
      assert connective.note =~ "the operands disagree"

      null_predicate =
        Enum.find(sites, &(&1.mutator == :ecto and &1.mutated_code =~ "not is_nil(u.score)"))

      assert null_predicate.note =~ "complementary row sets"

      temporal = Enum.find(sites, &(&1.mutator == :ecto and &1.mutated_code =~ "from_now"))
      assert temporal.note =~ "opposite sides of now"

      # …and a family that is *not* equivalence-sensitive (the `>` boundary swap here is, but the
      # membership-free condition carries no non-sensitive counterexample) — sanity-check that the
      # three notes are genuinely different from one another.
      assert connective.note != null_predicate.note
      assert null_predicate.note != temporal.note
    end

    test "tagged/1 only relays an already-final Mutation when it actually carries a producer" do
      # `tagged/1`'s `%Mutation{producer: producer} = relayed when not is_nil(producer)` clause is
      # the *only* clause that can ever match a bare `%Mutation{}` struct (the other two clauses
      # match plain `{family, node}`/`{family, node, finer}` tuples) — so it isn't merely narrowing
      # an already-Mutation-shaped input, it's the contract that every relayed struct reaching here
      # is producer-set (as every real caller — `Mutare.Ecto.Dynamic`'s island sub-contract —
      # guarantees). A producer-less Mutation is a contract violation, and should fail loudly
      # rather than quietly pass through unrelayed.
      spec = Mutare.Mutator.Spec.for_module(Mutare.Mutators.Arithmetic)
      relayed = Mutare.Mutator.Mutation.new(quote(do: 1 + 1), producer: spec)
      assert Mutare.Ecto.Config.tagged(relayed) == relayed

      producerless = Mutare.Mutator.Mutation.new(quote(do: 1 + 1))

      assert_raise FunctionClauseError, fn ->
        Mutare.Ecto.Config.tagged(producerless)
      end
    end

    test "finalize/2 resolves the equivalence note from the *first* finer label, not the last" do
      # No real producer currently emits more than one finer label for an equivalence-sensitive
      # family (`:comparison`'s is always a single operator string), so this is a contract pin, not
      # an observed-in-the-wild shape: construct a variant whose finer list disagrees between its
      # first (">",  the default boundary note) and last ("==", the NULL-exclusion note) label, and
      # confirm the first one wins.
      context = %{config: Mutare.Ecto.Config.parse!([])}
      mutation = Mutare.Mutator.Mutation.new(quote(do: 1 > 2), variant: [:comparison, ">", "=="])

      assert %Mutare.Mutator.Mutation{note: note} = Mutare.Ecto.Config.finalize(mutation, context)
      assert note =~ "a row whose value sits exactly on the bound"
    end
  end

  describe "multiple repos" do
    test "an aggregate is matched against each configured repo, under its own name" do
      src = """
      defmodule M do
        def a(q), do: Accounts.Repo.aggregate(q, :sum, :amount)
        def b(q), do: Billing.Repo.aggregate(q, :sum, :total)
      end
      """

      diffs =
        diffs(src,
          mutators: [
            {Mutare.Ecto, repo: Accounts.Repo, families: [:aggregate], as: :accounts},
            {Mutare.Ecto, repo: Billing.Repo, families: [:aggregate], as: :billing}
          ]
        )

      assert Enum.any?(diffs, fn {m, o, mut} ->
               m == :accounts and o =~ "Accounts.Repo" and o =~ ":sum" and mut =~ ":avg"
             end)

      assert Enum.any?(diffs, fn {m, o, mut} ->
               m == :billing and o =~ "Billing.Repo" and o =~ ":sum" and mut =~ ":avg"
             end)

      # Each repo's mutator only fires on its own Repo's call.
      assert Enum.count(diffs, fn {m, _o, _} -> m == :accounts end) == 1
      assert Enum.count(diffs, fn {m, _o, _} -> m == :billing end) == 1
    end
  end
end
