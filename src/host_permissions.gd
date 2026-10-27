class_name HostPermissions
extends RefCounted

# Apollo-family hosts (Apollo, Vibepollo) give full permissions only to the
# first client ever paired; later clients may only view and list apps, so
# launching fails and mouse, keyboard and controller input are dropped. The
# GameStream pairing protocol has no way to ask for more: the user has to
# allow it in the host's web page. Bit values from Apollo's crypto::PERM.
const CONTROLLER := 1 << 8
const MOUSE := 1 << 11
const KEYBOARD := 1 << 12
const LAUNCH := 1 << 26

const _NAMES := [[LAUNCH, "launch apps"], [MOUSE, "mouse"], [KEYBOARD, "keyboard"], [CONTROLLER, "controller"]]

## The permissions Nightfall needs that `permission` lacks; empty when the host
## doesn't report permissions (-1, e.g. Sunshine).
static func missing(permission: int) -> PackedStringArray:
	var result := PackedStringArray()
	if permission < 0:
		return result
	for entry in _NAMES:
		if permission & int(entry[0]) == 0:
			result.append(entry[1])
	return result

static func blocks_launch(permission: int) -> bool:
	return missing(permission).has("launch apps")

## What to tell the user, or "" when nothing is missing.
static func explain(missing_names: PackedStringArray) -> String:
	if missing_names.is_empty():
		return ""
	return ("The host doesn't allow Nightfall: %s. In the host's web page, find this "
		+ "headset under Client Management and allow all permissions. Vibepollo and "
		+ "Apollo give full access only to the first device paired.") % ", ".join(missing_names)
