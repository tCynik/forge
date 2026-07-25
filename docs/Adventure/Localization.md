Adventure mode content (quest names, dialogue, item/enemy/shop descriptions, point-of-interest
names) can be translated independently of both the main UI language files and the card
database's own translation system. This page covers how that works and how to add a
translation for a plane.

## The two pieces of a translatable field

A translatable field on a plane's JSON data (`res/<AdventureName>/world/*.json`) always comes
in a pair: the field itself, holding the original (English) text, and a second field
referencing a translation key. The original field is never removed or edited when adding a
translation - it stays as the fallback for any language (including English itself) that has no
matching entry.

```json
{
	"id": 28,
	"name": "Entering Shandalar",
	"locName": "adv.shandalar.q28.name",
	"description": "Learn about your surroundings.",
	"locDescription": "adv.shandalar.q28.desc",
	"prologue": {
		"text": "Darkness and silence surrounds you...",
		"loctext": "adv.shandalar.q28.prologue.text",
		"options": [
			{
				"name": "Where am I? What am I? What is going on?",
				"locname": "adv.shandalar.q28.prologue.opt1.name"
			}
		]
	}
}
```

**Watch the field name casing** - it isn't consistent between data types, and using the wrong
one will silently do nothing (the field is just ignored, no error):

| Data class | Field | Loc field |
|---|---|---|
| `AdventureQuestData` (quest name/description) | `name` / `description` | `locName` / `locDescription` |
| `AdventureQuestStage` (quest stage name/description) | `name` / `description` | `locName` / `locDescription` |
| `PointOfInterestData` (town/dungeon display name) | `displayName` | `locDisplayName` |
| `ItemData` (item name/description) | `name` / `description` | `locName` / `locDescription` |
| `EnemyData` (enemy name, boss intro/insult) | `name` / `bossIntro` / `bossInsult` | `locName` / `locBossIntro` / `locBossInsult` |
| `ShopData` (shop name/description) | `name` / `description` | `locName` / `locDescription` |
| `DialogData` (any dialogue node: prologue, epilogue, offer/decline dialogs, and every button option) | `text` / `name` | `loctext` / `locname` **(lowercase, no other field in the table is)** |

## Where translations live

Each plane gets its own translation file per language, so translators working on different
planes (or different languages) never collide in the same file:

```
res/languages/adventure-<plane, lowercase, spaces as underscores>-<locale>.properties
```

For example Shandalar's Russian translation is
`res/languages/adventure-shandalar-ru-RU.properties`. Inside, it's an ordinary Java properties
file mapping each loc key to the translated string:

```properties
adv.shandalar.q28.name=Прибытие в Шандалар
adv.shandalar.q28.desc=Узнайте больше об окружающем мире.
adv.shandalar.q28.prologue.text=Вокруг вас тьма и тишина...
adv.shandalar.q28.prologue.opt1.name=Где я? Кто я? Что происходит?
```

Loc key names themselves aren't interpreted by the game - use whatever convention keeps them
unique and readable; `adv.<plane>.<quest id>.<field path>` is what the existing content uses.

## Adding a translation to an existing plane

1. If `res/languages/adventure-<plane>-<locale>.properties` doesn't exist yet, create it.
2. For each string you want to translate, add a `loc*` field next to the original field in the
   plane's JSON (see the table above for the right field name), pointing at a key of your
   choosing.
3. Add that key to the properties file with the translated text.
4. You don't have to translate everything at once. Anything without a `loc*` field, or whose
   key isn't in the properties file for the active language, just falls back to the original
   (untranslated) field - never an error, never blank text.

## Adding a brand-new language

No code changes are needed to add a language to a plane that already has at least one
translation - just create the new `adventure-<plane>-<locale>.properties` file with the same
keys. Adding the *first* translation to a given locale for the main UI (not Adventure content)
is a separate, larger effort - see the existing `res/languages/<locale>.properties` files and
`forge/util/lang/Lang*.java` for pluralization rules.

## What this system does *not* cover

Card names and Oracle text - including the ~90 custom cards under
`res/adventure/common/custom_cards/`, since they're ordinary card scripts - go through Forge's
separate, pre-existing card translation system (`forge-core/src/main/java/forge/util/CardTranslation.java`,
`res/languages/cardnames-<locale>.txt`). That system is keyed by exact card name and applies
across every game mode, not just Adventure - it isn't something this page's mechanism talks to.
