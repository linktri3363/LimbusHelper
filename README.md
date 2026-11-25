# Limbus Helper

A Windower addon for FFXI that tracks the treasure chests in Apollyon and Temenos.
Each zone has four chest sectors. Opening one gives either the standard reward
(3,000 units) or the bonus reward (5,000 units). LimbusHelper shows which sectors
you've opened, highlights the bonus, and resets 5 seconds after a bonus so you can
start looking for the next one.

Chests are detected automatically from the "Acquired ... Units" message, using your
position to work out which sector's chest you opened. Rewards from anything that
isn't near a chest (such as a ???) are ignored.

## Installation

1. Create the directory `[path/to/windower]/addons/LimbusHelper`
2. Place `LimbusHelper.lua` inside it
3. In game: `//lua load limbushelper`

To load the addon at startup, add the line `lua load limbushelper` to
`[path/to/windower]/scripts/init.txt`.

## Overlay

The overlay appears automatically in Apollyon and Temenos.

- **Red** - Unopened
- **Green** - Opened (standard reward)
- **Gold** - Bonus

Drag the overlay to move it; its position is saved.

## Commands

`//lh` and `//limbushelper` both work.

| Command | Description |
| --- | --- |
| `//lh help` | Show the command list |
| `//lh reset [apollyon\|temenos\|all]` | Reset tracking. With no argument, resets the zone you're in (or both, outside Limbus) |
| `//lh sector <sector>` | Toggle a sector between Opened and Unopened |
| `//lh sector <sector> <3000\|5000>` | Log a chest result by hand (5000 logs a bonus) |
| `//lh pos` | Print your position, detected sector and distance to its chest |
| `//lh show` / `//lh hide` | Show or hide the overlay outside Limbus |
| `//lh debug` | Toggle logging of all incoming text, for troubleshooting |

Sectors: Apollyon `NW NE SW SE`, Temenos `N W E C`.

## Data

Progress is saved per character in `data/state_<CharName>.xml`, so several
characters running at once never overwrite each other. Display settings are in
`data/settings.xml`. Both are created automatically.

## Credits

Created by Kaius @ Bahamut and Linktri @ Asura.
