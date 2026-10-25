# Running it

Two pieces: a backend on this laptop, and the app on a phone. They must be on
the same wifi.

## 1. The backend

    cd backend
    python3 -m uvicorn app.main:app --host 0.0.0.0 --port 8010

`--host 0.0.0.0` matters: without it the server only answers localhost and the
phone cannot reach it. Needs `backend/.env` with `GEMINI_API_KEY`.

Check it:

    curl http://localhost:8010/health

## 2. The app

Open `argonr.xcodeproj`, pick your phone, run. AR does nothing in the
simulator.

The address is already set to this laptop. If the dot under the title is
orange, the address is wrong — find the current one with:

    ipconfig getifaddr en0

and set it under Settings.

## 3. What to do

1. Describe a game — "a Star Wars Hoth battle, rebels against an AT-ST"
2. **Build the world.** One Argon pass writes every model, the layout and the
   rules. Two to four minutes.
3. Point the phone at a table. The battle plays out on it.
4. **Playtest and fix.** Argon plays its own game, reads the telemetry next to
   renders of its own work, decides what is broken, and rewrites the program.
   Each pass takes two to three minutes.
5. Tap **Show the loop** to see every pass: the score, the bugs, and how many
   characters Argon rewrote.
6. The version strip keeps every world. Tap v0 to go back to the first
   attempt.

## Where things live

| | |
|---|---|
| Deployed backend | `/model3d`, `/model3d/refine`, `/models` only |
| This laptop | those plus `/world`, `/world/iterate/stream`, `/world/playtest` |

The world endpoints are in PR #4. Once that is merged and redeployed, point
Settings back at the Cloud Run URL and the laptop is no longer needed.

## If something is wrong

**Orange dot** — wrong address, or the backend is not running.

**"Could not connect"** — check `--host 0.0.0.0`, and that both devices are on
the same network.

**Nothing on the table** — AR needs a real surface and a few seconds. The
coaching overlay tells you when it has found one.

**A pass fails** — the loop keeps the last world that worked rather than
losing it. The error says which step failed.
