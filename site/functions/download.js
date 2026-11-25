// /download always gets the newest Codec: it reads latest.json from the release bucket and redirects
// to that release's disk image, so the website's links never name a version.

export async function onRequestGet({ request, env }) {
  let target = "https://github.com/srozen/codec/releases/latest";
  const latest = await env.RELEASES.get("latest.json");
  if (latest !== null) {
    const release = await latest.json();
    const image = (release.assets ?? []).find((asset) => asset.name.toLowerCase().endsWith(".dmg"));
    target = image ? new URL(image.browser_download_url, request.url).toString() : release.html_url;
  }
  return new Response(null, { status: 302, headers: { location: target, "cache-control": "no-store" } });
}

// Link checkers and `curl -I` ask with HEAD; without this, they'd get the home page instead.
export const onRequestHead = onRequestGet;
