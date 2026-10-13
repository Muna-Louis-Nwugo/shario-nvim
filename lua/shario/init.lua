-- Entry point: user commands, buffer tracking, and the glue between the
-- bridge (socket.io events) and ops/docstate (the actual CRDT mirror).
-- See info/PLUGIN_SPECIFICATIONS.md (in the shario repo) for the protocol
-- this implements, and shario-vscode/extension.js for the reference
-- implementation this was ported from.
local bridge = require("shario.bridge")
local process = require("shario.process")
local docstate = require("shario.docstate")
local diff = require("shario.diff")
local ops = require("shario.ops")

local M = {}

M.port = 3000

-- When true, :ShareUpdate is allowed to update onto a pre-release (beta)
-- shario version, not just the newest stable one. Set it before :ShareUpdate
-- runs, e.g. `require("shario").enable_beta = true` in your own config.
M.enable_beta = false

-- The root directory joined with -- only buffers under this get tracked,
-- same reasoning as shario-vscode's connectedRoot (don't forward edits for
-- files the server never loaded).
local connected_root = nil

local SESSION_NAME_WORDS = {
    "quick", "lazy", "brave", "calm", "eager", "fuzzy", "gentle", "jolly",
    "proud", "silly", "witty", "bold", "otter", "falcon", "maple", "comet",
    "badger", "willow", "ember", "puzzle", "raven", "cedar", "harbor", "thistle",
}

