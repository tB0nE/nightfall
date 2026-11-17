// JXA/AppKit: changes the currently visible Space on each attached screen.
// macOS does not expose a public API to enumerate every inactive Space.
// Pass $() for a nil argument: JXA turns a JS null into NSNull, which AppKit then messages
// (-[NSNull count] for the attributes dictionary).
ObjC.import('AppKit');
ObjC.import('Foundation');
function run(argv) {
    var color = argv[0], owner = argv[1], root = argv[2], image = argv[3];
    var fm = $.NSFileManager.defaultManager;
    fm.createDirectoryAtPathWithIntermediateDirectoriesAttributesError($(root), true, $(), $());
    var path = root + '/host-background.json';
    var ws = $.NSWorkspace.sharedWorkspace;
    function screens() { return $.NSScreen.screens; }
    // Wallpaper options hold an NSColor, which JSON can't carry: deepUnwrap makes it an empty
    // object, and handing that back as the fill colour throws. Keep plain values, rebuild them.
    var SCALING = $.NSWorkspaceDesktopImageScalingKey, CLIP = $.NSWorkspaceDesktopImageAllowClippingKey,
        FILL = $.NSWorkspaceDesktopImageFillColorKey;
    function present(v) { return v && !v.isNil(); }
    function encodeOptions(o) {
        var r = {};
        if (!present(o)) return r;
        var v = o.objectForKey(SCALING); if (present(v)) r.scaling = ObjC.unwrap(v);
        v = o.objectForKey(CLIP); if (present(v)) r.clip = ObjC.unwrap(v);
        v = o.objectForKey(FILL);
        if (present(v)) {
            var c = v.colorUsingColorSpace($.NSColorSpace.sRGBColorSpace);
            if (present(c)) r.fill = [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent];
        }
        return r;
    }
    function decodeOptions(r) {
        var d = $.NSMutableDictionary.dictionary;
        if (r.scaling !== undefined) d.setObjectForKey($.NSNumber.numberWithInteger(r.scaling), SCALING);
        if (r.clip !== undefined) d.setObjectForKey($.NSNumber.numberWithBool(r.clip), CLIP);
        if (r.fill) d.setObjectForKey($.NSColor.colorWithSRGBRedGreenBlueAlpha(r.fill[0], r.fill[1], r.fill[2], r.fill[3]), FILL);
        return d;
    }
    function id(s) { return String(ObjC.unwrap(s.deviceDescription.objectForKey('NSScreenNumber'))); }
    function snapshot() {
        var result = {}, list = screens();
        for (var i=0; i<list.count; i++) {
            var s = list.objectAtIndex(i), url = ws.desktopImageURLForScreen(s);
            if (!url) throw Error('Cannot read desktop wallpaper');
            result[id(s)] = {url:ObjC.unwrap(url.absoluteString), options:encodeOptions(ws.desktopImageOptionsForScreen(s))};
        }
        return result;
    }
    function write(data) {
        var error = Ref();
        if (!$(JSON.stringify(data)).writeToFileAtomicallyEncodingError($(path), true, $.NSUTF8StringEncoding, error))
            throw Error('Cannot save background recovery journal');
    }
    function set(s, state) {
        var error = Ref();
        if (!ws.setDesktopImageURLForScreenOptionsError($.NSURL.URLWithString($(state.url)), s, decodeOptions(state.options), error))
            throw Error('macOS rejected wallpaper update');
    }
    function restore() {
        if (!fm.fileExistsAtPath($(path))) return;
        var saved = JSON.parse(ObjC.unwrap($.NSString.stringWithContentsOfFileEncodingError($(path), $.NSUTF8StringEncoding, $())));
        if (color === 'off' && owner && saved.owner !== owner) return;
        var now = snapshot(), list = screens();
        for(var i=0; i<list.count; i++) {
            var s=list.objectAtIndex(i), key=id(s);
            if(saved.before[key] && now[key].url === saved.after)
                set(s, saved.before[key]);
        }
        fm.removeItemAtPathError($(path), $());
    }
    restore();
    if (color === 'off') return;
    var url = ObjC.unwrap($.NSURL.fileURLWithPath($(image)).absoluteString);
    var before = snapshot();
    if (!Object.keys(before).length) throw Error("No desktop screens available");
    write({owner:owner, before:before, after:url});
    try {
        var list = screens();
        // Scale to fill (NSImageScaleAxesIndependently = 1): a solid colour covers every screen.
        for(var i=0; i<list.count; i++) set(list.objectAtIndex(i), {url:url, options:{scaling:1}});
    } catch(e) { restore(); throw e; }
}
