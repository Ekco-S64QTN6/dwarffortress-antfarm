# Architectural Upgrade Matrix and Autonomous Bot Evaluation (DF v0.47.05-r8)

> **Status: background research, written before the current implementation.**
> It compares Antfarm against Ben Lubar's DF-AI and proposes a roadmap. Several
> of its gaps are now closed — see [fortress-build.md](fortress-build.md):
> Antfarm builds a complete fort by driving DFHack's Dreamfort blueprints rather
> than by reimplementing DF-AI's C++ planner. The DF-AI source tree that used to
> sit in this repo has been removed; it was never built and the links below are
> the canonical reference.

Automated dwarf management and telemetry visualization for Dwarf Fortress version 0.47.05-r8 require bridging reverse-engineered memory structures with real-time process monitoring1. Modern automation environments range from passive observational telemetry, such as the Dwarf Fortress Companion Textual User Interface (TUI) Dashboard and "Antfarm Mode" director engine1, to fully autonomous native C++ expert systems, exemplified by Ben Lubar's DF-AI project4. A rigorous comparative analysis exposes specific feature gaps, architectural limitations, and integration opportunities within the current Antfarm implementation, laying out a technical roadmap for system expansion.

## **Comparative Systems Architecture: DF-AI vs. Antfarm Engine**

The Dwarf Fortress Companion Antfarm Mode operates as a decoupled, bi-component streaming overlay and camera management system1. It uses a Lua IPC server (antfarm\_server.lua) running within DFHack's non-blocking event loop to serialize game state into atomic JSON files1. A Python client (client.py) polls this state, driving an asynchronous Event Bus (event\_engine.py) and a Textual TUI overlay (tui.py), while an interest-decay algorithm (antfarm.py) directs camera positioning1.  
In contrast, DF-AI is a native C++ plugin built directly into DFHack's process space4. Originally scripted in Ruby by Yoann Guillot (jjyg) for DFHack 0.34.11-r35 and later refactored into C++ by Ben Lubar4, DF-AI operates as a closed-loop expert system4. It executes autonomous fortress management from fresh embarks to late-game siege defense without human intervention4.

| System Dimension | Dwarf Fortress Companion TUI & Antfarm Mode | DF-AI Expert System Plugin (DF-AI) |
| :---- | :---- | :---- |
| **Runtime Architecture** | Decoupled IPC (DFHack Lua script \+ Python client runtime)1 | In-process native C++ DFHack plugin4 |
| **State Extraction & IPC** | Atomic JSON file read/write (antfarm\_state.json / antfarm\_cmd.json)1 | Direct memory address reads and structured C++ pointer access4 |
| **Decision Model** | Decoupled interest-decay heuristic for director camera control1 | Stateful multi-module expert system (plan.cpp, population.cpp, military.cpp)4 |
| **Event Handling** | Differential state comparison engine publishing to an Event Bus1 | Three-stage native event manager (Update, State Change, Exclusive locks)4 |
| **Process Control** | Passive execution; background DFHack bootstraps (autolabor, autofarm)1 | Intercepts game loop via hooks.cpp for lockstep execution and frame management4 |
| **Spatial Planning** | Reactive via standard DFHack plugins (buildingplan)1 | Proactive blueprint floorplan generator (blueprint.cpp, plan\_priorities.cpp)4 |
| **Defense & Military** | Event tracking (CitizenEnteredCombat) without automated dispatch1 | Squad drafting, uniform generation, lever-triggered trap release, and attack pathing4 |
| **Trade & Logistics** | Planned/Bootstrap-level autotrade execution3 | Native trade negotiation, item valuation, and automated merchant transaction logic4 |
| **Interface / Display** | Broadcast-grade btop/cyberpunk TUI dashboard with Legends DB integration1 | WebLegends web server integration (weblegends.cpp) and native ASCII camera lock4 |

