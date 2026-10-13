-- Spawns the Node socket.io bridge helper (bridge/socket-bridge.js) and
-- relays JSON-line messages to and from it. All the real docState/CRDT
-- logic lives in other modules -- this one only knows how to talk to the
-- bridge process. See bridge/socket-bridge.js for the wire shape.
local M = {}

local job_id = nil
local on_event = nil -- set via M.start, called as on_event(event, data, message)
local stdout_buffer = ""

local function plugin_root()
    local source = debug.getinfo(1, "S").source:sub(2)
    -- this file is lua/shario/bridge.lua -- three levels up is the plugin root
    return vim.fn.fnamemodify(source, ":h:h:h")
end

-- jobstart splits incoming bytes on "\n": the first element of a new chunk
-- continues whatever partial line was buffered from the last chunk, and
-- the last element is itself a partial line (empty if the chunk happened
-- to end exactly on a newline) to carry over to the next call.
local function handle_stdout(_, data)
    if not data then
        return
    end
    data[1] = stdout_buffer .. data[1]
    stdout_buffer = table.remove(data)

    for _, line in ipairs(data) do
        if line ~= "" then
            local ok, decoded = pcall(vim.json.decode, line)
            if ok and on_event then
                on_event(decoded.event, decoded.data, decoded.message)
            elseif not ok then
                vim.notify("shario: couldn't decode bridge message: " .. line, vim.log.levels.WARN)
            end
        end
    end
end

-- `port`: the shar server's port. `handler(event, data, message)` is
-- called for every relayed event: "connect", "disconnect", "error"
-- (message set), "bridge_exit" (message set), or any named server event
-- (data set) -- e.g. "initial-state", "ide-add-confirmed".
function M.start(port, handler)
    if job_id then
        return true
    end
    on_event = handler
    stdout_buffer = ""

    local bridge_script = plugin_root() .. "/bridge/socket-bridge.js"

    job_id = vim.fn.jobstart({ "node", bridge_script, "--port", tostring(port) }, {
        stdout_buffered = false,
        on_stdout = handle_stdout,
        on_stderr = function(_, data)
            if data then
                for _, line in ipairs(data) do
                    if line ~= "" then
                        vim.notify("[shario bridge] " .. line, vim.log.levels.WARN)
                    end
                end
            end
        end,
        on_exit = function(_, code)
            job_id = nil
            if on_event then
                on_event("bridge_exit", nil, "bridge process exited with code " .. code)
            end
        end,
    })

    if job_id <= 0 then
        vim.notify("shario: failed to start the socket.io bridge (is Node.js installed?)", vim.log.levels.ERROR)
        job_id = nil
        return false
    end
    return true
end

function M.join(path)
    if not job_id then
        return
    end
    vim.fn.chansend(job_id, vim.json.encode({ cmd = "join", path = path }) .. "\n")
end

function M.emit(event, data)
    if not job_id then
        return
    end
    vim.fn.chansend(job_id, vim.json.encode({ cmd = "emit", event = event, data = data }) .. "\n")
end

function M.stop()
    if job_id then
        vim.fn.jobstop(job_id)
        job_id = nil
    end
end

function M.is_running()
    return job_id ~= nil
end

return M
