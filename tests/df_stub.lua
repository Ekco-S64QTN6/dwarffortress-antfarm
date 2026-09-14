-- df_stub.lua
-- A fake `df` / `dfhack` big enough to unit-test the Antfarm scripts outside
-- Dwarf Fortress.
--
-- AGENTS.md section 4.3: DF cannot run headlessly, so the pure logic gets
-- tested against synthetic structures instead. This stub models the parts the
-- scripts actually touch -- the viewscreen stack, the popup queue, the
-- announcement log and d_init's per-announcement flags -- and records every
-- simulated keystroke so a test can assert on what the watchdog pressed.

local M = {}

-- ---------------------------------------------------------------- --
-- viewscreen types                                                  --
-- ---------------------------------------------------------------- --
-- A screen is {vtype = 'viewscreen_textviewerst', parent = <screen|nil>, ...}.
-- df.<name>:is_instance(scr) compares vtype, which is what DFHack's virtual
-- identity check does for real.

local VIEWSCREENS = {
    'viewscreen_dwarfmodest', 'viewscreen_textviewerst', 'viewscreen_topicmeetingst',
    'viewscreen_topicmeeting_takerequestsst', 'viewscreen_topicmeeting_fill_land_holder_positionsst',
    'viewscreen_requestagreementst', 'viewscreen_announcelistst', 'viewscreen_reportlistst',
    'viewscreen_movieplayerst', 'viewscreen_petitionsst', 'viewscreen_titlest',
    'viewscreen_loadgamest', 'viewscreen_savegamest', 'viewscreen_new_regionst',
    'viewscreen_update_regionst', 'viewscreen_adopt_regionst', 'viewscreen_choose_start_sitest',
    'viewscreen_setupdwarfgamest', 'viewscreen_setupadventurest', 'viewscreen_export_regionst',
    'viewscreen_export_graphical_mapst', 'viewscreen_legendsst', 'viewscreen_dungeonmodest',
    'viewscreen_game_cleanerst', 'viewscreen_layer_world_gen_paramst',
    'viewscreen_layer_world_gen_param_presetst', 'viewscreen_unitst',
}

-- Announcement types the tests care about; the real enum has 339.
local ANNOUNCEMENT_TYPES = {
    'FEATURE_DISCOVERY', 'STRUCK_DEEP_METAL', 'MIGRANT_ARRIVAL', 'CARAVAN_ARRIVAL',
    'LIAISON_ARRIVAL', 'DIPLOMAT_ARRIVAL', 'NOBLE_ARRIVAL', 'CAVE_COLLAPSE',
    'MEGABEAST_ARRIVAL', 'UNDEAD_ATTACK', 'BERSERK_CITIZEN', 'STRANGE_MOOD',
    'DIG_CANCEL_DAMP', 'DIG_CANCEL_WARM', 'CITIZEN_DEATH', 'BIRTH_CITIZEN',
    'AMBUSH_THIEF', 'AMBUSH_AMBUSHER', 'AMBUSH_SNATCHER', 'SEASON_SPRING',
    'CURRENT_WEATHER', 'MADE_ARTIFACT', 'CITIZEN_SNATCHED', 'POSSESSED_TANTRUM',
    'CITIZEN_TANTRUM', 'NIGHT_ATTACK_STARTS',
}

-- A DF vector: 0-indexed with a Lua-visible length, plus resize/erase/insert.
local Vector = {}
Vector.__index = function(t, k)
    if type(k) == 'number' then return rawget(t, '_items')[k + 1] end
    return Vector[k]
end
Vector.__len = function(t) return #rawget(t, '_items') end
function Vector:resize(n)
    local items = rawget(self, '_items')
    while #items > n do table.remove(items) end
end
function Vector:erase(i)
    table.remove(rawget(self, '_items'), i + 1)
end
function Vector:insert(pos, v)
    local items = rawget(self, '_items')
    if pos == '#' then table.insert(items, v) else table.insert(items, pos + 1, v) end
end
function Vector:push(v) table.insert(rawget(self, '_items'), v) end
local function vector(t)
    return setmetatable({_items = t or {}}, Vector)
end
M.vector = vector

-- ---------------------------------------------------------------- --
-- building the fake world                                           --
-- ---------------------------------------------------------------- --

