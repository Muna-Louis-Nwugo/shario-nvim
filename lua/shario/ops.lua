-- Turns one character-level edit (row, col, how many characters were
-- deleted starting there, what text was inserted in their place) into
-- "ide-add"/"remove" emits, updating a docState lines array in lockstep so
-- later edits can look up each character's current identity state.
--
-- This is a direct port of shario-vscode's handleChange/removeRange/
-- insertText/emitAdd/emitRemove -- row/col here are already character
-- indices (0-based row... actually 0-based for both row and col, matching
-- the wire protocol), not Neovim byte offsets. See diff.lua for the piece
-- that computes the edit this module expects from Neovim's own
-- line-range-based change notifications.
local docstate = require("shario.docstate")

local M = {}

-- Set by init.lua -- called as emit(event_name, data_table).
M.emit = function(_, _) end

local function emit_add(file_path, parent, line_hint, val, tag)
    -- NOT `cond and a or b` here on purpose: that idiom silently breaks
    -- whenever `a` itself can be nil/false (parent.id legitimately is nil
    -- for not-yet-reconciled pre-existing content), which it is here.
    local parent_id, parent_peer, parent_tag
    if parent.tag == nil then
        parent_id = parent.id
        parent_peer = parent.peer
        parent_tag = vim.NIL
    else
        parent_id = vim.NIL
        parent_peer = vim.NIL
        parent_tag = parent.tag
    end

    local payload = {
        file_path = file_path,
        parent_id = parent_id == nil and vim.NIL or parent_id,
        parent_peer = parent_peer == nil and vim.NIL or parent_peer,
        parent_tag = parent_tag,
        val = val,
        tag = tag,
        line_hint = line_hint,
    }
    M.emit("ide-add", payload)
end

local function emit_remove(file_path, row, col, is_whole_line, id, peer)
    local payload = {
        file_path = file_path,
        row = row,
        col = col,
        is_whole_line = is_whole_line,
        id = id ~= nil and id or vim.NIL,
        peer = peer ~= nil and peer or vim.NIL,
    }
    M.emit("remove", payload)
end

-- Sends the remove now if this identity is already known (a confirmed
-- add, or pre-existing content); otherwise holds it until the add it
-- belongs to resolves, since there's nothing to tell the server yet.
local function remove_identity(file_path, identity, row, col, is_whole_line)
    if identity.tag ~= nil then
        docstate.pending_removals[identity.tag] = {
            file_path = file_path,
            row = row,
            col = col,
            is_whole_line = is_whole_line,
        }
        return
    end
    emit_remove(file_path, row, col, is_whole_line, identity.id, identity.peer)
end

local function remove_anchor(file_path, lines, line_index)
    -- line_index is 1-based (Lua array index) here
    local line = lines[line_index]
    local prev = lines[line_index - 1]
    for _, cell in ipairs(line.cells) do
        table.insert(prev.cells, cell)
    end
    table.remove(lines, line_index)
    -- row is reported 0-based over the wire, same convention as the
    -- server's own row numbering
    remove_identity(file_path, line.anchor, line_index - 1, 0, true)
end

-- Walks the deleted range forward, removing cells from the local mirror
-- one at a time.
local function remove_range(file_path, lines, start_row, start_col, range_length)
    local row = start_row -- 0-based
    local col = start_col -- 0-based
    local remaining = range_length

    while remaining > 0 do
        local line = lines[row + 1]
        if col >= #line.cells then
            -- nothing left on this line -- the next character being
            -- deleted is the newline ending it, merging the line below up
            remove_anchor(file_path, lines, row + 2)
            remaining = remaining - 1
        else
            local cell = table.remove(line.cells, col + 1)
            remove_identity(file_path, cell, row, col, false)
            remaining = remaining - 1
        end
    end
end

-- `text` is a list of characters (not a string) to insert, so the caller
-- controls exactly what counts as "one character" (matters for multi-byte
-- codepoints) -- see diff.lua.
local function insert_text(file_path, lines, start_row, start_col, text, new_tag)
    local row = start_row
    local col = start_col

    for _, ch in ipairs(text) do
        local tag = new_tag()
        local line = lines[row + 1]
        local parent = col == 0 and line.anchor or line.cells[col]

        if ch == "\n" then
            local anchor = { id = nil, peer = nil, tag = tag }
            docstate.pending_adds[tag] = anchor

            local moved = {}
            for i = col + 1, #line.cells do
                table.insert(moved, line.cells[i])
            end
            for i = #line.cells, col + 1, -1 do
                table.remove(line.cells, i)
            end

            table.insert(lines, row + 2, { anchor = anchor, cells = moved })
            emit_add(file_path, parent, row, ch, tag)
            row = row + 1
            col = 0
        else
            local cell = { value = ch, id = nil, peer = nil, tag = tag }
            docstate.pending_adds[tag] = cell
            table.insert(line.cells, col + 1, cell)
            emit_add(file_path, parent, row, ch, tag)
            col = col + 1
        end
    end
end

-- `edit`: { row, col, deleted_length, inserted_chars } -- all 0-based,
-- character-indexed. `inserted_chars` is a list of single-character
-- strings (possibly including "\n" entries for inserted newlines).
function M.apply_edit(file_path, lines, edit)
    if edit.deleted_length > 0 then
        remove_range(file_path, lines, edit.row, edit.col, edit.deleted_length)
    end
    if #edit.inserted_chars > 0 then
        insert_text(file_path, lines, edit.row, edit.col, edit.inserted_chars, docstate.new_tag)
    end
end

-- Called once an "ide-add-confirmed" event arrives. Fills in the real
-- identity on the pending cell/anchor and flushes any remove that was
-- waiting on this exact tag.
function M.confirm_add(data)
    local pending = docstate.pending_adds[data.tag]
    if not pending then
        return
    end
    docstate.pending_adds[data.tag] = nil
    pending.id = data.id
    pending.peer = data.peer
    pending.tag = nil

    local waiting = docstate.pending_removals[data.tag]
    if waiting then
        docstate.pending_removals[data.tag] = nil
        emit_remove(waiting.file_path, waiting.row, waiting.col, waiting.is_whole_line, pending.id, pending.peer)
    end
end

return M
