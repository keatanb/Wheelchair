# **Wheelchair**

Full wheelchair mode looter mod that tracks items to be vendored.
- Automatically (by configurable class based rules, default all grays)
- Manually (by configurable bind, default ctrl-rclick) 
- Trashes a marked sell item in bag to replace with a more valuable or quest item if bags are full.

Alerts in standard blizzard error frame floating text when 3 or less bag slots are remaining.

_This addon uses Peddler as a base with fixes,modifications,additions and performance enhancements - running Peddler at the same time can cause some crazy behaviour_

## Enhancements over Peddler :
- FastLooting (bypass the Classic autoloot slowness without crashing the client)  
- Enhanced marked item tracking (moving or deleting items in bags causes old Peddler marks to go nuts in the container slots) 
- Automatically trash least valuable item stack to replace with more valuable (or quest required) lootable item 
- Alerts on low bag space
- Improved auto-vendor logic 

## Future Features
- Extend class based vendor logic to include stat weight based autoequip and vendor marking
- Display item score based on configured stat weights 
- Display vendor and stack prices on tooltips (use BVP or VP for now)