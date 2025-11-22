-- Playlist Tracker – Restores the last played file inside a folder/playlist and restores the playback on extension activation.
-- Author: Sai / ChatGPT
-- State is stored in ~/vlc_playlist_state.json (Location for Windows: Documents folder and Linux/Mac: Home folder)

local config = {
    state_file = nil
}

function descriptor()
    return {
        title = "Playlist Tracker",
        version = "1.0",
        author = "Sai, ChatGPT",
        description = "Restores the last played file inside a folder/playlist and restores the playback on extension activation.",
        capabilities = { "input-listener" }
    }
end

-- Print playlist entries for debugging purposes
local function log_playlist()
    vlc.msg.dbg("PTracker: Listing playlist...")

    local root = vlc.playlist.get("playlist", false)
    if not root or not root.children then
        vlc.msg.dbg("PTracker: Playlist empty or unavailable")
        return
    end

    for i, item in ipairs(root.children) do
        vlc.msg.dbg(string.format(
            "PTracker: [%d] name='%s' | path='%s'",
            i, tostring(item.name), tostring(item.path)
        ))
    end
end

-- Save JSON text to disk
local function save_state(json)
    if not config.state_file then return end

    local file = vlc.io.open(config.state_file, "wt")
    if not file then
        vlc.msg.err("PTracker: Could not write: " .. config.state_file)
        return
    end

    file:write(json)
    file:close()
    vlc.msg.dbg("PTracker: State saved")
end

-- Split a path into its component directory names
local function split_path(path)
    local parts = {}
    for p in path:gmatch("[^/]+") do
        table.insert(parts, p)
    end
    return parts
end

-- Compute the common folder prefix across a list of file paths
local function common_prefix(paths)
    if #paths == 0 then return nil end

    local split_paths = {}
    for i, p in ipairs(paths) do
        split_paths[i] = split_path(p)
    end

    local prefix, index = {}, 1

    while true do
        local token = split_paths[1][index]
        if not token then break end

        for j = 2, #split_paths do
            if split_paths[j][index] ~= token then
                return table.concat(prefix, "/") .. "/"
            end
        end

        table.insert(prefix, token)
        index = index + 1
    end

    return table.concat(prefix, "/") .. "/"
end

-- Extract paths of all playlist media items
local function collect_media_paths()
    local paths = {}
    local root = vlc.playlist.get("playlist", false)

    if not root or not root.children then
        return paths
    end

    for _, item in ipairs(root.children) do
        if item.path then
            table.insert(paths, item.path)
        end
    end

    return paths
end

-- Identify the "true root" folder representing the playlist
local function determine_root_folder()
    local paths = collect_media_paths()
    if #paths == 0 then
        vlc.msg.dbg("PTracker: No media paths found")
        return nil
    end

    local parents = {}
    for _, p in ipairs(paths) do
        local folder = p:match("(.*/)")
        if folder then
            table.insert(parents, folder)
        end
    end

    local root = common_prefix(parents)
    vlc.msg.dbg("PTracker: Root folder resolved: " .. tostring(root))
    return root
end

-- Read the state JSON file (raw string)
local function load_state()
    if not config.state_file then return nil end

    local file = vlc.io.open(config.state_file, "rt")
    if not file then return nil end

    local data = file:read("*a")
    file:close()

    return data
end

-- Given an index, return the corresponding playlist item ID
local function get_id_for_index(target_index)
    local root = vlc.playlist.get("playlist", false)
    if not root or not root.children then return nil end

    local item = root.children[target_index]
    if item then
        return item.id
    end

    return nil
end

-- Given an item ID, find its current playlist index
local function get_index_for_id(target_id)
    if not target_id then return nil end

    local root = vlc.playlist.get("playlist", false)
    if not root or not root.children then return nil end

    for i, item in ipairs(root.children) do
        if item.id == target_id then
            return i
        end
    end

    return nil
end

-- Save current playlist index to JSON
-- Note: VLC returns item IDs, so we map ID → playlist index
local function update_state()
    local current_id = vlc.playlist.current()
    if not current_id then
        vlc.msg.dbg("PTracker: No active playlist item")
        return
    end

    local idx = get_index_for_id(current_id)
    if not idx then
        vlc.msg.dbg("PTracker: Could not map current ID to index")
        return
    end

    local folder = determine_root_folder()
    if not folder then return end

    local table_data = {}
    local raw = load_state()

    -- Parse existing values into table_data
    if raw and #raw > 0 then
        for k, v in raw:gmatch('"([^"]+)":%s*(%d+)') do
            table_data[k] = tonumber(v)
        end
    end

    table_data[folder] = idx

    -- Build JSON manually (no JSON lib in VLC Lua)
    local json = "{\n"
    local first = true

    for k, v in pairs(table_data) do
        if not first then
            json = json .. ",\n"
        end
        json = json .. string.format('  "%s": %d', k, v)
        first = false
    end

    json = json .. "\n}\n"
    save_state(json)
end

-- Called whenever VLC switches to a new playlist item
function input_changed()
    vlc.msg.dbg("PTracker: Input changed")
    update_state()
end

-- Called when the extension is loaded
function activate()
    config.state_file = vlc.config.homedir() .. "/vlc_playlist_state.json"
    vlc.msg.dbg("PTracker: Using state file: " .. config.state_file)

    -- log_playlist() //for debugging

    local folder = determine_root_folder()
    if not folder then return end

    local raw = load_state()
    if not raw then
        vlc.msg.dbg("PTracker: No saved state")
        return
    end

    -- Escape Lua pattern characters for matching
    local escaped = folder:gsub("([%-%.%+%*%?%[%]%^%$%(%)%%])", "%%%1")
    local saved = raw:match('"' .. escaped .. '":%s*(%d+)')

    if not saved then
        vlc.msg.dbg("PTracker: No saved index for this folder")
        return
    end

    saved = tonumber(saved)
    vlc.msg.dbg("PTracker: Saved index: " .. saved)

    local id = get_id_for_index(saved)
    if id then
        vlc.msg.dbg("PTracker: Restoring via item ID " .. tostring(id))
        vlc.playlist.goto(id)
    else
        vlc.msg.dbg("PTracker: Index exists but corresponding ID is not yet available")
    end
end

-- Called when the extension is unloaded
function deactivate()
    vlc.msg.dbg("PTracker: Deactivated, saving state")
    update_state()
end
