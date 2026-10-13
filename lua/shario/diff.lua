-- Converts Neovim's line-range-based buffer change notifications
-- (`nvim_buf_attach`'s `on_lines`) into the single character-level edit
-- `ops.lua` expects -- the same role VS Code's own `{range, rangeLength,
-- text}` change events play for shario-vscode, which Neovim doesn't hand
-- you directly.
--
-- `on_lines` only reports *which lines* changed, not what changed within
-- them, so the actual character-level edit has to be computed by diffing:
-- the common prefix and common suffix between the old and new text for
-- the affected lines is found, and whatever's left in the middle is the
-- real edit (common technique -- this is the same approach Neovim's own
-- LSP client uses to turn on_lines into incremental sync notifications).
local docstate = require("shario.docstate")

local M = {}

-- Renders lines[from..to] (1-based, inclusive, from docState) back into a
-- single newline-joined string, matching how Neovim would represent the
-- same text.
local function render(lines, from, to)
    local parts = {}
    for i = from, to do
        local line = lines[i]
        local chars = {}
        for _, cell in ipairs(line.cells) do
            table.insert(chars, cell.value)
        end
        table.insert(parts, table.concat(chars))
    end
    return table.concat(parts, "\n")
end

-- Converts a character offset within a `render()`-style joined string back
-- into a 0-based {row, col} position, relative to `base_row` (the 0-based
-- row the joined string's first line corresponds to).
local function offset_to_pos(char_list, offset, base_row)
    local row = base_row
    local col = 0
    for i = 1, offset do
        if char_list[i] == "\n" then
            row = row + 1
            col = 0
        else
            col = col + 1
        end
    end
    return row, col
end

-- `old_lines`: this buffer's docState *before* the edit (still reflects
-- the pre-edit text, since docState is only mutated by ops.apply_edit).
-- `firstline`/`lastline`/`new_lastline`: straight from `on_lines`, 0-based,
-- end-exclusive.
--
-- Returns an edit table ({row, col, deleted_length, inserted_chars}) or
-- nil if the two sides turned out identical (on_lines can fire for
-- changes that net out to no actual text difference).
function M.compute_edit(bufnr, old_lines, firstline, lastline, new_lastline)
    local old_text = render(old_lines, firstline + 1, lastline)
    local new_buf_lines = vim.api.nvim_buf_get_lines(bufnr, firstline, new_lastline, false)
    local new_text = table.concat(new_buf_lines, "\n")

    local old_chars = docstate.chars(old_text)
    local new_chars = docstate.chars(new_text)

    local max_common = math.min(#old_chars, #new_chars)
    local prefix_len = 0
    while prefix_len < max_common and old_chars[prefix_len + 1] == new_chars[prefix_len + 1] do
        prefix_len = prefix_len + 1
    end

    local max_suffix = max_common - prefix_len
    local suffix_len = 0
    while
        suffix_len < max_suffix
        and old_chars[#old_chars - suffix_len] == new_chars[#new_chars - suffix_len]
    do
        suffix_len = suffix_len + 1
    end

    local deleted_length = #old_chars - prefix_len - suffix_len
    local inserted_chars = {}
    for i = prefix_len + 1, #new_chars - suffix_len do
        table.insert(inserted_chars, new_chars[i])
    end

    if deleted_length == 0 and #inserted_chars == 0 then
        return nil
    end

    local row, col = offset_to_pos(old_chars, prefix_len, firstline)

    return {
        row = row,
        col = col,
        deleted_length = deleted_length,
        inserted_chars = inserted_chars,
    }
end

return M
