/* LangTechDepot site behaviour. Two jobs, both small.

   1. One place to change when the two sites merge. Every link that leaves
      this site for the depot server is written as <a data-signup="query">,
      and is built from the two constants below. When this site is eventually
      served from depot.langtech.cloud itself, change those two and every link
      follows. Nothing else needs editing.

   2. The copy buttons. server/register.py carries its own copy of this
      handler for the token page - it is one file with no assets and it must
      keep working if this site is unreachable. Change one, change both. */

var DEPOT = 'https://depot.langtech.cloud';

/* Path of the sign-up form on that server. Nobody can be sent straight to a
   token: they fill this form in and the token comes back from it.

   It is "/" today. When the instructions site takes over "/" on that host,
   change this to "/signup" - register.py already answers there - and set
   DEPOT to '' at the same time. Those two lines are the whole client side of
   the merge. */
var SIGNUP = '/';

/* Where this site is published. Every download link in the pages is relative,
   so nothing here needs it - except the Linux command, which has to name an
   absolute URL for curl. The pages carry SITE_DEFAULT written out in full so
   the command is correct with JavaScript switched off; the rewrite below then
   corrects it to wherever the page is actually being served from. Move the
   site and the command follows, with no edit. */
var SITE_DEFAULT = 'https://sillsdev.github.io/langtechdepot/';

function siteBase() {
  var href = location.href.split('#')[0].split('?')[0];
  return href.replace(/[^/]*$/, '');  /* the directory this page lives in */
}

document.addEventListener('DOMContentLoaded', function () {
  var base = siteBase();
  document.querySelectorAll('[data-signup]').forEach(function (el) {
    var q = el.getAttribute('data-signup');
    el.setAttribute('href', DEPOT + SIGNUP + (q ? '?' + q : ''));
  });
  if (base === SITE_DEFAULT || /^file:/.test(base)) { return; }
  document.querySelectorAll('[data-site-url]').forEach(function (el) {
    el.textContent = el.textContent.split(SITE_DEFAULT).join(base);
  });
});

/* Copy the text of the element named by data-copy. navigator.clipboard needs
   a secure context, which a file:// preview and plain http are not, so the
   textarea fallback stays: a field user on a locked-down machine must never
   be told to retype a 40-character token by hand. */
function ltdCopy(btn) {
  var src = document.getElementById(btn.getAttribute('data-copy'));
  if (!src) { return; }
  var text = (src.textContent || '').trim();
  var done = function (ok) {
    btn.classList.toggle('done', ok);
    btn.textContent = ok ? 'Copied' : 'Press Ctrl+C';
    if (ok) { setTimeout(function () {
      btn.classList.remove('done'); btn.textContent = 'Copy';
    }, 2500); }
  };
  var fallback = function () {
    var ta = document.createElement('textarea');
    ta.value = text;
    ta.setAttribute('readonly', '');
    ta.style.position = 'fixed';
    ta.style.opacity = '0';
    document.body.appendChild(ta);
    ta.select();
    var ok = false;
    try { ok = document.execCommand('copy'); } catch (e) { ok = false; }
    document.body.removeChild(ta);
    /* Nothing copied: select it on the page so Ctrl+C is one keystroke away. */
    if (!ok && window.getSelection) {
      var r = document.createRange();
      r.selectNodeContents(src);
      window.getSelection().removeAllRanges();
      window.getSelection().addRange(r);
    }
    done(ok);
  };
  if (navigator.clipboard && navigator.clipboard.writeText) {
    navigator.clipboard.writeText(text).then(function () { done(true); }, fallback);
  } else {
    fallback();
  }
}

document.addEventListener('click', function (ev) {
  var btn = ev.target.closest ? ev.target.closest('[data-copy]') : null;
  if (btn) { ltdCopy(btn); }
});
