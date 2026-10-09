/* Droplet website: copying the install line, the menu-bar demo, the launch
   price chooser and the page's effects (the water behind the hero, the pinned
   three-step story, pointer light). Plain JavaScript without dependencies;
   every page stays readable and usable without it, and every effect stands
   down when the visitor asks for reduced motion. */
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
    var label = one(button, "[data-copy-label]") || button;
    var timer;
    if (!source) return;
    button.addEventListener("click", function () {
      clearTimeout(timer);
      copyText(source.textContent.trim()).then(function () {
        label.textContent = "Copied";
        replay(button, "is-copied");
        report(status, "Copied. Paste it into Terminal and press Return.", "is-ok");
        timer = setTimeout(function () {
          label.textContent = "Copy";
          button.classList.remove("is-copied");
          report(status, "", "");
        }, 4000);
      }, function () {
        label.textContent = "Copy";
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
    var frame = 0;
    var shown = { value: null, label: "" };

    function later(action, delay) { timers.push(setTimeout(action, delay)); }
    function stopTimers() { timers.forEach(clearTimeout); timers = []; cancelAnimationFrame(frame); }
    function say(text) { live.textContent = text; }
    function setIcon(kind) {
      if (stage.getAttribute("data-icon") === kind) return;
      stage.setAttribute("data-icon", kind);
      if (!reduced()) replay(toggle, "is-bumping");
    }
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
      if (value === shown.value && label === shown.label) return;
      if (label !== shown.label && !reduced()) replay(stageText, "is-changing");
      shown = { value: value, label: label };
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
    // Counts up every frame, easing out like a real transfer.
    function transfer(label, duration) {
      var began = Date.now();
      cancelAnimationFrame(frame);
      (function tick() {
        var share = Math.min(1, (Date.now() - began) / duration);
        setProgress(Math.round(100 * (1 - Math.pow(1 - share, 1.7))), label);
        if (share < 1) frame = requestAnimationFrame(tick);
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
      popover.classList.remove("is-first");
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
    range.addEventListener("change", function () { if (!reduced()) replay(range, "is-wobbling"); });
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

  /* ------------------------------------------------------------ effects */

  var finePointer = window.matchMedia ? window.matchMedia("(hover: hover) and (pointer: fine)") : null;
  function canHover() { return !!(finePointer && finePointer.matches); }
  function onChange(query, handler) {
    if (!query) return;
    if (query.addEventListener) query.addEventListener("change", handler);
    else if (query.addListener) query.addListener(handler);
  }
  // Calls the handler at most once per frame, with the latest event.
  function perFrame(handler) {
    var latest = null;
    return function (event) {
      if (latest === null) {
        requestAnimationFrame(function () {
          var next = latest;
          latest = null;
          handler(next);
        });
      }
      latest = event;
    };
  }
  function whenVisible(element, onShow, onHide, options) {
    if (!("IntersectionObserver" in window)) {
      onShow();
      return null;
    }
    var observer = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (entry.isIntersecting) onShow(entry);
        else if (onHide) onHide(entry);
      });
    }, options);
    observer.observe(element);
    return observer;
  }

  // Buttons lean a few pixels toward the pointer and light up under it.
  function initMagnetic(button) {
    var inside = false;
    button.addEventListener("pointerenter", function () { inside = true; });
    button.addEventListener("pointermove", perFrame(function (event) {
      if (!inside || !canHover() || reduced()) return;
      var box = button.getBoundingClientRect();
      var x = event.clientX - box.left;
      var y = event.clientY - box.top;
      button.style.setProperty("--gx", x.toFixed(0) + "px");
      button.style.setProperty("--gy", y.toFixed(0) + "px");
      button.style.setProperty("--mx", Math.max(-6, Math.min(6, (x - box.width / 2) * 0.16)).toFixed(1) + "px");
      button.style.setProperty("--my", Math.max(-4, Math.min(4, (y - box.height / 2) * 0.25)).toFixed(1) + "px");
    }));
    button.addEventListener("pointerleave", function () {
      inside = false;
      button.style.setProperty("--mx", "0px");
      button.style.setProperty("--my", "0px");
    });
  }

  // The water behind the hero: one fragment shader. Warped sine waves whose
  // thin bright crossings read as light through water, in the drop's colours.
  var WATER_VERTEX = "attribute vec2 p;void main(){gl_Position=vec4(p,0.0,1.0);}";
  var WATER_FRAGMENT = [
    "precision mediump float;",
    "uniform vec2 uRes;",
    "uniform float uTime;",
    "uniform vec3 uPointer;",
    "uniform float uDark;",
    "float ridge(vec2 p, float t) {",
    "  p += 0.55 * vec2(sin(p.y * 1.3 + t * 0.7), cos(p.x * 1.1 - t * 0.6));",
    "  p += 0.35 * vec2(sin(p.y * 2.3 - t * 0.5), cos(p.x * 2.7 + t * 0.8));",
    "  float n = sin(p.x * 1.9) * sin(p.y * 1.9) * 0.7 + sin((p.x + p.y) * 1.3 + t * 0.3) * 0.3;",
    "  return pow(1.0 - abs(n), 7.0);",
    "}",
    "void main() {",
    "  vec2 uv = gl_FragCoord.xy / uRes;",
    "  float aspect = uRes.x / uRes.y;",
    "  vec2 p = vec2(uv.x * aspect, uv.y) * 3.2;",
    "  float c = ridge(p, uTime) * 0.65 + ridge(p * 1.7 + vec2(4.0, 1.0), uTime * 1.25) * 0.45;",
    "  float d = distance(vec2(uv.x * aspect, uv.y), vec2(uPointer.x * aspect, uPointer.y));",
    "  c *= 1.0 + uPointer.z * 1.6 * smoothstep(0.45, 0.0, d);",
    "  float fade = smoothstep(0.0, 0.6, uv.y);",
    "  vec3 cyan = vec3(0.16, 0.84, 0.94);",
    "  vec3 blue = vec3(0.11, 0.43, 0.93);",
    "  vec3 indigo = vec3(0.35, 0.28, 0.84);",
    "  vec3 col = mix(mix(indigo, blue, uv.y), cyan, smoothstep(0.35, 1.0, uv.x * 0.6 + uv.y * 0.5));",
    "  col = mix(col * 0.8, col, uDark);",
    "  float a = clamp(c, 0.0, 1.0) * fade * mix(0.32, 0.5, uDark);",
    "  gl_FragColor = vec4(col * a, a);",
    "}"
  ].join("\n");

  function initWater(backdrop) {
    var canvas = document.createElement("canvas");
    var gl = null;
    try {
      gl = canvas.getContext("webgl", { alpha: true, premultipliedAlpha: true, antialias: false, depth: false, stencil: false, powerPreference: "low-power" });
    } catch (error) {
      gl = null;
    }
    if (!gl) return null;
    function compile(type, source) {
      var shader = gl.createShader(type);
      gl.shaderSource(shader, source);
      gl.compileShader(shader);
      return gl.getShaderParameter(shader, gl.COMPILE_STATUS) ? shader : null;
    }
    var vertex = compile(gl.VERTEX_SHADER, WATER_VERTEX);
    var fragment = compile(gl.FRAGMENT_SHADER, WATER_FRAGMENT);
    if (!vertex || !fragment) return null;
    var program = gl.createProgram();
    gl.attachShader(program, vertex);
    gl.attachShader(program, fragment);
    gl.linkProgram(program);
    if (!gl.getProgramParameter(program, gl.LINK_STATUS)) return null;
    gl.useProgram(program);
    gl.bindBuffer(gl.ARRAY_BUFFER, gl.createBuffer());
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
    var position = gl.getAttribLocation(program, "p");
    gl.enableVertexAttribArray(position);
    gl.vertexAttribPointer(position, 2, gl.FLOAT, false, 0, 0);
    var uniforms = {
      res: gl.getUniformLocation(program, "uRes"),
      time: gl.getUniformLocation(program, "uTime"),
      pointer: gl.getUniformLocation(program, "uPointer"),
      dark: gl.getUniformLocation(program, "uDark")
    };
    var dark = window.matchMedia ? window.matchMedia("(prefers-color-scheme: dark)") : null;
    var pointer = { x: 0.7, y: 0.6, on: 0, target: 0 };
    var state = { running: false, visible: true, lost: false, frame: 0, last: 0, clock: 8, drawn: false };

    canvas.setAttribute("aria-hidden", "true");
    backdrop.appendChild(canvas);

    // Drawn at a fraction of the screen's pixels: the softness hides it.
    function size() {
      var box = backdrop.getBoundingClientRect();
      var scale = box.width < 700 ? 0.35 : 0.5;
      var width = Math.max(1, Math.round(box.width * scale));
      var height = Math.max(1, Math.round(box.height * scale));
      if (canvas.width !== width || canvas.height !== height) {
        canvas.width = width;
        canvas.height = height;
        gl.viewport(0, 0, width, height);
      }
    }
    function draw() {
      if (state.lost) return;
      pointer.on += (pointer.target - pointer.on) * 0.08;
      gl.uniform2f(uniforms.res, canvas.width, canvas.height);
      gl.uniform1f(uniforms.time, state.clock);
      gl.uniform3f(uniforms.pointer, pointer.x, pointer.y, pointer.on);
      gl.uniform1f(uniforms.dark, dark && dark.matches ? 1 : 0);
      gl.drawArrays(gl.TRIANGLES, 0, 3);
      if (!state.drawn) {
        state.drawn = true;
        canvas.classList.add("is-ready");
      }
    }
    function loop(now) {
      if (!state.running) return;
      state.frame = requestAnimationFrame(loop);
      if (now - state.last < 33) return; // about 30 frames a second is plenty
      state.clock += Math.min(now - state.last, 100) / 1000 * 0.32;
      state.last = now;
      draw();
    }
    // Runs only while the hero is on screen, the tab is visible and motion is
    // welcome; otherwise it holds one still frame.
    function update() {
      var go = state.visible && !document.hidden && !reduced() && !state.lost;
      if (go && !state.running) {
        state.running = true;
        state.last = performance.now();
        state.frame = requestAnimationFrame(loop);
      } else if (!go && state.running) {
        state.running = false;
        cancelAnimationFrame(state.frame);
      }
      if (!go) draw();
    }
    canvas.addEventListener("webglcontextlost", function (event) {
      event.preventDefault();
      state.lost = true;
      update();
      if (canvas.parentNode) canvas.parentNode.removeChild(canvas);
    });
    size();
    if ("ResizeObserver" in window) {
      new ResizeObserver(function () {
        size();
        if (!state.running) draw();
      }).observe(backdrop);
    }
    whenVisible(backdrop, function () { state.visible = true; update(); }, function () { state.visible = false; update(); });
    document.addEventListener("visibilitychange", update);
    onChange(motion, update);
    onChange(dark, function () { if (!state.running) draw(); });
    update();
    return {
      point: function (x, y) {
        if (x === null) {
          pointer.target = 0;
          return;
        }
        pointer.x = x;
        pointer.y = 1 - y;
        pointer.target = 1;
      },
      state: state
    };
  }

  // Aurora, water and a spotlight that follows the pointer over the hero.
  function initBackdrop(backdrop) {
    var hero = backdrop.parentElement;
    var water = initWater(backdrop);
    backdrop.water = water;
    hero.addEventListener("pointermove", perFrame(function (event) {
      if (!event || !canHover()) return;
      var box = backdrop.getBoundingClientRect();
      var x = (event.clientX - box.left) / box.width;
      var y = (event.clientY - box.top) / box.height;
      backdrop.style.setProperty("--px", (x * 100).toFixed(2) + "%");
      backdrop.style.setProperty("--py", (y * 100).toFixed(2) + "%");
      backdrop.classList.add("is-lit");
      if (water) water.point(x, y);
    }));
    hero.addEventListener("pointerleave", function () {
      backdrop.classList.remove("is-lit");
      if (water) water.point(null);
    });
  }

  // A glint on the demo window's glass follows the pointer.
  function initGlint(screen) {
    var popover = one(screen, "[data-demo-popover]");
    if (!popover) return;
    screen.addEventListener("pointermove", perFrame(function (event) {
      if (!event || !canHover() || popover.hidden) return;
      var box = popover.getBoundingClientRect();
      popover.style.setProperty("--gx", (event.clientX - box.left).toFixed(0) + "px");
      popover.style.setProperty("--gy", (event.clientY - box.top).toFixed(0) + "px");
    }));
  }

  // Feature tiles: a border light under the pointer.
  function initTiles(grid) {
    grid.addEventListener("pointermove", perFrame(function (event) {
      if (!event || !canHover()) return;
      var tile = event.target.closest && event.target.closest(".tile");
      if (!tile) return;
      var box = tile.getBoundingClientRect();
      tile.style.setProperty("--x", (event.clientX - box.left).toFixed(0) + "px");
      tile.style.setProperty("--y", (event.clientY - box.top).toFixed(0) + "px");
    }));
  }

  // "Lives in your menu bar": the scene's drop walks through its three states
  // while the tile is in view; pointing at a state holds it.
  function initStates(scene) {
    var items = all(scene, "[data-state]");
    var drop = one(scene, ".scene-drop");
    var index = 0;
    var timer = null;
    var held = false;
    function set(i) {
      index = i;
      scene.setAttribute("data-active", items[i].getAttribute("data-state"));
      items.forEach(function (item, n) { item.classList.toggle("is-active", n === i); });
      if (drop && !reduced()) replay(drop, "is-bumping");
    }
    function stop() {
      clearInterval(timer);
      timer = null;
    }
    function play() {
      if (timer || held || reduced()) return;
      set(index);
      timer = setInterval(function () { set((index + 1) % items.length); }, 1800);
    }
    items.forEach(function (item, i) {
      item.addEventListener("pointerenter", function () {
        held = true;
        stop();
        set(i);
      });
      item.addEventListener("pointerleave", function () {
        held = false;
        play();
      });
    });
    whenVisible(scene, play, stop, { threshold: 0.4 });
    onChange(motion, function () { if (reduced()) stop(); });
  }

  // The header's links follow the section in view, with a sliding pill.
  function initNavSpy(nav) {
    var links = all(nav, "a").filter(function (link) { return link.hash && document.getElementById(link.hash.slice(1)); });
    if (!links.length || !("IntersectionObserver" in window)) return;
    var pill = document.createElement("span");
    pill.className = "nav-pill";
    pill.setAttribute("aria-hidden", "true");
    nav.insertBefore(pill, nav.firstChild);
    var current = null;
    var seen = {};
    function mark(link) {
      if (link === current) return;
      links.forEach(function (item) {
        if (item === link) item.setAttribute("aria-current", "location");
        else item.removeAttribute("aria-current");
      });
      if (link) {
        if (!current) pill.style.transition = "none"; // appear in place, then slide
        pill.style.setProperty("--x", link.offsetLeft + "px");
        pill.style.setProperty("--w", link.offsetWidth + "px");
        pill.getBoundingClientRect();
        pill.style.transition = "";
      }
      pill.classList.toggle("is-on", !!link);
      current = link;
    }
    var observer = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) { seen[entry.target.id] = entry.isIntersecting; });
      var found = null;
      links.forEach(function (link) { if (seen[link.hash.slice(1)]) found = link; });
      mark(found);
    }, { rootMargin: "-45% 0px -54% 0px" });
    links.forEach(function (link) { observer.observe(document.getElementById(link.hash.slice(1))); });
  }

  // Accordions open and close smoothly; keyboard use stays the browser's own.
  function initAccordion(details) {
    var summary = details.querySelector("summary");
    var animation = null;
    var closing = false;
    if (!summary || typeof details.animate !== "function") return;
    function run(from, to, done) {
      if (animation) animation.cancel();
      details.classList.add("is-animating");
      animation = details.animate({ height: [from + "px", to + "px"] }, { duration: 320, easing: "cubic-bezier(0.16, 1, 0.3, 1)" });
      animation.onfinish = function () {
        animation = null;
        details.classList.remove("is-animating");
        if (done) done();
      };
    }
    summary.addEventListener("click", function (event) {
      if (reduced()) return;
      event.preventDefault();
      var now = details.getBoundingClientRect().height;
      if (details.open && !closing) {
        closing = true;
        details.classList.add("is-closing");
        run(now, summary.getBoundingClientRect().height, function () {
          details.open = false;
          closing = false;
          details.classList.remove("is-closing");
        });
      } else {
        if (animation) {
          animation.cancel();
          animation = null;
        }
        closing = false;
        details.classList.remove("is-closing");
        details.open = true;
        run(now, details.getBoundingClientRect().height);
      }
    });
  }

  // How it works: on wide screens the steps scroll past a sticky stage that
  // acts each one out; elsewhere each card plays its little scene once.
  function initFlowStory(wrap) {
    var steps = all(wrap, ".flow-step");
    var screen = one(wrap, ".fs-screen");
    var button = one(wrap, ".fs-pop-btn");
    var wide = window.matchMedia ? window.matchMedia("(min-width: 1024px) and (min-height: 680px) and (prefers-reduced-motion: no-preference)") : null;
    var observer = null;
    function activate(step) {
      var n = String(steps.indexOf(step) + 1);
      if (wrap.getAttribute("data-step") === n) return;
      wrap.setAttribute("data-step", n);
      steps.forEach(function (item) { item.classList.toggle("is-active", item === step); });
    }
    // Where the cursor clicks Download, measured from the real layout.
    function aim() {
      if (!screen || !button) return;
      var x = button.offsetWidth / 2;
      var y = button.offsetHeight / 2;
      for (var node = button; node && node !== screen; node = node.offsetParent) {
        x += node.offsetLeft;
        y += node.offsetTop;
      }
      screen.style.setProperty("--btn-x", x + "px");
      screen.style.setProperty("--btn-y", y + "px");
    }
    function setup() {
      var on = !!(wide && wide.matches) && "IntersectionObserver" in window;
      wrap.classList.toggle("is-story", on);
      if (on && !observer) {
        aim();
        observer = new IntersectionObserver(function (entries) {
          entries.forEach(function (entry) { if (entry.isIntersecting) activate(entry.target); });
        }, { rootMargin: "-50% 0px -50% 0px" });
        steps.forEach(function (step) { observer.observe(step); });
        if (!wrap.hasAttribute("data-step")) activate(steps[0]);
      } else if (!on && observer) {
        observer.disconnect();
        observer = null;
        wrap.removeAttribute("data-step");
        steps.forEach(function (item) { item.classList.remove("is-active"); });
      }
    }
    setup();
    onChange(wide, setup);
    window.addEventListener("resize", perFrame(function () { if (observer) aim(); }));
    steps.forEach(function (step) {
      var watch = whenVisible(step, function () {
        step.classList.add("is-seen");
        if (watch) watch.disconnect();
      }, null, { threshold: 0.5 });
    });
  }

  /* ------------------------------------------------------------ start */

  function start() {
    document.documentElement.classList.add("js");
    all(document, "[data-copy]").forEach(initCopy);
    all(document, "[data-demo]").forEach(initDemo);
    all(document, "[data-price-form]").forEach(initPrice);
    all(document, "[data-backdrop]").forEach(initBackdrop);
    all(document, "[data-demo-screen]").forEach(initGlint);
    all(document, ".bento").forEach(initTiles);
    all(document, "[data-states]").forEach(initStates);
    all(document, ".site-nav").forEach(initNavSpy);
    all(document, "details").forEach(initAccordion);
    all(document, "[data-flow]").forEach(initFlowStory);
    all(document, ".hero-actions .btn, .header-row .btn, [data-price-submit]:not([aria-disabled])").forEach(initMagnetic);
  }
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", start);
  else start();
})();
