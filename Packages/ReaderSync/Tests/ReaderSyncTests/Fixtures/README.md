Checked-in objects that pin the sync format. `sync-v1/` is a `Sync/v1` folder as it lies under an
account's folder in Tactile Texts Cloud (heads, history, blobs and the shared `PDFs/` objects),
written once with a fixed key and fixed salts, nonces and write IDs by
`SyncFixtureTests.writeTheFixture`. `SyncFixtureTests.readsTheV1Fixture` reads it with the current
code, so a change that would stop existing synced data from being read fails there first.

Never regenerate an existing fixture or edit `SyncFixtureV1`'s values. When the sync format
version rises, add a new folder (`sync-v2/`) and a new test beside the old one, and keep the old
test passing. To write a new fixture, point `TACTILE_WRITE_SYNC_FIXTURE` at a folder that does not
exist yet and run `swift test --filter writeTheFixture`.
