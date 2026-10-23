extends SceneTree

func _init():
	var bundled := WebApps.load_apps()
	assert(bundled.size() >= 5, "the bundled list loads")
	var ids := bundled.map(func(app): return app["id"])
	assert(ids.has("youtube") and ids.has("webrcade"))
	for app in bundled:
		assert(String(app["url"]).begins_with("https://"))
	assert(bundled[0]["user_agent"].contains("TV"), "YouTube asks for its TV interface")

	var parsed := WebApps.parse('[{"id":"a","name":"A","url":"https://a.example/"},' +
		'{"id":"b","name":"B","url":"http://insecure.example/"},' +
		'{"id":"","name":"C","url":"https://c.example/"},' +
		'{"id":"d","name":"D","url":"javascript:alert(1)"}, 7]')
	assert(parsed.size() == 1 and parsed[0]["id"] == "a", "only valid https entries")
	assert(parsed[0]["user_agent"] == "")
	assert(WebApps.parse("not json").is_empty())
	assert(WebApps.load_apps("res://missing.json").is_empty())
	print("All web_apps tests passed")
	quit()
