-- Per-buffer CRDT identity mirror: one array per buffer, one entry per
-- line, each holding an anchor plus an ordered list of cells. Mirrors
-- shario-vscode's docState exactly -- same cell/anchor shape, same
-- tag-before-confirmation model. See shario's own
-- info/PLUGIN_SPECIFICATIONS.md for the full contract this implements.
--
-- cell/anchor shape: { value = "x" (nil for an anchor), id = number|nil,
-- peer = number|nil, tag = number|nil }
--
-- Positions throughout this module are *character* indices (1-based rows
-- via Lua arrays, 0-based columns to match the wire protocol), not byte
-- offsets -- callers crossing in from Neovim's byte-oriented buffer API
-- need to convert first. See diff.lua.
local M = {}

-- bufnr -> array of { anchor = cell, cells = { cell, ... } }
local doc_state = {}

-- tag -> { file_path, row, col, is_whole_line } -- a remove that arrived
-- before its own target's add was confirmed, waiting for that tag to
-- resolve into a real identity
M.pending_removals = {}

-- tag -> the cell/anchor table itself, mutated in place once confirmed
M.pending_adds = {}

-- file_path -> server lines snapshot from "initial-state", held only if it
-- arrives before this buffer's docState has been built yet
M.pending_snapshots = {}

local next_tag = 0
function M.new_tag()
    local t = next_tag
    next_tag = next_tag + 1
    return t
end

-- Splits a line into a list of single characters, Unicode-codepoint-aware
-- (not byte-aware) -- `vim.fn.split(..., '\\zs')` uses Vim's own
-- multibyte-aware string handling rather than a naive byte split.
function M.chars(line)
    if line == "" then
        return {}
    end
    return vim.fn.split(line, "\\zs")
end

-- Builds the initial mirror from a buffer's current lines. Every cell
-- starts with no tag and no known id/peer (except line 1's anchor, the
-- root sentinel) -- real identities for pre-existing content arrive later
-- via "initial-state".
local function build_initial_state(lines)
    local state = {}
    for i, line_text in ipairs(lines) do
        local anchor
        if i == 1 then
            anchor = { id = 0, peer = 0, tag = nil }
        else
            anchor = { id = nil, peer = nil, tag = nil }
        end

        local cells = {}
        for _, ch in ipairs(M.chars(line_text)) do
            table.insert(cells, { value = ch, id = nil, peer = nil, tag = nil })
        end

        table.insert(state, { anchor = anchor, cells = cells })
    end
    return state
end

-- Fills in real (id, peer) for pre-existing content from the server's
-- "initial-state" snapshot, matching purely by position -- safe only
-- because nothing's been edited between this client reading the file and
-- the server loading the same bytes, which is exactly when this fires.
-- Each server entry is a raw [id, peer] pair.
function M.reconcile_identities(lines, server_lines)
    for i = 1, math.min(#server_lines, #lines) do
        local server_line = server_lines[i]
        local line = lines[i]

        local anchor_info = server_line[1]
        if anchor_info then
            line.anchor.id = anchor_info[1]
            line.anchor.peer = anchor_info[2]
        end

        for j = 2, #server_line do
            local cell = line.cells[j - 1]
            if not cell then
                break
            end
            local info = server_line[j]
            cell.id = info[1]
            cell.peer = info[2]
        end
    end
end

-- Returns bufnr's local mirror, building it (and applying any
-- "initial-state" snapshot that arrived before this buffer was even
-- tracked) the first time it's needed.
function M.get_or_create(bufnr, file_path)
    local lines = doc_state[bufnr]
    if lines then
        return lines
    end

    lines = build_initial_state(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
    doc_state[bufnr] = lines

    local snapshot = M.pending_snapshots[file_path]
    if snapshot then
        M.pending_snapshots[file_path] = nil
        M.reconcile_identities(lines, snapshot)
    end

    return lines
end

function M.get(bufnr)
    return doc_state[bufnr]
end

function M.forget(bufnr)
    doc_state[bufnr] = nil
end

return M
