const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const { test } = require("node:test");

const html = fs.readFileSync(path.join(__dirname, "../docs/index.html"), "utf8");
const script = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].at(-1)[1];

function element(attributes = {}) {
    let content = "Copy";
    return {
        attributes, listeners: {}, disabled: false,
        get textContent() { return content; }, set textContent(value) { content = value; },
        get innerHTML() { return content; }, set innerHTML(value) { content = value; },
        setAttribute(name, value) { this.attributes[name] = value; },
        getAttribute(name) { return this.attributes[name]; },
        removeAttribute(name) { delete this.attributes[name]; },
        addEventListener(name, listener) { this.listeners[name] = listener; },
        classList: { contains() { return false; } }
    };
}

function page(clipboard) {
    const copy = element({ "data-copy": "synthetic install command", "data-en": "Copy", "data-zh": "复制" });
    const chinese = element({ "data-lang": "zh" });
    const command = element();
    const theme = element();
    const selection = { node: null, removeAllRanges() { this.node = null; },
        addRange(range) { this.node = range.node; } };
    const timers = [];
    const cancelledTimers = new Set();
    const document = {
        documentElement: element(),
        querySelectorAll(selector) {
            if (selector === "[data-zh]") return [copy];
            return selector === ".lang button" ? [chinese] : [];
        },
        querySelector(selector) {
            return { ".copy": copy, ".theme-toggle": theme, ".command .cmd": command }[selector];
        },
        createRange() { return { selectNodeContents(node) { this.node = node; } }; }
    };
    vm.runInNewContext(script, {
        document, navigator: { clipboard, language: "en", platform: "Linux" },
        localStorage: { getItem() { return null; }, setItem() {} },
        window: { getSelection() { return selection; } },
        setTimeout(callback) {
            const id = timers.length;
            timers.push(() => { if (!cancelledTimers.has(id)) callback(); });
            return id;
        },
        clearTimeout(id) { cancelledTimers.add(id); }
    });
    return { copy, command, selection, timers, chinese };
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


test("a previous copy reset cannot overwrite the next pending operation", async () => {
    const completions = [];
    const view = page({ writeText() { return new Promise(resolve => completions.push(resolve)); } });
    const first = view.copy.listeners.click();
    completions[0]();
    await first;
    const second = view.copy.listeners.click();
    assert.notEqual(view.copy.attributes["data-state"], "done");
    view.timers[0]();
    assert.equal(view.copy.textContent, "Copying…");
    assert.equal(view.copy.disabled, true);
    completions[1]();
    await second;
    assert.equal(view.copy.textContent, "Copied");
});

test("language changes preserve a pending clipboard operation", async () => {
    let finish;
    const view = page({ writeText() { return new Promise(resolve => { finish = resolve; }); } });
    const pending = view.copy.listeners.click();
    view.chinese.listeners.click();
    assert.equal(view.copy.textContent, "正在复制…");
    assert.equal(view.copy.disabled, true);
    finish();
    await pending;
    assert.equal(view.copy.textContent, "已复制");
});

test("language changes preserve confirmed clipboard completion", async () => {
    const view = page({ writeText() { return Promise.resolve(); } });
    await view.copy.listeners.click();
    view.chinese.listeners.click();
    assert.equal(view.copy.textContent, "已复制");
    assert.equal(view.copy.attributes["data-state"], "done");
    view.timers[0]();
    assert.equal(view.copy.textContent, "复制");
});

test("language changes preserve manual clipboard recovery", () => {
    const view = page(undefined);
    view.copy.listeners.click();
    view.chinese.listeners.click();
    assert.equal(view.copy.textContent, "按 Ctrl+C");
    assert.equal(view.selection.node, view.command);
    assert.equal(view.copy.disabled, false);
});
