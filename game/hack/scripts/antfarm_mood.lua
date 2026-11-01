-- antfarm_mood.lua
-- Watch strange moods, and make sure the moody dwarf can reach what they want.
--
-- WHY
--
-- A moody dwarf who cannot gather their materials goes insane, and the fort
-- loses them for good. The one mood the old live fort had succeeded by luck: it
-- wanted bauxite and the fort sat on 367 blocks of it. Nothing was watching.
--
-- The demand is exactly readable -- the mood job's `job_items` give item type,
-- material and quantity, and the items already attached say how much has been
-- gathered -- so this module never guesses from announcement text.
-- docs/AUTOMATION-GAPS.md section 12 has the full design.
--
-- What it does, in order of how often it is the real problem:
--
--   * reports every mood: dwarf, kind, claimed workshop, each requirement with
--     needed / gathered / reachable-in-fort amounts;
--   * unforbids matching items when only forbidden ones exist, which is the
--     commonest reason a satisfiable mood stalls;
--   * flags a requirement that nothing in the fort matches, early and loudly,
--     while there is still time to trade or produce it;
--   * places the workshop a mood needs when the fort has none of that kind --
--     an unclaimable mood is as fatal as a missing material;
--   * reports moody dwarves that have not claimed a workshop, and dwarves whose
--     mood has already failed.
--
--   * when NOTHING in the fort matches, escalates (docs/AUTOMATION-GAPS.md 12):
--       - bone / shell / horn / ivory / pearl / leather: makes sure a butcher's
--         workshop exists and an animal that yields it is marked -- never a
--         pet, a war or hunting animal, or the last of its sex in the herd
--         (leather also gets a tanner's workshop and a TAN_A_HIDE order);
--       - stone blocks / cut gems: queues a manager order at the right
--         workshop, placing the workshop if the fort has none;
--       - anything else, if the operator opted in and the mood is close to
--         failing: creates the item at the dwarf's feet, announced in-game.
--
-- Conjuring is OFF by default: it is a cheat, and on a stream it must be the
-- operator's choice. Turn it on with `antfarm_mood createitem on`.
--
-- Usage:
--   antfarm_mood                     report moods and what each one still needs
--   antfarm_mood fix                 act now (also runs on tick, every 60s)
--   antfarm_mood createitem on|off   allow last-resort item creation for moods
--   antfarm_mood createitem status

--@module = true

local utils = require('utils')

local RUN_INTERVAL_SEC = 60

-- Mood kinds that still lead to an artifact. Melancholy, Raving and Berserk are
-- what a failed mood turns into.
local ACTIVE = {Fey = true, Secretive = true, Possessed = true,
                Macabre = true, Fell = true}
local FAILED = {Melancholy = true, Raving = true, Berserk = true}

antfarm_mood_state = antfarm_mood_state or {last_run = 0, notes = {}, flagged = {}, routes = {}}
antfarm_mood_state.routes = antfarm_mood_state.routes or {}

local function note(text)
    table.insert(antfarm_mood_state.notes, 1, text)
    while #antfarm_mood_state.notes > 10 do
        table.remove(antfarm_mood_state.notes)
    end
end

local function unit_name(u)
    local ok, name = pcall(function()
        return dfhack.TranslateName(dfhack.units.getVisibleName(u))
    end)
    return (ok and name and name ~= '') and name or ('unit ' .. tostring(u.id))
end

local function mood_name(u)
    local ok, name = pcall(function() return df.mood_type[u.mood] end)
    return ok and name or nil
end

local function is_mood_job(job)
    local t = job.job_type
    return t >= df.job_type.StrangeMoodCrafter and t <= df.job_type.StrangeMoodMechanics
end

-- The dwarf and the claimed workshop hang off the job's general refs, exactly
-- as DFHack's own showmood finds them.
local function job_refs(job)
    local unit, building
    for i = 0, #job.general_refs - 1 do
        local ref = job.general_refs[i]
        local t = ref:getType()
        if t == df.general_ref_type.UNIT_WORKER then unit = ref:getUnit()
        elseif t == df.general_ref_type.BUILDING_HOLDER then building = ref:getBuilding() end
    end
    return unit, building
end

-- Bars and cloth are measured in dimension units (150 to a bar), everything
-- else by count -- the same rule showmood uses.
local function by_dimension(item_type)
    return item_type == df.item_type.BAR or item_type == df.item_type.CLOTH
end

local function amount_of(it, item_type)
    if not by_dimension(item_type) then return 1 end
    local ok, d = pcall(function() return it:getTotalDimension() end)
    return (ok and type(d) == 'number') and d or 0
end

local BODY_PARTS = {'bone', 'shell', 'horn', 'pearl', 'ivory_tooth'}

-- Names as showmood prints them; anything else falls back to the enum key.
local LABELS = {BOULDER = 'boulder', BLOCKS = 'blocks', WOOD = 'log', BAR = 'bar',
                SMALLGEM = 'cut gem', ROUGH = 'rough gem', SKIN_TANNED = 'leather',
                CLOTH = 'cloth', REMAINS = 'remains', CORPSE = 'corpse'}

local function describe(ji)
    local mat = ''
    if ji.mat_type == 0 and ji.mat_index < 0 then
        -- The inorganic wildcard: matinfo calls it "rock", but it means any
        -- stone, metal or gem of the right item type.
        mat = 'any '
    elseif ji.mat_type >= 0 then
        local ok, mi = pcall(dfhack.matinfo.decode, ji.mat_type, ji.mat_index)
        if ok and mi then mat = mi:toString() .. ' ' end
    end
    if ji.item_type < 0 then
        for _, part in ipairs(BODY_PARTS) do
            local ok, set = pcall(function() return ji.flags2[part] end)
            if ok and set then return mat .. part:gsub('_', '/') end
        end
        return mat .. 'item'
    end
    local key = df.item_type[ji.item_type]
    local name = LABELS[key] or (key and key:lower():gsub('_', ' ')) or 'item'
    return mat .. name
end

-- An item the moody dwarf could actually go and fetch, forbidden or not.
local function fetchable(it)
    local f = it.flags
    if f.in_job or f.construction or f.in_building or f.garbage_collect
        or f.trader or f.hostile or f.removed or f.artifact or f.owned then
        return false
    end
    -- Held or worn by somebody: not lying about to be picked up.
    local ok, holder = pcall(dfhack.items.getHolderUnit, it)
    return not (ok and holder)
end

-- isSuitableItem checks the item against the requirement's FLAGS, not its
-- type: on a live fort a "rough gem" demand matched 1086 ordinary stones. Check
-- the type and subtype here first.
local function matches(ji, it)
    local ok, r = pcall(function()
        local t = it:getType()
        if ji.item_type >= 0 and t ~= ji.item_type then return false end
        if ji.item_subtype >= 0 and it:getSubtype() ~= ji.item_subtype then return false end
        return dfhack.job.isSuitableItem(ji, t, it:getSubtype())
            and dfhack.job.isSuitableMaterial(ji, it:getMaterial(),
                                              it:getMaterialIndex(), t)
    end)
    return ok and r == true
end

-- What the fort holds for one requirement: reachable now, and forbidden.
local function candidates(ji)
    local free, forbidden, forbidden_items = 0, 0, {}
    local items = df.global.world.items.other.IN_PLAY
    for i = 0, #items - 1 do
        local it = items[i]
        if fetchable(it) and matches(ji, it) then
            local n = amount_of(it, ji.item_type)
            if it.flags.forbid then
                forbidden = forbidden + n
                table.insert(forbidden_items, it)
            else
                free = free + n
            end
        end
    end
    return free, forbidden, forbidden_items
end

local function requirements(job)
    local out = {}
    for i = 0, #job.job_items - 1 do
        local ji = job.job_items[i]
        local got = 0
        for j = 0, #job.items - 1 do
            local ref = job.items[j]
            if ref.job_item_idx == i then
                got = got + amount_of(ref.item, ji.item_type)
            end
        end
        local free, forbidden, forbidden_items = candidates(ji)
        table.insert(out, {
            index = i,
            what = describe(ji),
            need = ji.quantity,
            got = got,
            free = free,
            forbidden = forbidden,
            unit = by_dimension(ji.item_type) and 'dimension' or 'count',
            _forbidden_items = forbidden_items,
            _ji = ji,
        })
    end
    return out
end

-- Every mood in the fort: those at work, those still looking for a workshop,
-- and those that have already failed.
function scan()
    local moods, seen = {}, {}
    for _, job in utils.listpairs(df.global.world.jobs.list) do
        if is_mood_job(job) then
            local u, b = job_refs(job)
            if u then
                seen[u.id] = true
                local ok_t, timeout = pcall(function() return u.job.mood_timeout end)
                table.insert(moods, {
                    unit_id = u.id,
                    name = unit_name(u),
                    mood = mood_name(u) or 'unknown',
                    job = df.job_type[job.job_type],
                    workshop = b and b.id or -1,
                    timeout = ok_t and timeout or nil,
                    requirements = requirements(job),
                    _unit = u,
                })
            end
        end
    end
    local waiting, failed = {}, {}
    local units = df.global.world.units.active
    for i = 0, #units - 1 do
        local u = units[i]
        local ok, citizen = pcall(dfhack.units.isCitizen, u)
        if ok and citizen and not seen[u.id] then
            local kind = mood_name(u)
            if ACTIVE[kind] then
                local ok_s, skill = pcall(function() return df.job_skill[u.job.mood_skill] end)
                table.insert(waiting, {unit_id = u.id, name = unit_name(u), mood = kind,
                                       skill = ok_s and skill or nil})
            elseif FAILED[kind] then
                table.insert(failed, {unit_id = u.id, name = unit_name(u), mood = kind})
            end
        end
    end
    return moods, waiting, failed
end

local function remaining(r) return math.max(0, r.need - r.got) end

-- Which building a mood job claims. Brooding (macabre) and fell moods have no
-- single workshop, so they are left alone.
local MOOD_SHOP = {
    StrangeMoodCrafter    = {'Workshop', 'Craftsdwarfs',     "craftsdwarf's workshop"},
    StrangeMoodJeweller   = {'Workshop', 'Jewelers',         "jeweler's workshop"},
    StrangeMoodForge      = {'Workshop', 'MetalsmithsForge', "metalsmith's forge"},
    StrangeMoodMagmaForge = {'Workshop', 'MagmaForge',       'magma forge'},
    StrangeMoodCarpenter  = {'Workshop', 'Carpenters',       "carpenter's workshop"},
    StrangeMoodMason      = {'Workshop', 'Masons',           "mason's workshop"},
    StrangeMoodBowyer     = {'Workshop', 'Bowyers',          "bowyer's workshop"},
    StrangeMoodTanner     = {'Workshop', 'Leatherworks',     'leather works'},
    StrangeMoodWeaver     = {'Workshop', 'Clothiers',        "clothier's shop"},
    StrangeMoodMechanics  = {'Workshop', 'Mechanics',        "mechanic's workshop"},
    StrangeMoodGlassmaker = {'Furnace',  'GlassFurnace',     'glass furnace'},
}

local function sustenance()
    local ok, mod = pcall(reqscript, 'antfarm_sustenance')
    return ok and type(mod) == 'table' and mod or nil
end

-- A mood that has not claimed a workshop yet, in a fort that has none of the
-- kind it needs, will never claim one: the dwarf goes insane. Place one.
-- Magma forges are never placed blind -- they need magma.
local function ensure_mood_workshop(m)
    if m.workshop >= 0 then return nil end
    local want = MOOD_SHOP[m.job]
    if not want or want[2] == 'MagmaForge' then return nil end
    local btype = df.building_type[want[1]]
    local kind = (want[1] == 'Furnace' and df.furnace_type or df.workshop_type)[want[2]]
    if btype == nil or kind == nil then return nil end
    local sus = sustenance()
    if not sus or not sus.have_building or not sus.place_building then
        return false, 'antfarm_sustenance unavailable'
    end
    if sus.have_building(btype, kind) then return nil end
    local ok, why = sus.place_building(btype, kind)
    if ok then return true, want[3] end
    return false, ('needs a %s and none could be placed: %s'):format(want[3], tostring(why))
end

-- Unforbid just enough to cover what is still missing. Returns how many items
-- were released.
local function release(r)
    local short = remaining(r) - r.free
    local released = 0
    for _, it in ipairs(r._forbidden_items) do
        if short <= 0 then break end
        it.flags.forbid = false
        released = released + 1
        short = short - amount_of(it, it:getType())
    end
    return released
end

-- ---------------------------------------------------------------- --
-- escalation: butcher, produce, and (opt-in) conjure                --
-- ---------------------------------------------------------------- --
--
-- When nothing in the fort matches a requirement, unforbidding cannot help.
-- What can, in order: butcher for body parts, queue production for what the
-- fort can make, and -- only if the operator opted in and the mood is about to
-- fail -- create the item outright. docs/AUTOMATION-GAPS.md section 12.

-- Body-part demands and the creature materials butchering yields for them.
-- Verified live 2026-11-01 (region_smoke): a bonecarver mood's requirement is
-- item_type NONE with flags2.bone + flags2.body_part, and creature raws list
-- their tissues as material ids (DOG: SKIN, BONE, TOOTH...; YAK adds HORN, HOOF).
local PART_SOURCES = {
    bone = {'BONE'}, shell = {'SHELL'}, horn = {'HORN', 'HOOF'},
    pearl = {'PEARL'}, ivory_tooth = {'IVORY', 'TOOTH'},
    leather = {'SKIN'},
}

-- A requirement butchering can serve: a body part, or tanned leather (from a
-- hide). Returns the PART_SOURCES key.
local function butcher_part(ji)
    if ji.item_type < 0 then
        for _, part in ipairs(BODY_PARTS) do
            local ok, set = pcall(function() return ji.flags2[part] end)
            if ok and set then return part end
        end
        return nil
    end
    if ji.item_type == df.item_type.SKIN_TANNED then return 'leather' end
    return nil
end

local function creature_yields(race, materials)
    local ok, cr = pcall(function() return df.global.world.raws.creatures.all[race] end)
    if not ok or not cr then return false end
    for i = 0, #cr.material - 1 do
        local id = cr.material[i].id
        for _, want in ipairs(materials) do
            if id == want then return true end
        end
    end
    return false
end

-- Tame animals of the fort's own civilisation that may be butchered: never a
-- pet, never a war or hunting animal (both cost real training), never a
-- merchant's animal (wrong civ).
local function livestock()
    local out = {}
    local civ = df.global.ui.civ_id
    local trained = {[df.profession.TRAINED_WAR] = true, [df.profession.TRAINED_HUNTER] = true}
    local units = df.global.world.units.active
    for i = 0, #units - 1 do
        local u = units[i]
        local ok, usable = pcall(function()
            return u.flags1.tame and u.civ_id == civ
                and dfhack.units.isActive(u)
                and u.relationship_ids.Pet == -1
                and not trained[u.profession]
        end)
        if ok and usable then table.insert(out, u) end
    end
    return out
end

-- The animal to butcher for `materials`. An animal already marked (by
-- autobutcher, or an earlier pass) that yields them is used as is: the fix for
-- a live fort was a butcher's workshop, not another mark -- its yaks had been
-- marked for days with nowhere to be slaughtered. Otherwise pick one whose
-- loss leaves at least one of its sex in the herd, so a breeding pair or the
-- last of a species is never taken. Returns unit, already_marked.
function pick_for_slaughter(materials)
    local herds = {}
    for _, u in ipairs(livestock()) do
        if creature_yields(u.race, materials) then
            if u.flags2.slaughter then return u, true end
            local h = herds[u.race] or {[0] = 0, [1] = 0, units = {}}
            herds[u.race] = h
            if u.sex == 0 or u.sex == 1 then h[u.sex] = h[u.sex] + 1 end
            table.insert(h.units, u)
        end
    end
    local best, best_spare, best_adult
    for _, h in pairs(herds) do
        for _, u in ipairs(h.units) do
            local spare = (h[u.sex] or 0) - 1
            local okA, adult = pcall(dfhack.units.isAdult, u)
            adult = okA and adult and true or false
            if spare >= 1 and (not best or spare > best_spare
                    or (spare == best_spare and adult and not best_adult)) then
                best, best_spare, best_adult = u, spare, adult
            end
        end
    end
    return best, false
end

local function creature_name(u)
    local ok, id = pcall(function() return df.global.world.raws.creatures.all[u.race].creature_id end)
    return ok and id and id:lower():gsub('_', ' ') or ('unit ' .. tostring(u.id))
end

-- Make sure a workshop of `kind_name` exists. nil = already there, true =
-- placed, false + why = could not place.
local function ensure_workshop(kind_name)
    local btype, kind = df.building_type.Workshop, df.workshop_type[kind_name]
    if btype == nil or kind == nil then return false, 'unknown workshop ' .. kind_name end
    local sus = sustenance()
    if not sus or not sus.have_building or not sus.place_building then
        return false, 'antfarm_sustenance unavailable'
    end
    if sus.have_building(btype, kind) then return nil end
    local ok, why = sus.place_building(btype, kind)
    if ok then return true end
    return false, tostring(why)
end

-- Submit a manager order through DFHack's workorder script. __reduce_amount
-- makes `amount` the outstanding target, so resubmitting every pass never
-- stacks orders (same contract antfarm_quarters relies on).
local function submit_order(job, amount, extra)
    local parts = {('"job":"%s"'):format(job), ('"amount_total":%d'):format(amount)}
    local keys = {}
    for k in pairs(extra or {}) do table.insert(keys, k) end
    table.sort(keys)
    for _, k in ipairs(keys) do table.insert(parts, ('"%s":"%s"'):format(k, extra[k])) end
    table.insert(parts, '"__reduce_amount":true')
    local json = '{' .. table.concat(parts, ',') .. '}'
    local ok, result = pcall(dfhack.run_command, 'workorder', json)
    if ok and result == CR_OK then return true end
    return false, ok and ('workorder returned ' .. tostring(result)) or tostring(result)
end

local function mat_token(mat_type, mat_index)
    local ok, mi = pcall(dfhack.matinfo.decode, mat_type, mat_index)
    if not ok or not mi then return nil end
    local okt, token = pcall(function() return mi:getToken() end)
    return okt and token or nil
end

-- What the fort can make for a requirement nobody holds. Each entry: the
-- workshop, the order, and how to pick its material. Tanning is a raw-defined
-- reaction in 0.47 (there is no TanAHide job type; verified live), so it goes
-- through CustomReaction exactly like the brewing orders do.
local PRODUCE = {
    BLOCKS = {shop = 'Masons', label = 'stone blocks', job = 'ConstructBlocks'},
    SMALLGEM = {shop = 'Jewelers', label = 'cut gems', job = 'CutGems', input = 'ROUGH'},
    SKIN_TANNED = {shop = 'Tanners', label = 'tanned leather', job = 'CustomReaction',
                   reaction = 'TAN_A_HIDE'},
}

-- A rough gem the fort holds whose material the requirement accepts: cut gems
-- must name their material, and naming one the fort has guarantees the order
-- has an input.
local function input_material(ji, input_type)
    local t = df.item_type[input_type]
    local items = df.global.world.items.other.IN_PLAY
    for i = 0, #items - 1 do
        local it = items[i]
        if fetchable(it) then
            local ok, good = pcall(function()
                return it:getType() == t
                    and dfhack.job.isSuitableMaterial(ji, it:getMaterial(),
                                                      it:getMaterialIndex(), ji.item_type)
            end)
            if ok and good then return it:getMaterial(), it:getMaterialIndex() end
        end
    end
end

local function produce(r, ji, short)
    local key = df.item_type[ji.item_type]
    local spec = key and PRODUCE[key]
    if not spec then return nil end
    local extra = {}
    if spec.reaction then extra.reaction = spec.reaction end
    if ji.mat_type >= 0 and ji.mat_index >= 0 then
        extra.material = mat_token(ji.mat_type, ji.mat_index)
    elseif spec.input then
        local mt, mi = input_material(ji, spec.input)
        if mt == nil then
            return false, ('no %s in the fort to make %s from'):format(spec.input:lower(), spec.label)
        end
        extra.material = mat_token(mt, mi)
    end
    if extra.material == nil and (ji.mat_type >= 0 and ji.mat_index >= 0 or spec.input) then
        return false, 'could not name the material for the order'
    end
    local placed, why = ensure_workshop(spec.shop)
    if placed == false then
        return false, ('needs a %s workshop: %s'):format(spec.shop, why)
    end
    local count = by_dimension(ji.item_type) and 1 or short
    local ok, err = submit_order(spec.job, count, extra)
    if not ok then return false, err end
    return true, ('queued %d %s%s'):format(count, spec.label,
        placed and (' and placed a ' .. spec.shop .. ' workshop') or '')
end

local function butcher_for(m, part)
    local materials = PART_SOURCES[part]
    local u, already = pick_for_slaughter(materials)
    local placed, why = ensure_workshop('Butchers')
    local shop_note = placed and ' and placed a butcher\'s workshop' or ''
    if placed == false then
        return false, ('needs a butcher\'s workshop for %s and none could be placed: %s'):format(part, why)
    end
    local extra = ''
    if part == 'leather' then
        local tanned, twhy = ensure_workshop('Tanners')
        if tanned == false then
            return false, 'needs a tanner\'s workshop and none could be placed: ' .. twhy
        end
        local ok, err = submit_order('CustomReaction', 1, {reaction = 'TAN_A_HIDE'})
        if not ok then return false, 'tanning order failed: ' .. err end
        extra = '; queued tanning' .. (tanned and ' and placed a tanner\'s workshop' or '')
    end
    if not u then
        return false, ('needs %s and no animal can be spared for it (pets, trained '
            .. 'animals and the last of each sex are kept)'):format(part)
    end
    if not already then u.flags2.slaughter = true end
    return true, ('%s the %s for %s%s%s'):format(already and 'will butcher' or 'marked for slaughter',
        creature_name(u), part, shop_note, extra)
end

-- ---- conjuring: operator opt-in, last resort ------------------------- --

local CONFIG_PATH = 'dfhack-config/antfarm_mood.json'
-- About 10 in-game days of the ~41 a mood allows (mood_timeout counts down one
-- per game tick from ~50000; verified live).
local DEFAULT_BELOW_TICKS = 12000

function load_config()
    local cfg = {createitem_last_resort = false, createitem_below_ticks = DEFAULT_BELOW_TICKS}
    local ok, json = pcall(require, 'json')
    if not ok then return cfg end
    local okd, data = pcall(json.decode_file, CONFIG_PATH)
    if okd and type(data) == 'table' then
        cfg.createitem_last_resort = data.createitem_last_resort == true
        if type(data.createitem_below_ticks) == 'number' and data.createitem_below_ticks > 0 then
            cfg.createitem_below_ticks = data.createitem_below_ticks
        end
    end
    return cfg
end

function save_config(cfg)
    local ok, json = pcall(require, 'json')
    if not ok then return false, 'json module unavailable' end
    local okw, err = pcall(json.encode_file, cfg, CONFIG_PATH)
    return okw, err
end

-- Material flags that make an inorganic a plausible fill for each item type.
local CONJURE_CLASS = {BAR = 'IS_METAL', SMALLGEM = 'IS_GEM', ROUGH = 'IS_GEM',
                       BOULDER = 'IS_STONE', BLOCKS = 'IS_STONE'}
-- Never conjure the stuff of plots and legends.
local function special(id)
    return id:find('^ADAMANTINE') or id:find('^DIVINE') or id:find('^SLADE')
        or id:find('^RAW_ADAMANTINE')
end

local function conjure_material(ji)
    if ji.mat_type >= 0 and ji.mat_index >= 0 then return ji.mat_type, ji.mat_index end
    if ji.mat_type > 0 then return nil end
    local flag = CONJURE_CLASS[df.item_type[ji.item_type] or '']
    if not flag then return nil end
    -- The cheapest acceptable material, so the cheat is as small as it can be:
    -- the first live run took raws order and conjured iron on a map whose
    -- whole point is that it has no iron.
    local inorg = df.global.world.raws.inorganics
    local best, best_value
    for i = 0, #inorg - 1 do
        local ok, good = pcall(function()
            local raw = inorg[i]
            return raw.material.flags[flag] and not special(raw.id)
                and dfhack.job.isSuitableMaterial(ji, 0, i, ji.item_type)
        end)
        if ok and good then
            local okv, value = pcall(function() return inorg[i].material.material_value end)
            value = (okv and type(value) == 'number') and value or math.huge
            if not best or value < best_value then best, best_value = i, value end
        end
    end
    if best then return 0, best end
end

local MAX_CONJURED = 10

local function conjure(m, r, ji, short, unit)
    if ji.item_type < 0 then return false, 'body parts are never conjured' end
    local mt, mi = conjure_material(ji)
    if mt == nil then return false, 'no suitable material to create' end
    local n = by_dimension(ji.item_type) and math.ceil(short / 150) or short
    n = math.min(n, MAX_CONJURED)
    local made = 0
    for _ = 1, n do
        local ok, id = pcall(dfhack.items.createItem, ji.item_type, ji.item_subtype, mt, mi, unit)
        if ok and id then made = made + 1 end
    end
    if made == 0 then return false, 'createItem failed' end
    local text = ('[antfarm] Conjured %d %s for %s\'s strange mood (operator opt-in, '
        .. 'mood about to fail)'):format(made, r.what, m.name)
    pcall(dfhack.gui.showAnnouncement, text, 13, true)  -- 13 = COLOR_LIGHTMAGENTA
    return true, text
end

-- One requirement nothing in the fort matches. Each route reports once per
-- requirement (re-running it is harmless: marks are idempotent, orders use
-- __reduce_amount, and a placed workshop is found by have_building next time).
-- Records which route was taken so report() can show it.
function escalate(m, r, short, cfg)
    local actions = {}
    local ji = r._ji
    local route_key = ('%d:%d:route'):format(m.unit_id, r.index)
    local function once(suffix, text)
        local k = route_key .. ':' .. suffix
        if not antfarm_mood_state.flagged[k] then
            antfarm_mood_state.flagged[k] = true
            table.insert(actions, text)
        end
    end
    local routes = antfarm_mood_state.routes
    local part = butcher_part(ji)
    if part then
        local ok, what = butcher_for(m, part)
        routes[route_key] = ok and 'butcher' or 'none'
        once(ok and 'butcher' or 'butcher-failed', ('%s: %s'):format(m.name, what))
    else
        local ok, what = produce(r, ji, short)
        if ok then
            routes[route_key] = 'order'
            once('order', ('%s: %s for the mood'):format(m.name, what))
        elseif ok == false then
            routes[route_key] = 'none'
            once('order-failed', ('%s: cannot produce %s -- %s'):format(m.name, r.what, what))
        end
    end
    -- Last resort, only on the operator's opt-in and only once the mood is
    -- close to failing: an insane dwarf is unrecoverable, a conjured bar is
    -- merely a cheat -- and on a stream a loud one.
    if cfg.createitem_last_resort and m.timeout and m.timeout > 0
            and m.timeout <= cfg.createitem_below_ticks
            and not antfarm_mood_state.flagged[route_key .. ':conjured'] then
        local ok, what = conjure(m, r, ji, short, m._unit)
        if ok then
            antfarm_mood_state.flagged[route_key .. ':conjured'] = true
            routes[route_key] = 'conjured'
            table.insert(actions, what)
        else
            once('conjure-failed', ('%s: could not conjure %s -- %s'):format(m.name, r.what, what))
        end
    end
    return actions
end

-- Act on what scan() found. Returns a list of human-readable actions taken.
function fix()
    local actions = {}
    local cfg = load_config()
    local moods, waiting, failed = scan()
    for _, m in ipairs(moods) do
        local placed, what = ensure_mood_workshop(m)
        if placed then
            table.insert(actions, ('%s (%s) needs a %s the fort did not have -- placed one')
                :format(m.name, m.mood, what))
        elseif placed == false then
            local key = ('%d:shop'):format(m.unit_id)
            if not antfarm_mood_state.flagged[key] then
                antfarm_mood_state.flagged[key] = true
                table.insert(actions, ('%s (%s) %s'):format(m.name, m.mood, what))
            end
        end
        for _, r in ipairs(m.requirements) do
            local short = remaining(r)
            if short > 0 and r.free < short and r.forbidden > 0 then
                local n = release(r)
                if n > 0 then
                    table.insert(actions, ('%s: unforbade %d %s'):format(m.name, n, r.what))
                end
            end
            local key = ('%d:%d'):format(m.unit_id, r.index)
            if short > 0 and r.free + r.forbidden == 0
                    and not antfarm_mood_state.flagged[key] then
                antfarm_mood_state.flagged[key] = true
                table.insert(actions, ('%s (%s) needs %s and NOTHING in the fort matches -- '
                    .. 'trade or produce it before the mood fails'):format(m.name, m.mood, r.what))
            end
            if short > 0 and r.free + r.forbidden == 0 then
                for _, a in ipairs(escalate(m, r, short, cfg)) do table.insert(actions, a) end
            end
        end
    end
    for _, w in ipairs(waiting) do
        local key = ('%d:wait'):format(w.unit_id)
        if not antfarm_mood_state.flagged[key] then
            antfarm_mood_state.flagged[key] = true
            table.insert(actions, ('%s is in a %s mood and has not claimed a workshop '
                .. '(skill %s) -- does the fort have one?'):format(w.name, w.mood, tostring(w.skill)))
        end
    end
    for _, f in ipairs(failed) do
        local key = ('%d:failed'):format(f.unit_id)
        if not antfarm_mood_state.flagged[key] then
            antfarm_mood_state.flagged[key] = true
            table.insert(actions, ('%s has gone %s -- the mood failed'):format(f.name, f.mood))
        end
    end
    return actions
end

function tick()
    if not dfhack.isMapLoaded() then return end
    local now = (dfhack.getTickCount() or 0) / 1000
    if now - antfarm_mood_state.last_run < RUN_INTERVAL_SEC then return end
    antfarm_mood_state.last_run = now
    for _, a in ipairs(fix()) do note(a) end
end

-- Plain data only: requirement rows lose their item references.
function report()
    local moods, waiting, failed = scan()
    local out = {}
    for _, m in ipairs(moods) do
        local reqs, unmet, impossible = {}, 0, 0
        for _, r in ipairs(m.requirements) do
            local short = remaining(r)
            if short > 0 then unmet = unmet + 1 end
            if short > 0 and r.free + r.forbidden == 0 then impossible = impossible + 1 end
            table.insert(reqs, {what = r.what, need = r.need, got = r.got,
                                free = r.free, forbidden = r.forbidden, unit = r.unit,
                                route = antfarm_mood_state.routes[
                                    ('%d:%d:route'):format(m.unit_id, r.index)]})
        end
        table.insert(out, {name = m.name, mood = m.mood, job = m.job,
                           workshop = m.workshop, timeout = m.timeout,
                           -- 1200 game ticks to a day.
                           days_left = m.timeout and math.floor(m.timeout / 1200) or nil,
                           unmet = unmet, impossible = impossible,
                           requirements = reqs})
    end
    return {
        moods = out,
        waiting = waiting,
        failed = failed,
        notes = antfarm_mood_state.notes,
    }
end

if dfhack_flags and dfhack_flags.module then
    return
end

local args = {...}
local verb = (args[1] or 'status'):lower()

if verb == 'createitem' then
    local cfg = load_config()
    local want = (args[2] or 'status'):lower()
    if want == 'on' or want == 'off' then
        cfg.createitem_last_resort = (want == 'on')
        local ok, err = save_config(cfg)
        if not ok then
            print('antfarm_mood: could not save ' .. CONFIG_PATH .. ': ' .. tostring(err))
            return
        end
    end
    print(('antfarm_mood: last-resort createitem is %s (below %d ticks, about %d days, of mood time left)')
        :format(cfg.createitem_last_resort and 'ON' or 'OFF', cfg.createitem_below_ticks,
                math.floor(cfg.createitem_below_ticks / 1200)))
elseif verb == 'fix' then
    local actions = fix()
    if #actions == 0 then print('antfarm_mood: nothing to do') end
    for _, a in ipairs(actions) do print('antfarm_mood: ' .. a) end
else
    local r = report()
    if #r.moods == 0 and #r.waiting == 0 and #r.failed == 0 then
        print('antfarm_mood: no strange moods')
    end
    for _, m in ipairs(r.moods) do
        print(('antfarm_mood: %s -- %s mood, %s, workshop %d, about %s days left')
            :format(m.name, m.mood, m.job, m.workshop, tostring(m.days_left)))
        for _, q in ipairs(m.requirements) do
            local state = q.got >= q.need and 'have'
                or (q.free + q.forbidden == 0 and 'NONE IN FORT')
                or (q.free >= q.need - q.got and 'reachable')
                or 'forbidden/short'
            print(('    %-28s got %d/%d %s  (reachable %d, forbidden %d)  %s%s')
                :format(q.what, q.got, q.need, q.unit == 'dimension' and 'units' or '',
                        q.free, q.forbidden, state, q.route and ('  [' .. q.route .. ']') or ''))
        end
    end
    for _, w in ipairs(r.waiting) do
        print(('antfarm_mood: %s -- %s mood, no workshop claimed yet (skill %s)')
            :format(w.name, w.mood, tostring(w.skill)))
    end
    for _, f in ipairs(r.failed) do
        print(('antfarm_mood: %s -- mood FAILED (%s)'):format(f.name, f.mood))
    end
end
