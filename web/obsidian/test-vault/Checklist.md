# Checklist

The plugin's checks on Obsidian for iPhone and iPad, done by hand (D452). On the Mac they
run by themselves: `web/e2e/obsidian.spec.ts` opens a copy of this vault in a throwaway
Obsidian.

## Set up

On the Mac, copy this vault into Obsidian's iCloud folder and install the plugin into the
copy, as a reader would by hand:

```bash
cp -R web/obsidian/test-vault ~/Library/Mobile\ Documents/iCloud~md~obsidian/Documents/OpenNexus\ test
```

```bash
scripts/release-obsidian.sh --install ~/Library/Mobile\ Documents/iCloud~md~obsidian/Documents/OpenNexus\ test
```

On the iPhone or iPad, open the vault "OpenNexus test" in Obsidian and trust it when asked
(or Settings › Community plugins › Turn on community plugins). OpenNexus is listed and on.

## Check

- [ ] **Maps/Launch plan** opens as a map. Drag to pan, pinch to zoom, tap a topic for its
  details.
- [ ] Its **Roadmap** tab shows the second canvas.
- [ ] In the root topic's note, **Risks** opens Notes/Risks; **the budget** says there's no
  such note.
- [ ] **Channels**' link opens Notes/Risks.
- [ ] **Maps/Plan.nexus**: long-press the folder, then Open as OpenNexus map. (If the
  folder isn't listed, write that down: iCloud may treat it as a document where OpenNexus is
  installed.)
- [ ] **Maps/Plain** shows its outline and how to save a viewer copy (there's no `nexus`
  tool on iOS).
- [ ] **Embeds**, in Reading view and in Live Preview: four maps (the whole plan, the
  Roadmap canvas, Pricing framed with its branch, the package), then three messages.
- [ ] **Long note**: the map at the end appears as you scroll to it.
- [ ] **Trip**: Show this note as a map shows the note's outline; tapping a line puts the
  cursor on it.
- [ ] Insert map as outline, in a new note, writes Launch plan's topics as a list.
- [ ] Copy link to topic on a map, paste the link into a note and tap it: the map opens at
  that topic.
- [ ] **Crafted** and **Maps/Crafted**: the map shows; no alert, nothing opens by itself, and
  its links only show notices or open Notes/Risks.
- [ ] Edit in OpenNexus isn't offered.
- [ ] Switch Obsidian between light and dark: the map's bar and panels follow.
- [ ] Turn the plugin off: map tabs say the plugin is no longer active, and the maps in notes
  are gone.

Write what you find under A2 in `docs/plans/M49.md`.
