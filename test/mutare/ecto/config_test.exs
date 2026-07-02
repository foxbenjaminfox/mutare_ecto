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
      # :filter_drop → just the where-drop (a whole-`from` rewrite), no in-fragment swaps.
      drops = ecto_diffs(@src, ecto(families: [:filter_drop]))
      assert [{_original, mutated}] = drops
      assert mutated =~ "from(" and not (mutated =~ "u.age")
    end

    test "the default selection yields every default-on family" do
      all = mutated(ecto_diffs(@src))
      assert "u.age >= 18" in all
      assert "u.age > 19" in all
      assert Enum.any?(all, &(&1 =~ "from(" and not (&1 =~ "u.age")))
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

      # Portable default: left_join → inner_join only.
      portable = mutated(ecto_diffs(src, ecto(families: [:join_type])))
      assert Enum.any?(portable, &(&1 =~ "inner_join: c in assoc"))
      refute Enum.any?(portable, &(&1 =~ "right_join"))

      # Postgres: adds left_join → right_join.
      pg = mutated(ecto_diffs(src, ecto(families: [:join_type], dialects: [:postgres])))
      assert Enum.any?(pg, &(&1 =~ "inner_join: c in assoc"))
      assert Enum.any?(pg, &(&1 =~ "right_join: c in assoc"))
    end

    test "*→full join only under a FULL-capable dialect" do
      src = """
      defmodule M do
        import Ecto.Query
        def q do
          from p in Post, left_join: c in assoc(p, :comments), on: c.ok, select: p.id
        end
      end
      """

      # Portable default and a RIGHT-only dialect never introduce a FULL join.
      portable = mutated(ecto_diffs(src, ecto(families: [:join_type])))
      refute Enum.any?(portable, &(&1 =~ "full_join"))

      mysql = mutated(ecto_diffs(src, ecto(families: [:join_type], dialects: [:mysql])))
      refute Enum.any?(mysql, &(&1 =~ "full_join"))

      # Postgres and SQLite both support FULL JOIN: left_join → full_join is offered.
      for dialect <- [:postgres, :sqlite] do
        flips = mutated(ecto_diffs(src, ecto(families: [:join_type], dialects: [dialect])))

        assert Enum.any?(flips, &(&1 =~ "full_join: c in assoc")),
               "expected a full_join mutant under #{dialect}"
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
      assert :comparison in Mutare.Ecto.families()
      assert :arithmetic in Mutare.Ecto.families()
      assert :validation_drop in Mutare.Ecto.families()
      assert :persistence in Mutare.Ecto.families()
      assert :on_conflict in Mutare.Ecto.families()
      assert :query_terminal in Mutare.Ecto.families()
      assert :hook_drop in Mutare.Ecto.families()
      assert :ordering_nulls in Mutare.Ecto.families()
      assert :combination in Mutare.Ecto.families()
      assert :clause_drop in Mutare.Ecto.families()

      assert :integer_literal in Mutare.Ecto.families()
      assert :float_literal in Mutare.Ecto.families()
      assert :atom_literal in Mutare.Ecto.families()
      assert :string_literal in Mutare.Ecto.families()
      assert :boolean_literal in Mutare.Ecto.families()

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
      assert_raise ArgumentError, ~r/unknown Mutare.Ecto dialects: \[:oracle\]/, fn ->
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

    test "from_context/1 raises when the context carries neither :ecto_config nor :opts" do
      # The permissive default is gone: a context missing both keys is a programming error, not an
      # implicit all-families/no-repo config.
      assert_raise ArgumentError, ~r/expected a context with :ecto_config or :opts/, fn ->
        Mutare.Ecto.Config.from_context(%{})
      end

      # A well-formed context still resolves: :opts is parsed, a pre-parsed :ecto_config passes through.
      assert %Mutare.Ecto.Config{} =
               Mutare.Ecto.Config.from_context(%{opts: [families: [:comparison]]})

      config = Mutare.Ecto.Config.parse!(families: [:bound])
      assert Mutare.Ecto.Config.from_context(%{ecto_config: config}) == config
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

      in_place =
        Enum.find(
          sites,
          &(&1.mutator == :ecto and &1.mutated_code =~ "select: u.rank" and
              &1.mutated_code =~ "from(")
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
      # INNER↔LEFT swap is equivalent whenever no orphan row exists (e.g. a mandatory FK). Its note
      # differs from the in-fragment families', and like `:ordering_nulls` it rides the `mutate/2`
      # whole-`from` rewrite, not the host.
      src = """
      defmodule M do
        import Ecto.Query
        def q, do: from(p in Post, join: c in assoc(p, :comments), on: c.ok, select: p.id)
      end
      """

      %Mutare.Transform.Result{mutants: sites} =
        Mutare.transform_string(src,
          mutators: [{Mutare.Ecto, repo: MyApp.Repo}],
          expand_uses: true
        )

      join = Enum.find(sites, &(&1.mutated_code =~ "left_join" and &1.mutator == :ecto))

      assert join.note ==
               "kill may require an orphan row — a preserved-side row with no match (join kinds coincide when every row matches)"
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
