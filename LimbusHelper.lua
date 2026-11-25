--[[
    LimbusHelper
    Tracks treasure chest openings in Apollyon and Temenos (Limbus).
    Monitors whether each of the 4 zone sectors yields the standard reward
    (3,000) or the bonus reward (5,000).

    Apollyon sector detection (nearest-chest by 3-D distance):
      NW (-211,  542,  0)
      NE ( 214,  542,  0)
      SW (-109, -429,  0)
      SE ( 112, -430,  0)

    Temenos sector detection (nearest-chest by 3-D distance):
      N  (-598,  457,  84)
      W  (-596,  177,   4)
      E  (-596, -102,  84)
      C  (-281, -423, -162)

    Use //lh pos in-game to verify that your sector reads correctly.
    Use //lh sector <sector> [3000|5000] to log a chest manually.
    Use //lh debug to capture all incoming text lines for troubleshooting.
]]

_addon.name     = 'LimbusHelper'
_addon.author   = 'Kaius @ Bahamut, Linktri @ Asura'
_addon.version  = '1.06'
_addon.commands = {'limbushelper', 'lh'}

config = require('config')
texts  = require('texts')
require('logger')
require('sets')
require('coroutine')

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------
local APOLLYON = 38
local TEMENOS  = 37

local zone_name = {
    [APOLLYON] = 'Apollyon',
    [TEMENOS]  = 'Temenos',
}

-- Prefix used for this zone's keys in the state file
local zone_key = {
    [APOLLYON] = 'apollyon',
    [TEMENOS]  = 'temenos',
}

-- Per-zone ordered sector lists (order controls display)
local zone_sectors = {
    [APOLLYON] = {'NW', 'SW', 'NE', 'SE'},
    [TEMENOS]  = {'N', 'W', 'E', 'C'},
}

-- Known chest positions (3-D nearest-neighbour detection)
local zone_chests = {
    [APOLLYON] = {
        NW = {x = -211, y =  542, z = 0},
        NE = {x =  214, y =  542, z = 0},
        SW = {x = -109, y = -429, z = 0},
        SE = {x =  112, y = -430, z = 0},
    },
    [TEMENOS] = {
        N = {x = -598, y =  457, z =  84},
        W = {x = -596, y =  177, z =   4},
        E = {x = -596, y = -102, z =  84},
        C = {x = -281, y = -423, z = -162},
    },
}

local STANDARD_AMT    = 3000
local BONUS_AMT       = 5000
local CHEST_DIST      = 20   -- yalms; must be within this range to count as a chest open
local RECORD_COOLDOWN = 10   -- seconds between automatic chest recordings (debounce)
local RESET_DELAY     = 5    -- seconds after a bonus before tracking resets

-- Player-typed chat modes. Units messages arriving in these modes are ignored
-- so that someone typing "Acquired Temenos Units: 5000" can't log a chest.
local CHAT_MODES = S{1, 2, 4, 5, 6, 7, 9, 10, 11, 12, 13, 14, 15, 212, 213, 214}

-- ---------------------------------------------------------------------------
-- Config
-- Display settings are global (data/settings.xml). The overlay can be dragged;
-- its new position is saved automatically.
-- Sector state is per-character (data/state_CharName.xml) so that
-- simultaneous Windower instances never write to the same file.
-- ---------------------------------------------------------------------------
local display_defaults = T{
    display = T{
        pos  = T{x = 8, y = 8},
        bg   = T{alpha = 200},
        text = T{size = 11, red = 255, green = 255, blue = 255},
    },
}

settings = config.load(display_defaults)

-- Migrate pre-1.06 flat display keys into the texts-style table
if settings.pos_x then
    settings.display.pos.x    = settings.pos_x
    settings.display.pos.y    = settings.pos_y or settings.display.pos.y
    settings.display.text.size = settings.font_size or settings.display.text.size
    settings.display.bg.alpha = settings.bg_alpha or settings.display.bg.alpha
    settings.pos_x, settings.pos_y, settings.font_size, settings.bg_alpha = nil, nil, nil, nil
    settings:save('all')
