# ft-push: sending push notifications

The database queues notifications (chat, round wraps, achievements) and this function sends them.
One-time setup, all in the Supabase dashboard:

1. **Keys.** Open `Documents\JALF secrets\push-keys.txt` on your PC. It's never committed.
2. **Secrets.** Go to Edge Functions → Secrets and add `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY`,
   `VAPID_SUBJECT` and `FT_PUSH_SECRET` with the values from that file.
3. **Deploy.** Go to Edge Functions → Deploy a new function → Via editor. Name it `ft-push`,
   paste in `index.ts` and deploy.
   Then, in the function's settings, turn **Enforce JWT verification off**. The database calls
   it with `FT_PUSH_SECRET` instead.
4. **Point the database at it.** Run the two `update ft_config …` lines from `push-keys.txt` in
   the SQL editor.

To check it's working, run `select * from ft_push_queue;` in the SQL editor. It should empty
within a few seconds of something being queued. The function's logs show how many messages were sent.

The public key is also in `index.html` (`VAPID_PUBLIC`). If you ever make new keys, update both
places. Every device then has to turn notifications on again.
