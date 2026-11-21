# Warehouse

A searchable database of your characters' bags, personal banks, guild banks and mailboxes.

"Which alt has the Silk Cloth?" Warehouse remembers what every character holds, so you can search all of it from any character, filter by region, ruleset and faction, and see exactly where each stack is.

## Features

- Saves bags, equipped gear and gold on every character, automatically
- Saves the personal bank, guild bank and mailbox each time you open them
- Reads every guild bank tab you can view, without clicking through them
- Mail you send to your own characters shows in their mailbox at once ("on its way")
- Search names, item types and everything in an item's tooltip: stats, effects, slots
- Filter by **Region** (US, EU), **Ruleset** (PvE, PvP), **Faction** (Horde, Alliance) and character
- Show only bags, banks, guild banks, mail or equipped gear, in any combination
- Group items by item type, location, character or quality, under bars you can open and close
- Sort by name, total held, how many characters hold it, item level, quality, vendor value or when it was saved
- A bar per character showing who holds the selected item, split by location
- Item tooltips everywhere in the game show who holds the item
- A warning at login when saved mail is about to expire
- Shift-click an item to link it in chat
- Minimap button and an entry in the addon compartment

## Requirements

- World of Warcraft: Forever

## Installation

Copy the `Warehouse` folder into:

```
World of Warcraft\_forever_\Interface\AddOns\
```

On the beta client the folder is `World of Warcraft\_classic_beta_\Interface\AddOns\`.

If Warehouse doesn't show up in the AddOns list, restart the game completely.

## Getting started

1. Log in on each character once. Bags, gear and gold are saved straight away.
2. On each character, open the bank, the mailbox and (if you're in a guild) the guild bank once.
3. Type `/warehouse` and search.

From then on, everything updates as you play.

## Region and ruleset

World of Warcraft: Forever has no realm list: each region has one realm per ruleset, and character names (first name and surname) are unique across a region. Warehouse files each character by region and full name, and reads its region, ruleset and faction from the game at each login, so the filters work.

**Region** is the one the game reports: US or EU (or Other, for Korea, Taiwan and China). US includes Oceanic players, who share the US world and auction house.

**Ruleset.** Warehouse reads each character's ruleset from the game's own rules every time it logs in: Hardcore, Roleplay, PvP, Roleplay PvP (both the Roleplay and PvP rules on) or Normal (none of them). Characters on the same server that haven't logged in since share the answer. If the game can't say, Warehouse asks once: type `/warehouse ruleset normal` (or `pvp`, `rp`, `rppvp`, `hardcore`), or right-click the character on the Characters tab. The Ruleset filter groups Normal, Roleplay and Hardcore as **PvE**, and PvP and Roleplay PvP as **PvP**.

**Faction** is read from the game at each login.

## The window

**Items tab**
- Search box: finds items by name, item type and anything in their tooltip (see Searching below).
- **Filter**: sort, group, search tooltips, only items in 2 or more places, only mail expiring soon, minimum quality, open or close every group.
- **Region**, **Ruleset**, **Faction** and **Characters**: a highlighted button means that filter is on.
- Location buttons above the right side: **All**, **Bags**, **Bank**, **Guild**, **Mail**, **Worn**. From All, clicking a location shows only that location; click others to add them.
- On the right: who holds the selected item (hover a bar for each location, click it to show only that character), a summary with the vendor value, and every stack with when it was saved. Click the item again to go back to the overview of everything.

**Characters tab**
- Every character with ruleset, region, faction, gold and when they were last seen. Click one to show only their items; right-click to change their region or ruleset, or forget them.
- **Realms**: the servers your characters are on (shown by server number, since Forever hides realm names), with the ruleset the game reported. If the game couldn't say, set it here for every character on that server.
- **Guild Banks**: which tabs are saved and when. Right-click to forget one.
- **Gold**: on characters, waiting in mail, in guild banks, and by region.

**Options tab**
- **Saving**: read every guild bank tab; add mail sent to your characters to their mailbox; chat lines after saving; **Save Now**.
- **Item Tooltips**: show who holds an item, and which characters to show (this ruleset, this region or everywhere).
- **Mail**: the login warning, and how many days count as "soon".
- **Display** and search settings, **Storage** used, **This Character** (region and ruleset) and **Client** (which game features Warehouse found).

## Searching

- Every word you type must match, in any order: `cloth leg` finds cloth leggings.
- Put a phrase in quotes to match it exactly: `"chance on hit"`.
- A number on its own finds the item with that item ID.
- With the search box selected, shift-click an item in your bags to search for it.

Tooltips are read in the background the first time you search in a session; the line under the title shows the progress.

## Commands

| Command | What it does |
|---|---|
| `/warehouse` | open or close the window |
| `/warehouse <text>` | open the window and search |
| `/warehouse count <item>` | print who holds an item (name, item ID or shift-clicked link) |
| `/warehouse chars` | list your characters, their gold and when each was last seen |
| `/warehouse ruleset <normal, pvp, rp, rppvp or hardcore>` | set this character's ruleset, if the game can't say |
| `/warehouse scan` | save your bags and gear now (and any open bank, guild bank or mailbox) |
| `/warehouse forget <first name and surname>` | forget a character (asks first) |
| `/warehouse expiring` | list mail that expires soon on every character |
| `/warehouse characters` | open the Characters tab |
| `/warehouse options` | open the Options tab |
| `/warehouse minimap` | show or hide the minimap button |
| `/warehouse reset` | move the window back to the middle of the screen |
| `/warehouse probe` | check which game features Warehouse found |
| `/warehouse help` | list these commands in game |

## Troubleshooting

**A character's bank is empty in Warehouse.** The bank is only saved while it's open. Open it once on that character.

**Some guild bank tabs are missing.** Tabs you can't view aren't saved. If tabs you can view are missing, click through them once, or check **Read every guild bank tab** on the Options tab.

**Items show as "Item #12345".** The name is loaded from the server and appears after a short while.

**Nothing was saved after logging in.** Saving waits until combat ends. If the game hides the character's name, Warehouse uses the name it saved for that character last time; for a character it has never seen, it tries for 30 seconds. Type `/warehouse probe`: the **Character**, **Name**, **Faction**, **Ruleset** and **Realm** lines show what the game told Warehouse.

**A character's gold shows 0.** Warehouse 0.1.0 and 0.1.1 saved 0 gold when a character logged out, because the game reports 0 to addons while logging out. Log into that character once with 0.1.2 or later and its gold is saved correctly.

**"Ruleset not set" on a character.** Log in on that character once; the ruleset is read from the game. If the game can't say (the **Ruleset** line of `/warehouse probe` tells you), right-click the character on the Characters tab, or type `/warehouse ruleset normal` (or pvp, rp, rppvp, hardcore).

**Saved data disappeared between sessions.** Early beta builds lost saved addon data; if it happens on the live client, check that the game closes normally.

**Something stopped working after a game update.** Type `/warehouse probe` and include what it shows when you report the problem.

## Credits

Made by MendeleevForever. Warehouse is not made by or affiliated with Blizzard Entertainment.

Warehouse includes these libraries, with their licences in the `Libs` folder:

- LibStub and CallbackHandler-1.0 (Ace3 licence)
- LibDataBroker-1.1 and LibDBIcon-1.0
