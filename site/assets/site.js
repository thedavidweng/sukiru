// Explicit i18n detection: when the browser language does not match the page
// language, reveal the top banner offering a switch. The user's explicit
// choice (switch or dismiss) is remembered and never overridden afterwards.
(function () {
  var KEY = "sukiru-lang";
  function get() {
    try { return localStorage.getItem(KEY); } catch (e) { return null; }
  }
  function set(v) {
    try { localStorage.setItem(KEY, v); } catch (e) { /* private mode */ }
  }
  var pageLang = document.documentElement.lang.toLowerCase().indexOf("zh") === 0 ? "zh" : "en";
  var browserLang = (navigator.language || "en").toLowerCase().indexOf("zh") === 0 ? "zh" : "en";
  var banner = document.getElementById("lang-banner");
  if (!banner) return;

  var chosen = get();
  if (!chosen && browserLang !== pageLang) {
    banner.hidden = false;
  }

  var switcher = document.getElementById("lang-switch");
  if (switcher) {
    switcher.addEventListener("click", function () {
      set(pageLang === "zh" ? "en" : "zh"); // remember the language they switched to
    });
  }
  var dismiss = document.getElementById("lang-dismiss");
  if (dismiss) {
    dismiss.addEventListener("click", function () {
      set(pageLang); // remember they chose to stay
      banner.hidden = true;
    });
  }
})();

