# The app (and so `Hello.Repo`) is already started by Mix. Create the schema in
# the in-memory database once, before any test runs.
Ecto.Migrator.run(Hello.Repo, Ecto.Migrator.migrations_path(Hello.Repo), :up, all: true)

ExUnit.start()
