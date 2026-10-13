-- Spawns and manages the shario Rust server process itself -- separate
-- from the Node bridge (bridge.lua), which talks to it over a socket once
-- it's up. Mirrors shario-vscode's startSharProcess/maybeRestartServer.
local M = {}

local GITHUB_REPO = "Muna-Louis-Nwugo/shario"

-- The newest MAJOR shario release line this plugin version is built/tested
-- against. Bump this (and release a new plugin version) when shario ships
-- a breaking (MAJOR-bumped) release this plugin should follow instead --
-- see shario's own info/PLUGIN_SPECIFICATIONS.md for what a MAJOR bump
-- means. Anything within this major (a minor/patch release) is picked up
-- automatically -- see resolve_target_tag -- without needing a plugin
-- update at all.
local COMPATIBLE_SHARIO_MAJOR = 0

-- Set only by M.update_to (:ShareUpdate in init.lua), when the user
-- explicitly forces a specific release, possibly a different major than
-- COMPATIBLE_SHARIO_MAJOR. nil means "resolve normally" -- the newest
-- release matching COMPATIBLE_SHARIO_MAJOR, re-checked every time a binary
-- is needed. Deliberately not persisted across restarts -- an old manual
-- override shouldn't silently outlive the session you chose it in.
local active_version_override = nil

local job_id = nil
-- e.g. {"create", "my-session"} or {"participate", "my-session"} --
-- remembered so a later restart rejoins the same session instead of
-- needing a subcommand to default to.
local last_launch_args = nil

local function parse_major(tag)
    return tonumber(tag:match("shario_v(%d+)%."))
end

-- Maps this machine's OS/arch to the exact release asset name built by
-- shario's own .github/workflows/release.yml -- see shario's own
-- info/PLUGIN_SPECIFICATIONS.md for the full table.
local function binary_asset_name()
    local uname = vim.loop.os_uname()
    local sysname = uname.sysname
    local machine = uname.machine
    local is_arm = machine == "aarch64" or machine == "arm64" or machine == "ARM64"

    if sysname == "Windows_NT" then
        return is_arm and "shario-windows-arm64.exe" or "shario-windows-x64.exe"
    elseif sysname == "Darwin" then
        return is_arm and "shario-macos-arm64" or "shario-macos-x64"
    elseif sysname == "Linux" then
        return is_arm and "shario-linux-arm64" or "shario-linux-x64"
    end

    error("no prebuilt binary for " .. sysname .. "/" .. machine)
end

local function bin_dir(version)
    return vim.fn.stdpath("data") .. "/shario-nvim/bin/" .. version
end

-- Fetches this project's releases, newest first, filtered to stable-only
-- unless `enable_beta` is set -- this project marks test/beta releases as
-- pre-release on purpose, so plain usage should never pick one up unless
-- explicitly opted into (see M.enable_beta in init.lua).
-- `callback(releases_or_nil, err_or_nil)`.
local function fetch_releases(enable_beta, callback)
    vim.fn.jobstart({
        "curl",
        "-fsS",
        "-H",
        "User-Agent: shario-nvim",
        "https://api.github.com/repos/" .. GITHUB_REPO .. "/releases",
    }, {
        stdout_buffered = true,
        on_stdout = function(_, data)
            local body = table.concat(data, "\n")
            local ok, parsed = pcall(vim.json.decode, body)
            if not ok or type(parsed) ~= "table" then
                return -- on_exit has the real reason if this was actually an error
            end

            if enable_beta then
                callback(parsed, nil)
                return
            end
            local stable = {}
            for _, r in ipairs(parsed) do
                if not r.prerelease then
                    table.insert(stable, r)
                end
            end
            callback(stable, nil)
        end,
        on_exit = function(_, code)
            if code ~= 0 then
                callback(nil, "failed to reach GitHub (curl exited with code " .. code .. ")")
            end
        end,
    })
end

-- The tag M.ensure_binary should actually use: whatever M.update_to
-- explicitly forced, if anything, or else the newest release matching
-- COMPATIBLE_SHARIO_MAJOR -- resolved fresh every call so a new compatible
-- minor/patch release is always picked up without needing a plugin update,
-- while a differently-majored release is never used automatically.
-- `callback(tag_or_nil, err_or_nil)`.
local function resolve_target_tag(enable_beta, callback)
    if active_version_override then
        callback(active_version_override, nil)
        return
    end

    fetch_releases(enable_beta, function(releases, err)
        if not releases then
            callback(nil, err)
            return
        end
        for _, r in ipairs(releases) do
            if parse_major(r.tag_name) == COMPATIBLE_SHARIO_MAJOR then
                callback(r.tag_name, nil)
                return
            end
        end
        callback(nil, "no shario release found matching major version " .. COMPATIBLE_SHARIO_MAJOR)
    end)
end