// Hero intro: loose skill rows, each flagged with a problem, sort themselves
// into the captured list, resolve to a fix, and dissolve into the screenshot.
// Rows mirror public/screenshot.webp top to bottom; update them with it.
(function () {
  var section = document.querySelector(".hero");
  var stage = section && section.querySelector(".hero-stage");
  var shot = stage && stage.querySelector(".hero-shot");
  if (!shot) {
    if (section) section.classList.add("is-done");
    return;
  }
  var rows = [
    ["Monorepo Governance for Dual-Framework Proj…", "Pattern for creating and maintaining du…"],
    ["action-items", "Use when turning documents, meeting…"],
    ["aeo-audit", "Audit a website for agent discoverability (llms.t…"],
    ["agent-browser", "Browser automation CLI for AI agents. Use whe…"],
    ["agentmail", "Give the agent its own dedicated email…"],
    ["animate", "Build an animation from scratch, making the de…"],
    ["animation-vocabulary", "Reverse-lookup glossary that turns a vague de…"],
    ["apple-design", "Apple's approach to interface design and fluid,…"],
    ["apple-native-transcribe", "Transcribe local audio files with Apple'…"],
    ["ask-matt", "Ask which skill or flow fits your situation. A rou…"],
    ["ask-sonner", "Guide to Sonner, the React toast library — inst…"],
    ["baoyu-article-illustrator", "Article illustrations: type × style × palet…"]
  ];
  var ROW_TOP = 225 / 1358, ROW_STEP = 84.8 / 1358;
  var EASE = "cubic-bezier(.28,.11,.32,1)";
  var COLORS = ["#ff453a", "#ff9f0a", "#ffd60a", "#bf5af2"];
  var problems = (stage.getAttribute("data-problems") || "").split("|");
  var fixed = stage.getAttribute("data-fixed") || "";
  var camera = section.querySelector(".hero-camera");
  var sheen = section.querySelector(".hero-sheen");
  var copy = Array.prototype.slice.call(section.querySelectorAll(".hero-meta > *"));
  var replay = section.querySelector(".hero-replay");
  var motion = matchMedia("(prefers-reduced-motion: no-preference)");
  var cards = [], running = [], seed;

  function rand() { seed = (seed * 16807) % 2147483647; return (seed - 1) / 2147483646; }
  function anim(el, frames, opts) {
    var a = el.animate(frames, Object.assign({ fill: "both", easing: EASE }, opts));
    running.push(a);
    return a;
  }
  function el(tag, cls, text) {
    var e = document.createElement(tag);
    e.className = cls;
    e.textContent = text;
    return e;
  }

  function build() {
    rows.forEach(function (r, i) {
      var card = el("div", "hero-row", "");
      card.setAttribute("aria-hidden", "true");
      card.style.top = (ROW_TOP + ROW_STEP * i) * 100 + "%";
      card.appendChild(el("span", "n", r[0]));
      var tag = el("span", "tag", "");
      var bad = el("span", "bad", problems[i % problems.length]);
      bad.style.setProperty("--c", COLORS[i % COLORS.length]);
      tag.appendChild(bad);
      tag.appendChild(el("span", "ok", fixed));
      card.appendChild(tag);
      card.appendChild(el("span", "d", r[1]));
      stage.appendChild(card);
      cards.push(card);
    });
  }

  function finish() {
    running.forEach(function (a) { a.cancel(); });
    running = [];
    cards.forEach(function (c) { c.remove(); });
    cards = [];
    section.classList.add("is-done");
  }

  function play() {
    finish();
    if (!motion.matches) return;
    section.classList.remove("is-done");
    replay.hidden = true;
    seed = 7;
    build();

    // The camera starts pushed in and tilted, then pulls back as rows sort.
    anim(camera, [
      { transform: "translateZ(0) scale(1.55) rotateX(18deg) rotateZ(-4deg)" },
      { transform: "translateZ(0) scale(1.55) rotateX(18deg) rotateZ(-4deg)", offset: 0.28 },
      { transform: "scale(1) rotateX(0) rotateZ(0)" }
    ], { duration: 3600 });

    cards.forEach(function (card, i) {
      var x = (rand() - 0.5) * 260, y = (rand() - 0.5) * 1100, z = -100 - rand() * 700;
      var rx = (rand() - 0.5) * 70, ry = (rand() - 0.5) * 80, rz = (rand() - 0.5) * 40;
      var blur = Math.min(2.5, -z / 300);
      // k scales the position, d the depth and tilt: the drift eases both in.
      function at(k, d) {
        return "translate3d(" + x * k + "%," + y * k + "%," + z * d + "px) rotateX(" + rx * d +
          "deg) rotateY(" + ry * d + "deg) rotateZ(" + rz * d + "deg)";
      }
      var enter = i * 45, sortAt = 1150 + i * 70;

      anim(card, [
        { transform: at(1, 1) + " translateZ(-600px)", opacity: 0, filter: "blur(" + (blur + 10) + "px)" },
        { transform: at(0.85, 0.8), opacity: 1, filter: "blur(" + blur + "px)" }
      ], { duration: sortAt - enter, delay: enter, easing: "cubic-bezier(.2,.7,.3,1)" });
      anim(card, [
        { transform: at(0.85, 0.8), filter: "blur(" + blur + "px)", boxShadow: "0 0 0 1px rgba(255,255,255,.08), 0 1.6cqw 3cqw rgba(0,0,0,.55)" },
        { transform: "none", filter: "blur(0px)", boxShadow: "0 0 0 1px rgba(255,255,255,0), 0 0 0 rgba(0,0,0,0)" }
      ], { duration: 1100, delay: sortAt, easing: "cubic-bezier(.5,0,.15,1)", fill: "forwards" });

      // Once in place, each problem resolves to a fix.
      anim(card.querySelector(".bad"), [{ opacity: 1 }, { opacity: 0 }],
        { duration: 160, delay: sortAt + 900, fill: "forwards" });
      anim(card.querySelector(".ok"), [{ opacity: 0, transform: "scale(.6)" }, { opacity: 1, transform: "none" }],
        { duration: 260, delay: sortAt + 900, easing: "cubic-bezier(.3,1.6,.5,1)", fill: "forwards" });
      anim(card, [{ opacity: 1 }, { opacity: 0 }], { duration: 500, delay: 3050 + i * 25, fill: "forwards" });
    });

    // The window opens first under the list, then out to its full width.
    anim(shot, [
      { opacity: 0, clipPath: "inset(4.9% 45.4% 9.4% 22.6% round 0.8cqw)" },
      { opacity: 1, clipPath: "inset(4.9% 45.4% 9.4% 22.6% round 0.8cqw)", offset: 0.35 },
      { opacity: 1, clipPath: "inset(0% 0% 0% 0% round 0cqw)" }
    ], { duration: 1300, delay: 2250, easing: "cubic-bezier(.65,0,.2,1)" });
    anim(sheen, [{ opacity: 0 }, { opacity: 1, offset: 0.15 }, { opacity: 1, offset: 0.85 }, { opacity: 0 }],
      { duration: 1200, delay: 3350, easing: "linear" });
    anim(sheen, [{ transform: "translateX(-60%)" }, { transform: "translateX(60%)" }],
      { duration: 1200, delay: 3350, easing: "cubic-bezier(.45,0,.2,1)", pseudoElement: "::after" });
    copy.forEach(function (c, i) {
      anim(c, [{ opacity: 0, transform: "translateY(18px)" }, { opacity: 1, transform: "none" }],
        { duration: 900, delay: 3500 + i * 110, easing: "cubic-bezier(.2,.7,.3,1)" });
    });

    var last = running[running.length - 1];
    last.finished.then(function () {
      finish();
      replay.hidden = false;
    }, function () {});
  }

  replay.addEventListener("click", play);
  // Like apple.com's load timeout: a slow capture shows statically instead.
  var timer = setTimeout(finish, 3000);
  function start() {
    clearTimeout(timer);
    if (!section.classList.contains("is-done")) play();
  }
  shot.addEventListener("error", finish);
  if (shot.complete && shot.naturalWidth) start();
  else shot.addEventListener("load", start, { once: true });
})();
