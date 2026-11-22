class_name MapShape
extends RefCounted
# ------------------------------------------------------------------------------
# WHAT SHAPE A MAP IS, as opposed to what colour it is.
#
# The campaign had a hundred maps and one floor plan. Biome.gd gave each of them
# a palette, a sky, a fog and a prop vocabulary, so map 4 and map 84 looked
# nothing alike — and played identically. Every single one was built as
# `Kind.LANE, 384 cells, 11 nodes`, because Play.gd passed those literals and
# nothing ever varied them. Repainting a corridor does not make a second
# corridor.
#
# So a map now has a FORM as well as a palette, and the form changes what the
# player actually does:
#
#   * LANE forms are a spine — walk forward, fight through, boss at the end.
#     Readable, and the right shape for a campaign's backbone.
#   * ARENA forms are Layout's graph — rooms joined by paths, with loops and
#     side rooms, so there is a route to choose and a flank to be caught on.
#
# and within each, the SIZE and the NODE COUNT decide whether it reads as a
# tight warren or an open field. Those two numbers do more for how a map feels
# than any amount of scenery.
#
# EVERYTHING IS DERIVED FROM THE MAP INDEX. Map 37 of a campaign is the same
# shape every time anyone plays it, on any device, with no extra state to save —
# the same property the biome and the dread curve already have. No RNG here on
# purpose: a shuffled shape would make "that awful narrow one" unshareable.
#
# COST IS BOUNDED. Generation is a background thread but it is still seconds on
# a phone, and cells are quadratic: 448 is about 1.4x the work of 384, and the
# ceiling exists so a "big" map is a change of pace rather than a loading
# screen. shapetest.gd holds the bounds.
# ------------------------------------------------------------------------------

## Smallest and largest region we will generate, in walk cells at 0.5 m each.
## 288 cells is 144 m of ground; 448 is 224 m.
const CELLS_MIN: int = 288
const CELLS_MAX: int = 448

## Layout node counts that still produce a connected, readable graph.
const NODES_MIN: int = 7
const NODES_MAX: int = 17


## The forms, in the order they rotate through an act.
##
## Deliberately a short list that repeats rather than a hundred bespoke
## entries: a player should start recognising "this is a warren" by act three,
## because recognising it is what lets them play it differently.
static func forms() -> Array[Dictionary]:
	return [
		{
			"id": "spine", "name": "Spine",
			"kind": Terrain.Kind.LANE, "cells": 384, "nodes": 11,
			"blurb": "A road forward, and whatever is standing on it.",
		},
		{
			"id": "warren", "name": "Warren",
			# Many nodes in a small area: short sightlines, constant corners,
			# nowhere to kite. Melee champions' best map and archers' worst.
			"kind": Terrain.Kind.ARENA, "cells": 304, "nodes": 16,
			"blurb": "Close walls and too many corners.",
		},
		{
			"id": "causeway", "name": "Causeway",
			# The longest lane: a march, with the pack spread down it.
			"kind": Terrain.Kind.LANE, "cells": 448, "nodes": 9,
			"blurb": "A long way across open ground.",
		},
		{
			"id": "crossroads", "name": "Crossroads",
			# A graph with real loops — the first form where the route is a
			# decision rather than a direction.
			"kind": Terrain.Kind.ARENA, "cells": 384, "nodes": 13,
			"blurb": "Paths that meet, and meet again.",
		},
		{
			"id": "hollow", "name": "Hollow",
			# Few nodes, generous ground: open fighting, room to kite, the
			# map where a ranged build finally gets to breathe.
			"kind": Terrain.Kind.ARENA, "cells": 352, "nodes": 7,
			"blurb": "Open ground, and nothing to hide behind.",
		},
		{
			"id": "gauntlet", "name": "Gauntlet",
			# A tight lane. Short, dense, no detours.
			"kind": Terrain.Kind.LANE, "cells": 320, "nodes": 8,
			"blurb": "Narrow, and it only goes one way.",
		},
	]


## The grander form an act ends on.
##
## Act finales were structurally identical to the nine maps before them, which
## is a strange thing for the map a player has been climbing towards. This one
## is the largest arena we build.
static func finale() -> Dictionary:
	return {
		"id": "colosseum", "name": "Colosseum",
		"kind": Terrain.Kind.ARENA, "cells": CELLS_MAX, "nodes": 9,
		"blurb": "Ground made for an audience.",
	}


## The shape of map [index].
##
## The rotation is offset by the act so act 2 does not open on the same form
## act 1 did — with six forms and ten maps per act, a plain `index % 6` would
## line every act up the same way, and the repetition would be the thing the
## player noticed instead of the variety.
static func at(index: int) -> Dictionary:
	var i: int = clampi(index, 0, Campaign.map_count() - 1)
	var stage: int = Campaign.stage_in_act(i)
	if stage == Campaign.maps_per_act() - 1:
		return finale()
	var all: Array[Dictionary] = forms()
	var act: int = Campaign.act_of(i)
	return all[(stage + act) % all.size()]


## Convenience readers, so callers do not key into the dictionary by hand.
static func kind_at(index: int) -> int:
	return int(at(index).get("kind", Terrain.Kind.LANE))


static func cells_at(index: int) -> int:
	return clampi(int(at(index).get("cells", 384)), CELLS_MIN, CELLS_MAX)


static func nodes_at(index: int) -> int:
	return clampi(int(at(index).get("nodes", 11)), NODES_MIN, NODES_MAX)


static func name_at(index: int) -> String:
	return String(at(index).get("name", "Spine"))


static func blurb_at(index: int) -> String:
	return String(at(index).get("blurb", ""))