-- A plugin that wants to guarantee it knows a session's name (to show the
-- user) shouldn't rely on the server's own random fallback -- generate it
-- here instead, so it's always known up front, and always pass it to
-- `create` explicitly.
local function random_session_name()
    math.randomseed(os.time())
    local function pick()
        return SESSION_NAME_WORDS[math.random(#SESSION_NAME_WORDS)]
    end
    return pick() .. "-" .. pick() .. "-" .. pick()
end

local function notify(msg, level)
    vim.notify("[shario] " .. msg, level or vim.log.levels.INFO)
end

local function is_tracked_buffer(bufnr)
    if not connected_root then
        return false
    end
    if vim.bo[bufnr].buftype ~= "" then
        return false -- not a normal file buffer
    end
    local name = vim.api.nvim_buf_get_name(bufnr)
    if name == "" then
        return false
    end
    name = vim.fn.fnamemodify(name, ":p")
    return name:sub(1, #connected_root) == connected_root
end

-- Attaches change-tracking to one buffer. Safe to call more than once for
-- the same buffer -- nvim_buf_attach is a no-op if already attached with
-- the same callback set... actually it isn't, so guard explicitly.
local attached = {}
local function track_buffer(bufnr)
    if attached[bufnr] then
        return
    end
    if not is_tracked_buffer(bufnr) then
        return
    end
    attached[bufnr] = true

    local file_path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":p")
    docstate.get_or_create(bufnr, file_path)

    vim.api.nvim_buf_attach(bufnr, false, {
        on_lines = function(_, buf, _, firstline, lastline, new_lastline, _byte_count)
            if not bridge.is_running() then
                return
            end
            local lines = docstate.get(buf)
            if not lines then
                return
            end
            local edit = diff.compute_edit(buf, lines, firstline, lastline, new_lastline)
            if edit then
                ops.apply_edit(file_path, lines, edit)
            end
        end,
        on_detach = function(_, buf)
            attached[buf] = nil
            docstate.forget(buf)
        end,
    })
end

local function track_all_open_buffers()
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(bufnr) then
            track_buffer(bufnr)
        end
    end
end

-- Dispatches one relayed bridge event. See bridge.lua/socket-bridge.js for
-- the full event list.
local function handle_bridge_event(event, data, message)
    if event == "connect" then
        bridge.join(connected_root)
        notify("connected to Shar, joined as local for " .. connected_root)
        track_all_open_buffers()
    elseif event == "disconnect" then
        notify("disconnected from Shar", vim.log.levels.WARN)
        process.wait_for_up(M.port, 1, function(up)
            if up then
                return -- still alive -- not what killed the connection
            end
            notify("Shar server appears to have died -- attempting to restart it...", vim.log.levels.WARN)
            process.restart(M.port, function(line)
                vim.schedule(function()
                    vim.api.nvim_echo({ { "[shario server] " .. line } }, false, {})
                end)
            end, function(started)
                if not started then
                    return
                end
                process.wait_for_up(M.port, 30000, function(ok)
                    if ok then
                        notify("Shar server restarted -- waiting for it to reconnect...")
                    else
                        notify("Shar server did not come back up -- check :messages", vim.log.levels.ERROR)
                    end
                end)
            end)
        end)
    elseif event == "error" or event == "bridge_exit" then
        notify(message or "unknown bridge error", vim.log.levels.ERROR)
    elseif event == "initial-state" then
        -- NOT YET SENT BY THE SERVER in every case -- see
        -- shario-vscode/extension.js's file-level comment for the same
        -- caveat; ported here verbatim since the server side is shared.
        local target_bufnr = nil
        for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
            if vim.api.nvim_buf_is_loaded(bufnr) then
                local name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":p")
                if name == data.file_path then
                    target_bufnr = bufnr
                    break
                end
            end
        end

        local lines = target_bufnr and docstate.get(target_bufnr)
        if lines then
            docstate.reconcile_identities(lines, data.lines)
        else
            -- not open yet, or docState for it hasn't been built --
            -- get_or_create picks this up once it is
            docstate.pending_snapshots[data.file_path] = data.lines
        end
    elseif event == "ide-add-confirmed" then
        ops.confirm_add(data)
    elseif event == "ide-add-failed" then
        notify("ide-add failed: " .. vim.inspect(data), vim.log.levels.WARN)
    end
end

-- Shared by :ShareCreate/:ShareParticipate (after the server's confirmed
-- up) and a manual :ShareConnect to one already running.
local function connect()
    if bridge.is_running() then
        notify("already connected to Shar")
        return
    end
    connected_root = vim.fn.fnamemodify(vim.fn.getcwd(), ":p"):gsub("/$", "")
    ops.emit = bridge.emit
    bridge.start(M.port, handle_bridge_event)
end

local function start_session(args, label)
    process.start(args, M.port, function(line)
        vim.schedule(function()
            vim.api.nvim_echo({ { "[shario server] " .. line } }, false, {})
        end)
    end, function(started)
        if not started then
            return -- error already notified
        end
        process.wait_for_up(M.port, 30000, function(ok)
            if not ok then
                notify("Shar server did not come up in time -- check :messages", vim.log.levels.ERROR)
                return
            end
            connect()
            notify(label)
        end)
    end)
end

function M.create(name)
    local function go(chosen_name)
        local final_name = (chosen_name and chosen_name ~= "" and chosen_name) or random_session_name()
        start_session(
            { "create", final_name },
            string.format('Shar session created: "%s" -- share this name so others can join.', final_name)
        )
    end

    if name and name ~= "" then
        go(name)
    else
        vim.ui.input({ prompt = "Name this Shar session (blank for random): " }, function(input)
            if input == nil then
                return -- cancelled
            end
            go(input)
        end)
    end
end

function M.participate(name)
    local function go(chosen_name)
        if not chosen_name or chosen_name == "" then
            notify("a session name is required", vim.log.levels.ERROR)
            return
        end
        start_session({ "participate", chosen_name }, string.format('Joined Shar session: "%s"', chosen_name))
    end

    if name and name ~= "" then
        go(name)
    else
        vim.ui.input({ prompt = "Name of the Shar session to join: " }, go)
    end
end

function M.connect_existing()
    connect()
end

-- Checks GitHub for the newest shario release and downloads it, warning
-- first if its major version differs from what this plugin is pinned to
-- (see process.lua's COMPATIBLE_SHARIO_TAG) -- that's the project's own
-- signal for "likely incompatible," not something this plugin can verify
-- for real, since there's no version handshake in the wire protocol itself.
function M.update_server()
    notify("checking for the latest shario release...")
    process.check_latest(M.enable_beta, function(info, err)
        if not info then
            notify("failed to check for updates: " .. err, vim.log.levels.ERROR)
            return
        end

        local function do_update()
            notify("downloading " .. info.latest_tag .. "...")
            process.update_to(info.latest_tag, function(ok, update_err)
                if ok then
                    notify(
                        "downloaded " .. info.latest_tag .. " -- will be used next time the server (re)starts"
                    )
                else
                    notify("failed to download " .. info.latest_tag .. ": " .. update_err, vim.log.levels.ERROR)
                end
            end)
        end

        if not info.is_breaking then
            do_update()
            return
        end

        vim.ui.select({ "Update anyway", "Cancel" }, {
            prompt = "Latest shario release ("
                .. info.latest_tag
                .. ") has a different major version than what this plugin expects -- likely a breaking change.",
        }, function(choice)
            if choice == "Update anyway" then
                do_update()
            end
        end)
    end)
end

vim.api.nvim_create_user_command("ShareCreate", function(opts)
    M.create(opts.args)
end, { nargs = "?", desc = "Create a new Shar session" })

vim.api.nvim_create_user_command("ShareParticipate", function(opts)
    M.participate(opts.args)
end, { nargs = "?", desc = "Join an existing Shar session by name" })

vim.api.nvim_create_user_command("ShareConnect", function()
    M.connect_existing()
end, { desc = "Attach to a Shar server already running on this machine" })

vim.api.nvim_create_user_command("ShareUpdate", function()
    M.update_server()
end, { desc = "Download the latest shario server release, warning first if it looks like a breaking change" })

vim.api.nvim_create_autocmd("BufAdd", {
    callback = function(args)
        if bridge.is_running() then
            track_buffer(args.buf)
        end
    end,
})

return M
