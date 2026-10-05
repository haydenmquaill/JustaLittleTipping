// ft-push — sends queued push notifications (see migrations/009_push_notifications.sql).
// The database's 5-second job calls this whenever ft_push_queue has something in it. It claims up to
// 200 messages, signs each one with the VAPID keys and sends it to every device the person turned
// notifications on for. Devices the browser says are gone (404 / 410) are forgotten.
//
// Secrets (Edge Functions → Secrets): VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY, VAPID_SUBJECT, FT_PUSH_SECRET.
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are provided automatically.
// Deploy with JWT verification OFF — the database calls it with FT_PUSH_SECRET instead.
import webpush from "npm:web-push@3.6.7";
import { createClient } from "npm:@supabase/supabase-js@2";

const env = (k: string) => Deno.env.get(k) ?? "";
webpush.setVapidDetails(env("VAPID_SUBJECT"), env("VAPID_PUBLIC_KEY"), env("VAPID_PRIVATE_KEY"));
const sb = createClient(env("SUPABASE_URL"), env("SUPABASE_SERVICE_ROLE_KEY"), { auth: { persistSession: false } });

type Sub = { endpoint: string; p256dh: string; auth: string };
type Job = { id: number; title: string; body: string; url: string; tag: string | null; subs: Sub[] };

Deno.serve(async (req) => {
  if (req.headers.get("Authorization") !== `Bearer ${env("FT_PUSH_SECRET")}`) {
    return new Response("unauthorised", { status: 401 });
  }
  const { data, error } = await sb.rpc("ft_push_claim", { p_limit: 200 });
  if (error) return new Response(error.message, { status: 500 });

  let sent = 0, dropped = 0, failed = 0;
  await Promise.all((data as Job[]).flatMap((job) =>
    job.subs.map(async (s) => {
      try {
        await webpush.sendNotification(
          { endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } },
          JSON.stringify({ title: job.title, body: job.body, url: job.url, tag: job.tag }),
          { TTL: 60 * 60 },
        );
        sent++;
      } catch (e) {
        const code = (e as { statusCode?: number }).statusCode;
        if (code === 404 || code === 410) { await sb.rpc("ft_push_drop", { p_endpoint: s.endpoint }); dropped++; }
        else { failed++; console.error("push failed", code, (e as Error).message); }
      }
    })
  ));
  return Response.json({ messages: (data as Job[]).length, sent, dropped, failed });
});