-- Resolves to a working shario binary (see resolve_target_tag), downloading
-- it the first time that version is needed on this machine. Cached one
-- subfolder per version under Neovim's own data directory, so a version
-- already fetched before is never re-downloaded, and never clobbers
-- another version's cached copy. `callback(path_or_nil, err_or_nil)` is
-- called exactly once.
function M.ensure_binary(enable_beta, callback)
    resolve_target_tag(enable_beta, function(target_tag, resolve_err)
        if not target_tag then
            callback(nil, resolve_err)
            return
        end

        local ok, asset_name = pcall(binary_asset_name)
        if not ok then
            callback(nil, asset_name) -- asset_name is the error message here
            return
        end

        local dir = bin_dir(target_tag)
        local bin_path = dir .. "/" .. asset_name
        if vim.fn.filereadable(bin_path) == 1 then
            callback(bin_path, nil)
            return
        end

        vim.fn.mkdir(dir, "p")
        local url = "https://github.com/" .. GITHUB_REPO .. "/releases/download/" .. target_tag .. "/" .. asset_name

        vim.fn.jobstart({ "curl", "-fL", "-o", bin_path, url }, {
            on_exit = function(_, code)
                if code ~= 0 then
                    callback(nil, "curl exited with code " .. code .. " downloading " .. url)
                    return
                end
                if vim.loop.os_uname().sysname ~= "Windows_NT" then
                    vim.loop.fs_chmod(bin_path, tonumber("755", 8))
                end
                callback(bin_path, nil)
            end,
        })
    end)
end

-- Checks GitHub for the actual newest release overall (unlike
-- resolve_target_tag, not constrained to COMPATIBLE_SHARIO_MAJOR -- this is
-- the one place a major-crossing update can happen, and only with the
-- user's explicit confirmation, see M.update_to and :ShareUpdate).
-- `callback(info, err)`, where `info` is `{ latest_tag, is_breaking }` --
-- `is_breaking` true means its major version differs from
-- COMPATIBLE_SHARIO_MAJOR, so it very likely isn't compatible with this
-- plugin's wire-protocol assumptions (see shario's own
-- info/PLUGIN_SPECIFICATIONS.md).
function M.check_latest(enable_beta, callback)
    fetch_releases(enable_beta, function(releases, err)
        if not releases then
            callback(nil, err)
            return
        end
        if not releases[1] then
            callback(nil, "no shario releases found")
            return
        end
        local latest_tag = releases[1].tag_name
        callback({
            latest_tag = latest_tag,
            is_breaking = parse_major(latest_tag) ~= COMPATIBLE_SHARIO_MAJOR,
        }, nil)
    end)
end

-- Switches to `tag` for the rest of this session (not persisted -- see
-- active_version_override's own comment) and downloads it right away so
-- the next launch doesn't have to. `callback(ok, err)`.
function M.update_to(tag, callback)
    active_version_override = tag
    M.ensure_binary(false, function(path, err)
        callback(path ~= nil, err)
    end)
end

function M.is_running()
    return job_id ~= nil
end

-- `args`: e.g. {"create", "my-session"}. `on_output(line)` is called for
-- every line of the server's stdout/stderr (hand it to a dedicated buffer
-- or :messages, same idea as shario-vscode's output channel). `on_started(ok)`
-- is called exactly once, after the binary has been obtained (resolving
-- and downloading it first if not already cached) and the process spawn
-- has been attempted.
function M.start(args, port, enable_beta, on_output, on_started)
    if job_id then
        on_started(true) -- already (re)started this session
        return
    end
    last_launch_args = args

    M.ensure_binary(enable_beta, function(bin_path, err)
        if not bin_path then
            vim.notify("shario: failed to obtain server binary: " .. err, vim.log.levels.ERROR)
            on_started(false)
            return
        end

        local cmd = { bin_path, "--port", tostring(port) }
        for _, a in ipairs(args) do
            table.insert(cmd, a)
        end

        local function relay(_, data)
            if on_output and data then
                for _, line in ipairs(data) do
                    if line ~= "" then
                        on_output(line)
                    end
                end
            end
        end

        job_id = vim.fn.jobstart(cmd, {
            on_stdout = relay,
            on_stderr = relay,
            on_exit = function(_, code)
                job_id = nil
                if on_output then
                    on_output("shario server exited with code " .. code)
                end
            end,
        })

        if job_id <= 0 then
            vim.notify("shario: failed to launch the server process", vim.log.levels.ERROR)
            job_id = nil
            on_started(false)
            return
        end
        on_started(true)
    end)
end

-- Re-launches with whatever args were last used to start successfully.
-- `on_started(ok)` is called exactly once; `ok` is false (after notifying)
-- if nothing's ever been started yet.
function M.restart(port, enable_beta, on_output, on_started)
    if not last_launch_args then
        vim.notify(
            "shario: no session to restart into -- run :ShareCreate or :ShareParticipate first",
            vim.log.levels.ERROR
        )
        on_started(false)
        return
    end
    M.start(last_launch_args, port, enable_beta, on_output, on_started)
end

function M.stop()
    if job_id then
        vim.fn.jobstop(job_id)
        job_id = nil
    end
end

-- Polls a raw TCP connect to 127.0.0.1:port until it succeeds or
-- timeout_ms elapses. `callback(ok)` is called exactly once.
function M.wait_for_up(port, timeout_ms, callback)
    local deadline = vim.loop.now() + timeout_ms

    local function tick()
        local tcp = vim.loop.new_tcp()
        tcp:connect("127.0.0.1", port, function(err)
            tcp:close()
            if not err then
                vim.schedule(function()
                    callback(true)
                end)
            elseif vim.loop.now() >= deadline then
                vim.schedule(function()
                    callback(false)
                end)
            else
                vim.defer_fn(tick, 300)
            end
        end)
    end

    tick()
end

return M