function M.new()
    local w = {keys = {}, printed = {}, errors = {}, commands = {}, dismissed = {}}

    local df = {}
    for _, name in ipairs(VIEWSCREENS) do
        df[name] = {
            _name = name,
            is_instance = function(self, scr)
                return type(scr) == 'table' and scr.vtype == self._name
            end,
        }
    end

    df.announcement_type = {}
    for i, name in ipairs(ANNOUNCEMENT_TYPES) do
        df.announcement_type[i - 1] = name
        df.announcement_type[name] = i - 1
    end
    df.ui_sidebar_mode = {Default = 0, Build = 16, LookAround = 25}
    df.agreement_details_type = {}
    for i, name in ipairs({'JoinParty', 'DemonicBinding', 'Residency', 'Citizenship', 'Parley'}) do
        df.agreement_details_type[i - 1] = name
        df.agreement_details_type[name] = i - 1
    end

    -- d_init announcement flags: every type defaults to no pause, so a test
    -- must opt a type in, exactly like data/init/announcements.txt does.
    local ann_flags = {}
    for i = 0, #ANNOUNCEMENT_TYPES - 1 do
        ann_flags[i] = {PAUSE = false, DO_MEGA = false, RECENTER = false}
    end

    df.global = {
        pause_state = false,
        cur_year = 250,
        cur_year_tick = 1000,
        ui = {main = {mode = 0}, follow_unit = -1, petitions = vector{}},
        d_init = {announcements = {flags = ann_flags}},
        world = {
            status = {
                popups = vector{},
                announcements = vector{},
                flags = {combat = false, hunting = false, sparring = false},
            },
        },
    }

    local units = {}
    df.unit = {find = function(id) return units[id] end}
    w.units = units

    -- ------------------------------------------------------------ --
    -- map, tiles and jobs                                           --
    -- ------------------------------------------------------------ --
    df.tiletype_shape = {WALL = 1, FLOOR = 2, EMPTY = 3, RAMP = 4, STAIR_UP = 5,
                         STAIR_DOWN = 6, STAIR_UPDOWN = 7, BOULDER = 8,
                         PEBBLES = 9, SHRUB = 10, SAPLING = 11}
    df.tiletype_material = {SOIL = 1, STONE = 2, MINERAL = 3, LAVA_STONE = 4,
                            MAGMA = 5, POOL = 6, RIVER = 7, BROOK = 8, AIR = 9}
    df.tile_dig_designation = {No = 0, Default = 1, UpDownStair = 2, UpStair = 3,
                               DownStair = 4, Channel = 5}
    df.job_type = {ConstructBuilding = 1, DestroyBuilding = 2, Dig = 3}
    -- tiletype id N encodes {material, shape} directly, so a test can write a
    -- column without a lookup table.
    df.tiletype = {attrs = setmetatable({}, {__index = function(_, tt)
        return {material = math.floor(tt / 100), shape = tt % 100}
    end})}
    local function tt_of(mat, shape) return mat * 100 + shape end
    w.tt = tt_of

    -- The map is sparse: only blocks a test writes to exist, which is also how
    -- DF behaves outside the embark rectangle.
    local blocks_by_key = {}
    local blocks = vector{}
    df.global.world.map = {map_blocks = blocks, x_count = 192, y_count = 192, z_count = 60}
    -- Real field name: world.jobs.list, not world.job_list.
    df.global.world.jobs = {list = {next = nil}}

    local function block_key(bx, by, bz) return bx .. ',' .. by .. ',' .. bz end
    local function make_block(bx, by, bz)
        local des, tts = {}, {}
        for x = 0, 15 do
            des[x], tts[x] = {}, {}
            for y = 0, 15 do
                des[x][y] = {dig = 0, water_table = false, flow_size = 0}
                tts[x][y] = tt_of(df.tiletype_material.STONE, df.tiletype_shape.WALL)
            end
        end
        return {map_pos = {x = bx * 16, y = by * 16, z = bz},
                designation = des, tiletype = tts, flags = {designated = false}}
    end
    -- Create (or fetch) the block covering a tile.
    function w.block_at(x, y, z)
        local bx, by = math.floor(x / 16), math.floor(y / 16)
        local key = block_key(bx, by, z)
        local b = blocks_by_key[key]
        if not b then
            b = make_block(bx, by, z)
            blocks_by_key[key] = b
            blocks:push(b)
        end
        return b
    end
    function w.set_tile(x, y, z, mat, shape, opts)
        local b = w.block_at(x, y, z)
        b.tiletype[x % 16][y % 16] = tt_of(mat, shape)
        local d = b.designation[x % 16][y % 16]
        for k, v in pairs(opts or {}) do d[k] = v end
        return b
    end
    function w.designate(x, y, z, kind)
        local b = w.block_at(x, y, z)
        b.designation[x % 16][y % 16].dig = kind or df.tile_dig_designation.Default
        return b
    end
    function w.count_designated()
        local n = 0
        for i = 0, #blocks - 1 do
            local b = blocks[i]
            for x = 0, 15 do
                for y = 0, 15 do
                    if b.designation[x][y].dig ~= 0 then n = n + 1 end
                end
            end
        end
        return n
    end
    -- Fill a slab of one material/shape across the footprint the survey samples.
    function w.fill_level(z, mat, shape, half, opts)
        half = half or 8
        local cx, cy = w.center_x or 96, w.center_y or 96
        for x = cx - half, cx + half do
            for y = cy - half, cy + half do
                w.set_tile(x, y, z, mat, shape, opts)
            end
        end
    end

    df.global.world.units = {active = vector{}}
    function w.add_citizen(id, x, y, z)
        local u = {id = id, pos = {x = x, y = y, z = z}}
        units[id] = u
        df.global.world.units.active:push(u)
        return u
    end

    -- Viewscreen stack: index 1 is the root, the last entry is on top.
    local stack = {{vtype = 'viewscreen_dwarfmodest', parent = nil}}
    w.stack = stack
    local function top() return stack[#stack] end
    w.top = top

    function w.push(scr)
        scr.parent = top()
        table.insert(stack, scr)
        return scr
    end
    function w.pop()
        if #stack > 1 then return table.remove(stack) end
        return nil
    end

    local dfhack = {}
    dfhack.getTickCount = function() return w.now or 0 end
    dfhack.isMapLoaded = function() return w.map_loaded ~= false end
    dfhack.df2utf = function(s) return s end
    dfhack.printerr = function(s) table.insert(w.errors, s) end
    dfhack.onStateChange = {}
    dfhack.run_command = function(cmd) table.insert(w.commands, cmd); return 0 end
    dfhack.run_command_silent = function(cmd)
        table.insert(w.commands, cmd)
        return (w.command_output or {})[cmd] or '', 0
    end
    dfhack.gui = {
        getCurViewscreen = function() return top() end,
        getFocusString = function(scr)
            if not scr then return '' end
            return scr.focus or (scr.vtype or ''):gsub('^viewscreen_', ''):gsub('st$', '')
        end,
        revealInDwarfmodeMap = function() w.revealed = true end,
    }
    dfhack.screen = {
        isDismissed = function(scr) return scr and scr.is_dismissed or false end,
        dismiss = function(scr)
            table.insert(w.dismissed, scr.vtype)
            if scr == top() then w.pop() end
        end,
    }
    dfhack.filesystem = {
        isdir = function() return true end,
        exists = function() return false end,
        listdir = function() return {} end,
        mkdir = function() return true end,
    }
    dfhack.maps = {
        getTileSize = function() return 192, 192, 60 end,
        getTileBlock = function(x, y, z)
            if x < 0 or y < 0 or z < 0 then return nil end
            local key = block_key(math.floor(x / 16), math.floor(y / 16), z)
            return blocks_by_key[key]
        end,
    }
    dfhack.units = {
        isCitizen = function(u) return u and u.citizen ~= false end,
        isActive = function(u) return u and u.active ~= false end,
        getPosition = function(u) return u.pos end,
    }
    dfhack.job = {checkDesignationsNow = function() end}
    -- ---- world map, for embark site selection ------------------- --
    -- region_map[x][y] with the fields antfarm_embark scores on.
    -- Shaped like the real thing: region_map is region_map_entry**, so
    -- region_map[x] yields the first entry of column x and callers must use
    -- :_displace(y) to reach the rest. Indexing [x][y] must fail here exactly
    -- as it does in DF.
    local function column(entries)
        return setmetatable({}, {
            __index = function(_, k)
                if k == '_displace' then
                    return function(_, n) return entries[n] end
                end
                error('Cannot read field region_map_entry.' .. tostring(k)
                      .. ': not found.')
            end,
        })
    end

    function w.make_world(width, height, fill)
        local cols = {}
        for x = 0, width - 1 do
            local col = {}
            for y = 0, height - 1 do
                local e = {elevation = 150, rainfall = 50, vegetation = 50,
                           temperature = 50, evilness = 30, drainage = 50,
                           volcanism = 30, savagery = 30, salinity = 0,
                           geo_index = 0, finder_rank = 0}
                if fill then fill(e, x, y) end
                col[y] = e
            end
            cols[x] = column(col)
        end
        df.global.world.world_data = {
            world_width = width, world_height = height, region_map = cols,
        }
        return cols
    end

    dfhack.timeout = function() return nil end
    dfhack.timeout_active = function() end

    -- gui.simulateInput: record the key, then let the test's own handler decide
    -- what the game does with it. Default behaviour mirrors DF: Enter clears one
    -- popup, Escape pops the top screen.
    local gui = {}
    -- Set w.async_keys = true to model DF properly: gui.simulateInput QUEUES a
    -- key, and DF feeds it on a LATER frame. Code that checks whether a screen
    -- closed in the same call always reads the pre-keystroke screen. That is a
    -- real bug this stub could not catch while it applied keys synchronously.
    local queued = {}
    function w.flush_keys()
        local pending = queued
        queued = {}
        for _, q in ipairs(pending) do w.apply_key(q.scr, q.key) end
    end

    function w.apply_key(scr, key)
        if w.on_key then return w.on_key(scr, key) end
        local popups = df.global.world.status.popups
        if key == 'CLOSE_MEGA_ANNOUNCEMENT' and #popups > 0 then
            popups:erase(0); return
        end
        if key == 'D_PAUSE' then
            df.global.pause_state = not df.global.pause_state; return
        end
        if (key == 'LEAVESCREEN' or key == 'LEAVESCREEN_ALL') and #stack > 1 then
            w.pop()
        end
    end

    gui.simulateInput = function(scr, key)
        table.insert(w.keys, {key = key, screen = scr and scr.vtype})
        if w.async_keys then
            table.insert(queued, {scr = scr, key = key})
            return
        end
        if w.on_key then return w.on_key(scr, key) end
        local popups = df.global.world.status.popups
        if key == 'CLOSE_MEGA_ANNOUNCEMENT' and #popups > 0 then
            popups:erase(0)
            return
        end
        if key == 'D_PAUSE' then
            df.global.pause_state = not df.global.pause_state
            return
        end
        if (key == 'LEAVESCREEN' or key == 'LEAVESCREEN_ALL') and #stack > 1 then
            w.pop()
        end
    end

    w.df = df
    w.dfhack = dfhack
    w.gui = gui

    function w.add_popup(text)
        df.global.world.status.popups:push({text = text})
    end
    function w.add_announcement(type_name, text, opts)
        opts = opts or {}
        df.global.world.status.announcements:push({
            type = df.announcement_type[type_name],
            text = text,
            id = opts.id or (#df.global.world.status.announcements + 1),
            year = opts.year or df.global.cur_year,
            time = opts.time or df.global.cur_year_tick,
            repeat_count = opts.repeat_count or 0,
            flags = {continuation = false, announcement = true},
        })
        if opts.pauses then
            ann_flags[df.announcement_type[type_name]].PAUSE = true
        end
    end
    function w.keys_pressed()
        local out = {}
        for _, k in ipairs(w.keys) do table.insert(out, k.key) end
        return out
    end
    function w.advance(ms) w.now = (w.now or 0) + ms end

    w.now = 100000
    return w
end

-- Load an antfarm script in module mode against this fake world.
function M.load(world, path)
    local env = {}
    env.df = world.df
    env.dfhack = world.dfhack
    env.dfhack_flags = {module = true}
    env.require = function(name)
        if name == 'gui' then return world.gui end
        if name == 'json' then
            return {
                decode_file = function(path)
                    if world.files and world.files[path] then return world.files[path] end
                    error('no such file: ' .. tostring(path))
                end,
                encode_file = function(data, path)
                    world.files = world.files or {}
                    world.files[path] = data
                end,
            }
        end
        if name == 'utils' then
            return {listpairs = function(list)
                -- Reject nil: `world.job_list` does not exist in this build and
                -- reading it yields nil, which used to sail straight through
                -- here. Erroring makes a wrong field name a test failure rather
                -- than something only the live game finds.
                if list == nil then
                    error('listpairs called with nil -- wrong field name?')
                end
                local items = (world.job_list or {})
                local i = 0
                return function()
                    i = i + 1
                    if items[i] then return i, items[i] end
                end
            end}
        end
        error('unstubbed require: ' .. name)
    end
    env.reqscript = function(name) return world.scripts and world.scripts[name] end
    env.print = function(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
        table.insert(world.printed, table.concat(parts, ' '))
    end
    env.SC_MAP_UNLOADED, env.SC_WORLD_UNLOADED, env.SC_MAP_LOADED = 1, 2, 3
    env.CR_OK = 0
    setmetatable(env, {__index = _G})
    env._ENV = env

    local chunk, err = loadfile(path, 't', env)
    if not chunk then error(err) end
    chunk()
    return env
end

return M
