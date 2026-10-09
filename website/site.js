/* Droplet website: copying the install line, the menu-bar demo and the launch
   price chooser. Plain JavaScript without dependencies; every page stays
   readable and usable without it. */
(function () {
  "use strict";

  /* ------------------------------------------------------------ prices */

  // Prices are whole cents (4.99 is 499), so nothing depends on float maths.
  function parsePrice(raw, maxCents) {
    var text = String(raw == null ? "" : raw).replace(/\s+/g, "");
    text = text.replace(/^(?:US\$|USD|\$)/i, "").replace(/(?:USD|\$)$/i, "");
    if (text === "") return { ok: false, reason: "empty" };
    if (/^[-−]/.test(text)) return { ok: false, reason: "negative" };
    var match = /^(\d*)(?:[.,](\d*))?$/.exec(text);
    if (!match || (match[1] === "" && !match[2])) return { ok: false, reason: "format" };
    var fraction = match[2] || "";
    if (fraction.length > 2) return { ok: false, reason: "cents" };
    var whole = match[1].replace(/^0+(?=\d)/, "");
    if (whole.length > 6) return { ok: false, reason: "high" };
    var cents = Number(whole || "0") * 100 + Number((fraction + "00").slice(0, 2));
    if (cents > maxCents) return { ok: false, reason: "high", cents: cents };
    return { ok: true, cents: cents };
  }

  function formatPrice(cents) {
    var rest = cents % 100;
    return "US$" + Math.floor(cents / 100) + (rest ? "." + (rest < 10 ? "0" : "") + rest : "");
  }

  // What the price field shows: always two decimals, like 2.50.
  function inputValue(cents) {
    var rest = cents % 100;
    return Math.floor(cents / 100) + "." + (rest < 10 ? "0" : "") + rest;
  }

  function priceMessage(result, maxCents) {
    var max = formatPrice(maxCents);
    if (!result.ok) {
      return {
        empty: "Enter a price from US$0 to " + max + ".",
        format: "Use numbers only, for example 2.50.",
        cents: "Use at most two digits after the decimal point.",
        negative: "The price can’t be less than US$0.",
        high: "During the launch offer, the most you can pay is " + max + "."
      }[result.reason];
    }
    if (result.cents === 0) return "US$0 still gets the full license with unlimited downloads. It isn’t the trial.";
    if (result.cents === maxCents) return "That’s the regular price. Every price gets the same license.";
    return "You pay " + formatPrice(result.cents) + " and get the full license with unlimited downloads.";
  }

  if (typeof module === "object" && module.exports) {
    module.exports = { parsePrice: parsePrice, formatPrice: formatPrice, inputValue: inputValue, priceMessage: priceMessage };
  }
  if (typeof document === "undefined") return;

  /* ------------------------------------------------------------ helpers */

  var motion = window.matchMedia ? window.matchMedia("(prefers-reduced-motion: reduce)") : null;
  function reduced() { return !!(motion && motion.matches); }
  function one(root, selector) { return root.querySelector(selector); }
  function all(root, selector) { return Array.prototype.slice.call(root.querySelectorAll(selector)); }
  // Replays a CSS animation that is tied to a class.
  function replay(element, className) {
    element.classList.remove(className);
    element.getBoundingClientRect();
    element.classList.add(className);
  }

  /* ------------------------------------------------------------ copy */

  function report(element, text, state) {
    if (!element) return;
    element.textContent = text;
    element.classList.remove("is-ok", "is-error");
    if (state) element.classList.add(state);
  }

  function legacyCopy(text) {
    var active = document.activeElement;
    var area = document.createElement("textarea");
    area.value = text;
    area.setAttribute("readonly", "");
    area.style.cssText = "position:fixed;top:0;left:0;opacity:0;pointer-events:none";
    document.body.appendChild(area);
    area.select();
    var copied = false;
    try { copied = document.execCommand("copy"); } catch (error) { copied = false; }
    document.body.removeChild(area);
    if (active && active.focus) active.focus();
    return copied;
  }

  function copyText(text) {
    if (navigator.clipboard && navigator.clipboard.writeText && window.isSecureContext) {
      return navigator.clipboard.writeText(text).catch(function () {
        if (!legacyCopy(text)) throw new Error("copy failed");
      });
    }
    return legacyCopy(text) ? Promise.resolve() : Promise.reject(new Error("copy unavailable"));
  }

  function selectContents(element) {
    var selection = window.getSelection ? window.getSelection() : null;
    if (!selection) return;
    var range = document.createRange();
    range.selectNodeContents(element);
    selection.removeAllRanges();
    selection.addRange(range);
  }

  function initCopy(button) {
    var id = button.getAttribute("data-copy");
    var source = document.getElementById(id);
    var status = one(document, '[data-copy-status="' + id + '"]');
    var timer;
    if (!source) return;
    button.addEventListener("click", function () {
      clearTimeout(timer);
      copyText(source.textContent.trim()).then(function () {
        button.textContent = "Copied";
        button.classList.add("is-copied");
        report(status, "Copied. Paste it into Terminal and press Return.", "is-ok");
        timer = setTimeout(function () {
          button.textContent = "Copy";
          button.classList.remove("is-copied");
          report(status, "", "");
        }, 4000);
      }, function () {
        button.textContent = "Copy";
        button.classList.remove("is-copied");
        selectContents(source);
        report(status, "Couldn’t copy automatically. The line is selected: press ⌘C to copy it.", "is-error");
      });
    });
  }

  /* ------------------------------------------------------------ menu-bar demo */

  // Mirrors the app: the stages and texts of DownloadManager, the menu-bar icon
  // of AppDelegate, and the trial counter that only a saved video uses up.
  var VIDEO = "Big Buck Bunny 60fps 4K - Official Blender Foundation Short Film";
  var EXPLAIN = {
    trial: "In Droplet, this opens Settings, where you see your free downloads and can enter a license key.",
    finder: "In Droplet, Show in Finder opens your Downloads folder with the new MP4 selected.",
    open: "In Droplet, Open video plays the saved MP4 in your default video app, such as QuickTime Player."
  };

  function initDemo(stage) {
    var popover = one(stage, "[data-demo-popover]");
    var toggle = one(stage, "[data-demo-toggle]");
    var screen = one(stage, "[data-demo-screen]");
    var note = one(stage, "[data-demo-note]");
    var live = one(stage, "[data-demo-live]");
    var trial = one(stage, "[data-demo-trial]");
    var start = one(stage, "[data-demo-start]");
    var startLabel = one(stage, "[data-demo-start-label]");
    var progress = one(stage, "[data-demo-progress]");
    var fill = one(progress, ".pop-progress-fill");
    var stageText = one(stage, "[data-demo-stage]");
    var title = one(stage, "[data-demo-title]");
    var cancel = one(stage, "[data-demo-cancel]");
    var done = one(stage, "[data-demo-done]");
    var views = {};
    all(stage, "[data-view]").forEach(function (view) { views[view.getAttribute("data-view")] = view; });
    var intro = note.textContent;
    var pricing = document.getElementById("price");
    var remaining = 3;
    var phase = "idle";
    var timers = [];
    var iconTimer;

    function later(action, delay) { timers.push(setTimeout(action, delay)); }
    function stopTimers() { timers.forEach(clearTimeout); timers = []; }
    function say(text) { live.textContent = text; }
    function setIcon(kind) { stage.setAttribute("data-icon", kind); }
    function setNote(text, link) {
      note.textContent = text;
      if (link) {
        var anchor = document.createElement("a");
        anchor.href = link.href;
        anchor.textContent = link.label;
        note.appendChild(document.createTextNode(" "));
        note.appendChild(anchor);
      }
    }
    // Keyboard focus follows the view only when it was already in the window.
    function show(name, focusTarget) {
      var moveFocus = popover.contains(document.activeElement);
      phase = name;
      Object.keys(views).forEach(function (key) {
        views[key].hidden = key !== name;
        if (key === name && !reduced()) replay(views[key], "is-entering");
      });
      if (focusTarget && moveFocus && !popover.hidden) focusTarget.focus({ preventScroll: true });
    }
    function trialText() {
      return remaining > 0 ? remaining + " of 3 free downloads left" : "Free trial complete · Details";
    }
    function idleNote() {
      if (remaining > 0) setNote(intro);
      else setNote("That was the third free download. In Droplet, a license key now unlocks unlimited downloads.",
        pricing ? { href: "#price", label: "See the price" } : null);
    }
    function setProgress(value, label) {
      if (value === null) {
        progress.classList.add("is-indeterminate");
        progress.removeAttribute("aria-valuenow");
        fill.style.width = "";
        stageText.textContent = label;
      } else {
        progress.classList.remove("is-indeterminate");
        progress.setAttribute("aria-valuenow", String(value));
        fill.style.width = value + "%";
        stageText.textContent = label + " · " + value + "%";
      }
    }
    function transfer(label, duration) {
      var began = Date.now();
      (function tick() {
        var share = Math.min(1, (Date.now() - began) / duration);
        setProgress(Math.round(100 * (1 - Math.pow(1 - share, 1.7))), label);
        if (share < 1) later(tick, 90);
      })();
    }

    function begin() {
      stopTimers();
      if (remaining === 0) { // the demo's trial is used up: start over
        remaining = 3;
        trial.textContent = trialText();
        startLabel.textContent = "Download";
        setNote(intro);
        say("Demo reset. 3 of 3 free downloads left.");
        return;
      }
      title.textContent = "Fetching video…";
      setProgress(null, "Fetching video…");
      show("downloading", cancel);
      setIcon("busy");
      clearTimeout(iconTimer);
      say("Demo: download started.");
      setNote("Downloading. Close the window if you like: the drop in the menu bar shows the download is still running.");
      later(function () { title.textContent = VIDEO; }, 650);
      later(function () { transfer("Downloading video", 2200); }, 700);
      later(function () { transfer("Downloading audio", 650); }, 3000);
      later(function () { setProgress(null, "Merging video and audio…"); }, 3750);
      later(function () { setProgress(null, "Finishing file…"); }, 4450);
      later(finish, 5000);
    }

    function finish() {
      stopTimers();
      remaining = Math.max(0, remaining - 1);
      trial.textContent = trialText();
      show("done", done);
      setIcon("done");
      clearTimeout(iconTimer);
      iconTimer = setTimeout(function () { if (phase !== "downloading") setIcon("idle"); }, 2400);
      if (remaining > 0) {
        say("Demo: video saved. " + trialText() + ".");
        setNote("Saved. In the app this is a real MP4 in Downloads, and it used one free download: " + trialText() + ".");
      } else {
        startLabel.textContent = "Start the demo again";
        say("Demo: video saved. That was the last free download.");
        idleNote();
      }
    }

    function stopDownload() {
      stopTimers();
      setIcon("idle");
      show("idle", start);
      say("Demo: download cancelled. Cancelled downloads don’t use a free download.");
      setNote("Cancelled. A cancelled download doesn’t use one of your free downloads.");
    }

    function setOpen(open) {
      popover.hidden = !open;
      toggle.setAttribute("aria-expanded", String(open));
      if (open) {
        if (!reduced()) replay(popover, "is-opening");
        if (phase !== "downloading") idleNote();
      } else if (phase === "downloading") {
        setNote("The window is closed and the download keeps going. Click the drop in the menu bar to look.");
      } else {
        setNote("Click the drop in the menu bar to open Droplet again.");
      }
    }

    start.addEventListener("click", begin);
    cancel.addEventListener("click", stopDownload);
    one(stage, "[data-demo-new]").addEventListener("click", function () {
      show("idle", start);
      idleNote();
    });
    done.addEventListener("click", function () {
      show("idle");
      setOpen(false);
      toggle.focus();
    });
    trial.addEventListener("click", function () { setNote(EXPLAIN.trial); });
    all(stage, "[data-demo-explain]").forEach(function (button) {
      button.addEventListener("click", function () { setNote(EXPLAIN[button.getAttribute("data-demo-explain")]); });
    });
    toggle.addEventListener("click", function () { setOpen(popover.hidden); });
    // Like the real popover: Escape or a click elsewhere on the "screen" closes it.
    // Safari doesn't focus a clicked button, so Escape is also heard on the page,
    // unless someone is busy in another field or the demo is scrolled away.
    document.addEventListener("keydown", function (event) {
      if (event.key !== "Escape" || popover.hidden) return;
      var active = document.activeElement;
      var inside = stage.contains(active);
      var box = screen.getBoundingClientRect();
      if (!inside && (active !== document.body || box.bottom < 0 || box.top > window.innerHeight)) return;
      setOpen(false);
      if (inside) toggle.focus({ preventScroll: true });
    });
    screen.addEventListener("click", function (event) {
      if (!popover.hidden && !popover.contains(event.target) && !toggle.contains(event.target)) setOpen(false);
    });
  }

  /* ------------------------------------------------------------ launch price */

  function initPrice(form) {
    var max = parseInt(form.getAttribute("data-max-cents"), 10);
    var input = one(form, "[data-price-input]");
    var wrap = one(form, "[data-price-wrap]");
    var range = one(form, "[data-price-range]");
    var message = one(form, "[data-price-message]");
    var meter = one(form, "[data-price-meter]");
    var water = one(form, "[data-price-water]");
    var submit = one(form, "[data-price-submit]");
    var status = one(form, "[data-checkout-status]");
    var labels = all(form, "[data-price-label]");
    var picks = all(form, "[data-price-pick]");
    var unavailable = submit && submit.hasAttribute("data-checkout-unavailable");
    var statusText = status ? status.textContent : "";
    if (!(max > 0) || !input || !range) return;

    function render(cents, typed) {
      if (!typed) input.value = inputValue(cents);
      range.value = String(cents);
      range.setAttribute("aria-valuetext", formatPrice(cents));
      range.style.setProperty("--pct", (cents / max) * 100 + "%");
      labels.forEach(function (label) { label.textContent = formatPrice(cents); });
      picks.forEach(function (pick) {
        pick.setAttribute("aria-pressed", String(Number(pick.getAttribute("data-price-pick")) === cents));
      });
      // A little water even at US$0; brim-full at the regular price.
      if (water) water.style.setProperty("--empty", String(1 - (0.08 + (0.95 * cents) / max)));
      if (meter && !reduced()) replay(meter, "is-sloshing");
    }
    function explain(result) {
      message.textContent = priceMessage(result, max);
      message.classList.toggle("is-error", !result.ok);
      wrap.classList.toggle("is-invalid", !result.ok);
      if (result.ok) input.removeAttribute("aria-invalid");
      else input.setAttribute("aria-invalid", "true");
    }
    function resetStatus() {
      if (!status) return;
      status.textContent = statusText;
      status.classList.remove("is-active");
    }
    function choose(cents) {
      render(cents, false);
      explain({ ok: true, cents: cents });
      resetStatus();
    }
    // Checks the field; on a problem it says what is wrong and returns null.
    function checked() {
      var result = parsePrice(input.value, max);
      explain(result);
      if (!result.ok) {
        input.focus();
        return null;
      }
      render(result.cents, false);
      return result.cents;
    }

    input.addEventListener("input", function () {
      var result = parsePrice(input.value, max);
      resetStatus();
      if (result.ok) {
        render(result.cents, true);
        explain(result);
      } else if (result.reason === "empty") { // not an error while someone is still typing
        message.textContent = priceMessage(result, max);
        message.classList.remove("is-error");
        wrap.classList.remove("is-invalid");
        input.removeAttribute("aria-invalid");
      } else {
        explain(result);
      }
    });
    input.addEventListener("blur", function () {
      var result = parsePrice(input.value, max);
      if (result.ok) input.value = inputValue(result.cents);
      else explain(result);
    });
    range.addEventListener("input", function () { choose(parseInt(range.value, 10)); });
    range.addEventListener("keydown", function (event) {
      if (event.key !== "PageUp" && event.key !== "PageDown") return;
      event.preventDefault();
      var step = event.key === "PageUp" ? 50 : -50;
      choose(Math.min(max, Math.max(0, parseInt(range.value, 10) + step)));
    });
    picks.forEach(function (pick) {
      pick.addEventListener("click", function () { choose(Number(pick.getAttribute("data-price-pick"))); });
    });
    function closed() {
      var cents = checked();
      if (cents === null || !status) return;
      status.textContent = "Checkout isn’t open yet, so nothing happened: no payment was taken, no license was created and your choice of " +
        formatPrice(cents) + " was not saved.";
      status.classList.add("is-active");
    }
    form.addEventListener("submit", function (event) {
      if (unavailable) {
        event.preventDefault();
        closed();
        return;
      }
      if (checked() === null) event.preventDefault();
    });
    if (unavailable) submit.addEventListener("click", closed);
    render(parsePrice(input.value, max).ok ? parsePrice(input.value, max).cents : max, false);
  }

  /* ------------------------------------------------------------ start */

  function start() {
    document.documentElement.classList.add("js");
    all(document, "[data-copy]").forEach(initCopy);
    all(document, "[data-demo]").forEach(initDemo);
    all(document, "[data-price-form]").forEach(initPrice);
  }
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", start);
  else start();
})();
