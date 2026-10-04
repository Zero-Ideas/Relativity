# Studio spell-card persistence

This local plugin stores test spell books in Studio plugin settings, isolated
by place and player ID. It never accesses the production DataStore. Names in
local test cards are not filtered; published-game saves still require filtering.

Install/update with:

```powershell
rojo build studio-spells.project.json -o "$env:LOCALAPPDATA/Roblox/Plugins/RelativitySpellCards.rbxm"
```

If Studio does not reload the new local plugin automatically, reopen Studio.
The server will report `Local Studio spell-card persistence ready.` when active.
Without the plugin, saving is explicitly unavailable rather than claiming that
a session-only card is persistent. The plugin is not part of the Rojo game build.
