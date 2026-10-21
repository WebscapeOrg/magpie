const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const { test } = require("node:test");

const html = fs.readFileSync(path.join(__dirname, "../docs/index.html"), "utf8");
const script = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].at(-1)[1];

function element(attributes = {}) {
    return {
        attributes, listeners: {}, textContent: "Copy", innerHTML: "Copy", disabled: false,
        setAttribute(name, value) { this.attributes[name] = value; },
        getAttribute(name) { return this.attributes[name]; },
        removeAttribute(name) { delete this.attributes[name]; },
        addEventListener(name, listener) { this.listeners[name] = listener; },
        classList: { contains() { return false; } }
    };
}

function page(clipboard) {
    const copy = element({ "data-copy": "synthetic install command", "data-en": "Copy" });
    const command = element();
    const theme = element();
    const selection = { node: null, removeAllRanges() { this.node = null; },
        addRange(range) { this.node = range.node; } };
    const timers = [];
    const document = {
        documentElement: element(),
        querySelectorAll(selector) { return selector === "[data-zh]" ? [copy] : []; },
        querySelector(selector) {
            return { ".copy": copy, ".theme-toggle": theme, ".command .cmd": command }[selector];
        },
        createRange() { return { selectNodeContents(node) { this.node = node; } }; }
    };
    vm.runInNewContext(script, {
        document, navigator: { clipboard, language: "en", platform: "Linux" },
        localStorage: { getItem() { return null; }, setItem() {} },
        window: { getSelection() { return selection; } },
        setTimeout(callback) { timers.push(callback); }
    });
    return { copy, command, selection, timers };
}

test("clipboard absence selects the installation command for keyboard copying", () => {
    const view = page(undefined);
    assert.equal(typeof view.copy.listeners.click, "function");
    view.copy.listeners.click();
    assert.equal(view.selection.node, view.command);
    assert.match(view.copy.textContent, /Ctrl\+C/);
    assert.equal(view.copy.disabled, false);
});

test("clipboard refusal selects the command and does not report success", async () => {
    const view = page({ writeText() { return Promise.reject(new Error("denied")); } });
    await view.copy.listeners.click();
    assert.equal(view.selection.node, view.command);
    assert.match(view.copy.textContent, /Ctrl\+C/);
    assert.notEqual(view.copy.attributes["data-state"], "done");
    assert.equal(view.copy.disabled, false);
});

test("clipboard write reports pending and confirmed completion", async () => {
    let finish;
    let written;
    const view = page({ writeText(text) {
        written = text;
        return new Promise(resolve => { finish = resolve; });
    } });
    const pending = view.copy.listeners.click();
    assert.equal(view.copy.disabled, true);
    assert.match(view.copy.textContent, /Copying/);
    finish();
    await pending;
    assert.equal(written, "synthetic install command");
    assert.equal(view.copy.textContent, "Copied");
    assert.equal(view.copy.disabled, false);
    view.timers[0]();
    assert.equal(view.copy.innerHTML, "Copy");
});
