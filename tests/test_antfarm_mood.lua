-- Strange-mood watcher: requirement accounting, unforbidding, early warnings.
-- Run: lua tests/test_antfarm_mood.lua

local stub = dofile('tests/df_stub.lua')
local vector = stub.vector
local SCRIPT = 'game/hack/scripts/antfarm_mood.lua'

local pass, fail = 0, 0
local function check(name, ok, detail)
    if ok then
        pass = pass + 1
        print('  ok    ' .. name)
    else
        fail = fail + 1
        print(('  FAIL  %s%s'):format(name, detail and (' -- ' .. tostring(detail)) or ''))
    end
end

-- A two-way enum, as df.* enums are: name -> number and number -> name.
local function enum(t)
    local e = {}
    for k, v in pairs(t) do e[k] = v; e[v] = k end
    return e
end

local MAT_BAUXITE, MAT_IRON = 10, 11
local MAT_NAMES = {[MAT_BAUXITE] = 'bauxite', [MAT_IRON] = 'iron'}

local function fresh()
    local w = stub.new()
    local df = w.df
    df.job_type = enum{StrangeMoodCrafter = 55, StrangeMoodJeweller = 56,
                       StrangeMoodMagmaForge = 58, StrangeMoodGlassmaker = 66,
                       StrangeMoodMechanics = 67, Dig = 1}
    df.building_type = enum{Workshop = 1, Furnace = 2}
    df.workshop_type = enum{Craftsdwarfs = 3, Jewelers = 4, MagmaForge = 6}
    df.furnace_type = enum{GlassFurnace = 3}
    df.item_type = enum{NONE = -1, BAR = 0, BOULDER = 3, ROUGH = 5, CLOTH = 9}
    df.mood_type = enum{None = -1, Fey = 0, Secretive = 1, Possessed = 2,
                        Macabre = 3, Fell = 4, Melancholy = 5, Raving = 6, Berserk = 7}
    df.job_skill = enum{STONECRAFT = 5, CUTGEM = 6}
    df.general_ref_type = {UNIT_WORKER = 1, BUILDING_HOLDER = 2}
    df.global.world.items.other = {IN_PLAY = vector{}}
    df.global.world.units.active = vector{}
    df.global.world.jobs = {list = {}}
    w.job_list = {}

    -- Like the real one, isSuitableItem checks flags only and accepts any item
    -- TYPE. A stub that compared types hid a live bug: a rough-gem demand
    -- matched 1086 stones.
    w.dfhack.job = {
        isSuitableItem = function() return true end,
        isSuitableMaterial = function(ji, mat)
            return ji.mat_type < 0 or ji.mat_type == mat
        end,
    }
    w.dfhack.matinfo = {decode = function(t)
        return {toString = function() return MAT_NAMES[t] or 'stuff' end}
    end}
    w.dfhack.items = w.dfhack.items or {}
    w.dfhack.items.getHolderUnit = function(it) return it._holder end
    return w, stub.load(w, SCRIPT)
end

local function add_unit(w, id, mood, extra)
    local u = {id = id, name = 'Dwarf' .. id, mood = w.df.mood_type[mood] or -1,
               job = {mood_timeout = 0, mood_skill = 5}}
    for k, v in pairs(extra or {}) do u[k] = v end
    w.df.global.world.units.active:push(u)
    return u
end

local function add_item(w, item_type, mat, opts)
    opts = opts or {}
    local it = {
        flags = {forbid = opts.forbid or false},
        _holder = opts.holder,
        getType = function() return item_type end,
        getSubtype = function() return -1 end,
        getMaterial = function() return mat end,
        getMaterialIndex = function() return 0 end,
        getTotalDimension = function() return opts.dimension or 150 end,
    }
    w.df.global.world.items.other.IN_PLAY:push(it)
    return it
end

local function job_item(item_type, mat, quantity)
    return {item_type = item_type, item_subtype = -1, mat_type = mat or -1,
            mat_index = (mat == 0) and -1 or 0,
            quantity = quantity or 1, flags2 = {}}
end

-- A mood job: the dwarf and workshop hang off general_refs; attached items
-- reference the requirement they fill by job_item_idx.
local function add_mood_job(w, u, job_type, job_items, attached, unclaimed)
    local refs = vector{
        {getType = function() return w.df.general_ref_type.UNIT_WORKER end,
         getUnit = function() return u end},
    }
    if not unclaimed then
        refs:push({getType = function() return w.df.general_ref_type.BUILDING_HOLDER end,
                   getBuilding = function() return {id = 77} end})
    end
    local job = {job_type = w.df.job_type[job_type], general_refs = refs,
                 job_items = vector(job_items), items = vector(attached or {})}
    table.insert(w.job_list, job)
    return job
