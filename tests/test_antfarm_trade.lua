-- Tests for antfarm_trade.lua: what leaves the fort, what is bought, and whether
-- a purchase counts as having happened. The UI driver that presses the keys is
-- covered in test_antfarm_ui.lua.
--
-- Run: lua tests/test_antfarm_trade.lua   (from the repository root)

local stub = dofile('tests/df_stub.lua')
local TRADE = 'game/hack/scripts/antfarm_trade.lua'

local pass, fail = 0, 0
local function check(name, ok, detail)
    if ok then
        pass = pass + 1
        print('  ok    ' .. name)
    else
        fail = fail + 1
        print(('  FAIL  %s%s'):format(name, detail and ('  -- ' .. tostring(detail)) or ''))
    end
end

-- item_type as read from the live game: note there is no CRAFTS.
local ITEM_TYPE = {BAR = 0, SMALLGEM = 1, ROUGH = 3, GOBLET = 12, INSTRUMENT = 13, TOY = 14,
                   FIGURINE = 35, AMULET = 36, SCEPTER = 37, CROWN = 39, RING = 40,
                   EARRING = 41, BRACELET = 42, GEM = 43, TOTEM = 58, ROCK = 75, BOULDER = 76,
                   WEAPON = 80, ANVIL = 81, WOOD = 82, BIN = 83}

local function fresh()
    local w = stub.new()
    w.df.item_type = {}
    for k, v in pairs(ITEM_TYPE) do
        w.df.item_type[k] = v
        w.df.item_type[v] = k
    end
    w.df.building_type = w.df.building_type or {Workshop = 1, TradeDepot = 2}
    w.df.caravan_state = {T_trade_state = {[0] = 'None', [1] = 'Approaching', [2] = 'AtDepot',
                                           [3] = 'Leaving', [4] = 'Stuck'}}
    w.df.entity_sell_category = {MetalBars = 7}
    w.df.global.ui.caravans = stub.vector{}
    w.df.global.world.raws = {inorganics = stub.vector{}}
    local items = {all = stub.vector{}, other = {WEAPON = stub.vector{}, ANVIL = stub.vector{},
                                                 ROUGH = stub.vector{}, BAR = stub.vector{}}}
    w.df.global.world.items = items
    w.scripts = w.scripts or {}
    w.dfhack.items = w.dfhack.items or {}
    w.dfhack.items.getValue = function(it) return it.value or 10 end
    w.dfhack.matinfo = {decode = function(it)
        return {plant = it.wooden and {} or nil, material = {flags = {WOOD = it.wooden or false}}}
    end}
    local env = stub.load(w, TRADE)
    return w, env
end

local function item(type_name, opts)
    opts = opts or {}
    local it = {flags = {trader = opts.trader or false, artifact = opts.artifact or false,
                         forbid = opts.forbid or false},
                value = opts.value, wooden = opts.wooden,
                subtype = opts.subtype and {id = opts.subtype} or nil,
                material_index = opts.index or 0}
    function it:getType() return ITEM_TYPE[type_name] end
    function it:getMaterial() return 0 end
    function it:getMaterialIndex() return self.material_index end
    return it
end

local function metals_report(w, missing)
    w.scripts.antfarm_metals = {report = function() return {missing = missing} end}
end

print('antfarm_trade')

-- ---------------------------------------------------------------- --
do
    local w, env = fresh()
    check('there is no CRAFTS item type to lean on', w.df.item_type.CRAFTS == nil)
    w.df.global.world.items.all:push(item('FIGURINE'))
    w.df.global.world.items.all:push(item('RING'))
    w.df.global.world.items.all:push(item('SCEPTER'))
    w.df.global.world.items.all:push(item('SCEPTER', {trader = true}))
    w.df.global.world.items.all:push(item('BOULDER'))
    check('stock counts every kind of craft, not the merchants\' own',
          env.count_crafts() == 3, env.count_crafts())

    local order
    w.dfhack.run_command = function(_, json) order = json; return 0 end
    env.queue_trade_goods()
    check('the craft order is the shortfall below target', order and order:find('"amount_total":27', 1, true), order)
end

-- ---------------------------------------------------------------- --
do
    local _, env = fresh()
    check('finished goods may go', env.exportable(item('FIGURINE')))
    check('large gems may go', env.exportable(item('GEM')))
    check('cut small gems stay, they are for encrusting', not env.exportable(item('SMALLGEM')))
    check('rough gems stay', not env.exportable(item('ROUGH')))
    check('boulders stay', not env.exportable(item('BOULDER')))
    check('tools stay', not env.exportable(item('WEAPON', {subtype = 'ITEM_WEAPON_PICK'})))
    check('containers stay', not env.exportable(item('BIN')))
    check('artifacts never go', not env.exportable(item('FIGURINE', {artifact = true})))
    check('forbidden goods stay', not env.exportable(item('FIGURINE', {forbid = true})))
    check('wood may go to non-elves', env.exportable(item('FIGURINE', {wooden = true}), false))
    check('wood never goes to elves', not env.exportable(item('FIGURINE', {wooden = true}), true))
end

-- ---------------------------------------------------------------- --
do
    local function line(it, value) return {item = it, status = 0, value = value} end
    local _, env = fresh()
    local lines = {}
    for i = 1, 50 do table.insert(lines, line(item('FIGURINE'), i)) end
    local boulder = line(item('BOULDER'), 1000)
    table.insert(lines, boulder)
    local pending = line(item('RING'), 999)
    pending.status = 1
    table.insert(lines, pending)
    local n, value = env.mark_exports({info = stub.vector(lines)})
    check('caps how much is hauled at once', n == 40, n)
    check('sends the most valuable first', lines[50].status == 1 and lines[1].status == 0)
    check('leaves what may not go', boulder.status == 0)
    check('does not count lines already on the way', value == (11 + 50) * 20, value)
