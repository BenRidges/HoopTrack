# Supabase server code

The database schema and RLS policies were set up in the dashboard (Phase 9);
this folder holds server code that ships alongside the app.

| Function | Used by | What it does |
|---|---|---|
| `delete-account` | Profile → Delete account | Deletes the caller's synced rows, shared telemetry and auth user. Required by App Store Guideline 5.1.1(v). |

Deploy with the [Supabase CLI](https://supabase.com/docs/guides/cli):

```
supabase login
supabase link --project-ref <project ref>
supabase functions deploy delete-account
```

Also in the dashboard (Authentication → URL Configuration → Redirect URLs),
allow both:

- `hooptrack://auth/callback` (email confirmation)
- `hooptrack://auth/reset` (password reset)
