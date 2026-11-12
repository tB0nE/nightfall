// JXA/AppKit: changes the currently visible Space on each attached screen.
// macOS does not expose a public API to enumerate every inactive Space.
ObjC.import('AppKit');
ObjC.import('Foundation');
function run(argv) {
    var color = argv[0], owner = argv[1], root = argv[2], image = argv[3];
    var fm = $.NSFileManager.defaultManager;
    fm.createDirectoryAtPathWithIntermediateDirectoriesAttributesError($(root), true, null, null);
    var path = root + '/host-background.json';
    var ws = $.NSWorkspace.sharedWorkspace;
    function screens() { return $.NSScreen.screens; }
    function id(s) { return String(ObjC.unwrap(s.deviceDescription.objectForKey('NSScreenNumber'))); }
    function snapshot() {
        var result = {}, list = screens();
        for (var i=0; i<list.count; i++) {
            var s = list.objectAtIndex(i), url = ws.desktopImageURLForScreen(s);
            if (!url) throw Error('Cannot read desktop wallpaper');
            result[id(s)] = {url:ObjC.unwrap(url.absoluteString), options:ObjC.deepUnwrap(ws.desktopImageOptionsForScreen(s))};
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
        if (!ws.setDesktopImageURLForScreenOptionsError($.NSURL.URLWithString($(state.url)), s, $(state.options), error))
            throw Error('macOS rejected wallpaper update');
    }
    function restore() {
        if (!fm.fileExistsAtPath($(path))) return;
        var saved = JSON.parse(ObjC.unwrap($.NSString.stringWithContentsOfFileEncodingError($(path), $.NSUTF8StringEncoding, null)));
        if (color === 'off' && owner && saved.owner !== owner) return;
        var now = snapshot(), list = screens();
        for(var i=0; i<list.count; i++) {
            var s=list.objectAtIndex(i), key=id(s);
            if(saved.before[key] && now[key].url === saved.after)
                set(s, saved.before[key]);
        }
        fm.removeItemAtPathError($(path), null);
    }
    restore();
    if (color === 'off') return;
    var url = ObjC.unwrap($.NSURL.fileURLWithPath($(image)).absoluteString);
    var before = snapshot();
    if (!Object.keys(before).length) throw Error("No desktop screens available");
    write({owner:owner, before:before, after:url});
    try {
        var list = screens();
        for(var i=0; i<list.count; i++) set(list.objectAtIndex(i), {url:url, options:(function(){var o={};o[ObjC.unwrap($.NSWorkspaceDesktopImageScalingKey)]=1;return o;})()});
    } catch(e) { restore(); throw e; }
}
