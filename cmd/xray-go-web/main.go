package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"html/template"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"time"
)

const (
	defaultListen = "0.0.0.0:18088"
	configPath    = "/opt/etc/xray/vless-go-web.conf"
	tokenPath     = "/opt/etc/xray/vless-go-web.token"
)

type action struct {
	ID          string
	Label       string
	Description string
	Command     []string
	Timeout     time.Duration
	Group       string
	Tone        string
}

type pageData struct {
	Listen        string
	Token         string
	Status        string
	Output        string
	Active        string
	Primary       string
	Backup        string
	Watchdog      string
	Recovery      string
	Proxy0        string
	Health        string
	PrimarySel    string
	BackupSel     string
	Actions       []action
}

var actions = []action{
	{ID: "status", Label: "Xray Go status", Description: "Единый статус failover, watchdog и recovery", Command: []string{"/opt/bin/xray-go", "status"}, Timeout: 20 * time.Second, Group: "overview", Tone: "primary"},
	{ID: "doctor", Label: "Doctor support", Description: "Безопасная диагностика без raw VLESS/subscription", Command: []string{"/opt/bin/xray-go", "doctor", "--support"}, Timeout: 150 * time.Second, Group: "diagnostics", Tone: "primary"},
	{ID: "switch-primary", Label: "Switch primary", Description: "Переключить активный профиль на primary", Command: []string{"/opt/bin/xray-go", "switch", "primary"}, Timeout: 90 * time.Second, Group: "failover", Tone: "purple"},
	{ID: "switch-backup", Label: "Switch backup", Description: "Переключить активный профиль на backup", Command: []string{"/opt/bin/xray-go", "switch", "backup"}, Timeout: 90 * time.Second, Group: "failover", Tone: "amber"},
	{ID: "update-active", Label: "Update active config", Description: "Перегенерировать активный Xray config", Command: []string{"/opt/bin/vless-go-failover", "update-active"}, Timeout: 120 * time.Second, Group: "updates", Tone: "cyan"},
	{ID: "auto-update-run", Label: "Run auto-update", Description: "Запустить selector-aware auto-update сейчас", Command: []string{"/opt/bin/vless-go-auto-update", "run"}, Timeout: 150 * time.Second, Group: "updates", Tone: "cyan"},
	{ID: "update-go", Label: "Update Go edition", Description: "Обновить xray-go helpers и Go edition", Command: []string{"/opt/bin/xray-go", "update"}, Timeout: 300 * time.Second, Group: "updates", Tone: "cyan"},
	{ID: "update-core", Label: "Update Xray-core", Description: "Обновить Xray-core через безопасный updater", Command: []string{"/opt/bin/xray-go", "update-core"}, Timeout: 360 * time.Second, Group: "updates", Tone: "danger"},
	{ID: "recover-status", Label: "Recovery status", Description: "Показать статус тихой hourly recovery", Command: []string{"/opt/bin/xray-go", "recover", "status"}, Timeout: 30 * time.Second, Group: "recovery", Tone: "secondary"},
	{ID: "recover-check", Label: "Recovery check", Description: "Проверить здоровье без recovery-действий", Command: []string{"/opt/bin/xray-go", "recover", "check"}, Timeout: 45 * time.Second, Group: "recovery", Tone: "secondary"},
	{ID: "recover-run", Label: "Recover now", Description: "Запустить self-healing цепочку сейчас", Command: []string{"/opt/bin/xray-go", "recover"}, Timeout: 180 * time.Second, Group: "recovery", Tone: "amber"},
	{ID: "recover-enable", Label: "Enable hourly", Description: "Включить ежечасную тихую проверку", Command: []string{"/opt/bin/xray-go", "recover", "enable-hourly"}, Timeout: 45 * time.Second, Group: "recovery", Tone: "cyan"},
	{ID: "recover-disable", Label: "Disable hourly", Description: "Отключить ежечасную recovery-проверку", Command: []string{"/opt/bin/xray-go", "recover", "disable-hourly"}, Timeout: 45 * time.Second, Group: "recovery", Tone: "secondary"},
	{ID: "restart-xray", Label: "Restart Xray", Description: "Перезапустить S24xray", Command: []string{"/opt/etc/init.d/S24xray", "restart"}, Timeout: 45 * time.Second, Group: "maintenance", Tone: "secondary"},
	{ID: "restart-watchdog", Label: "Restart watchdog", Description: "Перезапустить S26vless-go-watchdog", Command: []string{"/opt/etc/init.d/S26vless-go-watchdog", "restart"}, Timeout: 45 * time.Second, Group: "maintenance", Tone: "secondary"},
	{ID: "cleanup-dry-run", Label: "Cleanup dry-run", Description: "Предпросмотр безопасной очистки", Command: []string{"/opt/bin/vless-go-cleanup", "--dry-run"}, Timeout: 45 * time.Second, Group: "maintenance", Tone: "secondary"},
	{ID: "history", Label: "History", Description: "История переключений", Command: []string{"/opt/bin/xray-go", "history"}, Timeout: 30 * time.Second, Group: "logs", Tone: "secondary"},
	{ID: "recovery-log", Label: "Recovery log", Description: "Последние строки recovery log", Command: []string{"/bin/sh", "-c", "tail -n 100 /opt/var/log/vless-go-recover.log 2>/dev/null || true"}, Timeout: 30 * time.Second, Group: "logs", Tone: "secondary"},
	{ID: "watchdog-log", Label: "Watchdog log", Description: "Последние строки watchdog log", Command: []string{"/bin/sh", "-c", "tail -n 100 /opt/var/log/vless-go-watchdog.log 2>/dev/null || true"}, Timeout: 30 * time.Second, Group: "logs", Tone: "secondary"},
}

