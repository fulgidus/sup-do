# sup-do

A tiny keepalive for Supabase: periodically writes an audit log row to your database so the project doesn't get paused for inactivity on the free tier.

Runs as a `systemd --user` timer on Linux (or `launchd` on macOS). No root required, no long-running daemon: it wakes up at the configured times, does one `INSERT` into an `audit_logs` table, and exits.

## How it works

1. A timer (systemd or launchd) wakes the script at fixed times (default: 04:00 / 10:00 / 16:00 / 22:00).
2. The script collects a precise timestamp, machine info (uptime, CPU load, RAM, hostname), and builds a JSON payload.
3. It sends a REST `POST` to `https://<project-ref>.supabase.co/rest/v1/audit_logs` using the **secret key** in the `apikey` header.
4. It logs the outcome and response time locally to `~/.local/state/supabase_keepalive.log`.

On Linux, if the machine is off or asleep at the scheduled time, the timer catches up the missed run at the next boot (`Persistent=true`). **launchd has no exact equivalent** - a missed `StartCalendarInterval` firing is not automatically replayed when the Mac wakes up. If catch-up matters on macOS, consider switching to `StartInterval` with your own last-run bookkeeping, or just accept that a sleeping laptop may skip a slot.

## Requirements

- Bash, `curl`, `jq`
- A Supabase project with an `audit_logs` table (schema below)
- **macOS**: `brew install coreutils` (for `gdate`, needed for sub-second timestamp precision - the script has an automatic fallback if it's not installed, at the cost of precision)

## Table schema

```sql
create table public.log_sources (
  id bigint primary key,
  created_at timestamptz not null default now(),
  name text not null,
  description text
);

create table public.audit_logs (
  id uuid primary key default uuid_generate_v7(), -- or your instance's equivalent
  created_at timestamptz not null default now(),
  source bigint references public.log_sources(id),
  level varchar not null,
  message text,
  payload jsonb
);
```

Register your source before first use:

```sql
insert into public.log_sources (id, created_at, name, description)
values (1, now(), 'Machine name', 'Free-form description');
```

## Setup

### 1. Configuration

Copy the example file and fill in your keys (**never commit this file**):

```bash
cp supabase_keepalive.example.env ~/.config/supabase_keepalive.env
chmod 600 ~/.config/supabase_keepalive.env
```

Required content in `~/.config/supabase_keepalive.env`:

```bash
SUPABASE_SECRET_KEY=sb_secret_xxxxxxxx
PROJECT_REF=xxxxxxxxxxxxxxxx
```

> Use the **secret key** (new `sb_secret_...` format), not the legacy `service_role`. The secret key bypasses Row Level Security policies - keep it out of version control, `chmod 600`, never in a public repository.
>
> Important: with Supabase's new API keys (`sb_publishable_...` / `sb_secret_...`), the `Authorization: Bearer` header **must not be used** - they aren't JWTs and the platform rejects them there. Pass them only via the `apikey` header.

### 2. Install the script

```bash
mkdir -p ~/.local/bin
cp supabase_keepalive.sh ~/.local/bin/
chmod +x ~/.local/bin/supabase_keepalive.sh
```

### 3a. Linux (systemd --user)

```bash
mkdir -p ~/.config/systemd/user
cp supabase_keepalive.service supabase_keepalive.timer ~/.config/systemd/user/

systemctl --user daemon-reload
systemctl --user enable --now supabase_keepalive.timer
```

Verify:
```bash
systemctl --user list-timers supabase_keepalive.timer
```

### 3b. macOS (launchd)

```bash
cp com.sup-do.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.sup-do.plist
```

Adjust the `Hour`/`Minute` entries under `StartCalendarInterval` in the plist for different run times.

## Manual test

Linux:
```bash
systemctl --user start supabase_keepalive.service
cat ~/.local/state/supabase_keepalive.log
```

macOS:
```bash
launchctl start com.sup-do
cat ~/.local/state/supabase_keepalive.log
```

Expected output:
```
2026-07-08T11:38:26.01234+02:00 audit insert status=201 elapsed=0.3421s
```

## Customizing the schedule

Edit `OnCalendar` in the `.timer` file (systemd) or `StartCalendarInterval` in the `.plist` (launchd). Default: 4 times a day, every 6 hours.

## Security notes

- Never commit `supabase_keepalive.env` - only the `.example.env` file.
- The secret key bypasses RLS: if compromised, an attacker has full access to the `audit_logs` table (and any other table, if the key isn't scoped). Use a dedicated secret key for this purpose if possible, not your project's main one.
- The local log (`~/.local/state/supabase_keepalive.log`) contains no secrets - just timestamp/status/elapsed - safe to share for debugging.
