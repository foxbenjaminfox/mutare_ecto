# The semantic-layer tests bring up their own SQLite-backed `MyApp.Repo` in `setup_all`
# (`Mutare.Ecto.SemanticHarness.start_repo!/0`), so the Repo and the exqlite NIF's runtime cost
# only touch that one file. Every other test run stays DB-free.
ExUnit.start()
