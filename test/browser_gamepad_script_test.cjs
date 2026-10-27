// Runs the actual injected script, not a separate implementation of the bridge.
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const source = fs.readFileSync(process.argv[2], 'utf8');
const state = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
let time = 100, pending, messages = 0;
const events = [];
const physical = {id: 'Physical Xbox', index: 0};
const bridge = {postMessage(message) { assert.equal(message, 'poll'); messages++; }};
const context = {navigator: {getGamepads: () => [physical, null, null, null]}, NightfallQuestPad: bridge,
    document: {},
    performance: {now: () => time}, Event: class {constructor(type) {this.type = type;}},
    dispatchEvent: e => events.push(e), addEventListener() {}, requestAnimationFrame: f => pending = f};
context.window = context;
vm.runInNewContext(source, context);
assert.equal(messages, 1);
bridge.onmessage({data: JSON.stringify(state)});
let pads = context.navigator.getGamepads();
assert.equal(pads[0], physical);
assert.equal(pads[1].mapping, 'standard');
assert.equal(pads[1].buttons[0].pressed, true); // A
assert.equal(pads[1].buttons[12].pressed, true); // D-pad up
assert.equal(pads[1].buttons[6].value, 1);
assert.equal(pads[1].buttons[7].value, 128 / 255);
assert.deepEqual(Array.from(pads[1].axes), [1, -1, -1, 1]);
assert.equal(events.at(-1).type, 'gamepadconnected');
bridge.onmessage({data: 'null'});
assert.equal(context.navigator.getGamepads()[1], null);
assert.equal(events.at(-1).type, 'gamepaddisconnected');
bridge.onmessage({data: JSON.stringify(state)});
time += 600;
pending();
assert.equal(context.navigator.getGamepads()[1], null, 'Stale input must expire');
assert.equal(events.at(-1).type, 'gamepaddisconnected');
assert.equal(context.navigator.getGamepads()[0], physical);
// Compatibility snapshots use the same proven bridge without changing Quest state.
time += 1;
bridge.onmessage({data: JSON.stringify({...state, id: 'Nightfall Xbox Wireless Controller', nativeName: 'Xbox Wireless Controller'})});
assert.equal(context.navigator.getGamepads()[1].id, 'Nightfall Xbox Wireless Controller');
assert.equal(events.at(-1).gamepad.id, 'Nightfall Xbox Wireless Controller');
// If WebView starts exposing the real pad, do not show a duplicate.
physical.id = 'Xbox Wireless Controller (STANDARD GAMEPAD Vendor: 045e Product: 0b13)';
bridge.onmessage({data: JSON.stringify({...state, id: 'Nightfall Xbox Wireless Controller', nativeName: 'Xbox Wireless Controller'})});
assert.equal(context.navigator.getGamepads()[1], null);
assert.equal(events.at(-1).type, 'gamepaddisconnected');
assert.equal(context.navigator.getGamepads()[0], physical);
console.log('Browser injected gamepad script tests passed');
