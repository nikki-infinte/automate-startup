# One-Command Local Dev Runner (`.\dev`)

Run one command (`.\dev`) to **automatically open IntelliJ IDEA**, launch your Spring Boot apps in **IntelliJ Debug mode** (with live logs & breakpoints inside IntelliJ's Debug console) in order (`App1 -> App2 -> ...`), and then start your frontend apps (`npm run dev`).

## Only 3 Commands

```powershell
.\dev          # Open IntelliJ & debug Spring apps sequentially -> start frontends -> show status
.\dev status   # Check what is UP / DOWN, runner (IntelliJ / Terminal), ports, and health
.\dev stop     # Stop all running Spring Boot & Frontend apps cleanly (without closing IntelliJ)
```

## Minimal `apps.json` (Plug & Play)

Just list your apps in startup order (`path` + optional `port` / `command`):

```json
[
  { "path": "./demo-apps/app1-service", "port": 8081, "command": "mvn spring-boot:run" },
  { "path": "./demo-apps/app2-service", "port": 8082, "command": "mvn spring-boot:run" },
  { "path": "D:/projects/frontend-1",   "port": 5173, "command": "npm run dev" }
]
```

## How It Works Under the Hood

1. **Auto-Discovery** ([scripts/dev-engine.ps1](scripts/dev-engine.ps1)):
   - Detects Spring Boot (`pom.xml`) vs Frontend (`package.json`).
   - Automatically finds `@SpringBootApplication` main class, Maven `<artifactId>`, `server.port`, and `/api/health` or `/actuator/health`.
   - Automatically locates `idea64.exe` (PATH, `C:\Program Files\JetBrains`, Toolbox, Windows Registry — or set `$env:INTELLIJ_EXE`).
2. **Native IntelliJ Debug Mode**:
   - Auto-generates `.idea/runConfigurations/<app>.xml` (`Application` run config) inside each Spring Boot project.
   - Launches `idea64.exe "<app.path>"` automatically (no need to open IntelliJ manually).
   - Focuses the IntelliJ project window and triggers `Shift+F9` (Debug) so live logs & breakpoints run right inside IntelliJ's Debug tool window.
   - Polls positive health (`HTTP 200`) on App1 before opening & debugging App2.
3. **Clean Stop (`.\dev stop`)**:
   - Stops each Spring Boot JVM by its listening port (leaving IntelliJ open cleanly) and closes any frontend terminals.

> **First-time open note:** Because IntelliJ has no native CLI `--debug` flag, the very first time a brand-new folder opens in IntelliJ you may see a one-time **"Trust Project?"** dialog or initial Maven indexing. Once trusted/indexed, `.\dev` retries `Shift+F9` automatically (or you can press `Shift+F9` once and `.\dev` immediately continues to App2).