end

-- ---------------------------------------------------------------- --
local function trade_view(trader, broker)
    return {trader_items = stub.vector(trader), broker_items = stub.vector(broker),
            trader_selected = {}, broker_selected = {}}
end

do
    local w, env = fresh()
    metals_report(w, {})
    local wants = env.trade_wants()
    check('a fort short of tools wants picks first', wants[1].label == 'pick', wants[1].label)
    local labels = {}
    for _, x in ipairs(wants) do labels[x.label] = x.limit end
    check('it wants up to five picks', labels.pick == 5, labels.pick)
    check('it wants an anvil when it has none', labels.anvil == 1, labels.anvil)

    for _ = 1, 3 do w.df.global.world.items.other.WEAPON:push(item('WEAPON', {subtype = 'ITEM_WEAPON_PICK'})) end
    w.df.global.world.items.other.WEAPON:push(item('WEAPON', {subtype = 'ITEM_WEAPON_PICK', trader = true}))
    w.df.global.world.items.other.ANVIL:push(item('ANVIL'))
    labels = {}
    for _, x in ipairs(env.trade_wants()) do labels[x.label] = x.limit end
    check('merchants\' picks are not the fort\'s', labels.pick == 2, labels.pick)
    check('one anvil is enough', labels.anvil == nil)
end

do
    local w, env = fresh()
    metals_report(w, {'IRON'})
    local ids = {}
    w.df.global.world.raws.inorganics:push({id = 'IRON'})
    w.df.global.world.raws.inorganics:push({id = 'STEEL'})
    w.df.global.world.raws.inorganics:push({id = 'NICKEL'})
    for _, x in ipairs(env.trade_wants()) do if x.kind == 'bar' then ids[x.inorganic] = x.priority end end
    check('a metal with no ore gets bought', ids.IRON == 1, ids.IRON)
    check('steel comes along with iron', ids.STEEL == 1, ids.STEEL)
    check('and nothing else', ids.NICKEL == nil)

    local iron = item('BAR', {index = 0, value = 100, trader = true})
    local nickel = item('BAR', {index = 2, value = 100, trader = true})
    local pick = item('WEAPON', {subtype = 'ITEM_WEAPON_PICK', value = 200, trader = true})
    local view = trade_view({nickel, iron, pick}, {item('FIGURINE', {value = 1000}),
                                                   item('RING', {value = 50}),
                                                   item('BOULDER', {value = 9999})})
    local plan = env.plan_trade(view)
    check('there is a plan', plan ~= nil)
    check('buys tools before bars', plan.buy[1].item == pick and plan.buy[2].item == iron)
    check('nothing off the list is bought', #plan.buy == 2, #plan.buy)
    check('the offer covers the margin', plan.paid >= plan.cost * 1.5, plan.paid)
    check('the offer spends the fewest goods', #plan.sell == 1 and plan.sell[1].v == 1000)
    check('boulders are never offered', plan.paid < 9999)

    check('not done while the goods are still the merchants\'',
          not env.trade_went_through(plan))
    iron.flags.trader, pick.flags.trader = false, false
    check('done once the goods change hands', env.trade_went_through(plan))
end

do
    local w, env = fresh()
    metals_report(w, {})
    local dear = item('WEAPON', {subtype = 'ITEM_WEAPON_PICK', value = 1000, trader = true})
    local plan, why = env.plan_trade(trade_view({dear}, {item('FIGURINE', {value = 100})}))
    check('no plan when nothing is affordable', plan == nil and why:find('afford', 1, true), why)

    plan, why = env.plan_trade(trade_view({dear}, {}))
    check('no plan with nothing to pay with', plan == nil and why:find('pay with', 1, true), why)

    local wants = {{kind = 'weapon', subtype = 'ITEM_WEAPON_PICK', limit = 1, label = 'pick', priority = 0}}
    local two = {item('WEAPON', {subtype = 'ITEM_WEAPON_PICK', value = 10, trader = true}),
                 item('WEAPON', {subtype = 'ITEM_WEAPON_PICK', value = 10, trader = true})}
    plan = env.plan_trade(trade_view(two, {item('FIGURINE', {value = 1000})}), wants)
    check('stops at the want\'s limit', #plan.buy == 1, #plan.buy)
end

-- ---------------------------------------------------------------- --
do
    local w, env = fresh()
    metals_report(w, {'IRON'})
    w.df.global.world.raws.inorganics:push({id = 'IRON'})
    w.df.global.world.raws.inorganics:push({id = 'COPPER'})
    w.df.global.world.raws.inorganics:push({id = 'STEEL'})
    w.df.historical_entity = {find = function()
        return {resources = {metals = stub.vector{0, 1, 2}}}
    end}
    local pri = stub.vector{0, 2, 4}
    local meeting = {civ_id = 1, sell_requests = {priority = {[7] = pri}}}
    local asked = env.fill_import_requests(meeting)
    check('asks for iron at the highest priority', pri[0] == 4, pri[0])
    check('leaves a metal the fort can mine alone', pri[1] == 2, pri[1])
    check('never lowers one', pri[2] == 4, pri[2])
    check('reports what it asked for', #asked == 1 and asked[1] == 'IRON', #asked)
end

-- ---------------------------------------------------------------- --
do
    local w, env = fresh()
    local c = {entity = 7, trade_state = 1}
    w.df.global.ui.caravans:push(c)
    check('an approaching caravan is not at the depot', env.caravan_at_depot() == nil)
    c.trade_state = 2
    check('one at the depot is', env.caravan_at_depot() == c)
    local v = env.visit(c)
    v.traded = true
    check('progress persists through the visit', env.visit(c).traded == true)
end

print(('%d passed, %d failed'):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