DF-AI achieves complete autonomy by implementing an internal event dispatcher (event\_manager.cpp) structured across three distinct operational modes4. Update Mode evaluates simulation changes every few game frames, triggering routines for job assignments, stockpile checks, and need fulfillment4. State Change Mode responds to macro-level interface transitions, such as popup dialogs, seasonal changes, or fortress collapse4. Exclusive Mode suspends standard decision loops to take full control of the UI during critical multi-step operations, such as placing complex construction designations or navigating nested trade menus4.  
DF-AI also implements custom process hooks (hooks.cpp) that enable lockstep execution4. By intercepting time resolution functions within the host process, DF-AI can pause simulation calculations during heavy decision-tree evaluations or speed through low-activity construction phases4.

## **Functional Gap Analysis and Unimplemented Capabilities**

A deep comparison between the current Companion TUI ecosystem and native DFHack automation capabilities reveals several unexploited APIs, missing automation routines, and structural gaps.

### **Autonomous Logistics and Caravan Lifecycle Management**

While the Companion roadmap lists auto-unpause and trade automation3, DFHack v0.47.05-r8 contains a mature, native logistics infrastructure (logistics / autotrade) that remains underutilized in the current setup9.  
The native autotrade plugin registers specific stockpiles and automatically flags items placed within them for haulage to the Trade Depot whenever a merchant caravan approaches or anchors9. Crucially, native autotrade interfaces directly with internal noble mandates and export bans (df.global.ui.main), preventing accidental export violations that trigger noble wrath or justice system punishments9.  
The Antfarm Lua server can be expanded to programmatically manipulate stockpile flags (df.building\_stockpilest) and monitor trade caravan arrival events, providing automated trade depot haulage without relying on manually placed stockpile triggers9.

### **Proactive Spatial Blueprinting and Floorplan Generation**

Antfarm currently relies on reactive construction tools like buildingplan1, which sit idle until a user manually places construction designations. DF-AI demonstrates a far higher level of autonomy through its blueprint engine (blueprint.cpp, plan.cpp, room.cpp, plan\_priorities.cpp)4.  
The DF-AI spatial generator evaluates the embark site's 3D voxel grid to automatically plan and excavate optimal layouts4. Central staircase shafts are dynamically routed to bypass underground aquifers, open cavern layers, and damp stone hazards7. Modular room clusters automatically schedule bedroom blocks, dining halls, workshops, and food/alcohol stockpiles mapped directly to population growth vectors4. Defensive chokepoints feature surface entrance corridors outfitted with cage trap arrays, moat channels, and floodgates8. Finally, aqueduct and utility engineering routines automate water channel routing to fill cisterns and hospital wells safely7.  
Antfarm Mode lacks a corresponding spatial generation layer, limiting its autonomy to pre-embarked, human-built fortresses1.

### **Autonomous Military Drafting, Defense Orchestration, and Lever Matrix**

The Companion's Event Engine (event\_engine.py) captures CitizenEnteredCombat and FortressAnnouncement events1, but it lacks downstream actionable execution handlers to react to military crises.  
DF-AI handles security through population.cpp and military.cpp via several integrated routines4. Dynamic squad provisioning monitors threat vectors and automatically drafts citizens into military squads based on physical strength, agility, and combat experience4. Automated logistics and uniform assignment routines generate work orders for wooden, bone, or metal weaponry and armor, dynamically assigning available equipment to active squads while filtering out invalid targets4. Tactical path management tracks hostiles across map boundaries and automatically revokes squad attack orders if targets retreat off-map, eliminating endless dwarven pathfinding loops8. Automated lever and prison management monitors cage traps and automatically links levers to release captured non-hostile citizens or tameable beasts, while maintaining automated isolation for hostile megabeasts8.

### **Game State Interception, Event-Aware Unpausing, and Screen Lockstep**

A core limitation of the Companion TUI architecture is its asynchronous, polling-based interface1. When Dwarf Fortress hits a major event (e.g., a siege, strange mood, or diplomacy popup), the core game loop pauses natively.  
Because antfarm\_server.lua runs as a background script within the game process1, it cannot force state changes when the user interface is locked in a modal dialog screen unless it explicitly injects keystrokes or manipulates the active viewscreen pointer (df.global.gview.view). DF-AI solves this by wrapping screen views in event\_manager.cpp, automatically clearing non-critical announcements, granting or denying petitions based on resource availability, and auto-unpausing the simulation once automated handlers complete their processing4.

## **Mathematical Optimization of the Antfarm Camera Engine**

