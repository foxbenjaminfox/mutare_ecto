defmodule Mutare.Ecto.ConfigTest do
  use ExUnit.Case, async: true

  import Mutare.Ecto.TestSupport

  # Milestone 4 configuration: narrowing the catalog with `families:`, gating dialect-specific
  # mutations with `dialects:`, reporting a sub-family under its own name with `:as`, and covering
  # several repos by listing the plugin more than once.

  defp ecto(opts), do: [mutators: [{Mutare.Ecto, [repo: MyApp.Repo] ++ opts}]]
  defp mutated(diffs), do: Enum.map(diffs, fn {_o, m} -> m end)
  defp families(opts), do: opts |> Mutare.Ecto.Config.parse!() |> Mutare.Ecto.Config.families()

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

    test "repo_key/1 reads the configured repo's resolved module key (nil when unset)" do
      config = Mutare.Ecto.Config.parse!(repo: MyApp.Repo)
      assert Mutare.Ecto.Config.repo_key(config) == Mutare.Calls.module_key(MyApp.Repo)
      assert Mutare.Ecto.Config.repo_key(Mutare.Ecto.Config.parse!([])) == nil
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

  describe "family catalog + validation" do
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
      assert families(families: :default) == Mutare.Ecto.default_families()
      assert families([]) == Mutare.Ecto.default_families()
      assert families(families: :all) == Mutare.Ecto.families()
    end

    test "family_enabled?/2 reads the parsed selection" do
      config = Mutare.Ecto.Config.parse!(families: [:comparison])
      assert Mutare.Ecto.Config.family_enabled?(config, :comparison)
      refute Mutare.Ecto.Config.family_enabled?(config, :arithmetic)
    end

    test "an unknown family in an :except list fails loudly" do
      assert_raise ArgumentError, ~r/unknown Mutare.Ecto families in :except: \[:bogus\]/, fn ->
        Mutare.Ecto.Config.parse!(families: {:default, except: [:bogus]})
      end
    end

    test "an unknown option in a {:default | :all, ...} selection fails loudly" do
      assert_raise ArgumentError, ~r/the only option is :except/, fn ->
        Mutare.Ecto.Config.parse!(families: {:all, exclude: [:integer_literal]})
      end

      assert_raise ArgumentError, ~r/must be a keyword list with an :except family list/, fn ->
        Mutare.Ecto.Config.parse!(families: {:default, [:integer_literal]})
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
                     Mutare.Ecto.Config.parse!(families: :comparison)
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