end

local function find_req(env, what)
    for _, m in ipairs(env.report().moods) do
        for _, q in ipairs(m.requirements) do
            if q.what == what then return m, q end
        end
    end
end

print('antfarm_mood')

-- No moods: a quiet report and no actions.
do
    local w, env = fresh()
    add_unit(w, 1, 'None')
    local r = env.report()
    check('no moods: empty report', #r.moods == 0 and #r.waiting == 0 and #r.failed == 0)
    check('no moods: fix() does nothing', #env.fix() == 0)
end

-- A dwarf in the first position of the units vector is still seen. DFHack's
-- ipairs starts at 0 on real vectors but not on the stub; index loops must be
-- used so neither misses element 0.
do
    local w, env = fresh()
    add_unit(w, 1, 'Fey')
    check('a moody dwarf at vector index 0 is reported',
          #env.report().waiting == 1)
end

-- Requirement accounting: attached items count toward `got`, bars by
-- dimension, and matching loose items are counted as reachable.
do
    local w, env = fresh()
    local u = add_unit(w, 1, 'Fey')
    local attached_bar = {getType = function() return w.df.item_type.BAR end,
                          getTotalDimension = function() return 150 end}
    add_mood_job(w, u, 'StrangeMoodCrafter', {
        job_item(w.df.item_type.BOULDER, MAT_BAUXITE, 2),
        job_item(w.df.item_type.BAR, -1, 450),
    }, {{job_item_idx = 1, item = attached_bar}})
    add_item(w, w.df.item_type.BOULDER, MAT_BAUXITE)
    add_item(w, w.df.item_type.BOULDER, MAT_IRON)          -- wrong material
    add_item(w, w.df.item_type.BAR, MAT_IRON, {dimension = 150})

    local r = env.report()
    check('an active mood is reported with its workshop',
          #r.moods == 1 and r.moods[1].mood == 'Fey'
          and r.moods[1].job == 'StrangeMoodCrafter' and r.moods[1].workshop == 77)
    local _, boulder = find_req(env, 'bauxite boulder')
    check('only matching material counts as reachable',
          boulder and boulder.free == 1 and boulder.got == 0 and boulder.need == 2,
          boulder and ('free=%d got=%d'):format(boulder.free, boulder.got))
    local _, bar = find_req(env, 'bar')
    check('bars are counted by dimension, attached and loose',
          bar and bar.got == 150 and bar.free == 150 and bar.need == 450,
          bar and ('got=%d free=%d'):format(bar.got, bar.free))
    check('an attached mood dwarf is not also listed as waiting', #r.waiting == 0)
end

-- The live bug: a rough-gem demand must not count stones, whatever
-- isSuitableItem says. Wildcard material reads as "any".
do
    local w, env = fresh()
    local u = add_unit(w, 1, 'Fey')
    add_mood_job(w, u, 'StrangeMoodJeweller', {job_item(w.df.item_type.ROUGH, 0, 1)})
    for _ = 1, 5 do add_item(w, w.df.item_type.BOULDER, 0) end
    add_item(w, w.df.item_type.ROUGH, 0)
    local _, q = find_req(env, 'any rough gem')
    check('a rough-gem demand is labelled like showmood', q ~= nil)
    check('stones do not count toward a rough-gem demand', q and q.free == 1,
          q and tostring(q.free))
end

-- The commonest stall: the item exists but is forbidden. Unforbid exactly
-- what is short, and nothing that is held by somebody.
do
    local w, env = fresh()
    local u = add_unit(w, 1, 'Secretive')
    add_mood_job(w, u, 'StrangeMoodJeweller', {job_item(w.df.item_type.ROUGH, -1, 2)})
    local a = add_item(w, w.df.item_type.ROUGH, MAT_BAUXITE, {forbid = true})
    local b = add_item(w, w.df.item_type.ROUGH, MAT_BAUXITE, {forbid = true})
    local c = add_item(w, w.df.item_type.ROUGH, MAT_BAUXITE, {forbid = true})
    local held = add_item(w, w.df.item_type.ROUGH, MAT_BAUXITE,
                          {forbid = true, holder = {id = 9}})

    local actions = env.fix()
    local released = 0
    for _, it in ipairs({a, b, c}) do
        if not it.flags.forbid then released = released + 1 end
    end
    check('fix() unforbids just enough forbidden items', released == 2, tostring(released))
    check('an item held by a unit is never touched', held.flags.forbid == true)
    check('the unforbid is reported as an action',
          #actions == 1 and actions[1]:find('unforbade 2', 1, true) ~= nil,
          table.concat(actions, ' | '))
    check('a second pass changes nothing more', #env.fix() == 0)
end

-- Nothing in the fort matches: flag it once, loudly, early.
do
    local w, env = fresh()
    local u = add_unit(w, 1, 'Possessed')
    add_mood_job(w, u, 'StrangeMoodCrafter', {job_item(w.df.item_type.BAR, MAT_IRON, 150)})
    local actions = env.fix()
    check('an unsatisfiable requirement is flagged',
          #actions == 1 and actions[1]:find('NOTHING in the fort matches', 1, true) ~= nil,
          table.concat(actions, ' | '))
    check('the warning is not repeated every pass', #env.fix() == 0)
    check('report counts the impossible requirement', env.report().moods[1].impossible == 1)
end

-- A met requirement is not acted on even if more forbidden copies exist.
do
    local w, env = fresh()
    local u = add_unit(w, 1, 'Fey')
    local attached = {getType = function() return w.df.item_type.BOULDER end}
    add_mood_job(w, u, 'StrangeMoodCrafter', {job_item(w.df.item_type.BOULDER, -1, 1)},
                 {{job_item_idx = 0, item = attached}})
    local spare = add_item(w, w.df.item_type.BOULDER, MAT_BAUXITE, {forbid = true})
    env.fix()
    check('a satisfied requirement leaves forbidden items alone', spare.flags.forbid == true)
end

-- Waiting for a workshop, and failed moods, are each reported once.
do
    local w, env = fresh()
    add_unit(w, 1, 'Fey')
    add_unit(w, 2, 'Berserk')
    add_unit(w, 3, 'Fey', {citizen = false})              -- a visitor
    local r = env.report()
    check('a moody dwarf without a workshop is waiting', #r.waiting == 1
          and r.waiting[1].skill == 'STONECRAFT')
    check('a failed mood is reported', #r.failed == 1 and r.failed[1].mood == 'Berserk')
    local actions = env.fix()
    check('waiting and failed are each announced', #actions == 2,
          table.concat(actions, ' | '))
    check('and only once', #env.fix() == 0)
end

-- A mood that cannot claim a workshop is fatal: place the one it needs.
local function fake_sustenance(w, existing)
    local placed = {}
    w.scripts = w.scripts or {}
    w.scripts.antfarm_sustenance = {
        have_building = function(btype, kind) return existing[btype .. ':' .. kind] == true end,
        place_building = function(btype, kind)
            table.insert(placed, btype .. ':' .. kind)
            return true
        end,
    }
    return placed
end

do
    local w, env = fresh()
    local placed = fake_sustenance(w, {})
    local u = add_unit(w, 1, 'Fey')
    add_mood_job(w, u, 'StrangeMoodJeweller', {job_item(w.df.item_type.ROUGH, 0, 1)}, nil, true)
    local actions = env.fix()
    check("a missing jeweler's workshop is placed",
          #placed == 1 and placed[1] == '1:4', table.concat(placed, ','))
    check('the placement is reported',
          table.concat(actions, ' | '):find("needs a jeweler's workshop", 1, true) ~= nil,
          table.concat(actions, ' | '))
end

do
    local w, env = fresh()
    local placed = fake_sustenance(w, {['1:4'] = true})
    local u = add_unit(w, 1, 'Fey')
    add_mood_job(w, u, 'StrangeMoodJeweller', {job_item(w.df.item_type.ROUGH, 0, 1)}, nil, true)
    env.fix()
    check('an existing workshop of the right kind is not duplicated', #placed == 0)
end

do
    local w, env = fresh()
    local placed = fake_sustenance(w, {})
    local u = add_unit(w, 1, 'Fey')
    add_mood_job(w, u, 'StrangeMoodGlassmaker', {}, nil, true)
    env.fix()
    check('a glassmaker mood gets a glass furnace', placed[1] == '2:3', tostring(placed[1]))
end

do
    local w, env = fresh()
    local placed = fake_sustenance(w, {})
    local u = add_unit(w, 1, 'Fey')
    add_mood_job(w, u, 'StrangeMoodMagmaForge', {}, nil, true)
    add_mood_job(w, add_unit(w, 2, 'Fey'), 'StrangeMoodCrafter', {})   -- claimed
    env.fix()
    check('magma forges are never placed blind, claimed moods are left alone',
          #placed == 0, table.concat(placed, ','))
end

-- The background tick runs fix() on its interval and keeps the notes.
do
    local w, env = fresh()
    add_unit(w, 1, 'Fey')
    w.advance(60000)
    env.tick()
    check('tick records mood actions in notes',
          #env.antfarm_mood_state.notes == 1, tostring(#env.antfarm_mood_state.notes))
end


-- ---------------------------------------------------------------- --
-- escalation: butcher, produce, conjure                              --
-- ---------------------------------------------------------------- --

-- Extra world for the escalation routes: item types, professions, creature
-- raws (material ids as the live raws list them), inorganics, the workorder
-- command, createItem and announcements.
local RACE_YAK, RACE_DOG = 1, 2
local function escalation_world(opts)
    opts = opts or {}
    local w, env = fresh()
    local df = w.df
    df.item_type = enum{NONE = -1, BAR = 0, BOULDER = 3, BLOCKS = 4, ROUGH = 5,
                        SMALLGEM = 6, CLOTH = 9, SKIN_TANNED = 15}
    df.workshop_type = enum{Craftsdwarfs = 3, Jewelers = 4, MagmaForge = 6, Masons = 7,
                            Butchers = 10, Tanners = 12}
    df.profession = enum{STANDARD = 0, TRAINED_HUNTER = 98, TRAINED_WAR = 99}
    df.global.ui.civ_id = 7
    local function mats(ids)
        local v = {}
        for _, id in ipairs(ids) do table.insert(v, {id = id}) end
        return vector(v)
    end
    df.global.world.raws = {
        creatures = {all = {
            [RACE_YAK] = {creature_id = 'YAK', material = mats{'SKIN', 'BONE', 'HORN', 'HOOF', 'LEATHER'}},
            [RACE_DOG] = {creature_id = 'DOG', material = mats{'SKIN', 'BONE', 'TOOTH', 'LEATHER'}},
        }},
        inorganics = vector{
            {id = 'ADAMANTINE', material = {flags = {IS_METAL = true}, material_value = 300}},
            {id = 'IRON', material = {flags = {IS_METAL = true}, material_value = 10}},
            {id = 'GRANITE', material = {flags = {IS_STONE = true}, material_value = 1}},
            {id = 'COPPER', material = {flags = {IS_METAL = true}, material_value = 2}},
        },
    }
    w.orders = {}
    w.dfhack.run_command = function(cmd, arg)
        if cmd == 'workorder' then table.insert(w.orders, arg) end
        return 0
    end
    w.dfhack.matinfo = {decode = function(t, i)
        return {toString = function() return MAT_NAMES[t] or 'stuff' end,
                getToken = function() return ('INORGANIC:M%d_%d'):format(t, i) end}
    end}
    w.created = {}
    w.dfhack.items.createItem = function(t, sub, mt, mi, u)
        table.insert(w.created, {t = t, mt = mt, mi = mi, unit = u and u.id})
        return 1000 + #w.created
    end
    w.announced = {}
    w.dfhack.gui.showAnnouncement = function(text) table.insert(w.announced, text) end
    w.dfhack.units.isAdult = function(u) return u.adult ~= false end
    local placed, have = {}, {}
    w.scripts = {antfarm_sustenance = {
        have_building = function(btype, kind) return have[kind] == true end,
        place_building = function(btype, kind) table.insert(placed, kind); have[kind] = true; return true end,
    }}
    w.placed = placed
    if opts.config then w.files = {['dfhack-config/antfarm_mood.json'] = opts.config} end
    return w, env
end

local function add_animal(w, id, race, sex, extra)
    local u = {id = id, race = race, sex = sex, civ_id = 7, citizen = false,
               flags1 = {tame = true}, flags2 = {slaughter = false},
               relationship_ids = {Pet = -1}, profession = 0, mood = -1}
    for k, v in pairs(extra or {}) do u[k] = v end
    w.df.global.world.units.active:push(u)
    return u
end

local function bone_job_item()
    return {item_type = -1, item_subtype = -1, mat_type = -1, mat_index = -1,
            quantity = 1, flags2 = {bone = true, body_part = true}}
end

local function marked(units)
    local n = 0
    for _, u in ipairs(units) do if u.flags2.slaughter then n = n + 1 end end
    return n
end

local function any_action(actions, needle)
    for _, a in ipairs(actions) do if a:find(needle, 1, true) then return true end end
    return false
end

-- The live case (region_smoke, 2026-11-01): a bonecarver needs bone, the fort
-- has none and no butcher's workshop. Mark a spare yak, never the pet or the
-- war dog, and place the workshop.
do
    local w, env = escalation_world()
    local u = add_unit(w, 1, 'Fey')
    add_mood_job(w, u, 'StrangeMoodCrafter', {bone_job_item()})
    local yak1 = add_animal(w, 11, RACE_YAK, 0)
    local yak2 = add_animal(w, 12, RACE_YAK, 0)
    local pet = add_animal(w, 13, RACE_DOG, 0, {relationship_ids = {Pet = 1}})
    local war = add_animal(w, 14, RACE_DOG, 0, {profession = 99})
    local actions = env.fix()
    check('bone: one spare yak is marked for slaughter', marked{yak1, yak2} == 1)
    check('bone: the pet and the war dog are never marked',
          not pet.flags2.slaughter and not war.flags2.slaughter)
    check('bone: a butcher\'s workshop is placed', w.placed[1] == w.df.workshop_type.Butchers)
    check('bone: the route is reported', any_action(actions, 'marked for slaughter the yak for bone'),
          table.concat(actions, ' | '))
    local again = env.fix()
    check('bone: a second pass marks nothing more and stays quiet',
          marked{yak1, yak2} == 1 and #again == 0, table.concat(again, ' | '))
    check('bone: report names the route', env.report().moods[1].requirements[1].route == 'butcher')
end

-- autobutcher had already marked the yaks; the fix is the workshop, not a mark.
do
    local w, env = escalation_world()
    local u = add_unit(w, 1, 'Fey')
    add_mood_job(w, u, 'StrangeMoodCrafter', {bone_job_item()})
    local yak1 = add_animal(w, 11, RACE_YAK, 0, {flags2 = {slaughter = true}})
    local yak2 = add_animal(w, 12, RACE_YAK, 0)
    local actions = env.fix()
    check('pre-marked: no extra animal is marked', marked{yak1, yak2} == 1 and yak1.flags2.slaughter)
    check('pre-marked: the workshop is still placed', #w.placed == 1)
    check('pre-marked: it says it will use the marked animal', any_action(actions, 'will butcher the yak'),
          table.concat(actions, ' | '))
end

-- A breeding pair is the herd: nothing can be spared.
do
    local w, env = escalation_world()
    local u = add_unit(w, 1, 'Fey')
    add_mood_job(w, u, 'StrangeMoodCrafter', {bone_job_item()})
    local bull = add_animal(w, 11, RACE_YAK, 1)
    local cow = add_animal(w, 12, RACE_YAK, 0)
    local actions = env.fix()
    check('pair: neither of a breeding pair is marked', marked{bull, cow} == 0)
    check('pair: it says nothing can be spared', any_action(actions, 'no animal can be spared'),
          table.concat(actions, ' | '))
end

-- Leather: an animal with skin, a tanner's workshop, and the 0.47 tanning
-- reaction (there is no TanAHide job type in this build).
do
    local w, env = escalation_world()
    local u = add_unit(w, 1, 'Fey')
    add_mood_job(w, u, 'StrangeMoodCrafter', {job_item(w.df.item_type.SKIN_TANNED, -1, 1)})
    add_animal(w, 11, RACE_DOG, 0); add_animal(w, 12, RACE_DOG, 0)
    env.fix()
    local tanned = false
    for _, o in ipairs(w.orders) do
        if o:find('"job":"CustomReaction"', 1, true) and o:find('"reaction":"TAN_A_HIDE"', 1, true)
            and o:find('__reduce_amount', 1, true) then tanned = true end
    end
    check('leather: a TAN_A_HIDE CustomReaction order is submitted', tanned, table.concat(w.orders, ' | '))
    local shops = {}
    for _, k in ipairs(w.placed) do shops[k] = true end
    check('leather: butcher\'s and tanner\'s workshops are placed',
          shops[w.df.workshop_type.Butchers] and shops[w.df.workshop_type.Tanners])
end

-- Stone blocks: a ConstructBlocks order for what is short, at a placed mason's.
do
    local w, env = escalation_world()
    local u = add_unit(w, 1, 'Fey')
    add_mood_job(w, u, 'StrangeMoodCrafter', {job_item(w.df.item_type.BLOCKS, 0, 3)})
    local actions = env.fix()
    check('blocks: a ConstructBlocks order for the 3 short',
          w.orders[1] == '{"job":"ConstructBlocks","amount_total":3,"__reduce_amount":true}', w.orders[1])
    check('blocks: a mason\'s workshop is placed', w.placed[1] == w.df.workshop_type.Masons)
    check('blocks: reported once', any_action(actions, 'queued 3 stone blocks'), table.concat(actions, ' | '))
    check('blocks: the next pass re-asserts the order but stays quiet', #env.fix() == 0 and #w.orders == 2)
end

-- Cut gems must name a material, so they take one from a rough gem the fort
-- actually holds; with none, they say so instead of submitting a blind order.
do
    local w, env = escalation_world()
    local u = add_unit(w, 1, 'Fey')
    add_mood_job(w, u, 'StrangeMoodJeweller', {job_item(w.df.item_type.SMALLGEM, 0, 1)})
    local actions = env.fix()
    check('gems: no rough gem means no order', #w.orders == 0 and any_action(actions, 'no rough in the fort'),
          table.concat(actions, ' | '))
end
do
    local w, env = escalation_world()
    local u = add_unit(w, 1, 'Fey')
    add_mood_job(w, u, 'StrangeMoodJeweller', {job_item(w.df.item_type.SMALLGEM, 0, 1)})
    add_item(w, w.df.item_type.ROUGH, 0)
    env.fix()
    check('gems: a CutGems order names the rough gem\'s material',
          w.orders[1] == '{"job":"CutGems","amount_total":1,"material":"INORGANIC:M0_0","__reduce_amount":true}',
          w.orders[1])
end

-- Conjuring is off unless the operator opted in.
local function bar_mood(w, timeout)
    local u = add_unit(w, 1, 'Fey', {job = {mood_timeout = timeout, mood_skill = 5}})
    add_mood_job(w, u, 'StrangeMoodCrafter', {job_item(w.df.item_type.BAR, 0, 300)})
    return u
end
do
    local w, env = escalation_world()
    bar_mood(w, 5000)
    env.fix()
    check('conjure: off by default, even with the mood about to fail', #w.created == 0)
end
do
    local w, env = escalation_world{config = {createitem_last_resort = true}}
    bar_mood(w, 30000)
    env.fix()
    check('conjure: opted in, but not while the mood has time left', #w.created == 0)
end
do
    local w, env = escalation_world{config = {createitem_last_resort = true}}
    local u = bar_mood(w, 5000)
    local actions = env.fix()
    check('conjure: two bars for 300 dimension units', #w.created == 2, tostring(#w.created))
    check('conjure: the cheapest metal (copper), never iron first in raws or adamantine',
          w.created[1] and w.created[1].mi == 3, w.created[1] and tostring(w.created[1].mi))
    check('conjure: created by the moody dwarf (at their feet)', w.created[1] and w.created[1].unit == u.id)
    check('conjure: announced in game, and in the notes', #w.announced == 1 and any_action(actions, 'Conjured'))
    env.fix()
    check('conjure: only once per requirement', #w.created == 2)
end
do
    local w, env = escalation_world{config = {createitem_last_resort = true}}
    local u = add_unit(w, 1, 'Fey', {job = {mood_timeout = 5000, mood_skill = 5}})
    add_mood_job(w, u, 'StrangeMoodCrafter', {bone_job_item()})
    env.fix()
    check('conjure: body parts are never conjured', #w.created == 0)
end

-- The opt-in round-trips through the config file.
do
    local w, env = escalation_world()
    check('config: defaults to off', env.load_config().createitem_last_resort == false)
    env.save_config({createitem_last_resort = true, createitem_below_ticks = 6000})
    local cfg = env.load_config()
    check('config: on and a custom threshold persist',
          cfg.createitem_last_resort == true and cfg.createitem_below_ticks == 6000)
end

-- The report gives a countdown a dashboard can show.
do
    local w, env = escalation_world()
    bar_mood(w, 24000)
    check('report: days_left from mood_timeout (1200 ticks a day)', env.report().moods[1].days_left == 20)
end

print(('\n%d passed, %d failed'):format(pass, fail))
if fail > 0 then error(('%d antfarm_mood tests failed'):format(fail)) end
