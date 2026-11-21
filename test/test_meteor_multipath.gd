extends SceneTree

# The client may only open a second network path when the stream goes through
# a Meteor that copies every packet to both (a plain host follows whichever
# path pinged last).
func _init() -> void:
	assert(MeteorClient.multipath_supported({"multipath": {"protocol": 1}}))
	assert(MeteorClient.multipath_supported({"multipath": {"protocol": 2}}))
	assert(not MeteorClient.multipath_supported({}), "no Meteor (plain Sunshine) = one path")
	assert(not MeteorClient.multipath_supported({"service": "nightfall-meteor", "protocol": 1}), "an older Meteor = one path")
	assert(not MeteorClient.multipath_supported({"multipath": {}}))
	assert(not MeteorClient.multipath_supported({"multipath": true}))
	print("All Meteor multipath discovery tests passed")
	quit()
