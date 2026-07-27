# rigitup-workflows

Reusable Workflows und Actions für [rigitup](https://github.com/leonweimann/rigitup)-Pipelines. Aufrufer referenzieren
sie mit vollem Commit-SHA; nichts wird kopiert.

Referenzimplementierung: [`rigitup-e2e-uv`](https://github.com/leonweimann/rigitup-e2e-uv)
— dort steht ein vollständiger Aufrufer im Einsatz.

## Aufruf

```yaml
jobs:
  ci:
    uses: leonweimann/rigitup-workflows/.github/workflows/uv-ci.yaml@<sha> # v0.1.0
    permissions:
      contents: read
      pull-requests: read
      packages: write
    with:
      app: app
      port: 8000
```

Zwei Regeln, die jeden Aufruf betreffen:

- **Required Checks gehören in den Aufrufer.** Ein Job aus einem Reusable
  Workflow heißt `<aufrufender Job> / <innerer Job>`, etwa `ci / Python`. Steht
  der Name im Branch-Ruleset, braucht es dafür einen eigenen Job im Aufrufer.
- **Berechtigungen nur einschränkbar.** Verlangt ein Job im Reusable Workflow
  mehr, als der Aufrufer gewährt, schlägt der _gesamte_ Lauf mit
  `startup_failure` fehl — ohne Hinweis auf Berechtigungen.

## uv-ci.yaml

Lint, Format, Typen, Tests, Container-Prüfung, Release-Erkennung und
Image-Veröffentlichung.

| Input            | Typ    | Pflicht | Bedeutung                             |
| ---------------- | ------ | ------- | ------------------------------------- |
| `app`            | string | ja      | Paket- und Image-Name                 |
| `port`           | number | ja      | Port des Containers                   |
| `python-version` | string | nein    | statt `.python-version`, Vorgabe 3.14 |

**Outputs** `is_release`, `part`, `version`, `tag`, `pr_number` — leer außer bei
einem Release-Commit auf `main`.

**Permissions** `contents: read`, `pull-requests: read`, `packages: write`.
**Secrets** keine.

| Job              | Läuft bei                      |
| ---------------- | ------------------------------ |
| `Python`         | immer                          |
| `Docker check`   | allem außer `push`             |
| `Classify`       | `push` auf `main`              |
| `Docker publish` | `push` auf `main`, nur Release |

## metadata.yaml

Autorenzuweisung, Label aus dem Conventional-Commit-Titel, genau eine
Release-Notes-Kategorie je PR.

**Inputs** keine. **Secrets** keine.
**Permissions** `contents: read`, `issues: write`, `pull-requests: write`.

Erwartet die Labels aus `.github/release.yaml` des Aufrufers. Release-PRs
(`release/vX.Y.Z`) werden von der Autorenzuweisung übergangen.

## release.yaml

Digest sammeln, auf Versionstags heben, Tag anlegen, unveränderlichen Release
mit `release-manifest.json` veröffentlichen.

**Inputs** `app`, `port`, `sha`, `version`, `tag` — alle Pflicht.
**Outputs** `digest`, `release_url`, `prerelease`.
**Permissions** `contents: write`, `packages: write`. **Secrets** keine.

Der Tag entsteht unsigniert über die API. Das Tag-Ruleset des Aufrufers darf
`creation` daher nicht blockieren.

```json
{
  "commit": "684a9e07…",
  "images": {
    "app": { "digest": "sha256:9a7e25bb…", "repository": "ghcr.io/…/app" }
  },
  "signing": { "build_provenance": true, "sbom": true },
  "tag": "v0.0.4",
  "version": "0.0.4"
}
```

## deploy-dokploy.yaml

Rendert `compose.dokploy.yaml` auf die Image-Referenz aus dem Release, übergibt
sie an Dokploy und wartet, bis `/health` die neue Version meldet. Sonst Rollback
auf die vorherige Compose-Konfiguration.

| Input         | Typ     | Pflicht | Bedeutung                         |
| ------------- | ------- | ------- | --------------------------------- |
| `environment` | string  | ja      | Environment mit den Zugangsdaten  |
| `app`         | string  | ja      | Service-Name in der Compose-Datei |
| `version`     | string  | ja      | ohne führendes `v`                |
| `tag`         | string  | ja      | mit führendem `v`                 |
| `sha`         | string  | ja      | veröffentlichter Commit           |
| `digest`      | string  | ja      | Digest des Images                 |
| `release_url` | string  | nein    | für die Zusammenfassung           |
| `dry-run`     | boolean | nein    | prüft alles, ändert nichts        |

**Permissions** `contents: read`.
**Secrets** `secrets: inherit` ist **erforderlich** — `environment:` im
aufgerufenen Job allein reicht nicht, das Secret bliebe leer.

| Environment                 | Art      | Bedeutung                       |
| --------------------------- | -------- | ------------------------------- |
| `DOKPLOY_API_KEY`           | Secret   | API-Schlüssel                   |
| `DOKPLOY_BASE_URL`          | Variable | HTTPS-Basis der Instanz         |
| `DOKPLOY_COMPOSE_ID`        | Variable | letztes Segment der Service-URL |
| `PRODUCTION_APP_URL`        | Variable | öffentliche Adresse der App     |
| `PRODUCTION_DEPLOY_ENABLED` | Variable | erst `true` schaltet scharf     |

Der Dokploy-Service muss **Raw Docker Compose** sein.

## Voraussetzungen im aufrufenden Repository

- `pyproject.toml` mit `[project].version`, `Dockerfile`, `compose.dokploy.yaml`
  in der Wurzel
- Health-Endpunkt mit HTTP 200 und
  `{"status": "ok", "version": "<Release-Version>"}`
- `.github/release.yaml` und die darin genannten Labels, darunter `deployment`
- `scripts/release.sh`: Branch `release/vX.Y.Z`, Titel `release(<part>): vX.Y.Z`,
  PR mit Label `deployment` und Auto-Merge
- Rulesets, die genau die Check-Namen des Aufrufers fordern

## Versionierung

Die Schnittstelle sind Inputs, Outputs, geforderte Berechtigungen, Job-Namen
und die Erwartungen ans aufrufende Repository.

| Änderung                                   | Stufe |
| ------------------------------------------ | ----- |
| neuer Pflicht-Input, entfernter Output     | major |
| zusätzlich geforderte Berechtigung         | major |
| umbenannter Job                            | major |
| neue Pflichtdatei im Aufrufer              | major |
| neuer optionaler Input, neuer Output       | minor |
| Fehlerbehebung ohne Schnittstellenänderung | patch |

Zeile 2 und 3 sehen additiv aus und sind es nicht: Die eine erzeugt
`startup_failure`, die andere ändert den Check-Namen und blockiert das Ruleset
des Konsumenten. Beides schlägt erst zu, wenn der Aufrufer seinen Pin hebt.

## Release

`self-release.yaml` manuell auslösen, Zielversion als Input. Vier Stufen vor dem
Tag: Versionsformat, Self-check grün **für genau diesen Commit**,
Selbstreferenzen aktuell, dann Tag und Release.

Konsumenten pinnen den SHA und notieren die Version als Kommentar. Dependabot
hebt solche Pins auf neue Tags — ohne Tags bleibt ein Repository auf dem Stand
seiner Einrichtung.

Noch nicht enthalten: ein Canary-Durchlauf gegen ein echtes aufrufendes
Repository. Bis dahin prüft der Release Syntax und Konsistenz, nicht Verhalten.

## Entwicklung

`.github/` enthält Bibliothek und Eigenbetrieb nebeneinander; unterschieden
wird am Auslöser:

| Pfad                                                             | Rolle        | Auslöser               |
| ---------------------------------------------------------------- | ------------ | ---------------------- |
| `.github/workflows/{uv-ci,metadata,release,deploy-dokploy}.yaml` | Bibliothek   | `workflow_call`        |
| `.github/actions/*`, `scripts/{ci,release,deploy}/*`             | Bibliothek   | `uses:`                |
| `.github/workflows/self-check.yaml`                              | Eigenbetrieb | `push`, `pull_request` |
| `.github/workflows/self-release.yaml`                            | Eigenbetrieb | `workflow_dispatch`    |
| `.github/dependabot.yaml`                                        | Eigenbetrieb | wöchentlich            |
| `scripts/ci/check-self-references.sh`                            | Eigenbetrieb | Self-check und Release |

Reusable Workflows müssen unter `.github/workflows/` liegen — Unterverzeichnisse
und Symlinks funktionieren dort nicht. Skripte erreichen einen Workflow nur über
eine Action: `github.workflow_sha` zeigt auf den Lauf des _Aufrufers_, dessen
Commit hier nicht existiert.

**Inhalt und Pins gehören in getrennte Commits.** `check-self-references.sh`
verlangt, dass jede Referenz auf dieses Repository den jüngsten Commit trifft,
der eine Action oder ein Skript geändert hat. Ein Commit, der Action und Pin
zugleich ändert, macht sich selbst zum jüngsten Inhalts-Commit — der Pin darin
zeigt dann auf den davor. Aus demselben Grund ignoriert Dependabot die
Selbstreferenzen.

`self-check.yaml` fährt actionlint, shellcheck, zizmor und die
Selbstreferenz-Prüfung. Er prüft die Bibliothek, führt sie aber nicht aus — ein
Fehler hier trifft jedes eingerichtete Repository gleichzeitig.