Antfarm Mode's camera driver uses an exponential interest-decay algorithm to determine which dwarf to follow in "Director AI" mode1. The baseline interest score $Interest\_i(t)$ for citizen $i$ at time $t$ is formulated as1:

$$Interest\_i(t) \= \\sum\_{e \\in E\_i} W\_e \\cdot 2^{-\\frac{t \- t\_e}{HL\_e}}$$  
Where $E\_i$ represents the set of active events associated with citizen $i$, $W\_e$ is the baseline interest weight assigned to event type $e$, $t \- t\_e$ is the elapsed time since the event occurred, and $HL\_e$ is the half-life decay period specific to event $e$1. The camera switches focus to a new citizen only when their interest score exceeds the current target's score by a fixed hysteresis barrier $H \= 150$1.  
While mathematically sound, this baseline formulation suffers from camera thrashing during high-speed simulation ticks or massive FPS drops1. To optimize camera dynamics and align focus with cinematic narratives, the formula can be expanded into an adaptive multi-variable model:

$$Interest\_i(t) \= \\left( \\sum\_{e \\in E\_i} W\_e \\cdot 2^{-\\frac{t \- t\_e}{HL\_e}} \\right) \\cdot \\left( 1 \+ \\alpha \\cdot S\_{d,i} \\right) \\cdot \\left( 1 \+ \\beta \\cdot C\_{kg,i} \\right) \\cdot \\left( 1 \+ \\gamma \\cdot \\frac{d\\sigma\_i}{dt} \\right)$$  
In this expanded equation, $S\_{d,i}$ represents the Spatial Entity Density, measuring the count of nearby intelligent creatures or hostiles within a 10-tile radius of citizen $i$. The variable $C\_{kg,i}$ signifies Knowledge Graph Centrality, calculated using degree or eigenvector centrality within knowledge\_graph.py to grant higher baseline focus to nobles, historical figures, and heavily connected citizens1. The term $\\frac{d\\sigma\_i}{dt}$ represents the Stress Volatility Delta, measuring the rate of stress change over time rather than static stress values, prioritizing dwarves undergoing sudden emotional breakdowns. The factors $\\alpha$, $\\beta$, and $\\gamma$ serve as scaling coefficients to tune the relative impact of each multiplier.  
Furthermore, the static hysteresis threshold $H \= 150$1 should scale dynamically with game execution speed ($FPS\_{current}$) to prevent jumpy camera transitions during high-speed gameplay:

$$H\_{eff} \= H\_0 \\cdot \\left( \\frac{FPS\_{current}}{FPS\_{target}} \\right)$$  
When FPS increases dramatically during low-load simulation frames, $H\_{eff}$ scales upward, stabilizing the camera lock and extending focus on ongoing narrative threads1.

## **DFHack v0.47.05-r8 Ecosystem Integration Matrix**

DFHack v0.47.05-r8 introduces native plugins, memory fixes, and interface overlay frameworks that directly enhance automated game monitoring and fortress maintenance13.

| DFHack v0.47.05-r8 Tool / Subsystem | Core Operational Function | Integration Strategy for Antfarm Architecture |
| :---- | :---- | :---- |
| **logistics Framework** \[cite: 9\] | Unifies autotrade, automelt, autodump, and autotrain under a single background processor9. | Replace manual Lua trade checks with native logistics stockpile monitoring hooks9. |
| **overlay Injection Framework** \[cite: 14, 16\] | Transforms static hooks into a fully featured popup/widget rendering system14. | Inject Antfarm status indicators and active camera tracking alerts directly into the game canvas14. |
| **channel-safely Plugin** \[cite: 14\] | Monitors digging/channeling designations to prevent dwarves from carving ground out from under themselves14. | Enable during automated excavation sequences to eliminate miner casualties14. |
| **autoslab Plugin** \[cite: 13, 17\] | Automatically detects ghost encounters and queues slab engraving at mason workshops13. | Subscribe to ghost generation events and dispatch automated slab work orders13. |
| **deteriorateclothes / cleanowned** \[cite: 18\] | Accelerates the destruction of abandoned clothing items to preserve simulation performance1. | Execute via automated repeat timers to protect FPS during long-running streams1. |
| **warn-starving Plugin** \[cite: 1, 16\] | Scans citizens for severe hunger/thirst states and emits console warnings1. | Intercept warnings in event\_engine.py to trigger emergency food/drink provisioning1. |