var page = template.Must(template.New("page").Funcs(template.FuncMap{"actionsIn": actionsIn}).Parse(`<!doctype html>
<html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Xray Go Control</title>
<style>
:root{--bg:#08090c;--panel:#15171c;--line:#343844;--text:#f7f7f8;--muted:#a4acb8;--blue:#2563eb;--cyan:#0891b2;--green:#16a34a;--amber:#d97706;--red:#b91c1c;--purple:#7c3aed}*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font-family:system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}.content{max-width:1280px;margin:0 auto;padding:24px}.top{display:flex;justify-content:space-between;gap:18px;align-items:flex-start;background:#101116;border:1px solid var(--line);border-radius:22px;padding:22px;margin-bottom:18px}h1{font-size:34px;margin:0 0 8px}h2{margin:0 0 14px;font-size:21px}.muted{color:var(--muted)}.listen{font-size:13px;color:var(--muted);margin-top:8px}.badge{display:inline-flex;gap:8px;align-items:center;border-radius:999px;padding:10px 14px;font-weight:800;white-space:nowrap;border:1px solid #14532d;background:#052e16;color:#bbf7d0}.dot{width:9px;height:9px;border-radius:999px;background:#22c55e;box-shadow:0 0 16px #22c55e}.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(190px,1fr));gap:14px;margin-bottom:18px}.card{background:var(--panel);border:1px solid var(--line);border-radius:18px;padding:17px;min-height:102px;position:relative;overflow:hidden}.card:before{content:"";position:absolute;left:0;top:17px;bottom:17px;width:6px;border-radius:8px;background:var(--accent,var(--blue))}.label{font-size:12px;text-transform:uppercase;letter-spacing:.08em;color:var(--muted);margin-left:13px}.value{font-size:24px;font-weight:850;margin:12px 0 0 13px;white-space:pre-line}.grid{display:grid;grid-template-columns:1.05fr .95fr;gap:18px}.panel{background:var(--panel);border:1px solid var(--line);border-radius:18px;padding:18px;margin-bottom:18px}.kicker{font-size:12px;text-transform:uppercase;letter-spacing:.08em;color:var(--muted);margin-bottom:8px}.actions{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:12px}button{width:100%;padding:12px 14px;border:0;border-radius:11px;background:#3f3f46;color:white;font-weight:800;cursor:pointer}.primary button{background:var(--blue)}.cyan button{background:var(--cyan)}.purple button{background:var(--purple)}.amber button{background:var(--amber)}.danger button{background:var(--red)}button:hover{filter:brightness(1.08)}.desc{color:var(--muted);font-size:12px;line-height:1.35;margin-top:7px}pre{white-space:pre-wrap;word-break:break-word;background:#050506;border:1px solid var(--line);border-radius:14px;padding:15px;max-height:620px;overflow:auto;color:#d6d9df}.formgrid{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:12px}label{display:block;color:#d9dde5;font-size:13px;font-weight:800}input,select{width:100%;margin:7px 0 12px;padding:11px 12px;border-radius:10px;border:1px solid #525866;background:#08090c;color:#f7f7f8}.note{font-size:12px;line-height:1.5;color:var(--muted)}@media(max-width:920px){.content{padding:16px}.top{display:block}.badge{margin-top:15px}.grid{grid-template-columns:1fr}}
</style></head><body><main class="content">
<section class="top"><div><h1>Xray Go Control</h1><div class="muted">Full Go / Entware dashboard для Keenetic Xray VLESS failover.</div><div class="listen">Адрес: {{.Listen}}</div></div><div class="badge"><span class="dot"></span>{{.Health}}</div></section>
<section class="cards"><div class="card" style="--accent:var(--green)"><div class="label">Активный слот</div><div class="value">{{.Active}}</div></div><div class="card" style="--accent:var(--cyan)"><div class="label">Primary</div><div class="value">{{.Primary}}</div></div><div class="card" style="--accent:var(--purple)"><div class="label">Backup</div><div class="value">{{.Backup}}</div></div><div class="card" style="--accent:var(--amber)"><div class="label">Watchdog</div><div class="value">{{.Watchdog}}</div></div><div class="card" style="--accent:var(--blue)"><div class="label">Recovery</div><div class="value">{{.Recovery}}</div></div><div class="card" style="--accent:var(--cyan)"><div class="label">Proxy0</div><div class="value">{{.Proxy0}}</div></div></section>
<div class="grid"><div>
<section class="panel"><div class="kicker">Overview</div><h2>Статус и диагностика</h2><div class="actions">{{range actionsIn .Actions "overview"}}<form method="post" action="/action" class="{{.Tone}}"><input type="hidden" name="token" value="{{$.Token}}"><input type="hidden" name="id" value="{{.ID}}"><button>{{.Label}}</button><div class="desc">{{.Description}}</div></form>{{end}}{{range actionsIn .Actions "diagnostics"}}<form method="post" action="/action" class="{{.Tone}}"><input type="hidden" name="token" value="{{$.Token}}"><input type="hidden" name="id" value="{{.ID}}"><button>{{.Label}}</button><div class="desc">{{.Description}}</div></form>{{end}}</div></section>
<section class="panel"><div class="kicker">Failover</div><h2>Переключение</h2><div class="actions">{{range actionsIn .Actions "failover"}}<form method="post" action="/action" class="{{.Tone}}"><input type="hidden" name="token" value="{{$.Token}}"><input type="hidden" name="id" value="{{.ID}}"><button>{{.Label}}</button><div class="desc">{{.Description}}</div></form>{{end}}</div></section>
<section class="panel"><div class="kicker">Recovery</div><h2>Тихое восстановление</h2><div class="actions">{{range actionsIn .Actions "recovery"}}<form method="post" action="/action" class="{{.Tone}}"><input type="hidden" name="token" value="{{$.Token}}"><input type="hidden" name="id" value="{{.ID}}"><button>{{.Label}}</button><div class="desc">{{.Description}}</div></form>{{end}}</div></section>
<section class="panel"><div class="kicker">Sources</div><h2>Источники и selectors</h2><form method="post" action="/set-source"><input type="hidden" name="token" value="{{.Token}}"><div class="formgrid"><div><label>Слот</label><select name="slot"><option value="primary">primary</option><option value="backup">backup</option></select></div><div><label>Selector</label><input name="selector" value="first" placeholder="first, index:7 или name"></div></div><label>VLESS URL или subscription URL</label><input type="password" name="source" autocomplete="off" placeholder="vless://... или https://..."><button>Сохранить источник</button></form><p class="note">Source значения отправляются как password-поля и не выводятся обратно на страницу.</p><form method="post" action="/set-selector"><input type="hidden" name="token" value="{{.Token}}"><div class="formgrid"><div><label>Primary selector</label><input name="primary" value="{{.PrimarySel}}"></div><div><label>Backup selector</label><input name="backup" value="{{.BackupSel}}"></div></div><button>Сохранить selectors</button></form></section>
</div><div>
<section class="panel"><div class="kicker">Status</div><h2>Системный статус</h2><pre>{{.Status}}</pre></section>
<section class="panel"><div class="kicker">Updates</div><h2>Обновления</h2><div class="actions">{{range actionsIn .Actions "updates"}}<form method="post" action="/action" class="{{.Tone}}"><input type="hidden" name="token" value="{{$.Token}}"><input type="hidden" name="id" value="{{.ID}}"><button>{{.Label}}</button><div class="desc">{{.Description}}</div></form>{{end}}</div></section>
<section class="panel"><div class="kicker">Maintenance</div><h2>Обслуживание</h2><div class="actions">{{range actionsIn .Actions "maintenance"}}<form method="post" action="/action" class="{{.Tone}}"><input type="hidden" name="token" value="{{$.Token}}"><input type="hidden" name="id" value="{{.ID}}"><button>{{.Label}}</button><div class="desc">{{.Description}}</div></form>{{end}}</div></section>
<section class="panel"><div class="kicker">Logs</div><h2>Логи и история</h2><div class="actions">{{range actionsIn .Actions "logs"}}<form method="post" action="/action" class="{{.Tone}}"><input type="hidden" name="token" value="{{$.Token}}"><input type="hidden" name="id" value="{{.ID}}"><button>{{.Label}}</button><div class="desc">{{.Description}}</div></form>{{end}}</div></section>
</div></div>
{{if .Output}}<section class="panel"><div class="kicker">Output</div><h2>Вывод команды</h2><pre>{{.Output}}</pre></section>{{end}}
<section class="panel"><div class="kicker">Security</div><h2>LAN only</h2><p class="note">Используй Web UI только в доверенной LAN. Не публикуй порт Web UI в WAN. Support diagnostics вызываются через <code>xray-go doctor --support</code>.</p></section>
</main></body></html>`))

