#!/usr/bin/env bash
# What `agentbus init-repo` reads out of a repository.
#
# A stranger installs the plugin, opens two sessions, and nothing happens,
# because their repository has no config and the old first run wrote a generic
# template they had to fill in by hand. Most people conclude the thing is broken
# and stop there. So the first run has to come back with this project's real
# ports and real start commands.
#
# The other half of the job is restraint. A detector that invents a port, or
# offers to restart somebody's database, writes a config that is worse than
# none: the guard either never fires or fires on the wrong thing, and both teach
# an agent that the bus is not to be trusted.

. "$AB_ROOT/tests/lib.sh"

# init-repo works on the directory it is standing in and needs no session.
init() {   # <repo> [<args…>] → its output
  local repo="$1"; shift
  ( cd "$repo" && "$AB_ROOT/bin/agentbus" init-repo "$@" 2>&1 )
}

config_of() {   # <repo> → the written config, or empty
  cat "$1/.claude/agent-bus.json" 2>/dev/null
}

# One field of one resource, so an assertion names what it is checking.
field() {   # <repo> <resource> <key>
  python3 -c "
import json, sys
try:
    cfg = json.load(open('$1/.claude/agent-bus.json'))
except Exception:
    sys.exit(0)
for r in cfg.get('resources', []):
    if r.get('name') == '$2':
        v = r.get('$3')
        print(json.dumps(v) if isinstance(v, (list, dict)) else (v if v is not None else ''))
        break"
}

names_of() {   # <repo> → the resource names, space separated
  python3 -c "
import json
try:
    cfg = json.load(open('$1/.claude/agent-bus.json'))
except Exception:
    raise SystemExit(0)
print(' '.join(r.get('name','') for r in cfg.get('resources', [])))"
}

new_repo() {   # <name> → a git repo with nothing in it
  local d; d=$(make_repo "$1")
  git -C "$d" add -A > /dev/null 2>&1
  git -C "$d" commit -qm init > /dev/null 2>&1
  printf '%s' "$d"
}

# ---- an empty repository still gets the universal resource -----------------

EMPTY=$(new_repo detempty)
out=$(init "$EMPTY")
assert_equal "worktree" "$(names_of "$EMPTY")" \
  "a repository with nothing in it gets only the checkout resource"
assert_contains "$out" "looked at this repository" "and is told what was found"
assert_equal "worktree" "$(field "$EMPTY" worktree scope)" \
  "which is scoped to one checkout"

# ---- a repository with no commits yet --------------------------------------
#
# Which is what `git init` leaves you with, and `init-repo` is one of the first
# things a new user runs. `git rev-parse --abbrev-ref HEAD` fails on an unborn
# HEAD and used to take the whole call down with it, so the repository got a
# key derived from its path — and that key changed the moment somebody made
# their first commit, orphaning anything written against the old one.

FRESH="$TEST_TMP/detfresh"
mkdir -p "$FRESH" && git -C "$FRESH" init -q . > /dev/null 2>&1
git -C "$FRESH" symbolic-ref HEAD refs/heads/main
git -C "$FRESH" config user.email t@e.i
git -C "$FRESH" config user.name t
key_of() {   # <repo> → the repo key doctor reports
  ( cd "$1" && "$AB_ROOT/bin/agentbus" doctor 2>/dev/null ) \
    | sed -n 's/^repo *: .*(\(.*\))$/\1/p'
}
before=$(key_of "$FRESH")
assert_not_contains "$before" "path:" \
  "a repository with no commits is still identified as a repository"
printf 'x\n' > "$FRESH/README"
git -C "$FRESH" add -A > /dev/null 2>&1
git -C "$FRESH" commit -qm first > /dev/null 2>&1
assert_equal "$before" "$(key_of "$FRESH")" \
  "and its key does not change when the first commit lands"

# ---- Next.js ---------------------------------------------------------------

NEXT=$(new_repo detnext)
printf '{"scripts":{"dev":"next dev"}}\n' > "$NEXT/package.json"
out=$(init "$NEXT")
assert_equal "server worktree" "$(names_of "$NEXT")" "a Next.js repo gets a server"
assert_equal "3000" "$(field "$NEXT" server port)" "on the port next uses by default"
assert_equal "npm run dev" "$(field "$NEXT" server start)" \
  "started the way this repository starts it"
assert_contains "$out" "package.json scripts.dev" "and is told where that came from"
assert_contains "$(field "$NEXT" server patterns)" 'next\\s+dev' \
  "the pattern pins the subcommand, not the bare word next"

