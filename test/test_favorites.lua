-- Tests for src/hatch/favorites.lua, the shared favorite label logic.
--
-- This module exists because the sound machine and the volume dimmer each had
-- their own copy and they drifted: one de-duplicated repeated names, the other
-- did not, so picking the second "Brown Noise" started the first. These cases
-- are what keeps them from drifting again.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_favorites.lua

local T = require("testlib")
local Favorites = require("hatch.favorites")

local function labelsOf(favorites)
  return table.concat(Favorites.labels(favorites), " | ")
end

T.section("Unique names are left alone")
do
  local favs = {
    { id = 1, name = "Bedtime", displayOrder = 1 },
    { id = 2, name = "Naptime", displayOrder = 2 },
  }
  T.eq("no number is added", labelsOf(favs), "Bedtime | Naptime")
  T.eq("byLabel resolves", (Favorites.byLabel(favs, "Naptime") or {}).id, 2)
end

T.section("Repeated names are numbered by touch ring")
do
  -- The ring number is the RANK of displayOrder, not its value: the Hatch app
  -- numbers the ring by position, so orders 1 and 4 show as rings 1 and 2.
  local favs = {
    { id = 10, name = "Brown Noise", displayOrder = 1 },
    { id = 20, name = "Brown Noise", displayOrder = 4 },
  }
  T.eq("ranked, not the raw order", labelsOf(favs), "Brown Noise (1) | Brown Noise (2)")
  T.eq("ring 1 resolves", (Favorites.byLabel(favs, "Brown Noise (1)") or {}).id, 10)
  T.eq("ring 2 resolves to the OTHER favorite", (Favorites.byLabel(favs, "Brown Noise (2)") or {}).id, 20)
end

T.section("Ring order is independent of array order")
do
  -- The API is not guaranteed to return favorites already sorted.
  local favs = {
    { id = 10, name = "Rain", displayOrder = 7 },
    { id = 20, name = "Rain", displayOrder = 2 },
  }
  T.eq("numbered by displayOrder", labelsOf(favs), "Rain (2) | Rain (1)")
  T.eq("ring 1 is the lower order", (Favorites.byLabel(favs, "Rain (1)") or {}).id, 20)
end

T.section("Missing fields do not break labelling")
do
  local favs = {
    { id = 10, name = "Ocean" },
    { id = 20, name = "Ocean" },
  }
  T.eq("absent displayOrder still disambiguates", labelsOf(favs), "Ocean (1) | Ocean (2)")

  local unnamed = { { id = 42 }, { id = 43, name = "Ocean" } }
  T.eq("absent name falls back to the id", labelsOf(unnamed), "Favorite 42 | Ocean")

  local mixed = {
    { id = 10, name = "Wind", displayOrder = 2 },
    { id = 20, name = "Wind" },
  }
  T.eq("no displayOrder sorts last", labelsOf(mixed), "Wind (1) | Wind (2)")
end

T.section("byLabel rejects what it cannot resolve")
do
  local favs = { { id = 1, name = "Bedtime", displayOrder = 1 } }
  T.falsy("unknown label", Favorites.byLabel(favs, "Nope"))
  T.falsy("nil label", Favorites.byLabel(favs, nil))
  T.falsy("empty label", Favorites.byLabel(favs, ""))
  T.falsy("empty favorites", Favorites.byLabel({}, "Bedtime"))
  T.falsy("nil favorites", Favorites.byLabel(nil, "Bedtime"))
  -- The bare name must NOT resolve once it has been numbered, or a stale saved
  -- selection would silently start whichever favorite happened to be first.
  local dupes = {
    { id = 10, name = "Brown Noise", displayOrder = 1 },
    { id = 20, name = "Brown Noise", displayOrder = 2 },
  }
  T.falsy("un-numbered name does not match a numbered entry", Favorites.byLabel(dupes, "Brown Noise"))
end

T.section("Commas are neutralised for comma-joined lists")
do
  -- Favorites are user-named, so a comma is reachable. Composer takes both the
  -- property list and the conditional list as one comma-joined string, so an
  -- unescaped comma splits one entry into two and the selection stops resolving.
  T.eq("comma becomes a space", Favorites.listSafe("Rain, Heavy"), "Rain  Heavy")
  T.eq("no comma is untouched", Favorites.listSafe("Ocean"), "Ocean")
  T.eq("every comma goes", Favorites.listSafe("a,b,c"), "a b c")
  T.eq("nil is safe", Favorites.listSafe(nil), "")

  -- The round trip the volume dimmer relies on: two same-named favorites with a
  -- comma still get distinct labels AND still resolve to the right favorite.
  local favs = {
    { id = 100, name = "Rain, Heavy", displayOrder = 1 },
    { id = 200, name = "Rain, Heavy", displayOrder = 2 },
  }
  local labels = Favorites.labels(favs)
  local safe1, safe2 = Favorites.listSafe(labels[1]), Favorites.listSafe(labels[2])
  T.neq("distinct after escaping", safe1, safe2)
  T.excludes("no comma survives into the list", safe1, ",")

  local resolved = nil
  for index, label in ipairs(labels) do
    if Favorites.listSafe(label) == safe2 then
      resolved = favs[index].id
    end
  end
  T.eq("escaped label resolves to the right favorite", resolved, 200)
end

T.section("Empty input")
do
  T.eq("no favorites", #Favorites.labels({}), 0)
  T.eq("nil favorites", #Favorites.labels(nil), 0)
end

T.finish()
