-- Tests for src/hatch/favorites.lua, the shared favorite label logic.
--
-- This module exists because the sound machine and the volume dimmer each had
-- their own copy and they drifted: one de-duplicated repeated names, the other
-- did not, so picking the second "Brown Noise" started the first. These cases
-- are what keeps them from drifting again.
--
-- Run from the repo root:
--   LUA_PATH="$PWD/src/?.lua;$PWD/vendor/?.lua;;" luajit test/test_favorites.lua

local Favorites = require("hatch.favorites")

local pass, fail = 0, 0
local function check(name, ok, detail)
  if ok then
    pass = pass + 1
    print(string.format("  ok   %s", name))
  else
    fail = fail + 1
    print(string.format("  FAIL %s%s", name, detail and ("  -> " .. tostring(detail)) or ""))
  end
end

local function labelsOf(favorites)
  return table.concat(Favorites.labels(favorites), " | ")
end

--------------------------------------------------------------------------------
print("[1] Unique names are left alone")
--------------------------------------------------------------------------------
do
  local favs = {
    { id = 1, name = "Bedtime", displayOrder = 1 },
    { id = 2, name = "Naptime", displayOrder = 2 },
  }
  check("no number is added", labelsOf(favs) == "Bedtime | Naptime", labelsOf(favs))
  check("byLabel resolves", (Favorites.byLabel(favs, "Naptime") or {}).id == 2)
end

--------------------------------------------------------------------------------
print("[2] Repeated names are numbered by touch ring")
--------------------------------------------------------------------------------
do
  -- The ring number is the RANK of displayOrder, not its value: the Hatch app
  -- numbers the ring by position, so orders 1 and 4 show as rings 1 and 2.
  local favs = {
    { id = 10, name = "Brown Noise", displayOrder = 1 },
    { id = 20, name = "Brown Noise", displayOrder = 4 },
  }
  check("ranked, not the raw order", labelsOf(favs) == "Brown Noise (1) | Brown Noise (2)", labelsOf(favs))
  check("ring 1 resolves", (Favorites.byLabel(favs, "Brown Noise (1)") or {}).id == 10)
  check("ring 2 resolves to the OTHER favorite", (Favorites.byLabel(favs, "Brown Noise (2)") or {}).id == 20)
end

--------------------------------------------------------------------------------
print("[3] Ring order is independent of array order")
--------------------------------------------------------------------------------
do
  -- The API is not guaranteed to return favorites already sorted.
  local favs = {
    { id = 10, name = "Rain", displayOrder = 7 },
    { id = 20, name = "Rain", displayOrder = 2 },
  }
  check("numbered by displayOrder", labelsOf(favs) == "Rain (2) | Rain (1)", labelsOf(favs))
  check("ring 1 is the lower order", (Favorites.byLabel(favs, "Rain (1)") or {}).id == 20)
end

--------------------------------------------------------------------------------
print("[4] Missing fields do not break labelling")
--------------------------------------------------------------------------------
do
  local favs = {
    { id = 10, name = "Ocean" },
    { id = 20, name = "Ocean" },
  }
  check("absent displayOrder still disambiguates", labelsOf(favs) == "Ocean (1) | Ocean (2)", labelsOf(favs))

  local unnamed = { { id = 42 }, { id = 43, name = "Ocean" } }
  check("absent name falls back to the id", labelsOf(unnamed) == "Favorite 42 | Ocean", labelsOf(unnamed))

  local mixed = {
    { id = 10, name = "Wind", displayOrder = 2 },
    { id = 20, name = "Wind" },
  }
  check("no displayOrder sorts last", labelsOf(mixed) == "Wind (1) | Wind (2)", labelsOf(mixed))
end

--------------------------------------------------------------------------------
print("[5] byLabel rejects what it cannot resolve")
--------------------------------------------------------------------------------
do
  local favs = { { id = 1, name = "Bedtime", displayOrder = 1 } }
  check("unknown label", Favorites.byLabel(favs, "Nope") == nil)
  check("nil label", Favorites.byLabel(favs, nil) == nil)
  check("empty label", Favorites.byLabel(favs, "") == nil)
  check("empty favorites", Favorites.byLabel({}, "Bedtime") == nil)
  check("nil favorites", Favorites.byLabel(nil, "Bedtime") == nil)
  -- The bare name must NOT resolve once it has been numbered, or a stale saved
  -- selection would silently start whichever favorite happened to be first.
  local dupes = {
    { id = 10, name = "Brown Noise", displayOrder = 1 },
    { id = 20, name = "Brown Noise", displayOrder = 2 },
  }
  check("un-numbered name does not match a numbered entry", Favorites.byLabel(dupes, "Brown Noise") == nil)
end

--------------------------------------------------------------------------------
print("[6] Commas are neutralised for comma-joined lists")
--------------------------------------------------------------------------------
do
  -- Favorites are user-named, so a comma is reachable. Composer takes both the
  -- property list and the conditional list as one comma-joined string, so an
  -- unescaped comma splits one entry into two and the selection stops resolving.
  check("comma becomes a space", Favorites.listSafe("Rain, Heavy") == "Rain  Heavy")
  check("no comma is untouched", Favorites.listSafe("Ocean") == "Ocean")
  check("every comma goes", Favorites.listSafe("a,b,c") == "a b c")
  check("nil is safe", Favorites.listSafe(nil) == "")

  -- The round trip the volume dimmer relies on: two same-named favorites with a
  -- comma still get distinct labels AND still resolve to the right favorite.
  local favs = {
    { id = 100, name = "Rain, Heavy", displayOrder = 1 },
    { id = 200, name = "Rain, Heavy", displayOrder = 2 },
  }
  local labels = Favorites.labels(favs)
  local safe1, safe2 = Favorites.listSafe(labels[1]), Favorites.listSafe(labels[2])
  check("distinct after escaping", safe1 ~= safe2, safe1 .. " vs " .. safe2)
  check("no comma survives into the list", not safe1:find(","), safe1)

  local resolved = nil
  for index, label in ipairs(labels) do
    if Favorites.listSafe(label) == safe2 then
      resolved = favs[index].id
    end
  end
  check("escaped label resolves to the right favorite", resolved == 200, tostring(resolved))
end

--------------------------------------------------------------------------------
print("[7] Empty input")
--------------------------------------------------------------------------------
do
  check("no favorites", #Favorites.labels({}) == 0)
  check("nil favorites", #Favorites.labels(nil) == 0)
end

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
