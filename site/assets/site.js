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
