-- Spawns and manages the shario Rust server process itself -- separate
-- from the Node bridge (bridge.lua), which talks to it over a socket once
-- it's up. Mirrors shario-vscode's startSharProcess/maybeRestartServer.
local M = {}

local GITHUB_REPO = "Muna-Louis-Nwugo/shario"

-- The exact shario release this plugin version is built/tested against.
-- Bump this (and release a new plugin version) when shario ships a release
-- this plugin should follow -- that bump is itself what makes updating the
-- plugin also fetch the new server version, since the binary cache below
-- is keyed by this tag. Releases are `shario_vMAJOR.MINOR.PATCH`; a MAJOR
-- bump means a breaking change (see shario's own info/PLUGIN_SPECIFICATIONS.md).
local COMPATIBLE_SHARIO_TAG = "shario_v0.1.0_beta4"

-- What M.ensure_binary actually downloads/runs. Starts at the plugin's own
-- pin every session; M.update_to can move it for the rest of this session
-- (see :ShareUpdate in init.lua). Deliberately not persisted across
-- restarts -- an old manual override shouldn't silently outlive the
-- session you chose it in, and updating the plugin should always win.
local active_version = COMPATIBLE_SHARIO_TAG

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

-- Resolves to a working shario binary matching `active_version`,
-- downloading it the first time this version is needed on this machine.
-- Cached one subfolder per version under Neovim's own data directory, so
-- switching versions (see M.update_to) never re-downloads one already
-- fetched before, and never clobbers another version's cached copy.
-- `callback(path_or_nil, err_or_nil)` is called exactly once.
function M.ensure_binary(callback)
    local ok, asset_name = pcall(binary_asset_name)
    if not ok then
        callback(nil, asset_name) -- asset_name is the error message here
        return
    end

    local dir = bin_dir(active_version)
    local bin_path = dir .. "/" .. asset_name
    if vim.fn.filereadable(bin_path) == 1 then
        callback(bin_path, nil)
        return
    end

    vim.fn.mkdir(dir, "p")
    local url = "https://github.com/" .. GITHUB_REPO .. "/releases/download/" .. active_version .. "/" .. asset_name

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
end

-- Checks GitHub for the actual newest release and compares its major
-- version against `active_version`'s. `callback(info, err)`, where `info`
-- is `{ latest_tag, is_breaking }` -- `is_breaking` true means the latest
-- release's major version differs from what's currently active, so it
-- very likely isn't compatible with this plugin's wire-protocol
-- assumptions (see shario's own info/PLUGIN_SPECIFICATIONS.md).
--
-- By default (`enable_beta` false) this uses /releases/latest, which
-- excludes anything marked pre-release (this project marks test/beta
-- releases as pre-release on purpose) -- so this never reports one as "the
-- latest" to update onto unless the caller explicitly opted in via
-- `enable_beta`, in which case it uses the plain /releases list (newest
-- first, including pre-releases) instead and just takes the first entry.
--
-- `-f` makes curl exit 22 (not just a non-zero code) specifically on an
-- HTTP error like the 404 /releases/latest gives when no stable release
-- exists yet, and suppresses the error body -- on_stdout can still fire
-- with that empty body, so a `responded` guard keeps it from also calling
-- back with a confusing "couldn't parse" once on_exit already has the real
-- reason.
function M.check_latest(enable_beta, callback)
    local responded = false
    local function respond(info, err)
        if responded then
            return
        end
        responded = true
        callback(info, err)
    end

    local url = "https://api.github.com/repos/"
        .. GITHUB_REPO
        .. (enable_beta and "/releases" or "/releases/latest")

    vim.fn.jobstart({ "curl", "-fsS", "-H", "User-Agent: shario-nvim", url }, {
        stdout_buffered = true,
        on_stdout = function(_, data)
            local body = table.concat(data, "\n")
            local ok, parsed = pcall(vim.json.decode, body)
            if not ok then
                return -- likely an HTTP-error body `-f` suppressed; on_exit has the real reason
            end

            local release = enable_beta and parsed[1] or parsed
            if not release or not release.tag_name then
                if enable_beta then
                    respond(nil, "no shario releases exist yet")
                end
                return
            end
            respond({
                latest_tag = release.tag_name,
                is_breaking = parse_major(release.tag_name) ~= parse_major(active_version),
            }, nil)
        end,
        on_exit = function(_, code)
            if code == 22 then
                respond(nil, "no stable shario release has been published yet")
            elseif code ~= 0 then
                respond(nil, "failed to reach GitHub (curl exited with code " .. code .. ")")
            else
                respond(nil, "couldn't parse GitHub's response")
            end
        end,
    })
end

-- Switches `active_version` to `tag` for the rest of this session (not
-- persisted -- see active_version's own comment) and downloads it right
-- away so the next launch doesn't have to. `callback(ok, err)`.
function M.update_to(tag, callback)
    active_version = tag
    M.ensure_binary(function(path, err)
        callback(path ~= nil, err)
    end)
end

function M.is_running()
    return job_id ~= nil
end

-- `args`: e.g. {"create", "my-session"}. `on_output(line)` is called for
-- every line of the server's stdout/stderr (hand it to a dedicated buffer
-- or :messages, same idea as shario-vscode's output channel). `on_started(ok)`
-- is called exactly once, after the binary has been obtained (downloading
-- it first if not already cached) and the process spawn has been attempted.
function M.start(args, port, on_output, on_started)
    if job_id then
        on_started(true) -- already (re)started this session
        return
    end
    last_launch_args = args

    M.ensure_binary(function(bin_path, err)
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
function M.restart(port, on_output, on_started)
    if not last_launch_args then
        vim.notify(
            "shario: no session to restart into -- run :ShareCreate or :ShareParticipate first",
            vim.log.levels.ERROR
        )
        on_started(false)
        return
    end
    M.start(last_launch_args, port, on_output, on_started)
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
