// Serves the release bucket at /releases/: each version's disk image, and latest.json, which Codec
// reads to look for updates. Ranges and conditional requests go through to R2, so a download that
// stops can carry on where it left off.

export async function onRequest({ request, env, params }) {
  if (request.method !== "GET" && request.method !== "HEAD") {
    return new Response("Method not allowed", { status: 405, headers: { allow: "GET, HEAD" } });
  }
  const key = (params.path ?? []).join("/");
  if (!key || key.includes("..")) return new Response("Not found", { status: 404 });

  const object = request.method === "HEAD"
    ? await env.RELEASES.head(key)
    : await env.RELEASES.get(key, { range: request.headers, onlyIf: request.headers });
  if (object === null) return new Response("Not found", { status: 404 });

  const headers = new Headers();
  object.writeHttpMetadata(headers);
  headers.set("etag", object.httpEtag);
  headers.set("accept-ranges", "bytes");
  headers.set("access-control-allow-origin", "*");

  if (request.method === "HEAD") {
    headers.set("content-length", String(object.size));
    return new Response(null, { headers });
  }
  // Without a body, a condition (If-None-Match, say) wasn't met.
  if (!("body" in object)) return new Response(null, { status: 304, headers });

  let status = 200;
  if (object.range && request.headers.has("range")) {
    const { offset = 0, length } = object.range;
    const end = length === undefined ? object.size - 1 : offset + length - 1;
    headers.set("content-range", `bytes ${offset}-${end}/${object.size}`);
    headers.set("content-length", String(end - offset + 1));
    status = 206;
  } else {
    headers.set("content-length", String(object.size));
  }
  return new Response(object.body, { status, headers });
}
