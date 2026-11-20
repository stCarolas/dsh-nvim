--- One-entry `vim.ui.select` helper shared by the plugin's pickers.
---
--- Labels are rendered by the caller; the selected entry is recovered from the
--- callback's index, so two rows that render the same text still stay
--- distinct. Pickers that only pass the chosen item fall back to label
--- matching.
local M = {}

--- Pick one entry from a label list.
--- @param entries table[]
--- @param label fun(entry: table): string
--- @param opts table `vim.ui.select` options
--- @param on_choice fun(entry: table)
function M.one(entries, label, opts, on_choice)
  local labels = {}
  for index, entry in ipairs(entries) do
    labels[index] = label(entry)
  end

  vim.ui.select(labels, opts, function(choice, index)
    if choice == nil then
      return
    end
    local entry = type(index) == "number" and entries[index] or nil
    if not entry then
      for position, text in ipairs(labels) do
        if text == choice then
          entry = entries[position]
          break
        end
      end
    end
    if entry then
      on_choice(entry)
    end
  end)
end

return M
