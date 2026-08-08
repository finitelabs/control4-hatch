-- Display labels for favorites, shared by every driver that lists them so the
-- sound machine and the volume dimmer cannot drift apart.

local Favorites = {}

--- Touch ring numbers as the Hatch app shows them: the RANK of displayOrder,
--- not its value, so orders 1 and 4 appear as rings 1 and 2.
--- @param favorites table[] Favorite records as the API returns them.
--- @return table ringByIndex Map of favorites index -> ring number.
local function ringNumbers(favorites)
  local ordered = {}
  for index, favorite in ipairs(favorites) do
    ordered[#ordered + 1] = { index = index, order = tonumber(favorite.displayOrder) }
  end
  table.sort(ordered, function(a, b)
    if a.order == b.order then
      return a.index < b.index
    end
    if a.order == nil then
      return false
    end
    if b.order == nil then
      return true
    end
    return a.order < b.order
  end)
  local ringByIndex = {}
  for rank, entry in ipairs(ordered) do
    ringByIndex[entry.index] = rank
  end
  return ringByIndex
end

local function baseName(favorite)
  return favorite.name or ("Favorite " .. tostring(favorite.id))
end

--- Display labels, indexed to line up with the favorites array.
---
--- The Hatch app allows favorites to share a name and tells them apart by ring
--- number. Only repeats get one, so a uniquely named favorite keeps the label
--- existing Programming refers to.
--- @param favorites table[]|nil
--- @return string[] labels
function Favorites.labels(favorites)
  favorites = favorites or {}
  local totals = {}
  for _, favorite in ipairs(favorites) do
    local name = baseName(favorite)
    totals[name] = (totals[name] or 0) + 1
  end

  local rings = ringNumbers(favorites)
  local labels = {}
  for index, favorite in ipairs(favorites) do
    local name = baseName(favorite)
    if (totals[name] or 0) > 1 then
      labels[index] = string.format("%s (%d)", name, rings[index] or index)
    else
      labels[index] = name
    end
  end
  return labels
end

--- Make a label safe to put in a comma-joined list, which is how Composer takes
--- both property item lists and conditional item lists. A comma inside a
--- user-named favorite would otherwise split it into two bogus entries. Apply it
--- to the list and to the value being matched so the two still compare equal.
--- @param text string|nil
--- @return string
function Favorites.listSafe(text)
  return (tostring(text or ""):gsub(",", " "))
end

--- Resolve a label produced by Favorites.labels() back to its favorite.
--- @param favorites table[]|nil
--- @param label string|nil
--- @return table|nil favorite
function Favorites.byLabel(favorites, label)
  if type(label) ~= "string" or label == "" then
    return nil
  end
  favorites = favorites or {}
  local labels = Favorites.labels(favorites)
  for index, candidate in ipairs(labels) do
    if candidate == label then
      return favorites[index]
    end
  end
  return nil
end

return Favorites