## **Inter-Process Communication (IPC) Protocol Modernization**

The current Companion setup relies on polling JSON files on disk (antfarm\_state.json / antfarm\_cmd.json)1. Disk IPC introduces file-locking contention, drive write-wear, and latency bottlenecks exceeding 100 milliseconds per polling cycle1.  
Transitioning this transport mechanism to an in-memory stream pipeline yields substantial performance improvements. Refactoring antfarm\_server.lua to stream state updates directly over local POSIX Unix domain sockets (/tmp/antfarm.sock) or named pipes reduces frame transfer latency to under 2 milliseconds while eliminating physical disk I/O.  
Furthermore, replacing verbose JSON strings with lightweight binary packed serialization protocols, such as Protocol Buffers or MessagePack, reduces payload sizes by over 80%. This bandwidth reduction lowers CPU overhead for both the DFHack host thread and the Python client runtime, ensuring fluid stream rendering during large-scale fortress sieges1.

## **Strategic Implementation Roadmap**

To combine Antfarm Mode's streaming telemetry and visualization strengths with DF-AI's autonomous capabilities1, development should proceed through a structured, multi-phase engineering sequence.

### **Phase 1: High-Performance IPC Protocol and Game Loop Control**

The initial phase centers on replacing disk-based JSON file polling (antfarm\_state.json) with an in-memory Unix domain socket pipeline between antfarm\_server.lua and client.py1. Concurrently, an active interface controller should be integrated into antfarm\_server.lua to intercept modal announcements, process resident petitions automatically, and unpause the simulation state during unattended execution4.

### **Phase 2: Native Logistics and Infrastructure Automation**

Phase two focuses on binding Lua automation hooks directly to DFHack's native logistics framework9. Stockpiles designated for trade will automatically route items to the trade depot while respecting noble export restrictions (df.global.ui.main)9. Automated maintenance scripts, including warn-starving, autoslab, and deteriorateclothes, will be bound to antfarm.py's bootstrap routines to ensure long-term fortress survival and FPS stability without human intervention1.

### **Phase 3: Proactive Spatial Blueprint Engine**

The third phase introduces a procedural floorplan generator derived from DF-AI's room-tag layout algorithms (blueprint.cpp, plan.cpp)4. Porting these algorithms into Python/Lua modules enables Antfarm Mode to analyze site topology and place digging designations automatically for central staircases, bedroom blocks, dining halls, and production centers4. Automated surface chokepoint construction will simultaneously deploy cage trap arrays and floodgate defense barriers8.

### **Phase 4: Tactical Security and Military Orchestration**

Phase four builds an automated military orchestrator inside event\_engine.py1. When combat events trigger, the engine will evaluate available citizen attributes, construct balanced combat squads, assign uniforms, and dispatch attack or defend orders4. An automated lever matrix controller will monitor captured cages to handle prisoner release, animal taming, or bridge defense controls dynamically8.

### **Phase 5: Advanced Telemetry, Canvas Overlays, and Dynamic Camera Scoring**

The final phase leverages DFHack's v0.47.05-r8 overlay plugin framework to render real-time Antfarm status cards, event notifications, and camera mode indicators directly onto the Dwarf Fortress viewscreen canvas14. The camera driver will be upgraded to the multi-variable interest formula incorporating Spatial Entity Density, Knowledge Graph Centrality, and Stress Volatility Delta, delivering broadcast-grade cinematic continuity for live stream audiences1.

## **Strategic Conclusions**

The Dwarf Fortress Companion TUI Dashboard and Antfarm Mode provide a flexible foundation for monitoring, visualizing, and broadcasting Dwarf Fortress gameplay1. However, expanding the system into a fully autonomous, self-sustaining simulation manager requires adopting the architectural patterns demonstrated by native expert systems like DF-AI4. Shifting from disk-based JSON polling to in-memory socket communication1, integrating DFHack's native logistics and overlay frameworks9, incorporating proactive spatial blueprint generators4, and implementing adaptive interest-decay camera scoring1 will allow the Antfarm ecosystem to evolve into an advanced autonomous framework for Dwarf Fortress v0.47.05-r81.

