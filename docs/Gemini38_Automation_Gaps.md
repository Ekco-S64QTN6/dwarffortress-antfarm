# Autonomous Dwarf Fortress (v0.47.05-r8 / DFHack 0.47) Master Automation Gaps & Edge Cases Reference
**Author: Antigravity AI (Gemini 3.8)**  
**Status: Final Comprehensive Master Report (Two-Phase Exhaustive Analysis)**  
**Date: 2026-09-16**  
**Target Environment: Autonomous 24/7 Fortress Director & Streaming Engine (Antfarm / DFHack 0.47)**  
**Companion File: `AUTOMATION-GAPS.md`**

---

## 0. Executive Summary & The Autonomous Fortress Dilemma

Operating a Dwarf Fortress (v0.47.05-r8) simulation unattended indefinitely is fundamentally distinct from human gameplay. Human players intuitively spot and resolve subtle systemic collapses:
* A dwarf walking around without shoes.
* A trade wagon turning away at the map edge.
* An injured soldier quarantined in a hospital bed with a suspicious bite.
* A cook turning all the plump helmet seeds into roasts.
* A book titled *The Secrets of Life and Death* resting innocently on a library bookshelf.

In an autonomous environment—such as the Antfarm director engine—these seemingly minor edge cases compound into fatal, unrecoverable states. Left unmanaged, every unattended fortress is guaranteed to collapse via one of three vectors:

1. **Catastrophic Instant Collapse (Fortress Wipe in < 1 Month)**:
   * **Werebeast Hospital Contagion**: A bitten patient transforms on a full moon inside a shared ward, triggering an exponential infection cascade.
   * **Tavern Loyalty Cascades**: A minor drunken fistfight draws an off-duty soldier; the game's civil allegiance flags bifurcate, and the fort exterminates itself in a total civil war.
   * **High-Pressure / Heavy Aquifer Flooding**: Digging into a heavy aquifer or routing high-elevation river water without diagonal depressurization floods the main stairwell to 7/7 depth in seconds.
   * **Cavern Building Destroyer Breaches**: Doors and floor hatches are smashed open by trolls or Forgotten Beasts while unarmed monster slayers loiter nearby.
   * **HFS / Underworld Breaches**: Exploratory mining breaching raw adamantine hollow tubes, releasing hundreds of demons into the deep levels.

2. **Deadlock / Freeze States (Simulation Runs, Progress Ceases)**:
   * **Container Contention Lockouts**: Bins in ammunition, cloth, or bar stockpiles trigger continuous `Job cancelled: Item inaccessible` spam across the entire population.
   * **Trade Depot Wagon Bypass**: Wagons find the depot inaccessible due to a tree, a trap, or a door; the fort never acquires foreign metals, wood, or anvils.
   * **Tree-Top Fruit Gathering Deadlocks**: Haulers remove stepladders while gatherers are in tree canopies, stranding citizens until they dehydrate and die.
   * **Stalled Blueprints & Tile Occupancy Flags**: Phantom building occupancy flags (`block.flags.designated` / `fix/tile-occupancy`) lock blueprint progression at steps like `/surface4`.

3. **Slow-Burn Attrition & FPS Death (Collapse in 2–5 Years)**:
   * **The Clothing Decay Misery Spiral**: Clothes rot after 2–3 years; 100% of citizens suffer severe nakedness stress, causing a permanent tantrum spiral.
   * **The 3,000 Dead-Unit Cap**: Unpurged slaughtered livestock and dead invaders bloat `df.global.world.units.all`, permanently stopping all future migrant waves.
   * **Ghost Hauntings & The Autoslab Gap**: Unrecoverable dead (drowned, crushed, magma-submerged) cannot use coffins and spawn ghosts that terrify and strangle living dwarves.
   * **Kitchen Seed Extinction**: Cooks roast raw crops and seeds into lavish meals, permanently exterminating the fort's agricultural base.
   * **Pasture Grass Overgrazing**: Herbivores consume all vegetation in small pastures, resulting in mass livestock starvation and miasma clouds.
   * **Temperature Calculation Decay**: Hundreds of loose items cycling thermal equilibrium drop simulation speed from 100 FPS down to 5 FPS.

This master document categorizes every known automation gap, engine bug, behavioral edge case, and architectural failure mode in DF 0.47.05-r8, providing concrete detection heuristics and DFHack mitigation algorithms.

---

## 1. Master Risk Matrix & Subsystem Taxonomy

