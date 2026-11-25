# Warehouse

**Find any item on any of your characters.**

Warehouse remembers what each of your characters holds: their bags, bank, guild bank, mailbox and the gear they're wearing. Search all of it from any character, and see exactly where every stack is.

## Features

- Saves your bags, equipped gear and gold automatically on every character
- Saves your bank, guild bank and mailbox each time you open them
- Reads every guild bank tab you're allowed to view, without clicking through them
- Items you mail to your own characters show up in their mailbox straight away
- Searches item names, item types and tooltip text: stats, effects, armor and weapon types
- Filters by region, ruleset, faction, character, guild bank and guild bank tab
- Shows only bags, banks, guild banks, mail or equipped gear, in any combination
- Groups items by item type, location, character or quality
- Sorts by name, amount held, item level, quality, vendor value and more
- Shows who holds an item, with a bar per character split by location
- Adds a list of who holds an item to item tooltips everywhere in the game
- Warns you at login when mail is about to expire
- Tracks gold on every character, in the mail and in guild banks
- Minimap button and addon compartment entry

## Requirements

- World of Warcraft: Forever

## Installation

1. Close the game.
2. Copy the `Warehouse` folder into:

   ```
   World of Warcraft\_forever_\Interface\AddOns\
   ```

3. Start the game. If Warehouse isn't in the AddOns list on the character screen, close the game completely and start it again.

## Getting started

1. Log in on each of your characters once. Their bags, gear and gold are saved straight away.
2. On each character, open the bank, the mailbox and (if you're in a guild) the guild bank once.
3. Type `/warehouse`, or click the minimap button, and search.

From then on, everything stays up to date as you play.

## The Items tab

**Search box.** Type part of an item's name, its type (such as "cloth" or "two-hand"), or anything from its tooltip (such as "stamina"). Every word must match. Put a phrase in quotes to match it exactly: `"chance on hit"`. A number on its own finds that item ID. With the search box selected, shift-click an item in your bags to search for it.

**Filter button.**
- **Sort by:** name, total held, characters holding it, item level, quality, vendor value, or recently saved.
- **Group by:** item type, location, character, quality, or nothing. Click a group's bar to open or close it.
- **Show:** search item tooltips; only items held in two or more places (handy for gathering stacks onto one character); only mail that expires soon.
- **Quality:** any, uncommon and better, rare and better, or epic and better.

**Filter buttons under the search box.** A highlighted button means that filter is on.
- **Region:** US or EU. US includes Oceanic players.
- **Ruleset:** PvE or PvP, plus RP or Hardcore if you have characters there, and Not read yet for characters you haven't logged in on since installing Warehouse.
- **Faction:** Horde or Alliance.
- **Characters:** everyone, only the character you're playing, only characters on the same ruleset, or one character you pick.
- **Guild banks:** each saved guild bank with its tabs. Untick any to leave them out.

**Location buttons** (top right): **All**, **Bags**, **Bank**, **Guild**, **Mail** and **Worn**. From All, clicking a location shows only that location; click others to add them back.

**The right-hand side** shows the selected item:
- **Who holds it:** a bar per character and guild bank, split by location. Hover a bar for the numbers; click it to show only that character's or guild bank's items.
- **Summary:** the total, who holds it, how many are in bags, banks, guild banks, mail and equipped, and what a vendor would pay for all of them.
- **Where it is:** every stack, with when it was saved. Mail shows when it expires.

Click the item again to go back to the overview of everything. Shift-click an item to link it in chat.

## The Characters tab

- **Characters:** every saved character, with ruleset, region, faction, gold and when they were last seen. Click one to show only their items. Right-click to forget a character you no longer play.
- **Guild banks:** each saved guild bank, its gold, and how many tabs are saved. Click one to show only its items. Right-click to forget it.
- **Gold:** on your characters, waiting in the mail, in guild banks, all together, and by region.

## The Options tab

- **Saving:** read every guild bank tab when it opens; add mail you send to your own characters to their mailbox; print a line in chat after saving a bank, guild bank or mailbox; **Save Now**.
- **Item tooltips:** show who holds an item, and which characters to include (this ruleset, this region, or everywhere).
- **Mail:** warn at login about mail that expires soon, and how many days count as soon (1, 3 or 7).
- **Display:** show or hide the minimap button; search item tooltips.
- **Storage:** how much Warehouse has saved.
- **This character:** its region, faction and ruleset.
- **Client:** which game features Warehouse found. Useful when reporting a problem.

## Item tooltips

Hover any item in the game to see how many each of your characters and guild banks holds, by location. The character you're playing is listed first. Turn this off, or change which characters are included, on the Options tab.

## Commands

| Command | What it does |
|---|---|
| `/warehouse` | open or close the window |
| `/warehouse <text>` | open the window and search |
| `/warehouse count <item>` | print who holds an item (name, item ID or shift-clicked link) |
| `/warehouse chars` | list your characters, their gold and when each was last seen |
| `/warehouse scan` | save your bags and gear now, and any bank, guild bank or mailbox you have open |
| `/warehouse forget <first name and surname>` | forget a character (asks first) |
| `/warehouse expiring` | list mail that expires soon on every character |
| `/warehouse characters` | open the Characters tab |
| `/warehouse options` | open the Options tab |
| `/warehouse minimap` | show or hide the minimap button |
| `/warehouse reset` | move the window back to the middle of the screen |
| `/warehouse probe` | list which game features Warehouse found |
| `/warehouse help` | list these commands in game |

## Troubleshooting

**A character's bank is empty.** The bank is saved while it's open. Open it once on that character.

**Some guild bank tabs are missing.** Tabs your rank can't view aren't saved. If a tab you can view is missing, click it once, or turn on **Read every guild bank tab** on the Options tab.

**Items show as "Item #12345".** The name is still loading from the game and appears after a moment.

**A character shows "ruleset not read yet".** Log in on that character once.

**Nothing was saved after logging in.** Saving waits until you leave combat. If the game didn't give Warehouse the character's details, Warehouse says so in chat; type `/reload` to try again.

**The window is off the screen.** Type `/warehouse reset`.

**The minimap button is gone.** Type `/warehouse minimap`.

**Reporting a problem.** Type `/warehouse probe` and include what it lists, along with what you were doing when the problem happened.

## Credits

Made by MendeleevForever.

Warehouse includes these libraries, with their licences in the `Libs` folder: LibStub and CallbackHandler-1.0 (Ace3 licence), LibDataBroker-1.1 and LibDBIcon-1.0.

World of Warcraft is a trademark of Blizzard Entertainment. Warehouse is not made by or affiliated with Blizzard Entertainment.
