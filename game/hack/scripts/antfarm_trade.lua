-- antfarm_trade.lua
-- Make the fort able to trade at all, then trade deliberately.
--
-- Two caravans reached this fort and left untraded, because there was no trade
-- depot: Dreamfort places one, but only at a step the stalled build never
-- reached. On an embark with no iron ore, trade is the *only* route to iron, so
-- a missing depot is not an economic inconvenience -- it is a hard ceiling on
-- what the fort can ever become.
--
-- Usage:
--   antfarm_trade            report depot, caravan and shopping list
--   antfarm_trade site       show where a depot would go, build nothing
--   antfarm_trade depot      build a trade depot if the fort has none
--   antfarm_trade goods      queue trade goods (rock crafts) and gem cutting
--   antfarm_trade trade      run the trade driver once (operator's say-so)

--@module = true

local DEPOT_SIZE = 5          -- trade depots are 5x5
local SEARCH_RADIUS = 30      -- how far from the anchor to look for a site

-- ---------------------------------------------------------------- --
-- depot                                                            --
-- ---------------------------------------------------------------- --

function find_depot()
    for _, b in ipairs(df.global.world.buildings.all) do
        if b:getType() == df.building_type.TradeDepot then return b end
    end
    return nil
end

-- A depot needs 5x5 of flat, walkable, building-free floor a wagon can reach.
-- Proper reachability is expensive, so this uses walkable-and-undesignated as
-- the proxy and leaves the final say to DF, which refuses to place a depot it
-- cannot path a wagon to.
-- Shapes a depot can actually be built on. Restricting this to FLOOR finds
-- nothing on a real surface: the ground is mostly SHRUB, SAPLING, PEBBLES and
-- BOULDER, which are floors with something lying on them and are perfectly
-- buildable. RAMP_TOP and WALL are not, and EMPTY is open air.
local BUILDABLE = {
    [df.tiletype_shape.FLOOR] = true,
    [df.tiletype_shape.PEBBLES] = true,
    [df.tiletype_shape.BOULDER] = true,
    [df.tiletype_shape.SHRUB] = true,
    [df.tiletype_shape.SAPLING] = true,
}

local function site_is_clear(x0, y0, z)
    for x = x0, x0 + DEPOT_SIZE - 1 do
        for y = y0, y0 + DEPOT_SIZE - 1 do
            local block = dfhack.maps.getTileBlock(x, y, z)
            if not block then return false end
            local tt = block.tiletype[x % 16][y % 16]
            local des = block.designation[x % 16][y % 16]
            local shape = df.tiletype.attrs[tt].shape
            local mat = df.tiletype.attrs[tt].material
            if not BUILDABLE[shape] then return false end
            if des.flow_size and des.flow_size > 0 then return false end
            if mat == df.tiletype_material.POOL or mat == df.tiletype_material.RIVER
                    or mat == df.tiletype_material.BROOK then return false end
            -- Never drop a depot onto the fort's own construction plan.
            if des.dig ~= df.tile_dig_designation.No then return false end
            if dfhack.buildings.findAtTile(xyz2pos(x, y, z)) then return false end
        end
    end
    return true
end

-- Prefer a site close to the fort anchor: the wagon should park by the
-- entrance, not across the map.
function find_depot_site()
    local anchor, z
    local ok, bp = pcall(reqscript, 'antfarm_blueprint')
    if ok and bp and bp.plan_summary then
        local okp, summary = pcall(bp.plan_summary)
        if okp and summary and summary.anchor and summary.levels then
            anchor = summary.anchor
            z = summary.levels.surface
        end
    end
    if not anchor then
        -- No plan: use a citizen's own position, which is demonstrably where
        -- the dwarves are standing.
        local u
        for _, cand in ipairs(df.global.world.units.active) do
            if dfhack.units.isCitizen(cand) then u = cand break end
        end
        if not u then return nil, 'no anchor and no citizens to locate the surface' end
        anchor = {x = u.pos.x, y = u.pos.y}
        z = u.pos.z
    end
    if not z then return nil, 'no surface level known' end

    local best, best_d
    for dx = -SEARCH_RADIUS, SEARCH_RADIUS do
        for dy = -SEARCH_RADIUS, SEARCH_RADIUS do
            local x, y = anchor.x + dx, anchor.y + dy
            local near_stairs = x + DEPOT_SIZE - 1 >= anchor.x - 3 and x <= anchor.x + 3
                and y + DEPOT_SIZE - 1 >= anchor.y - 3 and y <= anchor.y + 3
            if not near_stairs and site_is_clear(x, y, z) then
                local d = dx * dx + dy * dy
                if not best_d or d < best_d then
                    best_d, best = d, {x = x, y = y, z = z}
                end
            end
        end
    end
    if not best then
        return nil, ('no clear %dx%d site within %d tiles of the anchor on z=%d')
            :format(DEPOT_SIZE, DEPOT_SIZE, SEARCH_RADIUS, z)
    end
    return best
end

function ensure_depot()
    if find_depot() then return false, 'depot already exists' end
    -- Without materials DF cancels the job and the depot disappears.
    local oks, sust = pcall(reqscript, 'antfarm_sustenance')
    if oks and sust and sust.opening_in_progress and sust.opening_in_progress() then
        return false, 'the guided build is still laying out the surface'
    end
    if oks and sust and sust.building_material_on_hand and not sust.building_material_on_hand() then
        return false, 'nothing to build with yet'
    end
    local site, err = find_depot_site()
    if not site then return false, err end

    -- constructBuilding takes the CENTRE of a 5x5 depot.
    local cx = site.x + math.floor(DEPOT_SIZE / 2)
    local cy = site.y + math.floor(DEPOT_SIZE / 2)
    local ok, bld = pcall(dfhack.buildings.constructBuilding, {
        type = df.building_type.TradeDepot,
        pos = xyz2pos(cx, cy, site.z),
    })
    if not ok or not bld then
        return false, 'constructBuilding failed: ' .. tostring(bld)
    end
    -- A depot nobody builds is no better than no depot.
    pcall(dfhack.run_command, 'prioritize', '-a', 'ConstructBuilding')
    return true, ('trade depot placed at %d,%d,%d'):format(cx, cy, site.z)
end

-- ---------------------------------------------------------------- --
-- caravan                                                          --
-- ---------------------------------------------------------------- --

function caravan_present()
    local ok, n = pcall(function() return #df.global.ui.caravans end)
    if not ok then return false, 0 end
    return (n or 0) > 0, n or 0
end

-- Which civilisations are at the depot. The elven case is not cosmetic:
-- offering a wooden bin or barrel -- or anything made of wood -- reads to Elves
-- as a religious atrocity, and the documented outcome is trade abandonment and
-- war (AGENTS.md 6.27). Knowing who is here decides what may be offered.
function caravan_races()
    local races = {}
    pcall(function()
        local caravans = df.global.ui.caravans
        for i = 0, #caravans - 1 do
            local car = caravans[i]
            local ent = car.entity and df.historical_entity.find(car.entity)
            local id = ent and ent.race
            local name = id and df.global.world.raws.creatures.all[id]
                and df.global.world.raws.creatures.all[id].creature_id
            if name then races[name] = true end
        end
    end)
    return races
end

function elves_present()
    return caravan_races()['ELF'] and true or false
end

-- A caravan whose wagons have reached the depot. caravan_state.trade_state,
-- verified live 2026-11-01: Approaching -> AtDepot (-> Leaving).
function caravan_at_depot()
    local found
    pcall(function()
        local caravans = df.global.ui.caravans
        for i = 0, #caravans - 1 do
            local c = caravans[i]
            if df.caravan_state.T_trade_state[c.trade_state] == 'AtDepot' then found = c end
        end
    end)
    return found
end

-- One key per caravan visit, so "already brought goods / already traded"
-- resets when the next caravan arrives.
function caravan_key(c)
    return ('%d:%d:%d'):format(c.entity or -1, df.global.cur_year or 0, df.global.cur_season or 0)
end

-- Export goods that will not offend whoever is actually at the depot. Stone
-- crafts are the safe default everywhere; wood is safe with everyone *except*
-- Elves, which is why the standing craft order is pinned to INORGANIC rather
-- than left to pick whatever boulder or log is nearest.
function safe_export_material()
    if elves_present() then
        return 'INORGANIC', 'elven caravan present -- no wood may be offered'
    end
    return 'INORGANIC', 'stone crafts are the default export'
end

-- ---------------------------------------------------------------- --
-- shopping list                                                    --
-- ---------------------------------------------------------------- --

-- What the fort should be buying. The metals survey answers the important half
-- exactly: a metal with no ore on the map can only ever be traded for.
function shopping_list()
    local list = {}
    local ok, m = pcall(reqscript, 'antfarm_metals')
    if ok and m and m.report then
        local okr, rep = pcall(m.report)
        if okr and rep then
            for _, metal in ipairs(rep.missing or {}) do
                table.insert(list, {
                    what = metal .. ' bars',
                    why = 'no ore on this embark -- trade is the only source',
                    priority = (metal == 'IRON') and 1 or 3,
                })
            end
            if rep.martial then
                table.insert(list, {
                    what = 'weapons and armour',
                    why = 'best local metal is ' .. rep.martial,
                    priority = 2,
                })
            end
        end
    end
    -- Things a young fort reliably lacks regardless of geology.
    for _, w in ipairs(trade_wants()) do
        if w.kind ~= 'bar' then
            table.insert(list, {what = ('%d more %s(s)'):format(w.limit, w.label),
                                why = 'tools set how many dwarves can work', priority = 0})
        end
    end
    table.insert(list, {what = 'cloth and thread', why = 'no textile industry yet', priority = 2})
    table.insert(list, {what = 'leather', why = 'armour and crafts', priority = 3})
    table.insert(list, {what = 'breeding pairs of livestock', why = 'long-term food security', priority = 2})
    table.insert(list, {what = 'seeds not native to this biome', why = 'farm variety', priority = 4})
    table.insert(list, {what = 'booze variety', why = 'variety is a real happiness input', priority = 4})
    table.sort(list, function(a, b) return a.priority < b.priority end)
    return list
end

-- ---------------------------------------------------------------- --
-- what goes to the depot, what is bought                           --
-- ---------------------------------------------------------------- --
--
-- Exports are FINISHED GOODS ONLY -- the operator's rule, and the wiki's
-- (DF2014:Trade goods): crafts, figurines, jewellery, goblets, instruments,
-- toys, totems and large gems are light and valuable. Rough gems are cut;
-- cut gems are set into crafts (encrusting multiplies their value) and are
-- never sold; boulders, logs, containers, tools and fort equipment stay home.
--
-- There is no CRAFTS item type: df.item_type.CRAFTS is nil in this build (read
-- live, 2026-11-02). A MakeCrafts job yields any of these instead, which is why
-- CRAFT_TYPES is a list and why stock is counted across all of it.
CRAFT_TYPES = {'FIGURINE', 'AMULET', 'BRACELET', 'EARRING', 'RING', 'CROWN', 'SCEPTER'}
EXPORT_TYPES = {
    GOBLET = true, TOTEM = true, INSTRUMENT = true, TOY = true,
    GEM = true,   -- GEM = large gem; SMALLGEM is kept
}
for _, key in ipairs(CRAFT_TYPES) do EXPORT_TYPES[key] = true end

local function made_of_wood(it)
    local ok, wood = pcall(function()
        local mi = dfhack.matinfo.decode(it)
        return mi and (mi.plant ~= nil or mi.material.flags.WOOD) and true or false
    end)
    return ok and wood
end

-- May this item leave the fort? `elves`: an elven caravan is at the depot,
-- where anything wooden is an atrocity (AGENTS.md 6.27).
function exportable(it, elves)
    local ok, good = pcall(function()
        local key = df.item_type[it:getType()]
        if not EXPORT_TYPES[key] then return false end
        local f = it.flags
        if f.artifact or f.forbid or f.owned or f.removed or f.garbage_collect
            or f.trader or f.construction or f.hostile then return false end
        if elves and made_of_wood(it) then return false end
        return true
    end)
    return ok and good
end

local MAX_EXPORT_ITEMS = 40

-- The move-goods screen (viewscreen_layer_assigntradest), verified live:
-- `info` lists every candidate as {item, status, value}; status 0 = None,
-- 1 = AddPending, which is what selecting a line does. Leaving the screen
-- turns AddPending into BringItemToDepot jobs. Marks the most valuable
-- exportable items. Returns how many were marked and their value.
function mark_exports(view)
    local elves = elves_present()
    local cands = {}
    for i = 0, #view.info - 1 do
        local e = view.info[i]
        if e.status == 0 and exportable(e.item, elves) then
            table.insert(cands, {e = e, value = e.value or 0})
        end
    end
    table.sort(cands, function(a, b) return a.value > b.value end)
    local n, value = 0, 0
    for _, c in ipairs(cands) do
        if n >= MAX_EXPORT_ITEMS then break end
        c.e.status = 1
        n, value = n + 1, value + c.value
    end
    return n, value
end

-- What to buy, in order. Tools first, because two picks is what holds an entire
-- fort behind one bottleneck, and they cost little beside what they free up. Then
-- the metals the embark has no ore for (the whole point of the depot on a map with
-- no iron), steel with iron.
--
-- `limit` is how many more are worth having. Merchants' picks and axes are real
-- weapons at real prices, so a fort that has enough stops paying for them.
local PICK_TARGET, AXE_TARGET, ANVIL_TARGET = 5, 2, 1

local function owned_weapons(subtype_id)
    local n = 0
    pcall(function()
        local weapons = df.global.world.items.other.WEAPON
        for i = 0, #weapons - 1 do
            local it = weapons[i]
            if not it.flags.trader and it.subtype and it.subtype.id == subtype_id then n = n + 1 end
        end
    end)
    return n
end

local function owned_anvils()
    local n = 0
    pcall(function()
        local anvils = df.global.world.items.other.ANVIL
        for i = 0, #anvils - 1 do
            if not anvils[i].flags.trader then n = n + 1 end
        end
    end)
    return n
end

function trade_wants()
    local wants = {}
    local picks = PICK_TARGET - owned_weapons('ITEM_WEAPON_PICK')
    if picks > 0 then
        table.insert(wants, {kind = 'weapon', subtype = 'ITEM_WEAPON_PICK', limit = picks,
                             label = 'pick', priority = 0})
    end
    local axes = AXE_TARGET - owned_weapons('ITEM_WEAPON_AXE_BATTLE')
    if axes > 0 then
        table.insert(wants, {kind = 'weapon', subtype = 'ITEM_WEAPON_AXE_BATTLE', limit = axes,
                             label = 'axe', priority = 0.5})
    end
    local anvils = ANVIL_TARGET - owned_anvils()
    if anvils > 0 then
        table.insert(wants, {kind = 'anvil', limit = anvils, label = 'anvil', priority = 0.5})
    end
    local ok, m = pcall(reqscript, 'antfarm_metals')
    if ok and m and m.report then
        local okr, rep = pcall(m.report)
        local missing = (okr and rep and rep.missing) or {}
        local set = {}
        for _, metal in ipairs(missing) do set[metal] = true end
        if set.IRON then set.STEEL = true end
        local bars = {}
        for metal in pairs(set) do
            table.insert(bars, {kind = 'bar', inorganic = metal, label = metal .. ' bar',
                                priority = (metal == 'IRON' or metal == 'STEEL') and 1 or 3})
        end
        for _, w in ipairs(bars) do table.insert(wants, w) end
    end
    table.sort(wants, function(a, b)
        if a.priority ~= b.priority then return a.priority < b.priority end
        return a.label < b.label
    end)
    return wants
end

local function inorganic_id(it)
    local ok, id = pcall(function()
        if it:getMaterial() ~= 0 then return nil end
        return df.global.world.raws.inorganics[it:getMaterialIndex()].id
    end)
    return ok and id or nil
end

local function want_matches(w, it)
    if w.kind == 'bar' then
        return it:getType() == df.item_type.BAR and inorganic_id(it) == w.inorganic
    elseif w.kind == 'weapon' then
        if it:getType() ~= df.item_type.WEAPON then return false end
        local ok, id = pcall(function() return it.subtype.id end)
        return ok and id == w.subtype
    elseif w.kind == 'anvil' then
        return it:getType() == df.item_type.ANVIL
    end
    return false
end

-- Pay at least this multiple of the goods' value: merchants want a margin,
-- and a refused offer wastes the broker's visit.
TRADE_MARGIN = 1.5

-- The trade screen (viewscreen_tradegoodsst), verified live: trader_items /
-- broker_items with parallel *_selected vectors. Picks what to buy (by
-- want priority, while the fort can pay TRADE_MARGIN x its value) and the
-- fewest exportable goods that cover it. Returns nil when nothing fits.
function plan_trade(view, wants)
    wants = wants or trade_wants()
    if #wants == 0 then return nil, 'nothing on the shopping list' end
    local elves = elves_present()
    local offer, budget = {}, 0
    for i = 0, #view.broker_items - 1 do
        local it = view.broker_items[i]
        -- At the depot already, so only the type/material/state rules apply.
        if exportable(it, elves) then
            local v = dfhack.items.getValue(it)
            table.insert(offer, {i = i, v = v})
            budget = budget + v
        end
    end
    if budget == 0 then return nil, 'no finished goods at the depot to pay with' end
    local buy, cost, taken = {}, 0, {}
    for _, w in ipairs(wants) do
        local bought = 0
        for i = 0, #view.trader_items - 1 do
            if w.limit and bought >= w.limit then break end
            local it = view.trader_items[i]
            if not taken[i] and want_matches(w, it) then
                local v = dfhack.items.getValue(it)
                if (cost + v) * TRADE_MARGIN <= budget then
                    taken[i] = true
                    bought = bought + 1
                    table.insert(buy, {i = i, v = v, want = w, item = it})
                    cost = cost + v
                end
            end
        end
    end
    if #buy == 0 then return nil, 'the merchants have nothing on the shopping list we can afford' end
    table.sort(offer, function(a, b) return a.v > b.v end)
    local need, paid, sell = cost * TRADE_MARGIN, 0, {}
    -- Largest first until covered, then drop any that are no longer needed.
    for _, o in ipairs(offer) do
        if paid >= need then break end
        table.insert(sell, o)
        paid = paid + o.v
    end
    for k = #sell, 1, -1 do
        if paid - sell[k].v >= need then paid = paid - sell[k].v; table.remove(sell, k) end
    end
    return {buy = buy, sell = sell, cost = cost, paid = paid}
end

-- Did the purchase actually happen? Goods stop being the merchants' when a trade
-- goes through: the only proof, because sending the key proves nothing.
function trade_went_through(plan)
    local ok, done = pcall(function()
        for _, b in ipairs(plan.buy) do
            if b.item.flags.trader then return false end
        end
        return true
    end)
    return ok and done or false
end

-- The liaison's import list (viewscreen_topicmeeting_takerequestsst),
-- verified live: meeting.sell_requests.priority[entity_sell_category][j],
-- 0 none .. 4 very high; for MetalBars, j indexes the liaison civ's
-- resources.metals (inorganic indices). Only ever RAISES a priority, so a
-- player's own choices survive. Returns the metals requested.
function fill_import_requests(meeting)
    local asked = {}
    local ok, err = pcall(function()
        local pri = meeting.sell_requests.priority[df.entity_sell_category.MetalBars]
        local civ = df.historical_entity.find(meeting.civ_id)
        local metals = civ.resources.metals
        local want = {}
        for _, w in ipairs(trade_wants()) do
            if w.kind == 'bar' then want[w.inorganic] = (w.priority == 1) and 4 or 3 end
        end
        for j = 0, math.min(#pri, #metals) - 1 do
            local id = df.global.world.raws.inorganics[metals[j]].id
            local p = want[id]
            if p and pri[j] < p then
                pri[j] = p
                table.insert(asked, id)
            end
        end
    end)
    if not ok then return asked, tostring(err) end
    return asked
end

-- ---------------------------------------------------------------- --
-- export goods                                                     --
-- ---------------------------------------------------------------- --

-- Rock crafts are the default export: the fort sits on unlimited stone, crafts
-- are high value per unit of hauling, and a craftsdwarf's workshop already
-- exists. Capped, because an uncapped order eats every boulder and every idle
-- dwarf.
local CRAFT_TARGET = 30

-- Finished crafts the fort still owns; merchants' stock does not count.
function count_crafts()
    local kinds, n = {}, 0
    for _, key in ipairs(CRAFT_TYPES) do kinds[df.item_type[key]] = true end
    local items = df.global.world.items.all
    for i = 0, #items - 1 do
        local it = items[i]
        if kinds[it:getType()] and not it.flags.trader then n = n + 1 end
    end
    return n
end

-- Orders nobody can fill are worse than none, and the workshops that fill these
-- sit far along Dreamfort's build order. Place them on the surface as soon as the
-- fort has a depot and something to build with. A disposable fort sat on 30 craft
-- orders and 678 boulders with no craftsdwarf's workshop, and owned nothing to sell.
function ensure_goods_workshops()
    if not find_depot() then return {} end
    local ok, sust = pcall(reqscript, 'antfarm_sustenance')
    if not ok or not sust or not sust.place_building or not sust.building_material_on_hand() then
        return {}
    end
    local placed = {}
    for _, name in ipairs({'Craftsdwarfs', 'Jewelers'}) do
        local kind = df.workshop_type[name]
        if kind and not sust.have_building(df.building_type.Workshop, kind)
                and sust.place_building(df.building_type.Workshop, kind) then
            table.insert(placed, name)
        end
    end
    return placed
end

function queue_trade_goods()
    local have = count_crafts()
    if have >= CRAFT_TARGET then
        return false, ('%d crafts in stock, target %d -- nothing queued'):format(have, CRAFT_TARGET)
    end
    local want = CRAFT_TARGET - have
    -- __reduce_amount makes `want` the outstanding target, so the tick can
    -- re-assert it without stacking a new batch every pass.
    local ok, res = pcall(dfhack.run_command, 'workorder',
        ('{"job":"MakeCrafts","amount_total":%d,"material":"INORGANIC","__reduce_amount":true}'):format(want))
    if not ok or res ~= CR_OK then
        return false, 'could not queue crafts: ' .. tostring(res)
    end
    return true, ('rock crafts for export: %d in stock, %d more ordered'):format(have, want)
end

-- Rough gems are cut, never sold: cut gems are what encrusting sets into
-- crafts. A reserve stays rough because strange moods ask for rough gems.
local ROUGH_RESERVE = 5

function queue_gem_cutting()
    local by_mat, total = {}, 0
    local rough = df.global.world.items.other.ROUGH
    for i = 0, #rough - 1 do
        local it = rough[i]
        local f = it.flags
        if not (f.trader or f.forbid or f.in_job or f.artifact or f.removed) then
            local ok, id = pcall(function()
                return it:getMaterial() == 0 and df.global.world.raws.inorganics[it:getMaterialIndex()].id
            end)
            if ok and id then by_mat[id] = (by_mat[id] or 0) + 1; total = total + 1 end
        end
    end
    local spare = total - ROUGH_RESERVE
    if spare <= 0 then return 0 end
    local ids = {}
    for id in pairs(by_mat) do table.insert(ids, id) end
    table.sort(ids, function(a, b) return by_mat[a] > by_mat[b] end)
    local queued = 0
    for _, id in ipairs(ids) do
        if spare <= 0 then break end
        local n = math.min(by_mat[id], spare)
        local ok, res = pcall(dfhack.run_command, 'workorder',
            ('{"job":"CutGems","amount_total":%d,"material":"INORGANIC:%s","__reduce_amount":true}'):format(n, id))
        if ok and res == CR_OK then queued, spare = queued + n, spare - n end
    end
    return queued
end

-- ---------------------------------------------------------------- --
-- tick / report                                                    --
-- ---------------------------------------------------------------- --

antfarm_trade_state = antfarm_trade_state or {last_depot_try = 0, notes = {}}
antfarm_trade_state.visits = antfarm_trade_state.visits or {}
antfarm_trade_state.last_goods = antfarm_trade_state.last_goods or 0
antfarm_trade_state.last_trade_try = antfarm_trade_state.last_trade_try or 0

-- Per-caravan progress the UI driver reports back: brought goods, traded.
function visit(c)
    local key = caravan_key(c)
    local v = antfarm_trade_state.visits[key]
    if not v then
        v = {brought = false, traded = false, attempts = 0}
        antfarm_trade_state.visits[key] = v
    end
    return v
end


local function note(text)
    table.insert(antfarm_trade_state.notes, 1, text)
    while #antfarm_trade_state.notes > 8 do table.remove(antfarm_trade_state.notes) end
end

-- For antfarm_ui's trade driver: one line into this module's notes.
function record(text) note(text) end

local DEPOT_RETRY_SEC = 120
local GOODS_EVERY_SEC = 600
local TRADE_RETRY_SEC = 45
-- A caravan stays long enough for goods to be hauled and the broker to walk
-- over, and each attempt only sends what is newly ready, so keep trying.
local MAX_TRADE_ATTEMPTS = 16

function tick()
    if not dfhack.isMapLoaded() then return end
    local now = (dfhack.getTickCount() or 0) / 1000
    -- The depot is the one thing worth retrying on its own: everything else
    -- about trading is pointless without it.
    if not find_depot() and now - antfarm_trade_state.last_depot_try > DEPOT_RETRY_SEC then
        antfarm_trade_state.last_depot_try = now
        local built, msg = ensure_depot()
        note(built and msg or ('depot not placed: ' .. tostring(msg)))
    end
    -- Standing production of trade goods: crafts from stone, gems cut for
    -- encrusting. Making things is also what keeps craftsdwarves content.
    if now - antfarm_trade_state.last_goods > GOODS_EVERY_SEC then
        antfarm_trade_state.last_goods = now
        local okw, placed = pcall(ensure_goods_workshops)
        if okw then
            for _, name in ipairs(placed) do note('placed a ' .. name .. ' workshop for trade goods') end
        end
        pcall(queue_trade_goods)
        pcall(queue_gem_cutting)
    end
    -- A caravan at the depot: let antfarm_ui's trade driver request the
    -- broker, bring exports and trade. It only drives the UI while a client
    -- drives the fort, and gives up on a visit after a few tries.
    local c = caravan_at_depot()
    if c and find_depot() and now - antfarm_trade_state.last_trade_try > TRADE_RETRY_SEC then
        local v = visit(c)
        if not v.traded and v.attempts < MAX_TRADE_ATTEMPTS then
            local okm, ui = pcall(reqscript, 'antfarm_ui')
            if okm and ui and ui.request_trade then
                antfarm_trade_state.last_trade_try = now
                local started = ui.request_trade()
                if started then v.attempts = v.attempts + 1 end
            end
        end
    end
end

function report()
    local depot = find_depot()
    local present, count = caravan_present()
    local list = {}
    local ok, want = pcall(shopping_list)
    if ok then
        for i = 1, math.min(#want, 6) do table.insert(list, want[i].what) end
    end
    local races = {}
    for race in pairs(caravan_races()) do table.insert(races, race) end
    table.sort(races)
    return {
        depot = depot and true or false,
        depot_id = depot and depot.id or nil,
        caravan = present,
        caravans = count,
        races = races,
        elves = elves_present(),
        wants = list,
        notes = antfarm_trade_state.notes,
    }
end

if dfhack_flags and dfhack_flags.module then
    return
end

local args = {...}
local verb = (args[1] or 'status'):lower()

if verb == 'site' then
    local site, err = find_depot_site()
    if not site then
        print('antfarm_trade: ' .. tostring(err))
    else
        print(('antfarm_trade: a %dx%d depot would go at %d,%d,%d (top-left corner)')
            :format(DEPOT_SIZE, DEPOT_SIZE, site.x, site.y, site.z))
    end
elseif verb == 'depot' then
    local _, msg = ensure_depot()
    print('antfarm_trade: ' .. tostring(msg))
elseif verb == 'goods' then
    local _, msg = queue_trade_goods()
    print('antfarm_trade: ' .. tostring(msg))
    print(('antfarm_trade: %d rough gem(s) queued for cutting'):format(queue_gem_cutting()))
elseif verb == 'trade' then
    local ok, ui = pcall(reqscript, 'antfarm_ui')
    if not ok or not ui then print('antfarm_trade: antfarm_ui unavailable'); return end
    local started, why = ui.request_trade(true)
    print('antfarm_trade: ' .. tostring(why))
else
    local depot = find_depot()
    local present, count = caravan_present()
    print('antfarm_trade: depot   = ' .. (depot and ('yes (#' .. depot.id .. ')') or 'NONE'))
    print('antfarm_trade: caravan = ' .. (present and (count .. ' on map') or 'none'))
    if elves_present() then
        print('antfarm_trade: ELVEN caravan -- offer no wood, and never a wooden')
        print('antfarm_trade: bin or barrel: it is read as an atrocity (AGENTS.md 6.27)')
    end
    print('antfarm_trade: shopping list')
    for _, w in ipairs(shopping_list()) do
        print(('   [%d] %-36s %s'):format(w.priority, w.what, w.why))
    end
end
