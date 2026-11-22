class_name UiRoute
extends RefCounted
# ------------------------------------------------------------------------------
# The names of the screens.
#
# They live in their own file rather than on UiShell because every screen needs
# to say where it wants to go, and the shell needs to know about every screen:
# putting the constants on the shell would make screens and shell reference each
# other's classes, which GDScript resolves as a cyclic dependency at parse time.
# ------------------------------------------------------------------------------

const TITLE: String = "title"
const CHAMPIONS: String = "champions"
const SHEET: String = "sheet"
const STASH: String = "stash"
const SHOP: String = "shop"
const CAMPAIGN: String = "campaign"
const TRAINING: String = "training"
const QUESTS: String = "quests"
const PARTY: String = "party"
const STORE: String = "store"

## Not a screen: leave the menus and start playing. `arg` is the region index.
const LAUNCH: String = "launch"
