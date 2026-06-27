// Neon Strip <-> Supabase bridge (web only). Loaded next to index.html via the export
// head_include, AFTER the supabase-js UMD CDN script. GDScript drives it through
// JavaScriptBridge.eval and polls window.__gogi for async results.
//
// Auth model: the preview user is deterministic from their Gogi uid (email+password derived
// from it), so the SAME Supabase auth user signs in on every reload -> RLS-scoped rows persist
// across refreshes. Values below are baked at build time (anon key is publishable, not secret).
(function () {
  var SB_URL = "__SUPABASE_URL__";
  var SB_ANON = "__SUPABASE_ANON_KEY__";
  var UID = "__GOGI_USER_ID__";
  var TABLE = "__SUPABASE_TABLE__";
  var sb = null, authUid = null;
  window.__gogi = { ready: false, loaded: false, data: "null", saveTs: 0, err: "", uid: "" };

  function client() {
    if (sb) return sb;
    if (!window.supabase || !window.supabase.createClient) { window.__gogi.err = "no-sdk"; return null; }
    sb = window.supabase.createClient(SB_URL, SB_ANON);
    return sb;
  }
  function creds() {
    var slug = UID.toLowerCase().replace(/[^a-z0-9]/g, "");
    return { email: "ns_" + slug + "@neonstrip.app", password: "NpStrip!" + UID + "_v1" };
  }

  window.gogiInit = async function () {
    try {
      var c = client();
      if (!c) { window.__gogi.ready = true; return; }
      var cr = creds();
      var r = await c.auth.signInWithPassword({ email: cr.email, password: cr.password });
      if (r.error) {
        await c.auth.signUp({ email: cr.email, password: cr.password });
        await c.auth.signInWithPassword({ email: cr.email, password: cr.password });
      }
      var gu = await c.auth.getUser();
      authUid = (gu && gu.data && gu.data.user) ? gu.data.user.id : null;
      window.__gogi.uid = authUid || "";
      window.__gogi.ready = true;
    } catch (e) { window.__gogi.err = "init:" + e; window.__gogi.ready = true; }
  };

  window.gogiLoad = async function () {
    window.__gogi.loaded = false;
    try {
      var c = client();
      if (!c || !authUid) { window.__gogi.data = "null"; window.__gogi.loaded = true; return; }
      var r = await c.from(TABLE).select("data").eq("user_id", authUid).maybeSingle();
      window.__gogi.data = (r && r.data && r.data.data) ? JSON.stringify(r.data.data) : "null";
      window.__gogi.loaded = true;
    } catch (e) { window.__gogi.err = "load:" + e; window.__gogi.data = "null"; window.__gogi.loaded = true; }
  };

  window.gogiSave = async function (json) {
    try {
      var c = client();
      if (!c || !authUid) return;
      var blob = JSON.parse(json);
      await c.from(TABLE).upsert(
        { user_id: authUid, data: blob, updated_at: new Date().toISOString() },
        { onConflict: "user_id" }
      );
      window.__gogi.saveTs = Date.now();
    } catch (e) { window.__gogi.err = "save:" + e; }
  };
})();
