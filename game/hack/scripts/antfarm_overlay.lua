-- antfarm_overlay.lua
-- In-game HUD strip showing Antfarm's current mode and camera lock.
--
-- AGENTS.md 6.1.5: pure-Lua overlay scripts belong in hack/scripts/, never in
-- hack/lua/plugins/ (which is reserved for compiled .plug.so plugins), and
-- they must end with the dfhack_flags.module guard.

--@module = true

local overlay = require('plugins.overlay')
local server = reqscript('antfarm_server')

AntfarmStatusOverlay = defclass(AntfarmStatusOverlay, overlay.OverlayWidget)
AntfarmStatusOverlay.ATTRS{
    default_pos = {x = 2, y = -2},
    viewscreens = {'dwarfmode'},
    frame = {w = 48, h = 1},
}

local MODE_COLORS = {
    director = COLOR_LIGHTGREEN,
    timed    = COLOR_LIGHTCYAN,
    event    = COLOR_LIGHTMAGENTA,
    idle     = COLOR_GREY,
}

function AntfarmStatusOverlay:init()
    self.mode = 'idle'
    self.running = false
    self.label = ''
end

function AntfarmStatusOverlay:overlay_onupdate()
    local st = server.antfarm
    if not st then
        self.running = false
        self.frame.w = 0
        return
    end

    self.running = st.running
    self.mode = st.mode or 'idle'

    if not st.running then
        self.label = ''
        self.frame.w = 0
        return
    end

    local who = 'free camera'
    if st.follow_id and st.follow_id ~= -1 then
        local u = df.unit.find(st.follow_id)
        if u then
            local ok, vis = pcall(dfhack.units.getVisibleName, u)
            if ok and vis then
                local ok2, name = pcall(dfhack.TranslateName, vis)
                if ok2 and name and name ~= '' then who = name end
            end
        end
    end

    self.label = who
    -- 'ANTFARM ' + mode + ' | ' + name
    self.frame.w = 9 + #self.mode + 3 + #self.label
end

function AntfarmStatusOverlay:onRenderBody(dc)
    if not self.running then return end
    dc:string('ANTFARM ', COLOR_LIGHTMAGENTA)
    dc:string(self.mode:upper(), MODE_COLORS[self.mode] or COLOR_WHITE)
    dc:string(' | ', COLOR_DARKGREY)
    dc:string(self.label, COLOR_WHITE)
end

OVERLAY_WIDGETS = {status = AntfarmStatusOverlay}

if dfhack_flags and dfhack_flags.module then
    return
end

print('antfarm_overlay: registered as an overlay widget.')
print('Toggle it with:  overlay enable antfarm_overlay.status')
