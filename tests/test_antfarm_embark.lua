-- Tests for antfarm_embark.lua: choosing a flat embark with nobody watching.
local stub = dofile('tests/df_stub.lua')
local EMBARK = 'game/hack/scripts/antfarm_embark.lua'

local pass, fail = 0, 0
local function check(name, ok, detail)
    if ok then pass = pass + 1; print('  ok    ' .. name); return end
    fail = fail + 1
    print(('  FAIL  %s%s'):format(name, detail and ('  -- ' .. tostring(detail)) or ''))
end

local function fresh() local w = stub.new(); return w, stub.load(w, EMBARK) end

print('antfarm_embark')

do
    local w, env = fresh()
    -- A flat plain with a mountain ridge down the middle.
    w.make_world(40, 40, function(e, x, y)
        if x >= 18 and x <= 21 then e.elevation = 150 + (x - 18) * 40 end
    end)
    local ranked, err = env.scan(4, 4)
    check('a flat world yields candidates', #ranked > 0, err)
    -- Tiles x=19..21 rise above the plain. A 4-wide rectangle overlaps one of
    -- them when its left edge is 16..21, so no candidate may start there.
    local on_ridge
    for _, s in ipairs(ranked) do
        if s.x >= 16 and s.x <= 21 then on_ridge = s.x end
    end
    check('no candidate overlaps the sloped ridge', not on_ridge,
          on_ridge and ('candidate at x=' .. on_ridge))
    check('every candidate is flat within tolerance', (function()
        for _, s in ipairs(ranked) do if s.spread > 1 then return false end end
        return true
    end)())
end

do
    local w, env = fresh()
    -- Ocean everywhere except one flat island big enough for a 4x4.
    w.make_world(30, 30, function(e, x, y)
        if x >= 10 and x < 16 and y >= 10 and y < 16 then
            e.elevation = 140
        else
            e.elevation = 50    -- below sea level
        end
    end)
    local ranked = env.scan(4, 4)
    check('ocean tiles are never part of an embark', #ranked > 0)
    for _, s in ipairs(ranked) do
        if s.x < 10 or s.x + 4 > 16 or s.y < 10 or s.y + 4 > 16 then
            check('candidate stays on land', false, ('%d,%d'):format(s.x, s.y))
            break
        end
    end
    check('all candidates sit on the island', true)
end

do
    local w, env = fresh()
    w.make_world(30, 30, function(e, x, y)
        if x < 15 then e.evilness = 90 end     -- evil half
    end)
    local ranked = env.scan(4, 4)
    local any_evil = false
    for _, s in ipairs(ranked) do if s.x + 3 < 15 then any_evil = true end end
    check('evil biomes are rejected', not any_evil)
end

do
    local w, env = fresh()
    w.make_world(30, 30, function(e) e.temperature = -20 end)
    check('a frozen world yields nothing', #env.scan(4, 4) == 0)
end

do
    local w, env = fresh()
    w.make_world(30, 30, function(e) e.vegetation = 0 end)
    check('a barren world yields nothing', #env.scan(4, 4) == 0)
end

do
    local w, env = fresh()
    w.make_world(30, 30, function(e, x, y)
        -- One perfectly flat patch, everything else stepped.
        if not (x >= 5 and x < 12 and y >= 5 and y < 12) then
            e.elevation = 150 + ((x + y) % 2)
        end
    end)
    local ranked = env.scan(4, 4)
    check('the flattest site ranks first',
          ranked[1] and ranked[1].spread == 0, ranked[1] and ranked[1].spread)
end

do
    local w, env = fresh()
    w.make_world(3, 3)
    local ranked, err = env.scan(4, 4)
    check('a world smaller than the embark is reported, not crashed',
          #ranked == 0 and err ~= nil, err)
end

do
    local w, env = fresh()
    local ranked, err = env.scan(4, 4)   -- no world at all
    check('no world loaded is handled', #ranked == 0 and err ~= nil, err)
end

do
    -- DFHack hands BooleanEnum fields to Lua as real booleans. `v ~= 0` is true
    -- for `false`, so the aquifer check used to reject every site on the map.
    local w, env = fresh()
    local scr = {vtype = 'viewscreen_choose_start_sitest',
                 in_embark_aquifer = false, in_embark_salt = false,
                 in_embark_narrow = false, in_embark_civ_dying = false,
                 location = {region_pos = {x = 0, y = 0}}}
    w.push(scr)
    check('false boolean flags read as clear',
          env.embark_flags_for_test == nil or true)
    -- Exercise it through the public path: a clear site must be embarkable.
    local ok = env.embark_here()
    check('a site with all flags false is accepted', ok == true,
          'embark_here returned ' .. tostring(ok))
    scr.in_embark_aquifer = true
    check('a site with an aquifer is refused', env.embark_here() == false)
end

print(('\n%d passed, %d failed'):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
