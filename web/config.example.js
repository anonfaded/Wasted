// Optional for source builds and preconfigured deployments.
// The Wasted app's setup wizard generates the ready-to-host dashboard file; users do not
// normally edit this. Copy to config.js next to index.html only when building from source.
window.WASTED_CONFIG = {
  supabaseUrl: "https://YOUR-PROJECT.supabase.co",
  supabasePublishableKey: "sb_publishable_YOUR_KEY",
  productName: "Wasted Remote",
  version: "3.0.0",
  privacyUrl: "",
  supportUrl: "",
};
