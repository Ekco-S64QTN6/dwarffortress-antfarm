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

print(('\n%d passed, %d failed'):format(pass, fail))
if fail > 0 then error(('%d antfarm_mood tests failed'):format(fail)) end