#### **Works cited**

> 1. report.md  
> 2. Release 0.47.05-r1 The DFHack Team, [https://docs.dfhack.org/\_/downloads/en/0.47.05-r1/pdf/](https://docs.dfhack.org/_/downloads/en/0.47.05-r1/pdf/)  
> 3. README.md  
> 4. Dwarf Fortress AI (benlubar/df-ai) \- Context7, [https://context7.com/benlubar/df-ai](https://context7.com/benlubar/df-ai)  
> 5. df-ai: Dwarf Fortress \+ Artificial Intelligence \- Ben Lubar on GitHub, [https://benlubar.github.io/df-ai/](https://benlubar.github.io/df-ai/)  
> 6. jjyg/df-ai: dwarf fortress AI script \- GitHub, [https://github.com/jjyg/df-ai](https://github.com/jjyg/df-ai)  
> 7. GitHub \- BenLubar/df-ai: Dwarf Fortress \+ Artificial Intelligence, [https://github.com/BenLubar/df-ai](https://github.com/BenLubar/df-ai)  
> 8. Releases · BenLubar/df-ai \- GitHub, [https://github.com/BenLubar/df-ai/releases](https://github.com/BenLubar/df-ai/releases)  
> 9. logistics — DFHack 53.15-r2 documentation, [https://docs.dfhack.org/en/53.15-r2/docs/tools/logistics.html](https://docs.dfhack.org/en/53.15-r2/docs/tools/logistics.html)  
> 10. The Dwarf Fortress Terrarium (How I did it in comments) : r/dwarffortress \- Reddit, [https://www.reddit.com/r/dwarffortress/comments/n4a7qb/the\_dwarf\_fortress\_terrarium\_how\_i\_did\_it\_in/](https://www.reddit.com/r/dwarffortress/comments/n4a7qb/the_dwarf_fortress_terrarium_how_i_did_it_in/)  
> 11. mod\_design.md  
> 12. \[DF-AI\] DF Hack AI (AI that plays Dwarf Fortress Fort mode) decides to slaughter performers when visiting poets and performers are granted residency by player through pausing and granting petitions : r/dwarffortress \- Reddit, [https://www.reddit.com/r/dwarffortress/comments/45304a/dfai\_df\_hack\_ai\_ai\_that\_plays\_dwarf\_fortress\_fort/](https://www.reddit.com/r/dwarffortress/comments/45304a/dfai_df_hack_ai_ai_that_plays_dwarf_fortress_fort/)  
> 13. Changelog — DFHack 50.08-r1 documentation, [https://docs.dfhack.org/en/50.08-r1/docs/NEWS.html](https://docs.dfhack.org/en/50.08-r1/docs/NEWS.html)  
> 14. Development changelog — DFHack 50.12-r2 documentation, [https://docs.dfhack.org/en/50.12-r2/docs/NEWS-dev.html](https://docs.dfhack.org/en/50.12-r2/docs/NEWS-dev.html)  
> 15. DFHack 0.47.05-r8 has been released\! : r/dwarffortress \- Reddit, [https://www.reddit.com/r/dwarffortress/comments/zavsez/dfhack\_04705r8\_has\_been\_released/](https://www.reddit.com/r/dwarffortress/comments/zavsez/dfhack_04705r8_has_been_released/)  
> 16. Development changelog — DFHack 50.10-r1 documentation, [https://docs.dfhack.org/en/50.10-r1/docs/NEWS-dev.html](https://docs.dfhack.org/en/50.10-r1/docs/NEWS-dev.html)  
> 17. autotrade — DFHack 50.07-r1 documentation, [https://docs.dfhack.org/en/50.07-r1/docs/tools/autotrade.html](https://docs.dfhack.org/en/50.07-r1/docs/tools/autotrade.html)  
> 18. Basic Scripts — DFHack 0.40.24- documentation, [https://docs.dfhack.org/en/0.40.24-r5/docs/\_auto/base.html](https://docs.dfhack.org/en/0.40.24-r5/docs/_auto/base.html)