func main() {
	listen := readListen()
	token, err := ensureToken(tokenPath)
	if err != nil { log.Fatalf("token: %v", err) }
	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" { http.NotFound(w, r); return }
		render(w, listen, token, "")
	})
	mux.HandleFunc("/action", post(token, listen, func(r *http.Request) string { return runAction(r.FormValue("id")) }))
	mux.HandleFunc("/set-source", post(token, listen, handleSetSource))
	mux.HandleFunc("/set-selector", post(token, listen, handleSetSelector))
	ln, err := net.Listen("tcp", listen)
	if err != nil { log.Fatalf("listen %s: %v", listen, err) }
	log.Printf("xray-go-web started: http://%s", listen)
	log.Fatal(http.Serve(ln, mux))
}

func post(token, listen string, fn func(*http.Request) string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost { http.Error(w, "POST required", http.StatusMethodNotAllowed); return }
		if r.FormValue("token") != token { http.Error(w, "bad token", http.StatusForbidden); return }
		render(w, listen, token, fn(r))
	}
}

func render(w http.ResponseWriter, listen, token, output string) {
	status := quickStatus()
	pd := pageData{
		Listen: listen, Token: token, Status: status, Output: output, Actions: actions,
		Active: pick(status, "unknown", "активный слот:", "active slot:", "active:"),
		Primary: pick(status, "unknown", "основной профиль:", "primary source:", "primary:"),
		Backup: pick(status, "unknown", "резервный профиль:", "backup source:", "backup:"),
		Watchdog: pick(status, "unknown", "daemon:"),
		Recovery: recoverySummary(status),
		Proxy0: proxy0Summary(status),
		Health: health(status),
		PrimarySel: readFile("/opt/etc/xray/vless-go.primary.selector", "first"),
		BackupSel: readFile("/opt/etc/xray/vless-go.backup.selector", "first"),
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	_ = page.Execute(w, pd)
}

func quickStatus() string {
	if exists("/opt/bin/xray-go") {
		return "$ /opt/bin/xray-go status\n" + runCommand([]string{"/opt/bin/xray-go", "status"}, 25*time.Second)
	}
	parts := []string{}
	fallback := [][]string{{"/opt/bin/vless-go-failover", "status"}, {"/opt/bin/vless-go-watchdog", "status"}, {"/opt/bin/vless-go-recover", "status"}}
	for _, cmd := range fallback { parts = append(parts, "$ "+strings.Join(cmd, " "), runCommand(cmd, 10*time.Second)) }
	return strings.Join(parts, "\n\n")
}

func pick(s, def string, keys ...string) string {
	for _, line := range strings.Split(s, "\n") {
		line = strings.TrimSpace(line)
		for _, key := range keys {
			if strings.HasPrefix(strings.ToLower(line), strings.ToLower(key)) { return strings.TrimSpace(line[len(key):]) }
		}
	}
	return def
}

func recoverySummary(s string) string {
	lower := strings.ToLower(s)
	if strings.Contains(lower, "hourly recovery: enabled") { return "enabled" }
	if strings.Contains(lower, "hourly recovery: disabled") { return "disabled" }
	if strings.Contains(lower, "health: ok") { return "health OK" }
	return "unknown"
}

func proxy0Summary(s string) string {
	lower := strings.ToLower(s)
	if strings.Contains(lower, "proxy iface: proxy0") || strings.Contains(lower, "proxy0") { return "Proxy0" }
	return "unknown"
}

func health(s string) string {
	lower := strings.ToLower(s)
	bad := []string{"[fail]", "health: fail", "not running", "не запущен", "ошибка", "не найдено"}
	for _, b := range bad { if strings.Contains(lower, b) { return "НУЖНА ПРОВЕРКА" } }
	good := []string{"health: ok", "daemon: запущен", "daemon: running", "daemon: alive", "socks:"}
	for _, g := range good { if strings.Contains(lower, g) { return "ОНЛАЙН" } }
	return "ГОТОВ"
}

func actionsIn(items []action, group string) []action {
	out := []action{}
	for _, item := range items { if item.Group == group { out = append(out, item) } }
	return out
}

func runAction(id string) string {
	for _, a := range actions { if a.ID == id { return "$ "+strings.Join(a.Command, " ")+"\n"+runCommand(a.Command, a.Timeout) } }
	return "unknown action: " + id
}

func handleSetSource(r *http.Request) string {
	slot := strings.TrimSpace(r.FormValue("slot")); source := strings.TrimSpace(r.FormValue("source")); selector := strings.TrimSpace(r.FormValue("selector"))
	if selector == "" { selector = "first" }
	if slot != "primary" && slot != "backup" { return "ОШИБКА: неверный слот" }
	if source == "" { return "ОШИБКА: источник пустой" }
	cmd := []string{"/opt/bin/vless-go-failover", "set-"+slot, source, "--selector", selector}
	return "$ /opt/bin/vless-go-failover set-"+slot+" <hidden> --selector "+selector+"\n"+runCommand(cmd, 120*time.Second)
}

func handleSetSelector(r *http.Request) string {
	out := []string{}
	if p := strings.TrimSpace(r.FormValue("primary")); p != "" { cmd := []string{"/opt/bin/vless-go-failover", "set-selector", "primary", p}; out = append(out, "$ "+strings.Join(cmd, " ")+"\n"+runCommand(cmd, 40*time.Second)) }
	if b := strings.TrimSpace(r.FormValue("backup")); b != "" { cmd := []string{"/opt/bin/vless-go-failover", "set-selector", "backup", b}; out = append(out, "$ "+strings.Join(cmd, " ")+"\n"+runCommand(cmd, 40*time.Second)) }
	return strings.Join(out, "\n")
}

func runCommand(cmd []string, timeout time.Duration) string {
	if len(cmd) == 0 { return "empty command" }
	if !exists(cmd[0]) { return "не найдено: " + cmd[0] }
	ctx, cancel := context.WithTimeout(context.Background(), timeout); defer cancel()
	c := exec.CommandContext(ctx, cmd[0], cmd[1:]...)
	var out bytes.Buffer; c.Stdout = &out; c.Stderr = &out
	err := c.Run()
	text := strings.TrimSpace(out.String())
	if ctx.Err() == context.DeadlineExceeded { return text + "\nTIMEOUT" }
	if err != nil { return text + "\nERROR: " + err.Error() }
	if text == "" { return "OK (no output)" }
	return text
}

func exists(path string) bool { _, err := os.Stat(path); return err == nil }

func readListen() string {
	if v := strings.TrimSpace(os.Getenv("VLESS_GO_WEB_LISTEN")); v != "" { return v }
	if data, err := os.ReadFile(configPath); err == nil {
		for _, line := range strings.Split(string(data), "\n") {
			line = strings.TrimSpace(line)
			if strings.HasPrefix(line, "LISTEN=") { return strings.Trim(strings.TrimPrefix(line, "LISTEN="), "\"") }
		}
	}
	return defaultListen
}

func ensureToken(path string) (string, error) {
	if data, err := os.ReadFile(path); err == nil { if tok := strings.TrimSpace(string(data)); tok != "" { return tok, nil } }
	b := make([]byte, 16); if _, err := rand.Read(b); err != nil { return "", err }
	tok := hex.EncodeToString(b)
	if err := os.MkdirAll("/opt/etc/xray", 0700); err != nil { return "", err }
	if err := os.WriteFile(path, []byte(tok+"\n"), 0600); err != nil { return "", err }
	return tok, nil
}

func readFile(path, def string) string {
	data, err := os.ReadFile(path); if err != nil { return def }
	v := strings.TrimSpace(string(data)); if v == "" { return def }
	return v
}

func _keepFmt() { _ = fmt.Sprintf }