# `\bnext\b` on its own would claim the server for any command carrying the
# word — which is how a guard starts firing on things it has no business in.
assert_not_contains "$(field "$NEXT" server patterns)" '"\\bnext\\b"' \
  "the bare framework word is not a pattern on its own"

# ---- the port and the package manager come from the repository -------------

BUN=$(new_repo detbun)
printf '{"scripts":{"dev":"vite --port 4321"}}\n' > "$BUN/package.json"
: > "$BUN/bun.lock"
init "$BUN" > /dev/null
assert_equal "4321" "$(field "$BUN" server port)" \
  "an explicit --port beats the framework default"
assert_equal "bun run dev" "$(field "$BUN" server start)" \
  "and the lockfile decides the package manager"

PNPM=$(new_repo detpnpm)
printf '{"scripts":{"start":"nest start --watch"}}\n' > "$PNPM/package.json"
: > "$PNPM/pnpm-lock.yaml"
init "$PNPM" > /dev/null
assert_equal "pnpm run start" "$(field "$PNPM" server start)" "pnpm is recognised"
assert_equal "3000" "$(field "$PNPM" server port)" "and nest's default port"

# ---- Python ----------------------------------------------------------------

FASTAPI=$(new_repo detfastapi)
printf 'fastapi==0.115.0\nuvicorn[standard]==0.32.0\n' > "$FASTAPI/requirements.txt"
out=$(init "$FASTAPI")
assert_contains "$(names_of "$FASTAPI")" "api" "a FastAPI repo gets an api resource"
assert_equal "8000" "$(field "$FASTAPI" api port)" "on :8000"
assert_contains "$(field "$FASTAPI" api patterns)" "uvicorn" "matched on uvicorn"
assert_contains "$out" "requirements.txt" "and told where that came from"

DJANGO=$(new_repo detdjango)
printf 'import sys\n' > "$DJANGO/manage.py"
mkdir -p "$DJANGO/proj" && printf 'DEBUG = True\n' > "$DJANGO/proj/settings.py"
init "$DJANGO" > /dev/null
assert_equal "python manage.py runserver" "$(field "$DJANGO" server start)" \
  "manage.py next to a settings.py is Django"

NOTDJANGO=$(new_repo detnotdjango)
printf 'import sys\n' > "$NOTDJANGO/manage.py"
init "$NOTDJANGO" > /dev/null
assert_equal "worktree" "$(names_of "$NOTDJANGO")" \
  "a manage.py with no settings.py beside it is not"

# ---- a database is found and deliberately not given a start command --------

COMPOSE=$(new_repo detcompose)
cat > "$COMPOSE/docker-compose.yml" <<'YML'
services:
  db:
    image: postgres:16
    ports: ["5432:5432"]
  cache:
    image: redis:7
  web:
    image: nginx:latest
YML
out=$(init "$COMPOSE")
assert_contains "$(names_of "$COMPOSE")" "db" "a compose file with a database gets one"
assert_equal "" "$(field "$COMPOSE" db start)" \
  "with no start command — agent-bus must not restart somebody's database"
assert_contains "$out" "postgres:16" "and the image is quoted back"
assert_contains "$(field "$COMPOSE" db patterns)" "psql" "psql is guarded"
assert_contains "$(field "$COMPOSE" db patterns)" "redis-cli" "and so is redis-cli"
assert_not_contains "$(field "$COMPOSE" db patterns)" "mysql" \
  "but not clients for images this repository does not have"
assert_contains "$(field "$COMPOSE" db patterns)" "alembic" "migrations are guarded"

NODB=$(new_repo detnodb)
printf 'services:\n  web:\n    image: nginx:latest\n' > "$NODB/docker-compose.yml"
init "$NODB" > /dev/null
assert_equal "worktree" "$(names_of "$NODB")" \
  "a compose file with no database gets no db resource"

# ---- end-to-end runners point at the servers -------------------------------

E2E=$(new_repo dete2e)
printf '{"scripts":{"dev":"next dev"}}\n' > "$E2E/package.json"
printf 'export default {}\n' > "$E2E/playwright.config.ts"
out=$(init "$E2E")
assert_contains "$(names_of "$E2E")" "e2e" "a playwright config gets an e2e resource"
assert_contains "$(field "$E2E" e2e implies)" "server" \
  "which implies the server it is only meaningful against"
assert_contains "$out" "implies server" "and says so"

MAESTRO=$(new_repo detmaestro)
mkdir -p "$MAESTRO/maestro"
init "$MAESTRO" > /dev/null
assert_contains "$(names_of "$MAESTRO")" "e2e" "a maestro directory counts too"
assert_equal "" "$(field "$MAESTRO" e2e implies)" \
  "and implies nothing when no server was found"