end

-- Each sector key stores true when opened; <zone>_bonus stores the sector that
-- gave the bonus ('none' when there isn't one) so an interrupted auto-reset
-- can be finished after a reload or crash.
local state_defaults = T{}
for zone_id, list in pairs(zone_sectors) do
    for _, s in ipairs(list) do
        state_defaults[zone_key[zone_id]..'_'..s] = false
    end
    state_defaults[zone_key[zone_id]..'_bonus'] = 'none'
end

state = nil

local function init_player_state()
    if state then return end  -- already initialized
    local player = windower.ffxi.get_player()
    if not player then return end  -- defer; login event will handle it
    state = config.load('data/state_'..player.name..'.xml', state_defaults)
end

local disp = texts.new('', settings.display, settings)

-- ---------------------------------------------------------------------------
-- Runtime state
-- ---------------------------------------------------------------------------
-- tracking[zone_id][sector] = nil | 'std' | 'bonus'
local tracking = {
    [APOLLYON] = {},
    [TEMENOS]  = {},
}

local active_zone      = nil
local debug_mode       = false
local manual_show      = false  -- true when user forces display outside a tracked zone
local pending_reset    = {}     -- pending_reset[zone_id] = token of a live auto-reset countdown
local reset_token      = 0
local last_record_time = 0

-- ---------------------------------------------------------------------------
-- Persistence helpers
-- ---------------------------------------------------------------------------
local function save_state()
    if not state then return end  -- not yet initialized (player not logged in)
    for zone_id, list in pairs(zone_sectors) do
        local key   = zone_key[zone_id]
        local bonus = 'none'
        for _, s in ipairs(list) do
            local st = tracking[zone_id][s]
            state[key..'_'..s] = st ~= nil
            if st == 'bonus' then bonus = s end
        end
        state[key..'_bonus'] = bonus
    end
    state:save()
end

local function load_state()
    if not state then return end
    for zone_id, list in pairs(zone_sectors) do
        local key   = zone_key[zone_id]
        local bonus = state[key..'_bonus']
        tracking[zone_id] = {}
        for _, s in ipairs(list) do
            if bonus == s then
                tracking[zone_id][s] = 'bonus'
            elseif state[key..'_'..s] == true then
                tracking[zone_id][s] = 'std'
            end
        end
    end
end

local function zone_has_bonus(zone_id)
    for _, s in ipairs(zone_sectors[zone_id]) do
        if tracking[zone_id][s] == 'bonus' then return s end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Colour helpers
-- ---------------------------------------------------------------------------
local C_STD   = '\\cs(80,255,128)'  -- green      : opened (standard)
local C_BONUS = '\\cs(255,215,0)'   -- gold       : bonus chest
local C_UNK   = '\\cs(255,80,80)'   -- red        : not yet opened
local C_HEAD  = '\\cs(200,220,255)' -- light blue : header
local C_END   = '\\cr'

-- ---------------------------------------------------------------------------
-- Sector detection
-- ---------------------------------------------------------------------------
-- Returns the nearest chest's sector and the squared distance to it
local function nearest_chest(zone_id, x, y, z)
    local best, best_d2 = nil, math.huge
    for sector, pos in pairs(zone_chests[zone_id]) do
        local dx, dy, dz = x - pos.x, y - pos.y, z - pos.z
        local d2 = dx*dx + dy*dy + dz*dz
        if d2 < best_d2 then best_d2 = d2 ; best = sector end
    end
    return best, best_d2
end

local function detect_sector()
    if not active_zone then return nil end
    local me = windower.ffxi.get_mob_by_target('me')
    if not me then return nil end
    return (nearest_chest(active_zone, me.x, me.y, me.z))
end

-- ---------------------------------------------------------------------------
-- Sector / zone lookups
-- ---------------------------------------------------------------------------
local function valid_sector(s, zone_id)
    zone_id = zone_id or active_zone
    if not zone_id then return false end
    for _, v in ipairs(zone_sectors[zone_id]) do
        if v == s then return true end
    end
    return false
end

-- Returns the zone_id that owns sector s, or nil if not found
local function zone_for_sector(s)
    for zone_id, list in pairs(zone_sectors) do
        for _, v in ipairs(list) do
            if v == s then return zone_id end
        end
    end
    return nil
end

local function zone_by_name(name)
    name = (name or ''):lower()
    for zone_id, key in pairs(zone_key) do
        if key == name or key:sub(1, 1) == name then return zone_id end
    end
    return nil
end

local function sector_list_str(zone_id)
    return table.concat(zone_sectors[zone_id or active_zone], '|')
end

-- ---------------------------------------------------------------------------
-- Refresh the on-screen display
-- ---------------------------------------------------------------------------
local function render_zone_rows(zone_id, lines)
    local data = tracking[zone_id]
    lines[#lines+1] = C_HEAD..'=== '..zone_name[zone_id]..' ==='..C_END
    for _, s in ipairs(zone_sectors[zone_id]) do
        local st = data[s]
        local col, tag
        if st == 'bonus' then
            col = C_BONUS ; tag = 'BONUS!'
        elseif st == 'std' then
            col = C_STD   ; tag = 'Opened'
        else
            col = C_UNK   ; tag = 'Unopened'
        end
        local label      = s..string.rep(' ', 3 - #s)
        local padded_tag = tag..string.rep(' ', 8 - #tag)
        lines[#lines+1] = label..': '..col..padded_tag..C_END
    end
end

local function refresh_display()
    if not active_zone and not manual_show then
        disp:hide()
        return
    end

    local lines = {}

    if active_zone then
        render_zone_rows(active_zone, lines)
        if zone_has_bonus(active_zone) then
            lines[#lines+1] = ''
            if pending_reset[active_zone] then
                lines[#lines+1] = C_BONUS..'Bonus found!  Resetting in '..RESET_DELAY..'s...'..C_END
            else
                lines[#lines+1] = C_BONUS..'Bonus found!  Use //lh reset.'..C_END
            end
        end
    else
        -- Manual show outside tracked zones: display both
        render_zone_rows(APOLLYON, lines)
        lines[#lines+1] = ''
        render_zone_rows(TEMENOS, lines)
    end

    disp:text(table.concat(lines, '\n'))
    disp:show()
end

-- ---------------------------------------------------------------------------
-- Reset tracking for a zone
-- ---------------------------------------------------------------------------
local function reset_zone(zone_id)
    tracking[zone_id]      = {}
    pending_reset[zone_id] = nil  -- cancels any live countdown for this zone
    save_state()
    refresh_display()
end

-- Starts the post-bonus countdown. A token makes sure a stale countdown
-- (cancelled by a manual reset or superseded by a newer one) does nothing.
local function start_auto_reset(zone_id)
    reset_token = reset_token + 1
    local token = reset_token
    pending_reset[zone_id] = token
    coroutine.schedule(function()
        if pending_reset[zone_id] ~= token then return end
        reset_zone(zone_id)
        windower.add_to_chat(167, 'LimbusHelper: '..zone_name[zone_id]..' tracking reset. Find the next bonus!')
    end, RESET_DELAY)
end

-- ---------------------------------------------------------------------------
-- Record a chest result
-- ---------------------------------------------------------------------------
local function record_chest(zone_id, sector, amount)
    local is_bonus = (amount == BONUS_AMT)
    tracking[zone_id][sector] = is_bonus and 'bonus' or 'std'
    save_state()

    if is_bonus then
        windower.add_to_chat(158,
            'LimbusHelper: BONUS ('..amount..') at '
            ..zone_name[zone_id]..' '..sector
            ..'!  Tracking resets in '..RESET_DELAY..' seconds...')
        start_auto_reset(zone_id)
    else
        windower.add_to_chat(167,
            'LimbusHelper: Standard ('..amount..') at '
            ..zone_name[zone_id]..' '..sector..'.')
    end

    refresh_display()
end

-- Called whenever we arrive in (or load inside) a tracked zone
local function enter_zone(zone_id)
    active_zone = zone_id
    manual_show = false  -- active zone drives display
    load_state()
    -- A bonus with no live countdown means the reset was interrupted
    -- (reload, crash, zoning out mid-countdown); finish it now.
    local s = zone_has_bonus(zone_id)
    if s and not pending_reset[zone_id] then
        windower.add_to_chat(167, 'LimbusHelper: Pending bonus at '..zone_name[zone_id]..' '..s..' found; resetting shortly.')
        start_auto_reset(zone_id)
    end
    refresh_display()
end

local function init_current_zone()
    init_player_state()
    if not state then return end  -- player not yet available; login event will handle it
    local zone = windower.ffxi.get_info().zone
    if zone_name[zone] then
        enter_zone(zone)
    else
        active_zone = nil
        load_state()
        refresh_display()
    end
end

-- ---------------------------------------------------------------------------
-- Incoming text: detect chest reward messages
-- ---------------------------------------------------------------------------
windower.register_event('incoming text', function(original, modified, mode)
    if not active_zone then return end

    if debug_mode then
        log('[DBG mode='..mode..'] '..original)
    end

    if CHAT_MODES:contains(mode) then return end

    -- Match "Acquired Temenos Units: 3000" / "Acquired Apollyon Units: 5000"
    local zone_str, amt_str = original:match('Acquired (%a+) Units: (%d+)')
    if not zone_str then return end

    local amount = tonumber(amt_str)
    if amount ~= STANDARD_AMT and amount ~= BONUS_AMT then return end

    -- Sanity-check: message zone matches active zone
    if zone_str ~= zone_name[active_zone] then
        windower.add_to_chat(8, 'LimbusHelper: Units message zone ('..zone_str..') does not match active zone - ignored.')
        return
    end

    local me = windower.ffxi.get_mob_by_target('me')
    if not me then
        windower.add_to_chat(8,
            'LimbusHelper: Chest reward ('..amount
            ..') detected but could not read position. '
            ..'Use //lh sector <'..sector_list_str()
            ..'> '..amount..' to log manually.')
        return
    end

    -- Ignore if not near a known chest (e.g. ??? giving 3000)
    local sector, d2 = nearest_chest(active_zone, me.x, me.y, me.z)
    if d2 > CHEST_DIST * CHEST_DIST then return end

    -- Debounce: guard against duplicate lines firing within the same opening.
    -- Checked after the distance test so a ??? reward can't swallow a real chest.
    local now = os.time()
    if now - last_record_time < RECORD_COOLDOWN then return end
    last_record_time = now

    record_chest(active_zone, sector, amount)
end)

-- ---------------------------------------------------------------------------
-- Zone change
-- ---------------------------------------------------------------------------
windower.register_event('zone change', function(new_zone, old_zone)
    if zone_name[new_zone] then
        enter_zone(new_zone)
    else
        active_zone = nil
        refresh_display()  -- hides unless //lh show is active
    end
end)

-- ---------------------------------------------------------------------------
-- Load: fires once after the addon loads (handles loading while logged in)
-- ---------------------------------------------------------------------------
windower.register_event('load', init_current_zone)

-- ---------------------------------------------------------------------------
-- Login: catches the addon loading before the player finished logging in,
-- and switching characters in the same instance.
-- ---------------------------------------------------------------------------
windower.register_event('login', function()
    state         = nil  -- clear any previous character's state so init runs fresh
    pending_reset = {}
    init_current_zone()
end)

-- ---------------------------------------------------------------------------
-- Addon commands
-- ---------------------------------------------------------------------------
windower.register_event('addon command', function(cmd, ...)
    local args = {...}
    cmd = cmd and cmd:lower() or 'help'

    -- ---- reset ----
    if cmd == 'reset' then
        local which = args[1] and args[1]:lower()
        local zones
        if which == 'all' then
            zones = {APOLLYON, TEMENOS}
        elseif which then
            local z = zone_by_name(which)
            if not z then
                log('Usage: //lh reset [apollyon|temenos|all]')
                return
            end
            zones = {z}
        elseif active_zone then
            zones = {active_zone}
        else
            zones = {APOLLYON, TEMENOS}
        end
        local names = {}
        for _, z in ipairs(zones) do
            reset_zone(z)
            names[#names+1] = zone_name[z]
        end
        log('Chest tracking reset for '..table.concat(names, ' and ')..'.')

    -- ---- debug ----
    elseif cmd == 'debug' then
        debug_mode = not debug_mode
        log('Debug mode: '..(debug_mode and 'ON (logging all incoming text)' or 'OFF')..'.')

    -- ---- pos ----
    elseif cmd == 'pos' then
        local me = windower.ffxi.get_mob_by_target('me')
        if me then
            log(('Position  x=%.2f  y=%.2f  z=%.2f'):format(me.x, me.y, me.z))
            if active_zone then
                local s, d2 = nearest_chest(active_zone, me.x, me.y, me.z)
                log(('Detected sector: %s  (%.1f yalms from its chest)'):format(s, math.sqrt(d2)))
            else
                log('Detected sector: unknown (not in Apollyon or Temenos)')
            end
        else
            log('Cannot read player position.')
        end

    -- ---- sector (manual log / toggle) ----
    elseif cmd == 'sector' then
        local s      = (args[1] or ''):upper()
        local amount = tonumber(args[2])

        local zone_id = active_zone or zone_for_sector(s)
        if not zone_id then
            log('Unknown sector "'..s..'". Valid: Apollyon: NW NE SW SE  |  Temenos: N E W C')
        elseif not valid_sector(s, zone_id) then
            log('Valid sectors for '..zone_name[zone_id]..': '..sector_list_str(zone_id))
        elseif args[2] and amount ~= STANDARD_AMT and amount ~= BONUS_AMT then
            log('Amount must be '..STANDARD_AMT..' or '..BONUS_AMT..'.')
        elseif amount then
            record_chest(zone_id, s, amount)
        elseif tracking[zone_id][s] then
            -- Opened or bonus -> back to unopened
            tracking[zone_id][s] = nil
            if not zone_has_bonus(zone_id) then pending_reset[zone_id] = nil end
            save_state()
            log(zone_name[zone_id]..' '..s..' marked Unopened.')
            refresh_display()
        else
            record_chest(zone_id, s, STANDARD_AMT)
        end

    -- ---- show / hide ----
    elseif cmd == 'show' then
        manual_show = true
        refresh_display()

    elseif cmd == 'hide' then
        manual_show = false
        disp:hide()

    -- ---- help ----
    elseif cmd == 'help' or cmd == '' then
        windower.add_to_chat(167, 'LimbusHelper v'.._addon.version)
        windower.add_to_chat(167, '  //lh help                       - Show this help text')
        windower.add_to_chat(167, '  //lh reset [apollyon|temenos|all] - Reset tracking (auto-resets '..RESET_DELAY..'s after bonus)')
        windower.add_to_chat(167, '  //lh sector <sector>            - Toggle sector Opened/Unopened')
        windower.add_to_chat(167, '  //lh sector <sector> <3000|5000> - Log a chest result manually')
        windower.add_to_chat(167, '    Apollyon sectors: NW NE SW SE')
        windower.add_to_chat(167, '    Temenos  sectors: N  W  E  C')
        windower.add_to_chat(167, '  //lh pos                        - Print position and detected sector')
        windower.add_to_chat(167, '  //lh debug                      - Toggle verbose incoming-text logging')
        windower.add_to_chat(167, '  //lh show / hide                - Toggle the overlay (drag it to move)')

    -- ---- unknown ----
    else
        windower.add_to_chat(8, 'LimbusHelper: Unknown command "'..cmd..'". Type //lh help for usage.')
    end
end)
