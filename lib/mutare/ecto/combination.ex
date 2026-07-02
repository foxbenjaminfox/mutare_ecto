defmodule Mutare.Ecto.Combination do
  @moduledoc false
  # The shared set-operation swap catalog (`INTERSECT`↔`EXCEPT`) — used by both delivery forms:
  # the whole-`from` clause-key swap (`Mutare.Ecto.Query`, `intersect: ^q` → `except: ^q`) and the
  # standalone/pipe macro-name swap (`Mutare.Ecto.Clause`, `q |> intersect(^other)` →
  # `q |> except(^other)`). "Does any test pin *which* rows the combination keeps?" — the two
  # operations partition the left query's rows (A∩B vs A∖B are disjoint), so any row in the left
  # query distinguishes them.
  #
  # The swap preserves duplicate-handling: plain↔plain, `_all`↔`_all` — never `intersect`↔
  # `intersect_all`, which would conflate the set-op swap with a distinctness mutation. It is also
  # **portable** (no `dialects:` gate): unlike the `FULL JOIN` introduction, it only permutes forms
  # of equal adapter support — any adapter that runs the written `intersect_all` runs `except_all`.
  #
  # `union`/`union_all` are deliberately absent: `union` has no single set-theoretic complement
  # (both `intersect` and `except` are candidates), so a union swap would be an arbitrary choice
  # rather than a principled pair. Union stages still get the orthogonal `:clause_drop`.

  @flips %{
    intersect: :except,
    except: :intersect,
    intersect_all: :except_all,
    except_all: :intersect_all
  }

  @doc "The swapped set operation for a combination macro/clause name, or `nil` for any other name."
  @spec swap(atom()) :: atom() | nil
  def swap(name), do: Map.get(@flips, name)

  @doc """
  The finer `# mutare:ignore` label for a combination swap: the **source** operation's name
  (`# mutare:ignore[ecto:intersect]` leaves an `intersect`'s swap alone). The `_all` variants keep
  their own labels — `INTERSECT` and `INTERSECT ALL` are different SQL, so they suppress separately.
  """
  @spec label(atom()) :: String.t()
  def label(name) when is_map_key(@flips, name), do: Atom.to_string(name)

  @doc false
  # The finer labels the `:combination` family can emit — derived from the flip table's keys so the
  # vocabulary can't drift. Folded into the plugin's variant vocabulary by `Mutare.Ecto.variants/0`.
  @spec variant_labels() :: [String.t()]
  def variant_labels, do: @flips |> Map.keys() |> Enum.map(&label/1)
end