# ---- a Makefile and a Procfile ---------------------------------------------

MAKE=$(new_repo detmake)
printf 'dev:\n\tuvicorn app:api --port 9100\n\nclean:\n\trm -rf build\n' > "$MAKE/Makefile"
init "$MAKE" > /dev/null
assert_equal "make dev" "$(field "$MAKE" server start)" "a Makefile dev target is found"
assert_equal "9100" "$(field "$MAKE" server port)" "with the port from its recipe"

PROC=$(new_repo detproc)
printf 'web: gunicorn app:wsgi --bind 0.0.0.0:8080\nworker: celery -A app worker\n' > "$PROC/Procfile"
init "$PROC" > /dev/null
assert_contains "$(names_of "$PROC")" "web" "a Procfile gives one resource per process"
assert_contains "$(names_of "$PROC")" "worker" "including the ones that are not servers"

# ---- two servers in one repository do not collide --------------------------

MONO=$(new_repo detmono)
printf '{"scripts":{"dev":"next dev"}}\n' > "$MONO/package.json"
printf 'fastapi\n' > "$MONO/requirements.txt"
init "$MONO" > /dev/null
assert_contains "$(names_of "$MONO")" "server" "a monorepo gets the node server"
assert_contains "$(names_of "$MONO")" "api" "and the python one, under its own name"

# ---- writing, not writing, and overwriting ---------------------------------

DRY=$(new_repo detdry)
printf '{"scripts":{"dev":"next dev"}}\n' > "$DRY/package.json"
out=$(init "$DRY" --dry-run)
assert_no_file "$DRY/.claude/agent-bus.json" "--dry-run writes nothing"
assert_contains "$out" "nothing was written" "and says so"
assert_contains "$out" '"port": 3000' "while showing what it would have written"

init "$DRY" > /dev/null
assert_file "$DRY/.claude/agent-bus.json" "a second run without --dry-run writes it"
printf '{"resources": []}\n' > "$DRY/.claude/agent-bus.json"
out=$(init "$DRY")
assert_contains "$out" "already configured" "an existing config is not overwritten"
assert_equal "" "$(names_of "$DRY")" "and is left exactly as it was"
init "$DRY" --force > /dev/null
assert_contains "$(names_of "$DRY")" "server" "--force overwrites it"

LOCAL=$(new_repo detlocal)
printf '{"scripts":{"dev":"next dev"}}\n' > "$LOCAL/package.json"
out=$(init "$LOCAL" --local)
assert_no_file "$LOCAL/.claude/agent-bus.json" "--local writes nothing into the repo"
assert_contains "$out" "machine-local" "and says where it went instead"
assert_equal 1 "$(ls "$AGENTBUS_HOME"/repos/*.json 2>/dev/null | wc -l | tr -d ' ')" \
  "the override lands in the machine's own state"

# ---- what is written is actually usable ------------------------------------
#
# A config that reads well and guards nothing is the failure this milestone is
# about. Feed a real command through the real guard and see it claimed.

USABLE=$(new_repo detusable)
printf '{"scripts":{"dev":"next dev"}}\n' > "$USABLE/package.json"
init "$USABLE" > /dev/null
commit_all "$USABLE"
WT=$(make_worktree "$USABLE" detusable-wt2)
new_session det-a "$USABLE"
new_session det-b "$WT"
assert_contains "$(cat "$AGENTBUS_HOME/guard-tokens")" "3000" \
  "the detected port reaches the shell fast path"
out=$(ab_hook pre-tool "$(payload bash sid=det-a "cwd=$USABLE" \
  "cmd=curl -sf http://localhost:3000/api/health" id=det-1)")
assert_allow "$out" "a command against the detected port runs"
assert_equal 1 "$(locks_held)" "and claims the resource the detector wrote"
out=$(ab_hook pre-tool "$(payload bash sid=det-b "cwd=$WT" \
  "cmd=curl -sf http://localhost:3000/api/health" id=det-2)")
assert_deny "$out" "while the other session is refused"
ab_hook post-bash "$(payload post-bash sid=det-a "cwd=$USABLE" id=det-1)" > /dev/null

# …and a commit message that merely names the framework does not.
out=$(ab_hook pre-tool "$(payload bash sid=det-a "cwd=$USABLE" \
  "cmd=git commit -m \"bump next to 15 and move dev to :3000\"" id=det-3)")
assert_allow "$out" "a commit message naming the framework claims no server"
assert_contains "$(field "$USABLE" server patterns)" "next" \
  "even though the server's pattern is about next"

finish
