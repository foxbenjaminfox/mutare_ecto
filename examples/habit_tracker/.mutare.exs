[
  # Mutate the data layer (the schemas + the two query/business modules), not the
  # CLI parsing or boot glue — those are IO, not the Ecto surface this example is
  # about.
  exclude: [
    "lib/habit_tracker/cli.ex",
    "lib/habit_tracker/application.ex",
    "lib/habit_tracker/release.ex"
  ],
  # Just the Ecto surface, so the run stays focused on this library's mutators.
  # Add `:all` to also bring in Mutare's built-ins (the streak arithmetic, the
  # changeset literals, and so on) for a fuller picture.
  mutators: [
    {Mutare.Ecto, repo: HabitTracker.Repo}
  ]
]