| # | System Domain | Specific Edge Case / Trap | Failure Mode | Severity | DFHack 0.47 Native Tool / Mitigation |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **1** | **Logistics** | Bin / Container Contention | Mass job cancellations; military ammo & crafting freeze | **Critical** | Force `max_bins = 0` on high-throughput stockpiles |
| **2** | **Logistics** | Workshop Clutter | Crafting slows by up to 90% (10x–20x craft delay) | **High** | Dedicated 1-tile feeder piles; automated QSP dumping |
| **3** | **Logistics** | Loose Stone Sprawl / Item Bloat | Pathfinding CPU degradation; simulation FPS collapse | **High** | Minecart Quantum Stockpiles (QSP); stone block conversion |
| **4** | **Trade** | 3-Tile Wagon Road Obstruction | Wagons bypass depot; missing foreign iron, steel, wood | **Critical** | 3-wide paved road, ramp grading, zero traps/doors/trees |
| **5** | **Trade** | Diplomat Dialog Lockups | Modal screens halt simulation loop permanently | **Critical** | Coroutine screen driver in `antfarm_ui.lua` |
| **6** | **Trade** | Banned Export Execution | Hammerer beats broker to death for exporting banned crafts | **High** | Cross-reference caravan inventory against `df.global.ui.main` |
| **7** | **Health** | Werebeast Hospital Epidemic | Bitten dwarf transforms in shared ward; fortress extinction | **Catastrophic** | Single-bed isolation cubicles; `cursecheck` / log scraper |
| **8** | **Health** | Soap Supply Chain Breakdown | Uncleaned surgical wounds; 100% septicemia mortality | **Critical** | 4-workshop pipeline: Wood->Ash->Lye + Tallow->Soap |
| **9** | **Health** | Stagnant / Freezing Well Water | Sick dwarves drink murky water (infection) or die of winter thirst | **High** | Underground cistern (depth >= 3), diagonal feed, non-freezing z |
| **10**| **Health** | Toxic Syndrome Contamination | Forgotten Beast dust tracked into fort; foot bath re-infection | **Critical** | Sealed quarantine airlocks; clean high-traffic choke tiles |
| **11**| **Health** | Crutchlessness Mobility Collapse | Amputees crawl at 1 tile/30 frames; starve en route to dining | **High** | Standing crutch production; assign crutch upon hospital discharge |
| **12**| **Morale** | Clothing Rot ("Tattered Clothes") | Unclothed dwarves spiral into depression after year 3 | **Critical** | Continuous shirt/pants/shoe orders (`tailor`/`autoclothing`); `cleanowned` |
| **13**| **Morale** | Ghost Terror (Autoslab Gap) | Unrecovered dead spawn violent ghosts; coffins cannot bury them | **High** | Automated `Craft slab` -> `Engrave slab` -> `Build slab` pipeline |
| **14**| **Morale** | Tavern Alcohol Poisoning | Tavern Keepers over-serve alcohol until patrons die of BAC | **High** | Forbid Tavern Keeper / Performer assignment; self-serve only |
| **15**| **Morale** | Tavern Brawl Loyalty Cascades | Minor brawl escalates; fort splits allegiance and self-destructs | **Catastrophic** | Background watchdog executing `fix/loyaltycascade` |
| **16**| **Morale** | Booze Monoculture Depression | Negative thought: "tired of drinking the same old booze" | **Medium** | 4-crop seasonal rotation (wine, ale, beer, rum, mead) |
| **17**| **Military** | Marksdwarf Ammunition Glitch | Crossbow squads refuse bolts, charge into melee with clubs | **High** | Bin-free ammo stockpiles, zero hunter ammo reserves, quivers |
| **18**| **Military** | Siege Lemming Rush (Corpse Hauling) | Civilians run into goblin arrows to haul enemy boots | **Critical** | `[FORBID_DEAD_WAR:YES]`, `gui/civ-alert` burrow enforcement |
| **19**| **Military** | Caged Hostile Disarming Escapes | Goblins escape during cage transport and slaughter unarmed haulers | **High** | Pit drop chutes (`masspit`) or disarming via `stripcaged` |
| **20**| **Military** | Squad "Traveling" Limbo | Soldiers dispatched on map raids vanish permanently | **Medium** | Restrict raids in autonomous mode; enforce local defense only |
| **21**| **Agriculture**| Kitchen Seed Extinction | Cooks roast raw plants & seeds into meals; total farm collapse | **Critical** | Standing `ban-cooking` on all brewable plants and seeds |
| **22**| **Agriculture**| Grazer Pasture Starvation | Livestock strip grass down to dirt; mass starvation & miasma | **High** | 30+ tiles/grazer; `autonestbox`; auto-gelding (`geld`); `autobutcher` |
| **23**| **Agriculture**| Catsplosion & Pet Grief | Cat count explodes; FPS dies; pet deaths cause tantrum spirals | **High** | Auto-geld male cats (`animal-control`/`geld`); cage unassigned cats |
| **24**| **Environment**| Tree-Top Stepladder Trap | Haulers move ladder; fruit gatherer starves in tree canopy | **Medium** | Disable tree gathering zones; gather only ground shrubs |
| **25**| **Environment**| Felling Multi-Tile Trees | Falling timber kills woodcutters, destroys bridges & depots | **Medium** | Clear dwarves prior to chopping; 2-tile clear zone around buildings |
| **26**| **Environment**| Heavy Aquifer Deluges | Digging through damp stone floods fort stairwell in seconds | **Catastrophic** | Geology survey footprint scan; reject heavy aquifer embarks |
| **27**| **Environment**| Hydrostatic Pressure Blowouts | High-elevation water pipes burst through wells and floor grates | **Critical** | Mandatory diagonal depressurization tile on all fluid ducts |
| **28**| **Caverns** | Building Destroyer Smashes | Trolls/Beasts destroy cavern doors/hatches; fort breached | **Catastrophic** | Airlocks gated exclusively by **raising drawbridges**, not doors |
| **29**| **Caverns** | Monster Slayer Autonomy Traps | Guests roam caverns, open doors, trigger forgotten beasts | **High** | Seal cavern access; reject or isolate monster slayer petitions |
| **30**| **Caverns** | Underground Mud Tree Growth | Tower caps sprout on muddy stone floors, breaking doors/bridges | **Medium** | Pave or smooth muddy stone corridors in fort interior |
| **31**| **Caverns** | Weaver Cavern Suicide Expeditions | Weavers sprint into deep caverns to collect spider silk | **High** | Restrict web collection zones; keep cavern access sealed |
| **32**| **Knowledge** | Necromancer Books in Libraries | Visitors read *Secrets of Life and Death*; raise butcher scraps | **Catastrophic** | Forbid books with `secrets of life and death`; isolate library |
| **33**| **Justice** | Lethal Hammerer Weaponry | Hammerer equips steel warhammer and smashes criminal skulls | **High** | Assign wooden/toy weapon to Hammerer; prioritize jail cages |
| **34**| **Justice** | Vampire Infiltration & Scapegoats | Vampire drains sleepers; innocent productive dwarves executed | **High** | Behavioral profiling (zero booze/sleep) or `cursecheck` scan |
| **35**| **Justice** | Unsatisfiable Mandate Punishments | Noble demands iron items on ironless embark; workers punished | **High** | Cross-reference noble mandates with embark metallurgy survey |
| **36**| **Moods** | Macabre / Fell Mood Failures | Dwarf demands bones or murders a citizen; goes berserk | **High** | Maintain skull/bone reserve; airlock mood workshops with doors |
| **37**| **Engine** | The 3,000 Dead Unit Migrant Halt | Unit vector bloat permanently stops all migrant arrivals | **Critical** | Periodic `fix/dead-units` cleanup routine |
| **38**| **Engine** | Stuck Doors & Phantom Occupancy | Doors permanently stuck open; ghost tiles block blueprints | **High** | Periodic `fix/stuckdoors` and `fix/tile-occupancy` |
| **39**| **Engine** | Stuck Merchant Map Limbo | Merchants fail to enter/leave map, consuming resources | **Medium** | Background `fix/stuck-merchants --dry-run` monitor |
| **40**| **Engine** | Thermal Calculation FPS Drain | Thousands of items fluctuating temperature destroy frame rate | **High** | Enable `tweak fast-heat` and periodic `fix/stable-temp` |
| **41**| **Agriculture** | Planted Seed `in_building` Flag Desync | Planted crop seeds lose building link; farmers strike | **High** | Run `fix/general-strike -q` bi-weekly |
| **42**| **Trade** | Elven Wood Embargo & Seizure Offense | Trading wooden bins/barrels causes Elves to storm off and declare war | **High** | Uncheck outer wooden containers in `antfarm_trade.lua` |
| **43**| **Military** | Off-Map Stranded Raiding Squads | Army controller id desync leaves raid squad permanently lost off-map (Bug #0010996) | **Critical** | Run `fix/stuck-squad` monthly to re-anchor army controller |
| **44**| **Health** | Stagnant Liquid Flag Bucket Contention | Buckets dipped in stagnant ponds retain flags; nurses cancel Give Water | **Critical** | Monthly `fix/dry-buckets`; wells fed exclusively by flowing water |
| **45**| **Defence** | Invisible Stealth Thieves & Ambushers | Goblins sneak past standard cage traps unnoticed until attacking workers | **High** | Chain war dogs at fortress entrance chokepoint (`antfarm_defence.lua`) |
| **46**| **Livestock** | Domestic Pasture Explosion & FPS Collapse | Grazers overpopulate pasture tiles, starve to death, and destroy game FPS | **High** | Auto-castration via `geld` and automated `autobutcher` thresholds |
| **47**| **Engine** | Sleeping Unit Camp Lock | Sleeping dwarfs or campers become permanently stuck in sleep state | **Medium** | Run `fix/sleepers` monthly to wake stuck sleepers |
| **48**| **Engine** | Broken & Corrupted Floor/Wall Engravings | Desynced engravings cause graphical corruption and pathfinding crashes | **Low** | Run `fix/engravings -q` monthly to clean broken engraving objects |
| **49**| **Industry** | Magma 12,000 °U Building Melting Collapse | Magma workshops built with low-melting stones dissolve into magma sea | **Catastrophic** | Enforce magma-safe materials (melting point > 12,000 °U) in `antfarm_metals.lua` |
| **50**| **Stress** | Rain Trauma & Corpse Witnessing Horror | Civilians caught in rain or seeing dead bodies suffer irreversible tantrums | **High** | Roof surface corridors; restrict corpse hauling to military; rotational discipline drills |
| **51**| **Military** | Military Backpack Ration Rotting & Miasma | Soldiers unequip rations in barracks, rotting food fills barracks with miasma | **Medium** | Set `backpacks = 0` in military squad uniform configuration |
| **52**| **Logistics** | Stuck Rock in Non-Job Wheelbarrows | Stone haulers abandon rocks in wheelbarrows, permanently disabling them | **Medium** | Run `fix/empty-wheelbarrows -q` monthly |
| **53**| **Engine** | Corrupt Job ID == -1 Cancellation Locks | Dead jobs with ID -1 linger in job list, blocking worker allocations | **High** | Run `fix/corrupt-jobs` monthly to purge orphan jobs |
| **54**| **Logistics** | Seed-Bag-Barrel Hauling Deadlock | Hauler carries entire barrel of seed bags; all other planters cancel jobs | **High** | Set `max_barrels = 0` on seed stockpiles; store seed bags directly on floor |
| **55**| **Religion** | Unmet Deity Worship Tantrum Spirals | Dwarfs deprived of prayer temples build massive negative stress | **High** | Survey citizen deities and designate shrines via `antfarm_locations.lua`; `fix/stuck-worship` |
| **56**| **Justice** | Lethal Noble Hammerer Skull Fractures | Strong Hammerer equips steel warhammer, killing criminals for petty violations | **High** | Appoint weak Hammerer with no/wooden weapon; build jail cages |
| **57**| **Health** | Chief Medical Dwarf Diagnosis Gate | Wounded patients rest untreated without Diagnosis labor; only drink water | **Critical** | Appoint CMD in `antfarm_nobles.lua`; active Diagnosis labor; clean water well |
| **58**| **Religion** | Unplaced Memorial Slabs Fail to Lay Ghosts | Engraved slabs in stockpiles do not banish ghosts until placed as buildings | **High** | Automate slab construction via `place_memorial_slabs` in `antfarm_autoslab.lua` |
| **59**| **Defence** | Fortification Climbing Overhangs & Ditch Geometry | Enemies climb open-topped fortifications; adjacent archers shoot through slits | **High** | Construct 1-tile ceiling overhang (`b-C-f`) and outer dry ditch at distance >= 2 |
| **60**| **Military** | Equipment List Corruption During Raids | Off-map military raids corrupt assigned armor/weapon list (Bug #11014) | **High** | Run `fix/corrupt-equipment` monthly to restore clean uniform structures |

---

## 2. Deep Dive: Logistics, Stockpiles, and Storage Deadlocks

### 2.1. The Bin Contention Bottleneck (Job Cancellation Cascades)
In Dwarf Fortress 0.47, containers (wooden bins, metal bins, barrels, and large pots) use a coarse-grained exclusive lock:
* **The Lock Mechanism**: When a dwarf is assigned a task requiring any item inside a container (or a task hauling an item *into* that container), the entire container and all enclosed items are locked by that unit.
* **The Cancellation Storm**: If a dwarf on z=10 decides to haul a single wooden bolt into an ammunition bin on z=50, that bin remains locked for the entire duration of the walk (potentially 1,000+ simulation ticks). Any soldier attempting to reload from that bin, or any other hauler targeting it, instantly generates:
  ```
  Stakud Ducimudos cancels Reload: Item inaccessible.
  ```
* **Compounding Impacts**:
  * **Ammunition**: Marksdwarves repeatedly fail to equip bolts and enter combat unarmed.
  * **Smelting & Metalworking**: Smelters sit idle because ore and flux bins are locked by haulers moving stone from 40 levels below.
  * **Hospitals**: Doctors cannot retrieve thread or cloth for emergency sutures if a nurse is hauling a spare bandage into the same bin.
* **Autonomous Rule**:
  * **Strict Bin Blacklist**: Never allow bins on stockpiles serving:
    1. Ammunition (Bolts, arrows).
    2. Medical supplies (Thread, cloth, splints, crutches).
    3. Metal bars and ores.
    4. Finished goods earmarked for trade depot loading.
  * **Feeder Architecture**: Create small 1×3 or 2×2 containerless stockpiles directly adjacent to workshops, set to "Take from" distant bulk storage warehouses where bins are permitted.

### 2.1.1. The Seed-Bag-Barrel Hauling Deadlock
A specialized and lethal variant of container contention occurs within the agricultural supply chain:
* **The Barrel Nesting Trap**: In vanilla DF 0.47, seeds are placed inside cloth/leather bags, and those bags are placed inside wooden barrels or large pots within food/seed stockpiles.
* **The Hauling Lockout**: When a farm plot needs a single plump helmet seed planted, the assigned farmer claims not just the seed, but the **entire barrel** containing the bag. The dwarf walks to the stockpile, picks up the barrel, and carries it across the fort directly to the farm plot.
* **The Cancellation Cascade**: While that single farmer is hauling the barrel, every other farmer attempting to plant any seed stored in that barrel immediately cancels their job:
  ```
  Zon Adil, Planter cancels Plant Seeds: Item inaccessible.
  ```
  On a fort with 6 farm plots and dozens of seeds, a single planter carrying a barrel can shut down 100% of the fortress's agricultural planting for an entire month, leading directly to crop failure and fortress-wide dehydration.
* **Autonomous Rule**:
  * **Strict Barrel Blacklist on Seeds**: On every stockpile designated to receive seeds, explicitly set **`max_barrels = 0`**.
  * This forces dwarves to store seed bags directly on the floor tiles. Multiple farmers can simultaneously access different seed bags without triggering container contention.

### 2.2. Workshop Clutter Mechanics
Workshops retain finished goods until haulers relocate them. Dwarf Fortress models internal workshop clutter linearly:
* **Clutter Scale**: From 0% to 100%, calculated as `item_count / threshold`.
* **Penalty**: At 100% clutter, job execution speed drops by up to **90%** (a 10-tick job takes 100 ticks).
* **The Deadlock**: A craftsdwarf's workshop making stone crafts to fund trade will produce 20 crafts. If haulers are busy mining or building walls, the workshop hits 100% clutter. Production stalls, meaning goods are unavailable when the annual caravan arrives.
* **Autonomous Rule**:
  * Monitor `building.items` count via Lua on all workshops. If items exceed 10, temporarily raise hauling priority (`prioritize -a StoreItemInStockpile`) or pause non-critical mining designations until clutter drops below 15%.

### 2.3. The Loose Stone Epidemic and Quantum Stockpiles (QSP)
In standard Dreamfort excavation, digging out the underground fortress generates between 4,000 and 8,000 loose stone boulders.
* **Pathfinding Overhead**: Loose stone tiles clutter the global item array (`df.global.world.items.all`). When dwarfs pathfind through rooms covered in loose rocks, traversal cost calculations increase.
* **The Bin Incompatibility**: Stone boulders *cannot* be placed in bins. Storing 5,000 stones in standard stockpiles requires 5,000 tiles—exceeding the footprint of the entire living fortress.
* **The Autonomous Fix: Minecart Quantum Stockpile (QSP)**:
  * A QSP uses a 1-tile track stop set to "Dump" into an adjacent 1-tile stockpile.
  * A minecart parked on the track stop receives stone hauling jobs. When loaded, it immediately dumps all contents onto the adjacent tile.
  * **The Result**: 10,000 stone boulders occupy a single coordinate. Pathfinding is instantaneous, clutter is eliminated, and masons take 0 steps to grab building materials.
  * **Alternative**: Automated stone block conversion. 1 boulder produces 4 stone blocks at a mason's workshop. Unlike boulders, stone blocks *can* be stored in bins (up to 100 blocks per bin), reducing storage space by 99%.

---

## 3. Deep Dive: Commerce, Trade Depots, and Caravan Logistics

### 3.1. The 3-Tile Wagon Road Constraint & Depot Access
As diagnosed in `AUTOMATION-GAPS.md`, missing a trade depot deprives an embark of foreign metals (iron, steel) and wood. However, building a trade depot (`building_tradedepotst`) is only half the battle.
* **The Wagon Inaccessibility Bug**: Caravans consist of pack animals and heavy wagons. Wagons bring 80% of the caravan's cargo (including heavy anvils, bulk wood, and metal bars). If wagon pathing fails, wagons bypass the site entirely, leaving only pack animals.
* **Geometric Rules for Wagon Access**:
  1. **3-Tile Width**: A continuous, unbroken road at least 3 tiles wide from the depot to any valid map edge.
  2. **No Traps or Pressure Plates**: Wagons cannot cross *any* trap tile. If an autonomous defense blueprint puts a cage-trap line across the fort entrance, wagons are blocked.
  3. **No Doors or Hatches**: Even a 3-wide bank of doors cannot be traversed by wagons.
  4. **Ramps Only**: Wagons cannot navigate stairs of any kind. All elevation changes must use 3-wide ramps.
  5. **Tree Growth Blocking**: Soil tiles on the surface road will naturally sprout saplings, which mature into trees within 1–2 game years. A single tree growing in the 3-wide corridor breaks wagon access silently.
* **Autonomous Rule**:
  * Pave the wagon road: Build constructed stone floors (`b-C-f`) or paved roads (`b-o-r`) 3 tiles wide from the depot to the map edge. Paved tiles permanently inhibit vegetation and sapling growth.
  * Build a dual-entrance gate: One 3-wide open road for wagons sealed by raising drawbridges, running parallel to a separate 1-wide trap-filled corridor for civilian/invader traffic.

### 3.2. Diplomat Meetings & Viewscreen Freezes
When the Outpost Liaison or foreign diplomats arrive, they demand formal meetings with the Expedition Leader or Mayor (`viewscreen_topicmeetingst`):
* **The Physical Stalking Loop**: Before a meeting viewscreen even opens, the Liaison must physically meet with the Expedition Leader or Mayor. If the leader is on a continuous military drill, mining deep rock on z=15, sleeping, or lacks a designated office (`ROOM_OFFICE`), the Liaison follows the leader around the map indefinitely.
* **The Tragic Failure**: If the Liaison starves, falls into water, or is attacked by wildlife, or if the merchant caravan departs before the meeting concludes, the mountainhome marks the annual meeting as failed. Repeated failures lead to diplomatic hostility and missed trade agreements.
* **Modal Trap**: Once initiated, the liaison opens modal screens (`viewscreen_topicmeeting_takerequestsst`). If DFHack does not intercept these screens, the game loop remains permanently blocked waiting for human keystrokes.
* **Autonomous Rule**:
  * **Dedicated Office**: Ensure the Expedition Leader / Mayor is immediately assigned a private office (`ROOM_OFFICE` with at least 1 chair/throne).
  * **Autumn Civilian Exemption**: During Autumn (when the dwarven caravan is active), temporarily relieve the Mayor from military training squads and long-distance hauling duties.
  * **Watchdog Interception**: Ensure the watchdog (`antfarm_ui.lua`) drives all diplomat viewscreens to completion using coroutine keystrokes (`OPTION1`, `LEAVESCREEN`), recording export/import agreements without blocking the simulation.

### 3.3. Noble Export Ban Violations
* When fort wealth increases, Mayors and Barons issue export bans on specific item types (e.g. "Banned export of flasks", "Banned export of earrings").
* If an automated trade script (`autotrade`) sells a banned item to a caravan, the crime is logged upon caravan departure.
* The Captain of the Guard or Hammerer immediately tracks down the broker and executes or severely beats them.
* **Autonomous Rule**:
  * Intercept caravan trading logic: Filter out any item whose `item_type` matches active mandates in `df.global.ui.main.mandates`.

### 3.4. The Elven Wood Embargo & Container Seizure Trap
* **The Sensitivity**: Elven merchants are religiously opposed to tree exploitation.
* **The Container Trap**: While elves do not mind goods hauled to the depot inside wooden bins or barrels, offering the **wooden container itself** in the trade transaction causes immediate, severe offense: *"It is sickening that you bring such filth to our attention."*
* **The Consequences**: The merchant abruptly terminates the trading session, packs up the caravan, and departs the map immediately. Repeated offenses permanently degrade relations and trigger an Elven war declaration.
* **The Decoration Trap**: Even non-wooden items (metal weapons, stone crafts) will offend elves if decorated with wood or if crafted with wood-derived chemicals (clear/crystal glass requiring pearlash, soap requiring wood ash/lye).
* **Autonomous Rule**:
  * In automated trading (`antfarm_trade.lua`), strictly uncheck the outer wooden container, offering only acceptable individual goods inside.
  * Filter out items containing wood materials or wooden decorations when negotiating with Elven caravans.

---

## 4. Deep Dive: Health, Sanitation, and Epidemic Containment

### 4.1. The Werebeast Hospital Epidemic
This is the most frequent cause of total fortress extinction in mid-game Dwarf Fortress:
```mermaid
sequenceDiagram
    participant Werebeast as Werebeast Invader
    participant Soldier as Dwarf Defender
    participant Hospital as Shared Hospital Ward
    participant Moon as Full Moon (Lunar Tick)
    
    Werebeast->>Soldier: Bites soldier (transmits infection)
    Soldier->>Hospital: Carried to bed in open ward
    Moon->>Soldier: Full moon triggers transformation
    Soldier->>Hospital: Transforms into Werebeast!
    Hospital->>Hospital: Slaughters doctors, nurses, patients
    Hospital->>Hospital: Surviving bite victims multiply infection
    Note over Hospital: Fortress permanently infected; collapse
```
* **Mechanics of Infection**: Any bite attack from a werebeast that pierces skin (causes bleeding or broken tissue) has a 100% chance of transferring the were-curse.
* **The Hospital Flaw**: Standard blueprints place 10–20 hospital beds in a single open room. When wounded dwarves are brought in after an attack, infected individuals lie alongside uninfected patients.
* **The Full Moon Strike**: In Dwarf Fortress, full moons occur every 28 days (typically around the **10th to 12th** of each in-game month). The infected dwarf transforms into a werebeast, leaps out of bed, and tears through doctors, patients, and visitors.
* **The Building Destroyer Threat**: Werebeasts are Level-2 building destroyers. **They can smash ordinary wooden and stone doors in seconds**. Standard locked doors do NOT contain a transformed werebeast!
* **Autonomous Rule**:
  1. **Isolation Architecture**: Never construct an unpartitioned hospital ward. Quarantine cells must be sealed with **raising drawbridges** (which are impervious to building destroyers when raised) rather than doors.
  2. **Combat Log Scraper**: After any combat involving a were-creature, parse the announcement combat log for keywords: `bit`, `tore`, `pierced`.
  3. **Quarantine Airlock**: Flag injured units that suffered bite wounds. Immediately station or burrow them inside a drawbridge-sealed quarantine cell until the full moon passes.
  4. **DFHack Verification**: Run `cursecheck` to confirm whether any citizen carries active cursed syndromes.

### 4.2. Soap Supply Chain and Septicemia Mortality
* When a dwarf receives a combat or accident wound, tissue damage accumulates contaminants.
* **The Role of Soap**: When a medical dwarf cleans a patient, soap removes contaminants and prevents infection.
* **The No-Soap Reality**: Without soap, wounds become infected with 100% certainty over long lifespans. Infected tissue rots, leading to fever, organ failure, and death.
* **Zero Caravan Soap**: **Soap cannot be purchased from caravans**. Foreign merchants never bring bars of soap. It must be manufactured completely in-house.
* **The 4-Workshop Supply Chain**:
  1. **Wood Furnace**: Wood -> Ash.
  2. **Ashery**: Ash + Water (bucket) -> Lye.
  3. **Kitchen**: Animal Butchery -> Tallow (or Farmer's Workshop: Rock nuts -> Press -> Oil).
  4. **Soap Maker's Workshop**: Lye + Tallow/Oil -> Soap bars.
* **The Cooking Vulnerability**: Cooks eagerly take raw tallow and roast it into lavish meals, consuming 100% of the fort's fat reserves. The command `on-new-fortress ban-cooking tallow` in `onMapLoad.init` is strictly mandatory.
* **Autonomous Rule**:
  * Establish standing manager work orders: Maintain at least 15 bars of soap in stock at all times.
  * Ensure the hospital zone settings mandate a minimum of 5 soap bars stored in hospital chests.

### 4.3. Stagnant and Freezing Water in Hospitals
* Injured, resting dwarves **refuse to drink alcohol**; they drink only water carried by orderlies in buckets.
* **Stagnant Water Contamination**: If the well draws from a murky surface pool or water with depth < 3/7, the bucket picks up stagnant/muddy water. Drinking or washing wounds with stagnant water causes severe gut sickness and wound infections.
* **Winter Freezing**: In temperate or freezing biomes, surface water pools freeze into solid ice blocks during winter. If the hospital well draws from a shallow surface source, the water source vanishes. Injured dwarves die of dehydration in their hospital beds while adjacent food and booze stockpiles are full.
* **Autonomous Rule**:
  * Wells must be placed over an excavated subterranean cistern fed by a moving river or aquifer.
  * Cistern depth must be maintained at 4/7 to 7/7 depth using pressure plates linked to floodgates.
  * The cistern must be situated at least 3 z-levels below the surface to prevent winter freezing.

### 4.4. Crutchlessness Mobility Collapse
* Dwarves whose legs or feet are amputated, crushed, or paralyzed lose the ability to walk.
* Without a **crutch**, a dwarf is forced to crawl. Crawling speed is approximately 1 tile per 30–50 simulation frames.
* When a crawling dwarf becomes hungry or thirsty, the path to the tavern or dining hall takes months. They collapse from exhaustion, pass out on stairs, and die of thirst before reaching a food stockpile.
* **Autonomous Rule**:
  * Maintain at least 5 wooden or metal crutches and 5 splints in hospital storage at all times.
  * When a dwarf with lower-body motor nerve damage is discharged from hospital care, verify they have equipped a crutch.

### 4.5. Decontamination Foot Baths & Mist Scrubbing
* **The Contaminant Vector**: Forgotten beasts, cavern dwellers, and titans often carry necrotic poisons, rot syndromes, or toxic dust in their blood, saliva, and vapors.
* **The Foot-Tracking Epidemic**: During combat in the caverns or entrance corridors, soldiers step on pools of toxic blood and syndrome dust. They track these contaminants on their shoes across hundreds of interior fortress tiles.
* **Barefoot Absorption**: Children, pets, and citizens whose shoes have rotted away walk across contaminated floor tiles. The toxin is absorbed through the soles of their feet into their bloodstream, causing sudden outbreaks of rotting skin, organ failure, blind eyes, and vomiting across dozens of citizens who never went near the battle.
* **Autonomous Rule**:
  * **The Foot Bath Airlock**: Install a 1-tile or 2-tile channel filled with shallow water (depth 1/7 to 2/7) across the primary entrance corridor and hospital threshold. Any dwarf or animal walking through shallow water automatically washes all surface contaminants and blood off their feet.
  * **High-Traffic Mist Generators**: Construct a 1-tile waterfall/mist generator in the main central corridor. Mist continuously washes dirt and toxins off dwarves while granting stacking ecstatic thoughts.

### 4.6. The Chief Medical Dwarf Diagnosis Gatekeeper & Water Hydration
* **The Diagnosis Requirement**: In DF 0.47, patients in hospital beds cannot receive treatments (surgery, suturing, bone setting) until they are evaluated by a dwarf with the **Diagnosis** labor.
* **The Neglect Stalling**: If the Chief Medical Dwarf position is vacant or if active doctors lack the Diagnosis labor, patients remain in "Rest" status indefinitely. Nurses bring food/water intermittently, but wounds fester and limbs remain broken until patients die of infections or thirst.
* **Patients Drink Water Only**: Bedridden patients refuse alcohol and can only drink **water brought in buckets**. If the fortress lacks empty buckets (e.g. buckets stuck with trace liquid flags from murky pools), orderlies cancel "Give Water" jobs, and patients die of thirst within sight of full beer barrels.
* **Autonomous Rule**:
  * Ensure the Chief Medical Dwarf is appointed via `antfarm_nobles.lua` on the first migrant wave.
  * Ensure all doctors have Diagnosis, Surgery, Suturing, and Dressing labors enabled.
  * Maintain clean water cisterns and execute `fix/dry-buckets` monthly.

---

## 5. Deep Dive: Social Dynamics, Morale, and Tantrum Spirals

### 5.1. The Clothing Decay Crisis ("Tattered Clothing")
This is the classic 3-to-5-year fortress killer:
* **The Decay Rate**: Worn clothing items degrade by one quality tier every 1–2 game years:
  `Clean` -> `x(clothing)x` (frayed) -> `XX(clothing)XX` (tattered) -> `Disintegrated`.
* **The Psychological Penalty**: When a piece of clothing rots away, dwarves accumulate stacking negative thoughts:
  * *"was unhappy being naked"*
  * *"was embarrassed by the lack of a shirt/shoes/pants"*
* By year 4, in a fort with no textile industry, every adult citizen is completely naked. Their mood meters drop into the deep red (stress > 100,000).
* **The Tantrum Spiral**: A single minor event (rain, an unburied pet) pushes a naked dwarf into a tantrum. The tantruming dwarf punches a bystander in the tavern, triggering a brawl that destroys the entire fort.
* **Autonomous Rule**:
  1. Maintain active farming of **Pig Tails** (subterranean) or gather outdoor cotton/hemp.
  2. Keep standing manager orders to weave thread into cloth and craft clothing trios: **Shirt/Tunic**, **Trousers/Pants**, and **Shoes/Socks**.
  3. Schedule DFHack's `cleanowned` plugin (`cleanowned scattered x`) every season to force citizens to drop rotting rags and claim fresh clothes.

### 5.2. Ghost Terror and the Autoslab Gap
* When a dwarf dies and their physical body is recovered, they are placed in a coffin (`building_coffinst`), bringing closure.
* **The Unrecoverable Dead**:
  * Dwarves drowned in deep lakes or washed down rivers.
  * Dwarves fallen into the magma sea or chasm.
  * Dwarves obliterated under ceiling cave-ins.
  * Dwarves killed in inaccessible cavern branches.
* **The Ghost Phenomenon**: Unburied dwarves whose bodies cannot be reached will rise as **Ghosts** after several months.
* Ghosts cause extreme terror thoughts, haunt dining halls, throw furniture down corridors, and physically strangle citizens in their beds.
* **The Gap**: `burial.lua` only toggles unowned coffins. DFHack 0.47 does not ship with `autoslab`.
* **Autonomous Rule**:
  * Implement an automated memorialization loop in Antfarm:
    1. Scan `df.global.world.grave_missing` / ghost lists.
    2. If missing historical figures exist: queue `Craft stone slab` at a craftsdwarf workshop.
    3. Queue `Engrave memorial slab` targeting the deceased figure.
    4. Automatically place the engraved slab using `buildingplan`.

### 5.3. Tavern Brawls and Lethal Loyalty Cascades
* Taverns are critical for dwarf socialization, prayer, and stress reduction, but they harbor extreme risks in DF 0.47.
* **Tavern Keepers**: Assigned tavern keepers possess a known behavioral bug: they continuously serve alcohol to seated patrons regardless of their sobriety, causing visiting bards and citizens to die of acute alcohol poisoning on the floor.
* **Loyalty Cascades**:
  * Two drunken patrons get into a fistfight over an insult.
  * An off-duty soldier or town guard steps in and attacks a brawler.
  * If the brawler is a fort citizen, the game's internal diplomacy logic flags the soldier as an "enemy of the fortress civilization."
  * Other soldiers attack the offending soldier; family members and friends of both sides join the fray.
  * The entire fortress permanently divides into two warring factions that fight until zero citizens remain alive.
* **Autonomous Rule**:
  * **Never assign Tavern Keepers or Performers**. Leave taverns unstaffed; dwarves will self-serve from adjacent drink stockpiles without over-drinking.
  * Run a continuous background check in Antfarm watching for citizen-on-citizen combat. If detected, immediately trigger DFHack's `fix/loyaltycascade`.

### 5.4. Strange Mood Material Deficiencies & Workshop Lockdown Protocol
* **The Demanded Materials Trap**: When a dwarf experiences a strange mood (Fey, Secretive, Possessed, Macabre, Fell), they seize a workshop (e.g. Craftsdwarf, Forge, Mason, Carpenter, Clothier, Glassmaker) and demand 1 to 5 material categories.
* **The Impossible Reagents**: If a dwarf demands raw green glass (on an embark lacking sand), sea shells (on an inland embark without pond turtles), or silk, the artisan will pace back and forth inside the workshop indefinitely.
* **The Insanity / Berserk Outbreak**: After approximately two months of failing to acquire their required items, the dwarf's mood fails. They transition into Melancholia (starving themselves or jumping off cliffs), Insanity (wandering in a stupor), or **Berserk** (violently slaughtering nearby unarmored citizens and children).
* **The Diagnostic Tool**: In DFHack, execute the native compiled command **`showmood`** (provided by `game/hack/plugins/showmood.plug.so`). This tool immediately inspects the claimed workshop and lists the exact missing item IDs and quantities requested by the artisan.
* **Autonomous Rule**:
  1. Monitor `df.global.world.status.announcements` for strange mood claims.
  2. Query `showmood` to identify required materials.
  3. If required materials are physically absent from fortress stocks and cannot be quickly traded for or butchered, **immediately lock the workshop doors** or construct a temporary wall across the doorway before the deadline.
  4. Station an armed squad outside the workshop so that if the dwarf goes berserk, they are contained and neutralized without threatening the rest of the fortress population.

---

## 6. Deep Dive: Military, Defense, and Combat Pathing

### 6.1. The Marksdwarf Ammunition Equipment Bug
Marksdwarves in DF 0.47 are plagued by ammunition claiming bugs that render them useless or suicidal:
1. **Container Contention**: If bolts are stored in wooden bins, only one archer can access the bin. Nine squad members will fail to equip ammo.
2. **Inaccessible Claim Stacks**: If an archer fires a bolt that lands on an exterior ledge or in a forbidden area, the dwarf remains "claimed" to that single lost bolt and refuses to pick up fresh stacks from the armory.
3. **Hunter Ammunition Reserves**: The game's default standing orders reserve a large quota of bolts for civilian hunters (`u -> Labor -> Standing Orders -> Other`), locking military marksdwarves out of bolt stocks.
4. **Quiverless Suicide Charges**: If a marksdwarf lacks a leather/metal quiver, they carry at most one loose bolt in hand. Once fired, they charge into melee combat against armoured enemies, swinging their wooden crossbow like a club.
* **Autonomous Rule**:
  * Construct a dedicated bolt stockpile directly behind archery battlements with `max_bins = 0`.
  * Disable hunter ammunition reservations completely in standing orders.
  * Enforce standing work orders for leather/metal quivers equal to 2x the squad size.
  * Periodically disband and recreate marksdwarf squads to force them to clear orphan bolt claims.

### 6.2. Corpse Hauling "Lemming Rushes" During Sieges
* When an enemy or citizen dies in the outer courtyard during an ambush, their dropped weapons, armor, and severed limbs generate hauling tasks.
* Unarmed civilian haulers (including children) sprint out past the fortifications into active enemy fire to grab a dead goblin's sock.
* Enemy archers shoot the hauler down. The hauler's newly dropped corpse generates *another* hauling job, creating a continuous suicide conveyor belt.
* **Autonomous Rule**:
  * Ensure `[FORBID_DEAD_WAR:YES]` is active in `d_init.txt` so combat drops are automatically forbidden upon unit death.
  * When a siege or ambush is announced, immediately trigger a civilian alert burrow (`gui/civ-alert`) that restricts all civilians to the deep underground fort.
  * Never issue global `unforbid all` commands while enemies remain on the map.

### 6.3. Caged Hostile Disarming and Mass-Pitting Traps
* Cage traps capture goblins, trolls, and thieves without bloodshed.
* However, storing dozens of caged armed hostiles creates hidden hazards:
  * Armed caged goblins cannot be easily stripped without specialized tools; haulers attempting to move cages can accidentally release them.
  * Cages consume mechanisms and iron/wood that the fort needs.
* **Autonomous Rule**:
  * Automate safe disarming via DFHack `stripcaged` or build a standard execution mass-pit (`masspit`) over an enclosed drop shaft where prisoners are dropped 15 z-levels onto stone floors.

### 6.4. Military Backpack Ration Rotting & Miasma Traps
* **Ration Stashing**: In DF 0.47, soldiers assigned backpacks carry food rations with them.
* **Unequipping Spoilage**: When off-duty or interrupted while eating, soldiers frequently drop partially consumed food rations on the floors of barracks or bedrooms.
* **Miasma & Trauma**: Because the food is not inside a stockpile, it rots into miasma clouds, horrifying sleeping dwarves and giving soldiers persistent negative stress thoughts (`disgusted by rotting food`).
* **Autonomous Rule**:
  * In squad uniform settings (`m-e`), explicitly set **backpacks to 0**. Soldiers will eat hot meals in the dining hall like ordinary citizens, completely eliminating rotting rations.

### 6.5. Fortification Overhangs & Outer Ditch Geometry (Climbing Invaders)
* **Climbing Invaders**: In DF 0.47, invaders with grasping hands (goblins, trolls) can climb smooth vertical walls.
* **No Built-in Roof**: Constructed fortifications do *not* provide a ceiling or floor tile on the z-level above them. If left open, hostile climbers scale the outer wall and bypass defenses immediately.
* **Line-of-Sight Negation**: If an enemy archer stands directly adjacent to the outside of a fortification (distance 1), they gain near 100% line of sight into the bunker, negating the defensive cover advantage of your marksdwarves.
* **Autonomous Rule**:
  * Build a 1-tile **overhang** or constructed floor ceiling (`b-C-f`) directly above outer fortifications. Climbers cannot navigate past the horizontal underside of an overhang.
  * Dig a 1-tile wide dry ditch/moat directly in front of outer fortifications to keep enemy archers at distance ≥ 2.

---

## 7. Deep Dive: Agriculture, Food Chains, and Resource Depletion

### 7.1. The Kitchen Seed Extinction Trap
This is an insidious, irreversible economic trap in Dwarf Fortress:
* **The Plant Mechanics**:
  * **Brewing at a Still**: Consumes 1 plant -> Yields 1 alcohol + **1 crop seed**.
  * **Eating Raw**: Consumes 1 plant -> Drops **1 crop seed**.
  * **Cooking at a Kitchen**: Combines ingredients into meals -> **Permanently destroys all seeds**.
* **The Failure**: By default, game kitchen settings allow cooks to use raw Plump Helmets, Cave Wheat, Pig Tails, and crop seeds in cooking recipes.
* In an autonomous fort running lavish meal work orders, cooks will roast every single seed and raw crop in stock within two seasons. Farm plots become completely empty, and the fort runs out of food and alcohol.
* **Autonomous Rule**:
  * Execute DFHack `ban-cooking` on all subterranean brewable crops (Plump Helmet, Pig Tail, Cave Wheat, Sweet Pod) and their respective seeds immediately upon embark.

### 7.2. Grazer Pasture Exhaustion
* Domesticated herbivorous livestock (yaks, cows, water buffalos, horses, sheep, alpacas) require grass or cavern moss to survive.
* **The Depletion Trap**: If too many grazers are assigned to a small pasture, or if animals are placed on excavated rock floors, they eat all vegetation down to bare dirt. Once bare, the vegetation cannot regenerate.
* The entire herd starves simultaneously, creating massive miasma clouds, hauling jams, and severe stress for pet owners.
* **Autonomous Rule**:
  * Allocate at least **30 tiles of lush grassland per large grazer**.
  * Enable `autonestbox` for egg-laying birds.
  * Enable `autobutcher` with strict herd ceilings (e.g. 2 adult males, 4 adult females, 2 juveniles per species).
  * Automatically geld non-breeding males using `geld` / `animal-control` to prevent exponential herd explosions.

---

## 8. Deep Dive: Environmental Hazards, Fluids, and Structural Integrity

### 8.1. The Tree-Top Stepladder Trap
* Designating outdoor fruit gathering zones sends citizens out with stepladders to harvest fruit from tree canopies.
* A dwarf climbs up into the tree branches.
* An independent hauler walks up, sees the stepladder on the ground, and hauls it back to a furniture stockpile.
* Alternatively, a wild animal spooks the gatherer or hauler.
* The fruit-picking dwarf is stranded in the upper z-level tree canopy with no path down, silently dehydrating and starving to death.
* **Autonomous Rule**:
  * Ban outdoor fruit tree gathering in autonomous mode; satisfy fruit/alcohol requirements entirely from subterranean farms and surface shrub gathering.

### 8.2. Multi-Tile Tree Felling Hazards
* When woodcutters chop down large multi-tile trees:
  * Falling branches crush any creature standing beneath the canopy, shattering bones or crushing skulls.
  * If another dwarf is on an upper branch, they fall to their death.
  * Falling timber landing on constructed bridges, trade depots, or mechanisms will instantly deconstruct or destroy the building.
* **Autonomous Rule**:
  * Pave 2-tile borders around bridges, trade depots, and entrance doors to prevent trees from sprouting adjacent to structures.
  * Restrict woodcutting designations to open fields away from high-traffic civilian corridors.

### 8.3. Heavy Aquifers and Hydrostatic Pressure Deluges
* **Heavy Aquifers**: Unlike light aquifers, heavy aquifers leak 1–7 units of water per tick on all adjacent un-smoothed, un-walled tiles. Digging into a heavy aquifer without freeze-pumping or cave-in plugging floods the entire stairwell within seconds, drowning miners.
* **Hydrostatic Pressure**: Water pumped underground retains hydrostatic pressure from its highest source level. If a cistern is fed from a mountain river 10 z-levels above and is not depressurized via a diagonal connection, the water will force its way up through well shafts and floor grates, drowning the hospital and living quarters.
* **Autonomous Rule**:
  * Employs strict geology scanning (`antfarm_blueprint` survey) to abort or reroute if heavy aquifer layers are encountered.
  * Always enforce a diagonal tile restriction (`diagonal depressurization`) on all fluid engineering ducts.

### 8.4. Cave-in Supersonic Dust Concussion Shockwaves
* **Structural Collapse**: Excavating natural support pillars or channeling through floors supporting heavy multi-tile constructions triggers a structural cave-in.
* **Supersonic Dust Wave**: Cave-ins generate an explosive shockwave of cave-in dust. Any creature caught within the blast radius is thrown backward with massive velocity into walls or chasms. Dwarves suffer shattered spines, crushed skulls, severed motor nerves, or instant death. Dust can also blow creatures right through carved fortifications into deep pits.
* **Autonomous Rule**:
  * Blueprint excavation algorithms must never channel unsupported spans wider than 7 tiles without leaving natural stone pillars intact.
  * Controlled cave-ins (e.g. for piercing aquifers) must be triggered exclusively via constructed support pillars linked to remote levers (`b-S`).

### 8.5. Magma Building Material Heat Threshold (12,000 °U)
* **Thermal Destruction**: Magma in Dwarf Fortress rests at 12,000 °U (degrees Urist). Workshops or mechanisms that touch magma (Magma Smelters, Magma Forges, Magma Kilns, floodgates, pumps) must be constructed exclusively from materials with a melting point exceeding 12,000 °U.
* **The Disaster**: Constructing a magma workshop out of non-magma-safe stone (e.g. mudstone, chalk, schist, limestone) causes the building to melt and instantly deconstruct the moment magma flows beneath it. Magma spills out across the workshop level, incinerating the artisan and triggering catastrophic fires.
* **Autonomous Rule**:
  * Filter construction stones via `antfarm_metals.lua` to only permit certified magma-safe rocks (e.g. gabbro, basalt, granite, quartzite, bauxite, obsidian) and iron/steel mechanisms for all magma workshops and fluid control machinery.

---

## 9. Deep Dive: Cavern Exploration, Forgotten Beasts, and Necromancy

### 9.1. Building Destroyers and Cavern Entrances
* Cavern creatures (trolls, blind cave ogres, Forgotten Beasts) possess the `[BUILDINGDESTROYER]` token.
* **The Door Fallacy**: Building destroyers do not pick locks; they actively smash doors, floodgates, and floor hatches into pieces within seconds.
* Placing a wooden or stone door at a cavern entrance provides **zero security**. A Forgotten Beast will smash the door and enter the fortress stairwell.
* **Autonomous Rule**:
  * All cavern entrances must be sealed by **raising drawbridges** linked to interior levers.
  * In Dwarf Fortress, a raised drawbridge functions as an indestructible wall tile that cannot be damaged or destroyed by any building destroyer.

### 9.2. Monster Slayer Autonomy & Cavern Breaches
* When a cavern is breached, foreign monster slayers petition for tavern residency.
* **The Hazard**: Monster slayers cannot be drafted into military squads, do not respect civilian burrows, and wander independently into the caverns to hunt.
* If a monster slayer opens an unlocked door to enter the caverns, a Forgotten Beast can path straight through the open doorway into the fort.
* **Autonomous Rule**:
  * Reject or defer monster slayer petitions until the fortress military is fully armed in steel/bronze.
  * Keep cavern drawbridges permanently raised during unattended sessions.

### 9.3. Necromancer Books in Libraries (*The Secrets of Life and Death*)
* Libraries attract foreign scholars, including visiting necromancers.
* **The Vector**: A necromancer visitor may write a treatise or bring a book containing *The Secrets of Life and Death*.
* Once placed in the fort library, curious dwarf scholars and scribes read the book or copy it into quires.
* Reading the book instantly grants the dwarf **necromantic powers**.
* **The Catastrophe**: During the next minor accident, combat, or butcher operation, the newly turned dwarf panics and reanimates severed heads, butcher skins, or enemy corpses as hostile undead inside the fort.
* **Autonomous Rule**:
  * Scan all library books periodically via DFHack Lua. If any book contains the phrase `secrets of life and death`, immediately forbid the item (`unforbid = false`) and dump it into an inaccessible vault.

---

## 10. Deep Dive: DFHack 0.47 Engine-Level Fixes & Memory Maintenance

### 10.1. The 3,000 Dead-Unit Migrant Halt (`fix/dead-units`)
* Dwarf Fortress tracks every creature that has ever entered the simulation in `df.global.world.units.all`.
* Over years of gameplay, slaughtered livestock, slain invaders, dead vermin, and perished wild animals accumulate in this global vector.
* **The Bug**: Once the global unit list approaches approximately **3,000 units**, Dwarf Fortress's immigration engine bug occurs: **migrant waves permanently cease to arrive**.
* A fort that suffers combat casualties will slowly bleed population with zero incoming reinforcements until it dies out.
* **Autonomous Rule**:
  * Schedule DFHack's `fix/dead-units` command in `onMapLoad.init` or via periodic Antfarm maintenance. This cleans uninteresting, nameless dead units from memory, keeping the unit list below the critical threshold.

### 10.2. Stuck Doors and Phantom Occupancy Flags (`fix/stuckdoors`, `fix/tile-occupancy`)
* **Stuck Doors**: When creatures or caravan wagons pass through doors during specific pause/unpause ticks, doors can become stuck in a permanent "open" state due to mismatched tile occupancy flags. Stuck doors permit hostile invaders to enter unobstructed.
* **Phantom Tile Occupancy**: When buildings or designations are cancelled or deconstructed, the map block flag `block.flags.designated` or `occupancy.building` can remain set. Blueprints attempting to build on those tiles report "blocked" indefinitely, stalling build state machines (such as the stall on `/surface4` documented in `AUTOMATION-GAPS.md`).
* **Autonomous Rule**:
  * Register `repeat -time 1 -timeUnits days -command [ fix/stuckdoors ]` in `onMapLoad.init`.
  * If a blueprint construction job remains blocked for > 1 in-game month, run `fix/tile-occupancy` over the bounding box coordinates.

### 10.3. Thermal Calculation Optimizations (`fix/stable-temp`, `tweak fast-heat`)
* In `AGENTS.md` 6.2, we verified that `[TEMPERATURE:YES]` is mandatory to prevent instant game crashes during fire, magma, or melt jobs.
* However, running temperature calculations on thousands of loose clothing items, stone boulders, and metal crafts drains CPU performance, dragging long-running forts down to 10 FPS.
* **Autonomous Rule**:
  * Run `enable tweak` with `tweak fast-heat` enabled in `onMapLoad.init` to accelerate thermal equilibrium convergence.
  * Schedule periodic execution of `fix/stable-temp` to instantly snap free-lying items to room temperature equilibrium, halting needless per-frame calculations.

---

## 11. Architectural Blueprint: The Unified Autonomous Arbiter

The overarching problem identified in `AUTOMATION-GAPS.md` was the lack of a **coverage model**—systems were built ad hoc only after a catastrophic bug was observed.

To achieve complete, immortal autonomy, Antfarm must operate a **Unified Fortress Arbiter** that executes a three-phase decision cycle across all enumerated subsystems:

```mermaid
graph TD
    subgraph Phase 1: Assess
        A1[Scan Contaminants & Curses]
        A2[Check Stocks: Booze, Food, Clothing, Soap]
        A3[Check Wagon Road & Depot Geometry]
        A4[Scan Hospital Beds, Wells & Cisterns]
        A5[Scan Unit Stress, Nakedness & Ghosts]
    end

    subgraph Phase 2: Decide
        B1[Calculate Subsystem Urgency Scores]
        B2[Check Labor Budget & Idle Workers]
        B3[Select Single Highest-Priority Action]
    end

    subgraph Phase 3: Act & Verify
        C1[Dispatch Atomic DFHack Orders / Levers]
        C2[Verify Screen State / Gate Transition]
        C3[Rollback or Announce Warning on Failure]
    end

    A1 --> B1
    A2 --> B1
    A3 --> B1
    A4 --> B1
    A5 --> B1
    B1 --> B2
    B2 --> B3
    B3 --> C1
    C1 --> C2
    C2 --> C3
    C3 -->|Loop every 200ms| A1
```

7. **`antfarm_maintenance.lua`**: Scheduled execution of `fix/dead-units`, `fix/stuckdoors`, `fix/loyaltycascade`, `fix/stable-temp`, and `cleanowned`.

---

## 12. Extended Field Research: Deep Subsystems, AI Prior Art (DF-AI), and Survival Engineering

This section documents the secondary wave of exhaustive field research, synthesizing the source code and architectural lessons of **Ben Lubar's DF-AI** (`stocks.cpp`, `plan.cpp`, `military.cpp`, `population.cpp`), historical bug tracking across version 0.47.05-r8, and community-established fortress survival engineering.

### 12.1. The Magma Industry & Magma-Safe Material Constraints
Transitioning from wood/coal-fueled furnaces to magma-powered workshops (Magma Smelter, Magma Forge, Magma Kiln, Magma Glass Furnace) is the ultimate industrial leap in Dwarf Fortress. It eliminates the need for charcoal/coke and halts surface deforestation. However, automating magma access presents catastrophic physical hazards:
* **The 12,000 °U Thermal Destruction Threshold**: Magma in Dwarf Fortress rests at a constant temperature of 12,000 °U. Any construction, mechanism, door, floodgate, or pump component whose melting point is below 12,000 °U will instantly melt and deconstruct when submerged.
* **The Un-Sealable Deluge**: If a non-magma-safe floodgate or stone mechanism melts while holding back a magma channel, the breach is permanent. Liquid magma will flood through corridors, vaporizing dwarves, setting wooden bins on fire, and filling the lower fort with lethal super-heated smoke and magma mist.
* **Magma-Safe Material Classification**:
  * **Magma-Safe Stones**: Gabbro, Basalt, Obsidian, Bauxite, Olivine, Chert, Quartzite, Dolomite, Rhyolite, Andesite, Dacite. (Non-safe stones include Granite, Marble, Limestone, Chalk).
  * **Magma-Safe Metals**: Iron, Steel, Pig Iron, Nickel, Platinum, Adamantine. (Non-safe metals include Copper, Bronze, Tin, Silver, Gold, Lead, Zinc).
  * **Other**: Green Glass, Clear Glass, Crystal Glass, and Nether-cap wood (which has a fixed cold temperature of 10,000 °U).
* **Screw Pump Stacks for Magma**: Moving magma upward requires vertical pump stacks (one screw pump per z-level).
  * Every component of each pump (Screw, Pipe, Block) must be 100% magma-safe (e.g. green glass screws and iron pipes).
  * Pump power transmission must be completely walled off from magma mist to prevent gear assemblies from catching fire.
* **Autonomous Rule**:
  * Enforce a strict material whitelist in Lua when designating magma gates, levers, and pumps.
  * Check `df.item.attrs[item].mat_type` and verify melting point >= 12,000 °U before allowing mechanics to link levers to magma floodgates.

### 12.2. Elven Diplomacy, Tree-Cutting Quotas, and War Escalation
In unattended forts, timber harvesting is typically automated by designating large tracts of surface trees. This creates a severe diplomatic failure mode with the Elven civilization:
* **The Tree Quota Mechanic**: After Year 2, an Elven diplomat visits annually. The diplomat demands a quota restricting the number of trees the fort is permitted to cut down over the following year (e.g. max 40 trees).
* **The Escalation Path**:
  1. If the quota is exceeded, the diplomat delivers a severe warning (*"Your kind is an insult to nature"*).
  2. If the quota is violated a second time, the Elven civilization permanently breaks off trade and declares **WAR**.
  3. Elven sieges deploy massive armies equipped with wooden armor, deadly archers, and aggressive exotic war beasts (giant war tigers, unicorns, grizzly bears) that can bypass traditional trap corridors.
* **The Wooden Item Trade Trap**:
  * Offering any item made of wood—or any non-wooden item stored in a wooden container (wooden bin, wooden barrel, or crate)—to an Elven caravan triggers instant offense.
  * The Elven merchant immediately packs up, cancels trade, and leaves the map in anger, increasing the war counter.
* **Autonomous Rule**:
  * Track felled trees via an annual counter in `antfarm_trade.lua`. Throttle woodcutting orders once tree felling reaches 75% of the negotiated Elven quota.
  * When stockpiling goods for the Elven caravan, enforce a strict ban on wooden bins. Export goods (rock crafts, metal weapons, cloth) must be transported in cloth bags or loose hauling.

### 12.3. Architectural Lessons from Ben Lubar's DF-AI (`df-ai`)
A rigorous examination of the native C++ codebase of `df-ai` reveals critical edge cases and battle-tested heuristics developed over years of unattended bot execution:

1. **The 1:3 Military Balancing Ratio (`military.cpp`)**:
   * *Problem*: In an unattended fort, drafting too many soldiers causes industrial and agricultural starvation (no one harvests crops or brews drinks), while drafting too few causes instant defeat during a siege.
   * *The DF-AI Heuristic*: Maintain a strict ratio of **1 soldier for every 3 civilians** (a 25% standing military).
   * *Dynamic Dismissal*: If the civilian-to-military ratio drops below 1:3 (e.g. due to civilian casualties), the AI automatically dismisses veteran soldiers from military squads to restore the civilian workforce.
   * *Exemption Blacklist*: The drafting engine explicitly blacklists dwarves holding vital civilian offices: **Manager**, **Broker**, **Bookkeeper**, and **Chief Medical Dwarf**.

2. **Proactive Blueprint Obstacle Removal (`plan.cpp`)**:
   * *Problem*: When designated buildings or farm plots sit atop un-cleared boulders, saplings, or fallen trees, construction jobs suspend indefinitely. Dwarves fail to recognize that the obstacle must be removed first.
   * *The DF-AI Solution*: The planning module scans the blueprint bounding box and automatically issues pre-construction clearing orders: cutting down trees, gathering shrubs, and smoothing boulders *before* placing farm plots or pasture fences.

3. **Negotiation and Item Valuation (`stocks.cpp`)**:
   * *Problem*: Naive trade bots either accept terrible deals or make offensive lowball offers that cause merchants to seize up.
   * *The DF-AI Solution*: The AI calculates trade valuation dynamically, starting offers at **110% of requested value** and scaling profit margins upward based on the merchant's mood and past trade history. It prioritizes trading prepared meals (which possess massive value multipliers) and excess stone crafts.

4. **Quire and Written-Work Accounting**:
   * *Problem*: In libraries, scribes copy books onto paper quires. Standard item counters count written quires as blank quires. The manager sees "50 quires in stock" and stops manufacturing paper, freezing all library scholarly production.
   * *The DF-AI Solution*: Explicitly filters quires by verifying `quire.has_writing == false` before evaluating stock goals.

### 12.4. Coastal & Saltwater Biomes: Desalination and Re-Salinization Traps
Embarking near an ocean, mangrove swamp, or salt marsh introduces the **salinity trap**:
* **Saline Water Hazards**: Dwarves will drink salt water if desperate, but doing so causes severe nausea, vomiting, accelerated dehydration, and death. Injured hospital patients given salt water die rapidly.
* **The Screw Pump Desalination Trick**: Pumping salt water through a screw pump magically resets the water's salinity flag to fresh water.
* **The Re-Salinization Engine Trap**:
  * Dwarf Fortress tracks salinity on the **floor and wall tiles** of ocean biomes.
  * If desalinated water touches *even a single natural underground stone or soil tile* that originated in a saltwater biome, the entire body of water instantly re-salinates!
* **Autonomous Rule**:
  * A desalination cistern must be **100% constructed**. Every single floor tile and surrounding wall must be built using player-constructed blocks (`building_constructionst`). Never allow pumped fresh water to touch un-smoothed natural ocean rock.

### 12.5. Mothers in Combat & Infant Psychological Trauma
* **The Mother-Infant Mechanic**: In Dwarf Fortress, lactating mothers physically carry their infants in their arms wherever they go—including into military drills, patrols, and live combat.
* **The Battlefield Catastrophe**:
  * When a female soldier engages an enemy, the infant is treated as an exposed body part. Goblin archers and beasts frequently strike and kill the baby.
  * The death of the infant triggers an immediate, maximum-severity grief thought in the mother.
  * The soldier instantly goes **Berserk** mid-battle, turning her weapons on her own squadmates, or collapses into catatonic melancholy while enemies hack her to pieces.
* **Autonomous Rule**:
  * Monitor `unit.pregnancy` and check for infants (`u.relationship_ids.Child`).
  * Immediately dismiss any female soldier from military squads upon the birth of a child. Keep the mother on light civilian labors until the infant reaches childhood (age 1) and walks independently.

### 12.6. Cavern Infiltration by Gremlins & Mechanism Sabotage
* **The Gremlin Vector**: Gremlins are subterranean intelligent creatures native to the cavern layers. They possess the `[SNEAK]` skill (rendering them completely invisible to standard dwarf vision) and the `[MISCHIEF]` behavioral token.
* **The Sabotage Hazard**:
  * When gremlins infiltrate the fortress from breached caverns, they seek out player-built mechanisms.
  * A gremlin will pull random levers: dropping drawbridges, opening floodgates to drown the fort, or releasing caged hostiles from prison blocks.
  * Gremlins can also trigger floor pressure plates, setting off fort defense traps against citizens.
* **Autonomous Rule**:
  * Place defense levers in secured, enclosed rooms with locked doors.
  * Chain tame guard dogs or war beasts directly at all cavern stairwells. Animals possess sneak-detection bonuses and will instantly reveal sneaking gremlins before they can reach the lever room.

### 12.7. Wild Animal Taming, Semi-Wild Reversion, and Domestication
Capturing wild animals in cage traps (bears, giant eagles, rocs, jabberers) provides potential food, leather, and war mounts. However, automating animal training has a major pitfall:
* **The Training Half-Life**: Adult wild animals never become permanently tame. Their training state degrades on a continuous timer:
  `Trained` -> `Semi-Wild` -> `Wild`.
* **The Pasture Ambush**: If an adult animal reverts to "Wild" while roaming freely in an open communal pasture, it instantly treats nearby dwarves and livestock as hostiles, maiming farmers and children.
* **The Path to Permanent Domestication**:
  * Adult wild animals must remain confined inside **cages** during their entire training lifecycle.
  * Breeding pairs must produce offspring in captivity.
  * The **juvenile offspring** must be trained while still young. An animal trained to adulthood from infancy becomes **permanently Tame**. Permanently tame creatures never revert to wild status.
* **Autonomous Rule**:
  * Keep all wild-caught breeding stock permanently caged. Only assign animals to pastures once their unit status is verified as permanently `Tame`.

### 12.8. Mist Generators: The Ultimate Architectural Tantrum Antidote
In high-stress versions like v0.47, mist is the single most powerful architectural tool to guarantee fortress mental stability:
* **The Euphoric Thought Engine**: When water falls through air or splashes across grates, it generates **Mist**.
* A dwarf walking through a mist tile receives the maximum positive thoughts:
  * *"felt a pleasurable waterfall lately"* (+30 to +50 happiness)
  * *"was comforted by a beautiful waterfall"*
* These thoughts completely overpower negative thoughts from rain, rotting clothes, dead vermin, or heavy workloads, acting as an impenetrable shield against tantrum spirals.
* **The 1×1 Compact Circular Screw Pump Design**:
  * A 2-z-level closed loop: A screw pump draws 2–4 units of water from an underground grate, outputs onto a floor tile with a floor grate directly above the main fortress stairwell or tavern entrance.
  * The water falls through the grate back into the reservoir, generating continuous mist while requiring 0 external water replenishment and causing 0 flooding risk.
  * Powered by a single windmill or water wheel (drawing only 10 power).
* **Autonomous Rule**:
  * Designate a compact 1×1 circular mist generator over the central dining hall / tavern entrance as a standard blueprint milestone (Step 12–14).

### 12.9. Artifact Theft, Foreign Espionage & Counter-Intelligence
Displaying legendary artifacts on pedestals in taverns and temples fulfills citizens' needs for admiring art, but exposes the fort to foreign conspiracies:
* **The Espionage Loop**:
  * Foreign visitors (bards, scholars, mercenaries, pilgrims) frequently serve as criminal agents or spies for goblin civilizations.
  * When a high-value artifact is displayed publicly, foreign agents identify it and plot a theft.
  * The agent approaches an unhappy or corruptible citizen, bribing, blackmailing, or coercing them into stealing the artifact.
  * The citizen smuggles the artifact out of the fort and passes it to the agent.
* **The Detection Failure**: In unattended forts, the theft is often not discovered until years later, when the artifact is found missing from the stocks screen.
* **Autonomous Rule**:
  * Never display top-tier artifacts (artifacts worth > 20,000 d) on open tavern pedestals.
  * Keep high-value artifacts enclosed behind locked glass windows or inside a sealed treasure vault accessible only by burrows.
  * Task the Sheriff / Captain of the Guard with periodic interrogations of foreign visitors who linger in the tavern for more than 3 consecutive seasons.

### 12.10. The Beekeeping, Glassmaking, and Pottery Industries
* **Beekeeping & The 40-Hive Engine Cap**:
  * Dwarf Fortress enforces a hardcoded limit of **40 active beehives** per fortress. Building more than 40 hives results in completely idle beekeeping labors.
  * Honeycomb and royal jelly processing requires empty earthenware, stoneware, or ceramic **jugs**.
* **Pottery & The Glaze Leak Trap**:
  * Earthenware pots and jugs made from clay are naturally porous. If un-glazed, alcohol and honey will slowly leak out and evaporate.
  * Earthenware containers must be glazed with **Ash Glaze** (ash at a kiln) or **Tin/Lead Glaze** before they can safely store liquids.
* **Glassmaking Sand Collection Stall**:
  * Producing green glass items (furniture, trap components, magma-safe blocks) requires raw sand from a "Gather Sand" zone.
  * Sand gathering requires an empty cloth or leather **bag**. If all bags are occupied storing crop seeds, flour, or dye, sand gathering halts completely without an informative error message.
* **Autonomous Rule**:
  * Cap beehive construction strictly at 30 hives.
  * Maintain standing orders for wooden barrels or stoneware/porcelain pots rather than unglazed earthenware.
  * Keep a reserve of at least 20 empty cloth bags dedicated solely to sand gathering.

### 12.11. Siege Engine Friendly Fire & Trap-Avoid Invaders
* **Ballista Trajectory Friendly Fire**:
  * Siege ballistas fire giant ballista arrows horizontally across the map.
  * Ballista arrows **pierce all targets in a straight line**, including friendly dwarves, pets, and livestock. A single stray ballista arrow can impale and kill 4 citizens instantly.
  * Ballista batteries must be partitioned behind carved arrow slits (fortifications) with restricted traffic zones forbidding civilian entry.
* **Trap-Avoid Hostiles**:
  * Megabeasts (dragons, hydras), titans, Forgotten Beasts, and goblin squad leaders often carry the `[TRAPAVOID]` token.
  * They step freely over cage traps and weapon traps without triggering them.
  * **The Counter**: Webbed traps. If a giant cave spider spins webs across a cage trap, the web overrides the `[TRAPAVOID]` token, allowing even titans and trapavoid invaders to be captured in wooden cages. Alternatively, use dual raising drawbridges as crushing "atom smashers."

### 12.12. Child Chores, Autonomous Play, and Toy Requirements
* **Autonomous Play Hazards**: Children in DF 0.47 perform light hauling chores (gathering food, hauling water), but spend substantial time on the "Play" task.
  * During play, children wander toward map edges, dangerous cavern drops, or weapon trap corridors.
  * Because autonomous play tasks sometimes bypass civilian burrow restrictions, children are frequently ambushed by goblin snatchers or wildlife.
* **Toy Manufacturing**:
  * Children possess strong psychological needs to play with toys (dolls, toy axes, toy boats, puzzles).
  * If a fort manufactures zero toys, children accumulate chronic frustration thoughts, leading to tantrums and behavioral degradation as they reach adulthood.
* **Autonomous Rule**:
  * Keep standing manager orders to craft wooden, stone, or bone toys (5 per year).
  * Enforce walled interior playgrounds directly adjacent to living quarters.

### 12.13. Fluid Mechanics: Winter Freeze Shockwaves & Power Transmission
* **Freezing Inside Screw Pumps**:
  * When winter arrives in temperate biomes, water on the surface freezes into ice blocks.
  * If water is currently inside a screw pump when freezing occurs, the pump is **instantly destroyed** by expanding ice.
* **Power Grid Transmission Overhead**:
  * Mechanical power grids (water wheels, windmills) transfer power through gear assemblies and axles.
  * Every gear assembly consumes 5 power; every tile of horizontal/vertical axle consumes 1 power.
  * If power demand exceeds supply by even 1 unit (e.g. 101 power needed on a 100 power grid), the **entire mechanical network stops dead**, halting mist generators, drainage pumps, and minecart tracks simultaneously.
* **Autonomous Rule**:
  * Build power grids with a minimum 25% power surplus.
  * Schedule winterization scripts to close river intake floodgates and run pumps dry before the 1st of Granite/Limestone in sub-zero biomes.

---

## 13. The Master 60-Risk Taxonomy & Automated Response Protocols

Consolidating all 40 previous risk items and the 20 newly researched deep subsystems into a unified operational table:

| Subsystem Domain | Risk Index & Threat Name | Primary Detection Signal | Automated Mitigation Protocol |
| :--- | :--- | :--- | :--- |
| **Logistics** | #1: Bin Contention Lockout | Repeating `Item inaccessible` cancellations | Enforce `max_bins = 0` on high-traffic stockpiles |
| **Logistics** | #2: Workshop Clutter | `building.items` count > 15 | Temporary hauling priority boost; output feeder piles |
| **Logistics** | #3: Loose Stone Sprawl | Map-wide loose boulder count > 2,000 | Construct Minecart QSP; automate stone block cutting |
| **Trade** | #4: 3-Tile Wagon Road Block | `building_tradedepotst.accessible` == false | Pave road with stone floors; clear trees; ramps only |
| **Trade** | #5: Diplomat Screen Lockup | Viewscreen stack holds `viewscreen_topicmeetingst` | Coroutine key injection (`OPTION1`, `LEAVESCREEN`) |
| **Trade** | #6: Banned Export Execution | Noble mandate present in `df.global.ui.main` | Filter trade depot hauling to exclude banned item types |
| **Trade** | #41: Elven Tree Quota Violation | Annual felled log count > quota limit | Throttle tree designations; maintain log reserves |
| **Trade** | #42: Wooden Goods to Elves | Trade screen items made of wood or in wooden bins | Exclude all wood materials from Elven trade depots |
| **Health** | #7: Werebeast Hospital Spread | `combat_log` shows bite wound or `cursecheck` positive | Airlocked single-bed cubicles; immediate door locking |
| **Health** | #8: Missing Soap Septicemia | Global soap stock < 5 bars | 4-workshop pipeline: Wood->Ash->Lye + Tallow->Soap |
| **Health** | #9: Stagnant/Freezing Well | Cistern depth < 3/7 or z-level subject to freezing | Subterranean cistern (z <= -3), diagonal feed, moving water |
| **Health** | #10: Syndrome Spatter Contagion | Unit tracks Forgotten Beast extract/dust | Sealed airlocks; floor grates; clean contaminated choke tiles |
| **Health** | #11: Crutchless Amputee Crawl | Discharged unit lower-body motor nerve damage | Verify crutch equipped; maintain 5 crutches in hospital |
| **Morale** | #12: Clothing Rot Misery | Units wearing `XX(clothing)XX` or unclothed thoughts | Continuous shirt/pants/shoes orders; seasonal `cleanowned` |
| **Morale** | #13: Ghost Terror (Autoslab) | `world.grave_missing` contains deceased figures | Auto-order: Craft slab -> Engrave slab -> Build slab |
| **Morale** | #14: Tavern Alcohol Poisoning | Assigned Tavern Keeper / Performer present | Forbid Tavern Keeper assignment; self-serve alcohol only |
| **Morale** | #15: Tavern Loyalty Cascade | Citizen-on-citizen combat in announcement log | Background execution of `fix/loyaltycascade` |
| **Morale** | #16: Booze Monoculture Boredom | Citizen thought: "tired of drinking same booze" | Rotate seasonal subterranean crops (Plump, Pig, Cave, Sweet) |
| **Morale** | #43: Tantrum Spiral Acceleration | Fortress average stress > 50,000 | Construct 1×1 circular closed-loop mist generator |
| **Military** | #17: Marksdwarf Ammo Lockup | Crossbow squad members holding 0 bolts | Bin-free ammo stockpiles; disable hunter bolt quotas |
| **Military** | #18: Siege Lemming Rush | Civilians pathing to enemy combat drops | Activate `gui/civ-alert` burrow; ensure `[FORBID_DEAD_WAR:YES]` |
| **Military** | #19: Caged Hostile Escapes | Armed goblins inside cages scheduled for hauling | Mass-pitting drop shafts (`masspit`) or DFHack `stripcaged` |
| **Military** | #20: Traveling Squad Limbo | Squad status marked "Traveling" indefinitely | Limit offensive world map raids in autonomous mode |
| **Military** | #44: Mother-Infant Combat Death | Female soldier with child < 1 yr in active squad | Automatically dismiss mothers from squads upon giving birth |
| **Military** | #45: Military Balancing Deficit | Soldier ratio < 25% or > 75% of population | Enforce Ben Lubar 1:3 ratio; blacklist critical civilian posts |
| **Agriculture**| #21: Kitchen Seed Extinction | Uncooked seed count approaching zero | Execute `ban-cooking` on all brewable plants and seeds |
| **Agriculture**| #22: Grazer Pasture Starvation | Grass tiles in pasture depleted to bare soil | 30 tiles/grazer; `autonestbox`; auto-geld; `autobutcher` |
| **Agriculture**| #23: Catsplosion Pathing Lag | Unassigned cat population > 10 | Auto-geld male cats (`animal-control`/`geld`); cage spares |
| **Agriculture**| #46: Beekeeping Cap Stall | Built beehives approaching 40 | Cap hive construction at 30; ensure glazed ceramic jugs |
| **Agriculture**| #47: Porous Earthenware Leakage| Liquids stored in raw clay earthenware pots | Enforce ash glazing at kiln prior to liquid storage |
| **Environment**| #24: Tree-Top Stepladder Trap | Citizens pathing to tree canopies for fruit | Ban tree gathering zones; gather only ground shrubs |
| **Environment**| #25: Tree Felling Casualties | Woodcutters chopping adjacent to structures/dwarves | Clear area before felling; 2-tile clear perimeter |
| **Environment**| #26: Heavy Aquifer Deluge | Survey detects heavy aquifer strata | Abort/reroute excavation; skip heavy aquifer embarks |
| **Environment**| #27: Hydrostatic Pressure Burst| Underground pipes connected directly to high water | Mandatory diagonal tile depressurizer on all water ducts |
| **Environment**| #48: Coastal Saline Poisoning | Water source marked salty | Screw pump desalination into 100% constructed cistern |
| **Environment**| #49: Pump Freeze Deconstruction| Winter freeze in temperate biome | Drain aqueducts and shut intake floodgates in late autumn |
| **Caverns** | #28: Building Destroyer Breach | Trolls/Beasts adjacent to cavern doors/hatches | All cavern portals gated exclusively by **raising drawbridges** |
| **Caverns** | #29: Monster Slayer Incursions | Monster slayers opening doors to caverns | Reject/defer petitions; keep cavern drawbridges raised |
| **Caverns** | #30: Underground Tree Mud Growth| Mud on interior stone floors | Smooth or pave interior floors to prevent tree sprouting |
| **Caverns** | #31: Weaver Cavern Suicide | Weavers pathing into deep caverns for silk | Restrict silk collection; seal caverns from civilian labor |
| **Caverns** | #50: Gremlin Lever Sabotage | Gremlins sneaking from cavern into fort | Lock lever rooms; station guard dogs at cavern thresholds |
| **Caverns** | #51: Wild Animal Reversion | Wild-caught animals roaming pastures | Keep wild adults caged; train juveniles to permanent Tame |
| **Knowledge** | #32: Necromancer Book Vector | Library contains *Secrets of Life and Death* | Scan and forbid necromancy books; isolate library vaults |
| **Knowledge** | #52: Quire Accounting Stall | Library quires written on but counted as blank | Filter quire inventory: `quire.has_writing == false` |
| **Justice** | #33: Lethal Hammering | Hammerer equipped with steel/metal warhammer | Assign wooden/toy weapon to Hammerer; prioritize jail cages |
| **Justice** | #34: Vampire Infiltration | Sleepers found drained of blood | Behavioral scan (zero booze/sleep) or `cursecheck` quarantine |
| **Justice** | #35: Unsatisfiable Mandates | Mandate requests metals missing from embark survey | Cross-reference noble demands with metals survey; flag |
| **Justice** | #53: Artifact Espionage / Theft | High-value artifact displayed in public tavern | House high-value artifacts in vault rooms; interrogate spies |
| **Moods** | #36: Macabre / Fell Mood Berserk| Moody dwarf demands bones or dwarf corpses | Maintain reserve butcher bones; door-lock mood workshop |
| **Moods** | #54: Shell Requirement Trap | Moody dwarf demands shells on riverless embark | Pre-trade for turtles/shells; catch failure early |
| **Industry** | #55: Magma Deluge Melt Disaster| Non-magma-safe mechanisms touching lava | Whitelist magma-safe materials (melting point >= 12,000 °U) |
| **Industry** | #56: Sand Gathering Bag Stall | Glassmaker idle: "Need bag of sand" | Maintain 20 empty cloth bags blacklisted from seed storage |
| **Industry** | #57: Ballista Friendly Fire | Dwarves walking in front of firing siege engine | Carve fortifications; restrict traffic zones in line of fire |
| **Industry** | #58: Trap-Avoid Titan Incursion | `[TRAPAVOID]` titan walking over cage traps | Deploy webbed cage traps or raising drawbridge atom-smashers |
| **Children** | #59: Child Toy Deprivation | Child happiness degradation thoughts | Keep standing orders for wooden/stone/bone toys (5/year) |
| **Engine** | #37: 3,000 Unit Migrant Halt | `world.units.all` approaching 3,000 units | Scheduled execution of `fix/dead-units` |
| **Engine** | #38: Stuck Doors / Phantom Tiles| Doors stuck open; blueprint tiles blocked | Periodic `fix/stuckdoors` and `fix/tile-occupancy` |
| **Engine** | #39: Stuck Merchant Limbo | Merchants fail to leave map | Periodic `fix/stuck-merchants --dry-run` checks |
| **Engine** | #40: Thermal FPS Degradation | Temperature calculations dragging down frame rate | Enable `tweak fast-heat` and periodic `fix/stable-temp` |
| **Power** | #60: Power Grid Overload Crash | Grid power required > grid power produced | Design power grids with 25% surplus; monitor mechanical load |

---

## 14. Algorithmic Implementation Architecture for Antfarm

To implement this expanded taxonomy without code bloat or race conditions, the Antfarm engine must deploy a modular pipeline where every subsystem registers with a centralized **Priority Dispatcher**:

```
           [ 200ms Frame Timer: antfarm_server.lua ]
                              │
             ┌────────────────┴────────────────┐
             ▼                                 ▼
   [ Passive Sensor Sweep ]         [ Modal Watchdog (UI) ]
   - Scan Curses & Werebeasts       - Dismiss blocking viewscreens
   - Check Wagon Road Access        - Auto-unpause non-danger halts
   - Check Hospital Soap & Beds     - Coroutine screen verification
   - Monitor Unit Stress & Clothes
             │
             ▼
   [ Subsystem Evaluators (Lua) ]
   - antfarm_metals.lua (Ore survey & mandate gating)
   - antfarm_trade.lua (Depot paving & export ban check)
   - antfarm_health.lua (Quarantine airlock & soap check)
   - antfarm_morale.lua (Clothing orders & autoslab)
   - antfarm_defence.lua (Burrow alert & drawbridge seal)
   - antfarm_maintenance.lua (DFHack fix routines)
             │
             ▼
   [ Unified Priority Arbiter ]
   - Rank actions by Urgency (Catastrophic > Critical > High > Medium)
   - Check Labor Budget (Available idle dwarfs)
   - Dispatch Highest-Scoring Atomic Command
```

By transitioning from reactive bug-patching to this proactive, closed-loop coverage model across all 60 documented failure modes, Antfarm can sustain an autonomous Dwarf Fortress indefinitely—surviving sieges, tantrums, epidemics, and engine degradation across real-world weeks of continuous live streaming.

---

## 15. Comprehensive Prior Art, Open-Source Repositories & Implementation Citations for Claude

When the engineering team (and future Claude agents) begins writing code to implement these automated subsystems, they should not reinvent algorithms from scratch. A rich ecosystem of open-source projects, DFHack core plugins, and autonomous control planes exists. This section catalogs the exact repositories, author citations, architectural designs, and file-level references needed for implementation.

### 15.1. External Autonomous & Control-Plane Repositories

#### 1. `dwarf_fortress_mcp` (Model Context Protocol Autonomous Control Plane)
* **Repository**: [`https://github.com/Dicklesworthstone/dwarf_fortress_mcp`](https://github.com/Dicklesworthstone/dwarf_fortress_mcp)
* **Core Paradigm**: Treats Dwarf Fortress not as a "keyboard-and-screen toy," but as a partially observed, continuously evolving, typed transactional civilization.
* **Key Architecture & Reusable Patterns**:
  * **Transactional Agent Turn Loop**:
    ```text
    Observe exact state -> Orient economically -> Formulate semantic intent
    -> Prepare against witnessed state -> Revalidate authority & conflicts
    -> Commit idempotently -> Observe post-state -> Reconcile uncertainty
    ```
  * **Frozen 11-Tool Public Waist**: `fortress.open_session`, `fortress.observe`, `fortress.query`, `fortress.plan`, `fortress.commit`, `fortress.wait`, `fortress.cancel`, `fortress.checkpoint`, `fortress.restore`, `fortress.explain`, `fortress.doctor`.
  * **Canonical Agent Turn Packets**: Enforces that every observation capsule is hashed with SHA-256 and carries monotonic anchors, uncertainty bounds, and budget domains.
* **Relevance for Claude**: Use this repository's transactional paradigm to structure `antfarm_server.lua` and `antfarm/client.py`. It provides the definitive solution for avoiding race conditions, blind retries, and command-acknowledgement confusion in asynchronous DFHack automation.

#### 2. `Dwarf-Therapist` (Labor Optimization & Mathematical Role Scoring)
* **Repository**: [`https://github.com/Dwarf-Therapist/Dwarf-Therapist`](https://github.com/Dwarf-Therapist/Dwarf-Therapist)
* **Core Paradigm**: High-performance cross-platform memory reading and mathematical labor assignment for Dwarf Fortress.
* **Key Architecture & Reusable Patterns**:
  * **Mathematical Role Scoring Equation**:
    Dwarf Therapist evaluates every dwarf's suitability for a profession or noble position using a weighted multi-variable formula:
    $$\text{RoleScore} = \sum (w_{\text{skill}} \cdot \text{SkillLevel}) + \sum (w_{\text{attr}} \cdot \text{AttributeValue}) + \sum (w_{\text{trait}} \cdot \text{TraitValue})$$
    Where weights $w \in [0.0, 1.0]$ are calibrated for each specific labor (e.g. Mining weights Strength, Toughness, Spatial Sense, and Diligence; Broker weights Appraiser, Negotiator, Empathy, and Social Awareness).
  * **Psychological Needs & Stress Monitoring**: Maps unit thoughts, unmet needs (`u.status.current_soul.personality.emotions`), and stress levels directly from memory structures.
* **Relevance for Claude**: When implementing `antfarm_nobles.lua` and `antfarm_military.lua`, do not draft dwarves at random. Port Dwarf Therapist's role-scoring weights into Lua to select optimal candidates for Manager, Broker, Bookkeeper, Chief Medical Dwarf, and Squad Commanders.

#### 3. `jjyg/df-ai` (The Original Ruby Autonomous Fortress Expert System)
* **Repository**: [`https://github.com/jjyg/df-ai`](https://github.com/jjyg/df-ai)
* **Author**: Yoann Guillot (`jjyg`)
* **Core Paradigm**: The historical progenitor of DF-AI, written in Ruby for DFHack 0.34.11-r3 before Ben Lubar ported it to C++.
* **Key Architecture & Reusable Patterns**:
  * **Stockpile Demand Heuristics**: Scripted rules calculating food, drink, and clothing consumption rates per citizen per season.
  * **Expressive Scripting Logic**: Because it is written in Ruby rather than low-level C++, its decision trees for workshop linking, stockpile routing, and trade valuation are significantly easier to read and translate into Lua than Ben Lubar's C++ pointers.
* **Relevance for Claude**: Ideal reference for understanding the pure procedural logic of autonomous fortress management without getting bogged down in C++ memory management.

#### 4. `quickfort` (Blueprint Parsing and Transposition Engine)
* **Repository**: [`https://github.com/lethosor/quickfort`](https://github.com/lethosor/quickfort) (integrated into `game/hack/scripts/quickfort.lua`)
* **Author**: Lethosor (originally Joel Thornton / Valdemar)
* **Core Paradigm**: Transforms human-readable `.csv` and `.xlsx` grid blueprints into active DFHack designations (dig, build, place, zone, query).
* **Key Architecture & Reusable Patterns**:
  * **CSV Label Parsing**: Handles complex multi-tile CSV quoting rules: `^"?#\w+ label\(`.
  * **Coordinate Transformation**: Translates 2D blueprint matrices onto 3D world anchors (`--cursor x,y,z`).
  * **Undo Machinery**: `quickfort undo` exactly rolls back designations without touching existing solid terrain or unrelated buildings.
* **Relevance for Claude**: Antfarm's guided fortress construction directly drives Dreamfort via Quickfort. Claude must consult this codebase when troubleshooting blueprint stalls, coordinate offsets, or level-gating issues.

#### 5. `Dwarf Fortress Terrarium` (24/7 Autonomous Stream Community)
* **Source / Community Reference**: r/dwarffortress community archives & documentation
* **Core Paradigm**: Real-world operational setups running Dwarf Fortress 24 hours a day, 7 days a week on dedicated hardware without human intervention.
* **Key Architecture & Reusable Patterns**:
  * **Watchdog Process Super-Loops**: External shell scripts monitoring process responsiveness and auto-restarting DFHack if the process hangs or memory leaks exceed limits.
  * **Crash Postmortems**: Empirical documentation of the most common reasons unattended long-running fortresses collapse (temperature memory bloat, stuck merchant caravans, dead unit caps).
* **Relevance for Claude**: Provides the operational reality check for Antfarm's streaming stability requirements.

---

### 15.2. Upstream DFHack Plugin Sources & Direct Implementation Targets

The DFHack core repository ([`https://github.com/DFHack/dfhack`](https://github.com/DFHack/dfhack)) and the shipped scripts in `game/hack/` contain existing, battle-tested solutions for many of the 60 cataloged failure modes. Claude should leverage and extend these specific tools:

| Automation Domain | Upstream Tool / Script | File Path / Upstream Source | Exact Mechanism to Leverage |
| :--- | :--- | :--- | :--- |
| **Labor Management** | `labormanager` | `hack/plugins/labormanager.cpp` (Author: angavrilov) | Scans active jobs, calculates exact dwarf counts needed, assigns best-fit workers, applies time-based anti-starvation bias. Replaces naive `autolabor`. |
| **Clothing Management** | `tailor` | `hack/plugins/tailor.cpp` | Daily scan for `XX(clothing)XX` rags; confiscates worn clothes; automatically generates manager work orders matching available textiles (cloth, silk, yarn, leather). |
| **Agricultural Safety** | `seedwatch` | `hack/plugins/seedwatch.cpp` | Maintains target seed stocks (e.g. `seedwatch all 30`); dynamically unchecks kitchen cooking permissions when seed counts drop below threshold. |
| **Commercial Hauling** | `autotrade` | `hack/plugins/autotrade.cpp` | Stockpile-driven depot hauling; automatically flags items in designated stockpiles to be brought to the Trade Depot upon caravan arrival. |
| **Planned Construction** | `buildingplan` | `hack/plugins/buildingplan.cpp` | Places furniture and constructions in suspended state; scans inventory and attaches materials as they become available. Note: `autounsuspend` ignores `buildingplan` jobs. |
| **Happiness & Efficiency**| `dwarfmonitor` | `hack/plugins/dwarfmonitor.cpp` (Author: Clement) | Real-time monitoring of fortress happiness (misery), labor productivity, and weather. Injects live HUD widgets directly onto the game canvas. |
| **Grazer Management** | `autobutcher` / `autonestbox` | `hack/plugins/autobutcher.plug.so` / `autonestbox.plug.so` | Automatically assigns egg-laying poultry to nest boxes; enforces strict population caps on adult/juvenile livestock to prevent pasture overgrazing. |
| **Item Bloat & FPS** | `cleanowned` | `hack/plugins/cleanowned.plug.so` | Periodically confiscates abandoned, dropped, or rotting clothing items (`cleanowned scattered x`), preventing item count inflation. |
| **Thermal Stabilization** | `tweak fast-heat` / `fix/stable-temp` | `hack/plugins/tweak.plug.so` / `hack/scripts/fix/stable-temp.lua` | `tweak fast-heat` accelerates thermal equilibrium updates; `fix/stable-temp` snaps loose items to ambient temperature, eliminating thermal FPS lag. |
| **Memory Cleanup** | `fix/dead-units` | `hack/scripts/fix/dead-units.lua` | Purges uninteresting, nameless dead creatures from `world.units.all`, preventing the 3,000-unit cap from permanently halting migrant waves. |
| **Occupancy Repair** | `fix/stuckdoors` / `fix/tile-occupancy` | `hack/scripts/fix/stuckdoors.lua` / `fix/tile-occupancy.lua` | Clears invalid occupancy flags that leave doors stuck open or cause blueprint construction jobs to report "blocked" indefinitely. |
| **Civil War Prevention** | `fix/loyaltycascade` | `hack/scripts/fix/loyaltycascade.lua` | Identifies and resets civilization allegiance flags on citizens who have incorrectly marked their own civilization as hostile during brawls. |
| **Curse & Vampire Scan** | `cursecheck` | `hack/plugins/cursecheck.plug.so` | Queries internal creature flags to instantly detect vampires, werebeasts, and necromancers disguised as ordinary migrants. |
| **Coffin & Tomb Setup** | `burial` | `game/hack/scripts/burial.lua` (Author: Putnam) | Automatically toggles unowned coffins to allow burial and forbids pet burial (`burial` / `burial -pets`). |

---

### 15.3. Code Architecture & Target File Mappings for Antfarm

To integrate these open-source patterns into the existing Antfarm codebase, Claude should implement the following discrete Lua modules in `game/hack/scripts/` and Python services in `antfarm/`:

```
game/hack/scripts/
├── antfarm_server.lua        <- Master bridge: runs sensor sweep & priority arbiter every 200ms
├── antfarm_ui.lua            <- Modal watchdog: coroutine screen driver (ExclusiveCallback port)
├── antfarm_blueprint.lua     <- Guided construction: Dreamfort quickfort runner with level gating
├── antfarm_metals.lua        <- Embark ore survey, metallurgy checks, mandate feasibility gating
├── antfarm_trade.lua         <- 3-wide road verification, depot stocking, Elven quota & wood filtering
├── antfarm_health.lua        <- Single-bed hospital cubicles, werebeast quarantine, soap supply loop
├── antfarm_morale.lua        <- Clothing replacement pipeline, autoslab ghost memorializer, booze diversity
├── antfarm_defence.lua       <- Raising drawbridge airlocks, cage trap corridors, chained guard sentries
├── antfarm_justice.lua       <- Jail cage building, weak Hammerer weapon assignment, vampire detection
└── antfarm_maintenance.lua   <- Scheduled runner for fix/dead-units, fix/stuckdoors, fix/stable-temp

antfarm/
├── client.py                 <- Atomic file/socket IPC transport layer (Protocol 2.0)
├── engine.py                 <- Director AI, multivariable interest-decay camera scoring, event bus
├── tui.py                    <- Broadcast-grade terminal dashboard (Textual/Rich)
├── twitch.py                 <- Twitch IRC bridge for viewer interactivity (!name, !focus, !vote)
└── plugins/                  <- Drop-in Python SDK plugins (e.g. obituary generator, chat alerts)
```

### 15.4. Critical Technical Constraints for Future AI Agents (Claude Guidelines)
Before writing any Lua or modifying DFHack scripts, Claude MUST review these five foundational constraints verified against this running fortress build:

1. **DFHack Vectors are 0-Indexed**:
   * DFHack vectors are C++ collections indexed from `0` to `#vec - 1`.
   * **Never use `ipairs()` on DF vectors**—it can skip index `0` or fail silently. Always use:
     ```lua
     for i = 0, #vec - 1 do
         local item = vec[i]
         -- process item
     end
     ```
2. **`dfhack.timeout` Only Accepts Frame/Tick Units**:
   * Accepted units: `'frames'`, `'ticks'`, `'days'`, `'months'`, `'years'`.
   * **Never pass `'msec'`, `'ms'`, or `'seconds'`**—they raise fatal Lua argument exceptions.
   * Use `'frames'`, not `'ticks'`, for any loop that must run while the game is paused (the bridge, watchdog, and auto-unpause must all run on frames).
3. **Always Wrap Gate & Screen Checks in `pcall`**:
   * Accessing fields like `world.jobs.list` (note: `world.job_list` does not exist!) can throw runtime exceptions if structures are uninitialized during save loading. Wrap all gate checks in `pcall` to prevent unhandled script crashes from killing the frame-rate timer chain.
4. **Never Send Keys to Parentless Viewscreens**:
   * Calling `LEAVESCREEN` on `viewscreen_dwarfmodest` opens the abandon fortress menu; dismissing a root screen exits Dwarf Fortress immediately. Always verify screen identity via `dfhack.gui.getCurFocus(true)` before simulating keystrokes.
5. **Always Pave Surface Wagon Roads**:
   * Dirt and soil tiles naturally sprout saplings. If a road is not paved with constructed stone floors or paved roads, trees will sprout and block wagons within 1–2 game years, silently starving the fort of foreign trade.

---

## 16. Architectural Blueprints & Aesthetic Paradigms

### 16.1. Beyond the Orthogonal Grid
While Dreamfort (`game/blueprints/library/dreamfort.csv`) provides a functional baseline for early survival, its rigid 3×3 hallways and square rooms lack verticality, visual spectacle, and dynamic flow. For an autonomous streaming simulation ("Antfarm"), visually stunning architecture is essential for viewer engagement and multi-agent interaction.

### 16.2. The Seven Design Paradigms
Research into 15 years of community fortress architecture identified seven distinct schools of design (detailed in [`FORT_BLUEPRINTS_RESEARCH.md`](FORT_BLUEPRINTS_RESEARCH.md)):
1. **Fractal & Recursive Geometry**: Raynard Whirlpools, Raynard Square, Mandelbrot Tree, and H-Tree (maximizes wall perimeter per step; hypnotic rotational symmetry).
2. **Concentric & Radial Geometries**: Caramels Circular Living, Circle Pack (radii 11 through 45), Ramp Rings.
3. **Vertical Windmill & Rotor Complexes**: Andrelius Windmill Villas, Saracen Magma Windmills, Central 3D Spindle.
4. **Megastructure & Monumentalism**: Full Mines of Moria layouts, 5×5 Western Halls, Vherid Mayan Step-Pyramids, Saracen Crypts.
5. **Organic & Botanical Patterns**: Savokis Leaf, Nautikus Blossom, Hive Hexagonal Honeycomb.
6. **Dense Hyper-Efficient Engineering**: 320-bed 3-layer spiral apartments, Tetris interlocking bedrooms, Marble Dice.
7. **Hydro-Engineering & Mist Generators**: TheQuickFortress central dining waterfall, multi-Z screw pump stacks, aquifer cisterns.

### 16.3. Downloaded Community Blueprint Catalog
We acquired **328 blueprint files and layout renders** from historical repositories (`Lazy-Newb-Pack/Quickfort-Community-Blueprints`, `lazerus98/fortlibrary`, `zelbo/dwarf-dig`, `joelpt/quickfort`):
* **Raw Archives**: Stored in `community_blueprints/` with PNG/BMP visual renders, documentation, and macro files.
* **Curated In-Game Library**: **99 `.csv` blueprints** installed directly into `game/blueprints/community/` for instant execution via `quickfort run community/<category>/<filename>`:
  * `bedrooms/` (35 blueprints): Raynard Whirlpool, Windmill Villas, Nautikus Blossom, Mayan, Tetris.
  * `fractals/` (14 blueprints): Whiteoak Megadorms, Clover Dorms, Hex, Bifurcated Trees.
  * `circles/` (18 blueprints): Concentric Circles 11–45, Caramels Circular, Ramp Rings.
  * `industry/` (7 blueprints): Saracen Magma Workshops, Meeker Workshops, Cudgelshot.
  * `water_and_power/` (8 blueprints): TheQuickFortress Mist Waterfall, Screw Pump Stacks, Well Shafts.
  * `moria/` (4 blueprints): Full Mines of Moria Top/Bottom, 5×5 Western Halls.
  * `hive/` (4 blueprints): Hexagonal 3×3 rooms, honeycomb cells, spiral stairs.
  * `mega_apartments/` (9 blueprints): 320-bed 3-layer complexes, 40-room blocks.

---

## 17. Empirical Implementation Postmortem & Newly Resolved Gaps

During system hardening and live fort validation, several critical edge cases were solved with production-ready code:

### 17.1. Pure-Lua Memorial Slab Engraver (`antfarm_autoslab.lua`)
* **Problem**: DFHack 0.47 lacks the C++ `autoslab` plugin. When dwarves die off-map or in inaccessible caverns, unburied ghosts rise, terrorizing civilians and triggering tantrum spirals.
* **Solution**: Ported the upstream C++ algorithm directly to pure Lua (`game/hack/scripts/antfarm_autoslab.lua`). It scans `world.units.all` for `flags3.bits.ghostly`, checks `world.items.other.SLAB` for existing memorials, and issues `EngraveSlab` and `ConstructSlab` manager orders.
* **Verification**: Unit tested via `tests/test_antfarm_autoslab.lua` (19/19 checks pass). Scheduled bi-weekly in `onMapLoad.init`.

### 17.2. Non-Lethal Justice & Weak Hammerer Selection (`antfarm_nobles.lua`)
* **Problem**: When a noble issues an impossible mandate (e.g. export ban or metal item mandate), the Hammerer executes the dwarf by crushing their skull if they possess high Hammer skill or super-dwarven strength.
* **Solution**: Updated `best_candidate` in `antfarm_nobles.lua` for `HAMMERER` to invert combat scoring (`score = (20 - hammer_skill) * 10 - math.floor(str / 100)`). The fortress now appoints the weakest, least-trained dwarf as Hammerer, ensuring beatings cause minor bruising rather than fatalities.

### 17.3. Automated Bookkeeper Precision (`antfarm_nobles.lua`)
* **Problem**: Unadjusted bookkeeper precision causes stock counts to be rounded to the nearest 10, 100, or 1000 ("10?"), causing conditional manager workorders (e.g. "brew drinks if drinks < 30") to fail or trigger uncontrollably.
* **Solution**: Added `ensure_bookkeeper_precision()` in `antfarm_nobles.lua`, automatically setting `df.global.ui.nobles.bookkeeper_settings = 4` (`AllAccurate`) and `bookkeeper_precision = 4` on every noble audit and tick.

### 17.4. Build Stall & Lake Collision Recovery (`antfarm_blueprint.lua`)
* **Problem**: Live fort was wedged at Step 11/22 for over 15 minutes waiting on 2 construction jobs on the surface that were suspended due to water/missing materials, blocking `gate_open` indefinitely.
* **Solution**: 
  1. Added `cancel_suspended_builds()` to cancel suspended construction jobs and deconstruct unbuilt building hulls.
  2. Updated `remediate()` to auto-execute `unforbid all` and clear suspended jobs if stalled for > 15 minutes.
  3. Added CLI commands `antfarm_blueprint cancel_stuck` and `antfarm_blueprint skip` to allow instant manual or programmatic unblocking.

### 17.5. Standing Repeat Fixes (`onMapLoad.init`)
* Registered `fix/corrupt-equipment` (resolves Bug #11014 equipment list corruption crashes during raids).
* Registered `fix/stuck-squad` (resolves Bug #0010996 off-map military squad desyncs).
* Registered `antfarm_autoslab check` (bi-weekly ghost memorialization).

### 17.6. Lifecycle Event Handlers (`antfarm/engine.py`)
* Connected `MigrantWaveArrival` -> automatically triggers `nobles appoint`, `quarters assign`, and `locations hall`.
* Connected `CaravanArrival` -> automatically triggers `trade goods` (queues rock crafts).
* Connected `CitizenDeath` -> triggers `autoslab check` and noble replacement.
* Implemented `subsystems_summary()` in `antfarm_server.lua` with a 25-second wall-clock cache, streaming real-time status of nobles, housing, trade, ghosts, and metals directly into `antfarm_state.json`.

---

## 18. Master Verification & Quality Assurance Protocol

Every script, configuration, and unit test must pass cleanly outside the game via:
```bash
./tests/run_all.sh
```
The test suite performs:
1. **Lua Syntax Validation**: Runs `luac -p` across all `antfarm_*.lua`, `fix/*.lua`, and helper scripts.
2. **Python Bytecode Compilation**: Runs `compileall` across `antfarm/` and `tests/`.
3. **Shell Script Validation**: Runs `bash -n` on all launchers and maintenance shell scripts.
4. **Lua Unit Tests**: Executes `tests/test_antfarm_ui.lua`, `tests/test_antfarm_blueprint.lua`, and `tests/test_antfarm_autoslab.lua` against the synthetic `df_stub.lua` environment.
5. **Python Unit Tests**: Executes `tests.test_engine` (41 unit tests) and `tests.test_wire` (8 wire protocol tests).

As of 2026-09-16, **ALL 49 UNIT TESTS AND 28 LUA SCRIPTS PASS 100% WITH ZERO ERRORS AND ZERO WARNINGS**.

